#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
INSTALL="${SCRIPT_DIR}/install.sh"
UNINSTALL="${SCRIPT_DIR}/uninstall.sh"

# uninstall テスト用に install 済みの一時プロジェクトを作る。
setup() {
    TEST_PROJECT_DIR=$(mktemp -d)
    bash "${INSTALL}" --project-dir "${TEST_PROJECT_DIR}" --default-member leader
}

# uninstall テスト後に一時プロジェクトを破棄する。
teardown() {
    rm -rf "${TEST_PROJECT_DIR}" 2>/dev/null || true
}

# シナリオ: uninstall が communication モジュールの配置物を除去する。
# 保証: スクリプト、skill、hook 設定、Codex hooks の feature 設定が残らない。
@test "uninstall removes mailbox scripts and send helpers" {
    bash "${UNINSTALL}" --project-dir "${TEST_PROJECT_DIR}"
    [ ! -f "${TEST_PROJECT_DIR}/.ai-team/scripts/mailbox-init.sh" ]
    [ ! -f "${TEST_PROJECT_DIR}/.ai-team/scripts/mailbox-cleanup.sh" ]
    [ ! -f "${TEST_PROJECT_DIR}/.ai-team/scripts/mailbox-hook.sh" ]
    [ ! -f "${TEST_PROJECT_DIR}/.ai-team/scripts/send_mailbox_message.sh" ]
    [ ! -d "${TEST_PROJECT_DIR}/.agents/skills/mailbox-send" ]
    [ ! -d "${TEST_PROJECT_DIR}/.claude/skills/mailbox-send" ]
    [ ! -d "${TEST_PROJECT_DIR}/.agents/skills/mailbox-compose" ]
    [ ! -d "${TEST_PROJECT_DIR}/.claude/skills/mailbox-compose" ]
    config_contents="$(cat "${TEST_PROJECT_DIR}/.codex/config.toml")"
    [[ "${config_contents}" != *"codex_hooks = true"* ]]
    record=$(jq -r '.hooks.UserPromptSubmit[]?.hooks[]? | select(.command | startswith("bash .ai-team/scripts/mailbox-hook.sh record-prompt")) | .command' "${TEST_PROJECT_DIR}/.claude/settings.json" 2>/dev/null || echo "")
    [ -z "$record" ]
    stop=$(jq -r '.hooks.Stop[]?.hooks[]? | select(.command | startswith("bash .ai-team/scripts/mailbox-hook.sh flush-reply")) | .command' "${TEST_PROJECT_DIR}/.claude/settings.json" 2>/dev/null || echo "")
    [ -z "$stop" ]
    codex_record=$(jq -r '.hooks.UserPromptSubmit[]?.hooks[]? | select(.command == "bash .ai-team/scripts/mailbox-hook.sh record-prompt") | .command' "${TEST_PROJECT_DIR}/.codex/hooks.json" 2>/dev/null || echo "")
    [ -z "$codex_record" ]
    codex_stop=$(jq -r '.hooks.Stop[]?.hooks[]? | select(.command == "bash .ai-team/scripts/mailbox-hook.sh flush-reply") | .command' "${TEST_PROJECT_DIR}/.codex/hooks.json" 2>/dev/null || echo "")
    [ -z "$codex_stop" ]
}
