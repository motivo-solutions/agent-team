#!/usr/bin/env bats

setup() {
    export PROJECT_DIR="$(mktemp -d)"
    export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
    bash "$SCRIPT_DIR/install.sh" --project-dir "$PROJECT_DIR"
}

teardown() {
    rm -rf "$PROJECT_DIR"
}

# シナリオ: team-management をアンインストールする。
# 保証: install で配置した起動・復旧・停止 skill と runtime helper、構成 JSON が除去される。
@test "uninstall removes installed skills and runtime assets" {
    [ -e "$PROJECT_DIR/.claude/skills/team-start" ]
    [ -e "$PROJECT_DIR/.claude/skills/team-resume" ]
    [ -e "$PROJECT_DIR/.claude/skills/team-stop" ]

    run bash "$SCRIPT_DIR/uninstall.sh" --project-dir "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [ ! -e "$PROJECT_DIR/.claude/skills/team-start" ]
    [ ! -e "$PROJECT_DIR/.claude/skills/team-resume" ]
    [ ! -e "$PROJECT_DIR/.claude/skills/team-stop" ]
    [ ! -e "$PROJECT_DIR/.ai-team/scripts/team-start-runtime.sh" ]
    [ ! -e "$PROJECT_DIR/.ai-team/scripts/team-stop-runtime.sh" ]
    [ ! -e "$PROJECT_DIR/.ai-team/agents.config.json" ]
    [ ! -e "$PROJECT_DIR/.ai-team/layouts.config.json" ]
}
