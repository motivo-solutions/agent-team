#!/usr/bin/env bash
set -euo pipefail

# agent-team integrated uninstall script
# Removes files installed by the copied modules.
#
# Usage:
#   ./uninstall.sh
#   ./uninstall.sh --project-dir ~/workspace/my-project

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== team-management ==="
bash "$SCRIPT_DIR/team-management/scripts/uninstall.sh" "$@"

echo "=== session-management ==="
bash "$SCRIPT_DIR/session-management/scripts/uninstall.sh" "$@"

echo "=== bridge ==="
bash "$SCRIPT_DIR/bridge/scripts/uninstall.sh" "$@"

echo "=== communication ==="
bash "$SCRIPT_DIR/communication/scripts/uninstall.sh" "$@"

echo "=== tmux-layout ==="
bash "$SCRIPT_DIR/tmux-layout/scripts/uninstall.sh" "$@"

PROJECT_DIR="."
prev_arg=""
for arg in "$@"; do
    if [ "$prev_arg" = "--project-dir" ]; then
        PROJECT_DIR="$arg"
    fi
    prev_arg="$arg"
done

for dir in \
    "$PROJECT_DIR/.ai-team/scripts" \
    "$PROJECT_DIR/.ai-team/prompts" \
    "$PROJECT_DIR/.ai-team/persona" \
    "$PROJECT_DIR/.ai-team/docs" \
    "$PROJECT_DIR/.ai-team" \
    "$PROJECT_DIR/.claude/skills" \
    "$PROJECT_DIR/.claude" \
    "$PROJECT_DIR/.codex" \
    "$PROJECT_DIR/.agents/skills" \
    "$PROJECT_DIR/.agents"; do
    if [ -d "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
        rmdir "$dir"
    fi
done

echo "=== Uninstallation complete ==="
