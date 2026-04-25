#!/usr/bin/env bats

# mailbox-bridge.bats - Tests for mailbox-bridge.sh
# Requires: bats-core, tmux, inotifywait

# bridge の E2E テスト用に Mailbox root と 4 ペインの tmux セッションを作る。
setup() {
  export MAILBOX_ROOT
  MAILBOX_ROOT="$(mktemp -d)"

  for member in alpha bravo charlie delta; do
    mkdir -p "${MAILBOX_ROOT}/${member}/inbox" "${MAILBOX_ROOT}/${member}/outbox"
  done

  export TEST_SESSION
  TEST_SESSION="bats-test-$$-${BATS_TEST_NUMBER}"
  tmux new-session -d -s "$TEST_SESSION" -x 200 -y 50
  tmux split-window -t "${TEST_SESSION}:0.0" -h
  tmux split-window -t "${TEST_SESSION}:0.0" -v
  tmux split-window -t "${TEST_SESSION}:0.1" -v

  export MEMBER_A_PANE="${TEST_SESSION}:0.0"
  export MEMBER_B_PANE="${TEST_SESSION}:0.1"
  export MEMBER_C_PANE="${TEST_SESSION}:0.2"
  export MEMBER_D_PANE="${TEST_SESSION}:0.3"

  export BRIDGE_SCRIPT
  BRIDGE_SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/mailbox-bridge.sh"

  export BRIDGE_PID=""
}

# bridge テスト後に bridge プロセス、tmux セッション、Mailbox root を掃除する。
teardown() {
  if [[ -n "$BRIDGE_PID" ]] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi

  tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
  rm -rf "$MAILBOX_ROOT"
}

# 任意の 4 人分のペイン対応ブリッジを起動する。
start_bridge() {
  bash "$BRIDGE_SCRIPT" \
    "$MAILBOX_ROOT" \
    "alpha:${MEMBER_A_PANE}" \
    "bravo:${MEMBER_B_PANE}" \
    "charlie:${MEMBER_C_PANE}" \
    "delta:${MEMBER_D_PANE}" &
  BRIDGE_PID=$!
  sleep 2
}

# ブリッジ経由で配信されたメッセージが tmux ペインへ到達するまで待機する。
wait_for_pane_content() {
  local pane="$1"
  local expected="$2"
  local timeout="${3:-20}"
  local elapsed=0

  while (( elapsed < timeout )); do
    local content
    content="$(tmux capture-pane -t "$pane" -p 2>/dev/null || true)"
    if [[ "$content" == *"$expected"* ]]; then
      return 0
    fi
    sleep 0.5
    elapsed=$((elapsed + 1))
  done

  echo "Timed out waiting for '$expected' in pane $pane" >&2
  tmux capture-pane -t "$pane" -p >&2 || true
  return 1
}

# 送信元メンバーの outbox に Mailbox メッセージを作成する。
write_message() {
  local from_member="$1"
  local to_member="$2"
  local filename="$3"
  local message_type="$4"
  local body="$5"

  local filepath="${MAILBOX_ROOT}/${from_member}/outbox/${filename}"

  {
    echo "---"
    echo "from: ${from_member}"
    echo "to: ${to_member}"
    echo "type: ${message_type}"
    echo "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "---"
    echo ""
    echo "$body"
  } > "$filepath"
}

@test "sender outbox message is routed to recipient pane and inbox" {
  start_bridge

  write_message "alpha" "delta" "20260412T100000.md" "request" "Implement the latest battle flow."

  wait_for_pane_content "$MEMBER_D_PANE" "[Mailbox]"
  wait_for_pane_content "$MEMBER_D_PANE" "From: alpha"
  wait_for_pane_content "$MEMBER_D_PANE" "Type: request"
  wait_for_pane_content "$MEMBER_D_PANE" "Implement the latest battle flow."

  local content
  content="$(tmux capture-pane -t "$MEMBER_D_PANE" -p)"

  local mailbox_line from_line type_line body_line
  mailbox_line="$(echo "$content" | grep -n '^\[Mailbox\]$' | head -1 | cut -d: -f1)"
  from_line="$(echo "$content" | grep -n '^From: alpha$' | head -1 | cut -d: -f1)"
  type_line="$(echo "$content" | grep -n '^Type: request$' | head -1 | cut -d: -f1)"
  body_line="$(echo "$content" | grep -n '^Implement the latest battle flow\.$' | head -1 | cut -d: -f1)"
  (( mailbox_line < from_line ))
  (( from_line < type_line ))
  (( type_line < body_line ))

  [ -f "${MAILBOX_ROOT}/delta/inbox/20260412T100000.md" ]
  grep -q "from: alpha" "${MAILBOX_ROOT}/delta/inbox/20260412T100000.md"
}

# シナリオ: bridge 起動前から outbox に存在するメッセージを回収する。
# 保証: 起動時スキャンで既存メッセージも宛先 pane へ配送される。
@test "pre-existing outbox message is delivered on startup" {
  write_message "charlie" "alpha" "20260412T100000.md" "response" "Review completed."

  start_bridge

  wait_for_pane_content "$MEMBER_A_PANE" "From: charlie"
  wait_for_pane_content "$MEMBER_A_PANE" "Review completed."
}

# シナリオ: 同一送信者の連続メッセージを時系列順に配送する。
# 保証: ファイル名順で 1 件目が 2 件目より先に pane へ現れる。
@test "bridge delivers messages in filename order for the same sender" {
  start_bridge

  write_message "alpha" "bravo" "20260412T100000.md" "request" "First consistency check."
  write_message "alpha" "bravo" "20260412T100001.md" "request" "Second consistency check."

  wait_for_pane_content "$MEMBER_B_PANE" "First consistency check."
  wait_for_pane_content "$MEMBER_B_PANE" "Second consistency check."

  local content
  content="$(tmux capture-pane -t "$MEMBER_B_PANE" -p)"

  local first_line second_line
  first_line="$(echo "$content" | grep -n "First consistency check." | head -1 | cut -d: -f1)"
  second_line="$(echo "$content" | grep -n "Second consistency check." | head -1 | cut -d: -f1)"

  (( first_line < second_line ))
}

# シナリオ: 宛先不明メッセージを bridge が拒否する。
# 保証: どの pane にも配送せず、warning ログだけが出力される。
@test "bridge warns and skips unknown recipient" {
  local log_file="${MAILBOX_ROOT}/bridge.log"
  bash "$BRIDGE_SCRIPT" \
    "$MAILBOX_ROOT" \
    "alpha:${MEMBER_A_PANE}" \
    "bravo:${MEMBER_B_PANE}" \
    "charlie:${MEMBER_C_PANE}" \
    "delta:${MEMBER_D_PANE}" \
    2>"$log_file" &
  BRIDGE_PID=$!
  sleep 1

  write_message "alpha" "echo" "20260412T100000.md" "question" "Are you there?"
  sleep 2

  ! grep -q "Are you there?" <(tmux capture-pane -t "$MEMBER_A_PANE" -p)
  ! grep -q "Are you there?" <(tmux capture-pane -t "$MEMBER_B_PANE" -p)
  ! grep -q "Are you there?" <(tmux capture-pane -t "$MEMBER_C_PANE" -p)
  ! grep -q "Are you there?" <(tmux capture-pane -t "$MEMBER_D_PANE" -p)
  local elapsed=0
  while (( elapsed < 10 )); do
    if grep -q "Unknown recipient" "$log_file"; then
      return 0
    fi
    sleep 0.5
    elapsed=$((elapsed + 1))
  done

  return 1
}

# シナリオ: ユーザーが特定ペインへ直接入力した内容は Mailbox 中継の対象にしない。
# 保証: bridge は outbox 監視にのみ反応し、直接入力だけでは mailbox ファイルも他ペイン配送も発生しない。
@test "direct user input does not write mailbox messages" {
  start_bridge

  tmux send-keys -t "$MEMBER_A_PANE" -l "Direct user message." Enter
  sleep 2

  ! grep -q "Direct user message." <(tmux capture-pane -t "$MEMBER_B_PANE" -p)
  ! grep -q "Direct user message." <(tmux capture-pane -t "$MEMBER_C_PANE" -p)
  ! grep -q "Direct user message." <(tmux capture-pane -t "$MEMBER_D_PANE" -p)

  local message_count
  message_count="$(find "${MAILBOX_ROOT}" -type f -name '*.md' | wc -l | tr -d ' ')"
  [ "$message_count" -eq 0 ]
}

# シナリオ: bridge が Codex/Claude の composer へ Mailbox メッセージを配送する。
# 保証: 本文は `send-keys -l` で送り、送信確定は別 invocation の `Enter` で行い、paste-buffer は使わない。
# シナリオ: SIGTERM でブリッジを停止したとき、配下の inotifywait と while ループも終了する。
# 保証: bridge プロセス停止後、子孫プロセスが孤児として残らない。
@test "bridge cleanup terminates all descendant processes on shutdown" {
  start_bridge

  local descendant_pids
  descendant_pids="$(pgrep -P "$BRIDGE_PID" 2>/dev/null || true)"
  [ -n "$descendant_pids" ]

  local grandchild_pids=""
  local pid
  for pid in $descendant_pids; do
    local children
    children="$(pgrep -P "$pid" 2>/dev/null || true)"
    if [ -n "$children" ]; then
      grandchild_pids+=" $children"
    fi
  done

  kill -TERM "$BRIDGE_PID"
  wait "$BRIDGE_PID" 2>/dev/null || true
  BRIDGE_PID=""

  local elapsed=0
  local survivors
  while (( elapsed < 10 )); do
    survivors=""
    for pid in $descendant_pids $grandchild_pids; do
      if kill -0 "$pid" 2>/dev/null; then
        survivors+=" $pid"
      fi
    done
    if [ -z "$survivors" ]; then
      return 0
    fi
    sleep 0.5
    elapsed=$((elapsed + 1))
  done

  echo "Surviving descendants after bridge shutdown:$survivors" >&2
  return 1
}

@test "bridge sends mailbox text literally and submits in a separate invocation" {
  local fake_bin="${MAILBOX_ROOT}/fake-bin"
  local fake_tmux_log="${MAILBOX_ROOT}/fake-tmux.log"
  mkdir -p "$fake_bin"

  cat > "${fake_bin}/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "\$*" >> "${fake_tmux_log}"
if [[ "\$1" == "list-panes" ]]; then
  exit 0
fi
exit 0
EOF
  chmod +x "${fake_bin}/tmux"

  cat > "${fake_bin}/inotifywait" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
  chmod +x "${fake_bin}/inotifywait"

  write_message "alpha" "bravo" "20260412T100000.md" "request" "Literal submit check."

  env PATH="${fake_bin}:$PATH" bash "$BRIDGE_SCRIPT" \
    "$MAILBOX_ROOT" \
    "alpha:${MEMBER_A_PANE}" \
    "bravo:${MEMBER_B_PANE}" &
  BRIDGE_PID=$!
  sleep 1

  grep -Fq "send-keys -t ${MEMBER_B_PANE} -l [Mailbox]" "$fake_tmux_log"
  grep -Fq "send-keys -t ${MEMBER_B_PANE} Enter" "$fake_tmux_log"
  ! grep -Fq "set-buffer" "$fake_tmux_log"
  ! grep -Fq "paste-buffer" "$fake_tmux_log"
}
