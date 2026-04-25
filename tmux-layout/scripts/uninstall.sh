#!/usr/bin/env bash
set -euo pipefail

# uninstall.sh
# Uninstall script that removes .ai-team/scripts/apply-layout.sh

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

TARGET_FILE="${PROJECT_DIR}/.ai-team/scripts/apply-layout.sh"

rm -f "$TARGET_FILE"

echo "Uninstalled apply-layout.sh from ${PROJECT_DIR}/.ai-team/scripts/"
