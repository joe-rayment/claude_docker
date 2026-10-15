#!/usr/bin/env bats
#
# claude-orca-af0 -- tier presets: ONE NAME for an existing /tier argument
# form. `tier-set <name>` re-runs tier-set with the preset's own args (the
# unchanged binding path does the binding) and stamps .preset into tier.json
# when that exits 0; any later non-preset bind drops .preset again because
# write_state/write_state_v3 rebuild the file whole. A bare /tier lists the
# presets after the state lines and -- only when stdout is NOT a terminal,
# which is how the slash command and these tests both run it -- ends with a
# [tier-picker] block the command file turns into one AskUserQuestion.
# /tier show lists them too but never prints the picker.
#
# Fixture modelled on tests/tier-phrases.bats (FROZEN): throwaway state and
# settings files, ambient PROJECT_DIR / CLAUDE_ORCA_ROOT / BEADS_DIR unset,
# no network, no real Orca, and NEVER the live
# /workspace/claude-orca/.claude-dev/run/tier.json.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

TSET="$REPO_ROOT/scripts/tier-set.sh"
DERIVE="$REPO_ROOT/scripts/tier-derive.sh"
SHIPPED_PRESETS="$REPO_ROOT/config/tier-presets.json"
SHIPPED_ROUTES="$REPO_ROOT/config/delegate-routes.json"
CMD_FILE="$REPO_ROOT/config/claude-commands/tier.md"

setup() {
    export TIER_STATE_FILE="$BATS_TEST_TMPDIR/tier.json"
    export TIER_SETTINGS_LOCAL="$BATS_TEST_TMPDIR/settings.local.json"
    export TIER_DERIVE="$DERIVE"
    export TIER_MODELS_FETCH=0
    unset OPENROUTER_API_KEY
    export TIER_OPENROUTER_KEY_FILE="$BATS_TEST_TMPDIR/no-such-openrouter.key"
    unset PROJECT_DIR CLAUDE_ORCA_ROOT BEADS_DIR

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

    PRESETS_FILE="$BATS_TEST_TMPDIR/tier-presets.json"
    cat > "$PRESETS_FILE" <<'JSON'
{
  "presets": [
    {"name": "hybrid",     "summary": "Fable orchestrates, GLM 5.3 flash works, GPT-5.6 Luna (high) scouts", "args": ["fable", "glm-flash", "luna@high"]},
    {"name": "hybrid-glm", "summary": "as hybrid, with full-size GLM 5.3 workers for slices flash flounders on", "args": ["fable", "glm", "luna@high"]},
    {"name": "all-claude", "summary": "no OpenRouter: Fable, with the Claude worker and recon it derives", "args": ["fable"]}
  ]
}
JSON
    export TIER_PRESETS_FILE="$PRESETS_FILE"

    export TIER_MODELS_FILE="$BATS_TEST_TMPDIR/no-such-catalogue.json"
}

tier_set() { run "$TSET" "$@"; }

# ── (1) the preset binds exactly what its args bind ─────────────────────────

@test "tier hybrid binds exactly what tier fable glm-flash luna@high binds" {
    tier_set fable glm-flash luna@high
    [ "$status" -eq 0 ]
    cp "$TIER_STATE_FILE" "$BATS_TEST_TMPDIR/explicit.json"

    rm -f "$TIER_STATE_FILE"
    tier_set hybrid
    [ "$status" -eq 0 ]

    [[ "$output" == "preset hybrid -- "* ]]
    [[ "$output" == *"tier bound (explicit, pinned)  top=fable"* ]]
    run jq -e '.preset == "hybrid"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]

    run bash -c 'diff <(jq -S "del(.updated, .preset)" "$1") <(jq -S "del(.updated)" "$2")' \
        _ "$TIER_STATE_FILE" "$BATS_TEST_TMPDIR/explicit.json"
    [ "$status" -eq 0 ]
}

# ── (2) any later non-preset bind drops .preset ─────────────────────────────

@test "any other bind drops the preset" {
    tier_set hybrid
    [ "$status" -eq 0 ]
    run jq -e '.preset == "hybrid"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]

    tier_set opus
    [ "$status" -eq 0 ]
    run jq -e 'has("preset") | not' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.top == "opus"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (3) a one-word preset binds the derived ladder ──────────────────────────

@test "a one-word preset binds the derived ladder" {
    tier_set all-claude
    [ "$status" -eq 0 ]

    run jq -e '.top == "fable" and .worker == "sonnet" and .recon == "haiku"
               and .pinned == false and .preset == "all-claude"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker == {backend:"subagent", agent:"claude", model:"sonnet"}' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (4) bare /tier: presets section, current mark, picker block ─────────────

@test "bare tier lists every preset, marks the current one, and ends with the picker block" {
    tier_set hybrid
    [ "$status" -eq 0 ]

    run "$TSET"
    [ "$status" -eq 0 ]
    [[ "$output" == *"presets -- /tier <name>:"* ]]
    [[ "$output" == *"  * hybrid       "* ]]
    [ "$(printf '%s\n' "$output" | grep -c '(current)')" -eq 1 ]
    printf '%s\n' "$output" | grep '(current)' | grep -Eq '^[[:space:]]*\*[[:space:]]+hybrid'

    block="$(printf '%s\n' "$output" | sed -n '/^\[tier-picker\]$/,$p')"
    [ -n "$block" ]
    printf '%s\n' "$block" | grep -q '^current: hybrid$'
    first_opt="$(printf '%s\n' "$block" | grep '^option: ' | sed -n 1p)"
    [[ "$first_opt" == "option: hybrid -- "* ]]
    opt_count="$(printf '%s\n' "$block" | grep -c '^option: ')"
    [ "$opt_count" -eq 3 ]
    [ "$opt_count" -le 4 ]
    [ "$(printf '%s\n' "$output" | tail -n 1)" = "[/tier-picker]" ]

    # no .preset in the state: current is none and nothing is marked
    rm -f "$TIER_STATE_FILE"
    tier_set opus
    [ "$status" -eq 0 ]
    run "$TSET"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q '^current: none$'
    [[ "$output" != *"(current)"* ]]
}

# ── (5) /tier show lists presets, never the picker ──────────────────────────

@test "tier show lists the presets but prints no picker block" {
    tier_set hybrid
    [ "$status" -eq 0 ]

    run "$TSET" show
    [ "$status" -eq 0 ]
    [[ "$output" == *"presets -- /tier <name>:"* ]]
    [[ "$output" == *"  * hybrid       "* ]]
    [[ "$output" != *"[tier-picker]"* ]]
}

# ── (6) reserved words always win over a preset of the same name ────────────

@test "reserved words win: a preset named opus or glm-flash binds as today, no .preset" {
    cat > "$BATS_TEST_TMPDIR/reserved-presets.json" <<'JSON'
{
  "presets": [
    {"name": "opus",      "summary": "a sneaky preset named after a Claude alias", "args": ["haiku"]},
    {"name": "glm-flash", "summary": "a sneaky preset named after a route",        "args": ["haiku"]}
  ]
}
JSON

    TIER_PRESETS_FILE="$BATS_TEST_TMPDIR/reserved-presets.json" tier_set opus
    [ "$status" -eq 0 ]
    [[ "$output" != "preset "* ]]
    run jq -e '.top == "opus" and .worker == "sonnet" and .recon == "haiku"' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e 'has("preset") | not' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]

    rm -f "$TIER_STATE_FILE"
    TIER_PRESETS_FILE="$BATS_TEST_TMPDIR/reserved-presets.json" tier_set glm-flash
    [ "$status" -eq 0 ]
    [[ "$output" != "preset "* ]]
    run jq -e '.top == "glm-flash" and (.roles.recon.model == "glm-flash")' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e 'has("preset") | not' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (7) the shipped presets file is sound data ──────────────────────────────

@test "the shipped presets file is sound" {
    [ -f "$SHIPPED_PRESETS" ]
    preset_count="$(jq '.presets | length' "$SHIPPED_PRESETS")"
    [ "$preset_count" -ge 1 ] && [ "$preset_count" -le 4 ]

    # names: lowercase lead, [a-z0-9-] tail; unique; none reserved; none a route
    bad="$(jq -r '.presets[].name' "$SHIPPED_PRESETS" | grep -vE '^[a-z][a-z0-9-]*$')" || bad=""
    [ -z "$bad" ]
    bad="$(jq -r '.presets[].name' "$SHIPPED_PRESETS" | sort | uniq -d)"
    [ -z "$bad" ]
    bad="$(jq -r '.presets[].name' "$SHIPPED_PRESETS" \
        | grep -xE 'show|help|overdrive|auth|models|checker|worker|recon|fable|opus|sonnet|haiku')" || bad=""
    [ -z "$bad" ]
    routes="$(jq -r '.routes // {} | keys | .[]' "$SHIPPED_ROUTES" 2>/dev/null)"
    [ -n "$routes" ]
    overlap="$(comm -12 <(jq -r '.presets[].name' "$SHIPPED_PRESETS" | sort) <(printf '%s\n' "$routes" | sort))"
    [ -z "$overlap" ]

    # every args an array of 1-3 non-empty strings; every summary non-empty
    bad="$(jq -r '.presets[] | select((.args | type) != "array"
                or ((.args | length) < 1) or ((.args | length) > 3)
                or ([.args[] | (type == "string" and length > 0)] | any | not)) | .name' \
        "$SHIPPED_PRESETS")"
    [ -z "$bad" ]
    bad="$(jq -r '.presets[] | select((.summary | type) != "string" or (.summary | length) == 0) | .name' \
        "$SHIPPED_PRESETS")"
    [ -z "$bad" ]
}

# ── (8) a missing presets file changes nothing ──────────────────────────────

@test "a missing presets file changes nothing" {
    export TIER_PRESETS_FILE="$BATS_TEST_TMPDIR/no-such-presets.json"

    run "$TSET"
    [ "$status" -eq 0 ]
    [[ "$output" != *"presets --"* ]]
    [[ "$output" != *"[tier-picker]"* ]]

    # an unknown single word binds today's off-ladder fallback, unchanged:
    # exit 0, top=worker=recon=<word>, pinned false, no .preset, the
    # off-ladder note on stderr (captured on the pre-change script).
    rm -f "$TIER_STATE_FILE"
    tier_set hybrid
    [ "$status" -eq 0 ]
    [[ "$output" == *"tier bound  top=hybrid  →  worker=hybrid  recon=hybrid"* ]]
    [[ "$output" == *"top 'hybrid' is off-ladder — worker/recon set to the same model"* ]]
    run jq -e '.top == "hybrid" and .worker == "hybrid" and .recon == "hybrid"
               and .pinned == false and (has("preset") | not)' "$TIER_STATE_FILE"
    [ "$status" -eq 0 ]
}

# ── (9) the command file wires the picker ───────────────────────────────────

@test "the command file wires the picker" {
    [ -f "$CMD_FILE" ]
    grep -q 'Bash(tier-set:\*)' "$CMD_FILE"
    grep -q 'AskUserQuestion' "$CMD_FILE"
    first_body="$(awk '/^---$/{seen++; next} seen >= 2 && NF {print; exit}' "$CMD_FILE")"
    [ "$first_body" = '!`tier-set "$ARGUMENTS"`' ]
    grep -q '\[tier-picker\]' "$CMD_FILE"
    grep -q 'Which tier preset?' "$CMD_FILE"
    grep -q '^model: haiku$' "$CMD_FILE"
    grep -q '^description:.*preset' "$CMD_FILE"
    grep -q '^argument-hint: "hybrid' "$CMD_FILE"
}
