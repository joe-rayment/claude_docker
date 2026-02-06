#!/bin/bash
#
# Ralph Watchdog - Claude Code Execution Monitor
#
# Monitors the claude process in real-time, showing:
# - Whether a claude process is running + its PID
# - How long it's been running
# - Whether output is being received (via debug log file growth)
# - Clear WAITING / ACTIVE / STALLED status labels
#
# Usage:
#   ralph-watchdog        # Start monitoring (Ctrl+C to stop)
#   ralph-watch           # Same (alias)
#

# Colors
C_RED="\e[31m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_BLUE="\e[34m"
C_BOLD="\e[1m"
C_DIM="\e[2m"
C_RESET="\e[0m"

# Configuration
POLL_INTERVAL=10
STALL_THRESHOLD=120  # seconds with no file growth = STALLED

# State tracking
LAST_DEBUG_SIZE=0
LAST_LIVE_LOG_SIZE=0
LAST_OUTPUT_LOG_SIZE=0
LAST_CHANGE_TIME=0

# Format seconds into human-readable duration
format_duration() {
    local secs=$1
    if [ "$secs" -ge 3600 ]; then
        printf "%dh%02dm%02ds" $((secs / 3600)) $(((secs % 3600) / 60)) $((secs % 60))
    elif [ "$secs" -ge 60 ]; then
        printf "%dm%02ds" $((secs / 60)) $((secs % 60))
    else
        printf "%ds" "$secs"
    fi
}

# Format file size for display
format_size() {
    local bytes=$1
    if [ "$bytes" -ge 1048576 ]; then
        printf "%.1fM" "$(echo "$bytes / 1048576" | bc -l 2>/dev/null || echo "0")"
    elif [ "$bytes" -ge 1024 ]; then
        printf "%.1fK" "$(echo "$bytes / 1024" | bc -l 2>/dev/null || echo "0")"
    else
        printf "%dB" "$bytes"
    fi
}

# Get file size (0 if missing)
file_size() {
    local f="$1"
    if [ -f "$f" ]; then
        stat -c %s "$f" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# Find the latest ralph output log
find_latest_output_log() {
    local log_dir="/workspace/.ralph/logs"
    if [ -d "$log_dir" ]; then
        ls -t "$log_dir"/claude_output_*.log 2>/dev/null | head -1
    fi
}

# Main monitoring loop
main() {
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_BOLD}  Ralph Watchdog — Claude Code Monitor${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_DIM}  Polling every ${POLL_INTERVAL}s | Stall threshold: ${STALL_THRESHOLD}s${C_RESET}"
    echo -e "${C_DIM}  Press Ctrl+C to stop${C_RESET}"
    echo ""

    LAST_CHANGE_TIME=$(date +%s)

    while true; do
        local now=$(date +%s)
        local timestamp=$(date +%H:%M:%S)

        # Find claude process
        local claude_pid=$(pgrep -x claude 2>/dev/null | head -1)

        if [ -z "$claude_pid" ]; then
            echo -e "${C_DIM}[${timestamp}]${C_RESET} ${C_YELLOW}No claude process running${C_RESET}"
            # Reset state when no process
            LAST_DEBUG_SIZE=0
            LAST_LIVE_LOG_SIZE=0
            LAST_OUTPUT_LOG_SIZE=0
            LAST_CHANGE_TIME=$now
            sleep "$POLL_INTERVAL"
            continue
        fi

        # Get process elapsed time in seconds
        local elapsed
        elapsed=$(ps -o etimes= -p "$claude_pid" 2>/dev/null | tr -d ' ')
        if [ -z "$elapsed" ]; then
            echo -e "${C_DIM}[${timestamp}]${C_RESET} ${C_YELLOW}Process $claude_pid vanished${C_RESET}"
            sleep "$POLL_INTERVAL"
            continue
        fi

        local runtime=$(format_duration "$elapsed")

        # Track file sizes
        local debug_file="$HOME/.claude/debug/latest"
        local live_log="/workspace/.ralph/live.log"
        local output_log=$(find_latest_output_log)

        local cur_debug_size=$(file_size "$debug_file")
        local cur_live_log_size=$(file_size "$live_log")
        local cur_output_log_size=0
        if [ -n "$output_log" ]; then
            cur_output_log_size=$(file_size "$output_log")
        fi

        # Check if any file grew
        local grew=false
        if [ "$cur_debug_size" -gt "$LAST_DEBUG_SIZE" ] 2>/dev/null ||
           [ "$cur_live_log_size" -gt "$LAST_LIVE_LOG_SIZE" ] 2>/dev/null ||
           [ "$cur_output_log_size" -gt "$LAST_OUTPUT_LOG_SIZE" ] 2>/dev/null; then
            grew=true
            LAST_CHANGE_TIME=$now
        fi

        local silent_secs=$((now - LAST_CHANGE_TIME))

        # Determine status
        local status_label status_detail status_color
        if [ "$grew" = true ]; then
            status_label="ACTIVE"
            status_detail="receiving output (debug: $(format_size "$cur_debug_size"))"
            status_color="$C_GREEN"
        elif [ "$cur_debug_size" -eq 0 ] 2>/dev/null && [ "$silent_secs" -lt "$STALL_THRESHOLD" ]; then
            status_label="WAITING"
            status_detail="no response from API yet"
            status_color="$C_YELLOW"
        elif [ "$silent_secs" -ge "$STALL_THRESHOLD" ]; then
            status_label="STALLED?"
            status_detail="no new output for $(format_duration "$silent_secs")"
            status_color="$C_RED"
        else
            status_label="WAITING"
            status_detail="last output $(format_duration "$silent_secs") ago (debug: $(format_size "$cur_debug_size"))"
            status_color="$C_YELLOW"
        fi

        # Print status line
        echo -e "${C_DIM}[${timestamp}]${C_RESET} claude PID ${C_BOLD}${claude_pid}${C_RESET} | runtime: ${runtime} | ${status_color}${C_BOLD}${status_label}${C_RESET} — ${status_detail}"

        # Update tracked sizes
        LAST_DEBUG_SIZE=$cur_debug_size
        LAST_LIVE_LOG_SIZE=$cur_live_log_size
        LAST_OUTPUT_LOG_SIZE=$cur_output_log_size

        sleep "$POLL_INTERVAL"
    done
}

main
