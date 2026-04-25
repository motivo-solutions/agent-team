#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
INSTALL="${SCRIPT_DIR}/install.sh"

# install テストごとに独立した一時プロジェクトを用意する。
setup() {
    TEST_PROJECT_DIR=$(mktemp -d)
}

# install テスト後に一時プロジェクトを破棄する。
teardown() {
    rm -rf "${TEST_PROJECT_DIR}" 2>/dev/null || true
}

# シナリオ: communication install が Claude / Codex の補助スクリプトを配置する。
# 保証: Mailbox 管理と送信に必要なスクリプトが両環境へ実行可能で配置される。
@test "install places mailbox management scripts in shared ai-team directory" {
    bash "${INSTALL}" --project-dir "${TEST_PROJECT_DIR}"
    [ -f "${TEST_PROJECT_DIR}/.ai-team/scripts/mailbox-init.sh" ]
    [ -f "${TEST_PROJECT_DIR}/.ai-team/scripts/mailbox-cleanup.sh" ]
    [ -f "${TEST_PROJECT_DIR}/.ai-team/scripts/mailbox-hook.sh" ]
    [ -f "${TEST_PROJECT_DIR}/.ai-team/scripts/send_mailbox_message.sh" ]
    [ -x "${TEST_PROJECT_DIR}/.ai-team/scripts/mailbox-hook.sh" ]
    [ -x "${TEST_PROJECT_DIR}/.ai-team/scripts/send_mailbox_message.sh" ]
    [ ! -e "${TEST_PROJECT_DIR}/.claude/scripts/mailbox-hook.sh" ]
    [ ! -e "${TEST_PROJECT_DIR}/.codex/scripts/hooks/mailbox-hook.sh" ]
}

# シナリオ: Codex hooks の有効化を起動引数ではなく設定ファイルで担保する。
# 保証: `.codex/config.toml` に `codex_hooks = true` が書き込まれる。
@test "install enables codex hooks in config.toml" {
    bash "${INSTALL}" --project-dir "${TEST_PROJECT_DIR}"
    [ -f "${TEST_PROJECT_DIR}/.codex/config.toml" ]
    grep -Fq '[features]' "${TEST_PROJECT_DIR}/.codex/config.toml"
    grep -Fq 'codex_hooks = true' "${TEST_PROJECT_DIR}/.codex/config.toml"
}

# シナリオ: 手動の新規 Mailbox 送信用 skill を両環境へ配置する。
# 保証: Claude / Codex の両方で mailbox-compose skill を利用でき、Codex には UI metadata も含まれる。
@test "install places mailbox-compose skill for Claude Code and Codex" {
    bash "${INSTALL}" --project-dir "${TEST_PROJECT_DIR}"
    [ -f "${TEST_PROJECT_DIR}/.claude/skills/mailbox-compose/SKILL.md" ]
    [ -f "${TEST_PROJECT_DIR}/.agents/skills/mailbox-compose/SKILL.md" ]
    [ -f "${TEST_PROJECT_DIR}/.agents/skills/mailbox-compose/agents/openai.yaml" ]
    grep -Fq 'Use this skill only when you need to send a new Mailbox message proactively.' "${TEST_PROJECT_DIR}/.claude/skills/mailbox-compose/SKILL.md"
    grep -Fq 'display_name: Mailbox Compose' "${TEST_PROJECT_DIR}/.agents/skills/mailbox-compose/agents/openai.yaml"
}

# シナリオ: install が Claude / Codex の hook 設定を登録する。
# 保証: 自動返信に必要な UserPromptSubmit / Stop hook が両環境へ書き込まれる。
@test "install configures Claude and Codex hooks for mailbox auto-reply" {
    bash "${INSTALL}" --project-dir "${TEST_PROJECT_DIR}"
    jq -e '.hooks.UserPromptSubmit[]?.hooks[]? | select(.command == "bash .ai-team/scripts/mailbox-hook.sh record-prompt")' "${TEST_PROJECT_DIR}/.claude/settings.json"
    jq -e '.hooks.Stop[]?.hooks[]? | select(.command == "bash .ai-team/scripts/mailbox-hook.sh flush-reply")' "${TEST_PROJECT_DIR}/.claude/settings.json"
    jq -e '.hooks.UserPromptSubmit[]?.hooks[]? | select(.command == "bash .ai-team/scripts/mailbox-hook.sh record-prompt")' "${TEST_PROJECT_DIR}/.codex/hooks.json"
    jq -e '.hooks.Stop[]?.hooks[]? | select(.command == "bash .ai-team/scripts/mailbox-hook.sh flush-reply")' "${TEST_PROJECT_DIR}/.codex/hooks.json"
}
