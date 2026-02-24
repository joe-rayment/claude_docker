#!/bin/bash
# Start Dolt SQL server and wait for readiness.
# Called from entrypoint.sh and guided-setup.sh.
# Idempotent — safe to call multiple times.

DOLT_DATA="/home/agent/.dolt-data"
DOLT_PORT=3307
DOLT_HOST=127.0.0.1
PID_FILE="/tmp/.dolt-server.pid"
MAX_WAIT_SECONDS=10

# Bail if dolt not installed
command -v dolt &>/dev/null || exit 0

# Check if server is already running and healthy
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    if timeout 1 bash -c "echo > /dev/tcp/$DOLT_HOST/$DOLT_PORT" 2>/dev/null; then
        exit 0  # Already running and healthy
    fi
    # Process alive but not responding — kill and restart
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    sleep 1
fi

# Check for port conflict (another process on the port)
if timeout 1 bash -c "echo > /dev/tcp/$DOLT_HOST/$DOLT_PORT" 2>/dev/null; then
    echo "start-dolt: port $DOLT_PORT already in use by another process" >&2
    exit 1
fi

# Ensure data directory exists and is a dolt repo
mkdir -p "$DOLT_DATA"
if [ ! -d "$DOLT_DATA/.dolt" ]; then
    (cd "$DOLT_DATA" && dolt init --name "agent" --email "agent@localhost") >/dev/null 2>&1 || {
        echo "start-dolt: failed to initialize Dolt data directory" >&2
        exit 1
    }
fi

# Start server in background
(cd "$DOLT_DATA" && dolt sql-server \
    --host "$DOLT_HOST" \
    --port "$DOLT_PORT" \
    --log-level warning \
    </dev/null &) 2>/dev/null
echo $! > "$PID_FILE"

# Wait for readiness (poll with 0.5s interval)
elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT_SECONDS" ]; do
    if timeout 1 bash -c "echo > /dev/tcp/$DOLT_HOST/$DOLT_PORT" 2>/dev/null; then
        exit 0  # Server is ready
    fi
    sleep 0.5
    elapsed=$((elapsed + 1))
done

echo "start-dolt: server failed to start within ${MAX_WAIT_SECONDS}s" >&2
exit 1
