#!/usr/bin/env bats
#
# claude-orca-c3p.3 -- FROZEN from RED-AT onward.
# /tier binds a role to the user's OpenAI (ChatGPT) subscription: a bare
# `openai` (the role's default) and `openai:<family|id>` (a family alias
# follows its newest release, an exact id pins one model), both backend
# orca + agent opencode with the model spelled openai/... -- visibly
# distinct from the same OpenAI model through OpenRouter, whose bare
# names, vendor/model ids and catalogue phrases keep today's meaning. An
# effort rides on the spec like everywhere else; a signed-out folder
# still saves the binding and names /tier auth openai.
#
# Fast and hermetic: no network, no real opencode -- TIER_MODELS_FETCH=0,
# TIER_ORCA_PROBE_DISABLE=1; the OpenAI catalogue and auth store are
# fixtures and the OpenRouter catalogue is absent.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

TSET="$REPO_ROOT/scripts/tier-set.sh"
DERIVE="$REPO_ROOT/scripts/tier-derive.sh"

setup() {
    export TIER_STATE_FILE="$BATS_TEST_TMPDIR/tier.json"
    export TIER_SETTINGS_LOCAL="$BATS_TEST_TMPDIR/settings.local.json"
    export TIER_DERIVE="$DERIVE"
    export TIER_ORCA_PROBE_DISABLE=1
    export TIER_MODELS_FETCH=0
    unset OPENROUTER_API_KEY
    export TIER_OPENROUTER_KEY_FILE="$BATS_TEST_TMPDIR/no-such-openrouter.key"

    export TIER_ROUTES_FILE="$REPO_ROOT/config/delegate-routes.json"

    export TIER_OPENAI_MODELS_FILE="$BATS_TEST_TMPDIR/openai-models.json"
    cat > "$TIER_OPENAI_MODELS_FILE" <<'JSON'
[
  {"id": "gpt-5.6-luna", "family": "gpt-luna", "release_date": "2026-07-09"},
  {"id": "gpt-5.6-luna-fast", "family": "gpt-luna", "release_date": "2026-07-09"},
  {"id": "gpt-5.6-terra", "family": "gpt-terra", "release_date": "2026-07-09"},
  {"id": "gpt-5.6-sol", "family": "gpt-sol", "release_date": "2026-07-09"},
  {"id": "gpt-6.1-sol", "family": "gpt-sol", "release_date": "2026-09-29"},
  {"id": "gpt-5.4-mini", "family": "gpt-mini", "release_date": "2026-03-17"}
]
JSON

    # signed in by default: an oauth login with a refresh token
    export TIER_OPENAI_AUTH_FILE="$BATS_TEST_TMPDIR/opencode-auth.json"
    cat > "$TIER_OPENAI_AUTH_FILE" <<'JSON'
{"openai":{"type":"oauth","refresh":"rt-x","access":"a","expires":1,"accountId":"acct"}}
JSON
}

signed_out() {
    export TIER_OPENAI_AUTH_FILE="$BATS_TEST_TMPDIR/no-such-auth.json"
}

tier_set() { run "$TSET" "$@"; }

# ── (1) family specs bind the subscription's newest release, effort rides ───

@test "openai: family specs bind orca:opencode:openai/~<family>-latest per role, with the effort" {
    # Guards: openai:terra / openai:luna resolve through the catalogue's
    #   family column, so a new release needs no re-bind; an @high effort on
    #   recon is stored as the role's variant like on any opencode binding.
    # Fails if: the openai: prefix bound OpenRouter's copy, the family
    #   resolved to a pinned id, or the effort was dropped or errored.
    # Run: bats tests/tier-openai.bats
    tier_set opus openai:terra openai:luna@high
    [ "$status" -eq 0 ]

    run jq -e '.roles.worker == {backend:"orca", agent:"opencode", model:"openai/~gpt-terra-latest", pinned:true}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon == {backend:"orca", agent:"opencode", model:"openai/~gpt-luna-latest", pinned:true, variant:"high"}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"orca:opencode:openai/~gpt-luna-latest@high"* ]]
}

# ── (2) the distinction from OpenRouter holds ───────────────────────────────

@test "a bare route name and a bare vendor/model id stay OpenRouter, openai: is the subscription" {
    # Guards: everything that existed before openai: keeps its meaning --
    #   `luna` is still the delegate route (OpenRouter's ~-latest alias) and
    #   `openai/gpt-5.6-luna` (no colon) is still the OpenRouter model.
    # Fails if: an openai/ spelling leaked into a bare-name lookup, or a
    #   bare name was reinterpreted as the ChatGPT subscription.
    # Run: bats -f 'stay OpenRouter' tests/tier-openai.bats
    tier_set opus luna luna@high
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon.model == "openrouter/~openai/gpt-luna-latest"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]

    tier_set opus openai/gpt-5.6-luna
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker.model == "openrouter/openai/gpt-5.6-luna"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (3) an exact id pins one model; spaces normalise; the comma form works ──

@test "an openai: id pins one model, spaces normalise to the id, and the comma form carries the effort" {
    # Guards: openai:gpt-5.6-luna pins exactly that id (no ~-latest alias),
    #   "GPT 5.6 Luna" lower-cases and dashes to the same id, and the
    #   comma-split trio form resolves each OpenAI phrase with its effort.
    # Fails if: an id grew an alias suffix, whitespace broke the id, or the
    #   parenthesised effort was taken as part of the model name.
    # Run: bats -f 'pins one model' tests/tier-openai.bats
    tier_set worker openai:gpt-5.6-luna
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker == {backend:"orca", agent:"opencode", model:"openai/gpt-5.6-luna", pinned:true}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]

    tier_set "opus, openai:GPT 5.6 Luna, openai:luna (high)"
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker.model == "openai/gpt-5.6-luna"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon == {backend:"orca", agent:"opencode", model:"openai/~gpt-luna-latest", pinned:true, variant:"high"}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (4) an unknown family or id binds nothing ───────────────────────────────

@test "an unknown OpenAI family or id exits 1, lists the families, and binds nothing" {
    # Guards: a typo in an openai: spec is an error naming the families the
    #   subscription serves, never a silent free-text bind; tier.json is
    #   byte-identical afterwards.
    # Fails if: openai:nope bound anything (or an openrouter/ model), or the
    #   error did not name the available families.
    # Run: bats -f 'unknown OpenAI family' tests/tier-openai.bats
    tier_set worker openai
    [ "$status" -eq 0 ]
    before="$(cat "$TIER_STATE_FILE")"

    tier_set worker openai:nope
    [ "$status" -eq 1 ]
    [[ "$output" == *"luna"* ]]
    [[ "$output" == *"terra"* ]]
    after="$(cat "$TIER_STATE_FILE")"
    [ "$before" = "$after" ]
}

# ── (5) a bare openai binds the role's default ──────────────────────────────

@test "a bare openai binds the role's default subscription model: recon luna, worker terra" {
    # Guards: `openai` with no colon is the role default form -- recon
    #   recons on the newest GPT Luna, the worker executes on the newest
    #   GPT Terra -- both orca + opencode.
    # Fails if: both roles took the same default, or the bare word bound a
    #   Claude model or the OpenRouter GLM.
    # Run: bats -f "role's default subscription" tests/tier-openai.bats
    tier_set recon openai
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon.model == "openai/~gpt-luna-latest"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]

    tier_set worker openai
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker.model == "openai/~gpt-terra-latest"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (6) signed out: saved, with the sign-in pointer ─────────────────────────

@test "an openai/ bind while signed out saves and names /tier auth openai; signed in says nothing" {
    # Guards: a signed-out folder still records the binding (it runs once
    #   signed in) and prints the /tier auth openai pointer exactly on the
    #   openai/ path; a signed-in bind prints no sign-in pointer.
    # Fails if: the bind failed while signed out, or the OpenRouter
    #   not-authenticated note replaced the OpenAI one.
    # Run: bats -f 'signed out saves and names' tests/tier-openai.bats
    signed_out
    tier_set worker openai:luna
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker.model == "openai/~gpt-luna-latest"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/tier auth openai"* ]]

    tier_set worker openai:sol
    [ "$status" -eq 0 ]
    [[ "$output" != *"/tier auth openai"* ]]
}

# ── (7) the positional trio prints the pair exactly once ────────────────────

@test "the positional trio prints the OpenAI sign-in pair exactly once when signed out" {
    # Guards: the trio form, which prints no auth note for OpenRouter,
    #   prints the OpenAI pair once even when BOTH worker and recon are
    #   openai/ and signed out -- never twice, never per role.
    # Fails if: the pair printed zero or two times, or the trio errored.
    # Run: bats -f 'pair exactly once' tests/tier-openai.bats
    signed_out
    tier_set fable openai:terra openai:luna@high
    [ "$status" -eq 0 ]
    [ "$(grep -c 'not signed in to OpenAI' <<<"$output")" -eq 1 ]
    [ "$(grep -c '/tier auth openai' <<<"$output")" -eq 1 ]
}

# ── (8) the checker rung takes the same specs ───────────────────────────────

@test "the checker takes openai: specs: family alias on orca:opencode, pinned" {
    # Guards: the checker role resolves openai: family specs the same way
    #   worker/recon do and pins the binding.
    # Fails if: the checker fell through to the Claude default or lost its
    #   opencode agent or orca backend.
    # Run: bats -f 'checker takes openai' tests/tier-openai.bats
    tier_set checker openai:sol
    [ "$status" -eq 0 ]
    run jq -e '.roles.checker == {backend:"orca", agent:"opencode", model:"openai/~gpt-sol-latest", pinned:true}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (9) models openai: families and pins ────────────────────────────────────

@test "models openai lists each family with its newest release, and word-filters the pin list" {
    # Guards: /tier models openai shows one line per family (openai:<family>
    #   resolving to that family's newest release -- sol's is gpt-6.1-sol)
    #   and `models openai <words>` filters the pin list to matching ids.
    # Fails if: a family line resolved to an older or -fast twin release, or
    #   the word filter listed non-matching ids.
    # Run: bats -f 'word-filters the pin list' tests/tier-openai.bats
    tier_set models openai
    [ "$status" -eq 0 ]
    [[ "$output" == *"openai:luna"* ]]
    [[ "$output" == *"gpt-5.6-luna"* ]]
    sol_line="$(grep 'openai:sol' <<<"$output" | head -1)"
    [[ "$sol_line" == *"gpt-6.1-sol"* ]]

    tier_set models openai mini
    [ "$status" -eq 0 ]
    [[ "$output" == *"openai:gpt-5.4-mini"* ]]
    [[ "$output" != *"openai:gpt-5.6-luna"* ]]
}

# ── (10) the ignored-effort note names both opencode providers ──────────────

@test "the ignored-effort note on a Claude role says OpenRouter or OpenAI" {
    # Guards: the effort-ignored note now reads "applies to opencode roles
    #   only (OpenRouter or OpenAI)" -- effort never errors on a Claude role.
    # Fails if: the note still said OpenRouter only, or the effort errored.
    # Run: bats -f 'OpenRouter or OpenAI' tests/tier-openai.bats
    tier_set fable sonnet@high haiku
    [ "$status" -eq 0 ]
    [[ "$output" == *"applies to opencode roles only (OpenRouter or OpenAI)"* ]]
    [[ "$output" == *"OpenAI"* ]]
}

# ── (11) no catalogue at all: still binds, unchecked ────────────────────────

@test "with no OpenAI catalogue at all, a family spec still binds, unchecked" {
    # Guards: an empty catalogue (no fixture, signed out, no opencode
    #   cache) degrades to binding the ~-latest alias unchecked, with a
    #   note -- never a hard error.
    # Fails if: the bind failed, or an unchecked family bound a pinned id.
    # Run: bats -f 'binds, unchecked' tests/tier-openai.bats
    printf '[]\n' > "$TIER_OPENAI_MODELS_FILE"
    signed_out
    export TIER_OPENCODE_MODELS_CACHE="$BATS_TEST_TMPDIR/no-such-cache.json"

    tier_set worker openai:luna
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker.model == "openai/~gpt-luna-latest"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bound unchecked"* ]]
}
