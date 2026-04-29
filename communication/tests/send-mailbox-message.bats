#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
INSTALL="${SCRIPT_DIR}/install.sh"

# send_mailbox_message テストごとに install 済みの一時プロジェクトを用意する。
setup() {
    TEST_PROJECT_DIR=$(mktemp -d)
    export TEST_PROJECT_DIR
    mkdir -p "${TEST_PROJECT_DIR}/.git"
    bash "${INSTALL}" --project-dir "${TEST_PROJECT_DIR}"

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

# send_mailbox_message テスト後に一時プロジェクトを破棄する。
teardown() {
    rm -rf "${TEST_PROJECT_DIR}" 2>/dev/null || true
}

# シナリオ: 通常の proactive 送信は state file が無いとき成功する。
# 保証: outbox に Markdown メッセージが書き出され、終了コードが 0 になる。
@test "send succeeds when no pending Mailbox reply state exists" {
    cd "${TEST_PROJECT_DIR}"

    run bash .ai-team/scripts/send_mailbox_message.sh \
        --member alpha \
        --to bravo \
        --type request \
        --message "新規依頼です。"
    [ "$status" -eq 0 ]

    run bash -lc "find '${TEST_PROJECT_DIR}/.ai-team/test-session/mailbox/alpha/outbox' -maxdepth 1 -name '*.md' | sort"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# シナリオ: 同一 member に pending reply state が残っている間の手動送信は誤起動として拒否する。
# 保証: 終了コードが 1 になり、outbox に新規メッセージが書き出されない。
@test "send is blocked when a pending Mailbox reply state exists for the same member" {
    cd "${TEST_PROJECT_DIR}"

    state_dir="${TEST_PROJECT_DIR}/.ai-team/test-session/hook-state"
    mkdir -p "$state_dir"
    cat > "${state_dir}/alpha.json" <<'EOF'
{"member":"alpha","sender":"bravo","reply_type":"response"}
EOF

    run bash .ai-team/scripts/send_mailbox_message.sh \
        --member alpha \
        --to charlie \
        --type request \
        --message "誤起動の手動送信。"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pending"* ]]

    [ ! -d "${TEST_PROJECT_DIR}/.ai-team/test-session/mailbox/alpha/outbox" ] || {
        run bash -lc "find '${TEST_PROJECT_DIR}/.ai-team/test-session/mailbox/alpha/outbox' -maxdepth 1 -name '*.md'"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    }
}

# シナリオ: hook 自身が返信を配送する場合は --internal-from-hook でガードをバイパスする。
# 保証: state file が存在しても送信が成功し、outbox にメッセージが書き出される。
@test "send bypasses the guard when --internal-from-hook is provided" {
    cd "${TEST_PROJECT_DIR}"

    state_dir="${TEST_PROJECT_DIR}/.ai-team/test-session/hook-state"
    mkdir -p "$state_dir"
    cat > "${state_dir}/alpha.json" <<'EOF'
{"member":"alpha","sender":"bravo","reply_type":"response"}
EOF

    run bash .ai-team/scripts/send_mailbox_message.sh \
        --internal-from-hook \
        --member alpha \
        --to bravo \
        --type response \
        --message "hook 経由の自動返信。"
    [ "$status" -eq 0 ]

    run bash -lc "find '${TEST_PROJECT_DIR}/.ai-team/test-session/mailbox/alpha/outbox' -maxdepth 1 -name '*.md' | sort"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# シナリオ: 別 member の pending reply state は当該 member の手動送信を妨げない。
# 保証: alpha の state があっても charlie からの送信は成功する。
@test "send is not blocked by a pending reply state belonging to another member" {
    cd "${TEST_PROJECT_DIR}"

    state_dir="${TEST_PROJECT_DIR}/.ai-team/test-session/hook-state"
    mkdir -p "$state_dir"
    cat > "${state_dir}/alpha.json" <<'EOF'
{"member":"alpha","sender":"bravo","reply_type":"response"}
EOF

    run bash .ai-team/scripts/send_mailbox_message.sh \
        --member charlie \
        --to alpha \
        --type request \
        --message "別 member からの送信。"
    [ "$status" -eq 0 ]
}
