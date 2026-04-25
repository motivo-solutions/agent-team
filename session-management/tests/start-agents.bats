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

# シナリオ: start-agents に agents_config と pane_map を渡す。
# 保証: launcher を持つメンバーだけが対象 pane で起動され、session ID の保存は SessionStart hook に委譲される。
@test "start-agents launches configured members and reports JSON result" {
    prepare_tmux_stub
    export FAKE_TMUX_LOG="${TEST_LOG_DIR}/tmux.log"

    mkdir -p "${PROJECT_DIR}/.ai-team/prompts"
    printf '%s\n' 'Reviewer prompt' > "${PROJECT_DIR}/.ai-team/prompts/reviewer.md"
    printf '%s\n' 'Builder prompt' > "${PROJECT_DIR}/.ai-team/prompts/builder.md"

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
        "permission_mode": "acceptEdits",
        "prompt_path": ".ai-team/prompts/reviewer.md"
      }
    },
    {
      "member": "builder",
      "launcher": {
        "cli": "codex",
        "model": "gpt-5.4",
        "think_mode": "xhigh",
        "sandbox": "workspace-write",
        "approval_policy": "never",
        "prompt_path": ".ai-team/prompts/builder.md"
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

    run bash -lc 'cd "$PROJECT_DIR" && HOME="$TEST_HOME" PATH="$TEST_BIN:$PATH" ./.ai-team/scripts/start-agents.sh "$(< ./config/agents.json)" "$(< ./config/panes.json)"'
    [ "$status" -eq 0 ]

    run jq -e '
        .started == ["reviewer", "builder"]
        and .resumed == []
        and .kept == []
        and .skipped == ["leader", "observer"]
        and .failed == []
    ' <<< "$output"
    [ "$status" -eq 0 ]

    grep -Fq 'send-keys -t %11 -l AI_TEAM_MEMBER=reviewer claude' "$FAKE_TMUX_LOG"
    grep -Fq -- '--model claude-sonnet-4-6' "$FAKE_TMUX_LOG"
    grep -Fq -- '--effort high' "$FAKE_TMUX_LOG"
    grep -Fq -- '--permission-mode acceptEdits' "$FAKE_TMUX_LOG"
    grep -Fq -- '--append-system-prompt' "$FAKE_TMUX_LOG"

    grep -Fq 'send-keys -t %12 -l AI_TEAM_MEMBER=builder codex' "$FAKE_TMUX_LOG"
    grep -Fq -- '--model gpt-5.4' "$FAKE_TMUX_LOG"
    grep -Fq -- '--sandbox workspace-write' "$FAKE_TMUX_LOG"
    grep -Fq -- '--ask-for-approval never' "$FAKE_TMUX_LOG"

    ! grep -Fq 'send-keys -t %10 -l' "$FAKE_TMUX_LOG"
    ! grep -Fq 'send-keys -t %13 -l' "$FAKE_TMUX_LOG"
    [ ! -f "${PROJECT_DIR}/.ai-team/test-session/agent-sessions.json" ]
}

# シナリオ: Claude / Codex の SessionStart hook に session_id が渡される。
# 保証: 両 CLI とも common helper に依存せず agent-sessions.json へ session_id を保存し、メンバー別のキーを使い分ける。
@test "session start hooks persist session ids for Claude and Codex members" {
    prepare_tmux_stub
    export FAKE_TMUX_LOG="${TEST_LOG_DIR}/record-agent-session-id-tmux.log"
    rm -f "${PROJECT_DIR}/.ai-team/scripts/session-management-common.sh"

    run bash -lc "cd \"$PROJECT_DIR\" && printf '%s\n' '{\"session_id\":\"claude-session-123\",\"cwd\":\"$PROJECT_DIR\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}' | PATH=\"$TEST_BIN:\$PATH\" AI_TEAM_MEMBER=reviewer ./.ai-team/scripts/record-agent-session-id.sh --cli claude"
    [ "$status" -eq 0 ]

    run bash -lc "cd \"$PROJECT_DIR\" && printf '%s\n' '{\"session_id\":\"codex-thread-123\",\"cwd\":\"$PROJECT_DIR\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}' | PATH=\"$TEST_BIN:\$PATH\" AI_TEAM_MEMBER=builder ./.ai-team/scripts/record-agent-session-id.sh --cli codex"
    [ "$status" -eq 0 ]

    run jq -e '
        .members.reviewer.claude_session_id == "claude-session-123"
        and .members.builder.codex_session_id == "codex-thread-123"
    ' "${PROJECT_DIR}/.ai-team/test-session/agent-sessions.json"
    [ "$status" -eq 0 ]
}

# シナリオ: start-agents に同じ pane_id を共有する pane_map を渡す。
# 保証: session-management は重複 pane を検出してエラー終了し、起動コマンドは一切送信しない。
@test "start-agents rejects duplicate pane assignments" {
    prepare_tmux_stub
    export FAKE_TMUX_LOG="${TEST_LOG_DIR}/duplicate-panes-tmux.log"

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
        "prompt_path": ".ai-team/prompts/reviewer.md"
      }
    },
    {
      "member": "builder",
      "launcher": {
        "cli": "codex",
        "prompt_path": ".ai-team/prompts/builder.md"
      }
    }
  ]
}
EOF_AGENTS

    cat > "${PROJECT_DIR}/config/panes.json" <<'EOF_PANES'
{
  "leader": "%10",
  "reviewer": "%11",
  "builder": "%11"
}
EOF_PANES

    run bash -lc 'cd "$PROJECT_DIR" && PATH="$TEST_BIN:$PATH" ./.ai-team/scripts/start-agents.sh "$(< ./config/agents.json)" "$(< ./config/panes.json)" 2>&1'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Pane map must not contain duplicate pane IDs"* ]]
    [ ! -f "$FAKE_TMUX_LOG" ] || ! grep -Fq 'send-keys' "$FAKE_TMUX_LOG"
}
