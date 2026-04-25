#!/usr/bin/env bash
set -euo pipefail

# session-management モジュールのアンインストールスクリプト。
# install.sh で配置した公開スクリプト、内部共通ヘルパー、SessionStart hook を除去する。

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

echo "[session-management] Uninstalling from ${PROJECT_DIR}" >&2

rm -f "${PROJECT_DIR}/.ai-team/scripts/start-agents.sh"
rm -f "${PROJECT_DIR}/.ai-team/scripts/resume-agents.sh"
rm -f "${PROJECT_DIR}/.ai-team/scripts/session-management-common.sh"
rm -f "${PROJECT_DIR}/.ai-team/scripts/record-agent-session-id.sh"

CLAUDE_SETTINGS_FILE="${PROJECT_DIR}/.claude/settings.json"
if [[ -f "${CLAUDE_SETTINGS_FILE}" ]]; then
    jq '
        if .hooks then
            .hooks.SessionStart |= ((. // []) | map(select(.hooks | any(.command == "bash .ai-team/scripts/record-agent-session-id.sh --cli claude") | not)))
            | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
            | if (.hooks | length) == 0 then del(.hooks) else . end
        else
            .
        end
    ' "${CLAUDE_SETTINGS_FILE}" > "${CLAUDE_SETTINGS_FILE}.tmp"
    mv "${CLAUDE_SETTINGS_FILE}.tmp" "${CLAUDE_SETTINGS_FILE}"
fi

CODEX_HOOKS_FILE="${PROJECT_DIR}/.codex/hooks.json"
if [[ -f "${CODEX_HOOKS_FILE}" ]]; then
    jq '
        if .hooks then
            .hooks.SessionStart |= ((. // []) | map(select(.hooks | any(.command == "bash .ai-team/scripts/record-agent-session-id.sh --cli codex") | not)))
            | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
            | if (.hooks | length) == 0 then del(.hooks) else . end
        else
            .
        end
    ' "${CODEX_HOOKS_FILE}" > "${CODEX_HOOKS_FILE}.tmp"
    mv "${CODEX_HOOKS_FILE}.tmp" "${CODEX_HOOKS_FILE}"
fi

echo "[session-management] Uninstallation complete" >&2
