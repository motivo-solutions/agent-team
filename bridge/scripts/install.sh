#!/usr/bin/env bash
set -euo pipefail

# install.sh - Install mailbox-bridge.sh to .ai-team/scripts/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments: accept --project-dir, ignore unknown flags
PROJECT_DIR="."
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)
            PROJECT_DIR="$2"
            shift 2
            ;;
        *)
            # Ignore unknown arguments
            shift
            ;;
    esac
done

INSTALL_DIR="${PROJECT_DIR}/.ai-team/scripts"

mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/mailbox-bridge.sh" "$INSTALL_DIR/mailbox-bridge.sh"
chmod +x "$INSTALL_DIR/mailbox-bridge.sh"

echo "Installed mailbox-bridge.sh to $INSTALL_DIR"
