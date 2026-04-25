#!/usr/bin/env bash
set -euo pipefail

# agent-team integrated install script
# Installs the team-management runtime and the modules it depends on.
#
# Usage:
#   ./install.sh
#   ./install.sh --project-dir ~/workspace/my-project
#   ./install.sh --project-dir ~/workspace/my-project --default-member leader

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== tmux-layout ==="
bash "$SCRIPT_DIR/tmux-layout/scripts/install.sh" "$@"

echo "=== communication ==="
bash "$SCRIPT_DIR/communication/scripts/install.sh" "$@"

echo "=== bridge ==="
bash "$SCRIPT_DIR/bridge/scripts/install.sh" "$@"

echo "=== session-management ==="
bash "$SCRIPT_DIR/session-management/scripts/install.sh" "$@"

echo "=== team-management ==="
bash "$SCRIPT_DIR/team-management/scripts/install.sh" "$@"

echo "=== Installation complete ==="
