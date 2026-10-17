#!/usr/bin/env bats
#
# startup-menu -- the first-pane menu for a brand-new folder (claude-orca-bg9).
#
# bd, gh and claude are stubs that record their argv into $CALLS; git is real,
# on a throwaway repo with one commit. Every ambient PROJECT_DIR/BEADS_DIR/
# CLAUDE_ORCA_* is set or unset in setup() so this box cannot leak in.
#
# Assertions are `[ ]` and functions, never a bare `[[ ]]` (run-tests.sh).

load helpers/setup

MENU="${BATS_TEST_DIRNAME}/../scripts/startup-menu.sh"

setup() {
    P="$BATS_TEST_TMPDIR/demo"
    CALLS="$BATS_TEST_TMPDIR/calls"
    STUBS="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$P" "$STUBS"
    : >"$CALLS"
    git -C "$P" init --quiet -b main
    git -C "$P" -c user.name=t -c user.email=t@t commit --quiet --allow-empty -m first
    stub bd 0
    stub gh 0
    stub claude 0
    export PROJECT_DIR="$P"
    unset BEADS_DIR CLAUDE_ORCA_HOST_PROJECT_DIR
    export CLAUDE_ORCA_PROJECT_NAME=demo
    export PATH="$STUBS:$PATH"
}

# stub <name> <exit>: records "<name> <argv>" to $CALLS and exits <exit>.
stub() {
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit %s\n' "$1" "$CALLS" "$2" >"$STUBS/$1"
    chmod +x "$STUBS/$1"
}

menu() { bash "$MENU" "$@"; }
calls_of() { grep -c "^$1 " "$CALLS" || true; }

@test "a new folder: y, n, 2 inits beads once, never creates a repo or starts claude, writes the marker" {
    # Guards:   the happy first-run path: beads yes, GitHub no, stay in the shell
    # Fails if: bd init is skipped or run twice, the GitHub default flips to yes, or the marker is not written
    # Run:      bats -f 'a new folder: y, n, 2' tests/startup-menu.bats
    run bash -c "printf 'y\nn\n2\n' | bash '$MENU'"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^bd init --prefix demo$' "$CALLS")" -eq 1 ]
    [ "$(calls_of bd)" -eq 1 ]
    ! grep -q 'repo create' "$CALLS"
    [ "$(calls_of claude)" -eq 0 ]
    [ -f "$P/.claude-dev/run/startup-menu.done" ]
    run menu --due
    [ "$status" -eq 1 ]
}

@test "bd init never reads the menu's input, so the answers after it still reach their questions" {
    # Guards:   bd init asks "Contributing to someone else's repo?" on a terminal; it must not swallow the user's next answer
    # Fails if: bd init runs with the menu's stdin -- this stub then eats the GitHub "y" and no repo create is seen
    # Run:      bats -f 'bd init never reads' tests/startup-menu.bats
    printf '#!/bin/sh\necho "bd $*" >> "%s"\nif IFS= read -r l; then echo "bd-read $l" >> "%s"; fi\nexit 0\n' "$CALLS" "$CALLS" >"$STUBS/bd"
    chmod +x "$STUBS/bd"
    run bash -c "printf 'y\ny\n2\n' | bash '$MENU'"
    [ "$status" -eq 0 ]
    ! grep -q '^bd-read' "$CALLS"
    grep -q 'repo create demo --private' "$CALLS"
}

@test "EOF on the first prompt calls nothing and still writes the marker" {
    # Guards:   a pane with no reader never blocks and never counts as a yes
    # Fails if: EOF is treated as the default answer, or the marker is not written
    # Run:      bats -f 'EOF on the first prompt' tests/startup-menu.bats
    run bash -c "bash '$MENU' </dev/null"
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
    [ -f "$P/.claude-dev/run/startup-menu.done" ]
}

@test "--pane on a folder that is not new prints exactly the identity line and calls nothing" {
    # Guards:   later panes only say where they are
    # Fails if: --pane runs the menu for a folder that already has .beads, or prints more than one line
    # Run:      bats -f 'not new prints exactly' tests/startup-menu.bats
    mkdir "$P/.beads"
    run bash -c "bash '$MENU' --pane </dev/null"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "$output" = "● demo · claude-dev sandbox (Linux container, $P) · cs starts Claude Code · startup-menu sets up beads/GitHub" ]
    [ ! -s "$CALLS" ]
}

@test "an origin already set means no GitHub question and no repo create" {
    # Guards:   a folder that already has a remote is never offered a second repo
    # Fails if: the origin check is dropped, or the output stops naming the origin URL
    # Run:      bats -f 'origin already set' tests/startup-menu.bats
    git -C "$P" remote add origin https://example.test/me/demo.git
    run bash -c "printf 'n\n2\n' | bash '$MENU'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"origin is https://example.test/me/demo.git"* ]]
    [[ "$output" != *"Create a private GitHub repo"* ]]
    ! grep -q 'repo create' "$CALLS"
}

@test "GitHub yes runs gh with exactly the documented arguments" {
    # Guards:   the one outward-facing action is exactly a private repo from this folder
    # Fails if: --private, --source, --remote or the upload flag changes or goes missing
    # Run:      bats -f 'GitHub yes runs gh' tests/startup-menu.bats
    run bash -c "printf 'n\ny\n2\n' | bash '$MENU'"
    [ "$status" -eq 0 ]
    grep -qxF "gh repo create demo --private --source $P --remote origin --push" "$CALLS"
}

@test "What next: 1 and an empty line both start claude with --dangerously-skip-permissions" {
    # Guards:   Claude Code is the default way out of the menu
    # Fails if: the default stops launching claude, or drops the flag
    # Run:      bats -f 'What next: 1' tests/startup-menu.bats
    run bash -c "printf 'n\nn\n1\n' | bash '$MENU'"
    [ "$status" -eq 0 ]
    grep -qxF "claude --dangerously-skip-permissions" "$CALLS"
    : >"$CALLS"
    rm -f "$P/.claude-dev/run/startup-menu.done"
    run bash -c "printf 'n\nn\n\n' | bash '$MENU'"
    grep -qxF "claude --dangerously-skip-permissions" "$CALLS"
}

@test "gh not signed in and an n answer: no login, no repo create" {
    # Guards:   declining sign-in really declines
    # Fails if: gh auth login runs anyway, or the step carries on to create a repo
    # Run:      bats -f 'gh not signed in' tests/startup-menu.bats
    stub gh 1
    run bash -c "printf 'n\nn\n2\n' | bash '$MENU'"
    [ "$status" -eq 0 ]
    ! grep -q 'auth login' "$CALLS"
    ! grep -q 'repo create' "$CALLS"
}

@test "a live lock keeps a second --pane quiet; a dead-pid lock is taken over" {
    # Guards:   two panes opened at once do not both interrogate the user
    # Fails if: a live lock is ignored, or a stale lock blocks the menu forever
    # Run:      bats -f 'a live lock' tests/startup-menu.bats
    local lock="$P/.claude-dev/run/startup-menu.lock"
    mkdir -p "$lock"
    sleep 30 &
    local live=$!
    echo "$live" >"$lock/pid"
    run bash -c "printf 'y\ny\ny\n' | bash '$MENU' --pane"
    kill "$live" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ ! -s "$CALLS" ]
    echo 999999 >"$lock/pid"
    run bash -c "printf 'n\nn\n2\n' | bash '$MENU' --pane"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Initialize beads"* ]]
    [ ! -e "$lock" ]
}
