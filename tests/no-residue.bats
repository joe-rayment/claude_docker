#!/usr/bin/env bats
#
# S7 acceptance contract (claude-orca-3sk.7) -- FROZEN from RED-AT onward.
# Two jobs: (1) gate that the port actually happened -- run-tests.sh and
# every named suite exist, and config/claude-settings.json wires the full
# hook surface; (2) gate that the Docker/tmux/fleet/worktree-sessions
# layers left no residue under scripts/ or config/. At RED (nothing ported
# yet) job (1) fails; job (2) mechanically passes because there is nothing
# to grep yet -- it only bites once the port is done.

load helpers/setup

REQUIRED_SUITES="lane bd-guard outbound-guard auth-guard contract-gate delegation-gate acceptance-contracts statusline prime-hook rulebook session-end-audit workflows code-map"

@test "the ported suite exists: run-tests.sh and every named test suite" {
    [ -x "$REPO_ROOT/run-tests.sh" ]
    for suite in $REQUIRED_SUITES; do
        [ -f "$REPO_ROOT/tests/${suite}.bats" ]
    done
}

@test "claude-settings.json wires every required hook event and PreToolUse matcher" {
    settings="$REPO_ROOT/config/claude-settings.json"
    [ -f "$settings" ]
    run jq -e . "$settings"
    [ "$status" -eq 0 ]

    for event in UserPromptSubmit SessionStart PostModelSwitch ConfigChange Stop SessionEnd PreToolUse; do
        run jq -e --arg e "$event" '(.hooks[$e] // []) | length > 0' "$settings"
        [ "$status" -eq 0 ]
    done
    for matcher in Bash Agent Workflow; do
        run jq -e --arg m "$matcher" '[.hooks.PreToolUse[].matcher] | index($m) != null' "$settings"
        [ "$status" -eq 0 ]
    done
}

@test "no residue of the Docker/tmux/fleet/worktree-sessions layers under scripts/ or config/" {
    run grep -rniE \
        '\btmux\b|\bfleet\b|\bcs-new\b|\bpeers\b|\bsession-title\b|\biptables\b|\bxvfb\b|\bdocker\b|/workspace\b|/home/agent\b|/usr/local/bin\b' \
        "$REPO_ROOT/scripts" "$REPO_ROOT/config"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}
