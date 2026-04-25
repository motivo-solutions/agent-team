#!/usr/bin/env bash
set -euo pipefail

# 各メンバーの outbox を監視し、宛先ペインへ Mailbox メッセージを配送する。
# Usage: mailbox-bridge.sh <mailbox_root> <member:pane> [<member:pane> ...]

MAILBOX_ROOT="${1:?Usage: mailbox-bridge.sh <mailbox_root> <member:pane> [<member:pane> ...]}"
shift

if [ $# -lt 2 ]; then
  echo "[mailbox-bridge] Error: at least two member:pane mappings are required" >&2
  exit 1
fi

declare -A MEMBER_TO_PANE=()
declare -A WATCHER_PID_BY_MEMBER=()
declare -A PROCESSED_FILES=()

validate_member_name() {
  local member="$1"

  if [[ -z "$member" ]] || [[ "$member" == *".."* ]] || [[ "$member" == *"/"* ]]; then
    echo "[mailbox-bridge] Error: invalid member name: $member" >&2
    exit 1
  fi
}

validate_panes() {
  local member
  for member in "${!MEMBER_TO_PANE[@]}"; do
    if ! tmux list-panes -t "${MEMBER_TO_PANE[$member]}" &>/dev/null; then
      echo "[mailbox-bridge] Error: pane for ${member} does not exist: ${MEMBER_TO_PANE[$member]}" >&2
      exit 1
    fi
  done
}

send_to_pane() {
  # Args:
  #   $1: 配送先 pane ID。
  #   $2: pane に貼り付けるメッセージ本文。
  # Returns:
  #   なし。
  # Overview:
  #   1. 複数行メッセージを `send-keys -l` でそのまま入力する。
  #   2. composer が入力を取り込むまで短く待つ。
  #   3. 別 invocation の Enter で送信を確定する。
  local target_pane="$1"
  local text="$2"

  # 即座に Enter を送ると改行扱いになる TUI があるため、本文入力後に短く待つ。
  tmux send-keys -t "$target_pane" -l "$text"
  sleep 0.3
  tmux send-keys -t "$target_pane" Enter
}

parse_message() {
  local filepath="$1"

  MSG_FROM=""
  MSG_TO=""
  MSG_TYPE=""
  MSG_BODY=""

  local in_frontmatter=false
  local frontmatter_done=false
  local body_lines=()

  while IFS= read -r line; do
    if [[ "$frontmatter_done" == false ]]; then
      if [[ "$line" == "---" ]]; then
        if [[ "$in_frontmatter" == true ]]; then
          frontmatter_done=true
        else
          in_frontmatter=true
        fi
        continue
      fi

      if [[ "$in_frontmatter" == true ]]; then
        if [[ "$line" =~ ^from:\ *(.*) ]]; then
          MSG_FROM="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^to:\ *(.*) ]]; then
          MSG_TO="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^type:\ *(.*) ]]; then
          MSG_TYPE="${BASH_REMATCH[1]}"
        fi
      fi
    else
      body_lines+=("$line")
    fi
  done < "$filepath"

  local body_started=false
  local line
  for line in "${body_lines[@]}"; do
    if [[ "$body_started" == false ]] && [[ -z "$line" ]]; then
      continue
    fi

    body_started=true
    if [[ -n "$MSG_BODY" ]]; then
      MSG_BODY+=$'\n'
    fi
    MSG_BODY+="$line"
  done
}

format_for_pane() {
  local output=""

  output+="[Mailbox]"$'\n'
  output+="From: ${MSG_FROM}"$'\n'
  output+="Type: ${MSG_TYPE}"$'\n'
  output+=$'\n'
  output+="${MSG_BODY}"

  printf '%s' "$output"
}

copy_to_inbox() {
  local source_path="$1"
  local target_member="$2"
  local target_dir="${MAILBOX_ROOT}/${target_member}/inbox"

  mkdir -p "$target_dir"
  cp "$source_path" "${target_dir}/$(basename "$source_path")"
}

handle_outbox_file() {
  local member="$1"
  local filepath="$2"
  local filename
  filename="$(basename "$filepath")"

  PROCESSED_FILES["${member}:${filename}"]=1

  # 書き込み直後のファイルを扱うため、短時間だけ待ってから読む。
  sleep 0.1
  parse_message "$filepath"

  if [[ -z "$MSG_FROM" ]] || [[ -z "$MSG_TO" ]] || [[ -z "$MSG_TYPE" ]]; then
    echo "[mailbox-bridge] Warning: missing required frontmatter in ${filepath}" >&2
    return
  fi

  if [[ -z "${MEMBER_TO_PANE[$MSG_TO]+x}" ]]; then
    echo "[mailbox-bridge] Warning: Unknown recipient '${MSG_TO}' in ${filepath}" >&2
    return
  fi

  copy_to_inbox "$filepath" "$MSG_TO"
  send_to_pane "${MEMBER_TO_PANE[$MSG_TO]}" "$(format_for_pane)"
}

process_existing_files() {
  local member="$1"
  local outbox_dir="${MAILBOX_ROOT}/${member}/outbox"
  local files=()

  while IFS= read -r -d '' filepath; do
    files+=("$filepath")
  done < <(find "$outbox_dir" -maxdepth 1 -name '*.md' -print0 2>/dev/null | sort -z)

  local filepath
  for filepath in "${files[@]}"; do
    handle_outbox_file "$member" "$filepath"
  done
}

start_watchers() {
  local combined_fifo="$1"
  local member

  for member in "${!MEMBER_TO_PANE[@]}"; do
    local outbox_dir="${MAILBOX_ROOT}/${member}/outbox"
    mkdir -p "$outbox_dir"

    # メンバーごとの監視結果を 1 本の FIFO に集約する。
    (
      inotifywait -m -e close_write -e moved_to --format '%f' "$outbox_dir" 2>/dev/null |
      while IFS= read -r filename; do
        printf '%s %s\n' "$member" "$filename"
      done
    ) > "$combined_fifo" &

    WATCHER_PID_BY_MEMBER["$member"]=$!
  done
}

cleanup() {
  local member
  for member in "${!WATCHER_PID_BY_MEMBER[@]}"; do
    local pid="${WATCHER_PID_BY_MEMBER[$member]}"
    # ラッパーサブシェル配下の inotifywait / while ループも明示的に終了させる
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done

  if [[ -n "${COMBINED_FIFO:-}" ]]; then
    rm -f "$COMBINED_FIFO"
  fi
}

main() {
  local mapping
  for mapping in "$@"; do
    if [[ "$mapping" != *:* ]]; then
      echo "[mailbox-bridge] Error: invalid mapping: $mapping" >&2
      exit 1
    fi

    local member="${mapping%%:*}"
    local pane="${mapping#*:}"

    validate_member_name "$member"
    MEMBER_TO_PANE["$member"]="$pane"
    mkdir -p "${MAILBOX_ROOT}/${member}/inbox" "${MAILBOX_ROOT}/${member}/outbox"
  done

  validate_panes

  COMBINED_FIFO="$(mktemp -u)"
  mkfifo "$COMBINED_FIFO"
  trap cleanup EXIT

  start_watchers "$COMBINED_FIFO"

  local member
  for member in "${!MEMBER_TO_PANE[@]}"; do
    process_existing_files "$member"
  done

  while IFS= read -r event; do
    local event_member="${event%% *}"
    local filename="${event#* }"
    local file_key="${event_member}:${filename}"

    if [[ -n "${PROCESSED_FILES[$file_key]+x}" ]]; then
      continue
    fi

    if [[ "$filename" == *.md ]]; then
      handle_outbox_file "$event_member" "${MAILBOX_ROOT}/${event_member}/outbox/${filename}"
    fi
  done < "$COMBINED_FIFO"
}

main "$@"
