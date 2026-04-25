#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
PROJECT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
MAILBOX_INIT="${SCRIPT_DIR}/mailbox-init.sh"
MAILBOX_CLEANUP="${SCRIPT_DIR}/mailbox-cleanup.sh"

# mailbox-cleanup を検証するための tmux セッションを作る。
setup() {
    TEST_SESSION="test-mailbox-cleanup-$$"
    tmux new-session -d -s "${TEST_SESSION}" -x 200 -y 50 -c "${PROJECT_DIR}"
}

# mailbox-cleanup テスト後に生成物と tmux セッションを破棄する。
teardown() {
    rm -rf "${PROJECT_DIR}/.ai-team/${TEST_SESSION}" 2>/dev/null || true
    tmux kill-session -t "${TEST_SESSION}" 2>/dev/null || true
}

# シナリオ: 既存 Mailbox を cleanup で削除する。
# 保証: セッション配下の mailbox ディレクトリが丸ごと除去される。
@test "mailbox-cleanup removes directory" {
    # まず初期化
    tmux send-keys -t "${TEST_SESSION}" "bash ${MAILBOX_INIT} charlie" Enter
    sleep 2
    [ -d "${PROJECT_DIR}/.ai-team/${TEST_SESSION}/mailbox/charlie/inbox" ]

    # クリーンアップ
    tmux send-keys -t "${TEST_SESSION}" "bash ${MAILBOX_CLEANUP}" Enter
    sleep 2
    [ ! -d "${PROJECT_DIR}/.ai-team/${TEST_SESSION}/mailbox" ]
}

# シナリオ: Mailbox がまだ存在しない状態で cleanup を実行する。
# 保証: 失敗せず正常終了できる。
@test "mailbox-cleanup handles missing directory" {
    tmux send-keys -t "${TEST_SESSION}" "bash ${MAILBOX_CLEANUP} && echo CLEANUP_OK" Enter
    sleep 2
    local output
    output=$(tmux capture-pane -t "${TEST_SESSION}" -p)
    [[ "$output" == *"CLEANUP_OK"* ]]
}
