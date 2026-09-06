#!/usr/bin/env bats
#
# S4 acceptance contract (claude-orca-3sk.4) -- FROZEN from RED-AT onward.
# Exercises scripts/tier-derive.sh (ported unchanged -- the ladder), and the
# new tier.json-based scripts/tier-{set,gate,prime,reconcile}.sh that
# replace the old frontmatter-rewriting design (agents/*.md is write-denied
# inside the sandbox -- see .claude/plans/orca-port.md S3.1, S3.6, and
# scripts/tier-set.sh's own header). No Docker, no network, no bootstrap;
# each script is exercised directly against scratch CLAUDE_ORCA_ROOT/
# CLAUDE_CONFIG_DIR fixtures -- never the real ~/.claude.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

DERIVE="$REPO_ROOT/scripts/tier-derive.sh"
TSET="$REPO_ROOT/scripts/tier-set.sh"
GATE="$REPO_ROOT/scripts/tier-gate.sh"
PRIME="$REPO_ROOT/scripts/tier-prime.sh"
RECON="$REPO_ROOT/scripts/tier-reconcile.sh"

setup() {
    export CLAUDE_ORCA_ROOT="$BATS_TEST_TMPDIR/root"
    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/root/.claude"
    # V2c (claude-orca-qt9.7): tier.json moved to the agent-writable
    # .claude-dev/run -- tier-set runs INSIDE the sandbox, and state/ is
    # write-denied there.
    mkdir -p "$CLAUDE_ORCA_ROOT/.claude-dev/run" "$CLAUDE_CONFIG_DIR/agents"
    STATE_FILE="$CLAUDE_ORCA_ROOT/.claude-dev/run/tier.json"
    LOCAL_SETTINGS="$CLAUDE_CONFIG_DIR/settings.local.json"
    BASE_SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
}

tier_set() { run "$TSET" "$@"; }
gate() { run "$GATE" <<<"$1"; }              # gate '<json>' -- pipes $1 to tier-gate
prime() { run "$PRIME"; }
reconcile() { run "$RECON" </dev/null; }      # no stdin payload (SessionStart shape)
reconcile_with() { run "$RECON" <<<"$1"; }    # reconcile_with '<json>' (PostModelSwitch/ConfigChange shape)

# ── tier-derive (ported unchanged -- pure ladder function) ──────────────────

@test "tier-derive --overdrive: lifts the worker to the top per rung, recon stays derived from the capped worker" {
    run "$DERIVE" --overdrive fable
    [ "$output" = "claude-fable-5 claude-fable-5 claude-haiku-4-5-20251001" ]
    run "$DERIVE" --overdrive opus
    [ "$output" = "claude-opus-5 claude-opus-5 claude-haiku-4-5-20251001" ]
    run "$DERIVE" --overdrive sonnet
    [ "$output" = "claude-sonnet-5 claude-sonnet-5 claude-haiku-4-5-20251001" ]
    # the bottom rung has nothing to lift: overdrive changes nothing
    run "$DERIVE" --overdrive haiku
    [ "$output" = "claude-haiku-4-5-20251001 claude-haiku-4-5-20251001 claude-haiku-4-5-20251001" ]
}

@test "tier-derive --overdrive: a dated or [variant] top keeps its EXACT value in both the top and worker slots" {
    run "$DERIVE" --overdrive claude-opus-4-8-20260101
    [ "$output" = "claude-opus-4-8-20260101 claude-opus-4-8-20260101 claude-haiku-4-5-20251001" ]
    run "$DERIVE" --overdrive 'sonnet[1m]'
    [ "$output" = "sonnet[1m] sonnet[1m] claude-haiku-4-5-20251001" ]
}

@test "tier-derive --overdrive: an off-ladder top still exits 3 with no output" {
    run "$DERIVE" --overdrive gpt-5
    [ "$status" -eq 3 ]
    [ -z "$output" ]
}

@test "tier-derive --overdrive: no model argument is a usage error naming the flag" {
    run "$DERIVE" --overdrive
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: tier-derive"* ]]
    [[ "$output" == *"--overdrive"* ]]
}

@test "tier-derive: plain (no flag) derivation is byte-identical to the capped ladder" {
    run "$DERIVE" fable
    [ "$output" = "claude-fable-5 claude-sonnet-5 claude-haiku-4-5-20251001" ]
    run "$DERIVE" opus
    [ "$output" = "claude-opus-5 claude-sonnet-5 claude-haiku-4-5-20251001" ]
    run "$DERIVE" sonnet
    [ "$output" = "claude-sonnet-5 claude-haiku-4-5-20251001 claude-haiku-4-5-20251001" ]
    run "$DERIVE" haiku
    [ "$output" = "claude-haiku-4-5-20251001 claude-haiku-4-5-20251001 claude-haiku-4-5-20251001" ]
    run "$DERIVE" claude-opus-4-8-20260101
    [ "$output" = "claude-opus-4-8-20260101 claude-sonnet-5 claude-haiku-4-5-20251001" ]
    run "$DERIVE" gpt-5
    [ "$status" -eq 3 ]
    [ -z "$output" ]
}

@test "tier-derive: --rank and --name are unaffected by the overdrive flag's existence" {
    run "$DERIVE" --rank fable
    [ "$output" = "4" ]
    run "$DERIVE" --rank gpt-5
    [ "$output" = "0" ]
    run "$DERIVE" --name opus
    [ "$output" = "Opus 5" ]
    run "$DERIVE" --name gpt-5
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# ── tier-set (writes tier.json; never agents/*.md) ──────────────────────────

@test "tier-set writes tier.json and never touches agents/*.md" {
    printf -- '---\nname: executor\nmodel: sonnet\n---\nDo the slice.\n' > "$CLAUDE_CONFIG_DIR/agents/executor.md"
    printf -- '---\nname: scout\nmodel: haiku\n---\nGo look.\n' > "$CLAUDE_CONFIG_DIR/agents/scout.md"
    before_exec="$(cat "$CLAUDE_CONFIG_DIR/agents/executor.md")"
    before_scout="$(cat "$CLAUDE_CONFIG_DIR/agents/scout.md")"

    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]

    run jq -e '.top == "claude-fable-5" and .worker == "claude-sonnet-5" and .recon == "claude-haiku-4-5-20251001" and .pinned == false and .overdrive == false' "$STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -r '.updated' "$STATE_FILE"
    [[ "$output" == *T*Z ]]

    # agents/*.md are byte-identical to before -- tier-set never opens them
    [ "$(cat "$CLAUDE_CONFIG_DIR/agents/executor.md")" = "$before_exec" ]
    [ "$(cat "$CLAUDE_CONFIG_DIR/agents/scout.md")" = "$before_scout" ]
}

@test "tier-set <top>: merges .model into settings.local.json without clobbering other keys" {
    printf '{"otherKey":"keepme"}\n' > "$LOCAL_SETTINGS"
    TIER_DERIVE="$DERIVE" tier_set opus
    [ "$status" -eq 0 ]
    run jq -e '.model == "claude-opus-5" and .otherKey == "keepme"' "$LOCAL_SETTINGS"
    [ "$status" -eq 0 ]
}

@test "tier-set <top> <worker> [<recon>]: pins explicitly, recon shares worker on the 2-arg form" {
    TIER_DERIVE="$DERIVE" tier_set opus haiku
    [ "$status" -eq 0 ]
    run jq -e '.top == "claude-opus-5" and .worker == "claude-haiku-4-5-20251001" and .recon == "claude-haiku-4-5-20251001" and .pinned == true' "$STATE_FILE"
    [ "$status" -eq 0 ]

    TIER_DERIVE="$DERIVE" tier_set opus sonnet haiku
    [ "$status" -eq 0 ]
    run jq -e '.worker == "claude-sonnet-5" and .recon == "claude-haiku-4-5-20251001" and .pinned == true' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier-set overdrive: lifts the worker to the top, recon stays derived from the capped worker, sets overdrive" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set overdrive
    [ "$status" -eq 0 ]
    run jq -e '.top == "claude-fable-5" and .worker == "claude-fable-5" and .recon == "claude-haiku-4-5-20251001" and .overdrive == true and .pinned == false' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier-set overdrive: an off-ladder top refuses and leaves tier.json untouched" {
    TIER_DERIVE="$DERIVE" tier_set opus
    # Simulate an off-ladder top having been bound (e.g. by a custom /model).
    jq '.top = "my-custom-router"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    before="$(cat "$STATE_FILE")"
    TIER_DERIVE="$DERIVE" tier_set overdrive
    [ "$status" -eq 1 ]
    [ "$(cat "$STATE_FILE")" = "$before" ]

    # And with no top bound at all, it refuses rather than guessing one.
    rm -f "$STATE_FILE"
    TIER_DERIVE="$DERIVE" tier_set overdrive
    [ "$status" -eq 1 ]
    [ ! -f "$STATE_FILE" ]
}

@test "tier-set show: an unbound project prints a clear message; a bound one prints the trio and flags" {
    tier_set show
    [ "$status" -eq 0 ]
    [[ "$output" == *"no tier bound yet"* ]]

    TIER_DERIVE="$DERIVE" tier_set opus haiku
    tier_set show
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-opus-5"* ]]
    [[ "$output" == *"claude-haiku-4-5-20251001"* ]]
    [[ "$output" == *"pin"* ]] || [[ "$output" == *"PIN"* ]]
}

@test "tier-set: rejects an unsafe/unknown single argument without binding anything" {
    tier_set 'not a model!'
    [ "$status" -ne 0 ]
    [ ! -f "$STATE_FILE" ]
}

# ── tier-gate (PreToolUse[Agent]; reads tier.json) ──────────────────────────

seed_state() {  # seed_state <worker> <recon> -- a bound, unpinned, non-overdrive tier.json
    jq -n --arg w "$1" --arg c "$2" '{top:"claude-fable-5", worker:$w, recon:$c, pinned:false, overdrive:false, updated:"2026-01-01T00:00:00Z"}' > "$STATE_FILE"
}

@test "tier-gate injects the worker model for executor spawns and the recon model for scout spawns when model is omitted, and leaves explicit models alone" {
    seed_state claude-sonnet-5 claude-haiku-4-5-20251001

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p","description":"d"}}'
    [ "$status" -eq 0 ]
    exec_out="$output"   # save before the next `run` overwrites $output/$status
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$exec_out"
    [ "$status" -eq 0 ]
    # original tool_input fields survive the rewrite; systemMessage names it
    run jq -e '.hookSpecificOutput.updatedInput.prompt == "p" and .hookSpecificOutput.updatedInput.description == "d"' <<<"$exec_out"
    [ "$status" -eq 0 ]
    run jq -e '.systemMessage | test("tier-gate")' <<<"$exec_out"
    [ "$status" -eq 0 ]
    run jq -r '.hookSpecificOutput.hookEventName' <<<"$exec_out"
    [ "$output" = "PreToolUse" ]

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "haiku"' <<<"$output"
    [ "$status" -eq 0 ]

    # explicit model always wins, on either type
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","model":"opus","prompt":"p"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","model":"opus","prompt":"p"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "tier-gate: named roles (verifier, oracle, professor, bead-auditor) are never touched" {
    seed_state claude-sonnet-5 claude-haiku-4-5-20251001
    for role in verifier oracle professor bead-auditor; do
        gate '{"tool_name":"Agent","tool_input":{"subagent_type":"'"$role"'","prompt":"p"}}'
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
}

@test "tier-gate: a bare spawn with no subagent_type is generic and gets the worker default" {
    seed_state claude-sonnet-5 claude-haiku-4-5-20251001
    gate '{"tool_name":"Agent","tool_input":{"prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "tier-gate: spawns inside a subagent are left alone" {
    seed_state claude-sonnet-5 claude-haiku-4-5-20251001
    gate '{"tool_name":"Agent","transcript_path":"/p/s/subagents/agent-1.jsonl","tool_input":{"prompt":"p"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "tier-gate: malformed input and non-Agent tools fail open" {
    gate 'NOT JSON'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    gate '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "tier-gate: an unrankable/off-ladder worker in tier.json fails open (no injection, no error)" {
    seed_state my-custom-router claude-haiku-4-5-20251001
    gate '{"tool_name":"Agent","tool_input":{"prompt":"p"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "tier-gate: falls back to deriving from settings .model when tier.json is absent" {
    [ ! -f "$STATE_FILE" ]
    printf '{"model":"claude-fable-5"}\n' > "$BASE_SETTINGS"
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "tier-gate: injected tier is read from tier.json at runtime, never hardcoded" {
    seed_state claude-haiku-4-5-20251001 claude-haiku-4-5-20251001
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    run jq -e '.hookSpecificOutput.updatedInput.model == "haiku"' <<<"$output"
    [ "$status" -eq 0 ]

    seed_state claude-opus-5 claude-sonnet-5
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    run jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$output"
    [ "$status" -eq 0 ]
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p"}}'
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$output"
    [ "$status" -eq 0 ]
}

# ── tier-prime (SessionStart; reads tier.json) ──────────────────────────────

@test "tier-prime prints the trio from tier.json" {
    seed_state claude-sonnet-5 claude-haiku-4-5-20251001
    jq '.top = "claude-fable-5"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    prime
    [ "$status" -eq 0 ]
    [[ "$output" == *"orchestrator=claude-fable-5"* ]]
    [[ "$output" == *"worker=claude-sonnet-5"* ]]
    [[ "$output" == *"recon=claude-haiku-4-5-20251001"* ]]
}

@test "tier-prime states OVERDRIVE and PIN flags when set, and neither when unset" {
    seed_state claude-sonnet-5 claude-haiku-4-5-20251001
    prime
    [[ "$output" != *OVERDRIVE* ]]
    [[ "$output" != *PIN* ]]

    jq '.overdrive = true' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    prime
    [[ "$output" == *OVERDRIVE* ]]

    jq '.overdrive = false | .pinned = true' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    prime
    [[ "$output" == *PIN* ]]
    [[ "$output" != *OVERDRIVE* ]]

    # an unbound project (no tier.json) still exits 0, with an <unbound> fallback
    rm -f "$STATE_FILE"
    prime
    [ "$status" -eq 0 ]
    [[ "$output" == *"<unbound>"* ]]
}

# ── tier-reconcile (SessionStart/PostModelSwitch/ConfigChange) ──────────────

@test "tier-reconcile: re-derives tier.json's worker/recon from settings .model unless pinned" {
    printf '{"model":"claude-fable-5"}\n' > "$LOCAL_SETTINGS"
    reconcile
    [ "$status" -eq 0 ]
    run jq -e '.top == "claude-fable-5" and .worker == "claude-sonnet-5" and .recon == "claude-haiku-4-5-20251001"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # pinned: left exactly as it is, even though .model disagrees
    jq '.pinned = true | .worker = "claude-haiku-4-5-20251001"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    printf '{"model":"claude-opus-5"}\n' > "$LOCAL_SETTINGS"
    reconcile
    [ "$status" -eq 0 ]
    run jq -e '.worker == "claude-haiku-4-5-20251001"' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier-reconcile: purges legacy ANTHROPIC_DEFAULT_*/CLAUDE_CODE_SUBAGENT_MODEL vars from settings.local.json" {
    jq -n '{model:"claude-sonnet-5", env:{ANTHROPIC_DEFAULT_OPUS_MODEL:"x", CLAUDE_CODE_SUBAGENT_MODEL:"y", KEEP_ME:"z"}}' > "$LOCAL_SETTINGS"
    reconcile
    [ "$status" -eq 0 ]
    run jq -e '(.env | has("ANTHROPIC_DEFAULT_OPUS_MODEL") | not) and (.env | has("CLAUDE_CODE_SUBAGENT_MODEL") | not) and .env.KEEP_ME == "z"' "$LOCAL_SETTINGS"
    [ "$status" -eq 0 ]
}

@test "tier-reconcile: a to_model field on PostModelSwitch stdin is preferred, and is still pin-aware" {
    printf '{"model":"claude-sonnet-5"}\n' > "$LOCAL_SETTINGS"
    reconcile_with '{"to_model":"claude-fable-5"}'
    [ "$status" -eq 0 ]
    run jq -e '.top == "claude-fable-5" and .worker == "claude-sonnet-5"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    jq '.pinned = true' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    reconcile_with '{"to_model":"claude-opus-5"}'
    [ "$status" -eq 0 ]
    run jq -e '.top == "claude-fable-5"' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier-reconcile: overdrive re-applies every run, following a /model change" {
    printf '{"model":"claude-fable-5"}\n' > "$LOCAL_SETTINGS"
    reconcile
    jq '.overdrive = true' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    reconcile
    run jq -e '.worker == "claude-fable-5"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    printf '{"model":"claude-opus-5"}\n' > "$LOCAL_SETTINGS"
    reconcile
    [ "$status" -eq 0 ]
    run jq -e '.top == "claude-opus-5" and .worker == "claude-opus-5" and .overdrive == true' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier-reconcile: empty/non-JSON stdin and an off-ladder .model are all silent no-ops that never error" {
    printf '{"model":"claude-fable-5"}\n' > "$LOCAL_SETTINGS"
    reconcile
    before="$(cat "$STATE_FILE")"

    run bash -c "printf 'NOT JSON' | '$RECON'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$STATE_FILE")" = "$before" ]

    printf '{"model":"my-custom-router"}\n' > "$LOCAL_SETTINGS"
    reconcile
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE_FILE")" = "$before" ]
}

# ── tier v2: a backend per role (claude-orca-qa2.12) ────────────────────────

@test "tier.json v2 carries backend, agent and model per role and a v1 file reads as subagent backend" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]

    # the v1 keys stay exactly what they were -- the model id per role ...
    run jq -e '.worker == "claude-sonnet-5" and .recon == "claude-haiku-4-5-20251001"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    # ... and .roles carries backend + agent + model for all three roles.
    run jq -e '.roles.worker | .backend == "subagent" and .agent == "claude" and .model == "claude-sonnet-5"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon | .backend == "subagent" and .agent == "claude" and .model == "claude-haiku-4-5-20251001"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.checker | .backend == "subagent" and .agent == "claude" and .model == "inherit"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # a v1 file (no .roles block at all) reads as the subagent backend
    seed_state claude-sonnet-5 claude-haiku-4-5-20251001
    run jq -e 'has("roles") | not' "$STATE_FILE"
    [ "$status" -eq 0 ]
    prime
    [ "$status" -eq 0 ]
    [[ "$output" == *"worker=subagent:claude-sonnet-5"* ]]
    [[ "$output" == *"recon=subagent:claude-haiku-4-5-20251001"* ]]
    [[ "$output" == *"checker=subagent:inherit"* ]]
}

@test "tier-set binds worker openrouter:<vendor/model> to the orca backend with agent opencode and claude: to agent claude" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]

    TIER_DERIVE="$DERIVE" tier_set worker openrouter:qwen/qwen3-coder
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker | .backend == "orca" and .agent == "opencode" and .model == "openrouter/qwen/qwen3-coder"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    # the v1 mirror follows the role's model; the other roles are untouched
    run jq -e '.worker == "openrouter/qwen/qwen3-coder" and .roles.recon.backend == "subagent"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    TIER_DERIVE="$DERIVE" tier_set worker claude:sonnet
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker | .backend == "orca" and .agent == "claude" and .model == "claude-sonnet-5"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # `subagent` puts the worker back in-process on the DERIVED model
    TIER_DERIVE="$DERIVE" tier_set worker subagent
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker | .backend == "subagent" and .agent == "claude" and .model == "claude-sonnet-5"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.worker == "claude-sonnet-5"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # the same grammar on the recon and checker roles
    TIER_DERIVE="$DERIVE" tier_set recon openrouter:qwen/qwen3-coder
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon | .backend == "orca" and .agent == "opencode" and .model == "openrouter/qwen/qwen3-coder"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set checker claude:opus
    [ "$status" -eq 0 ]
    run jq -e '.roles.checker | .backend == "orca" and .agent == "claude" and .model == "claude-opus-5"' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier-prime prints the backend per role" {
    TIER_DERIVE="$DERIVE" tier_set fable
    TIER_DERIVE="$DERIVE" tier_set worker openrouter:qwen/qwen3-coder
    prime
    [ "$status" -eq 0 ]
    [[ "$output" == *"worker=orca:opencode:openrouter/qwen/qwen3-coder"* ]]
    [[ "$output" == *"recon=subagent:claude-haiku-4-5-20251001"* ]]
    [[ "$output" == *"checker=subagent:inherit"* ]]
    # the orchestrator line is still printed
    [[ "$output" == *"orchestrator=claude-fable-5"* ]]
}

@test "tier-gate still injects the worker model into generic Agent spawns and leaves named roles alone" {
    seed_state claude-sonnet-5 claude-haiku-4-5-20251001
    gate '{"tool_name":"Agent","tool_input":{"prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$output"
    [ "$status" -eq 0 ]

    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"verifier","prompt":"p"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # an orca-backed worker: the spawn is still ALLOWED, with one note and no
    # model injection (the orchestrator should have used orca-dispatch)
    TIER_DERIVE="$DERIVE" tier_set fable
    TIER_DERIVE="$DERIVE" tier_set worker openrouter:qwen/qwen3-coder
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    [ "$status" -eq 0 ]
    orca_out="$output"
    run jq -e '.systemMessage | test("orca")' <<<"$orca_out"
    [ "$status" -eq 0 ]
    run jq -e 'has("hookSpecificOutput") | not' <<<"$orca_out"
    [ "$status" -eq 0 ]

    # back on the subagent backend, injection is exactly as before
    TIER_DERIVE="$DERIVE" tier_set worker subagent
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$output"
    [ "$status" -eq 0 ]
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p"}}'
    run jq -e '.hookSpecificOutput.updatedInput.model == "haiku"' <<<"$output"
    [ "$status" -eq 0 ]
}

# ── bash 3.2 exercise ────────────────────────────────────────────────────────

@test "tier-set, tier-gate and tier-prime run cleanly under bash 3.2" {
    require_bash32() {
        [ -n "${BASH32:-}" ] && return 0
        . "$BATS_TEST_DIRNAME/helpers/ensure_bash32"
    }
    require_bash32

    run "$BASH32" "$TSET" opus
    [ "$status" -eq 0 ]
    run jq -e '.top == "claude-opus-5"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    run "$BASH32" "$PRIME"
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-opus-5"* ]]

    run "$BASH32" "$GATE" <<<'{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$output"
    [ "$status" -eq 0 ]
}
