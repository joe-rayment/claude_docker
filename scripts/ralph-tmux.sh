#!/bin/bash
#
# Ralph TMux - Better monitoring layout for Ralph loops
#
# Creates a 3-pane tmux session:
#   Top-left:     Ralph loop (main execution)
#   Top-right:    Live tail of Claude output (real-time visibility)
#   Bottom:       Watchdog (process health + status)
#
# Usage:
#   ralph-tmux [ralph arguments...]
#
# Examples:
#   ralph-tmux              # Run ralph loop with monitoring
#   ralph-tmux --resume     # Resume ralph with monitoring
#

set -e

# Colors
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_RESET="\033[0m"

SESSION_NAME="ralph-$(date +%s)"
RALPH_ARGS="$*"

# Build the ralph command (use wrapper for git automation)
if [ -x /usr/local/bin/ralph-wrapper.sh ]; then
    RALPH_CMD="/usr/local/bin/ralph-wrapper.sh $RALPH_ARGS"
else
    RALPH_CMD="ralph $RALPH_ARGS"
fi

# Determine which log to tail (try ralph logs first, fall back to claude debug)
# The tail command tries multiple sources in priority order
TAIL_CMD='bash -c '"'"'
    echo "Waiting for output logs..."
    # Wait for a log file to appear
    for i in $(seq 1 60); do
        if [ -f /workspace/.ralph/live.log ]; then
            echo "Tailing: .ralph/live.log"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            tail -f /workspace/.ralph/live.log
            break
        fi
        LOG=$(ls -t /workspace/.ralph/logs/claude_output_*.log 2>/dev/null | head -1)
        if [ -n "$LOG" ]; then
            echo "Tailing: $LOG"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            tail -f "$LOG"
            break
        fi
        if [ -f "$HOME/.claude/debug/latest" ] && [ -s "$HOME/.claude/debug/latest" ]; then
            echo "Tailing: ~/.claude/debug/latest"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            tail -f "$HOME/.claude/debug/latest"
            break
        fi
        sleep 2
    done
    if [ $i -eq 60 ]; then
        echo "No log files found after 2 minutes."
        echo "Press any key to exit."
        read -n 1
    fi
'"'"''

echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo -e "${C_BOLD}  Ralph TMux Monitor${C_RESET}"
echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo ""
echo -e "  ${C_BOLD}Top-left:${C_RESET}   Ralph loop"
echo -e "  ${C_BOLD}Top-right:${C_RESET}  Live Claude output"
echo -e "  ${C_BOLD}Bottom:${C_RESET}     Watchdog (health monitor)"
echo ""
echo -e "${C_DIM}  Ctrl+B then arrow keys to switch panes${C_RESET}"
echo -e "${C_DIM}  Ctrl+B then d to detach${C_RESET}"
echo ""

# Create tmux session with ralph loop in the first pane
tmux new-session -d -s "$SESSION_NAME" -c /workspace

# Top-left pane: Ralph loop
tmux send-keys -t "$SESSION_NAME:0.0" "$RALPH_CMD" Enter

# Split right for live output tail (40% width)
tmux split-window -h -p 40 -t "$SESSION_NAME:0.0" -c /workspace
tmux send-keys -t "$SESSION_NAME:0.1" "$TAIL_CMD" Enter

# Split bottom for watchdog (30% height, spans full width)
tmux split-window -v -p 30 -t "$SESSION_NAME:0.0" -c /workspace
tmux send-keys -t "$SESSION_NAME:0.2" "ralph-watchdog" Enter

# Focus on the ralph loop pane
tmux select-pane -t "$SESSION_NAME:0.0"

# Attach
exec tmux attach-session -t "$SESSION_NAME"
