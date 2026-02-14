#!/bin/bash
# agent-panels — manage Claude Code teammate tmux panes
#
# Usage:
#   agent-panels toggle    Show if hidden, hide if visible
#   agent-panels hide      Move agent panes to background window
#   agent-panels show      Bring agent panes back into main window
#   agent-panels list      Show agent pane info
#   agent-panels help      Show keybinding reference
#
# Agent panes are "hidden" by moving them to a background tmux window
# named "_agents". Showing joins them back into the main window.
# Note: hide moves ALL non-active panes, not just Claude agent panes.

# No set -e: tmux commands can legitimately fail (dead panes, races),
# and we handle errors explicitly in each operation.

# Colors
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_BLUE='\033[34m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_RED='\033[31m'
C_RESET='\033[0m'

HIDDEN_WINDOW="_agents"

# ── Guards ─────────────────────────────────────────────────────────────

# Allow help to work outside tmux
if [ "${1:-}" = "help" ] || [ -z "${1:-}" ]; then
    : # Skip tmux check for help/no-args
elif [ -z "${TMUX:-}" ]; then
    echo -e "${C_RED}Error:${C_RESET} Not inside a tmux session." >&2
    echo "  agent-panels requires tmux. Start with: tmux new-session -s main" >&2
    exit 1
fi

# ── Helpers ────────────────────────────────────────────────────────────

# Get the current window ID (where the user is)
current_window() {
    tmux display-message -p '#{window_id}'
}

# Get the current window's pane count
pane_count() {
    tmux list-panes -t "$(current_window)" 2>/dev/null | wc -l
}

# Check if the hidden _agents window exists
agents_window_exists() {
    tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qx "$HIDDEN_WINDOW"
}

# Count live panes in the _agents window (filter out dead ones)
agents_pane_count() {
    if ! agents_window_exists; then
        echo "0"
        return
    fi
    local count=0
    local pane_ids
    pane_ids=$(tmux list-panes -t "$HIDDEN_WINDOW" -F '#{pane_id}' 2>/dev/null) || { echo "0"; return; }
    for pid in $pane_ids; do
        # Check if the pane's process is still running
        local pane_pid
        pane_pid=$(tmux display-message -t "$pid" -p '#{pane_pid}' 2>/dev/null) || continue
        if [ -n "$pane_pid" ] && kill -0 "$pane_pid" 2>/dev/null; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

# ── Commands ───────────────────────────────────────────────────────────

cmd_hide() {
    local count
    count=$(pane_count)

    if [ "$count" -le 1 ]; then
        echo -e "${C_DIM}No agent panes to hide (only 1 pane in window).${C_RESET}"
        return 0
    fi

    # Remember the active pane so we don't move it
    local active_pane
    active_pane=$(tmux display-message -p '#{pane_id}')

    # Collect all non-active pane IDs
    local panes_to_move=()
    while IFS= read -r pane_id; do
        if [ "$pane_id" != "$active_pane" ]; then
            panes_to_move+=("$pane_id")
        fi
    done < <(tmux list-panes -F '#{pane_id}')

    if [ ${#panes_to_move[@]} -eq 0 ]; then
        echo -e "${C_DIM}No agent panes to hide.${C_RESET}"
        return 0
    fi

    # Move each pane to the hidden window.
    # The first pane uses break-pane (creates the window).
    # Subsequent panes use join-pane to add to it.
    # Track actual moves — individual panes may fail (already dead, etc.)
    local first=true
    local moved=0
    for pid in "${panes_to_move[@]}"; do
        if $first; then
            if tmux break-pane -d -s "$pid" -n "$HIDDEN_WINDOW" 2>/dev/null; then
                first=false
                moved=$((moved + 1))
            fi
        else
            if agents_window_exists && tmux join-pane -d -s "$pid" -t "$HIDDEN_WINDOW" 2>/dev/null; then
                moved=$((moved + 1))
            fi
        fi
    done

    if [ "$moved" -gt 0 ]; then
        echo -e "${C_YELLOW}Hidden${C_RESET} ${moved} agent pane(s). ${C_DIM}Ctrl-b a to show.${C_RESET}"
    else
        echo -e "${C_DIM}No panes could be hidden.${C_RESET}"
    fi
}

cmd_show() {
    if ! agents_window_exists; then
        echo -e "${C_DIM}No hidden agents to show.${C_RESET}"
        return 0
    fi

    local current_win
    current_win=$(current_window)

    # Collect live panes from _agents window
    local panes_to_restore=()
    local pane_ids
    pane_ids=$(tmux list-panes -t "$HIDDEN_WINDOW" -F '#{pane_id}' 2>/dev/null) || true

    for pid in $pane_ids; do
        # Only restore panes with a live process
        local pane_pid
        pane_pid=$(tmux display-message -t "$pid" -p '#{pane_pid}' 2>/dev/null) || continue
        if [ -n "$pane_pid" ] && kill -0 "$pane_pid" 2>/dev/null; then
            panes_to_restore+=("$pid")
        fi
    done

    if [ ${#panes_to_restore[@]} -eq 0 ]; then
        # Clean up the empty window
        tmux kill-window -t "$HIDDEN_WINDOW" 2>/dev/null || true
        echo -e "${C_DIM}No live agents to show (panes have exited).${C_RESET}"
        return 0
    fi

    # Join each pane back into the current window.
    # Track actual restores in case individual panes fail.
    local restored=0
    for pid in "${panes_to_restore[@]}"; do
        if tmux join-pane -d -s "$pid" -t "$current_win" 2>/dev/null; then
            restored=$((restored + 1))
        fi
    done

    # Re-tile the layout
    tmux select-layout -t "$current_win" tiled 2>/dev/null || true

    # Kill the _agents window if it's now empty (should auto-close, but be safe)
    if agents_window_exists; then
        local remaining
        remaining=$(tmux list-panes -t "$HIDDEN_WINDOW" 2>/dev/null | wc -l)
        if [ "${remaining:-0}" -eq 0 ]; then
            tmux kill-window -t "$HIDDEN_WINDOW" 2>/dev/null || true
        fi
    fi

    if [ "$restored" -gt 0 ]; then
        echo -e "${C_GREEN}Restored${C_RESET} ${restored} agent pane(s). ${C_DIM}Ctrl-b a to hide.${C_RESET}"
    else
        echo -e "${C_DIM}No panes could be restored.${C_RESET}"
    fi
}

cmd_toggle() {
    if agents_window_exists && [ "$(agents_pane_count)" -gt 0 ]; then
        cmd_show
    else
        cmd_hide
    fi
}

cmd_list() {
    echo -e "${C_BOLD}Agent Panels${C_RESET}"
    echo ""

    # Visible panes (current window)
    local visible_count
    visible_count=$(pane_count)
    echo -e "${C_BOLD}Visible panes:${C_RESET} ${visible_count}"
    tmux list-panes -F "  #{pane_index}: #{pane_current_command} (pid #{pane_pid}) #{?pane_active,← active,}" 2>/dev/null || true

    # Hidden panes
    if agents_window_exists; then
        echo ""
        local hidden_count
        hidden_count=$(agents_pane_count)
        echo -e "${C_BOLD}Hidden panes:${C_RESET} ${hidden_count}"
        tmux list-panes -t "$HIDDEN_WINDOW" -F "  #{pane_index}: #{pane_current_command} (pid #{pane_pid})" 2>/dev/null || true
    else
        echo ""
        echo -e "${C_DIM}No hidden panes.${C_RESET}"
    fi
}

cmd_help() {
    echo -e "${C_BOLD}Agent Panel Shortcuts${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}Ctrl-b a${C_RESET}         Toggle agent panels (hide/show)"
    echo -e "  ${C_BOLD}Ctrl-b A${C_RESET}         List agent panes"
    echo -e "  ${C_BOLD}Ctrl-b Tab${C_RESET}       Next pane"
    echo -e "  ${C_BOLD}Ctrl-b S-Tab${C_RESET}     Previous pane"
    echo -e "  ${C_BOLD}Ctrl-b z${C_RESET}         Zoom/unzoom pane (full-screen)"
    echo -e "  ${C_BOLD}Ctrl-b h/j/k/l${C_RESET}  Vim-style pane navigation"
    echo -e "  ${C_BOLD}Ctrl-b t${C_RESET}         Re-tile layout"
    echo -e "  ${C_BOLD}Ctrl-b |${C_RESET}         Split horizontal"
    echo -e "  ${C_BOLD}Ctrl-b -${C_RESET}         Split vertical"
    echo -e "  ${C_BOLD}Mouse${C_RESET}            Click to select, drag to resize, scroll to browse"
    echo ""
    echo -e "${C_BOLD}Shell commands:${C_RESET}"
    echo -e "  ${C_BOLD}ap toggle${C_RESET}        Same as Ctrl-b a"
    echo -e "  ${C_BOLD}ap hide${C_RESET}          Hide all non-active panes"
    echo -e "  ${C_BOLD}ap show${C_RESET}          Bring hidden panes back"
    echo -e "  ${C_BOLD}ap list${C_RESET}          Show pane info"
}

# ── Main ───────────────────────────────────────────────────────────────

case "${1:-}" in
    toggle)  cmd_toggle ;;
    hide)    cmd_hide ;;
    show)    cmd_show ;;
    list)    cmd_list ;;
    help)    cmd_help ;;
    *)       cmd_help ;;
esac
