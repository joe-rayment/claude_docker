#!/usr/bin/env bats
#
# claude-orca-6zg -- acceptance contract for scripts/worktree-gc.sh, the
# one sweep for merged worktrees, merged branches, stranded work and
# finished delegate job dirs. scripts/container/provision.d/65-worktree-sweep
# delegates to it (its own FROZEN suite,
# tests/container-provision-worktree-sweep.bats, must stay green).
#
# What the sweep may and may not do:
#   * clean worktree, branch merged into main  -> worktree removed, branch
#     deleted with `git branch -d`.
#   * clean worktree, branch NOT merged        -> worktree removed, branch
#     kept, "STRANDED branch ... N commit(s)" printed, exit 1.
#   * dirty worktree                           -> kept, "FAIL: kept", exit 1.
#   * main worktree HEAD not on main/master    -> "STRANDED HEAD", exit 1,
#     nothing deleted at all.
#   * merged local branches with no worktree   -> deleted.
#   * delegate job dir: dead pid + worktree gone -> home/ and config/
#     swept; receipt, log, branch, env, pid kept. Live pid -> untouched.
#
# Real `git init -b main`, real `git worktree add`. The sweep is plain git:
# a canary orca-ide on $PATH and $ORCA_CLI records any call and the last
# case asserts it was never invoked (claude-orca-9bh.4).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GC="$REPO_ROOT/scripts/worktree-gc.sh"
GC_BIN="$REPO_ROOT/bin/worktree-gc"

short_tmpdir() {
    mktemp -d /tmp/wtgc-XXXXXX
}

make_project() {
    local dir="$1"
    mkdir -p "$dir/.claude-dev/delegate"
    git init --quiet -b main "$dir" >/dev/null 2>&1
    git -C "$dir" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m init >/dev/null 2>&1
}

# A worktree of $1, at $2, on branch $3 (default: leaf of $2).
add_worktree() {
    local proj="$1" wt="$2" branch="${3:-$(basename "$wt")}"
    git -C "$proj" worktree add --quiet -b "$branch" "$wt" HEAD >/dev/null 2>&1
}

# A local branch $2 pointing at a commit main does not contain -- made
# with commit-tree so no second worktree is needed.
make_unmerged_branch() {
    local proj="$1" branch="$2" sha
    sha="$(git -C "$proj" -c user.email=test@example.com -c user.name=test \
        commit-tree 'HEAD^{tree}' -m stray)"
    git -C "$proj" branch "$branch" "$sha"
}

# A canary orca-ide/orca: records its argv to $ORCA_STUB_LOG, answers
# "reachable" to anything, and removes the path it is told to `worktree rm`
# -- so if the sweep still asked Orca for anything, the log would show it.
write_orca_canary() {
    local dir="$1" name
    mkdir -p "$dir"
    for name in orca-ide orca; do
        cat > "$dir/$name" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ORCA_STUB_LOG"
for a in "$@"; do
    case "$a" in
        path:*) rm -rf "${a#path:}" ;;
    esac
done
printf '{"ok":true,"result":{"runtime":{"reachable":true}}}\n'
exit 0
STUB
        chmod +x "$dir/$name"
    done
}

# A pid above pid_max can never name a process -- dead, deterministically.
dead_pid() {
    local max
    max="$(cat /proc/sys/kernel/pid_max 2>/dev/null)" || max=4194304
    printf '%s' $((max + 1))
}

run_gc() {  # run_gc <project> [extra args...]
    local proj="$1"; shift
    run bash "$GC" --project "$proj" "$@"
}

setup() {
    TMP="$(short_tmpdir)"
    export TMP
    export ORCA_STUB_LOG="$TMP/orca-calls.log"
    : > "$ORCA_STUB_LOG"
    LIVE_PID=""
}

teardown() {
    if [ -n "${LIVE_PID:-}" ]; then
        kill "$LIVE_PID" 2>/dev/null || true
        wait "$LIVE_PID" 2>/dev/null || true
    fi
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    return 0
}

# --- the contract ----------------------------------------------------------

@test "gc removes a clean worktree whose branch is merged into main and deletes the branch" {
    [ -x "$GC" ]
    [ -x "$GC_BIN" ]
    local proj="$TMP/project" wt="$TMP/wt-clean"
    make_project "$proj"
    add_worktree "$proj" "$wt" wt-clean

    run_gc "$proj"
    [ "$status" -eq 0 ]

    [[ "$output" == *"removed $wt"* ]]
    [[ "$output" == *"deleted branch wt-clean (merged)"* ]]

    [ ! -d "$wt" ]
    ! git -C "$proj" worktree list --porcelain | grep -qF "worktree $wt"
    [ -z "$(git -C "$proj" branch --list wt-clean)" ]
}

@test "gc keeps a clean worktree whose branch has commits not in main and reports it STRANDED (kept: unmerged)" {
    [ -x "$GC" ]
    local proj="$TMP/project" wt="$TMP/wt-stray"
    make_project "$proj"
    add_worktree "$proj" "$wt" wt-stray
    git -C "$wt" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m wip

    run_gc "$proj"
    [ "$status" -eq 1 ]

    [[ "$output" == *"STRANDED branch wt-stray: 1 commit(s) not in main"* ]]
    [[ "$output" == *"(worktree $wt kept: unmerged)"* ]]

    [ -d "$wt" ]
    [ -n "$(git -C "$proj" branch --list wt-stray)" ]
}

@test "gc keeps a dirty worktree and reports FAIL: kept" {
    [ -x "$GC" ]
    local proj="$TMP/project" wt="$TMP/wt-dirty"
    make_project "$proj"
    add_worktree "$proj" "$wt" wt-dirty
    echo changed > "$wt/dirty.txt"

    run_gc "$proj"
    [ "$status" -eq 1 ]

    [[ "$output" == *"FAIL: kept $wt (uncommitted or untracked changes)"* ]]

    [ -d "$wt" ]
    git -C "$proj" worktree list --porcelain | grep -qF "worktree $wt"
    [ -n "$(git -C "$proj" branch --list wt-dirty)" ]
}

@test "gc deletes merged branches with no worktree -- delegate/x, wt/y, worktree-agent-z and a plain name -- and keeps an unmerged one as STRANDED" {
    [ -x "$GC" ]
    local proj="$TMP/project"
    make_project "$proj"
    git -C "$proj" branch delegate/x HEAD
    git -C "$proj" branch wt/y HEAD
    git -C "$proj" branch worktree-agent-z HEAD
    git -C "$proj" branch old-integration HEAD
    make_unmerged_branch "$proj" stray

    run_gc "$proj"
    [ "$status" -eq 1 ]

    [[ "$output" == *"deleted branch delegate/x (merged)"* ]]
    [[ "$output" == *"deleted branch wt/y (merged)"* ]]
    [[ "$output" == *"deleted branch worktree-agent-z (merged)"* ]]
    [[ "$output" == *"deleted branch old-integration (merged)"* ]]
    [[ "$output" == *"STRANDED branch stray: 1 commit(s) not in main"* ]]

    [ -z "$(git -C "$proj" branch --list delegate/x)" ]
    [ -z "$(git -C "$proj" branch --list wt/y)" ]
    [ -z "$(git -C "$proj" branch --list worktree-agent-z)" ]
    [ -z "$(git -C "$proj" branch --list old-integration)" ]
    [ -n "$(git -C "$proj" branch --list stray)" ]
}

@test "gc reports STRANDED when the main worktree's HEAD is not on main and deletes nothing" {
    [ -x "$GC" ]
    local proj="$TMP/project"
    make_project "$proj"
    git -C "$proj" checkout --quiet -b side
    git -C "$proj" branch merged-earlier HEAD

    run_gc "$proj"
    [ "$status" -eq 1 ]

    [[ "$output" == *"STRANDED HEAD is on side, not main"* ]]
    [[ "$output" == *"merge back or switch"* ]]

    # deletes nothing: the deletable branch survives, HEAD was not moved
    [ -n "$(git -C "$proj" branch --list merged-earlier)" ]
    [ "$(git -C "$proj" symbolic-ref --short HEAD)" = "side" ]
}

@test "gc sweeps home/ and config/ of a finished delegate job but keeps its receipt, log, branch and env; a job with a live pid is untouched" {
    [ -x "$GC" ]
    local proj="$TMP/project" done_job="$TMP/project/.claude-dev/delegate/job-done" \
        live_job="$TMP/project/.claude-dev/delegate/job-live"
    make_project "$proj"
    mkdir -p "$done_job/home/.npm/_cacache" "$done_job/config/opencode/node_modules"
    echo cache > "$done_job/home/.npm/_cacache/blob"
    echo mod > "$done_job/config/opencode/node_modules/m.js"
    printf '%s\n' "$(dead_pid)" > "$done_job/pid"
    echo '{"ok":true}' > "$done_job/receipt.json"
    echo runner > "$done_job/runner.log"
    echo delegate/job-done > "$done_job/branch"
    echo KEY=value > "$done_job/env"
    echo log > "$done_job/worktree-add.log"

    sleep 300 &
    LIVE_PID=$!
    mkdir -p "$live_job/home"
    printf '%s\n' "$LIVE_PID" > "$live_job/pid"

    run_gc "$proj"
    [ "$status" -eq 0 ]

    [[ "$output" == *"swept job job-done (home, config)"* ]]

    [ ! -d "$done_job/home" ]
    [ ! -d "$done_job/config" ]
    [ -f "$done_job/receipt.json" ]
    [ -f "$done_job/runner.log" ]
    [ -f "$done_job/branch" ]
    [ -f "$done_job/env" ]
    [ -f "$done_job/worktree-add.log" ]
    [ -f "$done_job/pid" ]

    [ -d "$live_job/home" ]
    [ -f "$live_job/pid" ]
    kill -0 "$LIVE_PID"
}

@test "gc --report prints would-lines and deletes nothing" {
    [ -x "$GC" ]
    local proj="$TMP/project" wt="$TMP/wt-report" done_job="$TMP/project/.claude-dev/delegate/job-r"
    make_project "$proj"
    add_worktree "$proj" "$wt" wt-report
    git -C "$proj" branch delegate/old HEAD
    mkdir -p "$done_job/home"
    printf '%s\n' "$(dead_pid)" > "$done_job/pid"

    run_gc "$proj" --report
    [ "$status" -eq 0 ]

    [[ "$output" == *"would removed $wt"* ]]
    [[ "$output" == *"would deleted branch wt-report (merged)"* ]]
    [[ "$output" == *"would deleted branch delegate/old (merged)"* ]]
    [[ "$output" == *"would swept job job-r (home, config)"* ]]

    # nothing was deleted
    [ -d "$wt" ]
    [ -n "$(git -C "$proj" branch --list wt-report)" ]
    [ -n "$(git -C "$proj" branch --list delegate/old)" ]
    [ -d "$done_job/home" ]
}

@test "gc --quiet prints nothing on a clean repo and exits 0" {
    [ -x "$GC" ]
    local proj="$TMP/project"
    make_project "$proj"

    run_gc "$proj" --quiet
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "gc removes a clean worktree with plain git and never calls the Orca CLI, even when one answers reachable" {
    [ -x "$GC" ]
    local proj="$TMP/project" wt="$TMP/wt-orca"
    make_project "$proj"
    add_worktree "$proj" "$wt" wt-orca
    write_orca_canary "$TMP/bin"

    PATH="$TMP/bin:$PATH" ORCA_CLI="$TMP/bin/orca-ide" run_gc "$proj"
    [ "$status" -eq 0 ]

    [ ! -s "$ORCA_STUB_LOG" ]
    [[ "$output" == *"removed $wt"* ]]
    [[ "$output" == *"deleted branch wt-orca (merged)"* ]]

    [ ! -d "$wt" ]
    ! git -C "$proj" worktree list --porcelain | grep -qF "worktree $wt"
    [ -z "$(git -C "$proj" branch --list wt-orca)" ]
}

# --- a git-locked worktree: reported with its reason, never unlocked --------
# (claude-orca-9bh.11, C1c) Claude Code locks the worktree of each live
# Agent-tool agent with `git worktree lock --reason "claude agent ... (pid N)"`;
# in-process subagents hold no cwd, so the lock is the only liveness signal.

@test "gc reports a git-locked worktree as 'locked: <reason>', keeps it and its branch, and never unlocks it" {
    # Guards:   a worktree git-locked by a live agent survives the sweep
    #           intact, the lock's reason is shown, and the lock stays on.
    # Fails if: the sweep removes/prunes a locked worktree, drops or rewrites
    #           the reason, or unlocks it (git worktree unlock / remove -f -f).
    # Run:      bats -f 'git-locked worktree' tests/worktree-gc.bats
    [ -x "$GC" ]
    local proj="$TMP/project" wt="$TMP/wt-locked"
    make_project "$proj"
    add_worktree "$proj" "$wt" wt-locked
    git -C "$proj" worktree lock --reason "claude agent agent-x (pid 1)" "$wt"

    run_gc "$proj"
    [ "$status" -eq 0 ]

    [[ "$output" == *"locked: claude agent agent-x (pid 1)"* ]]
    [[ "$output" == *"$wt kept"* ]]
    [[ "$output" != *"removed $wt"* ]]

    [ -d "$wt" ]
    [ -n "$(git -C "$proj" branch --list wt-locked)" ]
    git -C "$proj" worktree list --porcelain | grep -qF "worktree $wt"
    git -C "$proj" worktree list --porcelain | grep -qxF "locked claude agent agent-x (pid 1)"
}

@test "gc keeps a locked worktree whose directory is gone (a lock is not pruned) and reports it locked" {
    # Guards:   a lock outranks every other state: even a vanished directory
    #           is not pruned (and not claimed "pruned") while the lock stands.
    # Fails if: the directory-gone check runs before the lock check and the
    #           sweep prunes a locked entry or prints "pruned" for it.
    # Run:      bats -f 'directory is gone' tests/worktree-gc.bats
    [ -x "$GC" ]
    local proj="$TMP/project" wt="$TMP/wt-gone"
    make_project "$proj"
    add_worktree "$proj" "$wt" wt-gone
    git -C "$proj" worktree lock --reason "claude agent agent-y (pid 2)" "$wt"
    rm -rf "$wt"

    run_gc "$proj"
    [ "$status" -eq 0 ]

    [[ "$output" == *"locked: claude agent agent-y (pid 2)"* ]]
    [[ "$output" != *"pruned"* ]]
    git -C "$proj" worktree list --porcelain | grep -qF "worktree $wt"
    git -C "$proj" worktree list --porcelain | grep -qxF "locked claude agent agent-y (pid 2)"
}

@test "gc with one merged, one unmerged and one locked worktree prints the removal, the STRANDED line and the locked line (exit 1)" {
    # Guards:   the three outcomes side by side: the merged one is removed,
    #           the unmerged one is STRANDED, the locked one is only reported;
    #           the exit code is 1 because of the STRANDED line alone.
    # Fails if: the locked worktree is removed or counted STRANDED by itself,
    #           or the merged/unmerged outcomes change when a lock is present.
    # Run:      bats -f 'one merged, one unmerged and one locked' tests/worktree-gc.bats
    [ -x "$GC" ]
    local proj="$TMP/project"
    local wm="$TMP/wt-merged" wu="$TMP/wt-unmerged" wl="$TMP/wt-locked"
    make_project "$proj"
    add_worktree "$proj" "$wm" wt-merged
    add_worktree "$proj" "$wu" wt-unmerged
    add_worktree "$proj" "$wl" wt-locked
    git -C "$wu" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m wip
    git -C "$proj" worktree lock --reason "claude agent agent-x (pid 1)" "$wl"

    run_gc "$proj"
    [ "$status" -eq 1 ]

    [[ "$output" == *"removed $wm"* ]]
    [[ "$output" == *"STRANDED branch wt-unmerged: 1 commit(s) not in main"* ]]
    [[ "$output" == *"locked: claude agent agent-x (pid 1)"* ]]
    [[ "$output" != *"STRANDED branch wt-locked"* ]]
    [ ! -d "$wm" ]
    [ -d "$wu" ]
    [ -d "$wl" ]
}
