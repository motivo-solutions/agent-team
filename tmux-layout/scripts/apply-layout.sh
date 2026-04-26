#!/usr/bin/env bash
set -euo pipefail

# apply-layout.sh
# Apply tmux pane configuration based on a layout definition JSON
#
# Usage: apply-layout.sh '<layout_json>' <session_name>
#
# Output: Prints the result JSON to stdout. Logs go to stderr.

log() {
    echo "[apply-layout] $*" >&2
}

die() {
    echo "[apply-layout] Error: $*" >&2
    exit 1
}

position_cells() {
    # Args:
    #   $1: レイアウト位置名。
    # Returns:
    #   標準出力: その位置が占有する基本領域名の一覧。
    # Overview:
    #   top / bottom / left / right を 4 分割の基本領域へ展開し、重なり検証に使う。
    case "$1" in
        top)
            printf '%s\n' top-left top-right
            ;;
        bottom)
            printf '%s\n' bottom-left bottom-right
            ;;
        left)
            printf '%s\n' top-left bottom-left
            ;;
        right)
            printf '%s\n' top-right bottom-right
            ;;
        top-left | top-right | bottom-left | bottom-right)
            printf '%s\n' "$1"
            ;;
        *)
            return 1
            ;;
    esac
}

# --- Argument check ---
if [ $# -lt 2 ]; then
    die "Usage: apply-layout.sh '<layout_json>' <session_name>"
fi

LAYOUT_JSON="$1"
SESSION="$2"

# --- Step 0: JSON parse and validation ---
if ! echo "$LAYOUT_JSON" | jq empty 2>/dev/null; then
    die "Invalid JSON input"
fi

# Verify it is an array
if ! echo "$LAYOUT_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    die "Invalid JSON: expected array"
fi

# Check that each element has the required fields
ELEMENT_COUNT=$(echo "$LAYOUT_JSON" | jq 'length')
if [ "$ELEMENT_COUNT" -eq 0 ]; then
    # Empty array: exit without action
    echo "{}"
    exit 0
fi

# --- Step 1: Validation ---

# Validate entries with non-null position, grouped by group_id
ACTIVE_ENTRIES=$(echo "$LAYOUT_JSON" | jq '[.[] | select(.position != null)]')
GROUP_LIST=$(echo "$ACTIVE_ENTRIES" | jq -r '[.[].group_id] | unique | .[]')

for group_id in $GROUP_LIST; do
    # Get the list of positions within the group
    POSITIONS=$(echo "$ACTIVE_ENTRIES" | jq -r --argjson gid "$group_id" \
        '[.[] | select(.group_id == $gid) | .position] | sort | .[]')

    POSITION_LIST=()
    while IFS= read -r pos; do
        [ -n "$pos" ] && POSITION_LIST+=("$pos")
    done <<< "$POSITIONS"

    POSITION_COUNT=${#POSITION_LIST[@]}

    # Check for duplicates
    UNIQUE_COUNT=$(echo "$ACTIVE_ENTRIES" | jq --argjson gid "$group_id" \
        '[.[] | select(.group_id == $gid) | .position] | unique | length')
    if [ "$POSITION_COUNT" -ne "$UNIQUE_COUNT" ]; then
        die "Duplicate positions in group $group_id"
    fi

    # Check that 'whole' does not coexist with other panes
    HAS_WHOLE=false
    for pos in "${POSITION_LIST[@]}"; do
        if [ "$pos" = "whole" ]; then
            HAS_WHOLE=true
        fi
    done
    if [ "$HAS_WHOLE" = true ] && [ "$POSITION_COUNT" -gt 1 ]; then
        die "Position 'whole' cannot coexist with other positions in group $group_id"
    fi

    # 'whole' alone is OK
    if [ "$HAS_WHOLE" = true ]; then
        continue
    fi

    # 基本領域（4 分割の各セル）を過不足なく 1 回ずつ占有していることを検証する。
    declare -A OCCUPIED_CELLS=()
    for pos in "${POSITION_LIST[@]}"; do
        if ! cells="$(position_cells "$pos")"; then
            die "Unknown position: $pos"
        fi

        while IFS= read -r cell; do
            [ -z "$cell" ] && continue
            if [ -n "${OCCUPIED_CELLS[$cell]:-}" ]; then
                die "Overlapping positions in group $group_id: ${OCCUPIED_CELLS[$cell]} and $pos both occupy $cell"
            fi
            OCCUPIED_CELLS["$cell"]="$pos"
        done <<< "$cells"
    done

    for cell in top-left top-right bottom-left bottom-right; do
        if [ -z "${OCCUPIED_CELLS[$cell]:-}" ]; then
            die "Positions in group $group_id must cover $cell"
        fi
    done
done

log "Validation passed"

# --- Step 2: Process deletion targets ---
KILL_ENTRIES=$(echo "$LAYOUT_JSON" | jq -c '[.[] | select(.position == null and .pane_id != null)]')
KILL_COUNT=$(echo "$KILL_ENTRIES" | jq 'length')

for i in $(seq 0 $((KILL_COUNT - 1))); do
    PANE_ID=$(echo "$KILL_ENTRIES" | jq -r ".[$i].pane_id")
    log "Killing pane: $PANE_ID"
    tmux kill-pane -t "$PANE_ID" 2>/dev/null || log "Warning: could not kill pane $PANE_ID"
done

# --- Step 3: Adjust window count ---
# List of group_ids (ascending, excluding null)
GROUP_IDS=$(echo "$ACTIVE_ENTRIES" | jq -r '[.[].group_id] | unique | sort | .[]')
GROUP_COUNT=$(echo "$ACTIVE_ENTRIES" | jq '[.[].group_id] | unique | length')

# Current window list
CURRENT_WINDOWS=$(tmux list-windows -t "$SESSION" -F '#{window_id}' 2>/dev/null || echo "")
if [ -n "$CURRENT_WINDOWS" ]; then
    CURRENT_WINDOW_COUNT=$(echo "$CURRENT_WINDOWS" | wc -l)
else
    CURRENT_WINDOW_COUNT=0
fi

log "Need $GROUP_COUNT windows, have $CURRENT_WINDOW_COUNT"

# Create missing windows (track ghost panes created by new-window)
declare -a GHOST_PANES=()
while [ "$CURRENT_WINDOW_COUNT" -lt "$GROUP_COUNT" ]; do
    ghost_pane=$(tmux new-window -t "$SESSION" -P -F '#{pane_id}')
    GHOST_PANES+=("$ghost_pane")
    log "Created new window with ghost pane $ghost_pane"
    CURRENT_WINDOW_COUNT=$((CURRENT_WINDOW_COUNT + 1))
done

# Re-fetch window IDs
WINDOW_IDS=()
while IFS= read -r wid; do
    [ -n "$wid" ] && WINDOW_IDS+=("$wid")
done <<< "$(tmux list-windows -t "$SESSION" -F '#{window_id}')"

# Map group_id -> window_id (group_id ascending <-> window order)
declare -A GROUP_TO_WINDOW
GROUP_INDEX=0
for gid in $GROUP_IDS; do
    GROUP_TO_WINDOW[$gid]="${WINDOW_IDS[$GROUP_INDEX]}"
    log "Group $gid -> Window ${WINDOW_IDS[$GROUP_INDEX]}"
    GROUP_INDEX=$((GROUP_INDEX + 1))
done

# --- Step 4: Move/create panes ---

# Process each group
for gid in $GROUP_IDS; do
    TARGET_WINDOW="${GROUP_TO_WINDOW[$gid]}"

    # Get entries for this group
    GROUP_ENTRIES=$(echo "$ACTIVE_ENTRIES" | jq -c --argjson gid "$gid" \
        '[.[] | select(.group_id == $gid)]')
    ENTRY_COUNT=$(echo "$GROUP_ENTRIES" | jq 'length')

    # First, move existing panes
    for i in $(seq 0 $((ENTRY_COUNT - 1))); do
        PANE_ID=$(echo "$GROUP_ENTRIES" | jq -r ".[$i].pane_id")
        if [ "$PANE_ID" = "null" ] || [ -z "$PANE_ID" ]; then
            continue
        fi

        # Check which window the pane is currently in
        CURRENT_WINDOW=$(tmux display-message -p -t "$PANE_ID" '#{window_id}' 2>/dev/null || echo "")
        if [ -z "$CURRENT_WINDOW" ]; then
            log "Warning: pane $PANE_ID not found, skipping"
            continue
        fi

        if [ "$CURRENT_WINDOW" != "$TARGET_WINDOW" ]; then
            log "Moving pane $PANE_ID from $CURRENT_WINDOW to $TARGET_WINDOW"
            tmux join-pane -s "$PANE_ID" -t "$TARGET_WINDOW" 2>/dev/null || \
                log "Warning: could not move pane $PANE_ID"
        fi
    done

    # Create new panes
    for i in $(seq 0 $((ENTRY_COUNT - 1))); do
        PANE_ID=$(echo "$GROUP_ENTRIES" | jq -r ".[$i].pane_id")
        POSITION=$(echo "$GROUP_ENTRIES" | jq -r ".[$i].position")

        if [ "$PANE_ID" != "null" ] && [ -n "$PANE_ID" ]; then
            continue
        fi

        # Check if the window has existing panes
        EXISTING_PANES=$(tmux list-panes -t "${SESSION}:${TARGET_WINDOW}" -F '#{pane_id}' 2>/dev/null || echo "")
        if [ -n "$EXISTING_PANES" ]; then
            EXISTING_COUNT=$(echo "$EXISTING_PANES" | wc -l)
        else
            EXISTING_COUNT=0
        fi

        if [ "$EXISTING_COUNT" -eq 0 ]; then
            # Window has no panes (unlikely but as a safety measure)
            log "Creating new pane in empty window $TARGET_WINDOW"
            tmux split-window -t "${SESSION}:${TARGET_WINDOW}" -c '#{pane_current_path}'
        else
            log "Creating new pane in window $TARGET_WINDOW (split)"
            tmux split-window -t "${SESSION}:${TARGET_WINDOW}" -c '#{pane_current_path}'
        fi
    done
done

# --- Step 4.5: Kill ghost panes that are no longer needed ---
# A ghost pane can be killed only if other panes exist in its window.
# If the ghost pane is the only pane (all entries in the group are new panes
# created by split-window), it is reused as one of the new panes.
for ghost in "${GHOST_PANES[@]+"${GHOST_PANES[@]}"}"; do
    if ! tmux list-panes -t "$ghost" &>/dev/null; then
        continue
    fi
    # Get the window containing this ghost pane
    ghost_window=$(tmux display-message -p -t "$ghost" '#{window_id}' 2>/dev/null || echo "")
    if [ -z "$ghost_window" ]; then
        continue
    fi
    pane_count_in_window=$(tmux list-panes -t "${SESSION}:${ghost_window}" -F '#{pane_id}' | wc -l)
    if [ "$pane_count_in_window" -gt 1 ]; then
        log "Killing ghost pane $ghost"
        tmux kill-pane -t "$ghost" 2>/dev/null || true
    else
        log "Keeping ghost pane $ghost (only pane in window $ghost_window)"
    fi
done

# --- Step 5: Adjust pane arrangement within windows ---

layout_checksum() {
    # Args:
    #   $1: checksum を除いた tmux layout 文字列。
    # Returns:
    #   標準出力: tmux が select-layout で要求する 4 桁 16 進 checksum。
    # Overview:
    #   tmux の layout checksum と同じ計算で、任意の分割形状を安全に適用する。
    local layout="$1"
    local checksum=0
    local i
    local ord

    LC_CTYPE=C
    for ((i = 0; i < ${#layout}; i++)); do
        printf -v ord '%d' "'${layout:i:1}"
        checksum=$(( ((checksum >> 1) | ((checksum & 1) << 15)) + ord ))
        checksum=$(( checksum & 0xffff ))
    done

    printf '%04x\n' "$checksum"
}

pane_layout_id() {
    # Args:
    #   $1: tmux pane_id（例: %5）。
    # Returns:
    #   標準出力: tmux layout 文字列で使う数値 ID。
    local pane_id="$1"
    echo "${pane_id#%}"
}

position_rect() {
    # Args:
    #   $1: position。
    # Returns:
    #   標準出力: row_start col_start row_end col_end。
    # Overview:
    #   position を 2x2 の基本領域上の矩形へ変換する。
    case "$1" in
        whole) echo "0 0 2 2" ;;
        top) echo "0 0 1 2" ;;
        bottom) echo "1 0 2 2" ;;
        left) echo "0 0 2 1" ;;
        right) echo "0 1 2 2" ;;
        top-left) echo "0 0 1 1" ;;
        top-right) echo "0 1 1 2" ;;
        bottom-left) echo "1 0 2 1" ;;
        bottom-right) echo "1 1 2 2" ;;
        *) return 1 ;;
    esac
}

split_region_positions() {
    # Args:
    #   $1: 分割軸（row または col）。
    #   $2: 分割境界。
    #   $3...: 分割対象の position 一覧。
    # Returns:
    #   分割できれば 0、できなければ 1。結果は SPLIT_FIRST / SPLIT_SECOND に入る。
    # Overview:
    #   position の矩形が分割境界をまたがない場合だけ、前半・後半の領域に分類する。
    local axis="$1"
    local cut="$2"
    local pos
    local rect_row_start
    local rect_col_start
    local rect_row_end
    local rect_col_end
    local start
    local end
    shift 2

    SPLIT_FIRST=()
    SPLIT_SECOND=()

    for pos in "$@"; do
        read -r rect_row_start rect_col_start rect_row_end rect_col_end <<< "$(position_rect "$pos")"
        if [ "$axis" = "col" ]; then
            start="$rect_col_start"
            end="$rect_col_end"
        else
            start="$rect_row_start"
            end="$rect_row_end"
        fi

        if [ "$start" -lt "$cut" ] && [ "$end" -gt "$cut" ]; then
            return 1
        elif [ "$end" -le "$cut" ]; then
            SPLIT_FIRST+=("$pos")
        else
            SPLIT_SECOND+=("$pos")
        fi
    done

    [ "${#SPLIT_FIRST[@]}" -gt 0 ] && [ "${#SPLIT_SECOND[@]}" -gt 0 ]
}

layout_leaf_positions() {
    # Args:
    #   $1-$4: 対象領域の row_start col_start row_end col_end。
    #   $5...: 対象領域に含まれる position 一覧。
    # Returns:
    #   標準出力: tmux layout の leaf order に並べた position。
    # Overview:
    #   build_region_layout と同じ分割規則で、pane を事前に並べ替えるための順序を求める。
    local row_start="$1"
    local col_start="$2"
    local row_end="$3"
    local col_end="$4"
    local cut
    local -a first_positions
    local -a second_positions
    shift 4

    if [ "$#" -eq 1 ]; then
        printf '%s\n' "$1"
        return
    fi

    if [ $((col_end - col_start)) -gt 1 ]; then
        cut=$((col_start + 1))
        if split_region_positions col "$cut" "$@"; then
            first_positions=("${SPLIT_FIRST[@]}")
            second_positions=("${SPLIT_SECOND[@]}")
            layout_leaf_positions "$row_start" "$col_start" "$row_end" "$cut" "${first_positions[@]}"
            layout_leaf_positions "$row_start" "$cut" "$row_end" "$col_end" "${second_positions[@]}"
            return
        fi
    fi

    if [ $((row_end - row_start)) -gt 1 ]; then
        cut=$((row_start + 1))
        if split_region_positions row "$cut" "$@"; then
            first_positions=("${SPLIT_FIRST[@]}")
            second_positions=("${SPLIT_SECOND[@]}")
            layout_leaf_positions "$row_start" "$col_start" "$cut" "$col_end" "${first_positions[@]}"
            layout_leaf_positions "$cut" "$col_start" "$row_end" "$col_end" "${second_positions[@]}"
            return
        fi
    fi

    die "Cannot order tmux layout positions: $*"
}

build_region_layout() {
    # Args:
    #   $1-$4: 対象領域の row_start col_start row_end col_end。
    #   $5-$8: 対象領域の width height x y。
    #   $9...: 対象領域に含まれる position 一覧。
    # Returns:
    #   標準出力: checksum を除いた tmux layout 文字列。
    # Overview:
    #   1. position の矩形を、重ならない縦または横の 2 領域へ分割する。
    #   2. 分割できなくなるまで再帰し、葉を pane_id に変換する。
    local row_start="$1"
    local col_start="$2"
    local row_end="$3"
    local col_end="$4"
    local width="$5"
    local height="$6"
    local x="$7"
    local y="$8"
    shift 8

    if [ "$#" -eq 1 ]; then
        printf '%sx%s,%s,%s,%s' "$width" "$height" "$x" "$y" "$(pane_layout_id "${PANE_BY_POSITION[$1]}")"
        return
    fi

    local cut
    local first_layout
    local second_layout
    local first_width
    local second_width
    local second_x
    local first_height
    local second_height
    local second_y
    local -a first_positions
    local -a second_positions

    if [ $((col_end - col_start)) -gt 1 ]; then
        cut=$((col_start + 1))
        if split_region_positions col "$cut" "$@"; then
            first_positions=("${SPLIT_FIRST[@]}")
            second_positions=("${SPLIT_SECOND[@]}")
            first_width=$(( (width - 1) / 2 ))
            second_width=$(( width - first_width - 1 ))
            second_x=$(( x + first_width + 1 ))
            first_layout=$(build_region_layout "$row_start" "$col_start" "$row_end" "$cut" "$first_width" "$height" "$x" "$y" "${first_positions[@]}")
            second_layout=$(build_region_layout "$row_start" "$cut" "$row_end" "$col_end" "$second_width" "$height" "$second_x" "$y" "${second_positions[@]}")
            printf '%sx%s,%s,%s{%s,%s}' "$width" "$height" "$x" "$y" "$first_layout" "$second_layout"
            return
        fi
    fi

    if [ $((row_end - row_start)) -gt 1 ]; then
        cut=$((row_start + 1))
        if split_region_positions row "$cut" "$@"; then
            first_positions=("${SPLIT_FIRST[@]}")
            second_positions=("${SPLIT_SECOND[@]}")
            first_height=$(( (height - 1) / 2 ))
            second_height=$(( height - first_height - 1 ))
            second_y=$(( y + first_height + 1 ))
            first_layout=$(build_region_layout "$row_start" "$col_start" "$cut" "$col_end" "$width" "$first_height" "$x" "$y" "${first_positions[@]}")
            second_layout=$(build_region_layout "$cut" "$col_start" "$row_end" "$col_end" "$width" "$second_height" "$x" "$second_y" "${second_positions[@]}")
            printf '%sx%s,%s,%s[%s,%s]' "$width" "$height" "$x" "$y" "$first_layout" "$second_layout"
            return
        fi
    fi

    die "Cannot build tmux layout for positions: $*"
}

apply_tmux_layout() {
    # Args:
    #   $1: tmux window_id。
    #   $2...: position 一覧。
    # Returns:
    #   なし。
    # Overview:
    #   2x2 の基本領域を再帰的に分割し、任意の非重複 position 構成を tmux layout に変換する。
    local target_window="$1"
    local window_width
    local window_height
    local layout_body
    local layout_checksum_value
    shift

    read -r window_width window_height <<< "$(tmux display-message -p -t "${SESSION}:${target_window}" '#{window_width} #{window_height}')"
    layout_body=$(build_region_layout 0 0 2 2 "$window_width" "$window_height" 0 0 "$@")
    layout_checksum_value=$(layout_checksum "$layout_body")

    tmux select-layout -t "${SESSION}:${target_window}" "${layout_checksum_value},${layout_body}"
}

# Build result JSON
RESULT_JSON="{}"

for gid in $GROUP_IDS; do
    TARGET_WINDOW="${GROUP_TO_WINDOW[$gid]}"

    GROUP_ENTRIES=$(echo "$ACTIVE_ENTRIES" | jq -c --argjson gid "$gid" \
        '[.[] | select(.group_id == $gid)]')
    ENTRY_COUNT=$(echo "$GROUP_ENTRIES" | jq 'length')

    # Get the current pane list within the window
    CURRENT_PANES=()
    while IFS= read -r pid; do
        [ -n "$pid" ] && CURRENT_PANES+=("$pid")
    done <<< "$(tmux list-panes -t "${SESSION}:${TARGET_WINDOW}" -F '#{pane_id}')"

    CURRENT_PANE_COUNT=${#CURRENT_PANES[@]}

    # Determine position types
    POSITIONS=()
    for i in $(seq 0 $((ENTRY_COUNT - 1))); do
        POSITIONS+=($(echo "$GROUP_ENTRIES" | jq -r ".[$i].position"))
    done

    # Re-fetch (pane list after splits)
    CURRENT_PANES=()
    while IFS= read -r pid; do
        [ -n "$pid" ] && CURRENT_PANES+=("$pid")
    done <<< "$(tmux list-panes -t "${SESSION}:${TARGET_WINDOW}" -F '#{pane_id}')"

    # Map existing pane IDs to new pane IDs
    # Existing panes: those with non-null pane_id in the layout
    # New panes: those with null pane_id -> assign from current window panes not in the existing list

    KNOWN_PANES=()
    NEW_PANE_POSITIONS=()
    KNOWN_POSITIONS=()

    for i in $(seq 0 $((ENTRY_COUNT - 1))); do
        PID=$(echo "$GROUP_ENTRIES" | jq -r ".[$i].pane_id")
        POS=$(echo "$GROUP_ENTRIES" | jq -r ".[$i].position")
        if [ "$PID" != "null" ] && [ -n "$PID" ]; then
            KNOWN_PANES+=("$PID")
            KNOWN_POSITIONS+=("$POS")
        else
            NEW_PANE_POSITIONS+=("$POS")
        fi
    done

    # Identify new panes (those in the current window not in KNOWN_PANES)
    NEW_PANES=()
    for cpid in "${CURRENT_PANES[@]}"; do
        IS_KNOWN=false
        for kpid in "${KNOWN_PANES[@]+"${KNOWN_PANES[@]}"}"; do
            if [ "$cpid" = "$kpid" ]; then
                IS_KNOWN=true
                break
            fi
        done
        if [ "$IS_KNOWN" = false ]; then
            NEW_PANES+=("$cpid")
        fi
    done

    # position ごとに適用対象の pane_id を割り当てる。
    declare -A PANE_BY_POSITION=()
    for i in "${!KNOWN_PANES[@]}"; do
        PANE_BY_POSITION["${KNOWN_POSITIONS[$i]}"]="${KNOWN_PANES[$i]}"
    done
    for i in "${!NEW_PANE_POSITIONS[@]}"; do
        if [ $i -lt ${#NEW_PANES[@]} ]; then
            PANE_BY_POSITION["${NEW_PANE_POSITIONS[$i]}"]="${NEW_PANES[$i]}"
        fi
    done

    LEAF_POSITIONS=()
    while IFS= read -r pos; do
        [ -n "$pos" ] && LEAF_POSITIONS+=("$pos")
    done <<< "$(layout_leaf_positions 0 0 2 2 "${POSITIONS[@]}")"

    SORTED_ENTRIES=()
    for pos in "${LEAF_POSITIONS[@]}"; do
        SORTED_ENTRIES+=("0:${PANE_BY_POSITION[$pos]}:$pos")
    done

    # tmux の layout 文字列は pane ID ではなく leaf order を基準に割り当てるため、
    # 適用前に pane の順番を layout の leaf order へ揃える。
    for idx in "${!SORTED_ENTRIES[@]}"; do
        ENTRY="${SORTED_ENTRIES[$idx]}"
        TARGET_PANE_ID=$(echo "$ENTRY" | cut -d: -f2)

        if [ "$idx" -lt "${#CURRENT_PANES[@]}" ]; then
            CURRENT_AT_IDX="${CURRENT_PANES[$idx]}"
            if [ "$TARGET_PANE_ID" != "$CURRENT_AT_IDX" ]; then
                tmux swap-pane -s "$TARGET_PANE_ID" -t "$CURRENT_AT_IDX" 2>/dev/null || true
                for j in "${!CURRENT_PANES[@]}"; do
                    if [ "${CURRENT_PANES[$j]}" = "$TARGET_PANE_ID" ]; then
                        CURRENT_PANES[$j]="$CURRENT_AT_IDX"
                    elif [ "${CURRENT_PANES[$j]}" = "$CURRENT_AT_IDX" ]; then
                        CURRENT_PANES[$j]="$TARGET_PANE_ID"
                    fi
                done
            fi
        fi
    done

    if [ "$ENTRY_COUNT" -gt 1 ]; then
        apply_tmux_layout "$TARGET_WINDOW" "${POSITIONS[@]}"
    fi

    # Add this window's information to the result JSON
    WINDOW_RESULT="[]"
    for ENTRY in "${SORTED_ENTRIES[@]}"; do
        PANE_ID=$(echo "$ENTRY" | cut -d: -f2)
        POSITION=$(echo "$ENTRY" | cut -d: -f3)
        WINDOW_RESULT=$(echo "$WINDOW_RESULT" | jq --arg pid "$PANE_ID" --arg pos "$POSITION" \
            '. + [{"pane_id": $pid, "position": $pos}]')
    done

    RESULT_JSON=$(echo "$RESULT_JSON" | jq --arg wid "$TARGET_WINDOW" --argjson entries "$WINDOW_RESULT" \
        '. + {($wid): $entries}')
done

# Output result
echo "$RESULT_JSON"
log "Layout applied successfully"
