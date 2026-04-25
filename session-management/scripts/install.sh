#!/usr/bin/env bash
set -euo pipefail

# session-management モジュールのインストールスクリプト。
# 公開スクリプト、共通ヘルパー、SessionStart hook を配置する。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_DIR="."

while [ $# -gt 0 ]; do
    case "$1" in
        --project-dir)
            PROJECT_DIR="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

PROJECT_DIR="$(cd "${PROJECT_DIR}" && pwd)"

echo "[session-management] Installing to ${PROJECT_DIR}" >&2

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

mkdir -p "${PROJECT_DIR}/.ai-team/scripts"
cp "${MODULE_DIR}/scripts/start-agents.sh" "${PROJECT_DIR}/.ai-team/scripts/start-agents.sh"
cp "${MODULE_DIR}/scripts/resume-agents.sh" "${PROJECT_DIR}/.ai-team/scripts/resume-agents.sh"
cp "${MODULE_DIR}/scripts/session-management-common.sh" "${PROJECT_DIR}/.ai-team/scripts/session-management-common.sh"
cp "${MODULE_DIR}/scripts/record-agent-session-id.sh" "${PROJECT_DIR}/.ai-team/scripts/record-agent-session-id.sh"
chmod +x "${PROJECT_DIR}/.ai-team/scripts/start-agents.sh"
chmod +x "${PROJECT_DIR}/.ai-team/scripts/resume-agents.sh"
chmod +x "${PROJECT_DIR}/.ai-team/scripts/session-management-common.sh"
chmod +x "${PROJECT_DIR}/.ai-team/scripts/record-agent-session-id.sh"

CLAUDE_SETTINGS_FILE="${PROJECT_DIR}/.claude/settings.json"
mkdir -p "${PROJECT_DIR}/.claude"
if [[ ! -f "${CLAUDE_SETTINGS_FILE}" ]]; then
    echo '{}' > "${CLAUDE_SETTINGS_FILE}"
fi

CLAUDE_RECORD_SESSION_ID_COMMAND="bash .ai-team/scripts/record-agent-session-id.sh --cli claude"
CLAUDE_RECORD_SESSION_ID_HOOK="{\"matcher\":\"startup|resume\",\"hooks\":[{\"type\":\"command\",\"command\":\"${CLAUDE_RECORD_SESSION_ID_COMMAND}\"}],\"description\":\"Persist Claude session ids for resume\"}"
HAS_CLAUDE_RECORD_SESSION_ID=$(jq -r --arg command "${CLAUDE_RECORD_SESSION_ID_COMMAND}" '.hooks.SessionStart[]?.hooks[]? | select(.command == $command) // empty' "${CLAUDE_SETTINGS_FILE}" 2>/dev/null || echo "")
if [[ -z "${HAS_CLAUDE_RECORD_SESSION_ID}" ]]; then
    jq --argjson hook "${CLAUDE_RECORD_SESSION_ID_HOOK}" '.hooks.SessionStart = ((.hooks.SessionStart // []) + [$hook])' "${CLAUDE_SETTINGS_FILE}" > "${CLAUDE_SETTINGS_FILE}.tmp"
    mv "${CLAUDE_SETTINGS_FILE}.tmp" "${CLAUDE_SETTINGS_FILE}"
fi

CODEX_HOOKS_FILE="${PROJECT_DIR}/.codex/hooks.json"
if [[ ! -f "${CODEX_HOOKS_FILE}" ]]; then
    echo '{"hooks":{}}' > "${CODEX_HOOKS_FILE}"
fi

HAS_CODEX_RECORD_SESSION_ID=$(jq -r '.hooks.SessionStart[]?.hooks[]? | select(.command == "bash .ai-team/scripts/record-agent-session-id.sh --cli codex") // empty' "${CODEX_HOOKS_FILE}" 2>/dev/null || echo "")
if [[ -z "${HAS_CODEX_RECORD_SESSION_ID}" ]]; then
    jq '.hooks = (.hooks // {})' "${CODEX_HOOKS_FILE}" > "${CODEX_HOOKS_FILE}.tmp"
    mv "${CODEX_HOOKS_FILE}.tmp" "${CODEX_HOOKS_FILE}"
    jq --argjson hook '{"matcher":"startup|resume","hooks":[{"type":"command","command":"bash .ai-team/scripts/record-agent-session-id.sh --cli codex"}]}' '.hooks.SessionStart = ((.hooks.SessionStart // []) + [$hook])' "${CODEX_HOOKS_FILE}" > "${CODEX_HOOKS_FILE}.tmp"
    mv "${CODEX_HOOKS_FILE}.tmp" "${CODEX_HOOKS_FILE}"
fi

echo "[session-management] Installation complete" >&2
