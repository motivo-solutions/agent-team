#!/usr/bin/env bats

setup() {
    export PROJECT_DIR="$(mktemp -d)"
    export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
    bash "$SCRIPT_DIR/install.sh" --project-dir "$PROJECT_DIR"
}

teardown() {
    rm -rf "$PROJECT_DIR"
}

# シナリオ: session-management をアンインストールする。
# 保証: 配置したスクリプトと SessionStart hook 設定が除去され、共有 feature 設定は壊さない。
@test "uninstall removes installed session-management scripts and hooks" {
    bash "$SCRIPT_DIR/uninstall.sh" --project-dir "$PROJECT_DIR"
    [ ! -f "$PROJECT_DIR/.ai-team/scripts/start-agents.sh" ]
    [ ! -f "$PROJECT_DIR/.ai-team/scripts/resume-agents.sh" ]
    [ ! -f "$PROJECT_DIR/.ai-team/scripts/session-management-common.sh" ]
    [ ! -f "$PROJECT_DIR/.ai-team/scripts/record-agent-session-id.sh" ]

    settings_hook=$(jq -r '
        .hooks.SessionStart[]?.hooks[]?
        | select(.command == "bash .ai-team/scripts/record-agent-session-id.sh --cli claude")
        | .command
    ' "$PROJECT_DIR/.claude/settings.json" 2>/dev/null || echo "")
    [ -z "$settings_hook" ]

    codex_hook=$(jq -r '
        .hooks.SessionStart[]?.hooks[]?
        | select(.command == "bash .ai-team/scripts/record-agent-session-id.sh --cli codex")
        | .command
    ' "$PROJECT_DIR/.codex/hooks.json" 2>/dev/null || echo "")
    [ -z "$codex_hook" ]
    grep -Fq 'codex_hooks = true' "$PROJECT_DIR/.codex/config.toml"
}
