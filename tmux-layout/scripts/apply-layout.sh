#!/usr/bin/env bash
set -euo pipefail

# apply-layout.sh
# レイアウト定義 JSON に従って tmux の window/pane 構成を目標状態へ近づける。

die() {
    # Args:
    #   $*: 標準エラーへ出力するエラーメッセージ。
    # Returns:
    #   なし。メッセージ出力後に終了コード 1 で終了する。
    # Overview:
    #   入力不備や tmux 操作不能など、処理継続できない状態を呼び出し元へ伝える。
    echo "[apply-layout] Error: $*" >&2
    exit 1
}

log() {
    # Args:
    #   $*: 標準エラーへ出力するログメッセージ。
    # Returns:
    #   なし。
    # Overview:
    #   stdout は結果 JSON 専用に保ち、診断情報だけを stderr へ流す。
    echo "[apply-layout] $*" >&2
}

cells_for_position() {
    # Args:
    #   $1: `top`, `bottom-right`, `whole` などの position 名。
    # Returns:
    #   標準出力: position が占有する 2x2 領域セル名の空白区切り。
    # Overview:
    #   1. 各 position を `tl/tr/bl/br` の集合へ変換する。
    #   2. 呼び出し側は集合の重複と不足から layout の妥当性を検証する。
    case "$1" in
        top-left) printf 'tl\n' ;;
        top-right) printf 'tr\n' ;;
        bottom-left) printf 'bl\n' ;;
        bottom-right) printf 'br\n' ;;
        top) printf 'tl\ntr\n' ;;
        bottom) printf 'bl\nbr\n' ;;
        left) printf 'tl\nbl\n' ;;
        right) printf 'tr\nbr\n' ;;
        whole) printf 'tl\ntr\nbl\nbr\n' ;;
        *) die "Unknown position: $1" ;;
    esac
}

position_order() {
    # Args:
    #   $1: position 名。
    # Returns:
    #   標準出力: 結果 JSON と pane 構築順に使う数値順序。
    # Overview:
    #   tmux pane の並びを、上から下・左から右へ読める順序にそろえる。
    case "$1" in
        whole | top | left | top-left) printf '10\n' ;;
        right | top-right) printf '20\n' ;;
        bottom | bottom-left) printf '30\n' ;;
        bottom-right) printf '40\n' ;;
        *) die "Unknown position: $1" ;;
    esac
}

pane_window_id() {
    # Args:
    #   $1: tmux pane_id。
    # Returns:
    #   標準出力: pane が属する tmux window_id。
    # Overview:
    #   既存 pane の現在地を取得し、目標 group window への移動要否判定に使う。
    tmux display-message -p -t "$1" '#{window_id}' 2>/dev/null
}

pane_count_in_window() {
    # Args:
    #   $1: tmux window_id。
    # Returns:
    #   標準出力: 対象 window に属する pane 数。
    # Overview:
    #   new-window が作った初期 pane を安全に削除できる状態かどうかを判定する。
    tmux list-panes -t "$1" -F '#{pane_id}' | wc -l | tr -d ' '
}

created_panes_in_window() {
    # Args:
    #   $1: tmux window_id。
    # Returns:
    #   標準出力: 対象 window にある未割当の作成済み pane_id。
    # Overview:
    #   tmux が new-window で作った初期 pane を、既存 pane 移動後または
    #   null pane 作成後に削除するため列挙する。
    local window_id="$1"
    local pane_id

    while IFS= read -r pane_id; do
        if [ -n "${CREATED_PANES[$pane_id]:-}" ]; then
            printf '%s\n' "$pane_id"
        fi
    done < <(tmux list-panes -t "$window_id" -F '#{pane_id}')
}

kill_created_panes_in_window() {
    # Args:
    #   $1: tmux window_id。
    # Returns:
    #   なし。
    # Overview:
    #   新規 window 作成時に tmux が自動生成した pane を、window 内に
    #   他 pane が存在する状態になってから削除する。
    local window_id="$1"
    local pane_id
    local pane_count

    while IFS= read -r pane_id; do
        [ -z "$pane_id" ] && continue
        pane_count="$(pane_count_in_window "$window_id")"
        if [ "$pane_count" -le 1 ]; then
            return 0
        fi
        log "Killing created pane ${pane_id} in ${window_id}"
        tmux kill-pane -t "$pane_id"
        unset 'CREATED_PANES[$pane_id]'
    done < <(created_panes_in_window "$window_id")
}

validate_layout_json() {
    # Args:
    #   なし。グローバル変数 LAYOUT_JSON を参照する。
    # Returns:
    #   0: 入力 JSON が仕様上有効。
    #   非 0: 不備検出時は die() で終了。
    # Overview:
    #   1. JSON 配列と各フィールドの型を検証する。
    #   2. 同じ pane_id の二重利用と同じ group 内の position 重複を拒否する。
    #   3. 各 group が 2x2 領域を重複なく全て覆うことを検証する。
    if ! jq empty <<< "$LAYOUT_JSON" >/dev/null 2>&1; then
        die "Invalid JSON input"
    fi

    if ! jq -e 'type == "array"' <<< "$LAYOUT_JSON" >/dev/null; then
        die "Invalid JSON: expected array"
    fi

    if ! jq -e '
        all(
            type == "object"
            and has("group_id")
            and has("pane_id")
            and has("position")
            and ((.group_id == null) or ((.group_id | type) == "number" and (.group_id | floor) == .group_id))
            and ((.pane_id == null) or ((.pane_id | type) == "string" and (.pane_id | length) > 0))
            and (
                .position == null
                or .position == "top-left"
                or .position == "top-right"
                or .position == "bottom-left"
                or .position == "bottom-right"
                or .position == "top"
                or .position == "bottom"
                or .position == "left"
                or .position == "right"
                or .position == "whole"
            )
            and (
                if .position == null then
                    .group_id == null and .pane_id != null
                else
                    .group_id != null
                end
            )
        )
    ' <<< "$LAYOUT_JSON" >/dev/null; then
        die "Invalid layout entry"
    fi

    if ! jq -e '[.[] | select(.pane_id != null) | .pane_id] | length == (unique | length)' <<< "$LAYOUT_JSON" >/dev/null; then
        die "Duplicate pane_id in layout"
    fi

    ACTIVE_ENTRIES="$(jq -c '[.[] | select(.position != null)]' <<< "$LAYOUT_JSON")"
    DELETE_ENTRIES="$(jq -c '[.[] | select(.position == null)]' <<< "$LAYOUT_JSON")"

    mapfile -t GROUP_IDS < <(jq -r '[.[].group_id] | unique | sort | .[]' <<< "$ACTIVE_ENTRIES")

    local group_id
    for group_id in "${GROUP_IDS[@]}"; do
        local duplicate_count
        duplicate_count="$(
            jq --argjson gid "$group_id" '
                [ .[] | select(.group_id == $gid) | .position ] as $positions
                | ($positions | length) - ($positions | unique | length)
            ' <<< "$ACTIVE_ENTRIES"
        )"
        if [ "$duplicate_count" -ne 0 ]; then
            die "Duplicate position in group ${group_id}"
        fi

        local -A occupied_cells=()
        local position
        while IFS= read -r position; do
            local cell
            while IFS= read -r cell; do
                if [ -n "${occupied_cells[$cell]:-}" ]; then
                    die "Positions overlap in group ${group_id}"
                fi
                occupied_cells[$cell]=1
            done < <(cells_for_position "$position")
        done < <(jq -r --argjson gid "$group_id" '.[] | select(.group_id == $gid) | .position' <<< "$ACTIVE_ENTRIES")

        if [ "${#occupied_cells[@]}" -ne 4 ]; then
            die "Positions in group ${group_id} must cover the whole 2x2 area"
        fi
    done
}

validate_session_pane_alignment() {
    # Args:
    #   なし。グローバル変数 LAYOUT_JSON / SESSION を参照する。
    # Returns:
    #   0: 開始時点の session pane と layout の pane_id 指定が一致する。
    #   非 0: 不整合検出時は die() で終了。
    # Overview:
    #   1. session に存在する pane_id を取得する。
    #   2. layout 内の non-null pane_id と集合として比較する。
    #   3. 片方にしかない pane があれば、呼び出し元の入力不整合として拒否する。
    local session_panes
    local layout_panes

    session_panes="$(tmux list-panes -s -t "$SESSION" -F '#{pane_id}' | sort)"
    layout_panes="$(jq -r '[.[] | select(.pane_id != null) | .pane_id] | sort | .[]' <<< "$LAYOUT_JSON")"

    if [ "$session_panes" != "$layout_panes" ]; then
        die "Layout pane set does not match session panes"
    fi
}

validate_invoking_pane_position() {
    # Args:
    #   なし。環境変数 TMUX_PANE とグローバル変数 LAYOUT_JSON / SESSION を参照する。
    # Returns:
    #   0: apply-layout.sh を実行した pane が削除対象ではない。
    #   非 0: 実行元 pane が不明、対象 session 外、または削除対象なら die() で終了。
    # Overview:
    #   1. tmux が設定する `TMUX_PANE` を実行元 pane として扱う。
    #   2. 実行元 pane が対象 session に属することを確認する。
    #   3. 実行元 pane の layout entry が `position: null` でないことを検証する。
    local invoking_pane="${TMUX_PANE:-}"
    local invoking_session
    local invoking_position

    if [ -z "$invoking_pane" ]; then
        die "TMUX_PANE is required to identify the invoking pane"
    fi

    invoking_session="$(tmux display-message -p -t "$invoking_pane" '#{session_name}' 2>/dev/null || true)"
    if [ "$invoking_session" != "$SESSION" ]; then
        die "Invoking pane must belong to session ${SESSION}"
    fi

    invoking_position="$(jq -r --arg pane_id "$invoking_pane" '.[] | select(.pane_id == $pane_id) | .position // "null"' <<< "$LAYOUT_JSON")"
    if [ "$invoking_position" = "null" ]; then
        die "The invoking pane position must not be null"
    fi
}

kill_deleted_panes() {
    # Args:
    #   なし。グローバル変数 DELETE_ENTRIES を参照する。
    # Returns:
    #   なし。
    # Overview:
    #   `position: null` の pane を明示削除対象として扱い、検証済みの pane を削除する。
    local pane_id

    while IFS= read -r pane_id; do
        log "Killing pane ${pane_id}"
        tmux kill-pane -t "$pane_id"
    done < <(jq -r '.[].pane_id' <<< "$DELETE_ENTRIES")
}

window_is_group_target() {
    # Args:
    #   $1: tmux window_id。
    # Returns:
    #   0: すでにいずれかの group の target window として使われている。
    #   1: まだ target window として使われていない。
    # Overview:
    #   複数 group が同じ window を target として共有しないようにする。
    local window_id="$1"
    local group_id

    for group_id in "${!GROUP_TO_WINDOW[@]}"; do
        if [ "${GROUP_TO_WINDOW[$group_id]}" = "$window_id" ]; then
            return 0
        fi
    done

    return 1
}

create_group_window() {
    # Args:
    #   $1: group_id。
    # Returns:
    #   なし。グローバル変数 TARGET_WINDOW に作成した tmux window_id を設定する。
    # Overview:
    #   group の配置先 window が既存 layout から確定できない場合にだけ
    #   新規 window を作成し、tmux が自動生成した初期 pane を追跡する。
    local group_id="$1"
    local created
    local window_id
    local pane_id

    created="$(tmux new-window -d -t "$SESSION" -P -F '#{window_id} #{pane_id}')"
    window_id="${created%% *}"
    pane_id="${created##* }"
    GROUP_TO_WINDOW["$group_id"]="$window_id"
    CREATED_PANES["$pane_id"]=1
    TARGET_WINDOW="$window_id"
}

ensure_group_target_window() {
    # Args:
    #   $1: group_id。
    #   $2: pane_id。既存 pane の current window を target 候補にする場合のみ指定する。
    # Returns:
    #   なし。グローバル変数 TARGET_WINDOW に group_id 対応の tmux window_id を設定する。
    # Overview:
    #   1. 既に target window があれば返す。
    #   2. pane_id の current window が未使用なら、その window を target にする。
    #   3. current window が別 group に使われている場合は、新規 window を作成する。
    local group_id="$1"
    local pane_id="${2:-}"
    local current_window=""

    if [ -n "${GROUP_TO_WINDOW[$group_id]:-}" ]; then
        TARGET_WINDOW="${GROUP_TO_WINDOW[$group_id]}"
        return 0
    fi

    if [ -n "$pane_id" ]; then
        current_window="$(pane_window_id "$pane_id")"
        if ! window_is_group_target "$current_window"; then
            GROUP_TO_WINDOW["$group_id"]="$current_window"
            TARGET_WINDOW="$current_window"
            return 0
        fi
    fi

    create_group_window "$group_id"
}

move_known_panes_to_target_windows() {
    # Args:
    #   なし。ACTIVE_ENTRIES と GROUP_TO_WINDOW を参照する。
    # Returns:
    #   なし。
    # Overview:
    #   1. 既存 pane_id を group_id に対応する target window へ集める。
    #   2. 配置先 window が未確定なら、その場で既存 window を割り当てるか新規作成する。
    #   3. 新規 window の初期 pane は、既存 pane 移動後に削除する。
    local group_id
    local pane_id

    while IFS=$'\t' read -r group_id pane_id; do
        local target_window
        local current_window
        ensure_group_target_window "$group_id" "$pane_id"
        target_window="$TARGET_WINDOW"
        current_window="$(pane_window_id "$pane_id")"

        if [ "$current_window" != "$target_window" ]; then
            log "Moving pane ${pane_id} to ${target_window}"
            tmux join-pane -s "$pane_id" -t "$target_window"
            kill_created_panes_in_window "$target_window"
        fi
    done < <(jq -r '.[] | select(.pane_id != null) | "\(.group_id)\t\(.pane_id)"' <<< "$ACTIVE_ENTRIES")
}

reorder_group_windows() {
    # Args:
    #   なし。GROUP_IDS / GROUP_TO_WINDOW / SESSION を参照する。
    # Returns:
    #   なし。
    # Overview:
    #   group_id 昇順と tmux window 表示順が一致するよう window を入れ替える。
    local -a window_indices=()
    local group_id
    local index
    local target_index
    local desired_window
    local current_window

    mapfile -t window_indices < <(tmux list-windows -t "$SESSION" -F '#{window_index}' | sort -n)

    for index in "${!GROUP_IDS[@]}"; do
        group_id="${GROUP_IDS[$index]}"
        target_index="${window_indices[$index]}"
        desired_window="${GROUP_TO_WINDOW[$group_id]}"
        current_window="$(tmux display-message -p -t "${SESSION}:${target_index}" '#{window_id}')"

        if [ "$current_window" != "$desired_window" ]; then
            tmux swap-window -s "$desired_window" -t "${SESSION}:${target_index}"
        fi
    done
}

sorted_positions_for_group() {
    # Args:
    #   $@: position 名の列。
    # Returns:
    #   標準出力: position_order 順に並べた position 名。
    # Overview:
    #   結果 JSON と layout 再構築の順序を同じ規則にそろえる。
    local position
    local order

    for position in "$@"; do
        order="$(position_order "$position")"
        printf '%s\t%s\n' "$order" "$position"
    done | sort -n -k1,1 | cut -f2-
}

position_signature() {
    # Args:
    #   $@: position 名の列。
    # Returns:
    #   標準出力: アルファベット順に連結した position signature。
    # Overview:
    #   有効な 2x2 領域の組み合わせを、case 文で判定しやすい文字列へ正規化する。
    printf '%s\n' "$@" | sort | paste -sd' ' -
}

join_position_pane() {
    # Args:
    #   $1: 移動元 position。
    #   $2: 分割対象 position。
    #   $3: tmux split 方向（`-h` または `-v`）。
    #   $4: `before` の場合は対象 pane の左または上へ入れる。
    # Returns:
    #   なし。
    # Overview:
    #   同一 window 内の pane を、指定 target pane の隣へ移動して配置を作る。
    local source_position="$1"
    local target_position="$2"
    local split_direction="$3"
    local placement="${4:-after}"
    local source_pane="${POSITION_TO_PANE[$source_position]}"
    local target_pane="${POSITION_TO_PANE[$target_position]}"
    local args=(join-pane -s "$source_pane" -t "$target_pane" "$split_direction")

    if [ "$placement" = "before" ]; then
        args+=(-b)
    fi

    tmux "${args[@]}"
}

rebuild_window_layout() {
    # Args:
    #   $1: target window_id。
    #   $@: group 内の position 名。
    # Returns:
    #   なし。
    # Overview:
    #   1. position の組み合わせから base pane と join-pane 手順を選ぶ。
    #   2. pane_id を保ったまま同一 window 内で順に join し、視覚的な layout を再構築する。
    local window_id="$1"
    shift
    local positions=("$@")
    local signature
    signature="$(position_signature "${positions[@]}")"
    local base_position
    local -a group_panes=()
    local position

    case "$signature" in
        whole) base_position="whole" ;;
        "bottom top") base_position="top" ;;
        "left right") base_position="left" ;;
        "bottom-left bottom-right top") base_position="top" ;;
        "bottom top-left top-right") base_position="bottom" ;;
        "bottom-right left top-right") base_position="left" ;;
        "bottom-left right top-left") base_position="right" ;;
        "bottom-left bottom-right top-left top-right") base_position="top-left" ;;
        *) die "Unsupported position combination: ${signature}" ;;
    esac

    for position in "${positions[@]}"; do
        group_panes+=("${POSITION_TO_PANE[$position]}")
    done

    if [ "${#group_panes[@]}" -eq 1 ]; then
        tmux select-pane -t "${POSITION_TO_PANE[$base_position]}" >/dev/null
        return
    fi

    case "$signature" in
        "bottom top")
            join_position_pane "bottom" "top" "-v"
            ;;
        "left right")
            join_position_pane "right" "left" "-h"
            ;;
        "bottom-left bottom-right top")
            join_position_pane "bottom-left" "top" "-v"
            join_position_pane "bottom-right" "bottom-left" "-h"
            ;;
        "bottom top-left top-right")
            join_position_pane "top-left" "bottom" "-v" "before"
            join_position_pane "top-right" "top-left" "-h"
            ;;
        "bottom-right left top-right")
            join_position_pane "top-right" "left" "-h"
            join_position_pane "bottom-right" "top-right" "-v"
            ;;
        "bottom-left right top-left")
            join_position_pane "top-left" "right" "-h" "before"
            join_position_pane "bottom-left" "top-left" "-v"
            ;;
        "bottom-left bottom-right top-left top-right")
            join_position_pane "top-right" "top-left" "-h"
            join_position_pane "bottom-left" "top-left" "-v"
            join_position_pane "bottom-right" "top-right" "-v"
            ;;
    esac

    tmux select-pane -t "${POSITION_TO_PANE[$base_position]}" >/dev/null
}

assign_and_shape_group() {
    # Args:
    #   $1: group_id。
    #   $2: group_id に対応する tmux window_id。
    # Returns:
    #   なし。グローバル RESULT_JSON を更新する。
    # Overview:
    #   1. 既存 pane と null pane の position 対応を決める。
    #   2. null pane に対応する新規 pane を作成する。
    #   3. window 内の pane を position に合わせて再構築し、結果 JSON に反映する。
    local group_id="$1"
    local window_id="$2"
    local group_entries
    group_entries="$(jq -c --argjson gid "$group_id" '[.[] | select(.group_id == $gid)]' <<< "$ACTIVE_ENTRIES")"

    POSITION_TO_PANE=()
    local -a positions=()
    local -a null_positions=()
    local position
    local pane_id

    while IFS=$'\t' read -r position pane_id; do
        positions+=("$position")
        if [ "$pane_id" = "null" ]; then
            null_positions+=("$position")
        else
            POSITION_TO_PANE["$position"]="$pane_id"
        fi
    done < <(jq -r '.[] | "\(.position)\t\(.pane_id // "null")"' <<< "$group_entries")

    for position in "${null_positions[@]}"; do
        pane_id="$(tmux split-window -t "$window_id" -P -F '#{pane_id}')"
        POSITION_TO_PANE["$position"]="$pane_id"
    done

    kill_created_panes_in_window "$window_id"

    local -a sorted_positions=()
    mapfile -t sorted_positions < <(sorted_positions_for_group "${positions[@]}")
    rebuild_window_layout "$window_id" "${sorted_positions[@]}"

    local window_result="[]"
    for position in "${sorted_positions[@]}"; do
        pane_id="${POSITION_TO_PANE[$position]}"
        window_result="$(jq -c --arg pane_id "$pane_id" --arg position "$position" '. + [{"pane_id": $pane_id, "position": $position}]' <<< "$window_result")"
    done

    RESULT_JSON="$(jq -c --arg window_id "$window_id" --argjson entries "$window_result" '. + {($window_id): $entries}' <<< "$RESULT_JSON")"
}

if [ "$#" -ne 2 ]; then
    die "Usage: apply-layout.sh '<layout_json>' <session_name>"
fi

LAYOUT_JSON="$1"
SESSION="$2"
ACTIVE_ENTRIES="[]"
DELETE_ENTRIES="[]"
RESULT_JSON="{}"
TARGET_WINDOW=""

declare -a GROUP_IDS=()
declare -A GROUP_TO_WINDOW=()
declare -A POSITION_TO_PANE=()
declare -A CREATED_PANES=()

command -v jq >/dev/null 2>&1 || die "jq is required"
command -v tmux >/dev/null 2>&1 || die "tmux is required"

validate_layout_json

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    die "tmux session not found: ${SESSION}"
fi

validate_session_pane_alignment
validate_invoking_pane_position
kill_deleted_panes

move_known_panes_to_target_windows

for group_id in "${GROUP_IDS[@]}"; do
    ensure_group_target_window "$group_id"
    target_window="$TARGET_WINDOW"
    assign_and_shape_group "$group_id" "$target_window"
done

reorder_group_windows

echo "$RESULT_JSON"
