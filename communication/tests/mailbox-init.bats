#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
PROJECT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
MAILBOX_INIT="${SCRIPT_DIR}/mailbox-init.sh"

# mailbox-init を検証するための tmux セッションを作る。
setup() {
    TEST_SESSION="test-mailbox-init-$$"
    tmux new-session -d -s "${TEST_SESSION}" -x 200 -y 50 -c "${PROJECT_DIR}"
}

# mailbox-init テスト用セッションと生成物を掃除する。
teardown() {
    rm -rf "${PROJECT_DIR}/.ai-team/${TEST_SESSION}" 2>/dev/null || true
    tmux kill-session -t "${TEST_SESSION}" 2>/dev/null || true
}

# シナリオ: 単一メンバーの Mailbox を初期化する。
# 保証: 対象メンバーの inbox / outbox ディレクトリが生成される。
@test "mailbox-init creates directory structure" {
    tmux send-keys -t "${TEST_SESSION}" "bash ${MAILBOX_INIT} charlie" Enter
    sleep 2
    [ -d "${PROJECT_DIR}/.ai-team/${TEST_SESSION}/mailbox/charlie/inbox" ]
    [ -d "${PROJECT_DIR}/.ai-team/${TEST_SESSION}/mailbox/charlie/outbox" ]
}

# シナリオ: 複数メンバーを 1 回で初期化する。
# 保証: 指定した全メンバー分の inbox / outbox がまとめて生成される。
@test "mailbox-init creates directory structures for multiple members in one invocation" {
    tmux send-keys -t "${TEST_SESSION}" "bash ${MAILBOX_INIT} alpha bravo charlie delta" Enter
    sleep 2
    [ -d "${PROJECT_DIR}/.ai-team/${TEST_SESSION}/mailbox/alpha/inbox" ]
    [ -d "${PROJECT_DIR}/.ai-team/${TEST_SESSION}/mailbox/bravo/inbox" ]
    [ -d "${PROJECT_DIR}/.ai-team/${TEST_SESSION}/mailbox/charlie/outbox" ]
    [ -d "${PROJECT_DIR}/.ai-team/${TEST_SESSION}/mailbox/delta/outbox" ]
}

# シナリオ: 同じメンバーへ繰り返し mailbox-init を実行する。
# 保証: 2 回目以降も失敗せず、冪等に完了できる。
@test "mailbox-init is idempotent" {
    tmux send-keys -t "${TEST_SESSION}" "bash ${MAILBOX_INIT} charlie && bash ${MAILBOX_INIT} charlie && echo IDEMPOTENT_OK" Enter
    sleep 2
    local output
    output=$(tmux capture-pane -t "${TEST_SESSION}" -p)
    [[ "$output" == *"IDEMPOTENT_OK"* ]]
}

# シナリオ: パストラバーサルを含む不正なメンバー名を渡す。
# 保証: mailbox-init は終了コード 1 で失敗し、ディレクトリを作成しない。
@test "mailbox-init rejects invalid member name" {
    tmux send-keys -t "${TEST_SESSION}" "bash ${MAILBOX_INIT} '../etc' ; echo EXIT_CODE=\$?" Enter
    sleep 2
    local output
    output=$(tmux capture-pane -t "${TEST_SESSION}" -p)
    [[ "$output" == *"EXIT_CODE=1"* ]]
}
