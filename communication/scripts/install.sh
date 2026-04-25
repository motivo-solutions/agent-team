#!/usr/bin/env bash
set -euo pipefail

# 通信基盤モジュールのインストールスクリプト
# Mailbox 管理スクリプトと送信ヘルパースクリプトを配置する

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# デフォルトの対象プロジェクト
PROJECT_DIR="."
DEFAULT_MEMBER=""

# 引数解析
while [ $# -gt 0 ]; do
    case "$1" in
        --project-dir)
            PROJECT_DIR="$2"
            shift 2
            ;;
        --default-member)
            DEFAULT_MEMBER="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

echo "[communication] Installing to ${PROJECT_DIR}" >&2

# --- Codex hooks feature flag を設定 ---
mkdir -p "${PROJECT_DIR}/.codex"
CODEX_CONFIG_FILE="${PROJECT_DIR}/.codex/config.toml"
if [[ ! -f "${CODEX_CONFIG_FILE}" ]]; then
    cat > "${CODEX_CONFIG_FILE}" <<'EOF'
[features]
codex_hooks = true
EOF
elif grep -Eq '^codex_hooks *= *true$' "${CODEX_CONFIG_FILE}"; then
    :
elif grep -Eq '^codex_hooks *= *(false|true)$' "${CODEX_CONFIG_FILE}"; then
    sed -i 's/^codex_hooks *= *.*/codex_hooks = true/' "${CODEX_CONFIG_FILE}"
elif grep -Eq '^\[features\]$' "${CODEX_CONFIG_FILE}"; then
    awk '
        BEGIN { inserted = 0 }
        /^\[features\]$/ && inserted == 0 {
            print
            print "codex_hooks = true"
            inserted = 1
            next
        }
        { print }
    ' "${CODEX_CONFIG_FILE}" > "${CODEX_CONFIG_FILE}.tmp"
    mv "${CODEX_CONFIG_FILE}.tmp" "${CODEX_CONFIG_FILE}"
else
    printf '\n[features]\ncodex_hooks = true\n' >> "${CODEX_CONFIG_FILE}"
fi

# --- 手動送信用 skill を配置 ---
mkdir -p "${PROJECT_DIR}/.claude/skills/mailbox-compose"
mkdir -p "${PROJECT_DIR}/.agents/skills/mailbox-compose"
cp -r "${MODULE_DIR}/skills/claude-code/mailbox-compose/." "${PROJECT_DIR}/.claude/skills/mailbox-compose/"
cp -r "${MODULE_DIR}/skills/codex-cli/mailbox-compose/." "${PROJECT_DIR}/.agents/skills/mailbox-compose/"
echo "[communication] Placed mailbox-compose skill" >&2

# --- Mailbox 管理スクリプトを配置 ---
mkdir -p "${PROJECT_DIR}/.ai-team/scripts"
cp "${MODULE_DIR}/scripts/mailbox-init.sh" "${PROJECT_DIR}/.ai-team/scripts/mailbox-init.sh"
cp "${MODULE_DIR}/scripts/mailbox-cleanup.sh" "${PROJECT_DIR}/.ai-team/scripts/mailbox-cleanup.sh"
cp "${MODULE_DIR}/scripts/mailbox-hook.sh" "${PROJECT_DIR}/.ai-team/scripts/mailbox-hook.sh"
cp "${MODULE_DIR}/scripts/send_mailbox_message.sh" "${PROJECT_DIR}/.ai-team/scripts/send_mailbox_message.sh"
chmod +x "${PROJECT_DIR}/.ai-team/scripts/mailbox-init.sh"
chmod +x "${PROJECT_DIR}/.ai-team/scripts/mailbox-cleanup.sh"
chmod +x "${PROJECT_DIR}/.ai-team/scripts/mailbox-hook.sh"
chmod +x "${PROJECT_DIR}/.ai-team/scripts/send_mailbox_message.sh"
echo "[communication] Placed mailbox scripts" >&2

# --- Claude Code hooks を設定 ---
CLAUDE_SETTINGS_FILE="${PROJECT_DIR}/.claude/settings.json"
if [[ ! -f "${CLAUDE_SETTINGS_FILE}" ]]; then
    echo '{}' > "${CLAUDE_SETTINGS_FILE}"
fi

CLAUDE_RECORD_COMMAND="bash .ai-team/scripts/mailbox-hook.sh record-prompt"
CLAUDE_STOP_COMMAND="bash .ai-team/scripts/mailbox-hook.sh flush-reply"
if [[ -n "${DEFAULT_MEMBER}" ]]; then
    CLAUDE_RECORD_COMMAND+=" --default-member ${DEFAULT_MEMBER}"
    CLAUDE_STOP_COMMAND+=" --default-member ${DEFAULT_MEMBER}"
fi

CLAUDE_RECORD_DESC="Record Mailbox-delivered prompts for auto-reply"
CLAUDE_RECORD_HOOK="{\"hooks\":[{\"type\":\"command\",\"command\":\"${CLAUDE_RECORD_COMMAND}\"}],\"description\":\"${CLAUDE_RECORD_DESC}\"}"
HAS_CLAUDE_RECORD=$(jq -r --arg command "${CLAUDE_RECORD_COMMAND}" '.hooks.UserPromptSubmit[]?.hooks[]? | select(.command == $command) // empty' "${CLAUDE_SETTINGS_FILE}" 2>/dev/null || echo "")
if [[ -z "${HAS_CLAUDE_RECORD}" ]]; then
    jq --argjson hook "${CLAUDE_RECORD_HOOK}" '.hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [$hook])' "${CLAUDE_SETTINGS_FILE}" > "${CLAUDE_SETTINGS_FILE}.tmp"
    mv "${CLAUDE_SETTINGS_FILE}.tmp" "${CLAUDE_SETTINGS_FILE}"
fi

CLAUDE_STOP_DESC="Relay Mailbox replies after Claude finishes a turn"
CLAUDE_STOP_HOOK="{\"hooks\":[{\"type\":\"command\",\"command\":\"${CLAUDE_STOP_COMMAND}\"}],\"description\":\"${CLAUDE_STOP_DESC}\"}"
HAS_CLAUDE_STOP=$(jq -r --arg command "${CLAUDE_STOP_COMMAND}" '.hooks.Stop[]?.hooks[]? | select(.command == $command) // empty' "${CLAUDE_SETTINGS_FILE}" 2>/dev/null || echo "")
if [[ -z "${HAS_CLAUDE_STOP}" ]]; then
    jq --argjson hook "${CLAUDE_STOP_HOOK}" '.hooks.Stop = ((.hooks.Stop // []) + [$hook])' "${CLAUDE_SETTINGS_FILE}" > "${CLAUDE_SETTINGS_FILE}.tmp"
    mv "${CLAUDE_SETTINGS_FILE}.tmp" "${CLAUDE_SETTINGS_FILE}"
fi

# --- Codex hooks を設定 ---
CODEX_HOOKS_FILE="${PROJECT_DIR}/.codex/hooks.json"
if [[ ! -f "${CODEX_HOOKS_FILE}" ]]; then
    echo '{"hooks":{}}' > "${CODEX_HOOKS_FILE}"
fi

HAS_CODEX_RECORD=$(jq -r '.hooks.UserPromptSubmit[]?.hooks[]? | select(.command == "bash .ai-team/scripts/mailbox-hook.sh record-prompt") // empty' "${CODEX_HOOKS_FILE}" 2>/dev/null || echo "")
if [[ -z "${HAS_CODEX_RECORD}" ]]; then
    jq '.hooks = (.hooks // {})' "${CODEX_HOOKS_FILE}" > "${CODEX_HOOKS_FILE}.tmp"
    mv "${CODEX_HOOKS_FILE}.tmp" "${CODEX_HOOKS_FILE}"
    jq --argjson hook '{"hooks":[{"type":"command","command":"bash .ai-team/scripts/mailbox-hook.sh record-prompt"}]}' '.hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [$hook])' "${CODEX_HOOKS_FILE}" > "${CODEX_HOOKS_FILE}.tmp"
    mv "${CODEX_HOOKS_FILE}.tmp" "${CODEX_HOOKS_FILE}"
fi

HAS_CODEX_STOP=$(jq -r '.hooks.Stop[]?.hooks[]? | select(.command == "bash .ai-team/scripts/mailbox-hook.sh flush-reply") // empty' "${CODEX_HOOKS_FILE}" 2>/dev/null || echo "")
if [[ -z "${HAS_CODEX_STOP}" ]]; then
    jq '.hooks = (.hooks // {})' "${CODEX_HOOKS_FILE}" > "${CODEX_HOOKS_FILE}.tmp"
    mv "${CODEX_HOOKS_FILE}.tmp" "${CODEX_HOOKS_FILE}"
    jq --argjson hook '{"hooks":[{"type":"command","command":"bash .ai-team/scripts/mailbox-hook.sh flush-reply"}]}' '.hooks.Stop = ((.hooks.Stop // []) + [$hook])' "${CODEX_HOOKS_FILE}" > "${CODEX_HOOKS_FILE}.tmp"
    mv "${CODEX_HOOKS_FILE}.tmp" "${CODEX_HOOKS_FILE}"
fi

echo "[communication] Installation complete" >&2
