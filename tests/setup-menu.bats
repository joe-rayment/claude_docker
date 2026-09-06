#!/usr/bin/env bats
#
# V6 acceptance contract (claude-orca-riu.5) -- FROZEN from RED-AT onward.
# `claude-dev setup`: the guided walk-through a first-time user gets instead
# of a wall of text -- six steps (Claude login, git identity, GitHub auth,
# OpenRouter key, beads, Orca settings) and a closing menu, every step
# skippable, 'a' skipping all the rest.
#
# Interactive input comes from /dev/tty in real life. CLAUDE_ORCA_SETUP_INPUT
# replaces that source for tests: set to a readable file, the walk-through
# reads its lines as answers; set but empty (or unreadable), there is no
# input at all -- which is exactly the no-terminal case, deterministic on a
# machine whose test run does have a controlling terminal.

load helpers/setup

# Writes one answer per line and points the walk-through at them.
answers() {
    local file="$BATS_TEST_TMPDIR/answers"
    printf '%s\n' "$@" > "$file"
    export CLAUDE_ORCA_SETUP_INPUT="$file"
}

run_setup() {
    run bash -c "cd '$PROJECT_DIR' && '$ORCA_HOST/bin/claude-dev' setup"
}

# 1-based line number of the first line of $output containing $1 (empty if
# absent) -- the walk-through's step order is an ordering claim, so it is
# checked as one rather than as six independent greps.
line_of() {
    printf '%s\n' "$output" | grep -n -F -- "$1" | head -1 | cut -d: -f1
}

STEP1="Step 1/6: Claude login"
STEP2="Step 2/6: Git identity"
STEP3="Step 3/6: GitHub auth"
STEP4="Step 4/6: OpenRouter key"
STEP5="Step 5/6: Beads"
STEP6="Step 6/6: Orca settings"

@test "setup walks all steps in order and records each choice" {
    make_project "$PROJECT_DIR"

    # One 'n' per step, then 'q' out of the closing menu.
    answers n n n n n n q
    run_setup
    [ "$status" -eq 0 ]

    local l1 l2 l3 l4 l5 l6
    l1="$(line_of "$STEP1")"; l2="$(line_of "$STEP2")"; l3="$(line_of "$STEP3")"
    l4="$(line_of "$STEP4")"; l5="$(line_of "$STEP5")"; l6="$(line_of "$STEP6")"
    [ -n "$l1" ] && [ -n "$l2" ] && [ -n "$l3" ]
    [ -n "$l4" ] && [ -n "$l5" ] && [ -n "$l6" ]
    [ "$l1" -lt "$l2" ]
    [ "$l2" -lt "$l3" ]
    [ "$l3" -lt "$l4" ]
    [ "$l4" -lt "$l5" ]
    [ "$l5" -lt "$l6" ]

    # The closing menu comes after the last step ...
    local lmenu
    lmenu="$(line_of "What next?")"
    [ -n "$lmenu" ]
    [ "$l6" -lt "$lmenu" ]

    # ... and every choice is recorded, one line per step.
    [[ "$output" == *"Setup summary:"* ]]
    [[ "$output" == *"claude-login: skipped"* ]]
    [[ "$output" == *"git-identity: skipped"* ]]
    [[ "$output" == *"github-auth: skipped"* ]]
    [[ "$output" == *"openrouter-key: skipped"* ]]
    [[ "$output" == *"beads: skipped"* ]]
    [[ "$output" == *"orca-settings: skipped"* ]]
}

@test "every setup step is individually skippable" {
    make_project "$PROJECT_DIR"

    local gitconfig="$PROJECT_DIR/.claude-dev/home/.gitconfig"
    printf '[user]\n\tname = Seeded Name\n\temail = seeded@example.com\n' \
        > "$gitconfig"
    local before
    before="$(cat "$gitconfig")"

    answers n n n n n n q
    run_setup
    [ "$status" -eq 0 ]

    # Nothing a skipped step would have done has happened: no key file, no
    # beads database, and the seeded git identity is byte for byte.
    [ ! -e "$PROJECT_DIR/.claude-dev/state/openrouter.key" ]
    [ ! -e "$PROJECT_DIR/.beads" ]
    [ "$(cat "$gitconfig")" = "$before" ]

    # A skipped step still reports what it found, so the run is a record
    # rather than silence.
    [[ "$output" == *"seeded@example.com"* ]]
}

@test "setup writes the openrouter key file with mode 600 from pasted input" {
    make_project "$PROJECT_DIR"

    # Steps 1-3 skipped, step 4 answered with a paste, then 5, 6 and quit.
    answers n n n y "sk-or-test-000" n n q
    run_setup
    [ "$status" -eq 0 ]

    local key="$PROJECT_DIR/.claude-dev/state/openrouter.key"
    [ -f "$key" ]
    [ "$(cat "$key")" = "sk-or-test-000" ]
    [ "$(file_mode "$key")" = "600" ]

    # Written from the user's own paste, and never echoed back: the run
    # says where it went and shows a masked tail only.
    [[ "$output" == *"mode 600"* ]]
    [[ "$output" == *"openrouter-key: written"* ]]
    [[ "$output" != *"sk-or-test-000"* ]]
}

@test "setup is a no-op without a tty and register only points at it" {
    make_project "$PROJECT_DIR"

    # No input source at all -- the no-terminal case.
    export CLAUDE_ORCA_SETUP_INPUT=""
    run_setup
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-dev setup"* ]]
    [ ! -e "$PROJECT_DIR/.claude-dev/state/openrouter.key" ]
    [ ! -e "$PROJECT_DIR/.beads" ]
    [[ "$output" != *"Step 1/6"* ]]
    [[ "$output" != *"What next?"* ]]

    # register stays non-interactive: it points at the walk-through and
    # never asks anything itself.
    run bash -c "cd '$PROJECT_DIR' && '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Run 'claude-dev setup' for a guided walk-through"* ]]
    [[ "$output" != *"Step 1/6"* ]]
    [[ "$output" != *"Walk through setup now?"* ]]
}

@test "a=skip-all ends the walk-through immediately" {
    make_project "$PROJECT_DIR"

    answers a
    run_setup
    [ "$status" -eq 0 ]

    [[ "$output" == *"$STEP1"* ]]
    [[ "$output" != *"$STEP2"* ]]
    [[ "$output" != *"$STEP3"* ]]
    [[ "$output" != *"$STEP4"* ]]
    [[ "$output" != *"$STEP5"* ]]
    [[ "$output" != *"$STEP6"* ]]
    [[ "$output" != *"What next?"* ]]

    # Skipping all still records the choice for every step.
    [[ "$output" == *"Setup summary:"* ]]
    [[ "$output" == *"orca-settings: skipped"* ]]
    [ ! -e "$PROJECT_DIR/.claude-dev/state/openrouter.key" ]
}
