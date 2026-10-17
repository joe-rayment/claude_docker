#!/usr/bin/env bats
#
# Two folders, one port. A folder's port is chosen once, at register, by
# probing for a number nothing answers on -- and a folder whose container
# is down answers on nothing, so the next folder to register is handed the
# same number. Whichever of the two starts second then dies in `docker run`
# on "Bind for 127.0.0.1:<port> failed: port is already allocated", on every
# start, because the number is persisted (a real Mac, 2026-09-19: the
# second folder could not be bootstrapped at all).
#
# The `docker` stub fails a `run` whose host port a running container
# already publishes, the way docker's own allocator does, and answers
# `ps -aq` and the .HostConfig.PortBindings inspect -- the one place a
# stopped container's claim is still readable.

load helpers/setup

ctr_line() {
    grep "^$1" "$CONTAINER_STUB_LOG" | head -1
}

# A container that is some OTHER folder's: $1 name, $2 state, $3 port.
other_container() {
    mkdir -p "$CONTAINER_STUB_STATE/containers"
    echo "$2" > "$CONTAINER_STUB_STATE/containers/$1"
    {
        printf 'image=claude-orca:other\n'
        printf 'mount=/some/other/dir:/workspace/dir\n'
        printf 'port=%s:%s\n' "$3" "$3"
    } > "$CONTAINER_STUB_STATE/containers/$1.meta"
}

@test "open moves a folder off a persisted port another container now publishes, instead of dying in docker run" {
    export CLAUDE_ORCA_PORT_BASE=7940
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    name="claude-orca-$(basename "$primary")"
    port="$(jq -r '.port' "$primary/.claude-dev/claude-orca.json")"
    [ "$port" -ge 7940 ]

    # This folder's container goes away, and while it is gone another
    # folder's comes up on the same number.
    rm -f "$CONTAINER_STUB_STATE/containers/$name" "$CONTAINER_STUB_STATE/containers/$name.meta"
    other_container claude-orca-other running "$port"

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]
    [[ "$output" != *"port is already allocated"* ]]
    [[ "$output" == *"port $port is in use"* ]]

    moved="$(jq -r '.port' "$primary/.claude-dev/claude-orca.json")"
    [ "$moved" -gt "$port" ]
    [[ "$output" == *"moves to $moved"* ]]
    [ "$(cat "$primary/.claude-dev/run/port")" = "$moved" ]
    line="$(ctr_line "run ")"
    [[ "$line" == *"127.0.0.1:$moved:$moved"* ]]
    [[ "$line" == *"-e CLAUDE_ORCA_SSHD_PORT=$moved"* ]]
    [[ "$line" != *"ORCA_PORT="* ]]
    grep -qx "port=$moved" "$primary/.claude-dev/run/sshd.ready"

    # The other folder's container was never touched.
    [ "$(cat "$CONTAINER_STUB_STATE/containers/claude-orca-other")" = "running" ]
    ! grep -q "claude-orca-other" <(grep -E "^(rm|stop) " "$CONTAINER_STUB_LOG")
}

@test "open recovers from the created container a failed docker run left behind" {
    export CLAUDE_ORCA_PORT_BASE=7950
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    name="claude-orca-$(basename "$primary")"
    port="$(jq -r '.port' "$primary/.claude-dev/claude-orca.json")"

    # What the failing start leaves: this folder's name, `created`, bound
    # to the contested number -- and the other folder still running on it.
    echo created > "$CONTAINER_STUB_STATE/containers/$name"
    other_container claude-orca-other running "$port"

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]
    moved="$(jq -r '.port' "$primary/.claude-dev/claude-orca.json")"
    [ "$moved" -gt "$port" ]
    [ "$(cat "$CONTAINER_STUB_STATE/containers/$name")" = "running" ]
    grep -q "^port=$moved:$moved" "$CONTAINER_STUB_STATE/containers/$name.meta"
}

@test "register skips a port a stopped container was created with, though nothing answers on it" {
    export CLAUDE_ORCA_PORT_BASE=7960
    other_container claude-orca-other exited 7960

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    port="$(jq -r '.port' "$primary/.claude-dev/claude-orca.json")"
    [ "$port" -gt 7960 ]
    [[ "$output" != *"is in use by something else"* ]]
}

@test "a folder whose own running container holds its port is left where it is" {
    export CLAUDE_ORCA_PORT_BASE=7970
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    port="$(jq -r '.port' "$primary/.claude-dev/claude-orca.json")"

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already running"* ]]
    [[ "$output" != *"is in use by something else"* ]]
    [ "$(jq -r '.port' "$primary/.claude-dev/claude-orca.json")" = "$port" ]
    ! grep -q "^run " "$CONTAINER_STUB_LOG"
}
