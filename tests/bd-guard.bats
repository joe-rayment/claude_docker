#!/usr/bin/env bats

# bd-guard — PreToolUse(Bash) hook that keeps beads Claude-only.
# Tests run the repo script directly (not the baked /usr/local/bin copy).

# The script under test is overridable so the suite can be pointed at the OLD
# script (e.g. `BD_GUARD_BIN=/tmp/old.sh bats …`) to prove the new adversarial
# tests actually fail against it — i.e. they are not defanged.
GUARD=${BD_GUARD_BIN:-/workspace/scripts/bd-guard.sh}

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    unset BD_GUARD_ALLOW
}

# run_guard <command-string>; sets $status / $output (stderr). The command
# string may contain tabs/leading whitespace — passed verbatim through jq.
run_guard() {
    run bash -c 'jq -n --arg c "$1" "{tool_input:{command:\$c}}" | '"$GUARD"' 2>&1' _ "$1"
}

@test "bd-guard: human assignee on create is hard-blocked" {
    run_guard 'bd create "Fix parser" -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: human assignee via --assignee= and bd assign is blocked" {
    run_guard 'bd update wp9 --assignee=Joe'
    [ "$status" -eq 2 ]
    run_guard 'bd assign wp9 joe'
    [ "$status" -eq 2 ]
}

@test "bd-guard: hard rule ignores BD_GUARD_ALLOW override" {
    export BD_GUARD_ALLOW=1
    run bash -c 'jq -n --arg c "bd create x -a joe" "{tool_input:{command:\$c}}" | BD_GUARD_ALLOW=1 '"$GUARD"' 2>&1'
    [ "$status" -eq 2 ]
}

@test "bd-guard: agent assignees and claim pass" {
    run_guard 'bd create "Fix parser" --assignee claude'
    [ "$status" -eq 0 ]
    run_guard 'bd update wp9 --claim'
    [ "$status" -eq 0 ]
    run_guard 'bd assign wp9 ""'
    [ "$status" -eq 0 ]
}

@test "bd-guard: user-directed close reason is soft-blocked" {
    run_guard 'bd close wp9 --reason "Done except push; Joe should run gh auth login and push the branch"'
    [ "$status" -eq 2 ]
    run_guard 'bd close wp9 --reason "Fixed the parser and verified via take-screenshot term"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: close reason discharging residual work in prose is blocked" {
    run_guard 'bd close vrv --reason "All subtasks done; the sole residual step is git push, auth-blocked, carried outside the tracker"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"follow-up bead"* ]]
    run_guard 'bd close wp9 --reason "Closing per user direction. NOT verified in-container until rebuild"'
    [ "$status" -eq 2 ]
}

@test "bd-guard: close reason naming a follow-up bead passes" {
    run_guard 'bd close vrv --reason "Done; residual step (git push) filed as bead bd-x9 which Claude will run after auth is restored"'
    [ "$status" -eq 0 ]
    run_guard 'bd create "Track the remaining work items in the sprint board UI"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: user-directed bead text is soft-blocked with chat redirect" {
    run_guard 'bd create "Ask the user which DB to use"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"ask it in your reply NOW"* ]]
    run_guard 'bd create "Migrate" -d "waiting for user approval"'
    [ "$status" -eq 2 ]
    run_guard 'bd update wp9 --notes "blocked on Joe deciding the region"'
    [ "$status" -eq 2 ]
}

@test "bd-guard: ordinary feature language about users passes" {
    run_guard 'bd create "Sanitize user input in the login form"'
    [ "$status" -eq 0 ]
    run_guard 'bd create "Allow the user to upload avatars"'
    [ "$status" -eq 0 ]
    run_guard 'bd create "Add user review feature to the store page"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: BD_GUARD_ALLOW=1 overrides soft rule only" {
    run bash -c 'jq -n --arg c "bd create \"Fix the ask-the-user detection\"" "{tool_input:{command:\$c}}" | BD_GUARD_ALLOW=1 '"$GUARD"' 2>&1'
    [ "$status" -eq 0 ]
}

@test "bd-guard: non-bd commands and empty input pass untouched" {
    run_guard 'git commit -m "ask the user later"'
    [ "$status" -eq 0 ]
    run_guard 'echo bd create'
    [ "$status" -eq 0 ]
    run bash -c "printf '' | $GUARD"
    [ "$status" -eq 0 ]
}

# --- Bypass resistance: hard rule must fire despite obfuscated prefixes -------

@test "bd-guard: env-assignment prefix does not hide a human assignee" {
    run_guard 'BEADS_ACTOR=claude bd create "x" -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: leading whitespace does not hide a human assignee" {
    run_guard '  bd create "x" -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: wrapper words (command/builtin/env/nohup/time) do not hide it" {
    for w in command builtin env nohup time; do
        run_guard "$w bd create \"x\" -a joe"
        [ "$status" -eq 2 ] || { echo "wrapper '$w' bypassed"; false; }
    done
}

@test "bd-guard: tab separators do not hide bd verb or assignee flags" {
    run_guard "$(printf 'bd\tcreate "x" -a joe')"
    [ "$status" -eq 2 ]
    run_guard "$(printf 'bd create "x" -a\tjoe')"
    [ "$status" -eq 2 ]
    run_guard "$(printf 'bd create "x" --assignee\tjoe')"
    [ "$status" -eq 2 ]
}

@test "bd-guard: stacked whitespace+env+wrapper+tab combo still blocks" {
    run_guard "$(printf '  FOO=1 command bd\tcreate "x" -a\tjoe')"
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: bd assign behind a wrapper word still extracts the assignee" {
    run_guard 'command bd assign wp9 joe'
    [ "$status" -eq 2 ]
}

@test "bd-guard: soft rule fires through an obfuscating prefix" {
    run_guard 'BEADS_ACTOR=claude bd create "Ask the user which DB to use"'
    [ "$status" -eq 2 ]
    run_guard 'command bd create -d "waiting for user approval"'
    [ "$status" -eq 2 ]
}

# --- Working BD_GUARD_ALLOW override (literal command prefix) -----------------

@test "bd-guard: literal BD_GUARD_ALLOW=1 command prefix overrides soft rule" {
    run_guard 'BD_GUARD_ALLOW=1 bd create "Ask the user which DB to use"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: literal BD_GUARD_ALLOW=1 prefix does NOT override hard rule" {
    run_guard 'BD_GUARD_ALLOW=1 bd create "x" -a joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

# --- P2 false positives that must be ALLOWED ---------------------------------

@test "bd-guard: feature text 'assigned to the user' is not a violation" {
    run_guard 'bd create "Show tasks assigned to the user on their dashboard"'
    [ "$status" -eq 0 ]
}

@test "bd-guard: close reasons describing done feature/doc work pass" {
    run_guard 'bd close wp9 --reason "Removed the unverified-email warning banner"'
    [ "$status" -eq 0 ]
    run_guard 'bd close wp9 --reason "Documented remaining work items in the roadmap"'
    [ "$status" -eq 0 ]
    run_guard 'bd close wp9 --reason "Guarded so the form is not pushed twice"'
    [ "$status" -eq 0 ]
}

# --- Hard rule: all three -a short-flag spellings extract the assignee --------

@test "bd-guard: -a=joe (equals-glued short flag) is blocked" {
    run_guard 'bd create x -a=joe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: -ajoe (value-glued short flag) is blocked" {
    run_guard 'bd create x -ajoe'
    [ "$status" -eq 2 ]
    [[ "$output" == *"NEVER assigned to a human"* ]]
}

@test "bd-guard: -a short-flag anchoring does not misfire on --all or --claim" {
    run_guard 'bd create x --all'
    [ "$status" -eq 0 ]
    run_guard 'bd update wp9 --claim'
    [ "$status" -eq 0 ]
    run_guard 'bd create x -aclaude'
    [ "$status" -eq 0 ]
}

# --- Soft rule: unverified boundary restored for closing quote/punctuation ----

@test "bd-guard: 'unverified' followed by quote or punctuation blocks a close" {
    run_guard 'bd close wp9 --reason "left unverified"'
    [ "$status" -eq 2 ]
    run_guard 'bd close wp9 --reason "deployed unverified."'
    [ "$status" -eq 2 ]
    # ...but the hyphenated feature term stays allowed.
    run_guard 'bd close wp9 --reason "Removed the unverified-email warning banner"'
    [ "$status" -eq 0 ]
}

# --- Override: only a genuine command-prefix assignment unlocks the soft rule -

@test "bd-guard: trailing BD_GUARD_ALLOW=1 comment does NOT unlock the soft rule" {
    run_guard 'bd create "Ask the user which DB" # BD_GUARD_ALLOW=1'
    [ "$status" -eq 2 ]
}

@test "bd-guard: BD_GUARD_ALLOW=1 after an env-assignment chain still unlocks" {
    run_guard 'FOO=1 BD_GUARD_ALLOW=1 bd create "Ask the user which DB"'
    [ "$status" -eq 0 ]
}

# --- Optional: brace-group command position is caught ------------------------

@test "bd-guard: bd inside a { ...; } brace group is caught" {
    run_guard '{ bd create x -a joe; }'
    [ "$status" -eq 2 ]
}
