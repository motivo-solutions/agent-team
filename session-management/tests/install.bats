#!/usr/bin/env bats

setup() {
    export PROJECT_DIR="$(mktemp -d)"
    export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
    bash "$SCRIPT_DIR/install.sh" --project-dir "$PROJECT_DIR"
}

teardown() {
    rm -rf "$PROJECT_DIR"
}

# シナリオ: session-management をインストールする。
# 保証: 起動/復旧スクリプトと SessionStart hook が Claude / Codex の両環境へ配置される。
@test "install places session-management scripts and session start hooks" {
    [ -f "$PROJECT_DIR/.ai-team/scripts/start-agents.sh" ]
    [ -f "$PROJECT_DIR/.ai-team/scripts/resume-agents.sh" ]
    [ -f "$PROJECT_DIR/.ai-team/scripts/session-management-common.sh" ]
    [ -f "$PROJECT_DIR/.ai-team/scripts/record-agent-session-id.sh" ]
    [ -x "$PROJECT_DIR/.ai-team/scripts/start-agents.sh" ]
    [ -x "$PROJECT_DIR/.ai-team/scripts/resume-agents.sh" ]
    [ -x "$PROJECT_DIR/.ai-team/scripts/record-agent-session-id.sh" ]
    [ ! -e "$PROJECT_DIR/.claude/scripts/record-agent-session-id.sh" ]
    [ ! -e "$PROJECT_DIR/.codex/scripts/hooks/record-agent-session-id.sh" ]
}

# シナリオ: session-management install が SessionStart hook を登録する。
# 保証: Claude / Codex の両設定に startup|resume 用の hook が書き込まれ、Codex hooks も有効化される。
@test "install configures Claude and Codex SessionStart hooks" {
    [ -f "$PROJECT_DIR/.claude/settings.json" ]
    [ -f "$PROJECT_DIR/.codex/hooks.json" ]
    [ -f "$PROJECT_DIR/.codex/config.toml" ]

    jq -e '
        .hooks.SessionStart[]?
        | select(.matcher == "startup|resume")
        | .hooks[]?
        | select(.command == "bash .ai-team/scripts/record-agent-session-id.sh --cli claude")
    ' "$PROJECT_DIR/.claude/settings.json"

    jq -e '
        .hooks.SessionStart[]?
        | select(.matcher == "startup|resume")
        | .hooks[]?
        | select(.command == "bash .ai-team/scripts/record-agent-session-id.sh --cli codex")
    ' "$PROJECT_DIR/.codex/hooks.json"

    grep -Fq '[features]' "$PROJECT_DIR/.codex/config.toml"
    grep -Fq 'codex_hooks = true' "$PROJECT_DIR/.codex/config.toml"
}
