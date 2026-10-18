#!/usr/bin/env bats
# outbound-guard.bats — the mechanical outbound-network rules a prose
# instruction alone couldn't hold (beads_claude_docker-y2qe, claude-orca-diz):
#   PreToolUse (matcher Bash)   deny any snow/snowsql invocation, always;
#                               deny `git push` unless `gh auth status`
#                               reports a live GitHub connection;
#                               deny `gh pr create` / `gh repo create` /
#                               `bd dolt push` unless the current prompt
#                               asked (the marker gate, unchanged for these
#                               three verbs)
#   UserPromptSubmit            outbound-guard --prompt: set/clear the
#                               per-session "this prompt asked for a push"
#                               marker from the prompt's own wording
# Like every hook in this repo it MUST fail open: malformed/empty stdin,
# missing session_id, a non-Bash tool — all silent exit 0, never a block.

REPO=${OUTBOUND_GUARD_REPO:-"$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"}
GUARD=${OUTBOUND_GUARD_BIN:-"$REPO/scripts/outbound-guard.sh"}
SETTINGS="$REPO/config/claude-settings.json"
MEMORY="$REPO/config/claude-user-memory.md"

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

# stub_gh <dir> <exit_code> [sleep_secs] — write a `gh` script at <dir>/gh
# that (if GH_CALLED_MARKER is exported) appends to that path every time
# it runs, then sleeps and exits with <exit_code>. Callers put <dir> at
# the front of PATH so the guard's own `gh auth status` call sees it.
stub_gh() {
    local dir="$1" code="$2" sleep_s="${3:-0}"
    mkdir -p "$dir"
    cat > "$dir/gh" <<STUB
#!/usr/bin/env bash
[ -n "\${GH_CALLED_MARKER:-}" ] && printf '1' >> "\$GH_CALLED_MARKER"
sleep $sleep_s
exit $code
STUB
    chmod +x "$dir/gh"
}

# make_no_gh_path <dir> — populate <dir> with symlinks to every binary
# outbound-guard.sh needs EXCEPT gh, so `command -v gh` genuinely fails
# without losing jq/bash/grep/etc. Built with explicit `command -v` calls
# run from bash (not this file's own shell) so nothing shadows them.
make_no_gh_path() {
    local dir="$1" b p
    mkdir -p "$dir"
    for b in bash env jq cat tr mkdir rm grep dirname readlink timeout basename sed; do
        p=$(command -v "$b" 2>/dev/null) || continue
        ln -sf "$p" "$dir/$b"
    done
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

@test "the warehouse CLI stays denied even when gh is connected" {
    stub_gh "$BATS_TEST_TMPDIR/bin" 0
    local old_path="$PATH"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run_pretool 'snow sql -q "select 1"'
    PATH="$old_path"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    [[ "$(deny_reason)" == *"no Snowflake access"* ]]
}

# ── git push: gated on a live GitHub connection, not a marker ──────────────

@test "git push is allowed when gh reports a GitHub connection" {
    stub_gh "$BATS_TEST_TMPDIR/bin" 0
    local old_path="$PATH"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run_pretool 'git push origin main'
    PATH="$old_path"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "git push is denied when gh reports no GitHub connection" {
    stub_gh "$BATS_TEST_TMPDIR/bin" 1
    local old_path="$PATH"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run_pretool 'git push origin main'
    PATH="$old_path"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    [[ "$(deny_reason)" == *"GitHub connection"* ]]
}

@test "git push is denied when gh is not on PATH" {
    make_no_gh_path "$BATS_TEST_TMPDIR/bin"
    local old_path="$PATH"
    PATH="$BATS_TEST_TMPDIR/bin"
    run_pretool 'git push origin main'
    PATH="$old_path"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    [[ "$(deny_reason)" == *"GitHub connection"* ]]
}

# bats test_tags=size:medium
@test "git push is denied when the connection check times out" {
    stub_gh "$BATS_TEST_TMPDIR/bin" 0 3
    export OUTBOUND_GUARD_GH_TIMEOUT=1
    local old_path="$PATH"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run_pretool 'git push origin main'
    PATH="$old_path"
    unset OUTBOUND_GUARD_GH_TIMEOUT
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    [[ "$(deny_reason)" == *"GitHub connection"* ]]
}

@test "the git push deny message names the connection and not the prompt" {
    stub_gh "$BATS_TEST_TMPDIR/bin" 1
    local old_path="$PATH"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run_pretool 'git push origin main'
    PATH="$old_path"
    [[ "$(deny_reason)" == *"GitHub connection"* ]]
    [[ "$(deny_reason)" != *"prompt"* ]]
    [[ "$(deny_reason)" != *"opt-in"* ]]
}

@test "the connection check is not run for a non-outbound command" {
    stub_gh "$BATS_TEST_TMPDIR/bin" 0
    local marker="$BATS_TEST_TMPDIR/gh-called"
    export GH_CALLED_MARKER="$marker"
    local old_path="$PATH"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run_pretool 'git commit -m x'
    PATH="$old_path"
    unset GH_CALLED_MARKER
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$marker" ]
}

@test "git push with no session_id still fails open" {
    stub_gh "$BATS_TEST_TMPDIR/bin" 0
    local old_path="$PATH"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run_pretool_no_sid 'git push origin main'
    PATH="$old_path"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── gh pr create / gh repo create / bd dolt push: still marker-gated ───────

@test "gh pr create still requires the prompt marker" {
    run_pretool 'gh pr create --fill'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"opt-in"* ]]

    run_prompt 'please open a pull request for this' 's1'
    [ "$status" -eq 0 ]
    run_pretool 'gh pr create --fill' 's1'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "gh repo create still requires the prompt marker" {
    run_pretool 'gh repo create foo --public'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"opt-in"* ]]

    run_prompt 'please publish this as a new repo' 's1'
    [ "$status" -eq 0 ]
    run_pretool 'gh repo create foo --public' 's1'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "bd dolt push still requires the prompt marker" {
    run_pretool 'bd dolt push'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"opt-in"* ]]

    run_prompt 'please push the dolt database' 's1'
    [ "$status" -eq 0 ]
    run_pretool 'bd dolt push' 's1'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── marker lifecycle: set by a prompt that asked, cleared by one that didn't ─
# (git push is exempt now -- these three verbs are the only ones still
# reading the marker.)

@test "outbound-guard: the marker is per session -- another session's marker-gated command still denies" {
    run_prompt 'please push this' 's1'
    [ "$status" -eq 0 ]
    run_pretool 'gh pr create --fill' 's2'
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

@test "outbound-guard: PreToolUse payload with no session_id key fails open for a marker-gated command (only the marker rule needs a session_id)" {
    run_pretool_no_sid 'gh pr create --fill'
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

# ── rulebook prose matches the mechanism ────────────────────────────────────

# ── compound `git push && <marker verb>` must still hit the marker gate ────
# (claude-orca-cc5: the git-push branch used to end in a bare `exit 0`, so a
# command that also matched MARKER_RE never reached that check.)

@test "a connected git push compounded with gh pr create still requires the prompt marker" {
    stub_gh "$BATS_TEST_TMPDIR/bin" 0
    local old_path="$PATH"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run_pretool 'git push origin main && gh pr create --fill'
    PATH="$old_path"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    [[ "$(deny_reason)" == *"opt-in"* ]]
}

@test "a connected git push compounded with gh repo create still requires the prompt marker" {
    stub_gh "$BATS_TEST_TMPDIR/bin" 0
    local old_path="$PATH"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run_pretool 'git push origin main && gh repo create foo --public'
    PATH="$old_path"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    [[ "$(deny_reason)" == *"opt-in"* ]]
}

@test "a connected git push compounded with bd dolt push still requires the prompt marker" {
    stub_gh "$BATS_TEST_TMPDIR/bin" 0
    local old_path="$PATH"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run_pretool 'git push origin main && bd dolt push'
    PATH="$old_path"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    [[ "$(deny_reason)" == *"opt-in"* ]]
}

@test "a connected git push on its own is still allowed with no marker" {
    stub_gh "$BATS_TEST_TMPDIR/bin" 0
    local old_path="$PATH"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run_pretool 'git push origin main'
    PATH="$old_path"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a disconnected git push compounded with gh pr create is denied for the connection" {
    stub_gh "$BATS_TEST_TMPDIR/bin" 1
    local old_path="$PATH"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run_pretool 'git push origin main && gh pr create --fill'
    PATH="$old_path"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    [[ "$(deny_reason)" == *"GitHub connection"* ]]
}

