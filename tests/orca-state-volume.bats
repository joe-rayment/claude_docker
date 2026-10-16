#!/usr/bin/env bats
#
# Orca's user-data-dir must not sit on the folder home.
#
# The folder home is a bind mount, and on a Mac a bind mount is not a Linux
# filesystem: Docker Desktop hands it through virtiofs, where a unix domain
# socket can be created and then neither chmod'd nor hard-linked. Orca's
# --serve path does both, in --user-data-dir, on every start:
#
#   chmod('<udd>/o-7563-9c89.sock')            -> EINVAL
#   link('<udd>/.pce...' -> 'daemon-v36.sock') -> ENOENT
#
# The first is an unhandled rejection, the second a fatal daemon start, and
# between them Orca never prints a Web client URL -- so the entrypoint gives
# up and the container exits. Measured on a Mac against orca-ide 1.4.197 on
# 2026-09-07: same image, same mounts, a user-data-dir on the folder home
# publishes no URL, one on a real Linux filesystem is ready in two seconds.
#
# No gate this repo has could see it. The suite runs on Linux, where that
# bind mount is an ordinary directory and all of it works; the ubuntu e2e
# in .github/workflows/image.yml is the same filesystem; and the macOS job
# runs Docker under colima, a different mount again, which currently dies
# in setup.sh's chown before Orca ever starts. So this file asserts the
# LAYOUT rather than the syscalls: Orca's user-data-dir is a named docker
# volume, at the path Orca already uses, and teardown takes it with the
# container. The syscalls themselves are only provable on a Mac with
# Docker Desktop, by starting Orca -- which is what was done by hand.
#
# Not frozen: this is a regression contract, not a bead's acceptance
# contract.

load helpers/setup

# The one line the `docker` stub logged for the invocation whose argv
# starts with $1 (its log is one line per invocation, argv joined).
ctr_line() {
    grep "^$1" "$CONTAINER_STUB_LOG" | head -1
}

# Assertions as FUNCTIONS, never as a bare `[[ ... ]]`. On macOS bats runs
# under the system bash 3.2, where a failing `[[ ]]` (and a failing `!`)
# does not trip errexit and the test goes on to pass -- so a `[[ ]]`
# assertion in the middle of a test body is checked on Linux and silently
# ignored on the Mac. A function call is checked on both.
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

@test "the container mounts a named volume at /home/agent/.config/orca, and nothing from the folder home" {
    mkdir -p "$PROJECT_DIR"
    local primary name line
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    name="claude-orca-$(basename "$primary")"
    line="$(ctr_line "run ")"
    [ -n "$line" ]

    # The volume is named after the container, so two folders never share
    # one and teardown can name it without keeping a record.
    contains "$line" "--volume $name-orca-state:/home/agent/.config/orca"

    # The home mount is still there -- .claude and the credentials do live
    # in the folder -- but nothing under it is Orca's user-data-dir.
    contains "$line" "--volume $primary/.claude-dev/home:/home/agent"
    lacks "$line" "$primary/.claude-dev/home/.config/orca"

    # And the entrypoint is not told to look anywhere else: the volume is
    # mounted at the path its default already points to.
    lacks "$line" "ORCA_USER_DATA_DIR"
}

@test "teardown removes the state volume, so the state still dies with the folder" {
    mkdir -p "$PROJECT_DIR"
    local primary name
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    name="claude-orca-$(basename "$primary")"

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --teardown"
    [ "$status" -eq 0 ]

    grep -qF "volume rm $name-orca-state" "$CONTAINER_STUB_LOG"
    # In that order: a volume in use by a container cannot be removed.
    [ "$(grep -n "^rm $name" "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)" \
      -lt "$(grep -n "^volume rm $name-orca-state" "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)" ]
    contains "$output" "Orca state removed"
}

@test "doctor names the state volume" {
    mkdir -p "$PROJECT_DIR"
    local primary name
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    name="claude-orca-$(basename "$primary")"
    stub_sshd_up "$primary"

    run bash -c "cd '$primary' && ./claude-dev --doctor"
    contains "$output" "$name-orca-state"
    contains "$output" "/home/agent/.config/orca"
}
