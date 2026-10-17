#!/usr/bin/env bats
#
# Acceptance contract for claude-orca-7uy -- FROZEN from RED-AT onward.
#
# The launcher mounts four per-container docker volumes next to the state
# volume -- ~/.cache, ~/.npm, ~/.local/share/opencode and ~/worktrees --
# because file-creating work on the macOS bind-mount share is what the
# Docker VM pays for (claude-orca-19o: 3000 small files create/stat/rm =
# 901 ms and 61,129 VM interrupts on the share vs 59 ms and 330 on a docker
# volume). The project folder and the rest of /home/agent stay bind mounts,
# ahead of the volumes, and the container is told which dirs are volumes in
# CLAUDE_ORCA_VOLUME_DIRS -- the one interface with the container half
# (claude-orca-1eh). A container predating the scratch mounts is recreated;
# teardown removes them with the container.

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

# needle $2 appears in haystack $1 strictly before needle $3.
before() {
    local ia ib
    ia="$(awk -v s="$1" -v n="$2" 'BEGIN { print index(s, n) }')"
    ib="$(awk -v s="$1" -v n="$3" 'BEGIN { print index(s, n) }')"
    if [ "$ia" -eq 0 ] || [ "$ib" -eq 0 ] || [ "$ib" -lt "$ia" ]; then
        printf 'expected %s\n       before: %s\n       actual: %s\n' "$2" "$3" "$1" >&2
        return 1
    fi
    return 0
}

@test "docker run mounts the four scratch volumes, named after the container" {
    mkdir -p "$PROJECT_DIR"
    local primary name
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    name="claude-orca-$(basename "$primary")"
    line="$(ctr_line "run ")"
    [ -n "$line" ]

    # Named after the container, like the state volume, so two folders
    # never share one and teardown can name them without a record.
    contains "$line" "--volume $name-cache:/home/agent/.cache"
    contains "$line" "--volume $name-npm:/home/agent/.npm"
    contains "$line" "--volume $name-opencode:/home/agent/.local/share/opencode"
    contains "$line" "--volume $name-worktrees:/home/agent/worktrees"
}

@test "the project folder and the home stay bind mounts, ahead of the volumes" {
    mkdir -p "$PROJECT_DIR"
    local primary
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    line="$(ctr_line "run ")"
    [ -n "$line" ]

    contains "$line" "--volume $primary:/workspace/$(basename "$primary")"
    contains "$line" "--volume $primary/.claude-dev/home:/home/agent"
    # The user keeps seeing the folder the template was started in -- the
    # bind mounts are what the Mac and Orca look at, so they come first.
    before "$line" \
        "--volume $primary/.claude-dev/home:/home/agent" \
        "--volume claude-orca-$(basename "$primary")-cache:"
}

@test "the container is told which dirs are volumes" {
    mkdir -p "$PROJECT_DIR"
    local primary
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    contains "$(ctr_line "run ")" \
        "-e CLAUDE_ORCA_VOLUME_DIRS=/home/agent/.cache:/home/agent/.npm:/home/agent/.local/share/opencode:/home/agent/worktrees"
}

@test "a container without the scratch mounts is recreated" {
    mkdir -p "$PROJECT_DIR"
    local primary name image port
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    name="claude-orca-$(basename "$primary")"
    image="$(cat "$CONTAINER_STUB_STATE/image")"
    port="$(cat "$primary/.claude-dev/run/port")"

    # Same folder, same image, same port, same home mount -- only the
    # scratch volumes are missing, which is what a container from before
    # this change looks like. DOCKER_STUB_PRESET_CONTAINER fakes one this
    # folder never created; see tests/launcher-v3.bats.
    rm -f "$CONTAINER_STUB_STATE/preset-applied"
    export DOCKER_STUB_PRESET_CONTAINER="$name:$image:$primary:$port"
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    contains "$output" \
        "container $name predates the scratch volumes (nothing mounted at /home/agent/.cache) -- recreating it"

    # Stopped, removed, and only then a container of this folder's own.
    rm_at="$(grep -n "^rm " "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)"
    run_at="$(grep -n "^run .*--name $name" "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)"
    [ -n "$rm_at" ]
    [ -n "$run_at" ]
    [ "$rm_at" -lt "$run_at" ]
}

@test "a container that has them is kept" {
    mkdir -p "$PROJECT_DIR"
    local primary
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    # No rm, no second run: the scratch mounts are part of what makes the
    # container this folder's.
    log_lacks "^rm "
    [ "$(grep -c '^run ' "$CONTAINER_STUB_LOG" || true)" -eq 0 ]
}

@test "teardown removes every scratch volume and the old Orca state volume an older folder may still have" {
    mkdir -p "$PROJECT_DIR"
    local primary name
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    name="claude-orca-$(basename "$primary")"

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --teardown"
    [ "$status" -eq 0 ]

    # Five volumes, one rm each: the four scratch ones plus the legacy
    # <ctr>-orca-state a pre-ssh folder may still carry (rm of a volume that
    # was never made is harmless), so nothing outlives the folder.
    [ "$(grep -c '^volume rm ' "$CONTAINER_STUB_LOG" || true)" -eq 5 ]
    log_contains "^volume rm $name-orca-state\$"
    log_contains "^volume rm $name-cache\$"
    log_contains "^volume rm $name-npm\$"
    log_contains "^volume rm $name-opencode\$"
    log_contains "^volume rm $name-worktrees\$"
}
