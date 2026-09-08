#!/usr/bin/env bats
# outbound-guard.bats — the two mechanical outbound-network rules a prose
# instruction alone couldn't hold (beads_claude_docker-y2qe, then re-gated on
# auth by beads_claude_docker-t1ym):
#   PreToolUse (matcher Bash)   deny any snow/snowsql invocation, always;
#                               deny git push / gh pr create / gh repo create /
#                               bd dolt push ONLY when GitHub auth is
#                               positively absent -- GH_TOKEN/GITHUB_TOKEN
#                               unset, `gh api user` fails (the validity
#                               probe as of beads_claude_docker-iih3; see
#                               tests/outbound-guard-gh-status.bats for its
#                               timeout/cache behavior), and no ~/.ssh/id_*
#                               private key. No prompt wording, no session
#                               marker.
# Like every hook in this repo it MUST fail open: malformed/empty stdin, a
# non-Bash tool -- all silent exit 0, never a block.

GUARD=${OUTBOUND_GUARD_BIN:-/workspace/scripts/outbound-guard.sh}

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"

    # Isolated HOME with no ~/.ssh by default -- stub_ssh_key populates
    # $HOME/.ssh/id_* for the tests that need the ssh-key auth signal.
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"

    # Stub PATH `gh` that fails by default (no output, exit 1) -- simulates
    # "auth absent" (including for `gh api user`, the validity probe).
    # stub_gh_authenticated overwrites this for the tests that need an
    # authenticated gh.
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    cat > "$STUB_BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
    chmod +x "$STUB_BIN/gh"
    export PATH="$STUB_BIN:$PATH"

    unset GH_TOKEN GITHUB_TOKEN
}

stub_gh_authenticated() {
    cat > "$STUB_BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
    echo "fake-gh-token-value"
    exit 0
fi
# `gh api user` is the validity probe github_auth_present() actually calls
# (beads_claude_docker-iih3 -- neither `gh auth token` nor `gh auth
# status` alone proved reliable: both can exit 0 for a token GitHub has
# since invalidated). Succeeding here is what makes this stub a genuinely
# authenticated gh.
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
    exit 0
fi
exit 1
STUBEOF
    chmod +x "$STUB_BIN/gh"
}

stub_ssh_key() {
    mkdir -p "$HOME/.ssh"
    : > "$HOME/.ssh/id_ed25519"
}

# run_pretool <command> [tool_name=Bash]; sets $status/$output.
run_pretool() {
    local cmd="$1" tool="${2:-Bash}"
    run bash -c 'jq -n --arg c "$1" --arg tool "$2" "{tool_name:\$tool, session_id:\"s1\", tool_input:{command:\$c}}" | "$0"' "$GUARD" "$cmd" "$tool"
}

# run_pretool_no_sid <command> [tool_name=Bash]; payload with no session_id KEY at all.
run_pretool_no_sid() {
    local cmd="$1" tool="${2:-Bash}"
    run bash -c 'jq -n --arg c "$1" --arg tool "$2" "{tool_name:\$tool, tool_input:{command:\$c}}" | "$0"' "$GUARD" "$cmd" "$tool"
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

@test "outbound-guard: snow deny is unconditional -- present GitHub auth does not lift it" {
    export GH_TOKEN="fake-gh-token-value"
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

# ── push/deploy: denied only when GitHub auth is positively absent ─────────

@test "outbound-guard: 'git push origin main' is denied with no GitHub auth" {
    run_pretool 'git push origin main'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    [[ "$(deny_reason)" == *"no GitHub authentication"* ]]
}

@test "outbound-guard: 'gh pr create --fill' is denied with no GitHub auth" {
    run_pretool 'gh pr create --fill'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"no GitHub authentication"* ]]
}

@test "outbound-guard: 'gh repo create' is denied with no GitHub auth" {
    run_pretool 'gh repo create foo --public'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"no GitHub authentication"* ]]
}

@test "outbound-guard: 'bd dolt push' is denied with no GitHub auth" {
    run_pretool 'bd dolt push'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"no GitHub authentication"* ]]
}

@test "outbound-guard: git push is allowed when GH_TOKEN is set" {
    export GH_TOKEN="fake-gh-token-value"
    run_pretool 'git push origin main'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: git push is allowed when GITHUB_TOKEN is set" {
    export GITHUB_TOKEN="fake-gh-token-value"
    run_pretool 'git push origin main'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: git push is allowed when gh is genuinely authenticated per 'gh api user' (no GH_TOKEN, no ssh key)" {
    stub_gh_authenticated
    run_pretool 'git push origin main'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: git push is allowed when a private ssh key exists in ~/.ssh (no GH_TOKEN, gh auth token fails)" {
    stub_ssh_key
    run_pretool 'git push origin main'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: git push is DENIED when ~/.ssh holds only a public key (id_rsa.pub is not authentication)" {
    mkdir -p "$HOME/.ssh"
    : > "$HOME/.ssh/id_rsa.pub"
    run_pretool 'git push origin main'
    [ "$status" -eq 0 ]
    [[ "$output" == *"no GitHub authentication"* ]]
}

@test "outbound-guard: gh pr create is allowed when GH_TOKEN is set" {
    export GH_TOKEN="fake-gh-token-value"
    run_pretool 'gh pr create --fill'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: bd dolt push is allowed when GH_TOKEN is set" {
    export GH_TOKEN="fake-gh-token-value"
    run_pretool 'bd dolt push'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: push denial/allow does not depend on session_id -- same result with no session_id key at all" {
    run_pretool_no_sid 'git push origin main'
    [ "$status" -eq 0 ]
    [[ "$(deny_reason)" == *"no GitHub authentication"* ]]

    export GH_TOKEN="fake-gh-token-value"
    run_pretool_no_sid 'git push origin main'
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
    run_pretool 'rm -rf /tmp/x' 'Read'
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

# ── wiring: config, Dockerfile, plugin regen ────────────────────────────────

@test "outbound-guard: wired on PreToolUse (Bash) in config/claude-settings.json via the guarded idiom" {
    run jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("outbound-guard")) | select(.command | contains("command -v outbound-guard"))] | length > 0' /workspace/config/claude-settings.json
    [ "$status" -eq 0 ]
}

@test "outbound-guard: the UserPromptSubmit (--prompt mode) hook entry is removed from config/claude-settings.json" {
    run jq -e '[.hooks.UserPromptSubmit[]? | .hooks[]? | select(.command | contains("outbound-guard"))] | length == 0' /workspace/config/claude-settings.json
    [ "$status" -eq 0 ]
}

@test "outbound-guard: the pre-existing Bash(snow *) / Bash(snowsql *) permission denies are kept" {
    run jq -e '.permissions.deny | index("Bash(snow *)")' /workspace/config/claude-settings.json
    [ "$status" -eq 0 ]
    run jq -e '.permissions.deny | index("Bash(snowsql *)")' /workspace/config/claude-settings.json
    [ "$status" -eq 0 ]
}

@test "outbound-guard: Dockerfile COPYs scripts/outbound-guard.sh to /usr/local/bin/outbound-guard" {
    run grep -E 'COPY[^#]*scripts/outbound-guard\.sh[[:space:]]+/usr/local/bin/outbound-guard' /workspace/Dockerfile
    [ "$status" -eq 0 ]
}

@test "outbound-guard: plugin/bin/outbound-guard is byte-identical to scripts/outbound-guard.sh" {
    [ -f /workspace/plugin/bin/outbound-guard ]
    diff -q /workspace/plugin/bin/outbound-guard /workspace/scripts/outbound-guard.sh
}

@test "outbound-guard: scripts/outbound-guard.sh is executable" {
    [ -x /workspace/scripts/outbound-guard.sh ]
}

@test "outbound-guard: no PROMPT_RE, --prompt mode, or marker-file machinery remains in the script" {
    run grep -nE 'PROMPT_RE|marker_file|OUTBOUND_GUARD_STATE_DIR|--prompt' /workspace/scripts/outbound-guard.sh
    [ "$status" -ne 0 ]
}
