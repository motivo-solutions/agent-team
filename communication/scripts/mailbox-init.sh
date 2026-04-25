#!/usr/bin/env bash
set -euo pipefail

# 現在の tmux セッション用の Mailbox ディレクトリを初期化する。
# Usage: mailbox-init.sh <member> [<member> ...]

# 引数:
#   $*: エラーメッセージ本文
# 戻り値:
#   なし。標準エラー出力後に終了コード 1 で終了する。
# 処理概要:
#   入力不備や不正なメンバー名を検出したときに処理を中断する。
die() {
    echo "[mailbox-init] Error: $*" >&2
    exit 1
}

if [ $# -lt 1 ]; then
    die "Usage: mailbox-init.sh <member> [<member> ...]"
fi

# tmux からセッション名を取得する。
SESSION_NAME=$(tmux display-message -p '#{session_name}')

for MEMBER in "$@"; do
    if [[ "$MEMBER" == *".."* ]] || [[ "$MEMBER" == *"/"* ]]; then
        die "Invalid member name: $MEMBER"
    fi

    MAILBOX_BASE=".ai-team/${SESSION_NAME}/mailbox/${MEMBER}"
    mkdir -p "${MAILBOX_BASE}/inbox"
    mkdir -p "${MAILBOX_BASE}/outbox"
    echo "[mailbox-init] Created mailbox for ${MEMBER} in session ${SESSION_NAME}" >&2
done
