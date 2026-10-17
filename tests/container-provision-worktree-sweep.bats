#!/usr/bin/env bats
#
# claude-orca-grq -- FROZEN from RED-AT onward.
#
# scripts/container/provision.d/65-worktree-sweep removes the noise Orca
# would otherwise show forever: every git worktree this project ever grew
# (dispatch --epic, delegate.sh, by-hand executors) but nothing ever removed.
# For every worktree other than the main one:
#
#   * directory gone           -> `git worktree prune`, logged "pruned".
#   * a process has it as cwd  -> kept, logged "busy" (not a failure).
#   * clean (no uncommitted or untracked changes):
#       - `git worktree remove <p>` -- plain git, Orca is never consulted
#         (claude-orca-9bh.4)
#     then `git worktree prune`, logged "removed".
#   * otherwise (dirty)        -> kept, logged "kept ... uncommitted", and
#     the step exits non-zero so `provision status` surfaces it.
#
# The step is exercised directly (it is a leaf under provision.d, not the
# whole entrypoint), against a real git repo with real `git worktree add`
# and a stub orca-ide that records any call -- the pattern tests/provision.bats and
# tests/container-entrypoint.bats use for the rest of provisioning.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
STEP="$REPO_ROOT/scripts/container/provision.d/65-worktree-sweep"

short_tmpdir() {
    mktemp -d /tmp/co-wts-XXXXXX
}

make_project() {
    local dir="$1"
    mkdir -p "$dir/.claude-dev/run" "$dir/.claude-dev/home"
    git init --quiet -b main "$dir" >/dev/null 2>&1
    git -C "$dir" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m init >/dev/null 2>&1
}

# A worktree of $1, at $2, on a new branch named after the leaf of $2.
add_worktree() {
    local proj="$1" wt="$2" branch
    branch="wt-$(basename "$wt")"
    git -C "$proj" worktree add --quiet -b "$branch" "$wt" HEAD >/dev/null 2>&1
}

# A stub orca-ide that only records its argv to $ORCA_STUB_LOG: since
# claude-orca-9bh.4 the sweep never calls Orca, so the log must stay empty.
write_orca_stub() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ORCA_STUB_LOG"
exit 0
STUB
    chmod +x "$path"
}

# A background process whose CWD is inside $1, for the busy-worktree case.
# `exec` inside the subshell so the sleep itself, not a wrapper around it,
# is the process whose /proc/<pid>/cwd resolves under the worktree.
start_busy_process() {
    ( cd "$1" && exec sleep 300 ) &
    BUSY_PID=$!
    # give it a moment to actually be inside the directory before /proc is read
    local i=0
    while [ "$i" -lt 20 ]; do
        [ "$(readlink -f "/proc/$BUSY_PID/cwd" 2>/dev/null)" = "$(cd "$1" && pwd -P)" ] && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

run_step() {  # run_step <project> [orca-cli-path]
    ORCA_CLI="${2:-}" PROJECT_DIR="$1" RUN_DIR="$1/.claude-dev/run" \
        PROVISION_DIR="$1/.claude-dev/run/provision" \
        run bash "$STEP"
}

setup() {
    TMP="$(short_tmpdir)"
    export TMP
    export ORCA_STUB_LOG="$TMP/orca-calls.log"
    : > "$ORCA_STUB_LOG"
    BUSY_PID=""
}

teardown() {
    if [ -n "${BUSY_PID:-}" ]; then
        kill "$BUSY_PID" 2>/dev/null || true
        wait "$BUSY_PID" 2>/dev/null || true
    fi
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    return 0
}

# --- the contract ----------------------------------------------------------

@test "sweep removes a clean worktree with git worktree remove and never calls Orca" {
    [ -x "$STEP" ]
    local proj="$TMP/project" wt="$TMP/wt-clean" cli="$TMP/bin/orca-ide"
    make_project "$proj"
    add_worktree "$proj" "$wt"
    write_orca_stub "$cli"

    run_step "$proj" "$cli"
    [ "$status" -eq 0 ]

    # the Orca stub was offered and never called
    [ ! -s "$ORCA_STUB_LOG" ]
    [[ "$output" == *"removed $wt"* ]]

    [ ! -d "$wt" ]
    ! git -C "$proj" worktree list --porcelain | grep -qF "worktree $wt"
}

@test "sweep prunes a worktree whose directory is gone" {
    [ -x "$STEP" ]
    local proj="$TMP/project" wt="$TMP/wt-gone"
    make_project "$proj"
    add_worktree "$proj" "$wt"
    rm -rf "$wt"
    git -C "$proj" worktree list --porcelain | grep -qF "worktree $wt"

    run_step "$proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pruned $wt"* ]]
    ! git -C "$proj" worktree list --porcelain | grep -qF "worktree $wt"
}

@test "sweep keeps a worktree with uncommitted changes and reports FAIL naming it" {
    [ -x "$STEP" ]
    local proj="$TMP/project" wt="$TMP/wt-dirty"
    make_project "$proj"
    add_worktree "$proj" "$wt"
    echo changed >> "$wt/README-dirty.txt"

    run_step "$proj"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"$wt"* ]]
    [[ "$output" == *"uncommitted"* ]]

    [ -d "$wt" ]
    git -C "$proj" worktree list --porcelain | grep -qF "worktree $wt"
}

@test "sweep keeps a worktree that a running process has as its cwd" {
    [ -x "$STEP" ]
    local proj="$TMP/project" wt="$TMP/wt-busy"
    make_project "$proj"
    add_worktree "$proj" "$wt"
    start_busy_process "$wt" || skip "could not confirm the busy process' cwd"

    run_step "$proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"busy"* ]]
    [[ "$output" == *"$wt"* ]]

    [ -d "$wt" ]
    git -C "$proj" worktree list --porcelain | grep -qF "worktree $wt"
}

@test "sweep leaves the main worktree alone and reports ok when nothing remains" {
    [ -x "$STEP" ]
    local proj="$TMP/project"
    make_project "$proj"

    run_step "$proj"
    [ "$status" -eq 0 ]

    git -C "$proj" worktree list --porcelain | grep -qF "worktree $(cd "$proj" && pwd -P)"
    [ "$(git -C "$proj" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
}
