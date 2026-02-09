#!/bin/bash

# Test helpers for bats experience tests
# Provides tmux-based interaction helpers and polling utilities

TEST_SESSION="claude-dev-test"

setup_tmux() {
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    tmux new-session -d -s "$TEST_SESSION" -x 120 -y 40
}

teardown_tmux() {
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
}

# Send keys to the test tmux session
send_keys() {
    tmux send-keys -t "$TEST_SESSION" "$@"
}

# Capture the current tmux pane content
capture_pane() {
    tmux capture-pane -t "$TEST_SESSION" -p
}

# Poll for text in the tmux pane, with timeout
# Usage: wait_for_text "pattern" [timeout_seconds]
wait_for_text() {
    local pattern="$1"
    local timeout="${2:-10}"
    local deadline=$((SECONDS + timeout))

    while [ $SECONDS -lt $deadline ]; do
        if capture_pane | grep -q "$pattern"; then
            return 0
        fi
        sleep 0.3
    done
    echo "Timed out waiting for: $pattern" >&2
    echo "--- Pane content ---" >&2
    capture_pane >&2
    echo "--- End pane content ---" >&2
    return 1
}

# Run a script in the tmux session (unsets TMUX to avoid skip guards)
run_in_pane() {
    send_keys "unset TMUX && $*" Enter
}
