#!/usr/bin/env bats
#
# S7 acceptance contract (claude-orca-3sk.7) -- FROZEN from RED-AT onward.
# Two jobs: (1) gate that the port actually happened -- run-tests.sh and
# every named suite exist, and config/claude-settings.json wires the full
# hook surface; (2) gate that a superseded layer left no residue under
# scripts/ or config/. At RED (nothing ported yet) job (1) fails; job (2)
# mechanically passes because there is nothing to grep yet -- it only bites
# once the port is done.
#
# claude-orca-qa2.3 re-points job (2): v3 runs Linux Orca inside an Apple
# container, so docker, /home/agent, /usr/local/bin and Xvfb are the design
# rather than residue. The stale tokens now are v2's -- Seatbelt, srt, the
# self-test, the launcher bundle, the walk-through -- alongside the
# tmux/fleet layer the port already dropped.

load helpers/setup

REQUIRED_SUITES="lane bd-guard outbound-guard auth-guard contract-gate delegation-gate acceptance-contracts statusline prime-hook rulebook session-end-audit workflows code-map container-entrypoint launcher-v3 v2-gone"

@test "claude-settings.json wires every required hook event and PreToolUse matcher" {
    settings="$REPO_ROOT/config/claude-settings.json"
    [ -f "$settings" ]
    run jq -e . "$settings"
    [ "$status" -eq 0 ]

    for event in UserPromptSubmit SessionStart PostToolUse PostModelSwitch ConfigChange Stop SessionEnd PreToolUse; do
        run jq -e --arg e "$event" '(.hooks[$e] // []) | length > 0' "$settings"
        [ "$status" -eq 0 ]
    done
    for matcher in Bash Agent Workflow; do
        run jq -e --arg m "$matcher" '[.hooks.PreToolUse[].matcher] | index($m) != null' "$settings"
        [ "$status" -eq 0 ]
    done
}
