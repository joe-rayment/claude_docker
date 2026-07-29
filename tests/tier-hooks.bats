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
    # pin billing mode to "api" so pre-existing assertions are independent of
    # whatever real credentials/env this container happens to run under;
    # billing-mode-specific tests below override this explicitly
    export COST_MIRROR_BILLING="api"
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
    [[ "$output" == *"main: 10 out · 100 cache-r (opus-5)"* ]]
    [[ "$output" == *"workers: 12 out · 120 cache-r (haiku-4-5-20251001)"* ]]
}

@test "cost-mirror: incremental — appended rows are picked up, totals not double-counted" {
    mk_transcript
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR" > /dev/null
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":90,"cache_read_input_tokens":900}}}\n' >> "$TP"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main: 100 out · 1k cache-r (opus-5)"* ]]
}

@test "cost-mirror: a truncated transcript is rescanned, not summed on top of stale state" {
    mk_transcript
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR" > /dev/null
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":3,"cache_read_input_tokens":30}}}\n' > "$TP"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main: 3 out · 30 cache-r (opus-5)"* ]]
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
    [[ "$output" == *"main: 10 out · 100 cache-r (opus-5)"* ]]
    jq -e '.v == 2' "$STATE_FILE"
}

@test "cost-mirror: pricing math — known token counts across two models produce the exact dollar clause" {
    mk_pricing_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"~\$26 · ~\$53 at fable-5 → saved ~\$27"* ]]
}

@test "cost-mirror: counterfactual top is picked by price, not by main-side volume" {
    # main: sonnet-5 at huge volume (cheap) and fable-5 at tiny volume
    # (pricier); worker: haiku. Old bug: pick_top_model ranked main rows by
    # (out+cr) volume, so sonnet-5 won on volume alone and fable-5's pricier
    # tokens repriced DOWN, driving "saved" hugely negative. Fixed: top is
    # ranked by output rate, so fable-5 wins despite its tiny volume, and
    # every row -- including the worker's -- reprices at/above actual cost.
    TP="$BATS_TEST_TMPDIR/proj-top/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-top"
    {
        printf '{"message":{"model":"claude-sonnet-5","usage":{"output_tokens":1000000}}}\n'
        printf '{"message":{"model":"claude-fable-5","usage":{"output_tokens":1000}}}\n'
        printf '{"isSidechain":true,"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":2000}}}\n'
    } > "$TP"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"at fable-5"* ]]
    [[ "$output" != *"at sonnet-5"* ]]
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"top model (counterfactual): fable-5"* ]]
    WORKER_LINE=$(echo "$output" | grep '^worker')
    [[ "$WORKER_LINE" != *"-\$"* ]]
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
    [[ "$output" == *"workers: 5 in · 8 out · 9 cache-r (legacy-1)"* ]]
    [[ "$output" == *"~\$0.00?"* ]]
}

@test "cost-mirror: token line surfaces in/cache-w and omits zero components" {
    mk_pricing_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main: 1.0M in · 100k out · 1.0M cache-r · 500k cache-w (fable-5)"* ]]
    [[ "$output" == *"workers: 2.0M in · 200k out (haiku-4-5-20251001)"* ]]
}

@test "cost-mirror: billing mode api leaves the hook dollar clause byte-identical to today" {
    mk_pricing_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"~\$26 · ~\$53 at fable-5 → saved ~\$27"* ]]
    [[ "$output" != *"API-equiv"* ]]
}

@test "cost-mirror: billing mode sub labels the hook dollar clause API-equiv, savings clause unchanged" {
    mk_pricing_transcript
    export COST_MIRROR_BILLING=sub
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"~\$26 API-equiv · ~\$53 at fable-5 → saved ~\$27"* ]]
}

@test "cost-mirror --report: api mode names the billing line, no API-equiv marker" {
    mk_pricing_transcript
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"billing: API (forced via COST_MIRROR_BILLING)"* ]]
    [[ "$output" != *"API-equiv"* ]]
    [[ "$output" == *"actual \$ "* ]]
}

@test "cost-mirror --report: sub mode names the billing line and marks money columns, table layout intact" {
    mk_pricing_transcript
    COST_MIRROR_BILLING=sub run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"billing: subscription (forced via COST_MIRROR_BILLING) — dollars are API-equivalent"* ]]
    [[ "$output" == *"actual \$*"* ]]
    [[ "$output" == *"at-top \$*"* ]]
    [[ "$output" == *"saved \$*"* ]]
    [[ "$output" == *'$26'* ]]
    [[ "$output" == *'$53'* ]]
    [[ "$output" == *'$27'* ]]
}

@test "cost-mirror: billing auto-detect reads oauth creds when no API key/token is in env" {
    mk_pricing_transcript
    unset COST_MIRROR_BILLING
    unset ANTHROPIC_API_KEY
    unset ANTHROPIC_AUTH_TOKEN
    CRED="$BATS_TEST_TMPDIR/creds.json"
    printf '{"claudeAiOauth":{"subscriptionType":"max"}}\n' > "$CRED"
    run env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u COST_MIRROR_BILLING \
        COST_MIRROR_CREDENTIALS_PATH="$CRED" python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"billing: subscription (auto: oauth creds (subscriptionType=max)) — dollars are API-equivalent"* ]]
}

@test "cost-mirror: billing auto-detect defaults to api when neither signal is present" {
    mk_pricing_transcript
    unset COST_MIRROR_BILLING
    unset ANTHROPIC_API_KEY
    unset ANTHROPIC_AUTH_TOKEN
    run env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u COST_MIRROR_BILLING \
        COST_MIRROR_CREDENTIALS_PATH=/nonexistent python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"billing: API (auto: no billing signal found, defaulting to api)"* ]]
}

@test "cost-mirror: an API key/token in env wins auto-detect over oauth creds" {
    mk_pricing_transcript
    unset COST_MIRROR_BILLING
    unset ANTHROPIC_API_KEY
    unset ANTHROPIC_AUTH_TOKEN
    CRED="$BATS_TEST_TMPDIR/creds.json"
    printf '{"claudeAiOauth":{"subscriptionType":"max"}}\n' > "$CRED"
    run env -u COST_MIRROR_BILLING -u ANTHROPIC_AUTH_TOKEN \
        ANTHROPIC_API_KEY=sk-test COST_MIRROR_CREDENTIALS_PATH="$CRED" python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"billing: API (auto: API key/token in env)"* ]]
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

# ── cost-mirror --report --all ──────────────────────────────────────────────

mk_all_projects() {
    # two independent "sessions" in two different project dirs, one model each
    ALLDIR="$BATS_TEST_TMPDIR/allprojects"
    mkdir -p "$ALLDIR/proj-a" "$ALLDIR/proj-b"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":10,"cache_read_input_tokens":100}}}\n' \
        > "$ALLDIR/proj-a/sess-a.jsonl"
    printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":20,"cache_read_input_tokens":200}}}\n' \
        > "$ALLDIR/proj-b/sess-b.jsonl"
    export COST_MIRROR_PROJECTS_DIR="$ALLDIR"
}

# md5sum of every file's path+contents under the state dir, order-independent
# (sorted) — a content-sensitive fingerprint, unlike `ls` which only sees
# filenames and is blind to a file being silently rewritten in place.
state_dir_checksum() {
    find "$COST_MIRROR_STATE_DIR" -type f -exec md5sum {} \; | sort | md5sum | awk '{print $1}'
}

@test "cost-mirror --report --all: aggregates every transcript into a per-session table plus a grand total" {
    # Two sessions, each with a main transcript AND a subagent file, so a
    # mutant that makes _session_file_paths() return just [tp] (silently
    # dropping subagent files from --all's per-session scope) changes the
    # TOTAL row below. A third, unrelated entry is pre-seeded directly into
    # the --all cache at a path nothing on disk glob-matches — it is never
    # touched by this run's scan, so a mutant that aggregates the grand
    # total over the WHOLE persisted cache instead of just this run's scope
    # also changes the TOTAL row below.
    #
    # Hand-computed at PRICING_TABLE rates (opus-5 out=25, haiku-4-5 out=5
    # USD/MTok; output_tokens only, so each row is one term):
    #   sess-a main   (opus-5,  out=1,000,000) = 1,000,000 * 25 / 1e6 = $25
    #   sess-a worker (haiku,   out=1,000,000) = 1,000,000 *  5 / 1e6 =  $5
    #   sess-b main   (haiku,   out=2,000,000) = 2,000,000 *  5 / 1e6 = $10
    #   sess-b worker (opus-5,  out=  200,000) =   200,000 * 25 / 1e6 =  $5
    #   actual total = 25 + 5 + 10 + 5                                = $45
    #   top model (highest output rate among MAIN rows) = opus-5 (25 > 5)
    #   at-top: every row repriced at opus-5's rate
    #     sess-a main   1,000,000 * 25 / 1e6 = $25 (already opus-5)
    #     sess-a worker 1,000,000 * 25 / 1e6 = $25
    #     sess-b main   2,000,000 * 25 / 1e6 = $50
    #     sess-b worker   200,000 * 25 / 1e6 =  $5
    #     at-top total = 25 + 25 + 50 + 5                            = $105
    #   saved = 105 - 45                                              = $60
    #   TOTAL row raw counters: in=0, out=4,200,000, cache-r=0, cache-w=0
    ALLDIR="$BATS_TEST_TMPDIR/allprojects"
    mkdir -p "$ALLDIR/proj-a/sess-a/subagents" "$ALLDIR/proj-b/sess-b/subagents"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":1000000}}}\n' \
        > "$ALLDIR/proj-a/sess-a.jsonl"
    printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n' \
        > "$ALLDIR/proj-a/sess-a/subagents/w1.jsonl"
    printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":2000000}}}\n' \
        > "$ALLDIR/proj-b/sess-b.jsonl"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":200000}}}\n' \
        > "$ALLDIR/proj-b/sess-b/subagents/w1.jsonl"
    export COST_MIRROR_PROJECTS_DIR="$ALLDIR"

    mkdir -p "$COST_MIRROR_STATE_DIR"
    printf '{"v":2,"files":{"%s/proj-c/stale.jsonl":{"off":999,"agg":{"main|claude-fable-5":{"in":0,"out":9999999,"cr":0,"w5":0,"w1":0}}}}}' \
        "$ALLDIR" > "$COST_MIRROR_STATE_DIR/all-sessions.json"

    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 session(s)"* ]]
    [[ "$output" == *"sess-a"* ]]
    [[ "$output" == *"sess-b"* ]]
    [[ "$output" == *"cost-mirror report — ALL sessions (2 transcripts)"* ]]
    [[ "$output" == *"opus-5"* ]]
    [[ "$output" == *"haiku-4-5-20251001"* ]]
    TOTAL_LINE=$(echo "$output" | grep '^TOTAL')
    read -r -a F <<< "$TOTAL_LINE"
    [ "${F[0]}" = "TOTAL" ]
    [ "${F[1]}" = "0" ]
    [ "${F[2]}" = "4200000" ]
    [ "${F[3]}" = "0" ]
    [ "${F[4]}" = "0" ]
    [ "${F[5]}" = '$45' ]
    [ "${F[6]}" = '$105' ]
    [ "${F[7]}" = '$60' ]
}

@test "cost-mirror --report --all: no transcripts found prints a message and exits nonzero" {
    EMPTY="$BATS_TEST_TMPDIR/emptyprojects"
    mkdir -p "$EMPTY"
    export COST_MIRROR_PROJECTS_DIR="$EMPTY"
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"no transcript files found"* ]]
}

@test "cost-mirror --report --all: an invalid --since value fails loud, valid ones are silent no-ops on match" {
    mk_all_projects
    run python3 "$MIRROR" --report --all --since notaday
    [ "$status" -eq 1 ]
    [[ "$output" == *"--since expects"* ]]
}

@test "cost-mirror --report --all --since: narrows to transcripts modified in the window" {
    mk_all_projects
    touch -d "3 days ago" "$ALLDIR/proj-a/sess-a.jsonl"
    run python3 "$MIRROR" --report --all --since 1d
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 session(s)"* ]]
    [[ "$output" == *"sess-b"* ]]
    [[ "$output" != *"sess-a"* ]]
}

@test "cost-mirror --report --all: warm run reuses the incremental cache, appended rows counted once not doubled" {
    # A pure "did the final total come out right" check can't tell a real
    # incremental scan from a mutant that always rescans from zero (both
    # give the same answer on a plain append). To make cache REUSE itself
    # load-bearing: after the cold run, corrupt the byte range that's
    # already been scanned (same length, now invalid JSON) and append a new
    # valid row. A true incremental scan never re-reads bytes before the
    # cached offset, so it still has the original row's tokens cached and
    # just adds the new row on top. A cold-from-zero rescan re-parses the
    # (now-corrupted) prefix, silently drops it as unparseable JSON, and
    # ends up with only the new row's tokens.
    mk_all_projects
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    ROW_A=$(echo "$output" | grep 'sess-a')
    read -r -a F <<< "$ROW_A"
    [ "${F[3]}" = "110" ]
    CACHE="$COST_MIRROR_STATE_DIR/all-sessions.json"
    [ -f "$CACHE" ]
    OFF_BEFORE=$(jq --arg p "$ALLDIR/proj-a/sess-a.jsonl" '.files[$p].off' "$CACHE")
    SIZE_BEFORE=$(wc -c < "$ALLDIR/proj-a/sess-a.jsonl")
    [ "$OFF_BEFORE" -eq "$SIZE_BEFORE" ]

    python3 -c "
path = '$ALLDIR/proj-a/sess-a.jsonl'
off = $OFF_BEFORE
with open(path, 'rb') as fh:
    data = fh.read()
prefix, rest = data[:off], data[off:]
corrupt = (b'#' * (len(prefix) - 1)) + b'\n'
with open(path, 'wb') as fh:
    fh.write(corrupt + rest)
"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":7,"cache_read_input_tokens":70}}}\n' >> "$ALLDIR/proj-a/sess-a.jsonl"

    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    ROW_A2=$(echo "$output" | grep 'sess-a')
    read -r -a F2 <<< "$ROW_A2"
    # warm reuse: cached 10/100 (cached before corruption) + new 7/70 = 187
    [ "${F2[3]}" = "187" ]
    # a cold-from-zero rescan would re-read the now-corrupted prefix, drop
    # it as unparseable, and see only the appended row's 7/70 = 77
    [ "${F2[3]}" != "77" ]

    OFF_AFTER=$(jq --arg p "$ALLDIR/proj-a/sess-a.jsonl" '.files[$p].off' "$CACHE")
    SIZE_AFTER=$(wc -c < "$ALLDIR/proj-a/sess-a.jsonl")
    [ "$OFF_AFTER" -eq "$SIZE_AFTER" ]
}

@test "cost-mirror --report --all: cache is a dedicated file, separate from hook per-session state" {
    mk_all_projects
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    [ -f "$COST_MIRROR_STATE_DIR/all-sessions.json" ]
    COUNT=$(ls "$COST_MIRROR_STATE_DIR" | wc -l)
    [ "$COUNT" -eq 1 ]
}

@test "cost-mirror --report: plain single-transcript mode still writes no state, even with an --all cache present" {
    # A filename-only comparison can't see a file being rewritten in place
    # (same name, different bytes) — checksum the state dir's contents
    # instead, not just its listing.
    mk_all_projects
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    BEFORE=$(state_dir_checksum)
    run python3 "$MIRROR" --report "$ALLDIR/proj-a/sess-a.jsonl"
    [ "$status" -eq 0 ]
    AFTER=$(state_dir_checksum)
    [ "$BEFORE" = "$AFTER" ]
}

@test "cost-mirror --report: bare --report with COST_MIRROR_PROJECTS_DIR honours the override, matching --all" {
    # _default_transcript() used to hardcode ~/.claude/projects/*/*.jsonl
    # for its no-state-file fallback, so COST_MIRROR_PROJECTS_DIR (honoured
    # by --all) was silently ignored by a bare --report with no state dir
    # to consult. Point COST_MIRROR_PROJECTS_DIR at a scratch corpus (a
    # single transcript, so the newest-mtime fallback is unambiguous) with
    # no prior cost-mirror state at all and confirm the bare --report
    # default lookup still finds and reports on it.
    SCRATCH="$BATS_TEST_TMPDIR/scratchprojects"
    mkdir -p "$SCRATCH/proj-only"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":10,"cache_read_input_tokens":100}}}\n' \
        > "$SCRATCH/proj-only/sess-only.jsonl"
    export COST_MIRROR_PROJECTS_DIR="$SCRATCH"
    run python3 "$MIRROR" --report
    [ "$status" -eq 0 ]
    [[ "$output" == *"cost-mirror report — $SCRATCH/proj-only/sess-only.jsonl"* ]]
    [[ "$output" == *"opus-5"* ]]
}
