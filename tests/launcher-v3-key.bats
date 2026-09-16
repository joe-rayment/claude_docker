#!/usr/bin/env bats
#
# Acceptance contract for claude-orca-qa2.7 -- FROZEN from RED-AT onward.
#
# v2 kept the OpenRouter key in .claude-dev/state/openrouter.key and the
# shell wrapper exported it; v3 deleted all of that with the Seatbelt half,
# so `delegate check` reports "OPENROUTER_API_KEY not set" until someone
# exports it by hand inside the container. The key belongs to the folder,
# so it lives in the folder-local home (gitignored with the rest of
# .claude-dev) at mode 600, rides into the VM as an env var, and is struck
# out of the container.log mirror exactly like GH_TOKEN.
#
# The key never reaches this test's terminal: CLAUDE_ORCA_KEY_INPUT stands
# in for /dev/tty, which bats does not have.

load helpers/setup

KEY="sk-or-v1-testkey0123456789abcdefghijklmnop"

@test "claude-dev key openrouter stores the key at .claude-dev/home/.openrouter.key with mode 600 without echoing it" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null

    printf '%s\n' "$KEY" > "$BATS_TEST_TMPDIR/key-input"
    run bash -c "cd '$primary' && CLAUDE_ORCA_KEY_INPUT='$BATS_TEST_TMPDIR/key-input' ./claude-dev key openrouter"
    [ "$status" -eq 0 ]

    keyfile="$primary/.claude-dev/home/.openrouter.key"
    [ -f "$keyfile" ]
    [ "$(cat "$keyfile")" = "$KEY" ]
    [ "$(file_mode "$keyfile")" = "600" ]

    # Never printed back, and never left anywhere else in the folder.
    [[ "$output" != *"$KEY"* ]]
    [[ "$output" == *".openrouter.key"* ]]
    ! grep -rqF "$KEY" "$primary/.claude-dev/run" 2>/dev/null
}

# claude-orca-376 supersedes this test's original assertion: the key file
# (.claude-dev/home/.openrouter.key) IS /home/agent/.openrouter.key inside
# the container -- same device, same inode -- so the entrypoint reads it
# for itself now. Putting it in the docker-run argv too was the exact
# round trip claude-orca-376 removes: an unpoliced key sitting in
# /proc/<pid>/environ for the whole container uptime, readable by every
# terminal, for a file already on a mount that terminal can already read.
@test "open does not pass OPENROUTER_API_KEY into the container even when the key file exists (claude-orca-376)" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null
    name="claude-orca-$(basename "$primary")"

    # No key: nothing about OpenRouter in the run line.
    line="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$line" != *"OPENROUTER_API_KEY"* ]]

    printf '%s\n' "$KEY" > "$BATS_TEST_TMPDIR/key-input"
    bash -c "cd '$primary' && CLAUDE_ORCA_KEY_INPUT='$BATS_TEST_TMPDIR/key-input' ./claude-dev key openrouter" >/dev/null

    # A fresh container: the key file exists, but the argv still carries
    # nothing about it -- the entrypoint reads the mounted file itself.
    rm -f "$CONTAINER_STUB_STATE/containers/$name"
    : > "$CONTAINER_STUB_LOG"
    : > "$primary/.claude-dev/run/container.log"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    line="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$line" != *"OPENROUTER_API_KEY"* ]]

    log="$primary/.claude-dev/run/container.log"
    [ -s "$log" ]
    ! grep -qF "OPENROUTER_API_KEY" "$log"
    [[ "$output" != *"$KEY"* ]]
}

@test "doctor reports the openrouter key as present or absent" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null

    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"openrouter key"* ]]
    [[ "$output" == *"absent"* ]]

    printf '%s\n' "$KEY" > "$BATS_TEST_TMPDIR/key-input"
    bash -c "cd '$primary' && CLAUDE_ORCA_KEY_INPUT='$BATS_TEST_TMPDIR/key-input' ./claude-dev key openrouter" >/dev/null

    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"openrouter key"* ]]
    [[ "$output" == *"present"* ]]
    [[ "$output" != *"$KEY"* ]]
}
