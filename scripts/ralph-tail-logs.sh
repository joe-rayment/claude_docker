#!/bin/bash
#
# Ralph Tail Logs - Live tail of Claude/Ralph output logs
#
# Tries multiple log sources in priority order:
#   1. .ralph/live.log (real-time Ralph output)
#   2. .ralph/logs/claude_output_*.log (most recent)
#   3. ~/.claude/debug/latest (Claude debug log)
#
# Used by ralph-tmux for the monitor pane.
#

echo "Waiting for output logs..."

# Wait for a log file to appear
for i in $(seq 1 60); do
    if [ -f /workspace/.ralph/live.log ]; then
        echo "Tailing: .ralph/live.log"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        tail -f /workspace/.ralph/live.log
        exit 0
    fi
    LOG=$(ls -t /workspace/.ralph/logs/claude_output_*.log 2>/dev/null | head -1)
    if [ -n "$LOG" ]; then
        echo "Tailing: $LOG"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        tail -f "$LOG"
        exit 0
    fi
    if [ -f "$HOME/.claude/debug/latest" ] && [ -s "$HOME/.claude/debug/latest" ]; then
        echo "Tailing: ~/.claude/debug/latest"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        tail -f "$HOME/.claude/debug/latest"
        exit 0
    fi
    sleep 2
done

echo "No log files found after 2 minutes."
echo "Press any key to exit."
read -n 1
