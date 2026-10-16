#!/usr/bin/env bats
# Guards:   a tier.json written when Orca still existed (backend "orca") reads and rewrites as subagent/headless, and /tier binds headless, never orca
# Fails if: tier_role stops mapping orca (or an unknown backend), tier-reconcile keeps storing the word "orca", or `tier-set worker orca` binds an orca backend
# Run:      bats tests/tier-headless.bats
#
# claude-orca-9bh.2 piece A2a. No Docker, no network: every script runs
# directly against a fixture CLAUDE_ORCA_ROOT / tier.json under
# $BATS_TEST_TMPDIR, never the real state.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

DERIVE="$REPO_ROOT/scripts/tier-derive.sh"
TSET="$REPO_ROOT/scripts/tier-set.sh"
PRIME="$REPO_ROOT/scripts/tier-prime.sh"
RECON="$REPO_ROOT/scripts/tier-reconcile.sh"
ROLES_LIB="$REPO_ROOT/scripts/lib/tier-roles.sh"

setup() {
    export CLAUDE_ORCA_ROOT="$BATS_TEST_TMPDIR/root"
    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/root/.claude"
    mkdir -p "$CLAUDE_ORCA_ROOT/.claude-dev/run" "$CLAUDE_CONFIG_DIR/agents"
    # the derived worker depends on an OpenRouter key: this box has none
    unset OPENROUTER_API_KEY
    export TIER_OPENROUTER_KEY_FILE="$BATS_TEST_TMPDIR/no-such-openrouter.key"
    STATE_FILE="$BATS_TEST_TMPDIR/root/.claude-dev/run/tier.json"
    export TIER_STATE_FILE="$STATE_FILE"
    export TIER_DERIVE="$DERIVE"
    export TIER_SETTINGS_LOCAL="$CLAUDE_CONFIG_DIR/settings.local.json"
    export TIER_SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
    case "$STATE_FILE" in "$BATS_TEST_TMPDIR"/*) ;; *) echo "fixture escaped tmpdir: $STATE_FILE" >&2; return 1 ;; esac
}

tier_set() { run "$TSET" "$@"; }
prime() { run "$PRIME" "$@"; }
reconcile() { run "$RECON" </dev/null; }

# an old (pre-9bh.2) tier.json: worker and recon on the dropped "orca" backend
seed_orca_state() {
    jq -n '{top:"fable", worker:"sonnet", recon:"openrouter/x/y",
            roles:{ worker:{backend:"orca",agent:"claude",model:"sonnet"},
                    recon:{backend:"orca",agent:"opencode",model:"openrouter/x/y"} },
            pinned:false, overdrive:false, updated:"2026-01-01T00:00:00Z"}' > "$STATE_FILE"
}

# role_field <role> <backend|agent|model> -- read through tier_role, the way every script does
role_field() {
    ( . "$ROLES_LIB"; tier_role_field "$STATE_FILE" "$1" "$2" )
}

@test "tier_role: a stored orca backend with the claude agent reads back as subagent" {
    seed_orca_state
    [ "$(role_field worker backend)" = "subagent" ]
    [ "$(role_field worker agent)" = "claude" ]
    [ "$(role_field worker model)" = "sonnet" ]
}

@test "tier_role: a stored orca backend with a non-claude agent reads back as headless" {
    seed_orca_state
    [ "$(role_field recon backend)" = "headless" ]
    [ "$(role_field recon agent)" = "opencode" ]
    [ "$(role_field recon model)" = "openrouter/x/y" ]
}

@test "tier_role: an unknown backend word reads back as subagent" {
    jq -n '{top:"fable", worker:"sonnet", recon:"haiku",
            roles:{ worker:{backend:"carrier-pigeon",agent:"claude",model:"sonnet"},
                    recon:{backend:"carrier-pigeon",agent:"opencode",model:"openrouter/x/y"} }}' > "$STATE_FILE"
    [ "$(role_field worker backend)" = "subagent" ]
    [ "$(role_field recon backend)" = "subagent" ]
}

@test "tier-reconcile: rewrites a stored orca backend in tier.json itself (claude -> subagent, other agents -> headless)" {
    seed_orca_state
    jq -n '{model:"opus"}' > "$TIER_SETTINGS_LOCAL"
    run jq -e '.roles.worker.backend == "orca" and .roles.recon.backend == "orca"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    reconcile
    [ "$status" -eq 0 ]
    # the file on disk now holds the new words -- no reader had to migrate it
    run jq -e '.roles.worker.backend == "subagent" and .roles.worker.agent == "claude"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon.backend == "headless" and .roles.recon.agent == "opencode" and .roles.recon.model == "openrouter/x/y"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    run grep -c '"orca"' "$STATE_FILE"
    [ "$output" = "0" ]
}

@test "tier-set worker claude:sonnet binds the headless backend with the claude agent" {
    tier_set worker claude:sonnet
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker | .backend == "headless" and .agent == "claude" and .model == "sonnet"' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier-set worker orca prints that orca is gone and binds subagent" {
    tier_set opus                      # a per-role bind needs a top bound first
    [ "$status" -eq 0 ]
    tier_set worker orca
    [ "$status" -eq 0 ]
    [[ "$output" == *'`orca` is gone: bound subagent'* ]]
    run jq -e '.roles.worker | .backend == "subagent" and .agent == "claude"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    run grep -c '"orca"' "$STATE_FILE"
    [ "$output" = "0" ]
}

@test "tier-set opus sonnet haiku prints worker=subagent:sonnet" {
    tier_set opus sonnet haiku
    [ "$status" -eq 0 ]
    [[ "$output" == *"worker=subagent:sonnet"* ]]
    run jq -e '.roles.worker.backend == "subagent" and .roles.recon.backend == "subagent"' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier-prime --short on the old orca file shows the migrated backends" {
    seed_orca_state
    prime --short
    [ "$status" -eq 0 ]
    # worker (orca+claude) -> subagent: bare model id; recon (orca+opencode) -> headless: backend-qualified
    [[ "$output" == "[tier] worker=sonnet recon=headless:opencode:openrouter/x/y"* ]]
    [[ "$output" != *orca* ]]
}
