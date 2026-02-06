#!/bin/bash
#
# Ralph Watchdog - Claude Code Execution Monitor
#
# Monitors the claude process in real-time, showing:
# - Process status, PID, and runtime
# - ACTIVE / WAITING / STALLED status based on log file growth
# - Last few lines of actual Claude output for visibility into what's happening
# - Process state from /proc (running, sleeping, disk I/O, etc.)
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
POLL_INTERVAL=5
STALL_THRESHOLD=120  # seconds with no file growth = STALLED
OUTPUT_LINES=6       # number of recent output lines to show

# State tracking
LAST_DEBUG_SIZE=0
LAST_LIVE_LOG_SIZE=0
LAST_OUTPUT_LOG_SIZE=0
LAST_CHANGE_TIME=0
PREV_OUTPUT_HASH=""

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

# Get process state description from /proc
get_process_state() {
    local pid=$1
    local state
    state=$(cat /proc/$pid/status 2>/dev/null | grep "^State:" | awk '{print $2, $3}')
    case "$state" in
        S*) echo "sleeping (waiting for I/O or event)" ;;
        R*) echo "running" ;;
        D*) echo "disk I/O wait (uninterruptible)" ;;
        T*) echo "stopped" ;;
        Z*) echo "zombie" ;;
        *)  echo "${state:-unknown}" ;;
    esac
}

# Get the best available output log for tailing
get_output_tail() {
    local lines=$1

    # Priority: ralph live.log > latest output log > debug log
    local live_log="/workspace/.ralph/live.log"
    local output_log=$(find_latest_output_log)
    local debug_log="$HOME/.claude/debug/latest"

    if [ -f "$live_log" ] && [ -s "$live_log" ]; then
        tail -n "$lines" "$live_log" 2>/dev/null
    elif [ -n "$output_log" ] && [ -f "$output_log" ] && [ -s "$output_log" ]; then
        tail -n "$lines" "$output_log" 2>/dev/null
    elif [ -f "$debug_log" ] && [ -s "$debug_log" ]; then
        # Debug log is JSON-ish, extract readable bits
        tail -n $((lines * 3)) "$debug_log" 2>/dev/null | grep -oP '"message":\s*"\K[^"]+' | tail -n "$lines"
    fi
}

# Main monitoring loop
main() {
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_BOLD}  Ralph Watchdog — Claude Code Monitor${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_DIM}  Polling every ${POLL_INTERVAL}s | Stall: ${STALL_THRESHOLD}s | Ctrl+C to stop${C_RESET}"
    echo ""

    LAST_CHANGE_TIME=$(date +%s)

    while true; do
        local now=$(date +%s)
        local timestamp=$(date +%H:%M:%S)

        # Find claude process
        local claude_pid=$(pgrep -x claude 2>/dev/null | head -1)

        if [ -z "$claude_pid" ]; then
            # Check if Ralph has halted with an error
            local ralph_status=""
            local ralph_action=""
            if [ -f "/workspace/.ralph/status.json" ]; then
                ralph_status=$(jq -r '.status // ""' /workspace/.ralph/status.json 2>/dev/null)
                ralph_action=$(jq -r '.last_action // ""' /workspace/.ralph/status.json 2>/dev/null)
            fi

            local cb_state=""
            if [ -f "/workspace/.ralph/.circuit_breaker_state" ]; then
                cb_state=$(jq -r '.state // ""' /workspace/.ralph/.circuit_breaker_state 2>/dev/null)
            fi

            if [ "$ralph_status" = "halted" ] || [ "$cb_state" = "OPEN" ]; then
                echo -e "${C_RED}${C_BOLD}[${timestamp}] ERROR: Ralph has stopped${C_RESET}"
                if [ "$ralph_action" = "permission_denied" ]; then
                    echo -e "  ${C_RED}! Permission denied — Claude was blocked from running commands${C_RESET}"
                    echo -e "  ${C_DIM}  This usually means --dangerously-skip-permissions wasn't applied${C_RESET}"
                fi
                if [ "$cb_state" = "OPEN" ]; then
                    local cb_reason=$(jq -r '.reason // "unknown"' /workspace/.ralph/.circuit_breaker_state 2>/dev/null)
                    echo -e "  ${C_RED}! Circuit breaker OPEN: ${cb_reason}${C_RESET}"
                    echo -e "  ${C_DIM}  Run: ralph --reset-circuit${C_RESET}"
                fi
                # Show last few errors from ralph.log
                if [ -f "/workspace/.ralph/logs/ralph.log" ]; then
                    local errors=$(grep -E '\[(ERROR|WARN)\]' /workspace/.ralph/logs/ralph.log | tail -3)
                    if [ -n "$errors" ]; then
                        echo -e "  ${C_DIM}┌─ recent errors ─────────────────────${C_RESET}"
                        echo "$errors" | while IFS= read -r line; do
                            printf "  ${C_DIM}│${C_RESET} ${C_RED}%.100s${C_RESET}\n" "$line"
                        done
                        echo -e "  ${C_DIM}└────────────────────────────────────${C_RESET}"
                    fi
                fi
            else
                echo -e "${C_DIM}[${timestamp}]${C_RESET} ${C_YELLOW}No claude process running${C_RESET}"
            fi

            LAST_DEBUG_SIZE=0
            LAST_LIVE_LOG_SIZE=0
            LAST_OUTPUT_LOG_SIZE=0
            LAST_CHANGE_TIME=$now
            PREV_OUTPUT_HASH=""
            sleep "$POLL_INTERVAL"
            continue
        fi

        # Get process elapsed time
        local elapsed
        elapsed=$(ps -o etimes= -p "$claude_pid" 2>/dev/null | tr -d ' ')
        if [ -z "$elapsed" ]; then
            echo -e "${C_DIM}[${timestamp}]${C_RESET} ${C_YELLOW}Process $claude_pid vanished${C_RESET}"
            sleep "$POLL_INTERVAL"
            continue
        fi

        local runtime=$(format_duration "$elapsed")
        local proc_state=$(get_process_state "$claude_pid")

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
        local status_label status_color
        if [ "$grew" = true ]; then
            status_label="ACTIVE"
            status_color="$C_GREEN"
        elif [ "$silent_secs" -ge "$STALL_THRESHOLD" ]; then
            status_label="STALLED"
            status_color="$C_RED"
        else
            status_label="WAITING"
            status_color="$C_YELLOW"
        fi

        # Print status header
        echo -e "${C_DIM}[${timestamp}]${C_RESET} PID ${C_BOLD}${claude_pid}${C_RESET} | ${runtime} | ${status_color}${C_BOLD}${status_label}${C_RESET} | silent: $(format_duration "$silent_secs") | ${C_DIM}${proc_state}${C_RESET}"

        # JSON mode buffers all output — warn user if output log stays empty
        if [ -n "$output_log" ] && [ "$cur_output_log_size" -eq 0 ] && [ "$elapsed" -ge 60 ]; then
            echo -e "  ${C_DIM}i Output log empty — JSON mode buffers until completion (normal)${C_RESET}"
        fi

        # Show recent output (only when it changed, to reduce noise)
        local current_output
        current_output=$(get_output_tail "$OUTPUT_LINES")
        local current_hash
        current_hash=$(echo "$current_output" | md5sum 2>/dev/null | cut -d' ' -f1)

        if [ -n "$current_output" ] && [ "$current_hash" != "$PREV_OUTPUT_HASH" ]; then
            echo -e "${C_DIM}  ┌─ recent output ──────────────────────${C_RESET}"
            echo "$current_output" | while IFS= read -r line; do
                # Truncate long lines for readability
                printf "  ${C_DIM}│${C_RESET} %.100s\n" "$line"
            done
            echo -e "${C_DIM}  └────────────────────────────────────${C_RESET}"
            PREV_OUTPUT_HASH="$current_hash"
        fi

        # Stall diagnostics
        if [ "$status_label" = "STALLED" ]; then
            echo -e "  ${C_RED}! Stalled for $(format_duration "$silent_secs").${C_RESET} Process state: ${proc_state}"
            # Check network connections
            local net_conns
            net_conns=$(ls /proc/$claude_pid/fd 2>/dev/null | wc -l)
            echo -e "  ${C_DIM}  Open file descriptors: ${net_conns}${C_RESET}"
        fi

        # Update tracked sizes
        LAST_DEBUG_SIZE=$cur_debug_size
        LAST_LIVE_LOG_SIZE=$cur_live_log_size
        LAST_OUTPUT_LOG_SIZE=$cur_output_log_size

        sleep "$POLL_INTERVAL"
    done
}

main
