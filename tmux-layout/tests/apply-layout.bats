#!/usr/bin/env bats

# apply-layout.sh のテスト。
# 実際の tmux セッションを使い、pane/window の副作用まで検証する。

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
APPLY_LAYOUT="${SCRIPT_DIR}/apply-layout.sh"

setup() {
    TEST_SESSION="test-apply-layout-$$-${BATS_TEST_NUMBER}"
    tmux new-session -d -s "${TEST_SESSION}" -x 200 -y 50
    INITIAL_PANE="$(tmux list-panes -t "${TEST_SESSION}" -F '#{pane_id}')"
    INITIAL_WINDOW="$(tmux list-windows -t "${TEST_SESSION}" -F '#{window_id}')"
    export TMUX_PANE="$INITIAL_PANE"
}

teardown() {
    tmux kill-session -t "${TEST_SESSION}" 2>/dev/null || true
}

result_json() {
    # Args:
    #   なし。Bats の `$output` を参照する。
    # Returns:
    #   標準出力: apply-layout.sh が stdout に出した JSON。
    # Overview:
    #   stderr 側のログを混ぜる実行環境でも JSON だけを取り出せるようにする。
    printf '%s\n' "$output" | grep -v '^\[apply-layout\]' | jq -c .
}

pane_count_in_window() {
    # Args:
    #   $1: tmux window_id。
    # Returns:
    #   標準出力: 対象 window に存在する pane 数。
    # Overview:
    #   list-panes の行数を空白なしの数値に正規化する。
    tmux list-panes -t "${TEST_SESSION}:$1" | wc -l | tr -d ' '
}

pane_value() {
    # Args:
    #   $1: tmux pane_id。
    #   $2: tmux format 文字列。
    # Returns:
    #   標準出力: 指定 pane の format 評価結果。
    # Overview:
    #   視覚的な pane 配置を座標値で検証する。
    tmux display-message -p -t "$1" "$2"
}

# シナリオ: JSON として解釈できない入力を渡す。
# 保証: tmux 操作を行わず、終了コード 1 で失敗する。
@test "apply-layout rejects invalid JSON" {
    run bash "${APPLY_LAYOUT}" "not valid json" "${TEST_SESSION}"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid JSON"* ]]
}

# シナリオ: top だけで bottom がなく、2x2 領域を覆い切れない layout を渡す。
# 保証: 領域不足として拒否される。
@test "apply-layout rejects incomplete position coverage" {
    local layout='[{"group_id":0,"pane_id":null,"position":"top"}]'

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 1 ]
    [[ "$output" == *"must cover"* ]]
}

# シナリオ: whole と他 position が同じ group に混在し、領域が重複する。
# 保証: 重複 layout として拒否される。
@test "apply-layout rejects overlapping positions" {
    local layout='[
        {"group_id":0,"pane_id":null,"position":"whole"},
        {"group_id":0,"pane_id":null,"position":"top"}
    ]'

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 1 ]
    [[ "$output" == *"overlap"* ]]
}

# シナリオ: 同じ group 内で position が重複する layout を渡す。
# 保証: 同じ 2x2 領域を二重利用するため拒否される。
@test "apply-layout rejects duplicate positions" {
    local layout='[
        {"group_id":0,"pane_id":null,"position":"top"},
        {"group_id":0,"pane_id":null,"position":"top"},
        {"group_id":0,"pane_id":null,"position":"bottom"}
    ]'

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Duplicate position"* ]]
}

# シナリオ: session に存在する pane を layout に含めず、新規 pane として扱う入力を渡す。
# 保証: session 状態と layout の pane_id 集合が不整合なため、バリデーションエラーになる。
@test "apply-layout rejects layout that omits an existing session pane" {
    local layout='[
        {"group_id":0,"pane_id":null,"position":"whole"}
    ]'

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 1 ]
    [[ "$output" == *"does not match session panes"* ]]
}

# シナリオ: layout が session に存在しない pane_id を参照する。
# 保証: session 状態と layout の pane_id 集合が不整合なため、バリデーションエラーになる。
@test "apply-layout rejects layout that references a non-session pane" {
    local layout
    layout="$(jq -n --arg keep_id "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$keep_id, "position":"top"},
        {"group_id":0, "pane_id":"%999999", "position":"bottom"}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 1 ]
    [[ "$output" == *"does not match session panes"* ]]
}

# シナリオ: apply-layout.sh を実行した pane を削除対象にする layout を渡す。
# 保証: 実行元 pane は position null を許容しないため、バリデーションエラーになる。
@test "apply-layout rejects deleting the invoking pane" {
    tmux split-window -t "${TEST_SESSION}"
    local panes other_pane layout
    panes="$(tmux list-panes -t "${TEST_SESSION}" -F '#{pane_id}')"
    other_pane="$(printf '%s\n' "$panes" | sed -n '2p')"
    layout="$(jq -n --arg runner "$TMUX_PANE" --arg other "$other_pane" '[
        {"group_id":0, "pane_id":$other, "position":"whole"},
        {"group_id":null, "pane_id":$runner, "position":null}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 1 ]
    [[ "$output" == *"invoking pane"* ]]
}

# シナリオ: position null の pane を含む cleanup layout を渡す。
# 保証: 指定 pane だけが kill され、維持対象 pane は残る。
@test "apply-layout kills panes with position null" {
    tmux split-window -t "${TEST_SESSION}"
    local panes pane_to_keep pane_to_kill layout remaining_panes
    panes="$(tmux list-panes -t "${TEST_SESSION}" -F '#{pane_id}')"
    pane_to_keep="$(printf '%s\n' "$panes" | sed -n '1p')"
    pane_to_kill="$(printf '%s\n' "$panes" | sed -n '2p')"
    layout="$(jq -n --arg keep_id "$pane_to_keep" --arg kill_id "$pane_to_kill" '[
        {"group_id":0, "pane_id":$keep_id, "position":"whole"},
        {"group_id":null, "pane_id":$kill_id, "position":null}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 0 ]
    remaining_panes="$(tmux list-panes -a -t "${TEST_SESSION}" -F '#{pane_id}')"
    [[ "$remaining_panes" == *"$pane_to_keep"* ]]
    [[ "$remaining_panes" != *"$pane_to_kill"* ]]
}

# シナリオ: group_id が 2 つある layout を空に近い session へ適用する。
# 保証: group 数に合わせて window が作成され、結果 JSON は 2 window を返す。
@test "apply-layout creates windows for groups" {
    local layout result window_count
    layout="$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0,"pane_id":$pid,"position":"whole"},
        {"group_id":1,"pane_id":null,"position":"whole"}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 0 ]
    window_count="$(tmux list-windows -t "${TEST_SESSION}" | wc -l | tr -d ' ')"
    [ "$window_count" -eq 2 ]
    result="$(result_json)"
    [ "$(jq 'keys | length' <<< "$result")" -eq 2 ]
}

# シナリオ: 既存 pane を別 group の window へ移動する layout を渡す。
# 保証: 指定 pane は目標 group window に集約され、移動元 window は余分に残らない。
@test "apply-layout moves existing pane to target group window" {
    tmux new-window -t "${TEST_SESSION}"
    local second_window_pane layout first_window panes_in_first window_count pane_count
    second_window_pane="$(tmux list-panes -t "${TEST_SESSION}:1" -F '#{pane_id}')"
    layout="$(jq -n --arg keep_id "$INITIAL_PANE" --arg move_id "$second_window_pane" '[
        {"group_id":0, "pane_id":$keep_id, "position":"top"},
        {"group_id":0, "pane_id":$move_id, "position":"bottom"}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 0 ]
    first_window="$(tmux list-windows -t "${TEST_SESSION}" -F '#{window_id}' | sed -n '1p')"
    panes_in_first="$(tmux list-panes -t "${TEST_SESSION}:${first_window}" -F '#{pane_id}')"
    window_count="$(tmux list-windows -t "${TEST_SESSION}" | wc -l | tr -d ' ')"
    pane_count="$(pane_count_in_window "$first_window")"
    [ "$window_count" -eq 1 ]
    [ "$pane_count" -eq 2 ]
    [[ "$panes_in_first" == *"$second_window_pane"* ]]
}

# シナリオ: 既存 pane がない group と、既存 pane だけの group を同時に適用する。
# 保証: 新規 window の初期 pane は layout に割り当てられず、pane_id null の補充分だけが残る。
@test "apply-layout deletes new-window initial pane after filling null pane" {
    local layout result first_window second_window first_position second_position window_count total_pane_count
    layout="$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":null, "position":"whole"},
        {"group_id":1, "pane_id":$pid, "position":"whole"}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 0 ]
    result="$(result_json)"
    first_window="$(tmux list-windows -t "${TEST_SESSION}" -F '#{window_id}' | sed -n '1p')"
    second_window="$(tmux list-windows -t "${TEST_SESSION}" -F '#{window_id}' | sed -n '2p')"
    window_count="$(tmux list-windows -t "${TEST_SESSION}" | wc -l | tr -d ' ')"
    total_pane_count="$(tmux list-panes -s -t "${TEST_SESSION}" -F '#{pane_id}' | wc -l | tr -d ' ')"
    [ "$window_count" -eq 2 ]
    [ "$total_pane_count" -eq 2 ]
    [ "$(jq --arg window_id "$first_window" '.[$window_id] | length' <<< "$result")" -eq 1 ]
    [ "$(jq --arg window_id "$second_window" '.[$window_id] | length' <<< "$result")" -eq 1 ]
    first_position="$(jq -r --arg window_id "$first_window" '.[$window_id][0].position' <<< "$result")"
    second_position="$(jq -r --arg window_id "$second_window" '.[$window_id][0].position' <<< "$result")"
    [ "$first_position" = "whole" ]
    [ "$second_position" = "whole" ]
    [ "$(jq -r --arg window_id "$second_window" '.[$window_id][0].pane_id' <<< "$result")" = "$INITIAL_PANE" ]
}

# シナリオ: 1 pane window 同士の group 順が layout と逆になっている。
# 保証: pane 移動ではなく window の並び替えで、stale window_id を参照せずに完了する。
@test "apply-layout reorders single-pane windows without stale window ids" {
    tmux new-window -t "${TEST_SESSION}"
    local second_pane layout result first_window second_window
    second_pane="$(tmux list-panes -t "${TEST_SESSION}:1" -F '#{pane_id}')"
    layout="$(jq -n --arg first "$INITIAL_PANE" --arg second "$second_pane" '[
        {"group_id":0, "pane_id":$second, "position":"whole"},
        {"group_id":1, "pane_id":$first, "position":"whole"}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 0 ]
    result="$(result_json)"
    first_window="$(tmux list-windows -t "${TEST_SESSION}" -F '#{window_id}' | sed -n '1p')"
    second_window="$(tmux list-windows -t "${TEST_SESSION}" -F '#{window_id}' | sed -n '2p')"
    [ "$(jq -r --arg window_id "$first_window" '.[$window_id][0].pane_id' <<< "$result")" = "$second_pane" ]
    [ "$(jq -r --arg window_id "$second_window" '.[$window_id][0].pane_id' <<< "$result")" = "$INITIAL_PANE" ]
}

# シナリオ: pane_id null を含む上下 2 ペイン layout を渡す。
# 保証: 不足分の pane が作成され、結果 JSON から新規 pane_id を取得できる。
@test "apply-layout creates a missing pane" {
    local layout result pane_count new_pane
    layout="$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$pid, "position":"top"},
        {"group_id":0, "pane_id":null, "position":"bottom"}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 0 ]
    pane_count="$(pane_count_in_window "$INITIAL_WINDOW")"
    [ "$pane_count" -eq 2 ]
    result="$(result_json)"
    new_pane="$(jq -r '.[][] | select(.position == "bottom") | .pane_id' <<< "$result")"
    [[ "$new_pane" == %* ]]
}

# シナリオ: left/right の 2 ペイン layout を渡す。
# 保証: 仕様上有効な左右分割として受理され、両 position が結果に出る。
@test "apply-layout supports left and right positions" {
    local layout result positions
    layout="$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$pid, "position":"left"},
        {"group_id":0, "pane_id":null, "position":"right"}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 0 ]
    result="$(result_json)"
    positions="$(jq -r '[.[][] | .position] | sort | join(",")' <<< "$result")"
    [ "$positions" = "left,right" ]
}

# シナリオ: left と右側 2 分割が混在する 3 ペイン layout を渡す。
# 保証: 2x2 領域を重複なく覆う混在形として受理される。
@test "apply-layout supports mixed left and right-side quadrants" {
    local layout result positions
    layout="$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$pid, "position":"left"},
        {"group_id":0, "pane_id":null, "position":"top-right"},
        {"group_id":0, "pane_id":null, "position":"bottom-right"}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 0 ]
    result="$(result_json)"
    positions="$(jq -r '[.[][] | .position] | sort | join(",")' <<< "$result")"
    [ "$positions" = "bottom-right,left,top-right" ]
    [ "$(jq '[.[] | length] | add' <<< "$result")" -eq 3 ]
}

# シナリオ: left と右側 2 分割の混在 layout を適用する。
# 保証: tmux 上の座標も「左 pane + 右上 pane + 右下 pane」の形になる。
@test "apply-layout physically shapes mixed left and right-side quadrants" {
    local layout result left_pane top_right_pane bottom_right_pane
    layout="$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$pid, "position":"left"},
        {"group_id":0, "pane_id":null, "position":"top-right"},
        {"group_id":0, "pane_id":null, "position":"bottom-right"}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 0 ]
    result="$(result_json)"
    left_pane="$(jq -r '.[][] | select(.position == "left") | .pane_id' <<< "$result")"
    top_right_pane="$(jq -r '.[][] | select(.position == "top-right") | .pane_id' <<< "$result")"
    bottom_right_pane="$(jq -r '.[][] | select(.position == "bottom-right") | .pane_id' <<< "$result")"
    [ "$(pane_value "$left_pane" '#{pane_left}')" -lt "$(pane_value "$top_right_pane" '#{pane_left}')" ]
    [ "$(pane_value "$top_right_pane" '#{pane_left}')" -eq "$(pane_value "$bottom_right_pane" '#{pane_left}')" ]
    [ "$(pane_value "$top_right_pane" '#{pane_top}')" -lt "$(pane_value "$bottom_right_pane" '#{pane_top}')" ]
}

# シナリオ: 4 象限 layout を渡す。
# 保証: 4 pane が作られ、各 quadrant に pane_id が対応付く。
@test "apply-layout arranges four quadrant positions" {
    local layout result positions pane_count
    layout="$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$pid, "position":"top-left"},
        {"group_id":0, "pane_id":null, "position":"top-right"},
        {"group_id":0, "pane_id":null, "position":"bottom-left"},
        {"group_id":0, "pane_id":null, "position":"bottom-right"}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 0 ]
    result="$(result_json)"
    pane_count="$(jq '[.[] | length] | add' <<< "$result")"
    [ "$pane_count" -eq 4 ]
    positions="$(jq -r '[.[][] | .position] | sort | join(",")' <<< "$result")"
    [ "$positions" = "bottom-left,bottom-right,top-left,top-right" ]
}

# シナリオ: 既存 4 pane のうち 2 pane を新規 group window へ移す。
# 保証: new-window が作る ghost pane は残らず、元の agent pane はすべて残る。
@test "apply-layout removes ghost panes without killing moved panes" {
    tmux split-window -t "${TEST_SESSION}"
    tmux split-window -t "${TEST_SESSION}"
    tmux split-window -t "${TEST_SESSION}"

    local all_panes pane1 pane2 pane3 pane4 layout second_window pane_count remaining_panes
    all_panes="$(tmux list-panes -t "${TEST_SESSION}" -F '#{pane_id}')"
    pane1="$(printf '%s\n' "$all_panes" | sed -n '1p')"
    pane2="$(printf '%s\n' "$all_panes" | sed -n '2p')"
    pane3="$(printf '%s\n' "$all_panes" | sed -n '3p')"
    pane4="$(printf '%s\n' "$all_panes" | sed -n '4p')"
    layout="$(jq -n --arg p1 "$pane1" --arg p2 "$pane2" --arg p3 "$pane3" --arg p4 "$pane4" '[
        {"group_id":0, "pane_id":$p1, "position":"top"},
        {"group_id":0, "pane_id":$p2, "position":"bottom"},
        {"group_id":1, "pane_id":$p3, "position":"top"},
        {"group_id":1, "pane_id":$p4, "position":"bottom"}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 0 ]
    remaining_panes="$(tmux list-panes -a -t "${TEST_SESSION}" -F '#{pane_id}')"
    [[ "$remaining_panes" == *"$pane1"* ]]
    [[ "$remaining_panes" == *"$pane2"* ]]
    [[ "$remaining_panes" == *"$pane3"* ]]
    [[ "$remaining_panes" == *"$pane4"* ]]
    second_window="$(tmux list-windows -t "${TEST_SESSION}" -F '#{window_id}' | sed -n '2p')"
    pane_count="$(pane_count_in_window "$second_window")"
    [ "$pane_count" -eq 2 ]
}

# シナリオ: 初回結果の pane_id を使って同じ目標 layout を 2 回続けて適用する。
# 保証: 2 回目に余分な pane は作られず、pane 数は目標数のまま維持される。
@test "apply-layout is idempotent when existing panes are explicit" {
    local layout first_result second_layout second_result first_count second_count bottom_pane
    layout="$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$pid, "position":"top"},
        {"group_id":0, "pane_id":null, "position":"bottom"}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 0 ]
    first_result="$(result_json)"
    first_count="$(pane_count_in_window "$INITIAL_WINDOW")"
    bottom_pane="$(jq -r '.[][] | select(.position == "bottom") | .pane_id' <<< "$first_result")"
    second_layout="$(jq -n --arg top_pane "$INITIAL_PANE" --arg bottom_pane "$bottom_pane" '[
        {"group_id":0, "pane_id":$top_pane, "position":"top"},
        {"group_id":0, "pane_id":$bottom_pane, "position":"bottom"}
    ]')"

    run bash "${APPLY_LAYOUT}" "$second_layout" "${TEST_SESSION}"

    [ "$status" -eq 0 ]
    second_result="$(result_json)"
    second_count="$(pane_count_in_window "$INITIAL_WINDOW")"
    [ "$first_count" -eq 2 ]
    [ "$second_count" -eq 2 ]
    [ "$(jq '[.[] | length] | add' <<< "$first_result")" -eq 2 ]
    [ "$(jq '[.[] | length] | add' <<< "$second_result")" -eq 2 ]
}

# シナリオ: whole 1 pane の layout を渡す。
# 保証: window 内は 1 pane となり、結果 JSON も whole を返す。
@test "apply-layout handles whole position" {
    local layout result pane_count position
    layout="$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$pid, "position":"whole"}
    ]')"

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"

    [ "$status" -eq 0 ]
    result="$(result_json)"
    position="$(jq -r '.[][] | .position' <<< "$result")"
    [ "$position" = "whole" ]
    pane_count="$(pane_count_in_window "$INITIAL_WINDOW")"
    [ "$pane_count" -eq 1 ]
}
