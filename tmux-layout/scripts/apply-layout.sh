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

    # Validate position combinations
    HAS_TOP=false; HAS_BOTTOM=false
    HAS_LEFT=false; HAS_RIGHT=false
    HAS_TOP_LEFT=false; HAS_TOP_RIGHT=false
    HAS_BOTTOM_LEFT=false; HAS_BOTTOM_RIGHT=false

    for pos in "${POSITION_LIST[@]}"; do
        case "$pos" in
            top)          HAS_TOP=true ;;
            bottom)       HAS_BOTTOM=true ;;
            left)         HAS_LEFT=true ;;
            right)        HAS_RIGHT=true ;;
            top-left)     HAS_TOP_LEFT=true ;;
            top-right)    HAS_TOP_RIGHT=true ;;
            bottom-left)  HAS_BOTTOM_LEFT=true ;;
            bottom-right) HAS_BOTTOM_RIGHT=true ;;
            *) die "Unknown position: $pos" ;;
        esac
    done

    # 2分割と4分割の position は混在させない。
    if [[ "$HAS_TOP" = true || "$HAS_BOTTOM" = true || "$HAS_LEFT" = true || "$HAS_RIGHT" = true ]] && [[ "$HAS_TOP_LEFT" = true || "$HAS_TOP_RIGHT" = true || "$HAS_BOTTOM_LEFT" = true || "$HAS_BOTTOM_RIGHT" = true ]]; then
        die "Conflicting positions in group $group_id: cannot mix 2-pane positions with top-left/top-right/bottom-left/bottom-right"
    fi

    if [[ "$HAS_TOP" = true || "$HAS_BOTTOM" = true ]] && [[ "$HAS_LEFT" = true || "$HAS_RIGHT" = true ]]; then
        die "Conflicting positions in group $group_id: cannot mix top/bottom with left/right"
    fi

    # top requires bottom (and vice versa)
    if [[ "$HAS_TOP" = true && "$HAS_BOTTOM" != true ]]; then
        die "Position 'top' requires 'bottom' in group $group_id"
    fi
    if [[ "$HAS_BOTTOM" = true && "$HAS_TOP" != true ]]; then
        die "Position 'bottom' requires 'top' in group $group_id"
    fi

    # left requires right (and vice versa)
    if [[ "$HAS_LEFT" = true && "$HAS_RIGHT" != true ]]; then
        die "Position 'left' requires 'right' in group $group_id"
    fi
    if [[ "$HAS_RIGHT" = true && "$HAS_LEFT" != true ]]; then
        die "Position 'right' requires 'left' in group $group_id"
    fi

    # top-left/top-right must come in pairs
    if [[ "$HAS_TOP_LEFT" = true && "$HAS_TOP_RIGHT" != true ]]; then
        die "Position 'top-left' requires 'top-right' in group $group_id"
    fi
    if [[ "$HAS_TOP_RIGHT" = true && "$HAS_TOP_LEFT" != true ]]; then
        die "Position 'top-right' requires 'top-left' in group $group_id"
    fi

    # bottom-left/bottom-right must come in pairs
    if [[ "$HAS_BOTTOM_LEFT" = true && "$HAS_BOTTOM_RIGHT" != true ]]; then
        die "Position 'bottom-left' requires 'bottom-right' in group $group_id"
    fi
    if [[ "$HAS_BOTTOM_RIGHT" = true && "$HAS_BOTTOM_LEFT" != true ]]; then
        die "Position 'bottom-right' requires 'bottom-left' in group $group_id"
    fi

    # At least some valid combination must exist
    # top-left only (without right) is caught above, so reaching here means OK
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

# Position priority mapping
# Positions in tiled layout:
#   2 panes (top/bottom): select-layout even-vertical
#   2 panes (left/right): select-layout even-horizontal
#   4 panes (quadrant): select-layout tiled
#   whole: 1 pane

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

    # Apply layout
    if [ "$ENTRY_COUNT" -eq 1 ]; then
        # whole: do nothing (single pane)
        :
    elif [ "$ENTRY_COUNT" -eq 2 ]; then
        HAS_LEFT_RIGHT=false
        for pos in "${POSITIONS[@]}"; do
            if [ "$pos" = "left" ] || [ "$pos" = "right" ]; then
                HAS_LEFT_RIGHT=true
            fi
        done

        if [ "$HAS_LEFT_RIGHT" = true ]; then
            tmux select-layout -t "${SESSION}:${TARGET_WINDOW}" even-horizontal
        else
            tmux select-layout -t "${SESSION}:${TARGET_WINDOW}" even-vertical
        fi
    elif [ "$ENTRY_COUNT" -eq 4 ]; then
        # 4-way split: tiled
        tmux select-layout -t "${SESSION}:${TARGET_WINDOW}" tiled
    fi

    # Sort panes based on position order
    # Position order: top-left(0), top-right(1), bottom-left(2), bottom-right(3), top/left(0), bottom/right(1), whole(0)
    # Rearrange pane_ids by position order and use swap-pane to reorder

    # Re-fetch (pane list after splits)
    CURRENT_PANES=()
    while IFS= read -r pid; do
        [ -n "$pid" ] && CURRENT_PANES+=("$pid")
    done <<< "$(tmux list-panes -t "${SESSION}:${TARGET_WINDOW}" -F '#{pane_id}')"

    # Position -> order mapping
    position_order() {
        case "$1" in
            top-left)     echo 0 ;;
            top-right)    echo 1 ;;
            bottom-left)  echo 2 ;;
            bottom-right) echo 3 ;;
            top)          echo 0 ;;
            bottom)       echo 1 ;;
            left)         echo 0 ;;
            right)        echo 1 ;;
            whole)        echo 0 ;;
            *)            echo 99 ;;
        esac
    }

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

    # Create a pane list sorted by position
    # (order, pane_id, position) list
    SORTED_ENTRIES=()
    for i in "${!KNOWN_PANES[@]}"; do
        ORD=$(position_order "${KNOWN_POSITIONS[$i]}")
        SORTED_ENTRIES+=("$ORD:${KNOWN_PANES[$i]}:${KNOWN_POSITIONS[$i]}")
    done
    for i in "${!NEW_PANE_POSITIONS[@]}"; do
        ORD=$(position_order "${NEW_PANE_POSITIONS[$i]}")
        if [ $i -lt ${#NEW_PANES[@]} ]; then
            SORTED_ENTRIES+=("$ORD:${NEW_PANES[$i]}:${NEW_PANE_POSITIONS[$i]}")
        fi
    done

    # Sort
    IFS=$'\n' SORTED_ENTRIES=($(sort <<< "${SORTED_ENTRIES[*]}")); unset IFS

    # Place panes in correct positions using swap-pane
    for idx in "${!SORTED_ENTRIES[@]}"; do
        ENTRY="${SORTED_ENTRIES[$idx]}"
        TARGET_PANE_ID=$(echo "$ENTRY" | cut -d: -f2)

        if [ "$idx" -lt "${#CURRENT_PANES[@]}" ]; then
            CURRENT_AT_IDX="${CURRENT_PANES[$idx]}"
            if [ "$TARGET_PANE_ID" != "$CURRENT_AT_IDX" ]; then
                tmux swap-pane -s "$TARGET_PANE_ID" -t "$CURRENT_AT_IDX" 2>/dev/null || true
                # Update CURRENT_PANES
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
