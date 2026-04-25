#!/usr/bin/env bash
set -euo pipefail

# team-management モジュールのインストールスクリプト。
# skill、runtime script、構成 JSON をプロジェクトへ配置する。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_DIR="."

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

PROJECT_DIR="$(cd "${PROJECT_DIR}" && pwd)"

echo "[team-management] Installing to ${PROJECT_DIR}" >&2

mkdir -p "${PROJECT_DIR}/.claude/skills/team-start"
cp "${MODULE_DIR}/skills/team-start/SKILL.md" "${PROJECT_DIR}/.claude/skills/team-start/SKILL.md"
echo "[team-management] Placed team-start skill" >&2

mkdir -p "${PROJECT_DIR}/.claude/skills/team-resume"
cp "${MODULE_DIR}/skills/team-resume/SKILL.md" "${PROJECT_DIR}/.claude/skills/team-resume/SKILL.md"
echo "[team-management] Placed team-resume skill" >&2

mkdir -p "${PROJECT_DIR}/.claude/skills/team-stop"
cp "${MODULE_DIR}/skills/team-stop/SKILL.md" "${PROJECT_DIR}/.claude/skills/team-stop/SKILL.md"
echo "[team-management] Placed team-stop skill" >&2

mkdir -p "${PROJECT_DIR}/.ai-team/scripts"
cp "${MODULE_DIR}/scripts/team-start-runtime.sh" "${PROJECT_DIR}/.ai-team/scripts/team-start-runtime.sh"
cp "${MODULE_DIR}/scripts/team-stop-runtime.sh" "${PROJECT_DIR}/.ai-team/scripts/team-stop-runtime.sh"
chmod +x "${PROJECT_DIR}/.ai-team/scripts/team-start-runtime.sh"
chmod +x "${PROJECT_DIR}/.ai-team/scripts/team-stop-runtime.sh"
echo "[team-management] Placed runtime helper scripts" >&2

mkdir -p "${PROJECT_DIR}/.ai-team"
cp "${MODULE_DIR}/config/agents.config.json" "${PROJECT_DIR}/.ai-team/agents.config.json"
cp "${MODULE_DIR}/config/layouts.config.json" "${PROJECT_DIR}/.ai-team/layouts.config.json"
echo "[team-management] Placed team configuration JSON files" >&2

echo "[team-management] Installation complete" >&2
