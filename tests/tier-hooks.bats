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
