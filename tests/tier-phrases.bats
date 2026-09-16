#!/usr/bin/env bats
#
# claude-orca-2j2 (claude-orca-1w8 slice A) -- FROZEN from RED-AT onward.
# tier-set positional/per-role PHRASES: a comma- or whitespace-separated
# single argument re-split into the trio, short names resolved through
# config/delegate-routes.json routes and an OpenRouter model catalogue, and
# a per-role reasoning-effort variant (@high / (high) / a trailing bare
# word). See scripts/tier-set.sh's own header and scripts/lib/tier-roles.sh
# for the shared @variant plumbing this bead builds on (commit a46070f).
#
# No network, no real Orca: TIER_ORCA_PROBE_DISABLE=1 and TIER_MODELS_FETCH=0
# throughout -- the catalogue and routes fixtures below are the only sources
# of truth a resolution can come from.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

TSET="$REPO_ROOT/scripts/tier-set.sh"
PRIME="$REPO_ROOT/scripts/tier-prime.sh"
DERIVE="$REPO_ROOT/scripts/tier-derive.sh"

setup() {
    export TIER_STATE_FILE="$BATS_TEST_TMPDIR/tier.json"
    export TIER_SETTINGS_LOCAL="$BATS_TEST_TMPDIR/settings.local.json"
    export TIER_DERIVE="$DERIVE"
    export TIER_ORCA_PROBE_DISABLE=1
    export TIER_MODELS_FETCH=0
    unset OPENROUTER_API_KEY
    export TIER_OPENROUTER_KEY_FILE="$BATS_TEST_TMPDIR/no-such-openrouter.key"

    ROUTES_FILE="$BATS_TEST_TMPDIR/delegate-routes.json"
    cat > "$ROUTES_FILE" <<'JSON'
{
  "routes": {
    "glm-flash": {"runner": "opencode", "model": "openrouter/z-ai/glm-5.3-flash", "grade": "scout"},
    "luna": {"runner": "opencode", "model": "openrouter/openai/gpt-5.6-luna", "grade": "executor"}
  }
}
JSON
    export TIER_ROUTES_FILE="$ROUTES_FILE"

    MODELS_FILE="$BATS_TEST_TMPDIR/openrouter-models.json"
    cat > "$MODELS_FILE" <<'JSON'
{
  "data": [
    {"id": "z-ai/glm-5.3-flash", "name": "GLM 5.3 Flash", "pricing": {"prompt": "0.0000002", "completion": "0.0000006"}},
    {"id": "z-ai/glm-5.3-flash:batch", "name": "GLM 5.3 Flash (Batch)", "pricing": {"prompt": "0.0000001", "completion": "0.0000003"}},
    {"id": "z-ai/glm-5.3", "name": "GLM 5.3", "pricing": {"prompt": "0.0000004", "completion": "0.0000012"}},
    {"id": "openai/gpt-5.6-luna", "name": "GPT-5.6 Luna", "pricing": {"prompt": "0.000003", "completion": "0.000012"}},
    {"id": "openai/gpt-5.6-luna-pro", "name": "GPT-5.6 Luna Pro", "pricing": {"prompt": "0.000008", "completion": "0.00003"}},
    {"id": "openai/gpt-luna-latest", "name": "GPT Luna Latest", "pricing": {"prompt": "0.000005", "completion": "0.00002"}},
    {"id": "sao10k/l3-lunaris-8b", "name": "L3 Lunaris 8B", "pricing": {"prompt": "0.0000002", "completion": "0.0000002"}}
  ]
}
JSON
    export TIER_MODELS_FILE="$MODELS_FILE"
}

tier_set() { run "$TSET" "$@"; }
prime_short() { run "$PRIME" --short; }

# ── (1) single quoted arg, whitespace-split ─────────────────────────────────

@test "single quoted whitespace arg re-splits into the trio, short names resolve through routes" {
    tier_set "fable glm-flash luna@high"
    [ "$status" -eq 0 ]

    run jq -e '.top == "fable" and .pinned == true' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker == {backend:"orca", agent:"opencode", model:"openrouter/z-ai/glm-5.3-flash", pinned:true}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon == {backend:"orca", agent:"opencode", model:"openrouter/openai/gpt-5.6-luna", pinned:true, variant:"high"}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (2) comma-separated single arg, phrases carry spaces and a paren effort ─

@test "comma-separated single arg re-splits into the trio, identical to the whitespace form" {
    tier_set "fable, GLM 5.3 flash, GPT-5.6 Luna (high)"
    [ "$status" -eq 0 ]

    run jq -e '.top == "fable" and .pinned == true' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker == {backend:"orca", agent:"opencode", model:"openrouter/z-ai/glm-5.3-flash", pinned:true}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon == {backend:"orca", agent:"opencode", model:"openrouter/openai/gpt-5.6-luna", pinned:true, variant:"high"}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (3) explicit vendor/model ids, no route or catalogue involved ──────────

@test "explicit vendor/model phrases bind identically with no route or catalogue lookup" {
    tier_set "fable z-ai/glm-5.3-flash openai/gpt-5.6-luna@high"
    [ "$status" -eq 0 ]

    run jq -e '.top == "fable"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker == {backend:"orca", agent:"opencode", model:"openrouter/z-ai/glm-5.3-flash", pinned:true}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon == {backend:"orca", agent:"opencode", model:"openrouter/openai/gpt-5.6-luna", pinned:true, variant:"high"}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (4) a Claude worker alongside a routed recon, no effort ────────────────

@test "a Claude worker binds as today, recon resolves through the route with no variant" {
    tier_set fable sonnet luna
    [ "$status" -eq 0 ]

    run jq -e '.roles.worker == {backend:"subagent", agent:"claude", model:"sonnet", pinned:true}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon == {backend:"orca", agent:"opencode", model:"openrouter/openai/gpt-5.6-luna", pinned:true}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon | has("variant") | not' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (5) an ambiguous catalogue query changes nothing ────────────────────────

@test "an ambiguous catalogue query with no common id prefix prints candidates, exits 1, binds nothing" {
    tier_set fable sonnet haiku
    [ "$status" -eq 0 ]
    before="$(cat "$TIER_STATE_FILE")"

    tier_set "fable, glm-flash, gpt luna"
    [ "$status" -eq 1 ]
    lines_count=$(printf '%s\n' "$output" | grep -c '/')
    [ "$lines_count" -ge 2 ]

    after="$(cat "$TIER_STATE_FILE")"
    [ "$before" = "$after" ]
}

# ── (6) help / -h / --help bind nothing ─────────────────────────────────────

@test "help, -h and --help print the explanation and bind nothing" {
    for flag in help -h --help; do
        rm -f "$TIER_STATE_FILE"
        tier_set "$flag"
        [ "$status" -eq 0 ]
        [ -n "$output" ]
        [ ! -f "$TIER_STATE_FILE" ]
    done
}

# ── (7) per-role form, 3rd token is a bare effort word ──────────────────────

@test "per-role form: a 3rd bare-word token is the effort, the other role is untouched" {
    tier_set fable sonnet haiku
    [ "$status" -eq 0 ]

    tier_set recon luna high
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon == {backend:"orca", agent:"opencode", model:"openrouter/openai/gpt-5.6-luna", pinned:true, variant:"high"}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker.model == "sonnet"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (8) an invalid effort word after @ errors, nothing bound ───────────────

@test "an unknown effort word after @ is an error and binds nothing" {
    tier_set fable
    [ "$status" -eq 0 ]
    before="$(cat "$TIER_STATE_FILE")"

    tier_set worker glm-flash@bogus
    [ "$status" -eq 1 ]

    after="$(cat "$TIER_STATE_FILE")"
    [ "$before" = "$after" ]
}

# ── (9) an effort on a Claude role is ignored, with a note ─────────────────

@test "an effort attached to a Claude worker is ignored, with a note, and the model still binds" {
    tier_set fable sonnet@high haiku
    [ "$status" -eq 0 ]
    [[ "$output" == *"applies to OpenRouter roles only"* ]]

    run jq -e '.roles.worker == {backend:"subagent", agent:"claude", model:"sonnet", pinned:true}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker | has("variant") | not' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (10) tier-set models <words> ────────────────────────────────────────────

@test "tier-set models <words> lists catalogue candidates and exits 0" {
    tier_set models luna
    [ "$status" -eq 0 ]
    [[ "$output" == *"openai/gpt-5.6-luna"* ]]
    [[ "$output" == *"openai/gpt-5.6-luna-pro"* ]]
}

# ── (11) no catalogue available: the slash form still binds, the bare word doesn't ─

@test "with no catalogue file and fetch disabled, a bare catalogue word fails but an explicit id still binds" {
    unset TIER_MODELS_FILE
    export TIER_MODELS_FILE="$BATS_TEST_TMPDIR/no-such-catalogue.json"

    tier_set fable glm-flash gpt-5.6-luna
    [ "$status" -eq 1 ]
    [[ "$output" == *"catalogue"* ]]
    [ ! -f "$TIER_STATE_FILE" ]

    tier_set fable glm-flash openai/gpt-5.6-luna@high
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon == {backend:"orca", agent:"opencode", model:"openrouter/openai/gpt-5.6-luna", pinned:true, variant:"high"}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (12) tier-prime --short shows the variant ───────────────────────────────

@test "tier-prime --short shows the recon variant after a phrase binding" {
    tier_set "fable glm-flash luna@high"
    [ "$status" -eq 0 ]

    TIER_PRIME_STATE_FILE="$TIER_STATE_FILE" TIER_PRIME_PRIMED_FILE="$BATS_TEST_TMPDIR/tier-primed.txt" \
        run "$PRIME" --short
    [ "$status" -eq 0 ]
    [[ "$output" == *"@high"* ]]
}
