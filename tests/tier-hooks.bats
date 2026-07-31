#!/usr/bin/env bats
# tier-hooks.bats — the spend-enforcement / tier-reminder hooks:
#   tier-gate      PreToolUse[Agent]     default-cheap model for generic spawns
#   workflow-lint  PreToolUse[Workflow]  deny scripts whose agent() omits model
#   cost-mirror    UserPromptSubmit      by-model session spend line
#   tier-prime     SessionStart/PreCompact  tier trio + protocol restatement
# All fail OPEN: any malformed/missing input path must be silent exit 0.

GATE=/workspace/scripts/tier-gate.sh
LINT=/workspace/scripts/workflow-lint.sh
MIRROR=/workspace/scripts/cost-mirror.py
DERIVE=/workspace/scripts/tier-derive.sh
PRIME=/workspace/scripts/tier-prime.sh
DOCKERFILE=/workspace/Dockerfile
SETTINGS_JSON=/workspace/config/claude-settings.json

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

# ── tier-prime ───────────────────────────────────────────────────────────────

setup_prime_agents() {
    # a scratch agents dir with executor.md/scout.md frontmatter, so the
    # trio line doesn't depend on this container's real bindings
    AGENTS_DIR="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$AGENTS_DIR"
    printf -- '---\nname: executor\nmodel: claude-sonnet-5\n---\nbody\n' > "$AGENTS_DIR/executor.md"
    printf -- '---\nname: scout\nmodel: claude-haiku-4-5-20251001\n---\nbody\n' > "$AGENTS_DIR/scout.md"
    export TIER_PRIME_SETTINGS="$SETTINGS"
    export TIER_PRIME_AGENTS_DIR="$AGENTS_DIR"
}

@test "tier-prime: no args prints the trio line and exits 0" {
    setup_prime_agents
    run "$PRIME"
    [ "$status" -eq 0 ]
    [[ "$output" == *"tier → orchestrator(settings model)=claude-fable-5[1m]"* ]]
    [[ "$output" == *"executor=claude-sonnet-5"* ]]
    [[ "$output" == *"scout=claude-haiku-4-5-20251001"* ]]
    [[ "$output" == *"verifier+oracle inherit the session model"* ]]
}

@test "tier-prime: --full adds the dispatch table and the standing-authorization sentence" {
    setup_prime_agents
    run "$PRIME" --full
    [ "$status" -eq 0 ]
    [[ "$output" == *"tier → orchestrator(settings model)=claude-fable-5[1m]"* ]]
    [[ "$output" == *"recon→scout"* ]]
    [[ "$output" == *"implementation slice→executor"* ]]
    [[ "$output" == *"non-trivial claim→verifier"* ]]
    [[ "$output" == *"trivial"*"→inline"* ]]
    [[ "$output" == *'subagent_type: "scout"'* ]]
    [[ "$output" == *"wrong tier"* ]]
    [[ "$output" == *"standing authorization"* ]]
    [[ "$output" == *"user's standing request"* ]]
    [[ "$output" == *"does NOT apply in this container"* ]]
}

@test "tier-prime: HOME unset still exits 0 with fallback text (no 'unbound variable' abort)" {
    unset TIER_PRIME_SETTINGS TIER_PRIME_AGENTS_DIR
    run env -u HOME -u TIER_PRIME_SETTINGS -u TIER_PRIME_AGENTS_DIR "$PRIME"
    [ "$status" -eq 0 ]
    [[ "$output" == *"orchestrator(settings model)=harness default"* ]]
    run env -u HOME -u TIER_PRIME_SETTINGS -u TIER_PRIME_AGENTS_DIR "$PRIME" --full
    [ "$status" -eq 0 ]
    [[ "$output" == *"standing authorization"* ]]
}

@test "tier-prime: missing settings/agent files still exits 0 with fallback text" {
    export TIER_PRIME_SETTINGS="$BATS_TEST_TMPDIR/nope-settings.json"
    export TIER_PRIME_AGENTS_DIR="$BATS_TEST_TMPDIR/nope-agents"
    run "$PRIME"
    [ "$status" -eq 0 ]
    [[ "$output" == *"orchestrator(settings model)=harness default"* ]]
    [[ "$output" == *"executor=sonnet (frontmatter)"* ]]
    [[ "$output" == *"scout=haiku (frontmatter)"* ]]
    run "$PRIME" --full
    [ "$status" -eq 0 ]
    [[ "$output" == *"standing authorization"* ]]
}

@test "tier-prime: trio line matches the exact expected string, character for character" {
    setup_prime_agents
    run "$PRIME"
    [ "$status" -eq 0 ]
    expected='tier → orchestrator(settings model)=claude-fable-5[1m]  executor=claude-sonnet-5  scout=claude-haiku-4-5-20251001 | verifier+oracle inherit the session model'
    [ "$output" = "$expected" ]
}

@test "config/claude-settings.json: SessionStart references tier-prime; PreCompact is exactly [bd prime, tier-prime --full] in order" {
    jq -e . "$SETTINGS_JSON"
    jq -e '[.hooks.SessionStart[].hooks[].command] | any(contains("tier-prime"))' "$SETTINGS_JSON"
    jq -e '[.hooks.PreCompact[].hooks] | flatten | length == 2' "$SETTINGS_JSON"
    jq -e '[.hooks.PreCompact[].hooks] | flatten | .[0].command | contains("bd prime")' "$SETTINGS_JSON"
    jq -e '[.hooks.PreCompact[].hooks] | flatten | .[1].command | contains("tier-prime")' "$SETTINGS_JSON"
    jq -e '[.hooks.PreCompact[].hooks] | flatten | .[1].command | contains("--full")' "$SETTINGS_JSON"
}

@test "Dockerfile: tier-prime.sh is COPY'd to /usr/local/bin/tier-prime" {
    grep -qE 'COPY .*scripts/tier-prime\.sh .*/usr/local/bin/tier-prime$' "$DOCKERFILE"
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

@test "workflow-lint: multi-line prompt with model far past the old 5-line window passes" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
const r = await agent(`
  line 1 of a long prompt
  line 2 of a long prompt
  line 3 of a long prompt
  line 4 of a long prompt
  line 5 of a long prompt
  line 6 of a long prompt
  line 7 of a long prompt
  line 8 of a long prompt
  line 9 of a long prompt
  line 10 of a long prompt
  line 11 of a long prompt
  line 12 of a long prompt
  line 13 of a long prompt
  line 14 of a long prompt
`, { model: "claude-haiku-4-5-20251001" })
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: prose containing the literal token agent( passes (template, string, and comment)" {
    # prose mentions sit more than 5 lines from any real model: line, so a
    # scanner that (like the pre-masking original) just line-greps for
    # agent( and looks 5 lines ahead for model: would flag every prose line
    # here; only masking string/template/comment content out first passes it.
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
const p1 = `please audit every agent() call in the script`
const p2 = "make sure agent() calls all set a model"
const p3 = 'agent( calls need review too'
// review each agent() call before merging
/* also check every agent() call in the diff */
// filler line 1 to push past the old 5-line window
// filler line 2 to push past the old 5-line window
// filler line 3 to push past the old 5-line window
// filler line 4 to push past the old 5-line window
// filler line 5 to push past the old 5-line window
const a = await agent(p1, { model: "claude-haiku-4-5-20251001" })
const b = await agent(p2, { model: "claude-sonnet-5" })
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: genuine missing model inside a long multi-line call still denies" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
const r = await agent(`
  line 1 of a long prompt
  line 2 of a long prompt
  line 3 of a long prompt
  line 4 of a long prompt
  line 5 of a long prompt
  line 6 of a long prompt
  line 7 of a long prompt
  line 8 of a long prompt
  line 9 of a long prompt
  line 10 of a long prompt
  line 11 of a long prompt
  line 12 of a long prompt
  line 13 of a long prompt
  line 14 of a long prompt
`, { schema: S, label: "l" })
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("line 1:")'
}

@test "workflow-lint: two agent() calls on one line, one missing a model, denies that line" {
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"parallel([() => agent(a, {model: m}), () => agent(b, {schema: S})])\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("line 1:")'
}

@test "workflow-lint: model in a neighbouring call does not launder a missing one on the next line" {
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"const a = await agent(\\\"a\\\", {model: \\\"m\\\"})\\nconst b = await agent(\\\"b\\\", {schema: S})\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("line 2:")'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("line 1:") | not'
}

@test "workflow-lint: WORKFLOW_LINT_WINDOW bounds the forward scan" {
    f="$BATS_TEST_TMPDIR/wf.js"
    printf 'const r = await agent(\n  a,\n  b,\n  c,\n  { model: "claude-haiku-4-5-20251001" }\n)\n' > "$f"
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | WORKFLOW_LINT_WINDOW=3 sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    # the same script passes with the default (unbounded-enough) window
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: unterminated template literal masks a real modelless agent() call after it (documented best-effort limit)" {
    f="$BATS_TEST_TMPDIR/wf.js"
    printf 'const p = `this template never closes\nsome more text\nawait agent(x, {schema: S})\nstill no backtick\n' > "$f"
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: model-ok annotation still works on the line after the call's closing paren" {
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"await agent(p, opts)\\n/* workflow-lint: model-ok */\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: D1 a division right after a closed brace is not mistaken for a regex start" {
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"agent(scout, { a: {}/2, model: \\\"haiku\\\" })\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: D2 a regex literal right after a closed block comment is still recognised as a regex" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
agent(x, /*c*/ /y\(/, { model: "h" })
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: D3 one-level nesting — a nested call's model does not launder a modelless outer call" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
await agent(outer, { schema: S }, agent(inner, { model: "m" }))
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("line 1:")'
}

@test "workflow-lint: D3 two-level nesting — an innermost model does not launder two modelless outer calls" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
await agent(outer, { schema: S }, agent(mid, { schema: S2 }, agent(inner, { model: "m" })))
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("line 1:")'
}

@test "workflow-lint: Object.assign opts built inline are collected and satisfy the guard" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
await agent("p", Object.assign({}, BASE, {model: M}))
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: a spread ternary inside the opts literal is collected and satisfies the guard" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
await agent("p", {label: "x", ...(cheap ? {model: "haiku"} : {model: "sonnet"})})
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: a bare ternary as the opts argument is collected and satisfies the guard" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
await agent("p", (cheap ? {model: "haiku"} : {model: "sonnet"}))
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: a helper call (not agent() itself) returning opts is collected and satisfies the guard" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
await agent("p", buildOpts({model: "haiku"}))
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: a nested agent( inside a .map closure in the outer call's arguments still denies" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
await agent(outer, { schema: S, onEach: items.map(x => agent(x, { model: m })) })
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("line 1:")'
}

@test "workflow-lint: D4 an identifier ending in model: does not satisfy the guard (with a genuine model: control)" {
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"agent({ prompt: \\\"kitchen reno\\\", remodel: true })\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"agent({ prompt: \\\"kitchen reno\\\", model: \\\"h\\\" })\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: a nested plain call before the opts object does not confuse the paren-depth walk" {
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"await agent(foo(1), { model: \\\"m\\\" })\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: an unterminated single-quoted string resyncs at EOL, so the next line's call is still checked" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
const s = 'unterminated
await agent(x, { schema: S })
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("line 2:")'
}

@test "workflow-lint: an unterminated double-quoted string resyncs at EOL, so the next line's call is still checked" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
const s = "unterminated
await agent(x, { schema: S })
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("line 2:")'
}

@test "workflow-lint: a nested object literal inside a \${...} template interpolation is handled (with model: and without)" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
await agent(`prompt ${JSON.stringify({a:1})}`, { model: "m" })
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    cat > "$f" <<'EOF'
await agent(`prompt ${JSON.stringify({a:1})}`, { schema: S })
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "workflow-lint: annotation exactly 2 lines past the call's closing paren line passes" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
const r = await agent(p, {
  schema: S
})
// filler
/* workflow-lint: model-ok */
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: annotation 3 lines past the call's closing paren line is out of window and denies" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
const r = await agent(p, {
  schema: S
})
// filler 1
// filler 2
/* workflow-lint: model-ok */
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "workflow-lint: several modelless calls on one line are reported as that one line, exactly once" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
parallel([agent(a, {schema: S}), agent(b, {schema: S2}), agent(c, {schema: S3})])
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '[.hookSpecificOutput.permissionDecisionReason | scan("line 1:")] | length == 1'
}

@test "workflow-lint: D5 a single line packed with ~20000 agent( calls does not hang and still denies" {
    f="$BATS_TEST_TMPDIR/wf.js"
    awk 'BEGIN { for (i = 0; i < 20000; i++) printf "agent(x); "; print "" }' > "$f"
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | timeout 10 sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "workflow-lint: a script over WORKFLOW_LINT_MAX_BYTES fails open without scanning" {
    f="$BATS_TEST_TMPDIR/wf.js"
    awk 'BEGIN { for (i = 0; i < 500010; i++) printf "a"; print "" }' > "$f"
    printf 'agent(x)\n' >> "$f"
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | timeout 10 sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: WORKFLOW_LINT_MAX_BYTES is honoured, both raised and default" {
    f="$BATS_TEST_TMPDIR/wf.js"
    printf 'await agent(x, {schema: S}) // more than fifty bytes on this line\n' > "$f"
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | WORKFLOW_LINT_MAX_BYTES=50 sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "workflow-lint: WORKFLOW_LINT_MAX_PER_LINE excess is fail-open (documented silent bypass)" {
    f="$BATS_TEST_TMPDIR/wf.js"
    awk 'BEGIN { for (i = 0; i < 64; i++) printf "agent(x, {model: m}); "; printf "agent(y, {schema: S})\n" }' > "$f"
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: WORKFLOW_LINT_MAX_PER_LINE is honoured from the environment" {
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"agent(y, {schema: S})\"}}" | WORKFLOW_LINT_MAX_PER_LINE=0 sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"agent(y, {schema: S})\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "workflow-lint: unterminated block comment masks a real modelless agent() call after it (documented best-effort limit)" {
    f="$BATS_TEST_TMPDIR/wf.js"
    printf '/* this comment never closes\nsome more text\nawait agent(x, {schema: S})\nstill no closing comment\n' > "$f"
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow-lint: WORKFLOW_LINT_DISABLE=1 bypasses entirely" {
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"agent(y, {schema: S})\"}}" | WORKFLOW_LINT_DISABLE=1 sh '"$LINT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run sh -c 'jq -cn "{tool_name:\"Workflow\",tool_input:{script:\"agent(y, {schema: S})\"}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "workflow-lint: a nested agent( call starting at column 1 of a continuation line is still recognised as nested" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
await agent(outer,
agent(inner, { model: "m" }),
{ schema: S })
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("line 1:")'
}

@test "workflow-lint: WORKFLOW_LINT_WINDOW truncation narrows the annotation window to the truncation point" {
    f="$BATS_TEST_TMPDIR/wf.js"
    cat > "$f" <<'EOF'
const r = await agent(p, {
  a: 1,
  b: 2,
  c: 3,
  d: 4
})
// filler
/* workflow-lint: model-ok */
EOF
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | WORKFLOW_LINT_WINDOW=3 sh '"$LINT"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    run sh -c 'jq -cn --rawfile s "'"$f"'" "{tool_name:\"Workflow\",tool_input:{script:\$s}}" | sh '"$LINT"
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

@test "cost-mirror: v4 state schema is written; an old-schema state triggers a clean full rescan" {
    # v4 (was v3): bumped for the message.id de-dup fix (a v3 state holds
    # per-content-block-inflated counts with no record of which message.id
    # contributed what, so it can't be fixed in place) and for the
    # bare-"worker" -> "worker:<role>" per-role split.
    mk_transcript
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR" > /dev/null
    # exclude lifetime.json — the hook now also writes the durable rollup
    # alongside its per-session <sha256>.json state file
    STATE_FILE=$(ls "$COST_MIRROR_STATE_DIR"/*.json | grep -v /lifetime.json)
    [ -n "$STATE_FILE" ]
    jq -e '.v == 4' "$STATE_FILE"
    jq -e --arg tp "$TP" '.files[$tp].agg["main|claude-opus-5"].out == 10' "$STATE_FILE"
    jq -e --arg tp "$TP" '.files[$tp].agg["main|claude-opus-5"].cr == 100' "$STATE_FILE"
    # seed an old-schema (list-agg, no v key) state with a bogus stale offset
    printf '{"files":{"%s":{"off":999999,"agg":{"main|claude-opus-5":[1,2]}}}}' "$TP" > "$STATE_FILE"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main: 10 out · 100 cache-r (opus-5)"* ]]
    jq -e '.v == 4' "$STATE_FILE"
}

@test "cost-mirror: v4 upgrade does NOT wipe a schema-compatible lifetime.json (independent LIFETIME_VERSION constant)" {
    # This slice bumped BOTH constants (the de-dup fix corrupted lifetime's
    # own counters too — see LIFETIME_VERSION's comment), but the two stay
    # independent constants on purpose: a lifetime.json already on the
    # CURRENT LIFETIME_VERSION must survive an unrelated future scan-state
    # STATE_VERSION bump untouched, same as v3's bagg-only bump left v2
    # lifetime data alone.
    mk_transcript
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR" > /dev/null
    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"
    [ -f "$LIFETIME" ]
    jq -e '.v == 3' "$LIFETIME"
    jq -e 'any(.sessions[]; .out == 10)' "$LIFETIME"
}

@test "cost-mirror: a pre-fix lifetime.json (old LIFETIME_VERSION, poisoned doubled counters) is rebuilt clean, not carried forward" {
    mkdir -p "$COST_MIRROR_STATE_DIR"
    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"
    printf '{"v":2,"sessions":{"deadsess|main|claude-opus-5":{"in":0,"out":99999999,"cr":0,"w5":0,"w1":0,"project":"ghost","mtime":1,"tp":"/nope.jsonl","sessionId":"deadsess"}}}' \
        > "$LIFETIME"
    mk_transcript
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR" > /dev/null
    jq -e '.v == 3' "$LIFETIME"
    # the old-version poisoned row is gone -- not merged, not carried forward
    jq -e 'any(.sessions | keys[]; . == "deadsess|main|claude-opus-5") | not' "$LIFETIME"
}

# ── cost-mirror: measurement fixes (de-dup / nested subagents / per-role) ──

@test "cost-mirror: message.id de-dup — three rows sharing one id count once, output takes the max" {
    # Real shape: one API response is written as one row per content block,
    # each repeating in/cache-r in full while output_tokens is cumulative
    # (e.g. the real 3,3,3,3,3,571 sample named in the bug report).
    TP="$BATS_TEST_TMPDIR/proj-dedup/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-dedup"
    {
        printf '{"message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":50,"output_tokens":3,"cache_read_input_tokens":100}}}\n'
        printf '{"message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":50,"output_tokens":3,"cache_read_input_tokens":100}}}\n'
        printf '{"message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":50,"output_tokens":571,"cache_read_input_tokens":100}}}\n'
    } > "$TP"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    MAIN_LINE=$(echo "$output" | grep '^main')
    read -r -a F <<< "$MAIN_LINE"
    [ "${F[2]}" = "50" ]    # in — counted once, not 3x150
    [ "${F[3]}" = "571" ]   # out — max/last, not summed (3+3+571=577)
    [ "${F[4]}" = "100" ]   # cache-r — counted once, not 3x300
}

@test "cost-mirror: de-dup persists across an incremental scan boundary landing inside a message.id group" {
    # The hook scans incrementally; a group can straddle two separate
    # invocations (more content blocks appended after the first scan). The
    # dedup ring lives in fstate, not a local, so it must survive that.
    TP="$BATS_TEST_TMPDIR/proj-dedup-inc/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-dedup-inc"
    printf '{"message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":50,"output_tokens":3,"cache_read_input_tokens":100}}}\n' > "$TP"
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR" > /dev/null
    printf '{"message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":50,"output_tokens":571,"cache_read_input_tokens":100}}}\n' >> "$TP"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main: 50 in · 571 out · 100 cache-r (opus-5)"* ]]
}

@test "cost-mirror: a row with no message.id is never deduped, counted in full (existing fixtures rely on this)" {
    mk_transcript
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    MAIN_LINE=$(echo "$output" | grep '^main')
    read -r -a F <<< "$MAIN_LINE"
    [ "${F[3]}" = "10" ]
}

@test "cost-mirror: nested workflow subagent transcripts (subagents/workflows/<wf>/agent-*.jsonl) are scanned" {
    TP="$BATS_TEST_TMPDIR/proj-nested/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-nested/sess/subagents/workflows/wf1"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":10}}}\n' > "$TP"
    printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":40}}}\n' \
        > "$BATS_TEST_TMPDIR/proj-nested/sess/subagents/workflows/wf1/agent-x.jsonl"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    WORKER_LINE=$(echo "$output" | grep '^worker ')
    [ -n "$WORKER_LINE" ]
    read -r -a F <<< "$WORKER_LINE"
    [ "${F[3]}" = "40" ]
}

@test "cost-mirror: subagent role label prefers customAgentType over agentType (named-spawn sidecar)" {
    # NAMED spawns put the spawn's *name* in agentType and the true role in
    # customAgentType -- using agentType alone would mislabel this as
    # "worker:final-check" instead of "worker:verifier".
    TP="$BATS_TEST_TMPDIR/proj-role/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-role/sess/subagents"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":10}}}\n' > "$TP"
    printf '{"message":{"model":"claude-sonnet-5","usage":{"output_tokens":20}}}\n' \
        > "$BATS_TEST_TMPDIR/proj-role/sess/subagents/agent-v1.jsonl"
    printf '{"agentType":"final-check","customAgentType":"verifier"}' \
        > "$BATS_TEST_TMPDIR/proj-role/sess/subagents/agent-v1.meta.json"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    ROLE_LINE=$(echo "$output" | grep '^worker:verifier')
    [ -n "$ROLE_LINE" ]
    [[ "$output" != *"worker:final-check"* ]]
}

@test "cost-mirror: a subagent with no sidecar, or an unreadable one, falls back to bare worker" {
    TP="$BATS_TEST_TMPDIR/proj-nosidecar/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-nosidecar/sess/subagents"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":10}}}\n' > "$TP"
    # no sidecar at all for agent-n1
    printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":5}}}\n' \
        > "$BATS_TEST_TMPDIR/proj-nosidecar/sess/subagents/agent-n1.jsonl"
    # a co-located but unreadable/malformed sidecar for agent-n2
    printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":9}}}\n' \
        > "$BATS_TEST_TMPDIR/proj-nosidecar/sess/subagents/agent-n2.jsonl"
    printf 'NOT JSON' > "$BATS_TEST_TMPDIR/proj-nosidecar/sess/subagents/agent-n2.meta.json"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    WORKER_LINE=$(echo "$output" | grep '^worker ')
    [ -n "$WORKER_LINE" ]
    read -r -a F <<< "$WORKER_LINE"
    [ "${F[3]}" = "14" ]  # both n1 (5) and n2 (9) folded into bare "worker"
    [[ "$output" != *"worker:"* ]]
}

@test "cost-mirror: hook 'workers:' clause folds in per-role worker:<role> rows, not just bare worker" {
    TP="$BATS_TEST_TMPDIR/proj-rolehook/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-rolehook/sess/subagents"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":10}}}\n' > "$TP"
    printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":7,"cache_read_input_tokens":70}}}\n' \
        > "$BATS_TEST_TMPDIR/proj-rolehook/sess/subagents/agent-e1.jsonl"
    printf '{"customAgentType":"executor"}' \
        > "$BATS_TEST_TMPDIR/proj-rolehook/sess/subagents/agent-e1.meta.json"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"workers: 7 out · 70 cache-r (haiku-4-5-20251001)"* ]]
}

@test "cost-mirror: delegation savings include worker:<role> rows, not just bare worker (consumer fix)" {
    # Before the fix, session_delegation_savings filtered on
    # key.startswith("worker|"), which "worker:scout|..." never matches --
    # this session would have silently reported $0.00 saved.
    TP="$BATS_TEST_TMPDIR/proj-rolesave/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-rolesave/sess/subagents"
    printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-opus-5","usage":{"output_tokens":1000000}}}\n' > "$TP"
    printf '{"timestamp":"2026-07-29T00:01:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n' \
        > "$BATS_TEST_TMPDIR/proj-rolesave/sess/subagents/agent-s1.jsonl"
    printf '{"customAgentType":"scout"}' \
        > "$BATS_TEST_TMPDIR/proj-rolesave/sess/subagents/agent-s1.meta.json"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    SAVE_LINE=$(echo "$output" | grep '^worker:scout')
    [ -n "$SAVE_LINE" ]
    read -r -a F <<< "$SAVE_LINE"
    # haiku out=1e6 @ $5/MTok actual=$5.00; repriced at opus-5's $25/MTok
    # (this session's one epoch, clamped to the whole timeline) = $25;
    # saved = $20 -- non-zero, proving the consumer fix took effect.
    [ "${F[6]}" = '$5.00' ]
    [ "${F[7]}" = '$25' ]
    [ "${F[8]}" = '$20' ]
}

@test "cost-mirror: render_report widens the side column and lists every distinct side, main first" {
    TP="$BATS_TEST_TMPDIR/proj-sides/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-sides/sess/subagents"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":10}}}\n' > "$TP"
    printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":5}}}\n' \
        > "$BATS_TEST_TMPDIR/proj-sides/sess/subagents/agent-a1.jsonl"
    printf '{"message":{"model":"claude-sonnet-5","usage":{"output_tokens":6}}}\n' \
        > "$BATS_TEST_TMPDIR/proj-sides/sess/subagents/agent-b1.jsonl"
    printf '{"customAgentType":"verifier"}' \
        > "$BATS_TEST_TMPDIR/proj-sides/sess/subagents/agent-b1.meta.json"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    ROWS=$(echo "$output" | grep -E '^(main|worker)' | awk '{print $1}')
    [ "$(echo "$ROWS" | head -1)" = "main" ]
    echo "$ROWS" | grep -qx "worker"
    echo "$ROWS" | grep -qx "worker:verifier"
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
    # whole-state-dir checksum (not a single filename) — the hook now
    # writes BOTH a per-session <sha256>.json file AND lifetime.json, and
    # this asserts a positional --report touches neither.
    CHECKSUM_BEFORE=$(state_dir_checksum)
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
    CHECKSUM_AFTER=$(state_dir_checksum)
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
    # USD/MTok; output_tokens only, so each row is one term). Neither
    # session carries a "timestamp" field, so every row lands in the
    # shared NA_BUCKET and each session collapses to ONE tier epoch (its
    # single main-loop model) — but epochs are computed and priced PER
    # SESSION (session_epoch_pricing on that session's OWN bucket_total,
    # summed via _add_pricing), never by merging both sessions' rows into
    # one epoch set, so sess-a's opus-5 tier must never reprice sess-b's
    # haiku-tier spend or vice versa ("neither reprices the other"):
    #   sess-a main   (opus-5,  out=1,000,000) actual = 1,000,000*25/1e6 = $25
    #   sess-a worker (haiku,   out=1,000,000) actual = 1,000,000* 5/1e6 =  $5
    #     sess-a's only main model is opus-5 -> sess-a's one epoch = opus-5
    #     worker at_epoch = 1,000,000*25/1e6 = $25 -> sess-a saved = 25-5 = $20
    #   sess-b main   (haiku,   out=2,000,000) actual = 2,000,000* 5/1e6 = $10
    #   sess-b worker (opus-5,  out=  200,000) actual =   200,000*25/1e6 =  $5
    #     sess-b's only main model is haiku   -> sess-b's one epoch = haiku
    #     worker at_epoch =   200,000* 5/1e6 =  $1 -> sess-b saved = 1-5 = -$4
    #   actual total = 25 + 5 + 10 + 5                                 = $45
    #   at-top total: main rows NEVER reprice (always at_epoch==actual, by
    #   construction — that's the fix) + worker at_epoch from above:
    #     sess-a: main $25 (unchanged) + worker $25 = $50
    #     sess-b: main $10 (unchanged) + worker  $1 = $11
    #     at-top total = 50 + 11                                       = $61
    #   saved = 61 - 45 = 20 + (-4)                                    = $16
    #   (the OLD single-session-wide-top method gave at-top $105/saved $60
    #   here — reproduced by tests below — by repricing sess-b's ENTIRE
    #   haiku-tier main+worker spend at sess-a's opus-5 rate; this is
    #   exactly the cross-session leak the per-session epoch fix closes)
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
    printf '{"v":4,"files":{"%s/proj-c/stale.jsonl":{"off":999,"agg":{"main|claude-fable-5":{"in":0,"out":9999999,"cr":0,"w5":0,"w1":0}}}}}' \
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
    [ "${F[6]}" = '$61' ]
    [ "${F[7]}" = '$16' ]
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
    # all-sessions.json (incremental cache) + lifetime.json (durable
    # rollup) — no per-session <sha256>.json hook state files, since --all
    # never ran the hook.
    [ -f "$COST_MIRROR_STATE_DIR/lifetime.json" ]
    COUNT=$(ls "$COST_MIRROR_STATE_DIR" | wc -l)
    [ "$COUNT" -eq 2 ]
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

@test "cost-mirror --report --this: honours COST_MIRROR_PROJECTS_DIR for the no-state-file fallback" {
    # _default_transcript() used to hardcode ~/.claude/projects/*/*.jsonl
    # for its no-state-file fallback, so COST_MIRROR_PROJECTS_DIR (honoured
    # by --all) was silently ignored. Point COST_MIRROR_PROJECTS_DIR at a
    # scratch corpus (a single transcript, so the newest-mtime fallback is
    # unambiguous) with no prior cost-mirror state at all and confirm
    # --this's default lookup still finds and reports on it.
    SCRATCH="$BATS_TEST_TMPDIR/scratchprojects"
    mkdir -p "$SCRATCH/proj-only"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":10,"cache_read_input_tokens":100}}}\n' \
        > "$SCRATCH/proj-only/sess-only.jsonl"
    export COST_MIRROR_PROJECTS_DIR="$SCRATCH"
    run python3 "$MIRROR" --report --this
    [ "$status" -eq 0 ]
    [[ "$output" == *"cost-mirror report — $SCRATCH/proj-only/sess-only.jsonl"* ]]
    [[ "$output" == *"opus-5"* ]]
}

@test "cost-mirror --report: bare default now aggregates (was: single newest-state-file transcript)" {
    # The behavior contract changed in this slice: bare --report (the
    # tier-cost alias) is now the aggregate report, matching --all
    # byte-for-byte, rather than falling back through _default_transcript().
    mk_all_projects
    run python3 "$MIRROR" --report
    bare_status="$status"
    bare_output="$output"
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    [ "$bare_status" -eq 0 ]
    [ "$bare_output" = "$output" ]
    [[ "$bare_output" == *"session(s) across"* ]]
}

@test "cost-mirror --report: the reported regression — bare default aggregates instead of pointing at the newest hook state file" {
    # Reproduces the exact bug from the bead: two sessions, one LARGE and
    # richly priced, one NEAR-EMPTY whose hook ran (and so whose state file
    # was written) LATER -- e.g. a second parallel session started and
    # immediately killed. Under the OLD behaviour, bare --report called
    # _default_transcript(), which returns the tp recorded in the
    # newest-mtime STATE FILE -- so it silently reported only the
    # near-empty session while the large session's spend went unreported
    # (no data lost, the report just quietly pointed elsewhere). This test
    # was confirmed to FAIL against the pre-slice code (bare --report
    # showed only the haiku/near-empty session, TOTAL out=1) and PASS
    # against this slice's code. Bare --report must now include BOTH
    # sessions, with total actual dollars equal to their sum.
    PROJECTS="$BATS_TEST_TMPDIR/regression-projects"
    mkdir -p "$PROJECTS/bigproj" "$PROJECTS/smallproj"
    BIG="$PROJECTS/bigproj/big.jsonl"
    SMALL="$PROJECTS/smallproj/small.jsonl"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":1000000}}}\n' > "$BIG"
    printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1}}}\n' > "$SMALL"
    export COST_MIRROR_PROJECTS_DIR="$PROJECTS"

    # Run the hook for the BIG session first...
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$BIG"'" | python3 '"$MIRROR" > /dev/null
    # ...then for the SMALL session, and force its state file strictly
    # newer so the newest-mtime pick is deterministic regardless of
    # filesystem mtime granularity.
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$SMALL"'" | python3 '"$MIRROR" > /dev/null
    SMALL_STATE=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16]+'.json')" "$SMALL")
    touch -d "+1 hour" "$COST_MIRROR_STATE_DIR/$SMALL_STATE"

    # Sanity: --this (the old default lookup, now opt-in) does point at the
    # near-empty session — confirms the newer-state-file setup is correct.
    run python3 "$MIRROR" --report --this
    [ "$status" -eq 0 ]
    [[ "$output" == *"$SMALL"* ]]
    [[ "$output" != *"$BIG"* ]]

    run python3 "$MIRROR" --report
    [ "$status" -eq 0 ]
    [[ "$output" == *"opus-5"* ]]
    [[ "$output" == *"haiku-4-5-20251001"* ]]
    TOTAL_LINE=$(echo "$output" | grep '^TOTAL')
    read -r -a F <<< "$TOTAL_LINE"
    # opus-5 1,000,000 out (BIG) + haiku 1 out (SMALL) = 1,000,001
    [ "${F[2]}" = "1000001" ]
}

@test "cost-mirror --report --session: unique prefix selects the right transcript" {
    PROJECTS="$BATS_TEST_TMPDIR/session-projects"
    mkdir -p "$PROJECTS/proj-x" "$PROJECTS/proj-y"
    printf '{"sessionId":"11111111-aaaa-bbbb-cccc-000000000001","message":{"model":"claude-opus-5","usage":{"output_tokens":10}}}\n' \
        > "$PROJECTS/proj-x/11111111-aaaa-bbbb-cccc-000000000001.jsonl"
    printf '{"sessionId":"22222222-aaaa-bbbb-cccc-000000000002","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":20}}}\n' \
        > "$PROJECTS/proj-y/22222222-aaaa-bbbb-cccc-000000000002.jsonl"
    export COST_MIRROR_PROJECTS_DIR="$PROJECTS"

    run python3 "$MIRROR" --report --session 1111
    [ "$status" -eq 0 ]
    [[ "$output" == *"opus-5"* ]]
    [[ "$output" != *"haiku"* ]]
}

@test "cost-mirror --report --session: ambiguous prefix fails loud listing candidates" {
    PROJECTS="$BATS_TEST_TMPDIR/session-projects-ambig"
    mkdir -p "$PROJECTS/proj-y"
    printf '{"sessionId":"22222222-aaaa-bbbb-cccc-000000000002","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":20}}}\n' \
        > "$PROJECTS/proj-y/22222222-aaaa-bbbb-cccc-000000000002.jsonl"
    printf '{"sessionId":"22223333-aaaa-bbbb-cccc-000000000003","message":{"model":"claude-fable-5","usage":{"output_tokens":30}}}\n' \
        > "$PROJECTS/proj-y/22223333-aaaa-bbbb-cccc-000000000003.jsonl"
    export COST_MIRROR_PROJECTS_DIR="$PROJECTS"

    run python3 "$MIRROR" --report --session 2222
    [ "$status" -eq 1 ]
    [[ "$output" == *"ambiguous"* ]]
    [[ "$output" == *"22222222"* ]]
    [[ "$output" == *"22223333"* ]]
}

@test "cost-mirror --report --session: no-match prefix fails loud" {
    PROJECTS="$BATS_TEST_TMPDIR/session-projects-nomatch"
    mkdir -p "$PROJECTS/proj-x"
    printf '{"sessionId":"11111111-aaaa-bbbb-cccc-000000000001","message":{"model":"claude-opus-5","usage":{"output_tokens":10}}}\n' \
        > "$PROJECTS/proj-x/11111111-aaaa-bbbb-cccc-000000000001.jsonl"
    export COST_MIRROR_PROJECTS_DIR="$PROJECTS"

    run python3 "$MIRROR" --report --session zzzz
    [ "$status" -eq 1 ]
    [[ "$output" == *"no session matches"* ]]
}

@test "cost-mirror --report --this: reproduces the old single-session default (newest hook state file)" {
    mk_transcript
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR" > /dev/null
    run python3 "$MIRROR" --report --this
    [ "$status" -eq 0 ]
    [[ "$output" == *"cost-mirror report — $TP"* ]]
    [[ "$output" == *"opus-5"* ]]
}

@test "cost-mirror --report: lifetime.json is idempotent across repeated aggregate runs (replace, never increment)" {
    mk_all_projects
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    FIRST="$output"
    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"
    [ -f "$LIFETIME" ]

    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    SECOND="$output"
    [ "$FIRST" = "$SECOND" ]
    CHECKSUM_AFTER_2=$(md5sum "$LIFETIME" | awk '{print $1}')

    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    THIRD="$output"
    [ "$SECOND" = "$THIRD" ]
    CHECKSUM_AFTER_3=$(md5sum "$LIFETIME" | awk '{print $1}')
    [ "$CHECKSUM_AFTER_2" = "$CHECKSUM_AFTER_3" ]
}

@test "cost-mirror --report: durable lifetime rollup — a deleted transcript's spend still counts, with a footnote" {
    mk_all_projects
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 session(s)"* ]]
    BEFORE_TOTAL=$(echo "$output" | grep '^TOTAL')

    rm "$ALLDIR/proj-a/sess-a.jsonl"
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 session(s)"* ]]
    [[ "$output" == *"no longer on disk"* ]]
    AFTER_TOTAL=$(echo "$output" | grep '^TOTAL')
    [ "$BEFORE_TOTAL" = "$AFTER_TOTAL" ]
}

@test "cost-mirror --report --session/--this: write no state, even with lifetime.json present" {
    mk_all_projects
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    [ -f "$COST_MIRROR_STATE_DIR/lifetime.json" ]
    BEFORE=$(state_dir_checksum)

    run python3 "$MIRROR" --report --session sess-a
    [ "$status" -eq 0 ]
    run python3 "$MIRROR" --report --this
    [ "$status" -eq 0 ]

    AFTER=$(state_dir_checksum)
    [ "$BEFORE" = "$AFTER" ]
}

# ── cost-mirror: tier epochs (delegation-only savings) ──────────────────────

mk_epoch_transcript() {
    # Single session; main-loop tier changes from opus-5 to haiku-4-5
    # mid-session (a real /tier downgrade), timestamped for real this
    # time (not the NA-bucket fallback other fixtures rely on). Worker
    # (isSidechain) rows scattered before/during/after both epochs. Every
    # row is output_tokens=1,000,000 (opus-5 $25/MTok, haiku-4-5 $5/MTok
    # out rate) so every dollar figure below is a whole multiple of $5.
    TP="$BATS_TEST_TMPDIR/proj-epoch/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-epoch"
    {
        # before the first main row -- inside the clamped-backward opus-5
        # epoch (see _epochs_from_main_buckets), not "outside every epoch"
        printf '{"isSidechain":true,"timestamp":"2026-07-28T23:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
        # opus-5 epoch: one main row, one worker row inside it
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-opus-5","usage":{"output_tokens":1000000}}}\n'
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:01:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
        # /tier downgrade to haiku-4-5: new epoch, one main row, one
        # worker row inside it (already at the epoch's own rate -> $0)
        printf '{"timestamp":"2026-07-29T00:10:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:11:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
        # after the last main row -- inside the clamped-forward haiku-4-5
        # epoch, not "outside every epoch"
        printf '{"isSidechain":true,"timestamp":"2026-07-29T01:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
    } > "$TP"
}

@test "cost-mirror: mid-session /tier change — delegation-only savings, proven to differ from the old whole-session method" {
    mk_epoch_transcript
    # Hand-computed at PRICING_TABLE rates (opus-5 out=25, haiku-4-5 out=5
    # USD/MTok; every row is 1,000,000 out, so each term is $25 or $5).
    # _epochs_from_main_buckets clamps the first/last epoch to cover the
    # WHOLE session timeline (see module docstring / defect-1 fix), so the
    # two boundary workers are NOT "outside every epoch" -- they reprice
    # against the nearest orchestrator tier, same as any interior worker:
    #   main opus-5   epoch [-inf, 00:10)    actual $25 (never repriced)
    #   main haiku-4-5 epoch [00:10, +inf)   actual  $5 (never repriced)
    #   worker @00:01 (inside opus-5 epoch)  actual $5, at_epoch(opus) $25
    #                                        -> saved $20
    #   worker @00:11 (inside haiku-4-5 epoch) actual $5, at_epoch(haiku) $5
    #                                        -> saved $0
    #   worker @23:00 prev day (before the first main row, now inside the
    #     clamped-backward opus-5 epoch) actual $5, at_epoch(opus) $25
    #                                        -> saved $20
    #   worker @01:00 (after the last main row, now inside the
    #     clamped-forward haiku-4-5 epoch) actual $5, at_epoch(haiku) $5
    #                                        -> saved $0
    #   actual total = 25 + 5 + 5+5+5+5                              = $50
    #   saved total  = 20 + 0 + 20 + 0                                = $40
    #   at-top total = actual + saved                                = $90
    #
    #   OLD single-top method (pick_top_model over the WHOLE session,
    #   reprice everything including main-loop rows): top=opus-5 (priced
    #   higher than haiku-4-5); reprices all 6 rows, main included, at
    #   opus-5's $25 rate -> old at-top = 25*6 = $150, old saved = $100.
    #   $100 != $40 -- proves the fix still changes the actual number (main-
    #   loop spend still never shows up as "saved") even though the clamp
    #   now reprices both boundary workers same as the old method would
    #   have priced them (at opus, the epoch nearest in time) rather than
    #   dropping them to zero.
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"~\$50 · ~\$90 at opus-5 → saved ~\$40"* ]]
    [[ "$output" != *"saved ~\$100"* ]]

    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    TOTAL_LINE=$(echo "$output" | grep '^TOTAL')
    read -r -a F <<< "$TOTAL_LINE"
    [ "${F[5]}" = '$50' ]
    [ "${F[6]}" = '$90' ]
    [ "${F[7]}" = '$40' ]
    # Main-loop spend can never show a nonzero "saved" -- the whole point
    # of the fix -- even the DOWNGRADE-side main row (haiku-4-5, cheaper
    # than the session's opus-5 "top"), whose saved would have been a
    # large FAKE $20 (25-5) under the old whole-session repricing.
    MAIN_HAIKU_LINE=$(echo "$output" | grep '^main.*haiku')
    read -r -a MH <<< "$MAIN_HAIKU_LINE"
    [ "${MH[6]}" = '$5.00' ]
    [ "${MH[7]}" = '$5.00' ]
    [ "${MH[8]}" = '$0.00' ]
    # the (single, since side+model aggregates all 4 buckets together)
    # worker row: actual $5*4=$20, at-top 25(23:00)+25(00:01)+5(00:11)+5(01:00)=$60,
    # saved $40 -- both boundary workers now reprice at their nearest
    # epoch instead of falling outside every epoch.
    WORKER_LINE=$(echo "$output" | grep '^worker')
    read -r -a WL <<< "$WORKER_LINE"
    [ "${WL[6]}" = '$20' ]
    [ "${WL[7]}" = '$60' ]
    [ "${WL[8]}" = '$40' ]
}

@test "cost-mirror: no-tier-change session with real timestamps still matches the pre-epoch dollar clause exactly" {
    # The compatibility guarantee ("a session that never changed model
    # must produce EXACTLY today's number") holds with real per-row
    # timestamps too, not just the NA-bucket no-timestamp fallback other
    # fixtures exercise — a single main-loop model forms exactly one
    # epoch regardless, so the epoch-aware math reduces to the old one.
    TP="$BATS_TEST_TMPDIR/proj-notierchange/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-notierchange"
    {
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-fable-5","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":400000,"ephemeral_1h_input_tokens":100000}}}}\n'
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:01:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":2000000,"output_tokens":200000}}}\n'
    } > "$TP"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"~\$26 · ~\$53 at fable-5 → saved ~\$27"* ]]
}

@test "cost-mirror: worker rows with no main rows at all — no epochs, no savings claimed" {
    TP="$BATS_TEST_TMPDIR/proj-workeronly/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-workeronly"
    printf '{"isSidechain":true,"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n' > "$TP"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"workers: 1.0M out (haiku-4-5-20251001)"* ]]
    [[ "$output" == *"~\$5.00"* ]]
    [[ "$output" != *"saved"* ]]

    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    WORKER_LINE=$(echo "$output" | grep '^worker')
    read -r -a WL <<< "$WORKER_LINE"
    [ "${WL[6]}" = '$5.00' ]
    [ "${WL[7]}" = '$5.00' ]
    [ "${WL[8]}" = '$0.00' ]
}

@test "cost-mirror: missing or unparseable timestamp does not crash, falls back to the shared NA bucket" {
    TP="$BATS_TEST_TMPDIR/proj-badts/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-badts"
    {
        printf '{"timestamp":"not-a-real-date","message":{"model":"claude-fable-5","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":400000,"ephemeral_1h_input_tokens":100000}}}}\n'
        printf '{"isSidechain":true,"message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":2000000,"output_tokens":200000}}}\n'
    } > "$TP"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    # same token profile as mk_pricing_transcript (fable-5 main + haiku
    # worker) -- one row's timestamp is a garbage string, the other has
    # none at all; both must land in NA_BUCKET without crashing and
    # reduce to the single-epoch/whole-session math, same $26/$53/$27.
    [[ "$output" == *"~\$26 · ~\$53 at fable-5 → saved ~\$27"* ]]
}

@test "cost-mirror: rows out of chronological order (clock skew) still epoch correctly — buckets are sorted, not scan order" {
    TP="$BATS_TEST_TMPDIR/proj-skew/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-skew"
    {
        # the haiku-4-5 main row is WRITTEN FIRST even though its own
        # timestamp is LATER than the opus-5 row below it — simulates a
        # backwards system-clock jump or two interleaved writers.
        printf '{"timestamp":"2026-07-29T00:10:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-opus-5","usage":{"output_tokens":1000000}}}\n'
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:01:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:11:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
    } > "$TP"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    # same epochs (opus-5 [00:00,00:10), haiku-4-5 [00:10,...)) as if the
    # file were written in chronological order: worker@00:01 still
    # reprices at opus-5 (saved $20), worker@00:11 still at haiku-4-5
    # (saved $0) — main $25+$5, worker $5+$5=$10 actual, $25+$5=$30 at-top
    [[ "$output" == *"~\$40 · ~\$60 at opus-5 → saved ~\$20"* ]]
}

@test "cost-mirror: single-model session with workers before the first and after the last main row matches the pre-epoch method byte-for-byte" {
    # The compatibility guarantee (module docstring / defect-1 fix): a
    # session that never changed its main-loop model must produce the
    # EXACT figure the old whole-session "reprice everything at the one
    # top model" method produced -- including for workers timestamped
    # entirely outside the main-loop's own bucket span. Before the fix,
    # _epochs_from_main_buckets built epochs spanning only [first main
    # bucket, last main bucket + 1), so these two boundary workers fell
    # in no epoch and contributed $0 to "saved" -- breaking the guarantee
    # (verified: this exact fixture reported saved $0.00 pre-fix, vs the
    # $54 below post-fix and under the true pre-epoch method alike).
    TP="$BATS_TEST_TMPDIR/proj-nt4/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-nt4"
    {
        # worker BEFORE the only main row
        printf '{"isSidechain":true,"timestamp":"2026-07-28T23:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":2000000,"output_tokens":200000}}}\n'
        # the only main row (fable-5) -- same profile as mk_pricing_transcript,
        # actual $23 (see that fixture's comment for the hand-computation)
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-fable-5","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":400000,"ephemeral_1h_input_tokens":100000}}}}\n'
        # worker AFTER the only main row
        printf '{"isSidechain":true,"timestamp":"2026-07-29T01:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":2000000,"output_tokens":200000}}}\n'
    } > "$TP"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    # main $23 + two workers at $3 each = $29 actual; both workers reprice
    # at fable-5 ($30 apiece) same as the old single-top method would ->
    # at-top $23+30+30=$83, saved $54 (NOT $0 -- the pre-fix bug's figure).
    [[ "$output" == *"~\$29 · ~\$83 at fable-5 → saved ~\$54"* ]]
    [[ "$output" != *"saved ~\$0"* ]]

    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    TOTAL_LINE=$(echo "$output" | grep '^TOTAL')
    read -r -a F <<< "$TOTAL_LINE"
    [ "${F[5]}" = '$29' ]
    [ "${F[6]}" = '$83' ]
    [ "${F[7]}" = '$54' ]
}

@test "cost-mirror: mutation kill (M1) — a bucket mixing two main-loop models with zero worker rows never shows main-loop spend as saved" {
    # M1 mutant: delete the main-row pin at session_epoch_pricing's
    # `if side == "main": d["at_epoch"] += actual; continue`. Two main
    # rows share one 5-minute bucket (a genuine tier change inside one
    # window), so pick_top_model resolves the bucket's epoch to opus-5
    # (pricier) -- WITHOUT the pin, the losing haiku-4-5 main row would
    # fall through to the epoch lookup too and reprice at opus-5's rate,
    # surfacing main-loop spend as fake "saved" ($0.50 actual repriced to
    # $2.50, saved $2.00) -- exactly what the pin forbids. No worker rows
    # at all, so this isolates the pin from epoch-boundary/worker logic.
    TP="$BATS_TEST_TMPDIR/proj-m1/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-m1"
    {
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":100000}}}\n'
        printf '{"timestamp":"2026-07-29T00:01:00Z","message":{"model":"claude-opus-5","usage":{"output_tokens":100000}}}\n'
    } > "$TP"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    MAIN_HAIKU_LINE=$(echo "$output" | grep '^main.*haiku')
    read -r -a MH <<< "$MAIN_HAIKU_LINE"
    [ "${MH[6]}" = '$0.50' ]
    [ "${MH[7]}" = '$0.50' ]
    [ "${MH[8]}" = '$0.00' ]
    MAIN_OPUS_LINE=$(echo "$output" | grep '^main.*opus')
    read -r -a MO <<< "$MAIN_OPUS_LINE"
    [ "${MO[6]}" = '$2.50' ]
    [ "${MO[7]}" = '$2.50' ]
    [ "${MO[8]}" = '$0.00' ]
    TOTAL_LINE=$(echo "$output" | grep '^TOTAL')
    read -r -a F <<< "$TOTAL_LINE"
    [ "${F[5]}" = '$3.00' ]
    [ "${F[6]}" = '$3.00' ]
    [ "${F[7]}" = '$0.00' ]
}

@test "cost-mirror: mutation kill (M3) — epochs are built from buckets in ascending order, not scan/arrival order" {
    # M3 mutant: replace `for bucket in sorted(by_bucket)` with plain
    # `for bucket in by_bucket` (dict/arrival order). File order here is
    # bucket10=opus-5, bucket0=haiku-4-5, bucket5=sonnet-5 -- i.e. written
    # out of chronological order -- with a worker at bucket7 (interior,
    # between the sonnet-5 and opus-5 main rows). Correctly sorted, the
    # worker's bucket falls in the opus-5 epoch (the true last epoch,
    # extended forward by the defect-1 clamp) -> saved $20. Built in scan
    # order instead, the opus-5@bucket10 row ends up misplaced first in
    # the epoch list and gets folded into a dead/empty range, so the
    # clamp instead extends the WRONG (sonnet-5) epoch forward -> saved
    # only $5 -- a materially different, wrong answer that test 55's
    # existing fixture doesn't catch (see M3 in the defect writeup).
    TP="$BATS_TEST_TMPDIR/proj-m3/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-m3"
    {
        printf '{"timestamp":"2026-07-29T00:50:00Z","message":{"model":"claude-opus-5","usage":{"output_tokens":1000000}}}\n'
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
        printf '{"timestamp":"2026-07-29T00:25:00Z","message":{"model":"claude-sonnet-5","usage":{"output_tokens":1000000}}}\n'
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:55:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
    } > "$TP"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    WORKER_LINE=$(echo "$output" | grep '^worker')
    read -r -a WL <<< "$WORKER_LINE"
    [ "${WL[6]}" = '$5.00' ]
    [ "${WL[7]}" = '$25' ]
    [ "${WL[8]}" = '$20' ]
    TOTAL_LINE=$(echo "$output" | grep '^TOTAL')
    read -r -a F <<< "$TOTAL_LINE"
    [ "${F[5]}" = '$45' ]
    [ "${F[6]}" = '$65' ]
    [ "${F[7]}" = '$20' ]
}

@test "cost-mirror: negative savings — a worker pricier than its epoch's orchestrator is NOT clamped to zero" {
    # A worker on a pricier model than the main-loop tier at the time
    # (e.g. escalating to fable-5 for a hard problem while the
    # orchestrator itself runs haiku-4-5) must show a genuine NEGATIVE
    # "saved" -- that IS the true cost of that choice, and clamping it to
    # zero would hide it. fmt_usd renders the sign, never absorbs it.
    TP="$BATS_TEST_TMPDIR/proj-negsave/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-negsave"
    {
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:01:00Z","message":{"model":"claude-fable-5","usage":{"output_tokens":10000}}}\n'
    } > "$TP"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"saved ~-\$0.45"* ]]

    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    WORKER_LINE=$(echo "$output" | grep '^worker')
    read -r -a WL <<< "$WORKER_LINE"
    [ "${WL[6]}" = '$0.50' ]
    [ "${WL[7]}" = '$0.05' ]
    [ "${WL[8]}" = '-$0.45' ]
}

@test "cost-mirror --report --all: sessions overlapping in real time never reprice each other, even sharing a 5-minute bucket" {
    # sess-a and sess-b use the IDENTICAL timestamps below, so if the two
    # sessions' bucketed rows were ever merged before epochs are computed,
    # this shared bucket would contain BOTH main models and resolve to
    # opus-5 (pricier) for both sessions — reproducing exactly the
    # cross-session leak the per-session epoch computation must prevent.
    ALLDIR="$BATS_TEST_TMPDIR/allprojects-ts"
    mkdir -p "$ALLDIR/proj-a" "$ALLDIR/proj-b"
    {
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-opus-5","usage":{"output_tokens":1000000}}}\n'
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:01:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
    } > "$ALLDIR/proj-a/sess-a.jsonl"
    {
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:01:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
    } > "$ALLDIR/proj-b/sess-b.jsonl"
    export COST_MIRROR_PROJECTS_DIR="$ALLDIR"

    # sess-a: main opus-5 tier -> worker (haiku-4-5) genuinely saved $20
    # (25-5) by delegating instead of running that work on opus-5.
    # sess-b: main was ALREADY haiku-4-5 the whole time -> its haiku-4-5
    # worker saves $0 (already at that tier) — UNLESS wrongly repriced at
    # sess-a's opus-5, which would ALSO show a fake $20.
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    TOTAL_LINE=$(echo "$output" | grep '^TOTAL')
    read -r -a F <<< "$TOTAL_LINE"
    [ "${F[7]}" = '$20' ]
    [ "${F[7]}" != '$40' ]
}

# ── cost-mirror: delegation-gate drift segment ─────────────────────────────
#
# delegation-gate.py persists {"max_streak","warns","denies"} per session at
# ~/.claude/cache/delegation-gate/<session_id>.json (see its own module
# docstring). cost-mirror appends a short " | inline: ..." clause read from
# that file, resolving session_id from its own hook event the same way
# delegation-gate reads it from its PreToolUse payload -- a plain top-level
# "session_id" field. These tests override HOME (unlike the rest of this
# file, which never touches it) because that's the only path delegation-gate
# state lives under; each test sets it locally so no other test is affected.

dg_state_file() {
    echo "$HOME/.claude/cache/delegation-gate/$1.json"
}

@test "cost-mirror: drift segment absent when the delegation-gate state file is missing" {
    export HOME="$BATS_TEST_TMPDIR/home-dg1"
    mkdir -p "$HOME"
    mk_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\",\"session_id\":\"nofile\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" != *"inline:"* ]]
}

@test "cost-mirror: drift segment absent when max_streak/warns/denies are all zero" {
    export HOME="$BATS_TEST_TMPDIR/home-dg2"
    mkdir -p "$HOME/.claude/cache/delegation-gate"
    printf '{"streak":0,"warned_at":0,"max_streak":0,"warns":0,"denies":0}' > "$(dg_state_file zeros)"
    mk_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\",\"session_id\":\"zeros\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" != *"inline:"* ]]
}

@test "cost-mirror: drift segment present and pluralised (3 warns, 1 deny)" {
    export HOME="$BATS_TEST_TMPDIR/home-dg3"
    mkdir -p "$HOME/.claude/cache/delegation-gate"
    printf '{"streak":5,"warned_at":5,"max_streak":12,"warns":3,"denies":1}' > "$(dg_state_file plural)"
    mk_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\",\"session_id\":\"plural\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"| inline: max streak 12 · 3 warns · 1 deny"* ]]
}

@test "cost-mirror: drift segment singularises 1 warn and 2 pluralises denies" {
    export HOME="$BATS_TEST_TMPDIR/home-dg4"
    mkdir -p "$HOME/.claude/cache/delegation-gate"
    printf '{"streak":1,"warned_at":1,"max_streak":4,"warns":1,"denies":2}' > "$(dg_state_file singular)"
    mk_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\",\"session_id\":\"singular\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"| inline: max streak 4 · 1 warn · 2 denies"* ]]
}

@test "cost-mirror: drift segment shows max streak alone when there were no warns or denies (e.g. mode=off)" {
    export HOME="$BATS_TEST_TMPDIR/home-dg5"
    mkdir -p "$HOME/.claude/cache/delegation-gate"
    printf '{"streak":6,"warned_at":0,"max_streak":6,"warns":0,"denies":0}' > "$(dg_state_file streakonly)"
    mk_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\",\"session_id\":\"streakonly\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"| inline: max streak 6"* ]]
    [[ "$output" != *"warn"* ]]
}

@test "cost-mirror: malformed delegation-gate state file does not break the cost line" {
    export HOME="$BATS_TEST_TMPDIR/home-dg6"
    mkdir -p "$HOME/.claude/cache/delegation-gate"
    printf 'NOT JSON AT ALL' > "$(dg_state_file broken)"
    mk_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\",\"session_id\":\"broken\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[cost-mirror] this session"* ]]
    [[ "$output" != *"inline:"* ]]
}

@test "cost-mirror: no session_id in the event omits the drift segment without erroring" {
    export HOME="$BATS_TEST_TMPDIR/home-dg7"
    mkdir -p "$HOME/.claude/cache/delegation-gate"
    printf '{"max_streak":9,"warns":2,"denies":0}' > "$(dg_state_file orphan)"
    mk_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[cost-mirror] this session"* ]]
    [[ "$output" != *"inline:"* ]]
}
