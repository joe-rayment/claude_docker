#!/usr/bin/env bats
#
# Guards:   tier-gate under the HEADLESS worker backend: a claude-agent role
#           still injects its model (with the headless note naming
#           `dispatch <bead>`), a model-less spawn onto a non-Claude role is
#           denied naming `dispatch <bead>` / `recon "<question>"`, and an
#           explicit model on the Agent call stays the in-process fallback.
# Fails if: tier-gate stops reading backend "headless", the deny reasons name
#           an Orca command or Orca, or a claude-agent headless role is denied.
# Run:      bats tests/tier-gate-headless.bats
# NOT a frozen contract file -- tests/tier-hooks.bats is the frozen S4 one.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

DERIVE="$REPO_ROOT/scripts/tier-derive.sh"
TSET="$REPO_ROOT/scripts/tier-set.sh"
GATE="$REPO_ROOT/scripts/tier-gate.sh"

setup() {
    unset PROJECT_DIR BEADS_DIR
    export CLAUDE_ORCA_ROOT="$BATS_TEST_TMPDIR/root"
    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/root/.claude"
    mkdir -p "$CLAUDE_ORCA_ROOT/.claude-dev/run" "$CLAUDE_CONFIG_DIR/agents"
    STATE_FILE="$CLAUDE_ORCA_ROOT/.claude-dev/run/tier.json"
}

tier_set() { run "$TSET" "$@"; }
gate() { run "$GATE" <<<"$1"; }

@test "tier-gate: a headless claude worker still injects its own model, with the headless note" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set worker claude:opus
    [ "$status" -eq 0 ]

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    [ "$status" -eq 0 ]
    out="$output"
    run jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.systemMessage | test("backend is headless")' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.systemMessage | contains("`dispatch <bead>`") and (contains("orca") | not)' <<<"$out"
    [ "$status" -eq 0 ]
    # the original tool_input survives, exactly as on the subagent path
    run jq -e '.hookSpecificOutput.updatedInput.prompt == "p" and .hookSpecificOutput.hookEventName == "PreToolUse"' <<<"$out"
    [ "$status" -eq 0 ]
}

@test "tier-gate: a Claude role's effort rides the spawn as the Agent call's effort" {
    # Guards: /tier ... haiku@low reaches an in-process scout as effort:low,
    #   minimal reads as Claude's nearest step (low), and a call that
    #   already names an effort keeps its own.
    # Fails if: tier-gate stops injecting effort, or overrides an explicit one.
    # Run: bats -f "effort rides the spawn" tests/tier-gate-headless.bats
    TIER_DERIVE="$DERIVE" tier_set opus sonnet@minimal haiku@low
    [ "$status" -eq 0 ]
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p"}}'
    run jq -e '.hookSpecificOutput.updatedInput | .model == "haiku" and .effort == "low"' <<<"$output"
    [ "$status" -eq 0 ]
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    run jq -e '.hookSpecificOutput.updatedInput.effort == "low"' <<<"$output"
    [ "$status" -eq 0 ]
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p","effort":"high"}}'
    run jq -e '.hookSpecificOutput.updatedInput.effort == "high"' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "tier-gate: a headless claude worker whose model cannot be ranked falls back to the derived rung" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    # a claude-agent headless role bound to an off-ladder id: not injectable as
    # such, so the rung derived from the bound top (fable -> sonnet) is used
    jq '.roles.worker = {backend:"headless", agent:"claude", model:"my-custom-router", pinned:true} | .worker = "my-custom-router"' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "tier-gate: a headless claude recon role injects the recon rung for scout spawns" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set recon claude:haiku
    [ "$status" -eq 0 ]

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p"}}'
    [ "$status" -eq 0 ]
    out="$output"
    run jq -e '.hookSpecificOutput.updatedInput.model == "haiku"' <<<"$out"
    [ "$status" -eq 0 ]
    # a claude-agent headless role is never denied (claude-orca-424.2): the
    # model rides in updatedInput, no permissionDecision alongside it
    run jq -e '.hookSpecificOutput | has("permissionDecision") | not' <<<"$out"
    [ "$status" -eq 0 ]

    # the same with a concrete (not alias) claude id in the role: still
    # injects its own model, still never denies
    jq '.roles.recon.model = "claude-haiku-4-5-20251001" | .recon = "claude-haiku-4-5-20251001"' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p"}}'
    [ "$status" -eq 0 ]
    out="$output"
    run jq -e '.hookSpecificOutput.updatedInput.model == "haiku"' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput | has("permissionDecision") | not' <<<"$out"
    [ "$status" -eq 0 ]

    # an explicit model on the call still wins, headless backend or not
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","model":"opus","prompt":"p"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "tier-gate: a model-less executor spawn onto a non-Claude headless worker is denied, naming dispatch" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set worker openrouter:z-ai/glm-5.3-flash
    [ "$status" -eq 0 ]

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    [ "$status" -eq 0 ]
    out="$output"
    run jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.permissionDecisionReason | contains("`dispatch <bead>`") and (contains("orca") | not)' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.permissionDecisionReason | contains("explicit model")' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput | has("updatedInput") | not' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e 'has("systemMessage") | not' <<<"$out"
    [ "$status" -eq 0 ]
}

@test "tier-gate: a model-less scout spawn onto a non-Claude headless recon role is denied, naming recon" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set recon openrouter:openai/gpt-5.6-luna@high
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon | .backend == "headless" and .agent == "opencode" and .model == "openrouter/openai/gpt-5.6-luna" and .variant == "high"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p"}}'
    [ "$status" -eq 0 ]
    out="$output"
    run jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.permissionDecisionReason | contains("recon \"<question>\"")' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.permissionDecisionReason | contains("gpt-5.6-luna@high")' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.permissionDecisionReason | contains("model: haiku")' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput | has("updatedInput") | not' <<<"$out"
    [ "$status" -eq 0 ]
}

@test "tier-gate: the deny is not throttled -- both calls in one session carry the full reason" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set recon openrouter:openai/gpt-5.6-luna@high
    [ "$status" -eq 0 ]

    gate '{"session_id":"sess-deny","tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p"}}'
    [ "$status" -eq 0 ]
    first="$output"
    gate '{"session_id":"sess-deny","tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p"}}'
    [ "$status" -eq 0 ]
    second="$output"
    for out in "$first" "$second"; do
        run jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("gpt-5.6-luna@high"))' <<<"$out"
        [ "$status" -eq 0 ]
    done
}

@test "tier-gate: an explicit model on the scout spawn wins over the headless recon role" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set recon openrouter:openai/gpt-5.6-luna@high
    [ "$status" -eq 0 ]

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","model":"haiku","prompt":"p"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "tier-gate: an unnamed spawn onto a non-Claude headless worker is denied too" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set worker openrouter:z-ai/glm-5.3-flash
    [ "$status" -eq 0 ]

    gate '{"tool_name":"Agent","tool_input":{"prompt":"p"}}'
    [ "$status" -eq 0 ]
    out="$output"
    run jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.permissionDecisionReason | contains("`dispatch <bead>`")' <<<"$out"
    [ "$status" -eq 0 ]
}
