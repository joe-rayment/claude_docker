#!/usr/bin/env bats
# outbound-guard.bats — the two mechanical outbound-network rules a prose
# instruction alone couldn't hold (beads_claude_docker-y2qe):
#   PreToolUse (matcher Bash)   deny any snow/snowsql invocation, always;
#                               deny git push / gh pr create / gh repo create /
#                               bd dolt push unless the current prompt asked
#   UserPromptSubmit            outbound-guard --prompt: set/clear the
#                               per-session "this prompt asked for a push"
#                               marker from the prompt's own wording
# Like every hook in this repo it MUST fail open: malformed/empty stdin,
# missing session_id, a non-Bash tool — all silent exit 0, never a block.

REPO=${OUTBOUND_GUARD_REPO:-"$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"}
GUARD=${OUTBOUND_GUARD_BIN:-"$REPO/scripts/outbound-guard.sh"}
SETTINGS="$REPO/config/claude-settings.json"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export OUTBOUND_GUARD_STATE_DIR="$BATS_TEST_TMPDIR/outbound-guard-state"
}

# run_pretool <command> [session_id=s1] [tool_name=Bash]; sets $status/$output.
run_pretool() {
    local cmd="$1" sid="${2:-s1}" tool="${3:-Bash}"
    run bash -c 'jq -n --arg c "$1" --arg sid "$2" --arg tool "$3" "{tool_name:\$tool, session_id:\$sid, tool_input:{command:\$c}}" | "$0"' "$GUARD" "$cmd" "$sid" "$tool"
}

# run_pretool_no_sid <command> [tool_name=Bash]; payload with no session_id KEY at all.
run_pretool_no_sid() {
    local cmd="$1" tool="${2:-Bash}"
    run bash -c 'jq -n --arg c "$1" --arg tool "$2" "{tool_name:\$tool, tool_input:{command:\$c}}" | "$0"' "$GUARD" "$cmd" "$tool"
}

# run_prompt <prompt text> [session_id=s1]; UserPromptSubmit payload.
run_prompt() {
    local prompt="$1" sid="${2:-s1}"
    run bash -c 'jq -n --arg p "$1" --arg sid "$2" "{session_id:\$sid, prompt:\$p}" | "$0" --prompt' "$GUARD" "$prompt" "$sid"
}

deny_reason() {
    printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason'
}

# ── snow / snowsql: unconditional deny ──────────────────────────────────────

@test "outbound-guard: 'pip install snowflake-cli && snow sql -q 1' is denied (snow after &&)" {
    run_pretool 'pip install snowflake-cli && snow sql -q 1'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    [[ "$(deny_reason)" == *"no Snowflake access"* ]]
}

@test "outbound-guard: 'snowsql -q \"select 1\"' is denied" {
    run_pretool 'snowsql -q "select 1"'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    [[ "$(deny_reason)" == *"no Snowflake access"* ]]
}

@test "outbound-guard: snow deny is unconditional -- no prior push-prompt marker lifts it" {
    run_prompt 'please push my changes'
    [ "$status" -eq 0 ]
    run_pretool 'snow sql -q "select 1"'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"no Snowflake access"* ]]
}

@test "outbound-guard: 'python -m snowflake.cli deploy' is denied (module form)" {
    run_pretool 'python -m snowflake.cli deploy'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"no Snowflake access"* ]]
}

@test "outbound-guard: 'python3 -m snowflake.cli deploy' is denied (module form)" {
    run_pretool 'python3 -m snowflake.cli deploy'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"no Snowflake access"* ]]
}

# ── push/deploy: denied unless the current prompt's marker is set ──────────

@test "outbound-guard: 'git push origin main' is denied with no marker" {
    run_pretool 'git push origin main'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    [[ "$(deny_reason)" == *"opt-in"* ]]
}

@test "outbound-guard: 'gh pr create --fill' is denied with no marker" {
    run_pretool 'gh pr create --fill'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"opt-in"* ]]
}

@test "outbound-guard: 'gh repo create' is denied with no marker" {
    run_pretool 'gh repo create foo --public'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"opt-in"* ]]
}

@test "outbound-guard: 'bd dolt push' is denied with no marker" {
    run_pretool 'bd dolt push'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"opt-in"* ]]
}

# ── marker lifecycle: set by a prompt that asked, cleared by one that didn't ─

@test "outbound-guard: git push is allowed only for the prompt that asked for it" {
    run_pretool 'git push origin main' 's1'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"opt-in"* ]]

    run_prompt 'please push this to origin' 's1'
    [ "$status" -eq 0 ]

    run_pretool 'git push origin main' 's1'
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run_prompt 'fix the typo in the README' 's1'
    [ "$status" -eq 0 ]

    run_pretool 'git push origin main' 's1'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"opt-in"* ]]
}

@test "outbound-guard: the marker is per session -- another session's push still denies" {
    run_prompt 'please push this' 's1'
    [ "$status" -eq 0 ]
    run_pretool 'git push origin main' 's2'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"opt-in"* ]]
}

@test "outbound-guard: prompt wording is case-insensitive and covers publish/PR phrasing" {
    run_prompt 'PUBLISH the release' 's1'
    [ "$status" -eq 0 ]
    run_pretool 'gh pr create --fill' 's1'
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run_prompt 'no relevant wording here' 's1'
    [ "$status" -eq 0 ]

    run_prompt 'please open a pull request for this' 's1'
    [ "$status" -eq 0 ]
    run_pretool 'gh pr create --fill' 's1'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── allow list: ordinary commands and non-Snowflake dependencies pass ──────

@test "outbound-guard: 'git commit -m x' is allowed" {
    run_pretool 'git commit -m x'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: 'git fetch' is allowed" {
    run_pretool 'git fetch'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: 'gh auth status' is allowed" {
    run_pretool 'gh auth status'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: 'pip install snowflake-snowpark-python' is allowed (no bare snow/snowsql token)" {
    run_pretool 'pip install snowflake-snowpark-python'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: 'pip install snowflake-cli' alone is allowed (package name, no separate snow invocation)" {
    run_pretool 'pip install snowflake-cli'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: 'pip install snowflake-connector-python' is allowed" {
    run_pretool 'pip install snowflake-connector-python'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── fail-open contract ───────────────────────────────────────────────────────

@test "outbound-guard: a non-Bash tool payload passes through with empty output" {
    run_pretool 'rm -rf /tmp/x' 's1' 'Read'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: malformed stdin exits 0 with no deny output" {
    run bash -c 'printf "not json at all" | "$0"' "$GUARD"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: empty stdin exits 0 with no output" {
    run bash -c 'printf "" | "$0"' "$GUARD"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: PreToolUse payload with no session_id key still denies a snow command (unconditional, no session_id needed)" {
    run_pretool_no_sid 'snowsql -q "select 1"'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"no Snowflake access"* ]]
}

@test "outbound-guard: PreToolUse payload with no session_id key still denies a snow module invocation" {
    run_pretool_no_sid 'python3 -m snowflake.cli deploy'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"no Snowflake access"* ]]
}

@test "outbound-guard: PreToolUse payload with no session_id key fails open for a push command (only the marker rule needs a session_id)" {
    run_pretool_no_sid 'git push origin main'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard --prompt: malformed stdin exits 0 and sets no marker" {
    run bash -c 'printf "not json at all" | "$0" --prompt' "$GUARD"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -d "$OUTBOUND_GUARD_STATE_DIR" ]
}

@test "outbound-guard --prompt: payload with no session_id exits 0 and writes nothing" {
    run bash -c 'jq -n --arg p "please push" "{prompt:\$p}" | "$0" --prompt' "$GUARD"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -d "$OUTBOUND_GUARD_STATE_DIR" ]
}

# ── wiring: config/claude-settings.json ─────────────────────────────────────
# S7 (claude-orca-3sk.7): the guarded idiom is `[ -x ".../bin/<name>" ] &&
# exec ".../bin/<name>" ...; exit 0` -- no `command -v`, no Dockerfile/
# plugin regen (neither exists in this template).

@test "outbound-guard: wired on PreToolUse (Bash) in config/claude-settings.json via the guarded idiom" {
    run jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("template/bin/outbound-guard")) | select(.command | contains("[ -x "))] | length > 0' "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "outbound-guard: wired on UserPromptSubmit (--prompt mode) in config/claude-settings.json via the guarded idiom" {
    run jq -e '[.hooks.UserPromptSubmit[] | .hooks[] | select(.command | contains("template/bin/outbound-guard") and contains("--prompt"))] | length > 0' "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "outbound-guard: the Bash(snow *) / Bash(snowsql *) permission denies are kept" {
    run jq -e '.permissions.deny | index("Bash(snow *)")' "$SETTINGS"
    [ "$status" -eq 0 ]
    run jq -e '.permissions.deny | index("Bash(snowsql *)")' "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "outbound-guard: bin/outbound-guard is a symlink to scripts/outbound-guard.sh" {
    [ -L "$REPO/bin/outbound-guard" ]
    [ "$(readlink "$REPO/bin/outbound-guard")" = "../scripts/outbound-guard.sh" ]
}

@test "outbound-guard: scripts/outbound-guard.sh is executable" {
    [ -x "$REPO/scripts/outbound-guard.sh" ]
}
