#!/bin/bash

# Voicetree Server Manager
# Manages the FastAPI backend process inside the container
# Usage: voicetree-server start|stop|restart|status|logs

VENV="/opt/voicetree/voicetree/.venv"
SERVER="/opt/voicetree/voicetree/server.py"
PID_FILE="/tmp/voicetree-server.pid"
LOG_FILE="/tmp/voicetree-server.log"
PORT=8001

# Colors
C_RED="\e[31m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_BOLD="\e[1m"
C_DIM="\e[2m"
C_RESET="\e[0m"

is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

cmd_start() {
    if is_running; then
        echo -e "${C_YELLOW}Voicetree backend already running${C_RESET} (PID $(cat "$PID_FILE"))"
        return 0
    fi

    if [ ! -f "$SERVER" ]; then
        echo -e "${C_RED}Error: server.py not found at $SERVER${C_RESET}"
        return 1
    fi

    # Source API keys from workspace .env if it exists
    if [ -f /workspace/.env ]; then
        set -a
        source /workspace/.env
        set +a
    fi

    echo -e "${C_YELLOW}Starting Voicetree backend on port ${PORT}...${C_RESET}"
    cd /opt/voicetree/voicetree
    nohup "$VENV/bin/python" "$SERVER" >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"

    # Wait briefly and verify it started
    sleep 2
    if is_running; then
        echo -e "${C_GREEN}Voicetree backend started${C_RESET} (PID $(cat "$PID_FILE"), log: $LOG_FILE)"
    else
        echo -e "${C_RED}Failed to start — check logs:${C_RESET} $LOG_FILE"
        rm -f "$PID_FILE"
        return 1
    fi
}

cmd_stop() {
    if ! is_running; then
        echo -e "${C_YELLOW}Voicetree backend is not running${C_RESET}"
        rm -f "$PID_FILE"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")
    echo -e "${C_YELLOW}Stopping Voicetree backend (PID $pid)...${C_RESET}"
    kill "$pid" 2>/dev/null
    # Wait up to 5 seconds for graceful shutdown
    for i in $(seq 1 10); do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.5
    done
    # Force kill if still running
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
    echo -e "${C_GREEN}Voicetree backend stopped${C_RESET}"
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_status() {
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE")
        echo -e "${C_GREEN}Voicetree backend: running${C_RESET} (PID $pid, port $PORT)"
        # Quick health check
        if curl -sf "http://localhost:${PORT}/health" &>/dev/null; then
            echo -e "  ${C_GREEN}Health: OK${C_RESET}"
        else
            echo -e "  ${C_YELLOW}Health: not responding yet${C_RESET}"
        fi
    else
        echo -e "${C_DIM}Voicetree backend: not running${C_RESET}"
        rm -f "$PID_FILE"
    fi
}

cmd_logs() {
    if [ -f "$LOG_FILE" ]; then
        tail -f "$LOG_FILE"
    else
        echo -e "${C_DIM}No log file yet. Start the server first.${C_RESET}"
    fi
}

# --- Main ---
case "${1:-}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    status)  cmd_status ;;
    logs)    cmd_logs ;;
    *)
        echo "Usage: voicetree-server {start|stop|restart|status|logs}"
        exit 1
        ;;
esac
