#!/usr/bin/env bats
# tier-hooks.bats — the three spend-enforcement hooks:
#   tier-gate      PreToolUse[Agent]     default-cheap model for generic spawns
#   workflow-lint  PreToolUse[Workflow]  deny scripts whose agent() omits model
#   cost-mirror    UserPromptSubmit      by-model session spend line
# All three fail OPEN: any malformed/missing input path must be silent exit 0.

GATE=/workspace/scripts/tier-gate.sh
LINT=/workspace/scripts/workflow-lint.sh
MIRROR=/workspace/scripts/cost-mirror.py
DERIVE=/workspace/scripts/tier-derive.sh

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    SETTINGS="$BATS_TEST_TMPDIR/settings.json"
    printf '{"model":"claude-fable-5[1m]"}\n' > "$SETTINGS"
    export TIER_GATE_SETTINGS="$SETTINGS"
    export TIER_GATE_DERIVE="$DERIVE"
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-state"
}

gate() { sh "$GATE"; }
lint() { sh "$LINT"; }
mirror() { python3 "$MIRROR"; }

# ── tier-gate ────────────────────────────────────────────────────────────────

@test "tier-gate: generic spawn without model gets the derived worker injected" {
    run sh -c 'printf %s "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"prompt\":\"p\",\"description\":\"d\"}}" | sh '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"'
    # fable top -> worker = sonnet (capped derivation), injected as the ALIAS —
    # the Agent tool's model param rejects concrete ids (verified live)
    echo "$output" | jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"'
    # original fields survive the rewrite
    echo "$output" | jq -e '.hookSpecificOutput.updatedInput.prompt == "p"'
    echo "$output" | jq -e '.hookSpecificOutput.updatedInput.description == "d"'
    # nothing silent: a systemMessage names the injection
    echo "$output" | jq -e '.systemMessage | test("tier-gate")'
}

@test "tier-gate: explicit model always wins, on any type (also the idempotency guard)" {
    run sh -c 'printf %s "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"model\":\"haiku\",\"prompt\":\"p\"}}" | sh '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "tier-gate: named roles are never touched" {
    for role in scout executor verifier oracle professor bead-auditor; do
        run sh -c 'printf %s "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"'"$role"'\",\"prompt\":\"p\"}}" | sh '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
}

@test "tier-gate: bare spawn with no subagent_type is generic and gets the default" {
    run sh -c 'printf %s "{\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"p\"}}" | sh '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"'
}

@test "tier-gate: spawns inside a subagent are left alone" {
    run sh -c 'printf %s "{\"tool_name\":\"Agent\",\"transcript_path\":\"/p/s/subagents/agent-1.jsonl\",\"tool_input\":{\"prompt\":\"p\"}}" | sh '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "tier-gate: off-ladder top fails open (no injection, no error)" {
    printf '{"model":"my-custom-router"}\n' > "$SETTINGS"
    run sh -c 'printf %s "{\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"p\"}}" | sh '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "tier-gate: malformed input and non-Agent tools fail open" {
    run sh -c 'printf %s "NOT JSON" | sh '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run sh -c 'printf %s "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}" | sh '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "tier-gate: injected tier is read from tier-derive at runtime, never hardcoded" {
    # a stub derive whose worker ranks as haiku must yield haiku — while the
    # real ladder for this settings file would say sonnet
    stub="$BATS_TEST_TMPDIR/derive-stub"
    printf '#!/bin/sh\ncase "$1" in --rank) echo 1 ;; *) echo "top-x worker-y recon-z" ;; esac\n' > "$stub"
    chmod +x "$stub"
    run sh -c 'printf %s "{\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"p\"}}" | TIER_GATE_DERIVE='"$stub"' sh '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.updatedInput.model == "haiku"'
    # an unrankable worker fails open instead of injecting garbage
    printf '#!/bin/sh\ncase "$1" in --rank) echo 0 ;; *) echo "top-x worker-y recon-z" ;; esac\n' > "$stub"
    run sh -c 'printf %s "{\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"p\"}}" | TIER_GATE_DERIVE='"$stub"' sh '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── workflow-lint ────────────────────────────────────────────────────────────

@test "workflow-lint: agent() without model is denied with the call site listed" {
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"const meta = 1\\nconst r = await agent(\\\"do it\\\", {schema: S})\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("line 2")'
}

@test "workflow-lint: model on the call line or within 5 lines passes" {
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"await agent(\\\"p\\\", {model: \\\"claude-haiku-4-5-20251001\\\"})\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"await agent(\\\"p\\\", {\\n  schema: S,\\n  label: \\\"l\\\",\\n  model: \\\"claude-haiku-4-5-20251001\\\",\\n})\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: model-ok annotation suppresses a dynamic-opts call" {
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"await agent(p, opts) /* workflow-lint: model-ok */\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: mixed script lists only the offending call sites" {
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"await agent(\\\"a\\\", {model: \\\"m\\\"})\\nawait agent(\\\"b\\\", {schema: S})\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("line 2")'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("line 1:") | not'
}

@test "workflow-lint: named workflows, scriptPath files, and junk input" {
    # {name: ...} invocation has no script to lint: pass through
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{name:\"review-changes\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # scriptPath is read and linted
    printf 'await agent("q", {schema: S})\n' > "$BATS_TEST_TMPDIR/wf.js"
    run sh -c 'printf "{\"tool_name\":\"Workflow\",\"tool_input\":{\"scriptPath\":\"%s\"}}" "'"$BATS_TEST_TMPDIR"'/wf.js" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    # malformed input fails open
    run sh -c 'printf %s x | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # a script whose only "agent" mentions are subagent()/prose is clean
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"const x = subagent(1); log(\\\"agent count\\\")\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── cost-mirror ──────────────────────────────────────────────────────────────

mk_transcript() {
    # main transcript: one main row, one sidechain row; plus one subagent file
    TP="$BATS_TEST_TMPDIR/proj/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj/sess/subagents"
    {
        printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":10,"cache_read_input_tokens":100}}}\n'
        printf '{"isSidechain":true,"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":5,"cache_read_input_tokens":50}}}\n'
        printf 'THIS LINE IS NOT JSON\n'
        printf '{"message":{"model":"<synthetic>","usage":{"output_tokens":999}}}\n'
    } > "$TP"
    printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":7,"cache_read_input_tokens":70}}}\n' \
        > "$BATS_TEST_TMPDIR/proj/sess/subagents/agent-a1.jsonl"
}

@test "cost-mirror: sums main vs workers by model, skipping junk and synthetic rows" {
    mk_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main: 10 out · 100 cache-read (opus-5)"* ]]
    [[ "$output" == *"workers: 12 out · 120 cache-read (haiku-4-5-20251001)"* ]]
}

@test "cost-mirror: incremental — appended rows are picked up, totals not double-counted" {
    mk_transcript
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR" > /dev/null
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":90,"cache_read_input_tokens":900}}}\n' >> "$TP"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main: 100 out · 1k cache-read (opus-5)"* ]]
}

@test "cost-mirror: a truncated transcript is rescanned, not summed on top of stale state" {
    mk_transcript
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR" > /dev/null
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":3,"cache_read_input_tokens":30}}}\n' > "$TP"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main: 3 out · 30 cache-read (opus-5)"* ]]
}

@test "cost-mirror: missing transcript and malformed stdin are silent exit 0" {
    run sh -c 'printf "{\"transcript_path\":\"/nope/missing.jsonl\"}" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run sh -c 'printf %s garbage | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

mk_pricing_transcript() {
    # main: fable-5 with a full token profile; worker (sidechain): haiku,
    # input/output only. Hand-computed at PRICING_TABLE rates (fable
    # in10/out50/cr1/w5=12.5/w1=20, haiku in1/out5/cr0.1/w5=1.25/w1=2):
    #   fable main  = (1e6*10 + 1e5*50 + 1e6*1 + 4e5*12.5 + 1e5*20)/1e6 = $23
    #   haiku worker = (2e6*1 + 2e5*5)/1e6                              = $3
    #   actual = $26
    #   at-top: haiku's tokens repriced at fable rates too:
    #     23 + (2e6*10 + 2e5*50)/1e6 = 23 + 30                          = $53
    #   saved = 53 - 26                                                 = $27
    TP="$BATS_TEST_TMPDIR/proj-price/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-price"
    {
        printf '{"message":{"model":"claude-fable-5","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":400000,"ephemeral_1h_input_tokens":100000}}}}\n'
        printf '{"isSidechain":true,"message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":2000000,"output_tokens":200000}}}\n'
    } > "$TP"
}

@test "cost-mirror: v2 state schema is written; an old-schema state triggers a clean full rescan" {
    mk_transcript
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR" > /dev/null
    STATE_FILE=$(ls "$COST_MIRROR_STATE_DIR"/*.json)
    [ -n "$STATE_FILE" ]
    jq -e '.v == 2' "$STATE_FILE"
    jq -e --arg tp "$TP" '.files[$tp].agg["main|claude-opus-5"].out == 10' "$STATE_FILE"
    jq -e --arg tp "$TP" '.files[$tp].agg["main|claude-opus-5"].cr == 100' "$STATE_FILE"
    # seed an old-schema (list-agg, no v key) state with a bogus stale offset
    printf '{"files":{"%s":{"off":999999,"agg":{"main|claude-opus-5":[1,2]}}}}' "$TP" > "$STATE_FILE"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main: 10 out · 100 cache-read (opus-5)"* ]]
    jq -e '.v == 2' "$STATE_FILE"
}

@test "cost-mirror: pricing math — known token counts across two models produce the exact dollar clause" {
    mk_pricing_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"~\$26 · ~\$53 at fable-5 → saved ~\$27"* ]]
}

@test "cost-mirror: sonnet-5 intro pricing flips exactly at the 2026-09-01 cutoff" {
    run python3 -c "
import importlib.util
from datetime import date
spec = importlib.util.spec_from_file_location('cost_mirror_under_test', '$MIRROR')
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)
print(cm._sonnet5_rates(date(2026, 8, 31)))
print(cm._sonnet5_rates(date(2026, 9, 1)))
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(2.0, 10.0)"* ]]
    [[ "$output" == *"(3.0, 15.0)"* ]]
}

@test "cost-mirror: unknown model shows tokens but no dollars, marks the clause with '?'" {
    TP="$BATS_TEST_TMPDIR/proj-unknown/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-unknown"
    {
        printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30}}}\n'
        printf '{"isSidechain":true,"message":{"model":"claude-legacy-1","usage":{"input_tokens":5,"output_tokens":8,"cache_read_input_tokens":9}}}\n'
    } > "$TP"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"workers: 8 out · 9 cache-read (legacy-1)"* ]]
    [[ "$output" == *"~\$0.00?"* ]]
}

@test "cost-mirror --report: TOTAL matches the hook dollars, is idempotent, and never touches state" {
    mk_pricing_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"~\$26 · ~\$53 at fable-5 → saved ~\$27"* ]]
    STATE_FILE=$(ls "$COST_MIRROR_STATE_DIR"/*.json)
    [ -n "$STATE_FILE" ]
    CHECKSUM_BEFORE=$(md5sum "$STATE_FILE" | awk '{print $1}')
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TOTAL"* ]]
    [[ "$output" == *'$26'* ]]
    [[ "$output" == *'$53'* ]]
    [[ "$output" == *'$27'* ]]
    FIRST_REPORT="$output"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    [ "$output" = "$FIRST_REPORT" ]
    CHECKSUM_AFTER=$(md5sum "$STATE_FILE" | awk '{print $1}')
    [ "$CHECKSUM_BEFORE" = "$CHECKSUM_AFTER" ]
}

@test "cost-mirror --report: a missing transcript exits nonzero with a stderr message" {
    run python3 "$MIRROR" --report /nope/missing.jsonl
    [ "$status" -eq 1 ]
    [[ "$output" == *"transcript not found"* ]]
}
