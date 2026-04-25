#!/usr/bin/env bats

setup() {
    export PROJECT_DIR="$(mktemp -d)"
    export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
    bash "$SCRIPT_DIR/install.sh" --project-dir "$PROJECT_DIR"
}

teardown() {
    rm -rf "$PROJECT_DIR"
}

# シナリオ: team-management をインストールする。
# 保証: runtime helper と構成 JSON が配置され、起動・復旧 skill はそれぞれ専用の入口を参照する。
@test "install places runtime scripts and external configuration files" {
    start_skill_file="$PROJECT_DIR/.claude/skills/team-start/SKILL.md"
    resume_skill_file="$PROJECT_DIR/.claude/skills/team-resume/SKILL.md"
    [ -f "$PROJECT_DIR/.ai-team/scripts/team-start-runtime.sh" ]
    [ -f "$PROJECT_DIR/.ai-team/scripts/team-stop-runtime.sh" ]
    [ ! -e "$PROJECT_DIR/.claude/scripts/team-start-runtime.sh" ]
    [ ! -e "$PROJECT_DIR/.claude/scripts/team-stop-runtime.sh" ]
    [ -f "$PROJECT_DIR/.ai-team/agents.config.json" ]
    [ -f "$PROJECT_DIR/.ai-team/layouts.config.json" ]
    [ ! -e "$PROJECT_DIR/.ai-team/team-management" ]
    [ ! -e "$PROJECT_DIR/.claude/team-management/agents.config.json" ]
    [ ! -e "$PROJECT_DIR/.claude/team-management/layouts.config.json" ]
    [ -f "$start_skill_file" ]
    [ -f "$resume_skill_file" ]

    grep -Fq '.ai-team/scripts/team-start-runtime.sh' "$start_skill_file"
    grep -Fq '.ai-team/agents.config.json' "$start_skill_file"
    grep -Fq '.ai-team/layouts.config.json' "$start_skill_file"
    grep -Fq 'The runtime script must treat the agent composition and layout as external inputs.' "$start_skill_file"
    ! grep -Fq -- '--resume' "$start_skill_file"

    grep -Fq '.ai-team/scripts/team-start-runtime.sh --resume' "$resume_skill_file"
    grep -Fq '.ai-team/agents.config.json' "$resume_skill_file"
    ! grep -Fq 'tmux rename-session' "$resume_skill_file"
}

# シナリオ: team-management 単体で配布する default config を確認する。
# 保証: default config は特定のチーム構成（alice/yuuka/kei/yuzu）に依存せず、
#       汎用的な leader / teammate プレースホルダで記述されており、
#       roles-workflow など上位モジュールの具体メンバー名を含まない。
@test "default configs are generic and free of roles-workflow member names" {
    agents_file="$PROJECT_DIR/.ai-team/agents.config.json"
    layouts_file="$PROJECT_DIR/.ai-team/layouts.config.json"

    # roles-workflow 固有のメンバー名が default config に漏れていない
    for name in alice yuuka kei yuzu; do
        ! grep -Fq "\"$name\"" "$agents_file"
        ! grep -Fq "\"$name\"" "$layouts_file"
    done

    # 汎用的な leader + teammate 構造になっている
    run jq -e '.members | length >= 2' "$agents_file"
    [ "$status" -eq 0 ]
    run jq -e '[.members[] | select(.leader == true)] | length == 1' "$agents_file"
    [ "$status" -eq 0 ]
    run jq -e '.members[] | select(.leader == true) | .member == "leader"' "$agents_file"
    [ "$status" -eq 0 ]
    run jq -e '[.members[] | select(.leader != true) | .member] | all(startswith("teammate"))' "$agents_file"
    [ "$status" -eq 0 ]

    # launcher.prompt_path は存在するが、roles-workflow の具体ファイル名を持たない
    run jq -e '[.members[] | select(.launcher) | .launcher.prompt_path] | all(contains("teammate"))' "$agents_file"
    [ "$status" -eq 0 ]

    # layout も同様に汎用メンバー名で構成されている
    agents_members="$(jq -r '[.members[].member] | sort | join(",")' "$agents_file")"
    layout_members="$(jq -r '[.[].member] | sort | join(",")' "$layouts_file")"
    [ "$agents_members" = "$layout_members" ]
}
