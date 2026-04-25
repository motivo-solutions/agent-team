#!/usr/bin/env bats

setup() {
    export PROJECT_DIR="$(mktemp -d)"
    export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
    export TEST_BIN="${PROJECT_DIR}/test-bin"
    export TEST_LOG_DIR="${PROJECT_DIR}/test-logs"
    export TEST_HOME="${PROJECT_DIR}/home"
    mkdir -p "$TEST_BIN" "$TEST_LOG_DIR" "${PROJECT_DIR}/config" "$TEST_HOME"
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
        if [ "${2:-}" = "-p" ] && [ "${3:-}" = "#{session_name}" ]; then
            printf 'test-session\n'
            exit 0
        fi

        if [ "${2:-}" = "-p" ] && [ "${3:-}" = "-t" ] && [ "${5:-}" = '#{pane_current_command}' ]; then
            case "${4}" in
                %11)
                    printf '%s\n' "${PANE_11_COMMAND}"
                    ;;
                %12)
                    printf '%s\n' "${PANE_12_COMMAND}"
                    ;;
                *)
                    printf 'bash\n'
                    ;;
            esac
            exit 0
        fi
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

# シナリオ: resume-agents に停止中と動作中のメンバーが混在している。
# 保証: 停止中メンバーだけが resume 起動され、動作中メンバーは kept としてスキップされる。
@test "resume-agents only resumes stopped members and keeps running ones" {
    prepare_tmux_stub
    export FAKE_TMUX_LOG="${TEST_LOG_DIR}/tmux.log"
    export PANE_11_COMMAND="bash"
    export PANE_12_COMMAND="codex"

    cat > "${PROJECT_DIR}/config/agents.json" <<'EOF_AGENTS'
{
  "members": [
    {
      "member": "leader",
      "leader": true
    },
    {
      "member": "reviewer",
      "launcher": {
        "cli": "claude",
        "model": "claude-sonnet-4-6",
        "think_mode": "high",
        "permission_mode": "acceptEdits"
      }
    },
    {
      "member": "builder",
      "launcher": {
        "cli": "codex",
        "model": "gpt-5.4",
        "think_mode": "xhigh",
        "sandbox": "workspace-write",
        "approval_policy": "never"
      }
    },
    {
      "member": "observer"
    }
  ]
}
EOF_AGENTS

    cat > "${PROJECT_DIR}/config/panes.json" <<'EOF_PANES'
{
  "leader": "%10",
  "reviewer": "%11",
  "builder": "%12",
  "observer": "%13"
}
EOF_PANES

    run bash -lc 'cd "$PROJECT_DIR" && PATH="$TEST_BIN:$PATH" ./.ai-team/scripts/resume-agents.sh "$(< ./config/agents.json)" "$(< ./config/panes.json)"'
    [ "$status" -eq 0 ]

    run jq -e '
        .started == []
        and .resumed == ["reviewer"]
        and .kept == ["builder"]
        and .skipped == ["leader", "observer"]
        and .failed == []
    ' <<< "$output"
    [ "$status" -eq 0 ]

    grep -Fq 'display-message -p -t %11 #{pane_current_command}' "$FAKE_TMUX_LOG"
    grep -Fq 'display-message -p -t %12 #{pane_current_command}' "$FAKE_TMUX_LOG"
    grep -Fq 'send-keys -t %11 -l AI_TEAM_MEMBER=reviewer claude' "$FAKE_TMUX_LOG"
    grep -Fq -- '--continue' "$FAKE_TMUX_LOG"
    ! grep -Fq 'send-keys -t %12 -l' "$FAKE_TMUX_LOG"
}

# シナリオ: resume-agents に保存済みの Claude / Codex セッション ID がある。
# 保証: 両 CLI とも `agent-sessions.json` の保存済み ID を優先して復旧し、Codex は `resume --last` を使わない。
@test "resume-agents uses saved session ids for both claude and codex members" {
    prepare_tmux_stub
    export FAKE_TMUX_LOG="${TEST_LOG_DIR}/saved-session-tmux.log"
    export PANE_11_COMMAND="bash"
    export PANE_12_COMMAND="bash"

    mkdir -p "${PROJECT_DIR}/.ai-team/test-session"
    cat > "${PROJECT_DIR}/.ai-team/test-session/agent-sessions.json" <<'EOF_STATE'
{
  "members": {
    "reviewer": {
      "claude_session_id": "claude-session-123"
    },
    "builder": {
      "codex_session_id": "codex-thread-123"
    }
  }
}
EOF_STATE

    cat > "${PROJECT_DIR}/config/agents.json" <<'EOF_AGENTS'
{
  "members": [
    {
      "member": "leader",
      "leader": true
    },
    {
      "member": "reviewer",
      "launcher": {
        "cli": "claude",
        "model": "claude-sonnet-4-6",
        "think_mode": "high",
        "permission_mode": "acceptEdits"
      }
    },
    {
      "member": "builder",
      "launcher": {
        "cli": "codex",
        "model": "gpt-5.4",
        "think_mode": "xhigh",
        "sandbox": "workspace-write",
        "approval_policy": "never"
      }
    }
  ]
}
EOF_AGENTS

    cat > "${PROJECT_DIR}/config/panes.json" <<'EOF_PANES'
{
  "leader": "%10",
  "reviewer": "%11",
  "builder": "%12"
}
EOF_PANES

    run bash -lc 'cd "$PROJECT_DIR" && HOME="$TEST_HOME" PATH="$TEST_BIN:$PATH" ./.ai-team/scripts/resume-agents.sh "$(< ./config/agents.json)" "$(< ./config/panes.json)"'
    [ "$status" -eq 0 ]

    run jq -e '
        .started == []
        and .resumed == ["reviewer", "builder"]
        and .kept == []
        and .skipped == ["leader"]
        and .failed == []
    ' <<< "$output"
    [ "$status" -eq 0 ]

    grep -Fq 'send-keys -t %11 -l AI_TEAM_MEMBER=reviewer claude' "$FAKE_TMUX_LOG"
    grep -Fq -- '--resume claude-session-123' "$FAKE_TMUX_LOG"
    grep -Fq 'send-keys -t %12 -l AI_TEAM_MEMBER=builder codex' "$FAKE_TMUX_LOG"
    grep -Fq 'resume codex-thread-123' "$FAKE_TMUX_LOG"
    ! grep -Fq 'resume --last' "$FAKE_TMUX_LOG"
}
