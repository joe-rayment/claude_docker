#!/usr/bin/env bats

# auth-guard.bats — scripts/auth-guard.sh: billing hard-guard
# (beads_claude_docker-q34). This container must run Claude Code on
# subscription auth only; ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN/
# ANTHROPIC_API_KEY -- in the process env OR under the `.env` object of
# ~/.claude/settings.json or ~/.claude/settings.local.json -- silently flip
# billing to API. A hazard, not a config choice: FATAL + exit 1 by default,
# CLAUDE_DEV_ALLOW_API_BILLING=1 downgrades to a WARNING and exit 0.
#
# FROZEN per beads_claude_docker-q34's acceptance contract: this file must
# not be edited after its RED commit. If a test here turns out to be wrong,
# stop and report -- do not edit it.

SCRIPT=/workspace/scripts/auth-guard.sh
ENTRYPOINT=/workspace/scripts/entrypoint.sh
REPO_ROOT=/workspace
TSET="$REPO_ROOT/scripts/tier-set.sh"
RECON="$REPO_ROOT/scripts/tier-reconcile.sh"
DERIVE="$REPO_ROOT/scripts/tier-derive.sh"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    # a scratch HOME so the real ~/.claude is never read or touched
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    # a clean slate regardless of what this live container happens to export
    unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_DEV_ALLOW_API_BILLING
    BASH_BIN="$(command -v bash)"
}

settings_json() {  # settings_json <json> -- writes ~/.claude/settings.json
    mkdir -p "$HOME/.claude"
    printf '%s' "$1" > "$HOME/.claude/settings.json"
}

settings_local_json() {  # settings_local_json <json> -- writes ~/.claude/settings.local.json
    mkdir -p "$HOME/.claude"
    printf '%s' "$1" > "$HOME/.claude/settings.local.json"
}

# ── no hits: silent exit 0 ──────────────────────────────────────────────────

@test "auth-guard.sh: silent exit 0 when nothing is present and ~/.claude does not even exist" {
    run env HOME="$HOME" "$BASH_BIN" "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "auth-guard.sh: an unrelated env var and unrelated .env keys never trigger a hit" {
    settings_json '{"env":{"KEEP":"1","ANTHROPIC_MODEL":"claude-opus-5"}}'
    run env HOME="$HOME" UNRELATED_VAR=1 "$BASH_BIN" "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── (1) process-env hard fail, one per var ──────────────────────────────────

@test "auth-guard.sh: FATAL + nonzero exit when ANTHROPIC_BASE_URL is in the process env" {
    run env HOME="$HOME" ANTHROPIC_BASE_URL="https://evil.example.com" "$BASH_BIN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"ANTHROPIC_BASE_URL"* ]]
    [[ "$output" == *"process environment"* ]]
}

@test "auth-guard.sh: FATAL + nonzero exit when ANTHROPIC_AUTH_TOKEN is in the process env" {
    run env HOME="$HOME" ANTHROPIC_AUTH_TOKEN="tok-123" "$BASH_BIN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"ANTHROPIC_AUTH_TOKEN"* ]]
    [[ "$output" == *"process environment"* ]]
}

@test "auth-guard.sh: FATAL + nonzero exit when ANTHROPIC_API_KEY is in the process env" {
    run env HOME="$HOME" ANTHROPIC_API_KEY="sk-ant-leaked" "$BASH_BIN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
    [[ "$output" == *"process environment"* ]]
}

@test "auth-guard.sh: FATAL names every offending var and location when several hit at once" {
    settings_json '{"env":{"ANTHROPIC_BASE_URL":"https://evil.example.com"}}'
    run env HOME="$HOME" ANTHROPIC_API_KEY="sk-ant-leaked" "$BASH_BIN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
    [[ "$output" == *"process environment"* ]]
    [[ "$output" == *"ANTHROPIC_BASE_URL"* ]]
    [[ "$output" == *"settings.json"* ]]
}

# ── (2) settings .env hard fail, both files ─────────────────────────────────

@test "auth-guard.sh: FATAL + nonzero exit when ANTHROPIC_BASE_URL is under settings.json .env" {
    settings_json '{"env":{"ANTHROPIC_BASE_URL":"https://evil.example.com"}}'
    run env HOME="$HOME" "$BASH_BIN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"ANTHROPIC_BASE_URL"* ]]
    [[ "$output" == *"settings.json"* ]]
}

@test "auth-guard.sh: FATAL + nonzero exit when ANTHROPIC_AUTH_TOKEN is under settings.json .env" {
    settings_json '{"env":{"ANTHROPIC_AUTH_TOKEN":"tok-123"}}'
    run env HOME="$HOME" "$BASH_BIN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"ANTHROPIC_AUTH_TOKEN"* ]]
    [[ "$output" == *"settings.json"* ]]
}

@test "auth-guard.sh: FATAL + nonzero exit when ANTHROPIC_API_KEY is under settings.json .env" {
    settings_json '{"env":{"ANTHROPIC_API_KEY":"sk-ant-leaked"}}'
    run env HOME="$HOME" "$BASH_BIN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
    [[ "$output" == *"settings.json"* ]]
}

@test "auth-guard.sh: FATAL + nonzero exit when ANTHROPIC_API_KEY is under settings.local.json .env" {
    settings_local_json '{"env":{"ANTHROPIC_API_KEY":"sk-ant-leaked"}}'
    run env HOME="$HOME" "$BASH_BIN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
    [[ "$output" == *"settings.local.json"* ]]
}

@test "auth-guard.sh: both settings files are checked independently -- a hit in each is reported" {
    settings_json '{"env":{"ANTHROPIC_BASE_URL":"https://evil.example.com"}}'
    settings_local_json '{"env":{"ANTHROPIC_AUTH_TOKEN":"tok-123"}}'
    run env HOME="$HOME" "$BASH_BIN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ANTHROPIC_BASE_URL"* ]]
    [[ "$output" == *"settings.json"* ]]
    [[ "$output" == *"ANTHROPIC_AUTH_TOKEN"* ]]
    [[ "$output" == *"settings.local.json"* ]]
}

# ── (3) CLAUDE_DEV_ALLOW_API_BILLING=1 downgrades to a warning ─────────────

@test "auth-guard.sh: CLAUDE_DEV_ALLOW_API_BILLING=1 downgrades a process-env hit to WARNING, exit 0" {
    run env HOME="$HOME" ANTHROPIC_API_KEY="sk-ant-leaked" CLAUDE_DEV_ALLOW_API_BILLING=1 "$BASH_BIN" "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"* ]]
    [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
    [[ "$output" != *"FATAL"* ]]
}

@test "auth-guard.sh: CLAUDE_DEV_ALLOW_API_BILLING=1 downgrades a settings .env hit to WARNING, exit 0" {
    settings_json '{"env":{"ANTHROPIC_BASE_URL":"https://evil.example.com"}}'
    run env HOME="$HOME" CLAUDE_DEV_ALLOW_API_BILLING=1 "$BASH_BIN" "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"* ]]
    [[ "$output" == *"ANTHROPIC_BASE_URL"* ]]
    [[ "$output" != *"FATAL"* ]]
}

@test "auth-guard.sh: CLAUDE_DEV_ALLOW_API_BILLING=1 downgrades a combined env+settings hit -- every line WARNING" {
    settings_json '{"env":{"ANTHROPIC_BASE_URL":"https://evil.example.com"}}'
    settings_local_json '{"env":{"ANTHROPIC_AUTH_TOKEN":"tok-123"}}'
    run env HOME="$HOME" ANTHROPIC_API_KEY="sk-ant-leaked" CLAUDE_DEV_ALLOW_API_BILLING=1 "$BASH_BIN" "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"* ]]
    [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
    [[ "$output" == *"ANTHROPIC_BASE_URL"* ]]
    [[ "$output" == *"ANTHROPIC_AUTH_TOKEN"* ]]
    [[ "$output" != *"FATAL"* ]]
}

@test "auth-guard.sh: only the exact flag value \"1\" downgrades -- other values still FATAL" {
    for v in 0 true yes; do
        run env HOME="$HOME" ANTHROPIC_API_KEY="sk-ant-leaked" CLAUDE_DEV_ALLOW_API_BILLING="$v" "$BASH_BIN" "$SCRIPT"
        [ "$status" -ne 0 ]
        [[ "$output" == *"FATAL"* ]]
    done
}

# ── fail-open per var-source: missing jq / missing settings files ──────────

@test "auth-guard.sh: a missing jq does not crash and still catches a process-env hit" {
    mkdir -p "$BATS_TEST_TMPDIR/empty-bin"
    run env HOME="$HOME" PATH="$BATS_TEST_TMPDIR/empty-bin" ANTHROPIC_API_KEY="sk-ant-leaked" "$BASH_BIN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
}

@test "auth-guard.sh: a missing jq fails open on a settings-only hit -- no crash, exit 0, no false FATAL" {
    settings_json '{"env":{"ANTHROPIC_API_KEY":"sk-ant-leaked"}}'
    mkdir -p "$BATS_TEST_TMPDIR/empty-bin"
    run env HOME="$HOME" PATH="$BATS_TEST_TMPDIR/empty-bin" "$BASH_BIN" "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "auth-guard.sh: settings.json missing entirely -- no crash, settings.local.json is still checked" {
    settings_local_json '{"env":{"ANTHROPIC_API_KEY":"sk-ant-leaked"}}'
    [ ! -f "$HOME/.claude/settings.json" ]
    run env HOME="$HOME" "$BASH_BIN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"settings.local.json"* ]]
}

@test "auth-guard.sh: a settings file with no .env object at all does not crash" {
    settings_json '{"model":"claude-fable-5"}'
    run env HOME="$HOME" "$BASH_BIN" "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── (4) entrypoint.sh wiring ─────────────────────────────────────────────────

@test "entrypoint.sh: invokes auth-guard.sh" {
    run grep -n 'auth-guard.sh' "$ENTRYPOINT"
    [ "$status" -eq 0 ]
}

@test "entrypoint.sh: an auth-guard failure stops the session via the sleep-infinity pattern" {
    run grep -A6 'auth-guard.sh' "$ENTRYPOINT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sleep infinity"* ]]
}

@test "entrypoint.sh: auth-guard runs before the session is launched (exec \"\$@\")" {
    guard_line=$(grep -n 'auth-guard.sh' "$ENTRYPOINT" | head -1 | cut -d: -f1)
    exec_line=$(grep -n 'exec "\$@"' "$ENTRYPOINT" | head -1 | cut -d: -f1)
    [ -n "$guard_line" ]
    [ -n "$exec_line" ]
    [ "$guard_line" -lt "$exec_line" ]
}

# ── (5) tier-set.sh / tier-reconcile.sh purge extension ────────────────────

@test "tier-set: purges ANTHROPIC_BASE_URL/AUTH_TOKEN/API_KEY from settings .env alongside the legacy purge" {
    TS="$BATS_TEST_TMPDIR/ag-tier-set-settings.json"
    TS_AGENTS="$BATS_TEST_TMPDIR/ag-tier-set-agents"
    mkdir -p "$TS_AGENTS"
    printf -- '---\nname: executor\nmodel: claude-sonnet-5\n---\nDo the slice.\n' > "$TS_AGENTS/executor.md"
    printf -- '---\nname: scout\nmodel: claude-haiku-4-5-20251001\n---\nGo look.\n' > "$TS_AGENTS/scout.md"
    jq -n '{model:"claude-opus-5", env:{KEEP:"1", CLAUDE_CODE_SUBAGENT_MODEL:"bad",
            ANTHROPIC_BASE_URL:"https://evil.example.com", ANTHROPIC_AUTH_TOKEN:"tok-123",
            ANTHROPIC_API_KEY:"sk-ant-leaked"}}' > "$TS"
    run env TIER_SETTINGS="$TS" TIER_AGENTS_DIR="$TS_AGENTS" TIER_DERIVE="$DERIVE" \
        TIER_NO_PROBE=1 sh "$TSET" sonnet
    [ "$status" -eq 0 ]
    jq -e '(.env | has("ANTHROPIC_BASE_URL")) | not' "$TS"
    jq -e '(.env | has("ANTHROPIC_AUTH_TOKEN")) | not' "$TS"
    jq -e '(.env | has("ANTHROPIC_API_KEY")) | not' "$TS"
    jq -e '(.env | has("CLAUDE_CODE_SUBAGENT_MODEL")) | not' "$TS"
    jq -e '.env.KEEP == "1"' "$TS"
}

@test "tier-reconcile: purges ANTHROPIC_BASE_URL/AUTH_TOKEN/API_KEY from settings .env alongside the legacy purge" {
    TR="$BATS_TEST_TMPDIR/ag-tier-reconcile-settings.json"
    TR_AGENTS="$BATS_TEST_TMPDIR/ag-tier-reconcile-agents"
    mkdir -p "$TR_AGENTS"
    printf -- '---\nname: executor\nmodel: claude-sonnet-5\n---\nDo the slice.\n' > "$TR_AGENTS/executor.md"
    printf -- '---\nname: scout\nmodel: claude-haiku-4-5-20251001\n---\nGo look.\n' > "$TR_AGENTS/scout.md"
    jq -n '{model:"claude-fable-5", env:{KEEP:"1", CLAUDE_CODE_SUBAGENT_MODEL:"bad",
            ANTHROPIC_BASE_URL:"https://evil.example.com", ANTHROPIC_AUTH_TOKEN:"tok-123",
            ANTHROPIC_API_KEY:"sk-ant-leaked"}}' > "$TR"
    run env TIER_SETTINGS="$TR" TIER_AGENTS_DIR="$TR_AGENTS" TIER_DERIVE="$DERIVE" sh "$RECON"
    [ "$status" -eq 0 ]
    jq -e '(.env | has("ANTHROPIC_BASE_URL")) | not' "$TR"
    jq -e '(.env | has("ANTHROPIC_AUTH_TOKEN")) | not' "$TR"
    jq -e '(.env | has("ANTHROPIC_API_KEY")) | not' "$TR"
    jq -e '(.env | has("CLAUDE_CODE_SUBAGENT_MODEL")) | not' "$TR"
    jq -e '.env.KEEP == "1"' "$TR"
}
