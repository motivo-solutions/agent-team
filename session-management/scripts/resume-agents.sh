#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 共通実装を source し、resume モードだけを公開する。
# 仕様上の外部インターフェースは本ファイルで固定する。
source "${SCRIPT_DIR}/session-management-common.sh"

session_management_main "resume" "$@"
