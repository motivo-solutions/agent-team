#!/usr/bin/env bats

setup() {
    export PROJECT_DIR="$(mktemp -d)"
    export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
    export SESSION_MANAGEMENT_SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../../session-management/scripts" && pwd)"
    export TEST_BIN="${PROJECT_DIR}/test-bin"
    export TEST_LOG_DIR="${PROJECT_DIR}/test-logs"
    mkdir -p "$TEST_BIN" "$TEST_LOG_DIR"
    bash "$SCRIPT_DIR/install.sh" --project-dir "$PROJECT_DIR"
}

teardown() {
    rm -rf "$PROJECT_DIR"
}

prepare_tmux_stub() {
    cat > "${TEST_BIN}/tmux" <<'EOF_TMUX'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$FAKE_TMUX_LOG"

case "$1" in
    display-message)
        if [ "${2:-}" = "-p" ] && [ "${3:-}" = '#{session_name}' ]; then
            printf '%s\n' "${FAKE_TMUX_SESSION_NAME}"
            exit 0
        fi
        ;;
    list-windows)
        printf '%s\n' "${FAKE_TMUX_WINDOWS}"
        exit 0
        ;;
    send-keys)
        exit 0
        ;;
esac

echo "unexpected tmux invocation: $*" >&2
exit 1
EOF_TMUX
    chmod +x "${TEST_BIN}/tmux"

}

write_prompt_files() {
    mkdir -p "${PROJECT_DIR}/.ai-team/prompts"
    for member in leader reviewer builder observer; do
        printf '%s\n' "${member} prompt" > "${PROJECT_DIR}/.ai-team/prompts/${member}.md"
    done
}

# シナリオ: team-start-runtime にカスタムの構成 JSON とレイアウト JSON を与える。
# 保証: runtime は mailbox-init、apply-layout、pane 保存、session-management への起動委譲、bridge 起動を行う。
@test "team-start-runtime orchestrates startup and delegates agent launch to session-management" {
    prepare_tmux_stub
    write_prompt_files

    export FAKE_TMUX_LOG="${TEST_LOG_DIR}/tmux.log"
    export FAKE_TMUX_SESSION_NAME="feature-session"
    export FAKE_TMUX_WINDOWS="@0"
    export MAILBOX_INIT_LOG="${TEST_LOG_DIR}/mailbox-init.log"
    export APPLY_LAYOUT_JSON_LOG="${TEST_LOG_DIR}/apply-layout.json"
    export APPLY_LAYOUT_SESSION_LOG="${TEST_LOG_DIR}/apply-layout.session"
    export START_AGENTS_LOG="${TEST_LOG_DIR}/start-agents.log"
    export BRIDGE_ARGS_LOG="${TEST_LOG_DIR}/bridge-args.log"

    cat > "${PROJECT_DIR}/.ai-team/scripts/mailbox-init.sh" <<'EOF_MAILBOX_INIT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$MAILBOX_INIT_LOG"
EOF_MAILBOX_INIT
    chmod +x "${PROJECT_DIR}/.ai-team/scripts/mailbox-init.sh"

    cat > "${PROJECT_DIR}/.ai-team/scripts/apply-layout.sh" <<'EOF_APPLY_LAYOUT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$1" > "$APPLY_LAYOUT_JSON_LOG"
printf '%s\n' "$2" > "$APPLY_LAYOUT_SESSION_LOG"
cat <<'EOF_LAYOUT_RESULT'
{"@0":[{"position":"top-left","pane_id":"%leader"},{"position":"top-right","pane_id":"%reviewer"},{"position":"bottom-left","pane_id":"%builder"},{"position":"bottom-right","pane_id":"%observer"}]}
EOF_LAYOUT_RESULT
EOF_APPLY_LAYOUT
    chmod +x "${PROJECT_DIR}/.ai-team/scripts/apply-layout.sh"

    cat > "${PROJECT_DIR}/.ai-team/scripts/mailbox-bridge.sh" <<'EOF_BRIDGE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$BRIDGE_ARGS_LOG"
EOF_BRIDGE
    chmod +x "${PROJECT_DIR}/.ai-team/scripts/mailbox-bridge.sh"

    cat > "${PROJECT_DIR}/.ai-team/scripts/start-agents.sh" <<'EOF_START_AGENTS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" > "$START_AGENTS_LOG.agents"
printf '%s\n' "$2" > "$START_AGENTS_LOG.panes"
printf '%s\n' '{"started":["reviewer","builder"],"resumed":[],"kept":[],"skipped":["leader","observer"],"failed":[]}'
EOF_START_AGENTS
    chmod +x "${PROJECT_DIR}/.ai-team/scripts/start-agents.sh"

    mkdir -p "${PROJECT_DIR}/custom-config"
    cat > "${PROJECT_DIR}/custom-config/agents.json" <<'EOF_AGENTS'
{
  "members": [
    {
      "member": "leader",
      "leader": true,
      "mailbox": true,
      "bridge": true
    },
    {
      "member": "reviewer",
      "leader": false,
      "mailbox": true,
      "bridge": false,
      "launcher": {
        "cli": "claude",
        "model": "claude-sonnet-4-6",
        "think_mode": "high",
        "permission_mode": "acceptEdits"
      }
    },
    {
      "member": "builder",
      "leader": false,
      "mailbox": true,
      "bridge": true,
      "launcher": {
        "cli": "codex",
        "model": "gpt-5.4",
        "think_mode": "xhigh",
        "sandbox": "read-only",
        "approval_policy": "never"
      }
    },
    {
      "member": "observer",
      "leader": false,
      "mailbox": false,
      "bridge": false
    }
  ]
}
EOF_AGENTS

    cat > "${PROJECT_DIR}/custom-config/layout.json" <<'EOF_LAYOUT'
[
  { "member": "leader",   "group_id": 0, "position": "top-left" },
  { "member": "reviewer", "group_id": 0, "position": "top-right" },
  { "member": "builder",  "group_id": 0, "position": "bottom-left" },
  { "member": "observer", "group_id": 0, "position": "bottom-right" }
]
EOF_LAYOUT

    run bash -lc 'cd "$PROJECT_DIR" && PATH="$TEST_BIN:$PATH" TMUX_PANE="%leader" ./.ai-team/scripts/team-start-runtime.sh "./custom-config/agents.json" "./custom-config/layout.json"'
    [ "$status" -eq 0 ]

    grep -Fxq 'leader' "$MAILBOX_INIT_LOG"
    grep -Fxq 'reviewer' "$MAILBOX_INIT_LOG"
    grep -Fxq 'builder' "$MAILBOX_INIT_LOG"
    ! grep -Fxq 'observer' "$MAILBOX_INIT_LOG"

    run jq -e 'length == 4 and all(has("member") | not)' "$APPLY_LAYOUT_JSON_LOG"
    [ "$status" -eq 0 ]
    run jq -e --arg leader '%leader' '.[] | select(.position == "top-left") | .pane_id == $leader' "$APPLY_LAYOUT_JSON_LOG"
    [ "$status" -eq 0 ]
    grep -Fxq 'feature-session' "$APPLY_LAYOUT_SESSION_LOG"

    panes_file="${PROJECT_DIR}/.ai-team/feature-session/panes.env"
    [ -f "$panes_file" ]
    grep -Fq 'TEAM_MEMBERS="leader reviewer builder observer"' "$panes_file"
    grep -Fq 'TEAMMATE_MEMBERS="reviewer builder observer"' "$panes_file"
    grep -Fq 'LEADER_PANE=%leader' "$panes_file"
    grep -Fq 'REVIEWER_PANE=%reviewer' "$panes_file"
    grep -Fq 'BUILDER_PANE=%builder' "$panes_file"
    grep -Fq 'OBSERVER_PANE=%observer' "$panes_file"

    run jq -e '.members | length == 4' "${START_AGENTS_LOG}.agents"
    [ "$status" -eq 0 ]
    run jq -e '.leader == "%leader" and .reviewer == "%reviewer" and .builder == "%builder" and .observer == "%observer"' "${START_AGENTS_LOG}.panes"
    [ "$status" -eq 0 ]

    grep -Fxq '.ai-team/feature-session/mailbox' "$BRIDGE_ARGS_LOG"
    grep -Fxq 'leader:%leader' "$BRIDGE_ARGS_LOG"
    grep -Fxq 'builder:%builder' "$BRIDGE_ARGS_LOG"
    ! grep -Fxq 'reviewer:%reviewer' "$BRIDGE_ARGS_LOG"
    ! grep -Fxq 'observer:%observer' "$BRIDGE_ARGS_LOG"

    [ -f "${PROJECT_DIR}/.ai-team/feature-session/bridge.pid" ]
    ! grep -Fq 'run-shell' "$FAKE_TMUX_LOG"
}

# シナリオ: team-start-runtime を `--resume` 付きで実行する。
# 保証: 保存済み panes.env から pane_map を復元し、resume-agents と bridge 再起動だけを行う。
@test "team-start-runtime resumes agents from saved pane state" {
    prepare_tmux_stub
    write_prompt_files

    export FAKE_TMUX_LOG="${TEST_LOG_DIR}/resume-tmux.log"
    export FAKE_TMUX_SESSION_NAME="resume-session"
    export FAKE_TMUX_WINDOWS="@0"
    export RESUME_AGENTS_LOG="${TEST_LOG_DIR}/resume-agents.log"
    export BRIDGE_ARGS_LOG="${TEST_LOG_DIR}/resume-bridge-args.log"

    cat > "${PROJECT_DIR}/.ai-team/scripts/resume-agents.sh" <<'EOF_RESUME_AGENTS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" > "$RESUME_AGENTS_LOG.agents"
printf '%s\n' "$2" > "$RESUME_AGENTS_LOG.panes"
printf '%s\n' '{"started":[],"resumed":["reviewer"],"kept":["builder"],"skipped":["leader","observer"],"failed":[]}'
EOF_RESUME_AGENTS
    chmod +x "${PROJECT_DIR}/.ai-team/scripts/resume-agents.sh"

    cat > "${PROJECT_DIR}/.ai-team/scripts/mailbox-bridge.sh" <<'EOF_BRIDGE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$BRIDGE_ARGS_LOG"
EOF_BRIDGE
    chmod +x "${PROJECT_DIR}/.ai-team/scripts/mailbox-bridge.sh"

    mkdir -p "${PROJECT_DIR}/custom-config"
    cat > "${PROJECT_DIR}/custom-config/agents.json" <<'EOF_AGENTS'
{
  "members": [
    {
      "member": "leader",
      "leader": true,
      "mailbox": true,
      "bridge": true
    },
    {
      "member": "reviewer",
      "leader": false,
      "mailbox": true,
      "bridge": false,
      "launcher": {
        "cli": "claude",
        "model": "claude-sonnet-4-6",
        "think_mode": "high",
        "permission_mode": "acceptEdits"
      }
    },
    {
      "member": "builder",
      "leader": false,
      "mailbox": true,
      "bridge": true,
      "launcher": {
        "cli": "codex",
        "model": "gpt-5.4",
        "think_mode": "xhigh",
        "sandbox": "read-only",
        "approval_policy": "never"
      }
    },
    {
      "member": "observer",
      "leader": false,
      "mailbox": false,
      "bridge": false
    }
  ]
}
EOF_AGENTS

    mkdir -p "${PROJECT_DIR}/.ai-team/resume-session"
    cat > "${PROJECT_DIR}/.ai-team/resume-session/panes.env" <<'EOF_PANES'
TEAM_MEMBERS="leader reviewer builder observer"
TEAMMATE_MEMBERS="reviewer builder observer"
LEADER_PANE=%leader
REVIEWER_PANE=%reviewer
BUILDER_PANE=%builder
OBSERVER_PANE=%observer
EOF_PANES

    run bash -lc 'cd "$PROJECT_DIR" && PATH="$TEST_BIN:$PATH" ./.ai-team/scripts/team-start-runtime.sh --resume "./custom-config/agents.json"'
    [ "$status" -eq 0 ]

    run jq -e '.members | length == 4' "${RESUME_AGENTS_LOG}.agents"
    [ "$status" -eq 0 ]
    run jq -e '.leader == "%leader" and .reviewer == "%reviewer" and .builder == "%builder" and .observer == "%observer"' "${RESUME_AGENTS_LOG}.panes"
    [ "$status" -eq 0 ]

    grep -Fxq '.ai-team/resume-session/mailbox' "$BRIDGE_ARGS_LOG"
    grep -Fxq 'leader:%leader' "$BRIDGE_ARGS_LOG"
    grep -Fxq 'builder:%builder' "$BRIDGE_ARGS_LOG"
    ! grep -Fxq 'reviewer:%reviewer' "$BRIDGE_ARGS_LOG"
    ! grep -Fxq 'observer:%observer' "$BRIDGE_ARGS_LOG"

    [ -f "${PROJECT_DIR}/.ai-team/resume-session/bridge.pid" ]
}

# シナリオ: team-start-runtime が session-management へ渡す pane_map に重複 pane が含まれる。
# 保証: 委譲先の validation エラーが呼び出し元へ伝播し、bridge 起動前に処理が失敗する。
@test "team-start-runtime surfaces delegated validation errors for duplicate panes" {
    prepare_tmux_stub
    write_prompt_files

    export FAKE_TMUX_LOG="${TEST_LOG_DIR}/delegated-duplicate-tmux.log"
    export FAKE_TMUX_SESSION_NAME="duplicate-session"
    export FAKE_TMUX_WINDOWS="@0"
    export MAILBOX_INIT_LOG="${TEST_LOG_DIR}/delegated-mailbox-init.log"
    export APPLY_LAYOUT_JSON_LOG="${TEST_LOG_DIR}/delegated-apply-layout.json"
    export APPLY_LAYOUT_SESSION_LOG="${TEST_LOG_DIR}/delegated-apply-layout.session"
    export BRIDGE_ARGS_LOG="${TEST_LOG_DIR}/delegated-bridge-args.log"

    bash "${SESSION_MANAGEMENT_SCRIPT_DIR}/install.sh" --project-dir "${PROJECT_DIR}"

    cat > "${PROJECT_DIR}/.ai-team/scripts/mailbox-init.sh" <<'EOF_MAILBOX_INIT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$MAILBOX_INIT_LOG"
EOF_MAILBOX_INIT
    chmod +x "${PROJECT_DIR}/.ai-team/scripts/mailbox-init.sh"

    cat > "${PROJECT_DIR}/.ai-team/scripts/apply-layout.sh" <<'EOF_APPLY_LAYOUT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$1" > "$APPLY_LAYOUT_JSON_LOG"
printf '%s\n' "$2" > "$APPLY_LAYOUT_SESSION_LOG"
cat <<'EOF_LAYOUT_RESULT'
{"@0":[{"position":"top-left","pane_id":"%leader"},{"position":"top-right","pane_id":"%shared"},{"position":"bottom-left","pane_id":"%shared"},{"position":"bottom-right","pane_id":"%observer"}]}
EOF_LAYOUT_RESULT
EOF_APPLY_LAYOUT
    chmod +x "${PROJECT_DIR}/.ai-team/scripts/apply-layout.sh"

    cat > "${PROJECT_DIR}/.ai-team/scripts/mailbox-bridge.sh" <<'EOF_BRIDGE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$BRIDGE_ARGS_LOG"
EOF_BRIDGE
    chmod +x "${PROJECT_DIR}/.ai-team/scripts/mailbox-bridge.sh"

    mkdir -p "${PROJECT_DIR}/custom-config"
    cat > "${PROJECT_DIR}/custom-config/agents.json" <<'EOF_AGENTS'
{
  "members": [
    {
      "member": "leader",
      "leader": true,
      "mailbox": true,
      "bridge": true
    },
    {
      "member": "reviewer",
      "leader": false,
      "mailbox": true,
      "bridge": false,
      "launcher": {
        "cli": "claude"
      }
    },
    {
      "member": "builder",
      "leader": false,
      "mailbox": true,
      "bridge": true,
      "launcher": {
        "cli": "codex"
      }
    },
    {
      "member": "observer",
      "leader": false,
      "mailbox": false,
      "bridge": false
    }
  ]
}
EOF_AGENTS

    cat > "${PROJECT_DIR}/custom-config/layout.json" <<'EOF_LAYOUT'
[
  { "member": "leader",   "group_id": 0, "position": "top-left" },
  { "member": "reviewer", "group_id": 0, "position": "top-right" },
  { "member": "builder",  "group_id": 0, "position": "bottom-left" },
  { "member": "observer", "group_id": 0, "position": "bottom-right" }
]
EOF_LAYOUT

    run bash -lc 'cd "$PROJECT_DIR" && PATH="$TEST_BIN:$PATH" TMUX_PANE="%leader" ./.ai-team/scripts/team-start-runtime.sh "./custom-config/agents.json" "./custom-config/layout.json" 2>&1'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Pane map must not contain duplicate pane IDs"* ]]

    grep -Fxq 'leader' "$MAILBOX_INIT_LOG"
    grep -Fxq 'reviewer' "$MAILBOX_INIT_LOG"
    grep -Fxq 'builder' "$MAILBOX_INIT_LOG"
    [ ! -f "${PROJECT_DIR}/.ai-team/duplicate-session/bridge.pid" ]
    [ ! -f "$BRIDGE_ARGS_LOG" ]
}
