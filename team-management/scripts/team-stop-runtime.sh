#!/usr/bin/env bash
set -euo pipefail

# Args:
#   なし。
# Returns:
#   0: 停止処理成功。
#   非 0: tmux session 名や必要ファイルの取得失敗。
# Overview:
#   1. session 名から state ディレクトリを決める。
#   2. bridge を停止し、Mailbox を cleanup する。
#   3. panes.env を読んで teammate pane を削除する。
#   4. state ファイルを削除する。

SESSION_NAME="$(tmux display-message -p '#{session_name}')"
STATE_DIR=".ai-team/${SESSION_NAME}"
PANES_FILE="${STATE_DIR}/panes.env"
BRIDGE_PID_FILE="${STATE_DIR}/bridge.pid"

stop_bridge_if_running() {
    # Args:
    #   $1: PID ファイルパス。
    # Returns:
    #   なし。
    # Overview:
    #   1. PID ファイルがあればプロセス生存確認を行う。
    #   2. bridge が生きていれば停止する。
    local pid_file="$1"

    if [ ! -f "$pid_file" ]; then
        return
    fi

    local bridge_pid
    bridge_pid="$(cat "$pid_file")"
    if kill -0 "$bridge_pid" 2>/dev/null; then
        kill "$bridge_pid" 2>/dev/null || true
        wait "$bridge_pid" 2>/dev/null || true
    fi
}

stop_bridge_if_running "$BRIDGE_PID_FILE"
bash .ai-team/scripts/mailbox-cleanup.sh

if [ -f "$PANES_FILE" ]; then
    # このファイルは team-start-runtime.sh が生成する。
    # jq の env から pane 変数を参照できるよう、一時的に export して取り込む。
    set -a
    # shellcheck disable=SC1090
    source "$PANES_FILE"
    set +a

    layout_json="$(
        TEAMMATES="${TEAMMATE_MEMBERS:-}" jq -nc '
            (env.TEAMMATES | split(" ") | map(select(length > 0))) as $members
            | [
                $members[]
                | {
                    group_id: 0,
                    pane_id: (env[(ascii_upcase + "_PANE")]),
                    position: null
                }
            ]'
    )"

    bash .ai-team/scripts/apply-layout.sh "$layout_json" "$SESSION_NAME" >/dev/null
fi

rm -f "${STATE_DIR}/bridge.pid"
rm -f "${STATE_DIR}/bridge.log"
rm -f "${STATE_DIR}/panes.env"
