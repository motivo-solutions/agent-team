#!/usr/bin/env bash
set -euo pipefail

# 現在の tmux セッション用の Mailbox ディレクトリを削除する。
# Usage: mailbox-cleanup.sh

# tmux からセッション名を取得する。
SESSION_NAME=$(tmux display-message -p '#{session_name}')

MAILBOX_DIR=".ai-team/${SESSION_NAME}/mailbox"

if [ -d "$MAILBOX_DIR" ]; then
    rm -rf "$MAILBOX_DIR"
    echo "[mailbox-cleanup] Removed mailbox for session ${SESSION_NAME}" >&2
else
    echo "[mailbox-cleanup] No mailbox found for session ${SESSION_NAME}, skipping" >&2
fi
