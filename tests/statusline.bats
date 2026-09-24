#!/usr/bin/env bats

# statusline.bats — config/statusline.sh gains three new segments (prompt-cache
# hit ratio, context-window remaining, session cost) fed by JSON fields Claude
# Code >=2.1.251 emits, degrading byte-identically to today's output when those
# fields are absent (the container is 2.1.247, so absence is the live case
# until the next image rebuild). See beads_claude_docker-1jw.

STATUSLINE=${STATUSLINE_BIN:-"$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/config/statusline.sh"}
FIXTURES="${BATS_TEST_DIRNAME}/fixtures"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

@test "statusline: full fixture renders the prompt-cache hit-ratio percent" {
    run bash "$STATUSLINE" < "$FIXTURES/statusline-full.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cache 87%"* ]]
}

@test "statusline: full fixture renders the context-window remaining percent" {
    run bash "$STATUSLINE" < "$FIXTURES/statusline-full.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ctx 62%"* ]]
}

@test "statusline: full fixture renders the session cost in USD" {
    run bash "$STATUSLINE" < "$FIXTURES/statusline-full.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'$3.42'* ]]
}

@test "statusline: subagentStatusLine renders empty content so native sub-agent rows are not drawn" {
    # The rows under the status bar are Claude Code's NATIVE sub-agent rows;
    # an agent whose subagentStatusLine command returns empty content is not
    # rendered. The Orca sidebar is the agent display now (claude-orca-640),
    # fed by Orca's managed SubagentStart/SubagentStop hook entries, which
    # stay. The command path is formed the same way statusLine reaches
    # config/statusline.sh: through the template's bin/ symlink.
    repo=$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)
    settings="$repo/config/claude-settings.json"
    # the statusLine entry itself is unchanged
    [ "$(jq -r '.statusLine.command // ""' "$settings")" = "__HOST__/template/bin/statusline" ]
    cmd=$(jq -r '.subagentStatusLine.command // ""' "$settings")
    [ -n "$cmd" ]
    [[ "$cmd" == "__HOST__/template/bin/statusline-subagent" ]]
    script="$(printf '%s' "$cmd" | sed "s#__HOST__/template#$repo#")"
    [ -x "$script" ]
    run "$script" <<< '{"id":"agent-1","name":"x","status":"running"}'
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.id')" = "agent-1" ]
    [ "$(printf '%s' "$output" | jq -r '.content')" = "" ]
}

@test "statusline: legacy fixture output is byte-identical to the pre-change script (regression guard)" {
    # Golden for this exact fixture. The session/weekly numbers are the
    # fixture's own rate_limits (23.5 -> 23%, 41.2 -> 41%) -- the script
    # reads them from Claude Code's JSON since Sept 2026 instead of fetching
    # them itself (slim-down B7).
    # The branch segment is derived from the checkout itself, using the exact
    # git expression statusline.sh runs (claude-orca-640): a worktree branch
    # like joe-rayment/wt-640 must pass the same golden a `main` checkout
    # does -- the golden guards the script, not the checkout's branch name.
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    golden=$'\033[32mSonnet\033[0m | \033[33m\xe2\x97\x8f\xe2\x97\x8f\xe2\x97\x8f\xe2\x97\x8f\xe2\x97\x8b\xe2\x97\x8b\xe2\x97\x8b\xe2\x97\x8b\xe2\x97\x8b\xe2\x97\x8b 45%\033[0m | \033[36m'"$branch"$'\033[0m | session: \033[32m23%\033[0m | weekly: \033[32m41%\033[0m'
    run bash "$STATUSLINE" < "$FIXTURES/statusline-legacy.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$golden" ]
}

# Guards:   the usage segments show "?" (grey), not a made-up number, when
#           Claude Code sends no rate_limits (not a subscriber, or before
#           the session's first reply).
# Fails if: the script invents a value, or reaches for the network.
# Run:      bats -f 'no rate_limits' tests/statusline.bats
@test "statusline: no rate_limits in the input shows ? for session and weekly" {
    run bash "$STATUSLINE" <<< '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":12}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'session: \033[90m?\033[0m | weekly: \033[90m?\033[0m'* ]]
}
