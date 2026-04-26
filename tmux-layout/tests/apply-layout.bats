#!/usr/bin/env bats

# apply-layout.sh のテスト
# 実際の tmux セッションを使って検証する

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
APPLY_LAYOUT="${SCRIPT_DIR}/apply-layout.sh"

setup() {
    TEST_SESSION="test-apply-layout-$$"
    # テスト用 tmux セッションを作成（デタッチ状態）
    tmux new-session -d -s "${TEST_SESSION}" -x 200 -y 50
    # 初期ペインIDを取得
    INITIAL_PANE=$(tmux list-panes -t "${TEST_SESSION}" -F '#{pane_id}')
    INITIAL_WINDOW=$(tmux list-windows -t "${TEST_SESSION}" -F '#{window_id}')
}

teardown() {
    # テスト用セッションを破棄（存在する場合）
    tmux kill-session -t "${TEST_SESSION}" 2>/dev/null || true
}

# --- バリデーションテスト ---

# シナリオ: JSON として解釈できない入力を渡す。
# 保証: apply-layout は失敗し、入力不正を示すエラーを返す。
@test "apply-layout rejects invalid JSON" {
    run bash "${APPLY_LAYOUT}" "not valid json" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error"* ]] || [[ "$output" == *"Error"* ]] || [[ "$output" == *"invalid"* ]] || [[ "$output" == *"Invalid"* ]]
}

# シナリオ: top だけで bottom がないレイアウトを渡す。
# 保証: 4 つの基本領域を覆えないため validation error になる。
@test "apply-layout rejects top without bottom" {
    local layout='[{"group_id":0,"pane_id":null,"position":"top"}]'
    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
}

# シナリオ: top-left だけで残りの基本領域がないレイアウトを渡す。
# 保証: 4 つの基本領域を覆えないため validation error になる。
@test "apply-layout rejects top-left without top-right" {
    local layout='[{"group_id":0,"pane_id":null,"position":"top-left"}]'
    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
}

# シナリオ: left だけで right がないレイアウトを渡す。
# 保証: 4 つの基本領域を覆えないため validation error になる。
@test "apply-layout rejects left without right" {
    local layout='[{"group_id":0,"pane_id":null,"position":"left"}]'
    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
}

# シナリオ: whole と他の position が同じ group に混在する。
# 保証: whole は単独利用しか許可されず validation error になる。
@test "apply-layout rejects whole with other panes" {
    local layout='[
        {"group_id":0,"pane_id":null,"position":"whole"},
        {"group_id":0,"pane_id":null,"position":"top"}
    ]'
    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
}

# シナリオ: top と top-right のように占有領域が重なる position を渡す。
# 保証: 重複する基本領域が検出され validation error になる。
@test "apply-layout rejects conflicting positions" {
    # top と top-right は同じ top-right 領域を占有するため矛盾する。
    local layout='[
        {"group_id":0,"pane_id":null,"position":"top"},
        {"group_id":0,"pane_id":null,"position":"top-right"}
    ]'
    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
}

# シナリオ: 2 ペイン系と 4 ペイン系を混在させ、占有領域が重なる構成を渡す。
# 保証: 重複する基本領域が検出され validation error になる。
@test "apply-layout rejects mixed positions that overlap" {
    local layout='[
        {"group_id":0,"pane_id":null,"position":"left"},
        {"group_id":0,"pane_id":null,"position":"bottom-left"},
        {"group_id":0,"pane_id":null,"position":"top-right"}
    ]'
    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
}

# シナリオ: 同じ group 内に同一 position が複数あるレイアウトを渡す。
# 保証: 重複 position が検出され validation error になる。
@test "apply-layout rejects duplicate positions" {
    local layout='[
        {"group_id":0,"pane_id":null,"position":"top"},
        {"group_id":0,"pane_id":null,"position":"top"},
        {"group_id":0,"pane_id":null,"position":"bottom"}
    ]'
    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
}

# --- 削除テスト ---

# シナリオ: position が null の既存ペインを含むレイアウトを渡す。
# 保証: 対象ペインだけが kill され、残すべきペインは維持される。
@test "apply-layout kills panes with position null" {
    # 2つ目のペインを作成
    tmux split-window -t "${TEST_SESSION}"
    local panes
    panes=$(tmux list-panes -t "${TEST_SESSION}" -F '#{pane_id}')
    local pane_to_kill
    pane_to_kill=$(echo "$panes" | tail -1)
    local pane_to_keep
    pane_to_keep=$(echo "$panes" | head -1)

    local layout
    layout=$(jq -n --arg kill_id "$pane_to_kill" --arg keep_id "$pane_to_keep" '[
        {"group_id":0, "pane_id":$keep_id, "position":"whole"},
        {"group_id":null, "pane_id":$kill_id, "position":null}
    ]')

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 0 ]

    # kill されたペインが存在しないことを確認
    local remaining_panes
    remaining_panes=$(tmux list-panes -t "${TEST_SESSION}" -F '#{pane_id}')
    [[ "$remaining_panes" != *"$pane_to_kill"* ]]
}

# --- ウィンドウ・グループテスト ---

# シナリオ: 複数の group_id を持つレイアウトを渡す。
# 保証: group_id ごとに tmux window が用意される。
@test "apply-layout groups panes by group_id" {
    # 2つの group_id → 2つのウィンドウ
    local layout='[
        {"group_id":0,"pane_id":null,"position":"whole"},
        {"group_id":1,"pane_id":null,"position":"whole"}
    ]'

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 0 ]

    # ウィンドウが2つあることを確認
    local window_count
    window_count=$(tmux list-windows -t "${TEST_SESSION}" | wc -l)
    [ "$window_count" -eq 2 ]
}

# シナリオ: 既存ペインを別 window から対象 group の window へ移動する。
# 保証: 指定された既存ペインが group_id に対応する window へ移動する。
@test "apply-layout moves existing pane to correct window" {
    # 2つ目のウィンドウを作成し、そこにペインを作る
    tmux new-window -t "${TEST_SESSION}"
    local second_window_pane
    second_window_pane=$(tmux list-panes -t "${TEST_SESSION}:1" -F '#{pane_id}')

    # group_id:0 に second_window_pane を移動させるレイアウト
    local layout
    layout=$(jq -n --arg pid "$second_window_pane" --arg keep_id "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$keep_id, "position":"top"},
        {"group_id":0, "pane_id":$pid, "position":"bottom"}
    ]')

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 0 ]

    # second_window_pane が最初のウィンドウに移動していることを確認
    local first_window_id
    first_window_id=$(tmux list-windows -t "${TEST_SESSION}" -F '#{window_id}' | head -1)
    local panes_in_first
    panes_in_first=$(tmux list-panes -t "${TEST_SESSION}:${first_window_id}" -F '#{pane_id}')
    [[ "$panes_in_first" == *"$second_window_pane"* ]]
}

# シナリオ: pane_id が null の entry を含むレイアウトを渡す。
# 保証: null entry に対応する新規ペインが作成される。
@test "apply-layout creates new pane" {
    # pane_id: null → split-window が実行される
    local layout
    layout=$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$pid, "position":"top"},
        {"group_id":0, "pane_id":null, "position":"bottom"}
    ]')

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 0 ]

    # ペインが2つになっていることを確認
    local pane_count
    pane_count=$(tmux list-panes -t "${TEST_SESSION}:${INITIAL_WINDOW}" | wc -l)
    [ "$pane_count" -eq 2 ]
}

# シナリオ: 既存ペインを持たない新しい group を含むレイアウトを渡す。
# 保証: 不足する tmux window が作成され、その group が配置される。
@test "apply-layout creates new window when no existing pane" {
    # 全 pane_id: null の新しいグループ → new-window
    local layout
    layout=$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$pid, "position":"whole"},
        {"group_id":1, "pane_id":null, "position":"whole"}
    ]')

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 0 ]

    # ウィンドウが2つあることを確認
    local window_count
    window_count=$(tmux list-windows -t "${TEST_SESSION}" | wc -l)
    [ "$window_count" -eq 2 ]
}

# シナリオ: top-left / top-right / bottom-left / bottom-right の 4 分割を適用する。
# 保証: 4 つの position が結果 JSON に保持される。
@test "apply-layout arranges panes by position" {
    # 4分割: top-left, top-right, bottom-left, bottom-right
    local layout
    layout=$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$pid, "position":"top-left"},
        {"group_id":0, "pane_id":null, "position":"top-right"},
        {"group_id":0, "pane_id":null, "position":"bottom-left"},
        {"group_id":0, "pane_id":null, "position":"bottom-right"}
    ]')

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 0 ]

    # 出力JSONを検証: 4つのペインがあること
    local result
    result=$(echo "$output" | grep -v '^\[apply-layout\]')
    local pane_count
    pane_count=$(echo "$result" | jq '[.[] | length] | add')
    [ "$pane_count" -eq 4 ]

    # 各 position が正しく割り当てられていること
    local positions
    positions=$(echo "$result" | jq -r '[.[][] | .position] | sort | join(",")')
    [ "$positions" = "bottom-left,bottom-right,top-left,top-right" ]
}

# シナリオ: left / right の 2 分割を適用する。
# 保証: 左右 2 ペインの position が結果 JSON に保持される。
@test "apply-layout arranges panes by left and right positions" {
    local layout
    layout=$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$pid, "position":"left"},
        {"group_id":0, "pane_id":null, "position":"right"}
    ]')

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 0 ]

    local result
    result=$(echo "$output" | grep -v '^\[apply-layout\]')
    local pane_count
    pane_count=$(echo "$result" | jq '[.[] | length] | add')
    [ "$pane_count" -eq 2 ]

    local positions
    positions=$(echo "$result" | jq -r '[.[][] | .position] | sort | join(",")')
    [ "$positions" = "left,right" ]
}

# シナリオ: left と右側上下 2 分割の mixed position を適用する。
# 保証: left が全高を占有し、右側だけが上下分割される。
@test "apply-layout allows mixed positions when areas do not overlap" {
    local layout
    layout=$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$pid, "position":"left"},
        {"group_id":0, "pane_id":null, "position":"top-right"},
        {"group_id":0, "pane_id":null, "position":"bottom-right"}
    ]')

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 0 ]

    local result
    result=$(echo "$output" | grep -v '^\[apply-layout\]')
    local pane_count
    pane_count=$(echo "$result" | jq '[.[] | length] | add')
    [ "$pane_count" -eq 3 ]

    local positions
    positions=$(echo "$result" | jq -r '[.[][] | .position] | sort | join(",")')
    [ "$positions" = "bottom-right,left,top-right" ]

    # left は全高を占有し、右側だけが上下に分割されることを保証する。
    local left_pane
    local top_right_pane
    local bottom_right_pane
    left_pane=$(echo "$result" | jq -r '.[][] | select(.position == "left") | .pane_id')
    top_right_pane=$(echo "$result" | jq -r '.[][] | select(.position == "top-right") | .pane_id')
    bottom_right_pane=$(echo "$result" | jq -r '.[][] | select(.position == "bottom-right") | .pane_id')

    local left_x left_y left_width left_height
    local top_right_x top_right_y top_right_width top_right_height
    local bottom_right_x bottom_right_y bottom_right_width bottom_right_height
    read -r left_x left_y left_width left_height <<< "$(tmux display-message -p -t "$left_pane" '#{pane_left} #{pane_top} #{pane_width} #{pane_height}')"
    read -r top_right_x top_right_y top_right_width top_right_height <<< "$(tmux display-message -p -t "$top_right_pane" '#{pane_left} #{pane_top} #{pane_width} #{pane_height}')"
    read -r bottom_right_x bottom_right_y bottom_right_width bottom_right_height <<< "$(tmux display-message -p -t "$bottom_right_pane" '#{pane_left} #{pane_top} #{pane_width} #{pane_height}')"

    [ "$left_x" -eq 0 ]
    [ "$left_y" -eq 0 ]
    [ "$top_right_x" -gt "$left_x" ]
    [ "$bottom_right_x" -eq "$top_right_x" ]
    [ "$top_right_y" -eq 0 ]
    [ "$bottom_right_y" -gt "$top_right_y" ]
    [ "$left_height" -gt "$top_right_height" ]
    [ "$left_height" -gt "$bottom_right_height" ]
    [ "$top_right_width" -eq "$bottom_right_width" ]
}

# シナリオ: right と左側上下 2 分割の mixed position を適用する。
# 保証: right が全高を占有し、左側だけが上下分割される。
@test "apply-layout arranges mixed positions with right occupying full height" {
    local layout
    layout=$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$pid, "position":"right"},
        {"group_id":0, "pane_id":null, "position":"top-left"},
        {"group_id":0, "pane_id":null, "position":"bottom-left"}
    ]')

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 0 ]

    local result
    result=$(echo "$output" | grep -v '^\[apply-layout\]')
    local right_pane
    local top_left_pane
    local bottom_left_pane
    right_pane=$(echo "$result" | jq -r '.[][] | select(.position == "right") | .pane_id')
    top_left_pane=$(echo "$result" | jq -r '.[][] | select(.position == "top-left") | .pane_id')
    bottom_left_pane=$(echo "$result" | jq -r '.[][] | select(.position == "bottom-left") | .pane_id')

    local right_x right_y right_width right_height
    local top_left_x top_left_y top_left_width top_left_height
    local bottom_left_x bottom_left_y bottom_left_width bottom_left_height
    read -r right_x right_y right_width right_height <<< "$(tmux display-message -p -t "$right_pane" '#{pane_left} #{pane_top} #{pane_width} #{pane_height}')"
    read -r top_left_x top_left_y top_left_width top_left_height <<< "$(tmux display-message -p -t "$top_left_pane" '#{pane_left} #{pane_top} #{pane_width} #{pane_height}')"
    read -r bottom_left_x bottom_left_y bottom_left_width bottom_left_height <<< "$(tmux display-message -p -t "$bottom_left_pane" '#{pane_left} #{pane_top} #{pane_width} #{pane_height}')"

    [ "$right_y" -eq 0 ]
    [ "$right_x" -gt "$top_left_x" ]
    [ "$top_left_x" -eq "$bottom_left_x" ]
    [ "$bottom_left_y" -gt "$top_left_y" ]
    [ "$right_height" -gt "$top_left_height" ]
    [ "$right_height" -gt "$bottom_left_height" ]
    [ "$top_left_width" -eq "$bottom_left_width" ]
}

# シナリオ: 既存の複数 agent pane を新規 window 作成を伴って再配置する。
# 保証: new-window の ghost pane だけが整理され、agent pane は削除されない。
@test "apply-layout does not kill agent panes when creating new windows" {
    # Simulate team-start scenario: 4 agent panes exist, move 2 to a new window
    # This tests the ghost pane issue: new-window creates a default pane that
    # must be cleaned up without killing the agent panes
    tmux split-window -t "${TEST_SESSION}"
    tmux split-window -t "${TEST_SESSION}"
    tmux split-window -t "${TEST_SESSION}"

    local all_panes
    all_panes=$(tmux list-panes -t "${TEST_SESSION}" -F '#{pane_id}')
    local pane1 pane2 pane3 pane4
    pane1=$(echo "$all_panes" | sed -n '1p')
    pane2=$(echo "$all_panes" | sed -n '2p')
    pane3=$(echo "$all_panes" | sed -n '3p')
    pane4=$(echo "$all_panes" | sed -n '4p')

    # pane1, pane2 stay in window 0; pane3, pane4 move to new window (group 1)
    local layout
    layout=$(jq -n --arg p1 "$pane1" --arg p2 "$pane2" --arg p3 "$pane3" --arg p4 "$pane4" '[
        {"group_id":0, "pane_id":$p1, "position":"top"},
        {"group_id":0, "pane_id":$p2, "position":"bottom"},
        {"group_id":1, "pane_id":$p3, "position":"top"},
        {"group_id":1, "pane_id":$p4, "position":"bottom"}
    ]')

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 0 ]

    # All 4 original panes must still exist
    local remaining_panes
    remaining_panes=$(tmux list-panes -a -t "${TEST_SESSION}" -F '#{pane_id}')
    [[ "$remaining_panes" == *"$pane1"* ]]
    [[ "$remaining_panes" == *"$pane2"* ]]
    [[ "$remaining_panes" == *"$pane3"* ]]
    [[ "$remaining_panes" == *"$pane4"* ]]

    # Window 1 should have exactly 2 panes (not 3 with ghost)
    local second_window
    second_window=$(tmux list-windows -t "${TEST_SESSION}" -F '#{window_id}' | sed -n '2p')
    local pane_count
    pane_count=$(tmux list-panes -t "${TEST_SESSION}:${second_window}" | wc -l)
    [ "$pane_count" -eq 2 ]
}

# シナリオ: whole position の単一ペインレイアウトを適用する。
# 保証: 結果 JSON で対象ペインの position が whole として返る。
@test "apply-layout handles whole position" {
    # position: "whole" → ウィンドウ全体
    local layout
    layout=$(jq -n --arg pid "$INITIAL_PANE" '[
        {"group_id":0, "pane_id":$pid, "position":"whole"}
    ]')

    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 0 ]

    # 出力JSONを検証: 1つのペインで position が "whole"
    local result
    result=$(echo "$output" | grep -v '^\[apply-layout\]')
    local position
    position=$(echo "$result" | jq -r '.[][] | .position')
    [ "$position" = "whole" ]

    # ウィンドウ内のペインが1つであること
    local pane_count
    pane_count=$(tmux list-panes -t "${TEST_SESSION}:${INITIAL_WINDOW}" | wc -l)
    [ "$pane_count" -eq 1 ]
}
