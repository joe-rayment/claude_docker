#!/usr/bin/env bats

# auth-guard.bats — scripts/auth-guard.sh: billing hard-guard
# (beads_claude_docker-q34). This sandbox must run Claude Code on
# subscription auth only; ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN/
# ANTHROPIC_API_KEY -- in the process env OR under the `.env` object of
# the config dir's settings.json or settings.local.json (lib/paths.sh's
# claude_config_dir(), default $HOME/.claude when CLAUDE_CONFIG_DIR is
# unset, same default these tests rely on) -- silently flip billing to
# API. A hazard, not a config choice: FATAL + exit 1 by default,
# CLAUDE_DEV_ALLOW_API_BILLING=1 downgrades to a WARNING and exit 0.
#
# S7 port (claude-orca-3sk.7) of the old template's entrypoint.sh wiring
# tests and the tier-set/tier-reconcile ANTHROPIC_* purge-extension tests
# is dropped: entrypoint.sh has no equivalent here (sandboxing is shell-
# level, see .claude/plans/orca-port.md S3.2, not a container ENTRYPOINT),
# and the purge-extension was never implemented in S4's tier-set.sh/
# tier-reconcile.sh (only ANTHROPIC_DEFAULT_*/CLAUDE_CODE_SUBAGENT_MODEL
# are purged there, per tests/tier-hooks.bats -- FROZEN); adding it would
# mean changing an already-verified S4 script outside this bead's scope.
# auth-guard.sh's own hook-time block covers the same hazard regardless.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/auth-guard.sh"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    # a scratch HOME so the real ~/.claude is never read or touched
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    # a clean slate regardless of what this live sandbox happens to export
    unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_DEV_ALLOW_API_BILLING CLAUDE_CONFIG_DIR
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

# A PATH with everything auth-guard.sh's own bootstrap needs (dirname,
# readlink -- see lib/paths.sh's symlink-chain resolver) EXCEPT jq itself,
# so the test isolates "jq is absent" from "nothing is on PATH".
no_jq_bin_dir() {
    local dir="$BATS_TEST_TMPDIR/no-jq-bin"
    mkdir -p "$dir"
    ln -sf "$(command -v dirname)" "$dir/dirname"
    ln -sf "$(command -v readlink)" "$dir/readlink"
    printf '%s\n' "$dir"
}

@test "auth-guard.sh: a missing jq does not crash and still catches a process-env hit" {
    run env HOME="$HOME" PATH="$(no_jq_bin_dir)" ANTHROPIC_API_KEY="sk-ant-leaked" "$BASH_BIN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
}

@test "auth-guard.sh: a missing jq fails open on a settings-only hit -- no crash, exit 0, no false FATAL" {
    settings_json '{"env":{"ANTHROPIC_API_KEY":"sk-ant-leaked"}}'
    run env HOME="$HOME" PATH="$(no_jq_bin_dir)" "$BASH_BIN" "$SCRIPT"
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

# ── config dir resolution: CLAUDE_CONFIG_DIR overrides $HOME/.claude ───────

@test "auth-guard.sh: CLAUDE_CONFIG_DIR overrides which settings.json is read" {
    alt="$BATS_TEST_TMPDIR/alt-config"
    mkdir -p "$alt"
    printf '%s' '{"env":{"ANTHROPIC_API_KEY":"sk-ant-leaked"}}' > "$alt/settings.json"
    run env HOME="$HOME" CLAUDE_CONFIG_DIR="$alt" "$BASH_BIN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"$alt/settings.json"* ]]
}

@test "auth-guard.sh: scripts/auth-guard.sh is executable" {
    [ -x "$SCRIPT" ]
}
