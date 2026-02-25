#!/bin/bash
# Start Dolt SQL server and wait for readiness.
# Called from entrypoint.sh and guided-setup.sh.
# Idempotent — safe to call multiple times.

DOLT_DATA="/home/agent/.dolt-data"
DOLT_PORT=3307
DOLT_HOST=127.0.0.1
PID_FILE="/tmp/.dolt-server.pid"
LOG_FILE="/tmp/.dolt-server.log"
MAX_WAIT=15

# Bail if dolt not installed
command -v dolt &>/dev/null || exit 0

# Already listening? Nothing to do.
if timeout 1 bash -c "echo > /dev/tcp/$DOLT_HOST/$DOLT_PORT" 2>/dev/null; then
    exit 0
fi

# Clean up stale PID if the process is dead
if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        # Process alive but not listening — kill and restart
        kill "$old_pid" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$PID_FILE"
fi

# Ensure data directory exists and is a dolt repo
mkdir -p "$DOLT_DATA"
if [ ! -d "$DOLT_DATA/.dolt" ]; then
    (cd "$DOLT_DATA" && dolt init --name "agent" --email "agent@localhost") >/dev/null 2>&1 || {
        echo "start-dolt: failed to initialize Dolt data directory" >&2
        exit 1
    }
fi

# Remove stale lock files if no dolt process is actually running
if ! pgrep -x dolt >/dev/null 2>&1; then
    rm -f "$DOLT_DATA/.dolt/dolt-lock"
    # noms/LOCK can also block restart after ungraceful shutdown
    find "$DOLT_DATA/.dolt" -name LOCK -delete 2>/dev/null || true
fi

# CRITICAL: cd into data directory — dolt uses CWD as default data_dir.
# Using --data-dir from elsewhere does NOT work the same way.
cd "$DOLT_DATA" || { echo "start-dolt: cannot cd to $DOLT_DATA" >&2; exit 1; }

# Truncate log for this startup attempt
: > "$LOG_FILE"

# Start server — prefer config.yaml (has host/port/log settings), fall back to CLI flags
if [ -f "config.yaml" ]; then
    dolt sql-server --config config.yaml </dev/null >>"$LOG_FILE" 2>&1 &
else
    dolt sql-server \
        --host "$DOLT_HOST" \
        --port "$DOLT_PORT" \
        --loglevel warning \
        </dev/null >>"$LOG_FILE" 2>&1 &
fi
echo $! > "$PID_FILE"

# Wait for readiness — check both port and process health
elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT" ]; do
    if timeout 1 bash -c "echo > /dev/tcp/$DOLT_HOST/$DOLT_PORT" 2>/dev/null; then
        exit 0  # Ready
    fi
    # Bail early if process died
    if ! kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        echo "start-dolt: server process died during startup" >&2
        [ -s "$LOG_FILE" ] && tail -5 "$LOG_FILE" >&2
        exit 1
    fi
    sleep 0.5
    elapsed=$((elapsed + 1))
done

echo "start-dolt: server failed to start within ${MAX_WAIT}s" >&2
[ -s "$LOG_FILE" ] && tail -5 "$LOG_FILE" >&2
exit 1
