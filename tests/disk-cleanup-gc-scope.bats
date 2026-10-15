#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# claude-orca-mbb -- the scope contract for disk-cleanup's worktree-gc call.
#
# The sweep's project is $WORKSPACE -- the one project root disk-cleanup
# uses for everything else -- never the ambient $PROJECT_DIR: every shell
# in this container has PROJECT_DIR pointed at the user's live folder, so
# picking it up would sweep that folder from inside any test or hook run.
#
# Modes (claude-orca-mbb DECISION): a plain run sweeps for real
# (worktree-gc --quiet, log block says mode=quiet); --report and --dry-run
# only report (worktree-gc --report, would-lines noted, nothing deleted,
# log block says mode=report). The FROZEN suites tests/disk-cleanup.bats,
# tests/disk-cleanup-ondemand.bats and tests/worktree-gc-wiring.bats are
# untouched by this contract.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CLEANUP="$REPO_ROOT/scripts/disk-cleanup.sh"

short_tmpdir() {
    mktemp -d /tmp/dcgcs-XXXXXX
}

# A git repo with one commit on main and .claude-dev/run/ in place --
# the shape of any folder worktree-gc would log about.
make_repo() {
    mkdir -p "$1/.claude-dev/run"
    git init --quiet -b main "$1" >/dev/null 2>&1
    git -C "$1" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m init >/dev/null 2>&1
}

# A worktree of $1, at $2, on branch $3: clean, merged, nothing to keep.
add_worktree() {
    git -C "$1" worktree add --quiet -b "$3" "$2" HEAD >/dev/null 2>&1
}

# A stub orca-ide: worktree-gc no longer consults Orca at all (claude-orca-9bh.4),
# so this only proves a stray ORCA_CLI changes nothing about the sweep.
write_orca_stub() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    status) printf '{"ok":true,"result":{"runtime":{"reachable":false}}}\n' ;;
esac
exit 0
STUB
    chmod +x "$1"
}

# The full-line shape of a run-log block header (claude-orca-jqh).
HEADER_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z mode=[a-z-]+ exit=[0-9]+$'

setup() {
    TMP="$(short_tmpdir)"
    export TMP
    # Fully sandboxed: a temp HOME, scan dir and TMPDIR so nothing here
    # reaches the real config dir, the real /tmp or the user's folder.
    export HOME="$TMP/home"
    export TMPDIR="$TMP/t"
    export TMP_SCAN_DIR="$TMP/scan"
    mkdir -p "$HOME" "$TMPDIR" "$TMP_SCAN_DIR"
    # WS: the workspace disk-cleanup is pointed at (a git repo).
    WS="$TMP/workspace"
    make_repo "$WS"
    # OTHER: stands in for the user's folder, whose ambient PROJECT_DIR
    # every shell in this container carries -- the sweep must never land here.
    OTHER="$TMP/users-folder"
    make_repo "$OTHER"
    write_orca_stub "$TMP/bin/orca-ide"
}

teardown() {
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    return 0
}

# Run disk-cleanup the way any shell in this container runs it: with the
# ambient PROJECT_DIR present, pointing at the stand-in user folder.
run_cleanup() {  # run_cleanup <mode args...>
    run env WORKSPACE="$WS" PROJECT_DIR="$OTHER" ORCA_CLI="$TMP/bin/orca-ide" \
        bash "$CLEANUP" "$@"
}

# --- the contract ----------------------------------------------------------

@test "a plain disk-cleanup run sweeps WORKSPACE, not the ambient PROJECT_DIR" {
    [ -x "$CLEANUP" ]
    run_cleanup
    [ "$status" -eq 0 ]

    # the sweep ran against WORKSPACE: one block, mode=quiet
    local log="$WS/.claude-dev/run/worktree-gc.log"
    [ -f "$log" ]
    [ "$(grep -cE "$HEADER_RE" "$log")" -eq 1 ]
    grep -qE " mode=quiet exit=0$" "$log"

    # the ambient PROJECT_DIR repo was never touched
    [ ! -e "$OTHER/.claude-dev/run/worktree-gc.log" ]
}

@test "disk-cleanup --report runs worktree-gc in report mode and deletes nothing" {
    [ -x "$CLEANUP" ]
    local wt="$TMP/wt-merged"
    add_worktree "$WS" "$wt" wt-merged

    run_cleanup --report
    [ "$status" -eq 0 ]

    # report mode: the merged worktree would go, but is still there
    [[ "$output" == *"would removed $wt"* ]]
    [ -d "$wt" ]

    # the run was logged as a report against WORKSPACE
    local log="$WS/.claude-dev/run/worktree-gc.log"
    [ -f "$log" ]
    [ "$(grep -cE "$HEADER_RE" "$log")" -eq 1 ]
    grep -qE " mode=report exit=0$" "$log"

    # the ambient PROJECT_DIR repo was never touched
    [ ! -e "$OTHER/.claude-dev/run/worktree-gc.log" ]
}

@test "disk-cleanup --dry-run also only reports" {
    [ -x "$CLEANUP" ]
    local wt="$TMP/wt-merged"
    add_worktree "$WS" "$wt" wt-merged

    run_cleanup --dry-run
    [ "$status" -eq 0 ]

    # dry-run: the merged worktree would go, but is still there
    [[ "$output" == *"would removed $wt"* ]]
    [ -d "$wt" ]

    # the run was logged as a report against WORKSPACE
    local log="$WS/.claude-dev/run/worktree-gc.log"
    [ -f "$log" ]
    [ "$(grep -cE "$HEADER_RE" "$log")" -eq 1 ]
    grep -qE " mode=report exit=0$" "$log"

    # the ambient PROJECT_DIR repo was never touched
    [ ! -e "$OTHER/.claude-dev/run/worktree-gc.log" ]
}
