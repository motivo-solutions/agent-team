#!/usr/bin/env bash
set -euo pipefail

# uninstall.sh - Remove mailbox-bridge.sh from .ai-team/scripts/

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

TARGET="${PROJECT_DIR}/.ai-team/scripts/mailbox-bridge.sh"

rm -f "$TARGET"

echo "Uninstalled mailbox-bridge.sh from ${PROJECT_DIR}/.ai-team/scripts"
