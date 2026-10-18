#!/usr/bin/env bats
#
# claude-orca-jqh -- the run-log contract for scripts/worktree-gc.sh.
#
# Every sweep run appends one block to <project>/.claude-dev/run/
# worktree-gc.log so a hook run that left a worktree behind explains
# itself: a header line
#   "<ISO-8601 UTC> mode=<mode> exit=<n>"
# followed by every line the run emitted -- including the ones --quiet
# suppresses on stdout, and for a busy worktree the pid, ppid and cmdline
# of the first process that made it busy. An --after-merge run also logs
# the triggering command text (first 200 chars). The file is capped at
# 200 KB by truncating the oldest half once it grows past that.
#
# This suite only adds the log contract; the three FROZEN suites
# (tests/worktree-gc.bats, tests/container-provision-worktree-sweep.bats,
# tests/worktree-gc-wiring.bats) are untouched.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GC="$REPO_ROOT/scripts/worktree-gc.sh"

short_tmpdir() {
    mktemp -d /tmp/wtgcl-XXXXXX
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

# The full-line shape of a block header: <ISO-8601 UTC> mode=<m> exit=<n>.
HEADER_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z mode=[a-z-]+ exit=[0-9]+$'

setup() {
    TMP="$(short_tmpdir)"
    export TMP
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

@test "every run appends a header line with mode and exit code (and no orca= field) to run/worktree-gc.log" {
    [ -x "$GC" ]
    local proj="$TMP/project" wt="$TMP/wt-merged" log="$TMP/project/.claude-dev/run/worktree-gc.log"
    make_project "$proj"
    add_worktree "$proj" "$wt" wt-merged

    # run 1, plain: removes the merged worktree, exit 0
    run bash "$GC" --project "$proj"
    [ "$status" -eq 0 ]
    [ -f "$log" ]
    grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z mode=cli exit=0$" "$log"
    grep -qF "removed $wt" "$log"

    # run 2, --quiet: nothing left to sweep, still a header line
    run bash "$GC" --project "$proj" --quiet
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # exactly two blocks, cli before quiet, and no orca= field anywhere
    [ "$(grep -cE "$HEADER_RE" "$log")" -eq 2 ]
    ! grep -qF "orca=" "$log"
    [ "$(grep -nE " mode=cli " "$log" | cut -d: -f1)" -lt "$(grep -nE " mode=quiet " "$log" | cut -d: -f1)" ]
}

# bats test_tags=size:medium
@test "a busy worktree's log names the pid and cmdline that kept it" {
    [ -x "$GC" ]
    local proj="$TMP/project" wt="$TMP/wt-busy" log="$TMP/project/.claude-dev/run/worktree-gc.log"
    make_project "$proj"
    add_worktree "$proj" "$wt" wt-busy

    ( cd "$wt" && exec sleep 300 ) &
    BUSY_PID=$!
    local i=0 want
    want="$(cd "$wt" && pwd -P)"
    while [ "$i" -lt 20 ]; do
        [ "$(readlink -f "/proc/$BUSY_PID/cwd" 2>/dev/null)" = "$want" ] && break
        sleep 0.1
        i=$((i + 1))
    done
    [ "$(readlink -f "/proc/$BUSY_PID/cwd" 2>/dev/null)" = "$want" ]

    run bash "$GC" --project "$proj"
    [ "$status" -eq 0 ]

    # the busy keep is explained on stdout and named in the log with pid,
    # ppid and the cmdline of the process that made it busy
    grep -qF "busy $wt (a running process has it as its cwd)" "$log"
    grep -qE "busy pid=$BUSY_PID ppid=[0-9]+ cmdline=.*sleep 300" "$log"

    [ -d "$wt" ]
}

@test "--after-merge logs the triggering command text" {
    [ -x "$GC" ]
    local proj="$TMP/project" wt="$TMP/wt-merged" log="$TMP/project/.claude-dev/run/worktree-gc.log"
    make_project "$proj"
    add_worktree "$proj" "$wt" wt-merged

    local payload
    payload="$(printf '{"tool_input":{"command":"git merge feature-x"},"cwd":"%s"}' "$proj")"
    run bash "$GC" --after-merge --project "$proj" <<< "$payload"
    [ "$status" -eq 0 ]

    # the sweep ran quietly and the log explains it: after-merge mode, the
    # command that triggered it, and the lines --quiet suppressed on stdout
    [ ! -d "$wt" ]
    grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z mode=after-merge exit=0$" "$log"
    grep -qF "command: git merge feature-x" "$log"
    grep -qF "removed $wt" "$log"
}

@test "the log is truncated to its newer half once it exceeds 200 KB" {
    [ -x "$GC" ]
    local proj="$TMP/project" log="$TMP/project/.claude-dev/run/worktree-gc.log"
    make_project "$proj"
    mkdir -p "$proj/.claude-dev/run"
    awk 'BEGIN{for(i=0;i<2560;i++) printf "fill%04d %093d\n", i, i}' > "$log"
    [ "$(wc -c < "$log")" -ge 250000 ]

    run bash "$GC" --project "$proj"
    [ "$status" -eq 0 ]

    local size
    size="$(wc -c < "$log")"
    [ "$size" -lt 204800 ]

    # the newest header survived the truncation; the oldest half did not
    grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z mode=cli exit=0$" "$log"
    ! grep -q '^fill0000 ' "$log"
}