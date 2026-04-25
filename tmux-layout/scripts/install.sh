#!/usr/bin/env bash
set -euo pipefail

# install.sh
# Install script that places apply-layout.sh into .ai-team/scripts/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

TARGET_DIR="${PROJECT_DIR}/.ai-team/scripts"

mkdir -p "$TARGET_DIR"
cp "${SCRIPT_DIR}/apply-layout.sh" "${TARGET_DIR}/apply-layout.sh"
chmod +x "${TARGET_DIR}/apply-layout.sh"

echo "Installed apply-layout.sh to ${TARGET_DIR}/"
