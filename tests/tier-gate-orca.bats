#!/usr/bin/env bats
#
# tier-gate under the ORCA worker backend (claude-orca-qa2.12, GREEN-2).
# NOT a frozen contract file -- tests/tier-hooks.bats is the frozen one, and
# it pins the non-Claude (opencode/openrouter) orca case to "note only, no
# injection". This file covers the rest of the rule: an Agent spawn is the
# subagent FALLBACK for an orca-backed role, so it must still land on a
# worker-tier model rather than inheriting the orchestrator's expensive one.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

DERIVE="$REPO_ROOT/scripts/tier-derive.sh"
TSET="$REPO_ROOT/scripts/tier-set.sh"
GATE="$REPO_ROOT/scripts/tier-gate.sh"

setup() {
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
    run jq -e '.hookSpecificOutput.updatedInput.model == "haiku"' <<<"$output"
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

@test "tier-gate: a non-Claude (opencode) orca worker is note-only — no model the Agent tool would take" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set worker openrouter:qwen/qwen3-coder
    [ "$status" -eq 0 ]

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    [ "$status" -eq 0 ]
    out="$output"
    run jq -e '.systemMessage | test("orca-dispatch")' <<<"$out"
    [ "$status" -eq 0 ]
    run jq -e 'has("hookSpecificOutput") | not' <<<"$out"
    [ "$status" -eq 0 ]
}
