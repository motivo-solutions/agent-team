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

@test "apply-layout rejects invalid JSON" {
    run bash "${APPLY_LAYOUT}" "not valid json" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error"* ]] || [[ "$output" == *"Error"* ]] || [[ "$output" == *"invalid"* ]] || [[ "$output" == *"Invalid"* ]]
}

@test "apply-layout rejects top without bottom" {
    local layout='[{"group_id":0,"pane_id":null,"position":"top"}]'
    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
}

@test "apply-layout rejects top-left without top-right" {
    local layout='[{"group_id":0,"pane_id":null,"position":"top-left"}]'
    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
}

@test "apply-layout rejects left without right" {
    local layout='[{"group_id":0,"pane_id":null,"position":"left"}]'
    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
}

@test "apply-layout rejects whole with other panes" {
    local layout='[
        {"group_id":0,"pane_id":null,"position":"whole"},
        {"group_id":0,"pane_id":null,"position":"top"}
    ]'
    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
}

@test "apply-layout rejects conflicting positions" {
    # top と top-right は同じ top-right 領域を占有するため矛盾する。
    local layout='[
        {"group_id":0,"pane_id":null,"position":"top"},
        {"group_id":0,"pane_id":null,"position":"top-right"}
    ]'
    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
}

@test "apply-layout rejects mixed positions that overlap" {
    local layout='[
        {"group_id":0,"pane_id":null,"position":"left"},
        {"group_id":0,"pane_id":null,"position":"bottom-left"},
        {"group_id":0,"pane_id":null,"position":"top-right"}
    ]'
    run bash "${APPLY_LAYOUT}" "$layout" "${TEST_SESSION}"
    [ "$status" -eq 1 ]
}

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
}

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
