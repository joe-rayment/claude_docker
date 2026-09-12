#!/usr/bin/env bats
#
# The folder's run/ logs have to say WHEN things happened (recovery plan
# step 0.2, .claude/plans/recovery.md).
#
# Why this file exists: on 2026-09-07 a folder took ~18 minutes to come up
# and nothing on disk could say where the time went. `container.log` had no
# timestamps at all and 4,625 of its 4,900 lines were one-per-second
# `docker inspect` state polls; `setup.log` and the entrypoint's own output
# were equally timeless. Reconstructing that first start needed file
# mtimes, which only exist by accident. A log that cannot answer "how long
# did that take" is why four days of fixes could not be measured.
#
# Assertions are `[ ]` and helper FUNCTIONS, never a bare `[[ ]]`: under
# macOS's bash 3.2 a failing `[[ ]]` does not trip errexit and the test
# goes on to pass (run-tests.sh re-execs under bash 4+ for exactly this
# reason, and this file must not depend on that having worked).

load helpers/setup

# Every line of a file matches the extended regex, or the test fails
# naming the first line that does not.
every_line_matches() {
    local file="$1" re="$2" bad
    [ -s "$file" ] || { echo "empty or missing: $file"; return 1; }
    bad="$(grep -nvE "$re" "$file" | head -3)"
    [ -z "$bad" ] || { echo "lines not matching /$re/:"; printf '%s\n' "$bad"; return 1; }
}

no_line_matches() {
    local file="$1" re="$2" bad
    bad="$(grep -nE "$re" "$file" | head -3)"
    [ -z "$bad" ] || { echo "lines matching /$re/ that should not be there:"; printf '%s\n' "$bad"; return 1; }
}

output_matches() {
    printf '%s' "$output" | grep -qE "$1" \
        || { echo "output did not match /$1/:"; printf '%s\n' "$output" | head -20; return 1; }
}

# HH:MM:SS at the start of a mirrored line.
STAMP='^[0-9][0-9]:[0-9][0-9]:[0-9][0-9] '

@test "container.log stamps every command it mirrors with a wall-clock time" {
    mkdir -p "$PROJECT_DIR"
    local primary
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null

    every_line_matches "$primary/.claude-dev/run/container.log" "$STAMP"
}

@test "container.log keeps the runtime and subcommand after the stamp, so the argv is still parseable" {
    mkdir -p "$PROJECT_DIR"
    local primary log
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null
    log="$primary/.claude-dev/run/container.log"

    # docker-cli-contract.bats reads the run argv back out of this file.
    grep -qE "${STAMP}docker run .*--name claude-orca-" "$log"
    grep -qE "${STAMP}docker build " "$log"
}

@test "container.log does not carry the one-per-second container-state polls" {
    mkdir -p "$PROJECT_DIR"
    local primary
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null

    # `inspect -f {{.State.Status}}` is called in a loop while waiting for
    # the container and again on every command; mirroring it buries the
    # handful of lines that say what actually happened.
    no_line_matches "$primary/.claude-dev/run/container.log" 'docker inspect '
}

@test "the launcher says how long Orca took to come up" {
    mkdir -p "$PROJECT_DIR"
    local primary
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]
    output_matches 'Orca is up \([0-9]+s\)'
}

@test "setup.sh stamps its own messages with elapsed seconds" {
    # A phase that needs root, run as a non-root user: need_root dies
    # through say/die before anything is installed, so this is a real run
    # of the real logger on any box, with no side effects.
    need_nonroot "as root the phase would really install, instead of dying in need_root"
    run bash "$REPO_ROOT/scripts/container/setup.sh" --phase base
    [ "$status" -ne 0 ]
    output_matches '^\[setup \+[0-9]+s\]'
}

@test "the entrypoint stamps its own messages with elapsed seconds" {
    # No PROJECT_DIR: the entrypoint dies at its first input check, which
    # is the same logger every later line uses.
    run env -u PROJECT_DIR bash "$REPO_ROOT/scripts/container/entrypoint.sh"
    [ "$status" -ne 0 ]
    output_matches '^\[entrypoint \+[0-9]+s\]'
}
