#!/usr/bin/env bash
set -euo pipefail

# team-management モジュールのアンインストールスクリプト。
# install.sh で配置した skill と runtime script を除去する。

# Default project directory
PROJECT_DIR="."

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --project-dir)
            PROJECT_DIR="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

echo "[team-management] Uninstalling from ${PROJECT_DIR}" >&2

# --- Remove team-start skill ---
rm -rf "${PROJECT_DIR}/.claude/skills/team-start"
echo "[team-management] Removed team-start skill" >&2

# --- Remove team-resume skill ---
rm -rf "${PROJECT_DIR}/.claude/skills/team-resume"
echo "[team-management] Removed team-resume skill" >&2

# --- Remove team-stop skill ---
rm -rf "${PROJECT_DIR}/.claude/skills/team-stop"
echo "[team-management] Removed team-stop skill" >&2

# --- Remove runtime helper scripts ---
rm -f "${PROJECT_DIR}/.ai-team/scripts/team-start-runtime.sh"
rm -f "${PROJECT_DIR}/.ai-team/scripts/team-stop-runtime.sh"
echo "[team-management] Removed runtime helper scripts" >&2

# --- Remove team configuration JSON files ---
rm -f "${PROJECT_DIR}/.ai-team/agents.config.json"
rm -f "${PROJECT_DIR}/.ai-team/layouts.config.json"
echo "[team-management] Removed team configuration JSON files" >&2

echo "[team-management] Uninstallation complete" >&2
