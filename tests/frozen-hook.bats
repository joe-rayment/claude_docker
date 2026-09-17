#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# frozen-hook.bats — git pre-commit hook that enforces a bead's FROZEN
# contract for every agent, Claude-side or not: once a RED-AT sha exists on
# the bead, no commit may touch the FROZEN paths. Modelled on
# tests/contract-gate.bats (stub bd first on PATH; fail-open when tooling
# is missing).

LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/lib/frozen-hook.sh"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"

    FIX="$BATS_TEST_TMPDIR/fixture"
    git init -q "$FIX"
    git -C "$FIX" config user.email worker@example.com
    git -C "$FIX" config user.name worker
    mkdir -p "$FIX/tests" "$FIX/scripts"
    echo base > "$FIX/impl.sh"
    echo test > "$FIX/tests/x.bats"
    git -C "$FIX" add -A
    git -C "$FIX" commit -qm "base"

    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    write_bd_stub
    export PATH="$STUB_DIR:/usr/local/bin:/usr/bin:/bin"

    export CLAUDE_ORCA_BEAD="claude-orca-2m5"
    # Default stub answers: the FROZEN line lives in the description, the
    # RED-AT sha in the notes (as `bd update --append-notes` writes it).
    export FAKE_BD_DESC="notes. FROZEN: tests/x.bats from RED-AT on."
    export FAKE_BD_NOTES="RED-AT: $(git -C "$FIX" rev-parse HEAD)"
}

# A fake `bd` that answers `bd show <bead>` with plain text built from
# $FAKE_BD_DESC / $FAKE_BD_NOTES, so the hook's extraction is exercised
# against the shapes `bd show` really prints.
write_bd_stub() {
    cat > "$STUB_DIR/bd" <<'EOF'
#!/bin/sh
if [ "$1" = "show" ]; then
    printf 'title\n\n%s\n\nNOTES\n%s\n' "$FAKE_BD_DESC" "$FAKE_BD_NOTES"
    exit 0
fi
exit 1
EOF
    chmod +x "$STUB_DIR/bd"
}

commit_fixture() {
    git -C "$FIX" add -A
    git -C "$FIX" commit -qm "$1" 2> "$BATS_TEST_TMPDIR/commit.err"
}

@test "hook blocks a commit touching a FROZEN path once RED-AT exists" {
    install_frozen_hook "$FIX" "claude-orca-2m5"
    echo edit > "$FIX/tests/x.bats"
    run commit_fixture "edit frozen test"
    [ "$status" -ne 0 ]
    grep -q "bd supersede" "$BATS_TEST_TMPDIR/commit.err"
    grep -q "tests/x.bats" "$BATS_TEST_TMPDIR/commit.err"
}

@test "hook lets a commit touching only the implementation through" {
    install_frozen_hook "$FIX" "claude-orca-2m5"
    echo impl > "$FIX/impl.sh"
    run commit_fixture "edit impl"
    [ "$status" -eq 0 ]
}

@test "hook is fail-open before any RED-AT exists" {
    FAKE_BD_NOTES="no red note yet"
    install_frozen_hook "$FIX" "claude-orca-2m5"
    echo edit > "$FIX/tests/x.bats"
    run commit_fixture "edit frozen test, no RED yet"
    [ "$status" -eq 0 ]
}

@test "hook is fail-open with no bd on PATH" {
    PATH_SAVE="$PATH"
    export PATH="/usr/bin:/bin"
    install_frozen_hook "$FIX" "claude-orca-2m5"
    echo edit > "$FIX/tests/x.bats"
    run commit_fixture "edit frozen test, no bd"
    [ "$status" -eq 0 ]
    export PATH="$PATH_SAVE"
}

@test "an existing user pre-commit hook is chained, not clobbered" {
    printf '#!/bin/sh\ntouch "%s/user-ran"\n' "$BATS_TEST_TMPDIR" > "$FIX/.git/hooks/pre-commit"
    chmod +x "$FIX/.git/hooks/pre-commit"
    install_frozen_hook "$FIX" "claude-orca-2m5"
    echo impl > "$FIX/impl.sh"
    run commit_fixture "chained"
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/user-ran" ]
}

@test "install_frozen_hook is idempotent: twice leaves one hook and no stray orig" {
    install_frozen_hook "$FIX" "claude-orca-2m5"
    install_frozen_hook "$FIX" "claude-orca-2m5"
    count="$(find "$FIX/.git/hooks" -maxdepth 1 -name 'pre-commit*' | wc -l)"
    [ "$count" -eq 1 ]
    [ -f "$FIX/.git/hooks/pre-commit" ]
    [ "$(cat "$FIX/.git/hooks/claude-orca-bead")" = "claude-orca-2m5" ]
}

@test "orca-dispatch and delegate suites stay green" {
    run bats tests/orca-dispatch-launch.bats tests/delegate.bats
    echo "$output" >&2
    [ "$status" -eq 0 ]
}
