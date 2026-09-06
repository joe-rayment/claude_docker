#!/usr/bin/env bats
#
# Acceptance contract for claude-orca-2qo -- FROZEN from RED-AT onward.
#
# The install has to be "run one command, start working": the bootstrap
# one-liner ends in `claude-dev register`, and register must finish the
# job rather than stopping to ask. Four things that means, one case each:
# no prompt (one pointer line instead), beads initialised for the folder,
# a failed AVAILABILITY probe warns instead of refusing (a failed
# CONFINEMENT probe still refuses -- that guarantee is untouched), and
# Orca opens by itself when it can.
#
# Nothing here needs a Mac: the self-test runs through the fake-outcomes
# file every other suite uses, orca-launch is stubbed at the path the
# folder's own launcher resolves, and `uname` is stubbed on PATH for the
# Darwin branch.

load helpers/setup

OPTIONAL_EXTRAS="Optional extras: claude-dev setup (OpenRouter key for cheap workers, gh sign-in inside the sandbox, Orca worktree setting)"

# Polls up to ~10s for $1 to exist.
wait_for_file() {
    local target="$1" i=0
    while [ "$i" -lt 100 ]; do
        [ -e "$target" ] && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

# Replaces the folder's orca-launch with one that records its argv at $2
# instead of exec'ing sandbox-exec on a GUI app.
stub_orca_launch() {
    local project="$1" marker="$2" stub
    stub="$project/.claude-dev/bin/orca-launch"
    rm -f "$stub"
    cat > "$stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$marker"
STUB
    chmod +x "$stub"
}

# A PATH dir whose \`uname -s\` says Darwin and which defers everything
# else to the real one (tests/wrapper-writes.bats uses the same shape).
darwin_bin() {
    local d="$BATS_TEST_TMPDIR/darwin-bin"
    mkdir -p "$d"
    cat > "$d/uname" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "-s" ] && { echo Darwin; exit 0; }
PATH="${ORIGINAL_PATH:-/usr/bin:/bin}" exec uname "$@"
STUB
    chmod +x "$d/uname"
    printf '%s\n' "$d"
}

@test "register never prompts: no walk-through question, one optional-extras pointer" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"

    run bash -c "cd '$primary' && '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]

    # The pointer, exactly once, naming what the walk-through is FOR --
    # so a reader can tell whether they need it without running it.
    [[ "$output" == *"$OPTIONAL_EXTRAS"* ]]
    [ "$(printf '%s\n' "$output" | grep -cF 'Optional extras: claude-dev setup')" -eq 1 ]

    # And no question of any kind, nor the old pointer that implied the
    # walk-through was the path rather than an extra.
    [[ "$output" != *"Walk through setup now?"* ]]
    [[ "$output" != *"[Y/n]"* ]]
    [[ "$output" != *"Run 'claude-dev setup' for a guided walk-through"* ]]
    [[ "$output" != *"Step 1/"* ]]

    # Belt and braces: the offer is gone from the source, not merely
    # skipped, and register has no way left to read a terminal.
    ! grep -q 'register_setup_offer' "$REPO_ROOT/scripts/launcher.sh"
    ! grep -q '/dev/tty' "$REPO_ROOT/scripts/launcher.sh"
}

@test "register initializes beads with the derived prefix when bd is present and .beads is absent" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    [ ! -e "$primary/.beads" ]

    # The suite disables this globally (the container has a REAL bd on
    # PATH and hundreds of make_project calls must not touch it); this
    # case is the one that turns it back on, against a stub.
    bdbin="$BATS_TEST_TMPDIR/bd-bin"
    mkdir -p "$bdbin"
    write_stub_bd "$bdbin/bd"
    export PATH="$bdbin:$PATH"
    export BD_STUB_LOG="$BATS_TEST_TMPDIR/bd-stub.log"
    : > "$BD_STUB_LOG"
    unset CLAUDE_ORCA_SKIP_BEADS

    run bash -c "cd '$primary' && '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Beads: initialized (prefix: project)"* ]]
    [ -d "$primary/.beads" ]
    grep -qE '^init .*--prefix project' "$BD_STUB_LOG"

    # Second register: .beads now exists, so it is left alone -- no
    # second init, and no noise about one.
    : > "$BD_STUB_LOG"
    run bash -c "cd '$primary' && '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Beads: initialized"* ]]
    ! grep -qE '^init ' "$BD_STUB_LOG"

    # And with the skip set (how every other suite runs), bd is never
    # called at all even though .beads is missing.
    rm -rf "$primary/.beads"
    : > "$BD_STUB_LOG"
    export CLAUDE_ORCA_SKIP_BEADS=1
    run bash -c "cd '$primary' && '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]
    [ ! -e "$primary/.beads" ]
    ! grep -qE '^init ' "$BD_STUB_LOG"
}

@test "a failed non-confinement probe warns and still hands off; a failed confinement probe still refuses" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"

    # An availability probe: reaching an allowed domain says nothing
    # about whether the sandbox holds, so it must not block the hand-off.
    avail="$BATS_TEST_TMPDIR/fake-avail-fail.txt"
    sed 's/^network-allowed-domain=0$/network-allowed-domain=1/' \
        "$CLAUDE_ORCA_SELFTEST_FAKE" > "$avail"
    grep -qx 'network-allowed-domain=1' "$avail"

    run bash -c "cd '$primary' && CLAUDE_ORCA_SELFTEST_FAKE='$avail' '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning: self-test probe network-allowed-domain failed (faked: FAIL) -- not a confinement failure; see claude-dev --doctor"* ]]
    [[ "$output" == *"How to run it"* ]]
    [[ "$output" == *"$OPTIONAL_EXTRAS"* ]]
    [[ "$output" != *"Refusing to hand off to Orca"* ]]

    # A confinement probe: unchanged: refuse, exit 2, and say nothing
    # about how to open a folder we just refused to hand over.
    conf="$BATS_TEST_TMPDIR/fake-conf-fail.txt"
    sed 's/^write-outside-denied=0$/write-outside-denied=1/' \
        "$CLAUDE_ORCA_SELFTEST_FAKE" > "$conf"
    grep -qx 'write-outside-denied=1' "$conf"

    run bash -c "cd '$primary' && CLAUDE_ORCA_SELFTEST_FAKE='$conf' '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Refusing to hand off to Orca"* ]]
    [[ "$output" != *"How to run it"* ]]
    [[ "$output" != *"not a confinement failure"* ]]

    # Both at once is still a refusal -- one confinement failure decides
    # it, and no warning line invites the user past it.
    both="$BATS_TEST_TMPDIR/fake-both-fail.txt"
    sed 's/^write-outside-denied=0$/write-outside-denied=1/' "$avail" > "$both"
    run bash -c "cd '$primary' && CLAUDE_ORCA_SELFTEST_FAKE='$both' '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Refusing to hand off to Orca"* ]]
    [[ "$output" != *"not a confinement failure"* ]]
}

@test "register opens Orca in the background only when CLAUDE_ORCA_OPEN=1 or Darwin with a terminal" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    marker="$BATS_TEST_TMPDIR/orca-launch-ran.txt"
    stub_orca_launch "$primary" "$marker"
    dbin="$(darwin_bin)"

    # Asked for explicitly: opens, in the background, with this folder.
    rm -f "$marker"
    run bash -c "cd '$primary' && CLAUDE_ORCA_OPEN=1 '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Opening Orca now (first launch: macOS may ask you to confirm)."* ]]
    wait_for_file "$marker"
    grep -qF -- "--project $primary" "$marker"

    # Declined explicitly: never, not even on a Mac.
    rm -f "$marker"
    run bash -c "cd '$primary' && PATH=\"$dbin:\$PATH\" CLAUDE_ORCA_OPEN=0 CLAUDE_ORCA_SKIP_SELFTEST=1 '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Opening Orca now"* ]]
    sleep 2
    [ ! -e "$marker" ]

    # Unset, and not a Mac (this container): nothing to open, so nothing
    # is opened -- and stdout here is a bats pipe, never a terminal.
    rm -f "$marker"
    run bash -c "cd '$primary' && '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Opening Orca now"* ]]
    sleep 2
    [ ! -e "$marker" ]
}
