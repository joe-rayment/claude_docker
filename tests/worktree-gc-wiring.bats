#!/usr/bin/env bats
#
# claude-orca-rdk -- the wiring contract: worktree-gc and branch-guard are
# reachable from the hooks and scripts that are supposed to run them.
#
#   1. config/claude-settings.json wires branch-guard into the PreToolUse
#      Bash matcher (right after bd-guard), runs worktree-gc --after-merge
#      under a new PostToolUse Bash matcher, and runs worktree-gc --quiet
#      at SessionStart right after the provision status entry.
#   2. worktree-gc --after-merge reads the PostToolUse hook JSON from
#      stdin and exits 0 silently unless the command was a git merge or a
#      `git branch -d/-D`.
#   3. after a `git merge` command it sweeps: a merged worktree goes, its
#      branch is deleted.
#   4. session-end-audit runs worktree-gc --quiet and dev-logs every
#      STRANDED line -- on a clean tree too, not only after the dirty-tree
#      note.
#   5. disk-cleanup --report names the delegate job dirs worktree-gc
#      sweeps.
#   6. an unmerged branch behind a kept dirty worktree is reported
#      STRANDED with the reason the worktree was kept (addendum B2) --
#      unmerged work in a live or dirty worktree can no longer hide.
#   7. an occupant that is only Orca's idle worktree terminal -- a shell
#      whose parent's cmdline contains orca-ide and which has no children
#      -- does not make a worktree busy when Orca is reachable, and still
#      does when it is not (addendum G).
#
# Real `git init -b main`, real `git worktree add`, a stub orca-ide via
# $ORCA_CLI and a stub dev-log on PATH -- the same pattern the frozen
# suites (tests/worktree-gc.bats, tests/container-provision-worktree-sweep.bats)
# use.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GC="$REPO_ROOT/scripts/worktree-gc.sh"
SETTINGS_JSON="$REPO_ROOT/config/claude-settings.json"
AUDIT="$REPO_ROOT/scripts/session-end-audit.sh"
DISK_CLEANUP="$REPO_ROOT/scripts/disk-cleanup.sh"

short_tmpdir() {
    mktemp -d /tmp/wtgcw-XXXXXX
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

# A stub orca-ide: `status --json` answers reachable per $ORCA_STUB_REACHABLE
# (default false); `worktree rm --worktree path:<p> --json` records its argv
# to $ORCA_STUB_LOG and, like the real thing, actually removes the path.
write_orca_stub() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ORCA_STUB_LOG"
case "${1:-}" in
    status)
        if [ "${ORCA_STUB_REACHABLE:-false}" = "true" ]; then
            printf '{"ok":true,"result":{"runtime":{"reachable":true}}}\n'
        else
            printf '{"ok":true,"result":{"runtime":{"reachable":false}}}\n'
        fi
        ;;
    worktree)
        if [ "${2:-}" = "rm" ]; then
            for a in "$@"; do
                case "$a" in
                    path:*) rm -rf "${a#path:}" ;;
                esac
            done
            printf '{"ok":true,"result":{}}\n'
        fi
        ;;
esac
exit 0
STUB
    chmod +x "$path"
}

# A dev-log stub: records every argv line to $DEVLOG_STUB_LOG.
write_devlog_stub() {
    local path="$1"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DEVLOG_STUB_LOG"
exit 0
STUB
    chmod +x "$path"
}

run_gc() {  # run_gc <project> [extra args...]
    local proj="$1"; shift
    run bash "$GC" --project "$proj" "$@"
}

# An Orca idle-terminal stand-in behind $1: a shell whose own argv0 names
# orca-ide (so the child's /proc/<ppid>/cmdline contains it) waiting on
# one childless child -- the sleep -- whose cwd is the worktree. Records
# the shell pid on $IDLE_PIDS for teardown.
start_idle_terminal() {  # start_idle_terminal <worktree>
    ( cd "$1" && exec -a orca-ide-parent bash -c 'sleep 300 & wait' ) \
        </dev/null >/dev/null 2>&1 &
    local pid=$!
    IDLE_PIDS="$IDLE_PIDS $pid"
    local i=0 want
    want="$(cd "$1" && pwd -P)"
    while [ "$i" -lt 40 ]; do
        [ "$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" = "$want" ] && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

kill_idle_terminals() {
    local p c pid
    for p in ${IDLE_PIDS:-}; do
        for c in /proc/[0-9]*/status; do
            [ -r "$c" ] || continue
            if [ "$(awk '/^PPid:/{print $2}' "$c" 2>/dev/null)" = "$p" ]; then
                pid="${c#/proc/}"
                kill "${pid%/status}" 2>/dev/null || true
            fi
        done
        kill "$p" 2>/dev/null || true
    done
    IDLE_PIDS=""
}

setup() {
    TMP="$(short_tmpdir)"
    export TMP
    export ORCA_STUB_LOG="$TMP/orca-calls.log"
    : > "$ORCA_STUB_LOG"
    IDLE_PIDS=""
}

teardown() {
    kill_idle_terminals
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    return 0
}

# --- the contract ----------------------------------------------------------

@test "claude-settings.json wires branch-guard under PreToolUse Bash, worktree-gc --after-merge under PostToolUse Bash and worktree-gc --quiet under SessionStart" {
    [ -f "$SETTINGS_JSON" ]
    run jq -e . "$SETTINGS_JSON"
    [ "$status" -eq 0 ]

    # PostToolUse is wired at all
    run jq -e '.hooks.PostToolUse | length > 0' "$SETTINGS_JSON"
    [ "$status" -eq 0 ]

    # branch-guard sits in the PreToolUse Bash matcher, right after bd-guard
    run jq -e '
        [.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command] as $c
        | ([($c | to_entries[] | select(.value | contains("bin/bd-guard"))).key] | .[0]) as $bd
        | ([($c | to_entries[] | select(.value | contains("bin/branch-guard"))).key] | .[0]) as $bg
        | ($bd != null and $bg != null and $bg == ($bd + 1))' "$SETTINGS_JSON"
    [ "$status" -eq 0 ]

    # PostToolUse Bash: the --after-merge entry, in the house hook shape
    run jq -e --arg want '[ -x "__HOST__/template/bin/worktree-gc" ] && exec "__HOST__/template/bin/worktree-gc" --after-merge; exit 0' \
        '[.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[].command] | index($want) != null' \
        "$SETTINGS_JSON"
    [ "$status" -eq 0 ]

    # SessionStart: worktree-gc --quiet right after the provision status entry
    run jq -e '
        [.hooks.SessionStart[0].hooks[].command] as $c
        | ([($c | to_entries[] | select(.value | contains("bin/provision") and contains("status --failed"))).key] | .[0]) as $pv
        | ([($c | to_entries[] | select(.value | contains("bin/worktree-gc") and contains("--quiet"))).key] | .[0]) as $gv
        | ($pv != null and $gv != null and $gv == ($pv + 1))' "$SETTINGS_JSON"
    [ "$status" -eq 0 ]
}

@test "worktree-gc --after-merge ignores a command that is not a merge or branch delete" {
    [ -x "$GC" ]
    local proj="$TMP/project" wt="$TMP/wt-x"
    make_project "$proj"
    add_worktree "$proj" "$wt" wt-x

    local payload
    payload="$(printf '{"tool_input":{"command":"git status"},"cwd":"%s"}' "$proj")"
    run bash "$GC" --after-merge --project "$proj" <<< "$payload"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # nothing was swept: the merged worktree and its branch still stand
    [ -d "$wt" ]
    [ -n "$(git -C "$proj" branch --list wt-x)" ]
}

@test "worktree-gc --after-merge sweeps a merged worktree after a git merge command" {
    [ -x "$GC" ]
    local proj="$TMP/project" wt="$TMP/wt-x" out rc
    make_project "$proj"
    add_worktree "$proj" "$wt" wt-x
    write_orca_stub "$TMP/bin/orca-ide"

    out="$(cd "$proj" && printf '{"tool_input":{"command":"git merge wt-x"},"cwd":"%s"}' "$proj" \
        | ORCA_CLI="$TMP/bin/orca-ide" bash "$GC" --after-merge 2>&1)"
    rc=$?
    [ "$rc" -eq 0 ]

    [[ "$out" == *"removed $wt"* ]]
    [ ! -d "$wt" ]
    [ -z "$(git -C "$proj" branch --list wt-x)" ]
}

@test "session-end-audit calls worktree-gc and dev-logs a STRANDED line" {
    [ -x "$AUDIT" ]
    local proj="$TMP/project"
    make_project "$proj"
    make_unmerged_branch "$proj" stray
    mkdir -p "$TMP/bin"
    write_devlog_stub "$TMP/bin/dev-log"

    payload="$(printf '{"cwd":"%s"}' "$proj")"
    DEVLOG_STUB_LOG="$TMP/devlog.log" PATH="$TMP/bin:$PATH" run bash "$AUDIT" <<< "$payload"
    [ "$status" -eq 0 ]

    grep -qF "session ended with stranded work: STRANDED branch stray" "$TMP/devlog.log"
    # the tree was clean: no dirty-tree note, but the sweep still ran
    ! grep -qF "dirty tree" "$TMP/devlog.log"
}

@test "disk-cleanup --report names the delegate job dirs" {
    [ -x "$DISK_CLEANUP" ]
    local proj="$TMP/project"
    make_project "$proj"
    mkdir -p "$proj/.claude-dev/delegate/job-a/home/.npm"
    echo cache > "$proj/.claude-dev/delegate/job-a/home/blob"

    WORKSPACE="$proj" run bash "$DISK_CLEANUP" --report
    [ "$status" -eq 0 ]

    [[ "$output" == *"delegate job dirs (worktree-gc sweeps home/ and config/ of finished jobs)"* ]]
    [[ "$output" == *".claude-dev/delegate"* ]]
}

@test "worktree-gc reports STRANDED for an unmerged branch checked out in a kept dirty worktree" {
    [ -x "$GC" ]
    local proj="$TMP/project" wt="$TMP/wt-stray"
    make_project "$proj"
    add_worktree "$proj" "$wt" wt-stray
    git -C "$wt" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m wip
    echo untracked > "$wt/scratch.txt"
    write_orca_stub "$TMP/bin/orca-ide"

    ORCA_CLI="$TMP/bin/orca-ide" run_gc "$proj"
    [ "$status" -eq 1 ]

    [[ "$output" == *"FAIL: kept $wt (uncommitted or untracked changes)"* ]]
    [[ "$output" == *"STRANDED branch wt-stray: 1 commit(s) not in main (worktree $wt kept: uncommitted changes)"* ]]
}

@test "worktree-gc treats an idle shell whose parent is orca-ide as not busy when Orca is reachable, and as busy when it is not" {
    [ -x "$GC" ]
    local proj="$TMP/project" wt="$TMP/wt-idle"
    make_project "$proj"
    add_worktree "$proj" "$wt" wt-idle
    write_orca_stub "$TMP/bin/orca-ide"

    start_idle_terminal "$wt" || skip "could not seat the idle-terminal occupant in $wt"

    # Orca reachable: the occupant is Orca's own idle terminal, the rm
    # closes it, and the merged worktree goes.
    ORCA_CLI="$TMP/bin/orca-ide" ORCA_STUB_REACHABLE=true run_gc "$proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"removed $wt (closed Orca's idle terminal)"* ]]
    [ ! -d "$wt" ]

    # The same occupant with Orca unreachable: plain git cannot close a
    # terminal, so every process still means busy.
    local wt2="$TMP/wt-idle2"
    add_worktree "$proj" "$wt2" wt-idle2
    start_idle_terminal "$wt2" || skip "could not seat the idle-terminal occupant in $wt2"

    ORCA_CLI="$TMP/bin/orca-ide" run_gc "$proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"busy $wt2"* ]]
    [ -d "$wt2" ]
}