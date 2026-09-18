#!/usr/bin/env bats
#
# claude-orca-jh7 -- tests must never sweep the user's folder.
#
# Measured 2026-09-18: tests/session-end-audit.bats and
# tests/orca-dispatch.bats each appended blocks to the USER'S
# /workspace/claude-orca/.claude-dev/run/worktree-gc.log (every shell in
# this container exports PROJECT_DIR=/workspace/claude-orca and
# scripts default to it). Two contracts close that:
#
#   1. session-end-audit.sh runs the sweep only when the hook payload
#      itself carried a cwd; the $PWD fallback still serves the
#      dirty-tree note but never the sweep.
#   2. Every block in <project>/.claude-dev/run/worktree-gc.log carries,
#      on a caller= line of its own (second line, right after the
#      header), the cmdline of the invoking process and its two
#      ancestors -- so any future leak names who invoked it.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
AUDIT="$REPO_ROOT/scripts/session-end-audit.sh"
GC="$REPO_ROOT/scripts/worktree-gc.sh"

make_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init --quiet -b main >/dev/null 2>&1
    git -C "$dir" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m init >/dev/null 2>&1
}

# A stub orca-ide that answers unreachable, so a sweep run in a fixture
# can never reach the real runtime.
write_orca_stub() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    status) printf '{"ok":true,"result":{"runtime":{"reachable":false}}}\n' ;;
esac
exit 0
STUB
    chmod +x "$path"
}

@test "session-end-audit: a payload lacking cwd runs no sweep" {
    local proj_a="$BATS_TEST_TMPDIR/cwd-repo" proj_b="$BATS_TEST_TMPDIR/ambient-repo"
    make_repo "$proj_a"
    make_repo "$proj_b"
    write_orca_stub "$BATS_TEST_TMPDIR/bin/orca-ide"

    # No payload cwd, run from one fixture repo with the ambient
    # PROJECT_DIR pointed at another: the $PWD fallback may serve the
    # dirty-tree note, but neither fixture may gain a sweep log.
    run env HOME="$BATS_TEST_TMPDIR" \
        PROJECT_DIR="$proj_b" \
        PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
        ORCA_CLI="$BATS_TEST_TMPDIR/bin/orca-ide" \
        bash -c 'cd "$1" && printf "not json" | bash "$2" </dev/null' \
        _ "$proj_a" "$AUDIT"
    [ "$status" -eq 0 ]
    [ ! -f "$proj_a/.claude-dev/run/worktree-gc.log" ]
    [ ! -f "$proj_b/.claude-dev/run/worktree-gc.log" ]
}

@test "worktree-gc: every log block names its caller" {
    local proj="$BATS_TEST_TMPDIR/caller-repo"
    make_repo "$proj"
    write_orca_stub "$BATS_TEST_TMPDIR/bin/orca-ide"

    # Run the sweep from a bash -c wrapper whose argv carries the marker
    # (as $0, so it lands in /proc/<pid>/cmdline); the block must trace
    # the chain back to it.
    run env HOME="$BATS_TEST_TMPDIR" \
        PROJECT_DIR="$proj" \
        PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
        ORCA_CLI="$BATS_TEST_TMPDIR/bin/orca-ide" \
        bash -c 'bash "$1" --quiet --project "$2" </dev/null' \
        WGC_CALLER_MARKER "$GC" "$proj"
    [ "$status" -eq 0 ]

    local log="$proj/.claude-dev/run/worktree-gc.log"
    [ -f "$log" ]
    # header first, caller= second
    sed -n '1p' "$log" | grep -qE \
        '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z mode=quiet orca=unreachable exit=0$'
    sed -n '2p' "$log" | grep -q '^caller='
    sed -n '2p' "$log" | grep -q 'WGC_CALLER_MARKER'
}
