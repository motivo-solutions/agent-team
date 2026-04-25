#!/usr/bin/env bash
set -euo pipefail

# 引数:
#   $1: mode ("record-prompt" or "flush-reply")
#   $2...: optional flags such as --default-member <name>
# 戻り値:
#   0 固定。hook 失敗で対話全体を壊さないよう、異常時も黙って終了する。
# 処理概要:
#   1. UserPromptSubmit では Mailbox 配送メッセージかどうかを判定し、返信先を state に保存する。
#   2. Stop では保存済み state を読み、last_assistant_message を Mailbox 返信として出力する。
#   3. last_assistant_message が null / 空文字なら「完了した。」を返信本文に使う。

mode="${1:-}"
shift || true

default_member=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --default-member)
      default_member="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

log() {
  echo "[mailbox-hook] $*" >&2
}

# 引数:
#   なし
# 戻り値:
#   stdout に現在の member 名を出力。判定できなければ空文字。
# 処理概要:
#   1. AI_TEAM_MEMBER があればそれを採用する。
#   2. 無ければ install 時に指定した default_member を使う。
resolve_member() {
  if [[ -n "${AI_TEAM_MEMBER:-}" ]]; then
    printf '%s\n' "${AI_TEAM_MEMBER}"
    return 0
  fi

  if [[ -n "$default_member" ]]; then
    printf '%s\n' "$default_member"
    return 0
  fi

  printf '\n'
}

# 引数:
#   なし
# 戻り値:
#   stdout に tmux session 名を出力。取得できなければ空文字。
# 処理概要:
#   hook 実行プロセスから現在の tmux session 名を読む。
resolve_session_name() {
  tmux display-message -p '#{session_name}' 2>/dev/null || true
}

# 引数:
#   $1: current working directory
# 戻り値:
#   stdout に repo root を出力。見つからなければ空文字。
# 処理概要:
#   .git または .agents を基準にプロジェクト root を遡って探す。
resolve_repo_root() {
  local current_dir="$1"

  while [[ "$current_dir" != "/" ]]; do
    if [[ -d "${current_dir}/.git" ]] || [[ -d "${current_dir}/.agents" ]]; then
      printf '%s\n' "$current_dir"
      return 0
    fi
    current_dir="$(dirname "$current_dir")"
  done

  printf '\n'
}

# 引数:
#   $1: repo root
#   $2: session name
#   $3: member
# 戻り値:
#   stdout に state file path を出力する。
# 処理概要:
#   セッション単位・メンバー単位で pending reply state の保存先を決める。
state_file_path() {
  local repo_root="$1"
  local session_name="$2"
  local member="$3"

  printf '%s\n' "${repo_root}/.ai-team/${session_name}/hook-state/${member}.json"
}

# 引数:
#   $1: prompt text
# 戻り値:
#   Mailbox prompt なら 0、そうでなければ 1。
# 処理概要:
#   先頭の [Mailbox] ヘッダで bridge 配送メッセージを判定する。
is_mailbox_prompt() {
  local prompt="$1"
  [[ "$prompt" == "[Mailbox]"* ]]
}

# 引数:
#   $1: prompt text
# 戻り値:
#   stdout に From ヘッダの sender を出力。見つからなければ空文字。
# 処理概要:
#   bridge が付与した From ヘッダを取り出す。
extract_sender() {
  local prompt="$1"
  local line

  while IFS= read -r line; do
    if [[ "$line" =~ ^From:\ (.+)$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<< "$prompt"

  if [[ "$prompt" =~ From:\ ([^[:space:]]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  printf '\n'
}

# 引数:
#   $1: state file path
#   $2: member
#   $3: sender
# 戻り値:
#   なし
# 処理概要:
#   次の Stop hook が返信に使う宛先情報を JSON で保存する。
write_state() {
  local path="$1"
  local member="$2"
  local sender="$3"

  mkdir -p "$(dirname "$path")"
  jq -n \
    --arg member "$member" \
    --arg sender "$sender" \
    '{member: $member, sender: $sender, reply_type: "response"}' > "$path"
}

# 引数:
#   $1: state file path
# 戻り値:
#   stdout に sender を出力。無ければ空文字。
# 処理概要:
#   pending reply state から返信先を復元する。
read_sender_from_state() {
  local path="$1"
  jq -r '.sender // empty' "$path" 2>/dev/null || true
}

# 引数:
#   $1: repo root
# 戻り値:
#   stdout に Mailbox 送信スクリプトの path を出力。見つからなければ空文字。
# 処理概要:
#   Claude/Codex 共通で使う共有配置の送信スクリプトを探す。
resolve_send_script() {
  local repo_root="$1"
  local candidate

  for candidate in \
    "${repo_root}/.ai-team/scripts/send_mailbox_message.sh"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '\n'
}

input="$(cat)"
member="$(resolve_member)"
session_name="$(resolve_session_name)"
repo_root="$(resolve_repo_root "$(pwd)")"

if [[ -z "$member" ]] || [[ -z "$session_name" ]] || [[ -z "$repo_root" ]]; then
  exit 0
fi

state_file="$(state_file_path "$repo_root" "$session_name" "$member")"

case "$mode" in
  record-prompt)
    prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null || true)"
    if [[ -z "$prompt" ]] || ! is_mailbox_prompt "$prompt"; then
      exit 0
    fi

    sender="$(extract_sender "$prompt")"
    if [[ -z "$sender" ]]; then
      exit 0
    fi

    write_state "$state_file" "$member" "$sender"
    ;;
  flush-reply)
    if [[ ! -f "$state_file" ]]; then
      exit 0
    fi

    sender="$(read_sender_from_state "$state_file")"
    if [[ -z "$sender" ]]; then
      rm -f "$state_file"
      exit 0
    fi

    reply="$(printf '%s' "$input" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)"
    if [[ -z "$reply" ]]; then
      reply="完了した。"
    fi

    send_script="$(resolve_send_script "$repo_root")"
    if [[ -z "$send_script" ]]; then
      log "send_mailbox_message.sh not found"
      exit 0
    fi

    if "$send_script" \
      --member "$member" \
      --to "$sender" \
      --type response \
      --message "$reply" \
      --session-name "$session_name" \
      --repo-root "$repo_root" >/dev/null; then
      rm -f "$state_file"
    else
      log "failed to send mailbox reply from ${member} to ${sender}"
    fi
    ;;
  *)
    exit 0
    ;;
esac
