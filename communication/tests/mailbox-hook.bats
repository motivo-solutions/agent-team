#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
INSTALL="${SCRIPT_DIR}/install.sh"

# mailbox-hook の unit テスト用に install 済みの一時プロジェクトを作る。
setup() {
    TEST_PROJECT_DIR=$(mktemp -d)
    export TEST_PROJECT_DIR
    mkdir -p "${TEST_PROJECT_DIR}/.git"
    bash "${INSTALL}" --project-dir "${TEST_PROJECT_DIR}" --default-member alpha

    mkdir -p "${TEST_PROJECT_DIR}/bin"
    cat > "${TEST_PROJECT_DIR}/bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "display-message" ]] && [[ "$2" == "-p" ]] && [[ "$3" == "#{session_name}" ]]; then
  printf 'test-session\n'
  exit 0
fi
exit 1
EOF
    chmod +x "${TEST_PROJECT_DIR}/bin/tmux"
    export PATH="${TEST_PROJECT_DIR}/bin:${PATH}"
}

# mailbox-hook テスト後に一時プロジェクトを破棄する。
teardown() {
    rm -rf "${TEST_PROJECT_DIR}" 2>/dev/null || true
}

# シナリオ: Claude の hook が Mailbox prompt を検知して返信 state を保存し、Stop で sender に返信する。
# 保証: AI_TEAM_MEMBER が無い場合は default member 扱いで outbox に response メッセージが生成される。
@test "claude mailbox hook relays last assistant message back to sender" {
    cd "${TEST_PROJECT_DIR}"

    run bash .ai-team/scripts/mailbox-hook.sh record-prompt --default-member alpha <<'EOF'
{"prompt":"[Mailbox]\nFrom: bravo\nType: request\n\nPlease review the patch."}
EOF
    [ "$status" -eq 0 ]
    [ -f "${TEST_PROJECT_DIR}/.ai-team/test-session/hook-state/alpha.json" ]

    run bash .ai-team/scripts/mailbox-hook.sh flush-reply --default-member alpha <<'EOF'
{"last_assistant_message":"レビューしました。問題ありません。"}
EOF
    [ "$status" -eq 0 ]

    run bash -lc "find '${TEST_PROJECT_DIR}/.ai-team/test-session/mailbox/alpha/outbox' -maxdepth 1 -name '*.md' | sort"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    message_file="$(printf '%s\n' "$output" | head -1)"
    grep -Fq 'from: alpha' "$message_file"
    grep -Fq 'to: bravo' "$message_file"
    grep -Fq 'type: response' "$message_file"
    grep -Fq 'レビューしました。問題ありません。' "$message_file"
}

# シナリオ: Codex teammate の Stop hook で last_assistant_message が null のとき定型文を返信する。
# 保証: 完了通知として「完了した。」が outbox に書き込まれる。
@test "codex mailbox hook falls back to completion message when assistant output is null" {
    cd "${TEST_PROJECT_DIR}"

    run env AI_TEAM_MEMBER=charlie bash .ai-team/scripts/mailbox-hook.sh record-prompt <<'EOF'
{"prompt":"[Mailbox]\nFrom: alpha\nType: question\n\nStatus?"}
EOF
    [ "$status" -eq 0 ]
    [ -f "${TEST_PROJECT_DIR}/.ai-team/test-session/hook-state/charlie.json" ]

    run env AI_TEAM_MEMBER=charlie bash .ai-team/scripts/mailbox-hook.sh flush-reply <<'EOF'
{"last_assistant_message":null}
EOF
    [ "$status" -eq 0 ]

    run bash -lc "find '${TEST_PROJECT_DIR}/.ai-team/test-session/mailbox/charlie/outbox' -maxdepth 1 -name '*.md' | sort"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    message_file="$(printf '%s\n' "$output" | head -1)"
    grep -Fq 'from: charlie' "$message_file"
    grep -Fq 'to: alpha' "$message_file"
    grep -Fq '完了した。' "$message_file"
}
