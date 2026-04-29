#!/usr/bin/env bats

setup() {
    export PROJECT_DIR="$(mktemp -d)"
    export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
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

# シナリオ: 保存済み state を使って team-stop-runtime を実行する。
# 保証: panes.env に記録された全 pane を layout JSON に含め、leader は維持、non-leader は削除対象として apply-layout に渡される。
@test "team-stop-runtime derives pane cleanup targets from saved member state" {
    prepare_tmux_stub

    export FAKE_TMUX_LOG="${TEST_LOG_DIR}/stop-tmux.log"
    export FAKE_TMUX_SESSION_NAME="cleanup-session"
    export FAKE_TMUX_WINDOWS="@0"
    export APPLY_LAYOUT_JSON_LOG="${TEST_LOG_DIR}/stop-apply-layout.json"
    export APPLY_LAYOUT_SESSION_LOG="${TEST_LOG_DIR}/stop-apply-layout.session"
    export MAILBOX_CLEANUP_LOG="${TEST_LOG_DIR}/mailbox-cleanup.log"

    cat > "${PROJECT_DIR}/.ai-team/scripts/mailbox-cleanup.sh" <<'EOF_MAILBOX_CLEANUP'
#!/usr/bin/env bash
set -euo pipefail
printf 'cleanup\n' > "$MAILBOX_CLEANUP_LOG"
EOF_MAILBOX_CLEANUP
    chmod +x "${PROJECT_DIR}/.ai-team/scripts/mailbox-cleanup.sh"

    cat > "${PROJECT_DIR}/.ai-team/scripts/apply-layout.sh" <<'EOF_STOP_APPLY_LAYOUT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$1" > "$APPLY_LAYOUT_JSON_LOG"
printf '%s\n' "$2" > "$APPLY_LAYOUT_SESSION_LOG"
printf '{}'
EOF_STOP_APPLY_LAYOUT
    chmod +x "${PROJECT_DIR}/.ai-team/scripts/apply-layout.sh"

    mkdir -p "${PROJECT_DIR}/.ai-team/cleanup-session"
    cat > "${PROJECT_DIR}/.ai-team/cleanup-session/panes.env" <<'EOF_PANES'
TEAM_MEMBERS="leader reviewer builder observer"
TEAMMATE_MEMBERS="reviewer builder observer"
LEADER_PANE=%leader
REVIEWER_PANE=%reviewer
BUILDER_PANE=%builder
OBSERVER_PANE=%observer
EOF_PANES
    printf '999999\n' > "${PROJECT_DIR}/.ai-team/cleanup-session/bridge.pid"
    printf 'bridge\n' > "${PROJECT_DIR}/.ai-team/cleanup-session/bridge.log"

    run bash -lc 'cd "$PROJECT_DIR" && PATH="$TEST_BIN:$PATH" ./.ai-team/scripts/team-stop-runtime.sh'
    [ "$status" -eq 0 ]

    grep -Fxq 'cleanup' "$MAILBOX_CLEANUP_LOG"
    grep -Fxq 'cleanup-session' "$APPLY_LAYOUT_SESSION_LOG"
    run jq -e '
        length == 4
        and any(.pane_id == "%leader" and .group_id == 0 and .position == "whole")
        and any(.pane_id == "%reviewer" and .position == null)
        and any(.pane_id == "%builder" and .position == null)
        and any(.pane_id == "%observer" and .position == null)
    ' "$APPLY_LAYOUT_JSON_LOG"
    [ "$status" -eq 0 ]
    run jq -e 'all(if .position == null then .group_id == null else true end)' "$APPLY_LAYOUT_JSON_LOG"
    [ "$status" -eq 0 ]

    [ ! -f "${PROJECT_DIR}/.ai-team/cleanup-session/bridge.pid" ]
    [ ! -f "${PROJECT_DIR}/.ai-team/cleanup-session/bridge.log" ]
    [ ! -f "${PROJECT_DIR}/.ai-team/cleanup-session/panes.env" ]
}
