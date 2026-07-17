#!/usr/bin/env bats

# bd-guard — PreToolUse(Bash) hook that keeps beads Claude-only.
# Tests run the repo script directly (not the baked /usr/local/bin copy).

GUARD=/workspace/scripts/bd-guard.sh

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    unset BD_GUARD_ALLOW
}

# run_guard <command-string>; sets $status / $output (stderr)
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
