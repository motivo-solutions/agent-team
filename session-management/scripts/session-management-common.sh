#!/usr/bin/env bash
set -euo pipefail

die() {
    # Args:
    #   $*: 標準エラーへ出力するメッセージ。
    # Returns:
    #   なし。メッセージ出力後に終了コード 1 で終了する。
    # Overview:
    #   session-management の前提条件や入力検証に失敗したときに処理を中断する。
    echo "[session-management] Error: $*" >&2
    exit 1
}

read_json_input() {
    # Args:
    #   $1: JSON 文字列、または JSON を含むファイルパス。
    # Returns:
    #   標準出力: 正規化前の JSON テキスト。
    # Overview:
    #   1. 実在するファイルパスならその内容を読む。
    #   2. それ以外は引数値をそのまま JSON テキストとして扱う。
    local input_value="$1"

    if [ -f "$input_value" ]; then
        cat "$input_value"
        return 0
    fi

    printf '%s\n' "$input_value"
}

shell_quote() {
    # Args:
    #   $1: シェル引数として安全に埋め込みたい文字列。
    # Returns:
    #   標準出力: POSIX shell で再利用できる quoted 文字列。
    # Overview:
    #   tmux 先のシェルへ送るコマンド文字列を安全に組み立てる。
    printf '%q' "$1"
}

json_array_from_args() {
    # Args:
    #   $@: JSON 配列へ変換したい要素列。
    # Returns:
    #   標準出力: 引数列を JSON 配列へ変換した文字列。
    # Overview:
    #   1. 要素が 0 件なら空配列を返す。
    #   2. 要素がある場合は順序を保ったまま JSON 配列へ変換する。
    if [ "$#" -eq 0 ]; then
        printf '[]\n'
        return 0
    fi

    printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

emit_result_json() {
    # Args:
    #   なし。グローバル配列 STARTED_MEMBERS / RESUMED_MEMBERS / KEPT_MEMBERS / SKIPPED_MEMBERS / FAILED_MEMBERS を使う。
    # Returns:
    #   標準出力: 仕様書で定めた結果 JSON。
    # Overview:
    #   Bash 配列で収集したメンバー分類を 1 個の JSON オブジェクトへ整形する。
    jq -nc \
        --argjson started "$(json_array_from_args "${STARTED_MEMBERS[@]}")" \
        --argjson resumed "$(json_array_from_args "${RESUMED_MEMBERS[@]}")" \
        --argjson kept "$(json_array_from_args "${KEPT_MEMBERS[@]}")" \
        --argjson skipped "$(json_array_from_args "${SKIPPED_MEMBERS[@]}")" \
        --argjson failed "$(json_array_from_args "${FAILED_MEMBERS[@]}")" \
        '{
            started: $started,
            resumed: $resumed,
            kept: $kept,
            skipped: $skipped,
            failed: $failed
        }'
}

send_literal_command() {
    # Args:
    #   $1: コマンド送信先 pane ID。
    #   $2: literal に入力するコマンド文字列。
    # Returns:
    #   0: 送信成功。
    #   非 0: tmux への送信失敗。
    # Overview:
    #   1. `send-keys -l` で文字列をそのまま入力する。
    #   2. 少し待ってから Enter を別 invocation で送る。
    local target_pane="$1"
    local command_text="$2"

    if ! tmux send-keys -t "$target_pane" -l "$command_text"; then
        return 1
    fi

    # 長い入力でも取りこぼしにくいよう、送信確定を少し遅らせる。
    sleep 0.3
    tmux send-keys -t "$target_pane" Enter
}

current_tmux_session_name() {
    # Args:
    #   なし。
    # Returns:
    #   標準出力: 現在の tmux session 名。取得できない場合は空文字。
    # Overview:
    #   セッション名が取得できるときだけ内部状態ファイルの保存先解決に使う。
    tmux display-message -p '#{session_name}' 2>/dev/null || true
}

project_root_dir() {
    # Args:
    #   なし。必要に応じて環境変数 `SESSION_MANAGEMENT_PROJECT_ROOT` を参照する。
    # Returns:
    #   標準出力: session-management の状態保存先に使う project root。
    # Overview:
    #   1. 呼び出し側が解決済みの root を渡した場合はそれを優先する。
    #   2. そうでなければ現在ディレクトリから `.git` / `.agents` / `.claude` / `.codex` を遡って探す。
    #   3. 見つからない場合でも現在ディレクトリを project root とみなして継続する。
    local current_dir

    if [ -n "${SESSION_MANAGEMENT_PROJECT_ROOT:-}" ]; then
        printf '%s\n' "${SESSION_MANAGEMENT_PROJECT_ROOT}"
        return 0
    fi

    current_dir="$(pwd -P)"
    while [ "$current_dir" != "/" ]; do
        if [ -d "${current_dir}/.git" ] || [ -d "${current_dir}/.agents" ] || [ -d "${current_dir}/.claude" ] || [ -d "${current_dir}/.codex" ]; then
            printf '%s\n' "$current_dir"
            return 0
        fi

        current_dir="$(dirname "$current_dir")"
    done

    printf '%s\n' "$(pwd -P)"
}

session_state_file_path() {
    # Args:
    #   なし。
    # Returns:
    #   標準出力: 生成対象の状態ファイルパス。session 名を解決できない場合は空文字。
    # Overview:
    #   project root 配下の `.ai-team/<session>/agent-sessions.json` を返し、各 CLI の resume 用 session ID 読み出しに使う。
    local session_name
    local project_root

    session_name="$(current_tmux_session_name)"
    if [ -z "$session_name" ]; then
        printf '\n'
        return 0
    fi

    project_root="$(project_root_dir)"
    printf '%s/.ai-team/%s/agent-sessions.json\n' "$project_root" "$session_name"
}

load_member_session_value() {
    # Args:
    #   $1: メンバー ID。
    #   $2: 読み出すキー名。
    # Returns:
    #   標準出力: 保存済み値。未保存なら空文字。
    # Overview:
    #   SessionStart hook が保存した値を resume 用に読み出す。
    local member="$1"
    local session_key="$2"
    local state_file

    state_file="$(session_state_file_path)"
    if [ -z "$state_file" ] || [ ! -f "$state_file" ]; then
        printf '\n'
        return 0
    fi

    jq -r --arg member "$member" --arg session_key "$session_key" '.members[$member][$session_key] // empty' "$state_file"
}

load_claude_session_id() {
    # Args:
    #   $1: メンバー ID。
    # Returns:
    #   標準出力: 保存済み Claude session ID。未保存なら空文字。
    # Overview:
    #   SessionStart hook が保存した Claude session ID を resume 用に読み出す。
    load_member_session_value "$1" "claude_session_id"
}

load_codex_session_id() {
    # Args:
    #   $1: メンバー ID。
    # Returns:
    #   標準出力: 保存済み Codex thread ID。未保存なら空文字。
    # Overview:
    #   SessionStart hook が保存した Codex thread ID を resume 用に読み出す。
    load_member_session_value "$1" "codex_session_id"
}

validate_agents_config_json() {
    # Args:
    #   なし。グローバル変数 AGENTS_CONFIG_JSON を使う。
    # Returns:
    #   0: 構成検証成功。
    #   非 0: 不備検出時は die() で終了。
    # Overview:
    #   1. members 配列の存在と member 文字列を確認する。
    #   2. launcher があるメンバーは provider ごとの項目型が正しいことを検証する。
    if ! jq -e '.members | type == "array" and length > 0' <<< "$AGENTS_CONFIG_JSON" >/dev/null; then
        die "Agents config must contain a non-empty members array"
    fi

    if ! jq -e '.members | all(.member? != null and (.member | type == "string") and (.member | length > 0))' <<< "$AGENTS_CONFIG_JSON" >/dev/null; then
        die "Each agent entry must contain a non-empty string member"
    fi

    if ! jq -e '
        .members
        | all(
            if .launcher? == null then
                true
            else
                .launcher
                | type == "object"
                and .cli? != null
                and (.cli == "claude" or .cli == "codex")
                and (
                    .model? == null
                    or (.model | type == "string")
                )
                and (
                    .think_mode? == null
                    or (.think_mode | type == "string")
                )
                and (
                    if .cli == "claude" then
                        (
                            .permission_mode? == null
                            or (.permission_mode | type == "string")
                        )
                        and (.sandbox? == null)
                        and (.approval_policy? == null)
                    else
                        (
                            .sandbox? == null
                            or (.sandbox | type == "string")
                        )
                        and (
                            .approval_policy? == null
                            or (.approval_policy | type == "string")
                        )
                        and (.permission_mode? == null)
                    end
                )
            end
        )
    ' <<< "$AGENTS_CONFIG_JSON" >/dev/null; then
        die "Each agent entry must use a valid launcher object"
    fi
}

validate_pane_map_json() {
    # Args:
    #   なし。グローバル変数 PANE_MAP_JSON を使う。
    # Returns:
    #   0: pane_map 検証成功。
    #   非 0: 不備検出時は die() で終了。
    # Overview:
    #   1. pane_map がオブジェクトであることを確認する。
    #   2. launcher を持つメンバーに pane_id が解決できることを確認する。
    #   3. agents_config に含まれる member 間で pane_id が重複していないことを確認する。
    if ! jq -e 'type == "object"' <<< "$PANE_MAP_JSON" >/dev/null; then
        die "Pane map must be a JSON object"
    fi

    if ! jq -e --argjson pane_map "$PANE_MAP_JSON" '
        .members
        | all(
            if .launcher? == null then
                true
            else
                $pane_map[.member]? != null
                and ($pane_map[.member] | type == "string")
                and ($pane_map[.member] | length > 0)
            end
        )
    ' <<< "$AGENTS_CONFIG_JSON" >/dev/null; then
        die "Pane map must contain pane IDs for all launchable members"
    fi

    if ! jq -e --argjson pane_map "$PANE_MAP_JSON" '
        [.members[].member | $pane_map[.]? | select(. != null)]
        | length == (unique | length)
    ' <<< "$AGENTS_CONFIG_JSON" >/dev/null; then
        die "Pane map must not contain duplicate pane IDs"
    fi
}

pane_id_for_member() {
    # Args:
    #   $1: メンバー ID。
    # Returns:
    #   標準出力: 対応する pane ID。未定義なら空文字。
    # Overview:
    #   pane_map JSON から member キーに対応する pane_id を引く。
    local member="$1"

    jq -r --arg member "$member" '.[$member] // empty' <<< "$PANE_MAP_JSON"
}

prompt_path_for_member() {
    # Args:
    #   $1: メンバー ID。
    # Returns:
    #   標準出力: 暗黙規約で決まる role prompt のパス。
    # Overview:
    #   agents.config.json には prompt path を持たせず、member ID から
    #   `.ai-team/prompts/{member}.md` を一意に決定する。
    local member="$1"

    printf '.ai-team/prompts/%s.md\n' "$member"
}

ensure_prompt_file_exists() {
    # Args:
    #   $1: メンバー ID。
    # Returns:
    #   0: role prompt が存在する。
    #   非 0: role prompt が存在しない。
    # Overview:
    #   start 時に渡す prompt が実行時 shell で欠落しないよう、送信前に検出する。
    local member="$1"
    local prompt_path

    prompt_path="$(prompt_path_for_member "$member")"
    if [ ! -f "$prompt_path" ]; then
        echo "Prompt file not found for member ${member}: ${prompt_path}" >&2
        return 1
    fi
}

pane_current_command() {
    # Args:
    #   $1: pane ID。
    # Returns:
    #   標準出力: `pane_current_command` の値。取得できない場合は空文字。
    # Overview:
    #   冪等性ガード用に対象 pane の現在コマンド名を tmux から取得する。
    local pane_id="$1"

    tmux display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null || true
}

is_cli_running_in_pane() {
    # Args:
    #   $1: pane ID。
    #   $2: launcher.cli の値。
    # Returns:
    #   0: 対象 CLI が既に動作中。
    #   1: 動作中ではない。
    # Overview:
    #   `pane_current_command` が provider 名と一致した場合だけ動作中とみなす。
    local pane_id="$1"
    local cli_name="$2"
    local current_command

    current_command="$(pane_current_command "$pane_id")"
    [ "$current_command" = "$cli_name" ]
}

build_claude_start_command() {
    # Args:
    #   $1: メンバー定義 1 件分の JSON。
    # Returns:
    #   標準出力: Claude の新規起動コマンド。
    # Overview:
    #   1. model / think_mode / permission_mode を CLI フラグへ変換する。
    #   2. role prompt を append-system-prompt として付与する。
    #   3. session ID の保存は SessionStart hook に委譲する。
    local row_json="$1"
    local member
    local prompt_path
    local model
    local think_mode
    local permission_mode
    local command_text

    member="$(jq -r '.member' <<< "$row_json")"
    prompt_path="$(prompt_path_for_member "$member")"
    model="$(jq -r '.launcher.model // empty' <<< "$row_json")"
    think_mode="$(jq -r '.launcher.think_mode // empty' <<< "$row_json")"
    permission_mode="$(jq -r '.launcher.permission_mode // empty' <<< "$row_json")"

    ensure_prompt_file_exists "$member"

    command_text="AI_TEAM_MEMBER=$(shell_quote "$member") claude"

    if [ -n "$model" ]; then
        command_text+=" --model $(shell_quote "$model")"
    fi

    if [ -n "$think_mode" ]; then
        command_text+=" --effort $(shell_quote "$think_mode")"
    fi

    if [ -n "$permission_mode" ]; then
        command_text+=" --permission-mode $(shell_quote "$permission_mode")"
    fi

    command_text+=" --append-system-prompt \"\$(< $(shell_quote "$prompt_path"))\""

    printf '%s\n' "$command_text"
}

build_claude_resume_command() {
    # Args:
    #   $1: メンバー定義 1 件分の JSON。
    # Returns:
    #   標準出力: Claude の resume 起動コマンド。
    # Overview:
    #   1. 保存済み session_id があれば `--resume <id>` を使う。
    #   2. なければ current directory の直近会話を使う `--continue` へフォールバックする。
    local row_json="$1"
    local member
    local model
    local think_mode
    local permission_mode
    local saved_session_id
    local command_text

    member="$(jq -r '.member' <<< "$row_json")"
    model="$(jq -r '.launcher.model // empty' <<< "$row_json")"
    think_mode="$(jq -r '.launcher.think_mode // empty' <<< "$row_json")"
    permission_mode="$(jq -r '.launcher.permission_mode // empty' <<< "$row_json")"
    saved_session_id="$(load_claude_session_id "$member")"

    command_text="AI_TEAM_MEMBER=$(shell_quote "$member") claude"

    if [ -n "$model" ]; then
        command_text+=" --model $(shell_quote "$model")"
    fi

    if [ -n "$think_mode" ]; then
        command_text+=" --effort $(shell_quote "$think_mode")"
    fi

    if [ -n "$permission_mode" ]; then
        command_text+=" --permission-mode $(shell_quote "$permission_mode")"
    fi

    if [ -n "$saved_session_id" ]; then
        command_text+=" --resume $(shell_quote "$saved_session_id")"
    else
        command_text+=" --continue"
    fi

    printf '%s\n' "$command_text"
}

build_codex_start_command() {
    # Args:
    #   $1: メンバー定義 1 件分の JSON。
    # Returns:
    #   標準出力: Codex の新規起動コマンド。
    # Overview:
    #   1. model / think_mode / sandbox / approval_policy を CLI フラグへ変換する。
    #   2. role prompt を初期 user prompt として渡す。
    #   3. session ID の保存は SessionStart hook に委譲する。
    local row_json="$1"
    local member
    local prompt_path
    local prompt_text
    local model
    local think_mode
    local sandbox
    local approval_policy
    local command_text

    member="$(jq -r '.member' <<< "$row_json")"
    prompt_path="$(prompt_path_for_member "$member")"
    ensure_prompt_file_exists "$member"
    prompt_text="$(cat "$prompt_path")"
    model="$(jq -r '.launcher.model // empty' <<< "$row_json")"
    think_mode="$(jq -r '.launcher.think_mode // empty' <<< "$row_json")"
    sandbox="$(jq -r '.launcher.sandbox // empty' <<< "$row_json")"
    approval_policy="$(jq -r '.launcher.approval_policy // empty' <<< "$row_json")"

    command_text="AI_TEAM_MEMBER=$(shell_quote "$member") codex"

    if [ -n "$model" ]; then
        command_text+=" --model $(shell_quote "$model")"
    fi

    if [ -n "$think_mode" ]; then
        command_text+=" -c $(shell_quote "model_reasoning_effort=\"$think_mode\"")"
    fi

    if [ -n "$sandbox" ]; then
        command_text+=" --sandbox $(shell_quote "$sandbox")"
    fi

    if [ -n "$approval_policy" ]; then
        command_text+=" --ask-for-approval $(shell_quote "$approval_policy")"
    fi

    command_text+=" $(shell_quote "$prompt_text")"

    printf '%s\n' "$command_text"
}

build_codex_resume_command() {
    # Args:
    #   $1: メンバー定義 1 件分の JSON。
    # Returns:
    #   標準出力: Codex の resume 起動コマンド。
    # Overview:
    #   1. 新規起動と同じ provider 設定をグローバルオプションへ反映する。
    #   2. 保存済み thread ID があれば `resume <id>` を優先する。
    #   3. 未保存時だけ `resume --last` へフォールバックする。
    local row_json="$1"
    local member
    local model
    local think_mode
    local sandbox
    local approval_policy
    local saved_session_id
    local command_text

    member="$(jq -r '.member' <<< "$row_json")"
    model="$(jq -r '.launcher.model // empty' <<< "$row_json")"
    think_mode="$(jq -r '.launcher.think_mode // empty' <<< "$row_json")"
    sandbox="$(jq -r '.launcher.sandbox // empty' <<< "$row_json")"
    approval_policy="$(jq -r '.launcher.approval_policy // empty' <<< "$row_json")"
    saved_session_id="$(load_codex_session_id "$member")"

    command_text="AI_TEAM_MEMBER=$(shell_quote "$member") codex"

    if [ -n "$model" ]; then
        command_text+=" --model $(shell_quote "$model")"
    fi

    if [ -n "$think_mode" ]; then
        command_text+=" -c $(shell_quote "model_reasoning_effort=\"$think_mode\"")"
    fi

    if [ -n "$sandbox" ]; then
        command_text+=" --sandbox $(shell_quote "$sandbox")"
    fi

    if [ -n "$approval_policy" ]; then
        command_text+=" --ask-for-approval $(shell_quote "$approval_policy")"
    fi

    if [ -n "$saved_session_id" ]; then
        command_text+=" resume $(shell_quote "$saved_session_id")"
    else
        command_text+=" resume --last"
    fi

    printf '%s\n' "$command_text"
}

command_for_member_row() {
    # Args:
    #   $1: 実行モード。`start` または `resume`。
    #   $2: メンバー定義 1 件分の JSON。
    # Returns:
    #   標準出力: provider ごとの起動コマンド。
    #   非 0: 未対応 provider 検出時。
    # Overview:
    #   実行モードと launcher.cli に応じて provider 別ビルダーへ処理を委譲する。
    local mode="$1"
    local row_json="$2"
    local cli

    cli="$(jq -r '.launcher.cli' <<< "$row_json")"

    case "$cli:$mode" in
        claude:start)
            build_claude_start_command "$row_json"
            ;;
        claude:resume)
            build_claude_resume_command "$row_json"
            ;;
        codex:start)
            build_codex_start_command "$row_json"
            ;;
        codex:resume)
            build_codex_resume_command "$row_json"
            ;;
        *)
            return 1
            ;;
    esac
}

process_member_row() {
    # Args:
    #   $1: 実行モード。`start` または `resume`。
    #   $2: メンバー定義 1 件分の JSON。
    # Returns:
    #   0: 対象メンバーの分類処理完了。
    #   非 0: なし。失敗時も FAILED_MEMBERS に記録して継続する。
    # Overview:
    #   1. launcher の有無で対象外メンバーを skip する。
    #   2. resume 時は pane 上の動作状況を見て kept を判定する。
    #   3. 起動コマンド送信に成功したメンバーを started / resumed へ分類する。
    local mode="$1"
    local row_json="$2"
    local member
    local pane_id
    local cli
    local command_text

    member="$(jq -r '.member' <<< "$row_json")"

    if [ "$(jq -r 'has("launcher") and (.launcher != null)' <<< "$row_json")" != "true" ]; then
        SKIPPED_MEMBERS+=("$member")
        return 0
    fi

    pane_id="$(pane_id_for_member "$member")"
    if [ -z "$pane_id" ]; then
        FAILED_MEMBERS+=("$member")
        return 0
    fi

    cli="$(jq -r '.launcher.cli' <<< "$row_json")"
    if [ "$mode" = "resume" ] && is_cli_running_in_pane "$pane_id" "$cli"; then
        KEPT_MEMBERS+=("$member")
        return 0
    fi

    if ! command_text="$(command_for_member_row "$mode" "$row_json")"; then
        FAILED_MEMBERS+=("$member")
        return 0
    fi

    if ! send_literal_command "$pane_id" "$command_text"; then
        FAILED_MEMBERS+=("$member")
        return 0
    fi

    if [ "$mode" = "start" ]; then
        STARTED_MEMBERS+=("$member")
    else
        RESUMED_MEMBERS+=("$member")
    fi
}

session_management_main() {
    # Args:
    #   $1: 実行モード。`start` または `resume`。
    #   $2: agents_config の JSON 文字列、またはファイルパス。
    #   $3: pane_map の JSON 文字列、またはファイルパス。
    # Returns:
    #   0: 処理完了。結果 JSON を標準出力へ返す。
    #   非 0: 引数不足や JSON 不備など前提条件が満たされない。
    # Overview:
    #   1. 入力を JSON として読み込み、基本構造を検証する。
    #   2. members を順に処理し、started / resumed / kept / skipped / failed を集計する。
    #   3. 集計結果を仕様書どおりの JSON 形式で返す。
    local mode="$1"
    local agents_input="${2:-}"
    local pane_map_input="${3:-}"
    local row

    if [ -z "$agents_input" ] || [ -z "$pane_map_input" ]; then
        die "Usage: ${mode}-agents.sh <agents_config_json> <pane_map_json>"
    fi

    AGENTS_CONFIG_JSON="$(read_json_input "$agents_input")"
    PANE_MAP_JSON="$(read_json_input "$pane_map_input")"

    if ! jq -e . >/dev/null 2>&1 <<< "$AGENTS_CONFIG_JSON"; then
        die "Agents config must be valid JSON"
    fi

    if ! jq -e . >/dev/null 2>&1 <<< "$PANE_MAP_JSON"; then
        die "Pane map must be valid JSON"
    fi

    validate_agents_config_json
    validate_pane_map_json

    STARTED_MEMBERS=()
    RESUMED_MEMBERS=()
    KEPT_MEMBERS=()
    SKIPPED_MEMBERS=()
    FAILED_MEMBERS=()

    while IFS= read -r row; do
        [ -z "$row" ] && continue
        process_member_row "$mode" "$row"
    done < <(jq -c '.members[]' <<< "$AGENTS_CONFIG_JSON")

    emit_result_json
}
