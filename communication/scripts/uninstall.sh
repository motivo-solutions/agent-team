#!/usr/bin/env bash
set -euo pipefail

# 通信基盤モジュールのアンインストールスクリプト
# install.sh で配置したファイルを除去する

# デフォルトの対象プロジェクト
PROJECT_DIR="."

# 引数解析
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

echo "[communication] Uninstalling from ${PROJECT_DIR}" >&2

# --- 配置したファイルを除去 ---
rm -f "${PROJECT_DIR}/.ai-team/scripts/mailbox-init.sh"
rm -f "${PROJECT_DIR}/.ai-team/scripts/mailbox-cleanup.sh"
rm -f "${PROJECT_DIR}/.ai-team/scripts/mailbox-hook.sh"
rm -f "${PROJECT_DIR}/.ai-team/scripts/send_mailbox_message.sh"
rm -rf "${PROJECT_DIR}/.agents/skills/mailbox-compose"
rm -rf "${PROJECT_DIR}/.claude/skills/mailbox-compose"

CODEX_CONFIG_FILE="${PROJECT_DIR}/.codex/config.toml"
if [[ -f "${CODEX_CONFIG_FILE}" ]]; then
    awk '
        BEGIN { in_features = 0; skip_codex_hooks = 0 }
        /^\[features\]$/ {
            in_features = 1
            print
            next
        }
        /^\[/ {
            in_features = 0
        }
        in_features == 1 && /^codex_hooks *= */ {
            next
        }
        { print }
    ' "${CODEX_CONFIG_FILE}" > "${CODEX_CONFIG_FILE}.tmp"
    mv "${CODEX_CONFIG_FILE}.tmp" "${CODEX_CONFIG_FILE}"
fi

CLAUDE_SETTINGS_FILE="${PROJECT_DIR}/.claude/settings.json"
if [[ -f "${CLAUDE_SETTINGS_FILE}" ]]; then
    jq '
        if .hooks then
            .hooks.UserPromptSubmit |= ((. // []) | map(select(.hooks | any(.command | startswith("bash .ai-team/scripts/mailbox-hook.sh record-prompt")) | not)))
            | .hooks.Stop |= ((. // []) | map(select(.hooks | any(.command | startswith("bash .ai-team/scripts/mailbox-hook.sh flush-reply")) | not)))
            | if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end
            | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
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
            .hooks.UserPromptSubmit |= ((. // []) | map(select(.hooks | any(.command == "bash .ai-team/scripts/mailbox-hook.sh record-prompt") | not)))
            | .hooks.Stop |= ((. // []) | map(select(.hooks | any(.command == "bash .ai-team/scripts/mailbox-hook.sh flush-reply") | not)))
            | if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end
            | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
            | if (.hooks | length) == 0 then del(.hooks) else . end
        else
            .
        end
    ' "${CODEX_HOOKS_FILE}" > "${CODEX_HOOKS_FILE}.tmp"
    mv "${CODEX_HOOKS_FILE}.tmp" "${CODEX_HOOKS_FILE}"
fi

echo "[communication] Removed communication files" >&2

echo "[communication] Uninstallation complete" >&2
