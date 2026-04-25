#!/usr/bin/env bash
set -euo pipefail

# 引数:
#   --cli <claude|codex>: 保存先キーを決める CLI 種別。
# 戻り値:
#   0: 保存成功または保存対象外。
#   非 0: state file 更新失敗。
# 処理概要:
#   1. hook stdin から session_id と cwd を読む。
#   2. repo root と tmux session 名を解決する。
#   3. AI_TEAM_MEMBER に対応する session ID を agent-sessions.json へ保存する。

cli=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cli)
            cli="${2:-}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

resolve_repo_root() {
    # Args:
    #   $1: 探索開始ディレクトリ。
    # Returns:
    #   標準出力: repo root。見つからなければ空文字。
    # Overview:
    #   SessionStart hook が subdirectory で動いても同じ state ファイルへ保存できるよう、
    #   `.git` / `.agents` / `.claude` / `.codex` の存在を手がかりに root を探す。
    local current_dir="$1"

    while [ -n "$current_dir" ] && [ "$current_dir" != "/" ]; do
        if [ -d "${current_dir}/.git" ] \
            || [ -d "${current_dir}/.agents" ] \
            || [ -d "${current_dir}/.claude" ] \
            || [ -d "${current_dir}/.codex" ]; then
            printf '%s\n' "$current_dir"
            return 0
        fi

        current_dir="$(dirname "$current_dir")"
    done

    printf '\n'
}

current_tmux_session_name() {
    # Args:
    #   なし。
    # Returns:
    #   標準出力: 現在の tmux session 名。取得できない場合は空文字。
    # Overview:
    #   hook 実行時の tmux session 名を state file の名前空間として使う。
    tmux display-message -p '#{session_name}' 2>/dev/null || true
}

save_agent_session_id() {
    # Args:
    #   $1: repo root。
    #   $2: メンバー ID。
    #   $3: 保存先キー名。
    #   $4: 保存する session ID。
    # Returns:
    #   0: 保存成功または保存不要。
    #   非 0: jq 変換やファイル更新の失敗。
    # Overview:
    #   1. tmux session 名から `.ai-team/<session>/agent-sessions.json` を決める。
    #   2. 既存 JSON を温存しつつ、対象メンバー配下の session ID を更新する。
    local repo_root="$1"
    local member="$2"
    local session_key="$3"
    local session_id="$4"
    local session_name
    local state_file

    session_name="$(current_tmux_session_name)"
    if [ -z "$session_name" ]; then
        return 0
    fi

    state_file="${repo_root}/.ai-team/${session_name}/agent-sessions.json"
    mkdir -p "$(dirname "$state_file")"

    if [ ! -f "$state_file" ]; then
        printf '{}\n' > "$state_file"
    fi

    jq \
        --arg member "$member" \
        --arg session_key "$session_key" \
        --arg session_id "$session_id" \
        '
            .members = (.members // {})
            | .members[$member] = (.members[$member] // {})
            | .members[$member][$session_key] = $session_id
        ' \
        "$state_file" > "${state_file}.tmp"
    mv "${state_file}.tmp" "$state_file"
}

input="$(cat)"
member="${AI_TEAM_MEMBER:-}"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
hook_event_name="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
hook_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"

if [ -z "$member" ] || [ -z "$session_id" ] || [ "$hook_event_name" != "SessionStart" ]; then
    exit 0
fi

if [ -z "$hook_cwd" ]; then
    hook_cwd="$(pwd -P)"
fi

repo_root="$(resolve_repo_root "$hook_cwd")"
if [ -z "$repo_root" ]; then
    exit 0
fi

case "$cli" in
    claude)
        save_agent_session_id "$repo_root" "$member" "claude_session_id" "$session_id"
        ;;
    codex)
        save_agent_session_id "$repo_root" "$member" "codex_session_id" "$session_id"
        ;;
    *)
        exit 0
        ;;
esac
