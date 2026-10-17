#!/usr/bin/env bats
#
# Acceptance contract for claude-orca-wda -- FROZEN from RED-AT onward.
#
# A container with no "cpus" in claude-orca.json runs uncapped: it may use
# every core of the Docker VM, so parallel agents saturate the Mac
# (measured in claude-orca-19o). The contract here makes a null .cpus mean
# "default cap: half the VM's cores" -- on the create path as a --cpus flag
# with a one-line stderr note, and on the kept-container path applied live
# with `docker update`, which is never fatal and never a recreate.
#
# Nothing in the contract limits how many agents may run; only how much
# CPU one container may take.
#
# The docker stub answers `info --format '{{.NCPU}}'` out of
# $CONTAINER_STUB_NCPU (nothing when unset -- today's behaviour), answers
# `inspect -f '{{.HostConfig.NanoCpus}}'` out of $CONTAINER_STUB_NANOCPUS,
# and takes $CONTAINER_STUB_UPDATE_RC as `update` failing.

load helpers/setup

# Ambient environment of the dev box this suite runs inside: the launcher
# must see none of it.
unset PROJECT_DIR || true
unset CLAUDE_ORCA_ROOT || true
unset BEADS_DIR || true

# The one line the `docker` stub logged for the invocation whose argv
# starts with $1 (its log is one line per invocation, argv joined).
ctr_line() {
    grep "^$1" "$CONTAINER_STUB_LOG" | head -1
}

# Assertions as FUNCTIONS, never as a bare `[[ ... ]]`: under bash 3.2 a
# failing bare `[[ ... ]]` that is not the last command does not stop the
# test (errexit ignores it), so it would pass for the wrong reason.
contains() {
    case "$1" in
        *"$2"*) return 0 ;;
    esac
    printf 'expected to contain: %s\n           actual: %s\n' "$2" "$1" >&2
    return 1
}

lacks() {
    case "$1" in
        *"$2"*)
            printf 'expected NOT to contain: %s\n               actual: %s\n' "$2" "$1" >&2
            return 1 ;;
    esac
    return 0
}

log_contains() {
    if ! grep -q -- "$1" "$CONTAINER_STUB_LOG"; then
        printf 'expected the stub log to contain: %s\nlog was:\n%s\n' "$1" "$(cat "$CONTAINER_STUB_LOG")" >&2
        return 1
    fi
    return 0
}

log_lacks() {
    if grep -q -- "$1" "$CONTAINER_STUB_LOG"; then
        printf 'expected the stub log NOT to contain: %s\nlog was:\n%s\n' "$1" "$(cat "$CONTAINER_STUB_LOG")" >&2
        return 1
    fi
    return 0
}

# A project whose claude-orca.json carries .cpus BEFORE bootstrap registers
# it: register writes its defaults only when the file is absent.
make_project_cpus() {
    local dir="$1" cpus="$2"
    mkdir -p "$dir/.claude-dev"
    printf '{"version":3,"port":null,"cpus":%s,"memory":null,"extraMounts":[]}\n' "$cpus" \
        > "$dir/.claude-dev/claude-orca.json"
    make_project_v3 "$dir"
}

# The bootstrap itself ends in register -> open, which creates the
# container -- so the `run` line out of one make_project_v3 IS the create
# path, and a second `./claude-dev open` over the same folder is the
# kept-container path.
kept_container_open() {
    export CONTAINER_STUB_NANOCPUS="${CONTAINER_STUB_NANOCPUS:-0}"
    : > "$CONTAINER_STUB_LOG"
    bash -c "cd '$1' && ./claude-dev open"
}

@test "null cpus caps a new container at half the VM cores" {
    export CONTAINER_STUB_NCPU=10
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    line="$(ctr_line "run ")"
    [ -n "$line" ]
    contains "$line" "--cpus 5"
}

@test "odd and tiny core counts round down but never below one" {
    export CONTAINER_STUB_NCPU=3
    odd_dir="$BATS_TEST_TMPDIR/odd"
    mkdir -p "$odd_dir"
    run make_project_v3 "$odd_dir"
    [ "$status" -eq 0 ]
    contains "$(ctr_line "run ")" "--cpus 1"

    export CONTAINER_STUB_NCPU=1
    tiny_dir="$BATS_TEST_TMPDIR/tiny"
    mkdir -p "$tiny_dir"
    : > "$CONTAINER_STUB_LOG"
    run make_project_v3 "$tiny_dir"
    [ "$status" -eq 0 ]
    contains "$(ctr_line "run ")" "--cpus 1"
}

@test "an explicit cpus wins verbatim and is not announced" {
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_cpus "$primary" 2.5
    [ "$status" -eq 0 ]

    line="$(ctr_line "run ")"
    [ -n "$line" ]
    contains "$line" "--cpus 2.5"
    lacks "$output" "cpu cap:"
}

@test "cpus 0 is the opt-out" {
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_cpus "$primary" 0
    [ "$status" -eq 0 ]

    line="$(ctr_line "run ")"
    [ -n "$line" ]
    contains "$line" "--cpus 0"
}

@test "no answer from docker info means no flag" {
    unset CONTAINER_STUB_NCPU
    primary="$(abspath "$PROJECT_DIR")"
    mkdir -p "$primary"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    line="$(ctr_line "run ")"
    [ -n "$line" ]
    lacks "$line" "--cpus"

    export CONTAINER_STUB_NCPU=garbage
    other="$BATS_TEST_TMPDIR/garbage-ncpu"
    mkdir -p "$other"
    : > "$CONTAINER_STUB_LOG"
    run make_project_v3 "$other"
    [ "$status" -eq 0 ]

    line="$(ctr_line "run ")"
    [ -n "$line" ]
    lacks "$line" "--cpus"
}

@test "the default is announced exactly once" {
    export CONTAINER_STUB_NCPU=10
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    count="$(printf '%s\n' "$output" | grep -c 'cpu cap: 5 of 10 cores' || true)"
    [ "$count" -eq 1 ]
    contains "$output" \
        'cpu cap: 5 of 10 cores (default; set "cpus" in claude-orca.json -- 0 = no cap)'
}

@test "a kept container gets the cap applied live" {
    export CONTAINER_STUB_NCPU=10
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    name="claude-orca-$(basename "$primary")"

    export CONTAINER_STUB_NANOCPUS=0
    run kept_container_open "$primary"
    [ "$status" -eq 0 ]

    log_contains "^update --cpus 5 $name\$"
    log_lacks "^rm "
    [ "$(grep -c '^run ' "$CONTAINER_STUB_LOG" || true)" -eq 0 ]
}

@test "a kept container already at the cap is left alone" {
    export CONTAINER_STUB_NCPU=10
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    export CONTAINER_STUB_NANOCPUS=5000000000
    run kept_container_open "$primary"
    [ "$status" -eq 0 ]

    log_lacks "^update"
}

@test "a failing update is not fatal" {
    export CONTAINER_STUB_NCPU=10
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    export CONTAINER_STUB_NANOCPUS=0
    export CONTAINER_STUB_UPDATE_RC=1
    run kept_container_open "$primary"
    [ "$status" -eq 0 ]

    contains "$output" "could not apply the cpu cap"
}
