#!/usr/bin/env bash
set -euo pipefail

# Args:
#   $1: `--resume` の場合は復旧モードを表すフラグ。
#   $2: エージェント構成 JSON ファイルのパス。
#   $3: レイアウト定義 JSON ファイルのパス。復旧モードでは省略可能。
# Returns:
#   0: 起動または復旧成功。
#   非 0: 引数不足、設定ファイル不備、状態ファイル不備、または依存スクリプト失敗。
# Overview:
#   1. 通常起動では mailbox 初期化、layout 適用、pane 保存を行う。
#   2. start/resume どちらも session-management へエージェント起動を委譲する。
#   3. bridge の起動状態を整えて team セッションを利用可能にする。

die() {
    # Args:
    #   $*: 標準エラーへ出力するメッセージ。
    # Returns:
    #   なし。標準エラー出力後に終了コード 1 で終了する。
    # Overview:
    #   runtime に必要な前提が崩れたときに処理を中断する。
    echo "[team-start-runtime] Error: $*" >&2
    exit 1
}

wait_for_file() {
    # Args:
    #   $1: 出現を待つファイルパス。
    #   $2: 最大待機回数。
    # Returns:
    #   0: 期限内にファイルが作成された。
    #   非 0: 期限内に作成されなかった。
    # Overview:
    #   短いポーリングで非同期起動後の PID ファイル生成を待つ。
    local target_path="$1"
    local max_attempts="$2"
    local attempt=0

    while [ "$attempt" -lt "$max_attempts" ]; do
        if [ -f "$target_path" ]; then
            return 0
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done

    return 1
}

shell_quote() {
    # Args:
    #   $1: シェル引数として安全に埋め込みたい文字列。
    # Returns:
    #   標準出力: POSIX shell で再利用できる quoted 文字列。
    # Overview:
    #   bridge 起動コマンドの組み立てで安全な引数表現を使う。
    printf '%q' "$1"
}

pane_env_name_for_member() {
    # Args:
    #   $1: メンバー ID。
    # Returns:
    #   標準出力: `FOO_PANE` 形式の環境変数名。
    # Overview:
    #   メンバー ID を大文字化して pane 保存用の変数名へ変換する。
    local member="$1"

    printf '%s_PANE' "$(printf '%s' "$member" | tr '[:lower:]' '[:upper:]')"
}

validate_agents_config() {
    # Args:
    #   なし。
    # Returns:
    #   0: agents 構成検証成功。
    #   非 0: 不備検出時は die() で終了。
    # Overview:
    #   1. members 配列と member 文字列を確認する。
    #   2. leader 数と member 重複を検証する。
    #   3. 全メンバーの暗黙 role prompt が存在することを確認する。
    if ! jq -e '.members | type == "array" and length > 0' "$agents_config_path" >/dev/null; then
        die "Agents config must contain a non-empty members array"
    fi

    if ! jq -e '.members | all(.member? != null and (.member | type == "string") and (.member | length > 0))' "$agents_config_path" >/dev/null; then
        die "Each agent entry must contain a non-empty string member"
    fi

    local leader_count
    leader_count="$(jq '[.members[] | select(.leader == true)] | length' "$agents_config_path")"
    if [ "$leader_count" -ne 1 ]; then
        die "Agents config must contain exactly one leader"
    fi

    local member_count
    local unique_member_count
    member_count="$(jq '.members | length' "$agents_config_path")"
    unique_member_count="$(jq '[.members[].member] | unique | length' "$agents_config_path")"
    if [ "$member_count" -ne "$unique_member_count" ]; then
        die "Agents config contains duplicate member IDs"
    fi

    local member
    while IFS= read -r member; do
        local prompt_path
        prompt_path=".ai-team/prompts/${member}.md"
        if [ ! -f "$prompt_path" ]; then
            die "Prompt file not found for member ${member}: ${prompt_path}"
        fi
    done < <(jq -r '.members[].member' "$agents_config_path")
}

validate_layout_config() {
    # Args:
    #   なし。
    # Returns:
    #   0: layout 構成検証成功。
    #   非 0: 不備検出時は die() で終了。
    # Overview:
    #   1. layout 配列の基本形を確認する。
    #   2. agents と同じ member 集合であることを検証する。
    if [ ! -f "$layout_config_path" ]; then
        die "Layout config not found: $layout_config_path"
    fi

    if ! jq -e 'type == "array" and length > 0' "$layout_config_path" >/dev/null; then
        die "Layout config must be a non-empty array"
    fi

    if ! jq -e 'all(.member? != null and (.member | type == "string") and (.member | length > 0) and .group_id? != null and .position? != null and (has("pane_id") | not))' "$layout_config_path" >/dev/null; then
        die "Each layout entry must contain member, group_id, and position only (pane_id is resolved by runtime)"
    fi

    local agents_members_json
    local layout_members_json
    agents_members_json="$(jq -c '[.members[].member] | sort' "$agents_config_path")"
    layout_members_json="$(jq -c '[.[].member] | sort' "$layout_config_path")"
    if [ "$agents_members_json" != "$layout_members_json" ]; then
        die "Agents config and layout config must contain the same member set"
    fi
}

layout_input_json() {
    # Args:
    #   なし。
    # Returns:
    #   標準出力: apply-layout.sh に渡す JSON。
    # Overview:
    #   1. layout JSON の `member` を落とす。
    #   2. leader の行は現在の pane ID を、非 leader は null の pane_id を設定する。
    jq --arg leader "$LEADER_MEMBER" --arg leader_pane "$TMUX_PANE" '
        map({
            group_id,
            pane_id: (if .member == $leader then $leader_pane else null end),
            position
        })
    ' "$layout_config_path"
}

window_id_for_group() {
    # Args:
    #   $1: group_id。
    # Returns:
    #   標準出力: 対応する tmux window_id。
    # Overview:
    #   layout の group_id と現在の window 順を対応付けて window_id を解決する。
    local target_group_id="$1"
    local group_ids=()
    local window_ids=()
    local index=0

    while IFS= read -r value; do
        [ -n "$value" ] && group_ids+=("$value")
    done < <(jq -r '[.[].group_id] | unique | sort | .[]' "$layout_config_path")

    while IFS= read -r value; do
        [ -n "$value" ] && window_ids+=("$value")
    done < <(tmux list-windows -t "$SESSION_NAME" -F '#{window_id}')

    for index in "${!group_ids[@]}"; do
        if [ "${group_ids[$index]}" = "$target_group_id" ]; then
            printf '%s\n' "${window_ids[$index]}"
            return 0
        fi
    done

    return 1
}

pane_id_for_member_from_layout() {
    # Args:
    #   $1: メンバー ID。
    # Returns:
    #   標準出力: メンバーに対応する pane ID。
    # Overview:
    #   1. layout JSON から member の group_id と position を引く。
    #   2. group_id から window_id を解決する。
    #   3. apply-layout の結果 JSON から pane ID を取得する。
    local member="$1"
    local group_id
    local position
    local window_id

    group_id="$(jq -r --arg member "$member" '.[] | select(.member == $member) | .group_id' "$layout_config_path")"
    position="$(jq -r --arg member "$member" '.[] | select(.member == $member) | .position' "$layout_config_path")"
    window_id="$(window_id_for_group "$group_id")"

    jq -r --arg window_id "$window_id" --arg position "$position" \
        '.[$window_id][] | select(.position == $position) | .pane_id' <<< "$LAYOUT_RESULT_JSON"
}

write_panes_env() {
    # Args:
    #   なし。
    # Returns:
    #   なし。
    # Overview:
    #   1. 全メンバーの pane ID を保存する。
    #   2. leader 以外のメンバー一覧も stop 用に保存する。
    local teammate_members=""
    local member

    {
        echo "TEAM_MEMBERS=\"${ALL_MEMBERS[*]}\""
        for member in "${ALL_MEMBERS[@]}"; do
            local pane_env_name
            pane_env_name="$(pane_env_name_for_member "$member")"
            printf '%s=%s\n' "$pane_env_name" "${PANE_IDS_BY_MEMBER[$member]}"
            if [ "$member" != "$LEADER_MEMBER" ]; then
                if [ -n "$teammate_members" ]; then
                    teammate_members+=" "
                fi
                teammate_members+="$member"
            fi
        done
        echo "TEAMMATE_MEMBERS=\"${teammate_members}\""
    } > "${STATE_DIR}/panes.env"
}

load_panes_from_state() {
    # Args:
    #   なし。
    # Returns:
    #   0: 保存済み panes.env の読込成功。
    #   非 0: 必須項目が欠けている場合は die() で終了。
    # Overview:
    #   1. panes.env を source して保存済み pane 情報を読む。
    #   2. TEAM_MEMBERS と各 `*_PANE` を連想配列へ復元する。
    if [ ! -f "$PANES_FILE" ]; then
        die "Saved panes state not found: $PANES_FILE"
    fi

    set -a
    # shellcheck disable=SC1090
    source "$PANES_FILE"
    set +a

    read -r -a ALL_MEMBERS <<< "${TEAM_MEMBERS:-}"
    if [ "${#ALL_MEMBERS[@]}" -eq 0 ]; then
        die "Saved panes state must contain TEAM_MEMBERS"
    fi

    local member
    for member in "${ALL_MEMBERS[@]}"; do
        local pane_env_name
        pane_env_name="$(pane_env_name_for_member "$member")"
        if [ -z "${!pane_env_name:-}" ]; then
            die "Saved panes state is missing pane ID for member: $member"
        fi
        PANE_IDS_BY_MEMBER["$member"]="${!pane_env_name}"
    done
}

pane_map_json_from_state() {
    # Args:
    #   なし。グローバル配列 ALL_MEMBERS と連想配列 PANE_IDS_BY_MEMBER を使う。
    # Returns:
    #   標準出力: session-management へ渡す pane_map JSON。
    # Overview:
    #   連想配列に保持した member -> pane_id を JSON オブジェクトへ変換する。
    local pane_map='{}'
    local member

    for member in "${ALL_MEMBERS[@]}"; do
        pane_map="$(jq --arg member "$member" --arg pane_id "${PANE_IDS_BY_MEMBER[$member]}" '. + {($member): $pane_id}' <<< "$pane_map")"
    done

    printf '%s\n' "$pane_map"
}

run_session_management_script() {
    # Args:
    #   $1: 実行する session-management スクリプトのパス。
    # Returns:
    #   0: 実行成功かつ failed が 0 件。
    #   非 0: 依存スクリプト不在、実行失敗、または failed メンバーあり。
    # Overview:
    #   1. agents_config ファイル内容と pane_map JSON を session-management へ渡す。
    #   2. 返ってきた結果 JSON の failed 配列を見て runtime 失敗可否を決める。
    local script_path="$1"
    local agents_json
    local pane_map_json
    local failed_members
    local result_json

    if [ ! -x "$script_path" ]; then
        die "Required session-management script not found: $script_path"
    fi

    agents_json="$(cat "$agents_config_path")"
    pane_map_json="$(pane_map_json_from_state)"
    result_json="$(bash "$script_path" "$agents_json" "$pane_map_json")"
    failed_members="$(jq -r '.failed | join(",")' <<< "$result_json")"

    if [ -n "$failed_members" ]; then
        die "Session management reported failed members: $failed_members"
    fi
}

bridge_is_running() {
    # Args:
    #   なし。
    # Returns:
    #   0: bridge.pid が存在し、対象プロセスが生存している。
    #   1: PID ファイル不在またはプロセス停止済み。
    # Overview:
    #   既存 bridge を再利用できるかどうかを PID ベースで判定する。
    if [ ! -f "$BRIDGE_PID_FILE" ]; then
        return 1
    fi

    local bridge_pid
    bridge_pid="$(cat "$BRIDGE_PID_FILE")"
    kill -0 "$bridge_pid" 2>/dev/null
}

start_bridge_detached() {
    # Args:
    #   なし。
    # Returns:
    #   0: bridge 起動に成功。
    #   非 0: PID ファイル生成失敗。
    # Overview:
    #   1. setsid で bridge を新セッションへ切り離して起動する。
    #   2. 起動シェルが pid_file へ自身の PID を記録してから bridge へ exec する。
    #   3. PID ファイル生成を短時間待って起動完了を判定する。
    local bridge_command
    local mapping

    bridge_command="echo \$\$ > $(shell_quote "$BRIDGE_PID_FILE"); exec bash $(shell_quote ".ai-team/scripts/mailbox-bridge.sh") $(shell_quote "$MAILBOX_ROOT")"
    for mapping in "${BRIDGE_MAPPINGS[@]}"; do
        bridge_command+=" $(shell_quote "$mapping")"
    done
    bridge_command+=" > $(shell_quote "$BRIDGE_LOG_FILE") 2>&1"

    rm -f "$BRIDGE_PID_FILE"
    setsid bash -c "$bridge_command" </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true

    if ! wait_for_file "$BRIDGE_PID_FILE" 20; then
        die "Bridge PID file was not created"
    fi
}

prepare_bridge_mappings() {
    # Args:
    #   なし。
    # Returns:
    #   なし。
    # Overview:
    #   agents_config の `bridge == true` なメンバーだけを `member:pane_id` 形式へ変換する。
    local member

    BRIDGE_MAPPINGS=()
    while IFS= read -r member; do
        [ -z "$member" ] && continue
        BRIDGE_MAPPINGS+=("${member}:${PANE_IDS_BY_MEMBER[$member]}")
    done < <(jq -r '.members[] | select(.bridge == true) | .member' "$agents_config_path")
}

start_mode() {
    # Args:
    #   なし。
    # Returns:
    #   0: 通常起動成功。
    #   非 0: 前提不備または依存処理失敗。
    # Overview:
    #   1. mailbox 初期化と layout 適用を行う。
    #   2. pane_map を解決して保存する。
    #   3. session-management へ teammate 起動を委譲し、bridge を起動する。
    local member
    local mailbox_members=()

    if [ -z "${TMUX_PANE:-}" ]; then
        die "TMUX_PANE is required for startup"
    fi

    validate_layout_config
    PANE_IDS_BY_MEMBER["$LEADER_MEMBER"]="$TMUX_PANE"

    while IFS= read -r member; do
        [ -n "$member" ] && mailbox_members+=("$member")
    done < <(jq -r '.members[] | select(.mailbox == true) | .member' "$agents_config_path")

    bash .ai-team/scripts/mailbox-init.sh "${mailbox_members[@]}"
    LAYOUT_RESULT_JSON="$(bash .ai-team/scripts/apply-layout.sh "$(layout_input_json)" "$SESSION_NAME")"

    while IFS= read -r member; do
        [ -z "$member" ] && continue
        if [ "$member" = "$LEADER_MEMBER" ]; then
            continue
        fi
        PANE_IDS_BY_MEMBER["$member"]="$(pane_id_for_member_from_layout "$member")"
        if [ -z "${PANE_IDS_BY_MEMBER[$member]}" ] || [ "${PANE_IDS_BY_MEMBER[$member]}" = "null" ]; then
            die "Could not resolve pane ID for member: $member"
        fi
    done < <(jq -r '.members[] | .member' "$agents_config_path")

    write_panes_env
    run_session_management_script ".ai-team/scripts/start-agents.sh"
    prepare_bridge_mappings
    start_bridge_detached
}

resume_mode() {
    # Args:
    #   なし。
    # Returns:
    #   0: 復旧成功。
    #   非 0: 保存済み state 不備または依存処理失敗。
    # Overview:
    #   1. panes.env から pane_map を復元する。
    #   2. session-management へ resume を委譲する。
    #   3. bridge が停止していれば再起動する。
    load_panes_from_state
    run_session_management_script ".ai-team/scripts/resume-agents.sh"
    prepare_bridge_mappings

    if ! bridge_is_running; then
        start_bridge_detached
    fi
}

MODE="start"

if [ "${1:-}" = "--resume" ]; then
    MODE="resume"
    shift
fi

if [ "$MODE" = "start" ]; then
    if [ "$#" -ne 2 ]; then
        echo "Usage: team-start-runtime.sh <agents_config_path> <layout_config_path>" >&2
        exit 1
    fi
else
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        echo "Usage: team-start-runtime.sh --resume <agents_config_path> [layout_config_path]" >&2
        exit 1
    fi
fi

agents_config_path="$1"
layout_config_path="${2:-}"

if [ ! -f "$agents_config_path" ]; then
    echo "Agents config not found: $agents_config_path" >&2
    exit 1
fi

SESSION_NAME="$(tmux display-message -p '#{session_name}')"
STATE_DIR=".ai-team/${SESSION_NAME}"
PANES_FILE="${STATE_DIR}/panes.env"
MAILBOX_ROOT="${STATE_DIR}/mailbox"
BRIDGE_PID_FILE="${STATE_DIR}/bridge.pid"
BRIDGE_LOG_FILE="${STATE_DIR}/bridge.log"

mkdir -p "$STATE_DIR"

declare -a ALL_MEMBERS=()
declare -a BRIDGE_MAPPINGS=()
declare -A PANE_IDS_BY_MEMBER=()

validate_agents_config
LEADER_MEMBER="$(jq -r '.members[] | select(.leader == true) | .member' "$agents_config_path")"

while IFS= read -r member; do
    [ -n "$member" ] && ALL_MEMBERS+=("$member")
done < <(jq -r '.members[].member' "$agents_config_path")

if [ "$MODE" = "start" ]; then
    start_mode
else
    resume_mode
fi
