#!/usr/bin/env bats
#
# tier-gate under the ORCA worker backend (claude-orca-qa2.12, GREEN-2).
# NOT a frozen contract file -- tests/tier-hooks.bats is the frozen S4 one.
# The orca-backend rule as of claude-orca-424.2: a model-less spawn onto an
# orca-backed non-Claude role is DENIED, the reason naming the exact command
# the tier wants (`recon "<question>"` for recon, `orca-dispatch <bead>` for
# worker); an explicit model on the Agent call stays the deliberate
# in-process fallback, and a claude-agent orca role still injects.

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

@test "tier-gate: an orca+claude worker still injects its own model, with the orca note" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set worker claude:opus
    [ "$status" -eq 0 ]

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    [ "$status" -eq 0 ]
    out="$output"
    run jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.systemMessage | test("orca")' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.systemMessage | test("orca-dispatch")' <<<"$out"
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
    # Run: bats -f "effort rides the spawn" tests/tier-gate-orca.bats
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

@test "tier-gate: an orca+claude worker whose model cannot be ranked falls back to the derived rung" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    # a claude-agent orca role bound to an off-ladder id: not injectable as
    # such, so the rung derived from the bound top (fable -> sonnet) is used
    jq '.roles.worker = {backend:"orca", agent:"claude", model:"my-custom-router", pinned:true} | .worker = "my-custom-router"' \
        "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "tier-gate: an orca+claude recon role injects the recon rung for scout spawns" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set recon claude:haiku
    [ "$status" -eq 0 ]

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p"}}'
    [ "$status" -eq 0 ]
    out="$output"
    run jq -e '.hookSpecificOutput.updatedInput.model == "haiku"' <<<"$out"
    [ "$status" -eq 0 ]
    # a claude-agent orca role is never denied (claude-orca-424.2): the
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

    # an explicit model on the call still wins, orca backend or not
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","model":"opus","prompt":"p"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# The probe is what decides orca-vs-subagent at bind time, so it has to read
# the shape the CLI actually prints. Orca 1.4.197 wraps every answer in
# {"id","ok","result"} -- reading the flat .runtime.reachable made the probe
# answer "unreachable" against a runtime that was up (found by qa2.13/qa2.19).
probe_stub() {
    local json="$1" stub="$BATS_TEST_TMPDIR/orca-stub"
    printf '#!/usr/bin/env bash\ncat <<%s\n%s\n%s\n' "'JSON'" "$json" "JSON" \
        >"$stub"
    chmod +x "$stub"
    printf '%s' "$stub"
}

@test "tier_orca_reachable reads the wrapped status envelope the Orca CLI really prints" {
    # shellcheck disable=SC1091
    . "$REPO_ROOT/scripts/lib/tier-roles.sh"

    up='{"id":"local-status","ok":true,"result":{"target":{"kind":"local"},"app":{"running":true,"pid":123},"runtime":{"state":"ready","reachable":true,"runtimeId":"ab0c4f52"}},"_meta":{"runtimeId":"ab0c4f52"}}'
    TIER_ORCA_PROBE_CMD="$(probe_stub "$up")" run tier_orca_reachable
    [ "$status" -eq 0 ]

    down='{"id":"local-status","ok":true,"result":{"target":{"kind":"local"},"app":{"running":false,"pid":null},"runtime":{"state":"not_running","reachable":false,"runtimeId":null}},"_meta":{"runtimeId":"none"}}'
    TIER_ORCA_PROBE_CMD="$(probe_stub "$down")" run tier_orca_reachable
    [ "$status" -ne 0 ]

    # an older CLI printing the payload flat still counts as reachable
    flat='{"runtime":{"state":"ready","reachable":true}}'
    TIER_ORCA_PROBE_CMD="$(probe_stub "$flat")" run tier_orca_reachable
    [ "$status" -eq 0 ]

    TIER_ORCA_PROBE_DISABLE=1 TIER_ORCA_PROBE_CMD="$(probe_stub "$up")" \
        run tier_orca_reachable
    [ "$status" -ne 0 ]
}

@test "tier-gate: a model-less executor spawn onto a non-Claude orca worker is denied, naming orca-dispatch" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set worker openrouter:z-ai/glm-5.3-flash
    [ "$status" -eq 0 ]

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    [ "$status" -eq 0 ]
    out="$output"
    run jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.permissionDecisionReason | contains("orca-dispatch")' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.permissionDecisionReason | contains("explicit model")' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput | has("updatedInput") | not' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e 'has("systemMessage") | not' <<<"$out"
    [ "$status" -eq 0 ]
}

@test "tier-gate: a model-less scout spawn onto a non-Claude orca recon role is denied, naming recon" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set recon openrouter:openai/gpt-5.6-luna@high
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon | .backend == "orca" and .agent == "opencode" and .model == "openrouter/openai/gpt-5.6-luna" and .variant == "high"' "$STATE_FILE"
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

@test "tier-gate: an explicit model on the scout spawn wins over the orca recon role" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set recon openrouter:openai/gpt-5.6-luna@high
    [ "$status" -eq 0 ]

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","model":"haiku","prompt":"p"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "tier-gate: an unnamed spawn onto a non-Claude orca worker is denied too" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set worker openrouter:z-ai/glm-5.3-flash
    [ "$status" -eq 0 ]

    gate '{"tool_name":"Agent","tool_input":{"prompt":"p"}}'
    [ "$status" -eq 0 ]
    out="$output"
    run jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.permissionDecisionReason | contains("orca-dispatch")' <<<"$out"
    [ "$status" -eq 0 ]
}
