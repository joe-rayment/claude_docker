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
    # claude-orca-qa2.20: the derived worker depends on whether an OpenRouter
    # key is present, so every case that pins the claude rung needs a box with
    # no key at all -- neither the env var nor the on-disk key file.
    unset OPENROUTER_API_KEY
    export TIER_OPENROUTER_KEY_FILE="$BATS_TEST_TMPDIR/no-such-openrouter.key"
    STATE_FILE="$CLAUDE_ORCA_ROOT/.claude-dev/run/tier.json"
    LOCAL_SETTINGS="$CLAUDE_CONFIG_DIR/settings.local.json"
    BASE_SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
}

tier_set() { run "$TSET" "$@"; }
gate() { TIER_GATE_DERIVE="$DERIVE" run "$GATE" <<<"$1"; }              # gate '<json>' -- pipes $1 to tier-gate, pinned to this repo's tier-derive (never PATH)
prime() { run "$PRIME"; }
reconcile() { run "$RECON" </dev/null; }      # no stdin payload (SessionStart shape)
reconcile_with() { run "$RECON" <<<"$1"; }    # reconcile_with '<json>' (PostModelSwitch/ConfigChange shape)

# ── tier-derive (ported unchanged -- pure ladder function) ──────────────────

@test "tier-derive --overdrive: lifts the worker to the top per rung, recon stays derived from the capped worker" {
    run "$DERIVE" --overdrive fable
    [ "$output" = "fable fable haiku" ]
    run "$DERIVE" --overdrive opus
    [ "$output" = "opus opus haiku" ]
    run "$DERIVE" --overdrive sonnet
    [ "$output" = "sonnet sonnet haiku" ]
    # the bottom rung has nothing to lift: overdrive changes nothing
    run "$DERIVE" --overdrive haiku
    [ "$output" = "haiku haiku haiku" ]
}

@test "tier-derive --overdrive: a dated or [variant] top keeps its EXACT value in both the top and worker slots" {
    run "$DERIVE" --overdrive claude-opus-4-8-20260101
    [ "$output" = "claude-opus-4-8-20260101 claude-opus-4-8-20260101 haiku" ]
    run "$DERIVE" --overdrive 'sonnet[1m]'
    [ "$output" = "sonnet[1m] sonnet[1m] haiku" ]
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
    [ "$output" = "fable sonnet haiku" ]
    run "$DERIVE" opus
    [ "$output" = "opus sonnet haiku" ]
    run "$DERIVE" sonnet
    [ "$output" = "sonnet haiku haiku" ]
    run "$DERIVE" haiku
    [ "$output" = "haiku haiku haiku" ]
    run "$DERIVE" claude-opus-4-8-20260101
    [ "$output" = "claude-opus-4-8-20260101 sonnet haiku" ]
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
    [ "$output" = "Opus" ]
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

    run jq -e '.top == "fable" and .worker == "sonnet" and .recon == "haiku" and .pinned == false and .overdrive == false' "$STATE_FILE"
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
    run jq -e '.model == "opus" and .otherKey == "keepme"' "$LOCAL_SETTINGS"
    [ "$status" -eq 0 ]
}

@test "tier-set <top> <worker> [<recon>]: pins explicitly, recon shares worker on the 2-arg form" {
    TIER_DERIVE="$DERIVE" tier_set opus haiku
    [ "$status" -eq 0 ]
    run jq -e '.top == "opus" and .worker == "haiku" and .recon == "haiku" and .pinned == true' "$STATE_FILE"
    [ "$status" -eq 0 ]

    TIER_DERIVE="$DERIVE" tier_set opus sonnet haiku
    [ "$status" -eq 0 ]
    run jq -e '.worker == "sonnet" and .recon == "haiku" and .pinned == true' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier-set overdrive: lifts the worker to the top, recon stays derived from the capped worker, sets overdrive" {
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set overdrive
    [ "$status" -eq 0 ]
    run jq -e '.top == "fable" and .worker == "fable" and .recon == "haiku" and .overdrive == true and .pinned == false' "$STATE_FILE"
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
    [[ "$output" == *"opus"* ]]
    [[ "$output" == *"haiku"* ]]
    [[ "$output" == *"pin"* ]] || [[ "$output" == *"PIN"* ]]
}

@test "tier-set: rejects an unsafe/unknown single argument without binding anything" {
    tier_set 'not a model!'
    [ "$status" -ne 0 ]
    [ ! -f "$STATE_FILE" ]
}

# ── tier-gate (PreToolUse[Agent]; reads tier.json) ──────────────────────────

seed_state() {  # seed_state <worker> <recon> -- a bound, unpinned, non-overdrive tier.json
    jq -n --arg w "$1" --arg c "$2" '{top:"fable", worker:$w, recon:$c, pinned:false, overdrive:false, updated:"2026-01-01T00:00:00Z"}' > "$STATE_FILE"
}

@test "tier-gate injects the worker model for executor spawns and the recon model for scout spawns when model is omitted, and leaves explicit models alone" {
    seed_state sonnet haiku

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
    seed_state sonnet haiku
    # claude-orca-8a0.2 split this set: verifier and bead-auditor GRADE, so
    # they take the checker rung (the top capped at opus -- seed_state's top
    # is fable); oracle and professor are consults and stay untouched. The
    # case name predates the split.
    for role in verifier bead-auditor; do
        TIER_GATE_DERIVE="$DERIVE" gate '{"tool_name":"Agent","tool_input":{"subagent_type":"'"$role"'","prompt":"p"}}'
        [ "$status" -eq 0 ]
        run jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$output"
        [ "$status" -eq 0 ]
    done
    for role in oracle professor; do
        TIER_GATE_DERIVE="$DERIVE" gate '{"tool_name":"Agent","tool_input":{"subagent_type":"'"$role"'","prompt":"p"}}'
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
}

@test "tier-gate: a bare spawn with no subagent_type is generic and gets the worker default" {
    seed_state sonnet haiku
    gate '{"tool_name":"Agent","tool_input":{"prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "tier-gate: spawns inside a subagent are left alone" {
    seed_state sonnet haiku
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
    seed_state my-custom-router haiku
    gate '{"tool_name":"Agent","tool_input":{"prompt":"p"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "tier-gate: falls back to deriving from settings .model when tier.json is absent" {
    [ ! -f "$STATE_FILE" ]
    printf '{"model":"fable"}\n' > "$BASE_SETTINGS"
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "tier-gate: injected tier is read from tier.json at runtime, never hardcoded" {
    seed_state haiku haiku
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    run jq -e '.hookSpecificOutput.updatedInput.model == "haiku"' <<<"$output"
    [ "$status" -eq 0 ]

    seed_state opus sonnet
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    run jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$output"
    [ "$status" -eq 0 ]
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p"}}'
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$output"
    [ "$status" -eq 0 ]
}

# ── tier-prime (SessionStart; reads tier.json) ──────────────────────────────

@test "tier-prime prints the trio from tier.json" {
    seed_state sonnet haiku
    jq '.top = "fable"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    prime
    [ "$status" -eq 0 ]
    [[ "$output" == *"orchestrator=fable"* ]]
    [[ "$output" == *"worker=sonnet"* ]]
    [[ "$output" == *"recon=haiku"* ]]
}

@test "tier-prime states OVERDRIVE and PIN flags when set, and neither when unset" {
    seed_state sonnet haiku
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
    printf '{"model":"fable"}\n' > "$LOCAL_SETTINGS"
    reconcile
    [ "$status" -eq 0 ]
    run jq -e '.top == "fable" and .worker == "sonnet" and .recon == "haiku"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # pinned: left exactly as it is, even though .model disagrees
    jq '.pinned = true | .worker = "haiku"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    printf '{"model":"opus"}\n' > "$LOCAL_SETTINGS"
    reconcile
    [ "$status" -eq 0 ]
    run jq -e '.worker == "haiku"' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier-reconcile: purges legacy ANTHROPIC_DEFAULT_*/CLAUDE_CODE_SUBAGENT_MODEL vars from settings.local.json" {
    jq -n '{model:"sonnet", env:{ANTHROPIC_DEFAULT_OPUS_MODEL:"x", CLAUDE_CODE_SUBAGENT_MODEL:"y", KEEP_ME:"z"}}' > "$LOCAL_SETTINGS"
    reconcile
    [ "$status" -eq 0 ]
    run jq -e '(.env | has("ANTHROPIC_DEFAULT_OPUS_MODEL") | not) and (.env | has("CLAUDE_CODE_SUBAGENT_MODEL") | not) and .env.KEEP_ME == "z"' "$LOCAL_SETTINGS"
    [ "$status" -eq 0 ]
}

@test "tier-reconcile: a to_model field on PostModelSwitch stdin is preferred, and is still pin-aware" {
    printf '{"model":"sonnet"}\n' > "$LOCAL_SETTINGS"
    reconcile_with '{"to_model":"claude-fable-5-1"}'
    [ "$status" -eq 0 ]
    run jq -e '.top == "claude-fable-5-1" and .worker == "sonnet"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    jq '.pinned = true' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    reconcile_with '{"to_model":"opus"}'
    [ "$status" -eq 0 ]
    run jq -e '.top == "claude-fable-5-1"' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier-reconcile: overdrive re-applies every run, following a /model change" {
    printf '{"model":"fable"}\n' > "$LOCAL_SETTINGS"
    reconcile
    jq '.overdrive = true' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    reconcile
    run jq -e '.worker == "fable"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    printf '{"model":"opus"}\n' > "$LOCAL_SETTINGS"
    reconcile
    [ "$status" -eq 0 ]
    run jq -e '.top == "opus" and .worker == "opus" and .overdrive == true' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier-reconcile: empty/non-JSON stdin and an off-ladder .model are all silent no-ops that never error" {
    printf '{"model":"fable"}\n' > "$LOCAL_SETTINGS"
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
    # claude-orca-xrp: the derived worker's BACKEND is whatever the Orca probe
    # answers, so a case that asserts the subagent default has to say "no Orca"
    # out loud -- ambient reachability (the suite now runs inside the folder's
    # own container, where orca-ide is up) is not part of what this case means.
    TIER_ORCA_PROBE_DISABLE=1 TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]

    # the v1 keys stay exactly what they were -- the model id per role ...
    run jq -e '.worker == "sonnet" and .recon == "haiku"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    # ... and .roles carries backend + agent + model for all three roles.
    run jq -e '.roles.worker | .backend == "subagent" and .agent == "claude" and .model == "sonnet"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon | .backend == "subagent" and .agent == "claude" and .model == "haiku"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    # claude-orca-8a0.2: the checker rung is DERIVED (the top capped at opus),
    # so a fable top binds opus here; "inherit" survives only as the v1 read
    # rule, exercised below.
    run jq -e '.roles.checker | .backend == "subagent" and .agent == "claude" and .model == "opus"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # a v1 file (no .roles block at all) reads as the subagent backend
    seed_state sonnet haiku
    run jq -e 'has("roles") | not' "$STATE_FILE"
    [ "$status" -eq 0 ]
    prime
    [ "$status" -eq 0 ]
    [[ "$output" == *"worker=subagent:sonnet"* ]]
    [[ "$output" == *"recon=subagent:haiku"* ]]
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
    run jq -e '.roles.worker | .backend == "orca" and .agent == "claude" and .model == "sonnet"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # `subagent` puts the worker back in-process on the DERIVED model
    TIER_DERIVE="$DERIVE" tier_set worker subagent
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker | .backend == "subagent" and .agent == "claude" and .model == "sonnet"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.worker == "sonnet"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # the same grammar on the recon and checker roles
    TIER_DERIVE="$DERIVE" tier_set recon openrouter:qwen/qwen3-coder
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon | .backend == "orca" and .agent == "opencode" and .model == "openrouter/qwen/qwen3-coder"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    TIER_DERIVE="$DERIVE" tier_set checker claude:opus
    [ "$status" -eq 0 ]
    run jq -e '.roles.checker | .backend == "orca" and .agent == "claude" and .model == "opus"' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier-prime prints the backend per role" {
    TIER_DERIVE="$DERIVE" tier_set fable
    TIER_DERIVE="$DERIVE" tier_set worker openrouter:qwen/qwen3-coder
    prime
    [ "$status" -eq 0 ]
    [[ "$output" == *"worker=orca:opencode:openrouter/qwen/qwen3-coder"* ]]
    [[ "$output" == *"recon=subagent:haiku"* ]]
    [[ "$output" == *"checker=subagent:opus"* ]]
    # the orchestrator line is still printed
    [[ "$output" == *"orchestrator=fable"* ]]
}

@test "tier-gate still injects the worker model into generic Agent spawns and leaves named roles alone" {
    seed_state sonnet haiku
    gate '{"tool_name":"Agent","tool_input":{"prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$output"
    [ "$status" -eq 0 ]

    # verifier GRADES, so it takes the checker rung: seed_state's top is
    # "fable" and a v1 file carries no checker rung of its own, so slice B's
    # rule derives it from that top -- fable -> opus (claude-orca-8a0.2)
    gate '{"tool_name":"Agent","tool_input":{"subagent_type":"verifier","prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$output"
    [ "$status" -eq 0 ]

    # oracle and professor are consults, not graders: still untouched
    for role in oracle professor; do
        gate '{"tool_name":"Agent","tool_input":{"subagent_type":"'"$role"'","prompt":"p"}}'
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done

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

# ── the GLM-by-default worker (claude-orca-qa2.20) ──────────────────────────

@test "tier derives an openrouter glm-5.3 opencode worker when an OpenRouter key is present and the claude rung when it is not" {
    orca_up="$BATS_TEST_TMPDIR/orca-up"
    cat > "$orca_up" <<'STUB'
#!/bin/sh
echo '{"ok":true,"result":{"runtime":{"reachable":true}}}'
STUB
    chmod +x "$orca_up"
    keyfile="$BATS_TEST_TMPDIR/openrouter.key"
    printf 'sk-or-v1-testkey\n' > "$keyfile"

    # no key anywhere -> the claude rung, exactly as before
    TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    run jq -e '.worker == "sonnet" and (.roles.worker | .agent == "claude" and .model == "sonnet")' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # a key file -> the worker becomes the GLM rung on opencode, and with a
    # reachable Orca runtime it lands on the orca backend
    TIER_OPENROUTER_KEY_FILE="$keyfile" TIER_ORCA_PROBE_CMD="$orca_up" \
        TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker | .backend == "orca" and .agent == "opencode" and .model == "openrouter/z-ai/glm-5.3"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    # the v1 mirror follows, the top is untouched, and only the worker moved
    run jq -e '.worker == "openrouter/z-ai/glm-5.3" and .top == "fable"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon | .backend == "subagent" and .agent == "claude" and .model == "haiku"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    run jq -e '.roles.checker | .agent == "claude" and .model == "opus"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # tier-prime shows it
    prime
    [ "$status" -eq 0 ]
    [[ "$output" == *"worker=orca:opencode:openrouter/z-ai/glm-5.3"* ]]

    # the env var alone is enough; with no Orca the vendor still holds and
    # only the backend falls back -- "no Orca" is pinned by the probe switch
    # (claude-orca-xrp), never left to the box the suite happens to run on
    OPENROUTER_API_KEY=sk-or-v1-fromenv TIER_ORCA_PROBE_DISABLE=1 \
        TIER_DERIVE="$DERIVE" tier_set opus
    [ "$status" -eq 0 ]
    run jq -e '.top == "opus" and (.roles.worker | .backend == "subagent" and .agent == "opencode" and .model == "openrouter/z-ai/glm-5.3")' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # an explicit /tier worker claude:<x> still overrides the default
    OPENROUTER_API_KEY=sk-or-v1-fromenv TIER_DERIVE="$DERIVE" tier_set worker claude:sonnet
    [ "$status" -eq 0 ]
    run jq -e '.roles.worker | .agent == "claude" and .model == "sonnet" and .pinned == true' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # an explicit 3-arg pin is an explicit pin: the key never overrides it
    OPENROUTER_API_KEY=sk-or-v1-fromenv TIER_DERIVE="$DERIVE" tier_set opus sonnet haiku
    [ "$status" -eq 0 ]
    run jq -e '.worker == "sonnet" and (.roles.worker | .agent == "claude") and .pinned == true' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # an empty key file is not a key
    : > "$keyfile"
    TIER_OPENROUTER_KEY_FILE="$keyfile" TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    run jq -e '.worker == "sonnet" and (.roles.worker | .agent == "claude")' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier-gate injects the checker rung into verifier spawns" {
    TIER_ORCA_PROBE_DISABLE=1 TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]

    # the graders run the checker rung -- opus under a fable top, so the check
    # sits in neither the orchestrator's seat nor the worker's
    for role in verifier bead-auditor; do
        TIER_GATE_DERIVE="$DERIVE" gate '{"tool_name":"Agent","tool_input":{"subagent_type":"'"$role"'","prompt":"p"}}'
        [ "$status" -eq 0 ]
        out="$output"
        run jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$out"
        [ "$status" -eq 0 ]
        run jq -e '.hookSpecificOutput.updatedInput.prompt == "p"' <<<"$out"
        [ "$status" -eq 0 ]
    done

    # oracle and professor are consults, not graders: untouched by design
    for role in oracle professor; do
        TIER_GATE_DERIVE="$DERIVE" gate '{"tool_name":"Agent","tool_input":{"subagent_type":"'"$role"'","prompt":"p"}}'
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done

    # an explicit model on the call always wins
    TIER_GATE_DERIVE="$DERIVE" gate '{"tool_name":"Agent","tool_input":{"subagent_type":"verifier","model":"haiku","prompt":"p"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # the RUNG, never a hardcoded opus: a sonnet top grades from sonnet
    TIER_ORCA_PROBE_DISABLE=1 TIER_DERIVE="$DERIVE" tier_set sonnet
    [ "$status" -eq 0 ]
    TIER_GATE_DERIVE="$DERIVE" gate '{"tool_name":"Agent","tool_input":{"subagent_type":"verifier","prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$output"
    [ "$status" -eq 0 ]

    # a v1 tier.json carries no checker rung at all: derive it from the top
    seed_state sonnet haiku
    TIER_GATE_DERIVE="$DERIVE" gate '{"tool_name":"Agent","tool_input":{"subagent_type":"verifier","prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "opus"' <<<"$output"
    [ "$status" -eq 0 ]

    # an off-ladder top has no rung to grade from: fail open, inject nothing
    jq '.top = "some-custom-router-id"' "$STATE_FILE" > "$BATS_TEST_TMPDIR/off.json"
    mv "$BATS_TEST_TMPDIR/off.json" "$STATE_FILE"
    TIER_GATE_DERIVE="$DERIVE" gate '{"tool_name":"Agent","tool_input":{"subagent_type":"verifier","prompt":"p"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # and an explicit `/tier checker inherit` still means inherit
    TIER_ORCA_PROBE_DISABLE=1 TIER_DERIVE="$DERIVE" tier_set fable
    TIER_DERIVE="$DERIVE" tier_set checker inherit
    [ "$status" -eq 0 ]
    run jq -e '.roles.checker | .model == "inherit" and .pinned == true' "$STATE_FILE"
    [ "$status" -eq 0 ]
    TIER_GATE_DERIVE="$DERIVE" gate '{"tool_name":"Agent","tool_input":{"subagent_type":"verifier","prompt":"p"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "tier-gate announces an injection once per session per slot" {
    seed_state sonnet haiku

    # two consecutive scout spawns, same session: the first carries the
    # notice, the second is silent about it but still gets its model
    TIER_GATE_DERIVE="$DERIVE" gate '{"session_id":"sess-1","tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p"}}'
    [ "$status" -eq 0 ]
    first_out="$output"
    run jq -e '.systemMessage | test("tier-gate")' <<<"$first_out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "haiku"' <<<"$first_out"
    [ "$status" -eq 0 ]

    TIER_GATE_DERIVE="$DERIVE" gate '{"session_id":"sess-1","tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p"}}'
    [ "$status" -eq 0 ]
    second_out="$output"
    run jq -e 'has("systemMessage") | not' <<<"$second_out"
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "haiku"' <<<"$second_out"
    [ "$status" -eq 0 ]

    # a different session: the notice returns
    TIER_GATE_DERIVE="$DERIVE" gate '{"session_id":"sess-2","tool_name":"Agent","tool_input":{"subagent_type":"scout","prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.systemMessage | test("tier-gate")' <<<"$output"
    [ "$status" -eq 0 ]

    # back on sess-1, but the CHECKER slot: it announces once even though
    # the recon slot on that same session already did (the marker is per
    # slot, not just per session)
    TIER_GATE_DERIVE="$DERIVE" gate '{"session_id":"sess-1","tool_name":"Agent","tool_input":{"subagent_type":"verifier","prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.systemMessage | test("tier-gate")' <<<"$output"
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
    run jq -e '.top == "opus"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    run "$BASH32" "$PRIME"
    [ "$status" -eq 0 ]
    [[ "$output" == *"opus"* ]]

    run "$BASH32" "$GATE" <<<'{"tool_name":"Agent","tool_input":{"subagent_type":"executor","prompt":"p"}}'
    [ "$status" -eq 0 ]
    run jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"' <<<"$output"
    [ "$status" -eq 0 ]
}

# ── the 2026 reseat: a derived checker rung (claude-orca-8a0.2) ─────────────
#
# The checker is no longer a flat "inherit". It is derived from the top like
# every other rung, CAPPED at opus: a fable orchestrator is graded by opus --
# a seat that is neither the top's nor the worker's, which is the whole point
# of an independent checker -- and an opus or sonnet top is graded by its own
# model, which is what "inherit" always meant for them.

@test "tier derives the checker to opus when the top is fable" {
    # "no Orca" is pinned by the probe switch (claude-orca-xrp), never left to
    # the box the suite happens to run on.
    TIER_ORCA_PROBE_DISABLE=1 TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]

    run jq -e '.roles.checker | .backend == "subagent" and .agent == "claude" and .model == "opus"' "$STATE_FILE"
    [ "$status" -eq 0 ]
    # ... and it is a seat of its own: neither the top nor the worker.
    run jq -e '.top == "fable" and .worker == "sonnet" and .roles.checker.model != .top and .roles.checker.model != .worker' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # tier-derive is the single source of the rule -- tier-set never repeats it
    run "$DERIVE" --checker fable
    [ "$status" -eq 0 ]
    [ "$output" = "opus" ]

    # tier-prime shows the bound checker, not a placeholder
    prime
    [ "$status" -eq 0 ]
    [[ "$output" == *"checker=subagent:opus"* ]]

    # and a SessionStart reconcile does not revert it to "inherit"
    reconcile
    [ "$status" -eq 0 ]
    run jq -e '.roles.checker.model == "opus"' "$STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "tier derives the checker to the top model when the top is opus or sonnet" {
    TIER_ORCA_PROBE_DISABLE=1 TIER_DERIVE="$DERIVE" tier_set opus
    [ "$status" -eq 0 ]
    run jq -e '.top == "opus" and .roles.checker.model == "opus"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    TIER_ORCA_PROBE_DISABLE=1 TIER_DERIVE="$DERIVE" tier_set sonnet
    [ "$status" -eq 0 ]
    run jq -e '.top == "sonnet" and .roles.checker.model == "sonnet"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # the ladder itself: capped at opus, floored at haiku, family-ranked
    run "$DERIVE" --checker opus
    [ "$output" = "opus" ]
    run "$DERIVE" --checker sonnet
    [ "$output" = "sonnet" ]
    run "$DERIVE" --checker haiku
    [ "$output" = "haiku" ]
    run "$DERIVE" --checker claude-opus-4-8-20260101
    [ "$output" = "opus" ]
    run "$DERIVE" --checker "sonnet[1m]"
    [ "$output" = "sonnet" ]

    # off-ladder stays off-ladder: nothing printed, the caller keeps inherit
    run "$DERIVE" --checker some-custom-router-id
    [ "$status" -eq 3 ]
    [ -z "$output" ]
}

@test "tier derives the worker to sonnet when the top is fable" {
    TIER_ORCA_PROBE_DISABLE=1 TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]
    run jq -e '.worker == "sonnet" and (.roles.worker | .agent == "claude" and .model == "sonnet")' "$STATE_FILE"
    [ "$status" -eq 0 ]
    # the expensive tiers stay out of the worker seat, and recon below it
    run "$DERIVE" fable
    [ "$output" = "fable sonnet haiku" ]
}

@test "tier recon openrouter binds the flash-class default model" {
    TIER_ORCA_PROBE_DISABLE=1 TIER_DERIVE="$DERIVE" tier_set fable
    [ "$status" -eq 0 ]

    # the bare `openrouter` spec takes the role's OpenRouter default: for
    # recon that is the flash-class model, not the full-size worker GLM.
    TIER_DERIVE="$DERIVE" tier_set recon openrouter
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon | .backend == "orca" and .agent == "opencode" and .model == "openrouter/z-ai/glm-5.3-flash" and .pinned == true' "$STATE_FILE"
    [ "$status" -eq 0 ]
    # the v1 mirror follows, and the other roles are untouched
    run jq -e '.recon == "openrouter/z-ai/glm-5.3-flash" and .roles.worker.model == "sonnet"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # the default is a named constant in lib/tier-roles.sh, not a literal
    run grep -c 'TIER_OPENROUTER_RECON_MODEL="openrouter/z-ai/glm-5.3-flash"' "$REPO_ROOT/scripts/lib/tier-roles.sh"
    [ "$output" = "1" ]

    # the explicit spelling still works and lands on the same binding
    TIER_DERIVE="$DERIVE" tier_set recon openrouter:z-ai/glm-5.3-flash
    [ "$status" -eq 0 ]
    run jq -e '.roles.recon.model == "openrouter/z-ai/glm-5.3-flash"' "$STATE_FILE"
    [ "$status" -eq 0 ]

    # and the command is documented where the roles are explained
    run grep -qF -- '/tier recon openrouter' "$REPO_ROOT/knowledge-base/TIERED_ORCHESTRATION.md"
    [ "$status" -eq 0 ]
    run grep -qF -- '/tier recon openrouter' "$REPO_ROOT/config/claude-commands/tier.md"
    [ "$status" -eq 0 ]
}

# ── token diet: tier-prime --short is change-gated; /tier binds print no essay ─

@test "tier-prime --short: prints on the first call, nothing on the next, and again when the binding changes" {
    "$TSET" fable >/dev/null
    run "$PRIME" --short
    [ "$status" -eq 0 ]
    # the derived worker rung is tier-set's business (pinned elsewhere);
    # this case is about the gating, so it checks shape, not model
    [[ "$output" == "[tier] worker="*" recon="* ]]
    [[ "$output" != *"OVERDRIVE"* ]]
    [ -f "$CLAUDE_ORCA_ROOT/.claude-dev/run/tier-primed.txt" ]
    run "$PRIME" --short
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    "$TSET" overdrive >/dev/null
    run "$PRIME" --short
    [ "$status" -eq 0 ]
    [[ "$output" == "[tier] worker="*" (OVERDRIVE)" ]]
    run "$PRIME" --short
    [ -z "$output" ]
    # the full SessionStart trio is not gated: it prints every time
    prime
    [[ "$output" == *"orchestrator=fable"* ]]
    prime
    [[ "$output" == *"orchestrator=fable"* ]]
}

@test "tier-set overdrive / <top> / <role> <spec>: the bound line plus the NEW-spawns line, no explanatory paragraph" {
    tier_set fable
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == "tier bound  top=fable"* ]]
    [[ "${lines[1]}" == "→ applies to NEW spawns"* ]]
    tier_set overdrive
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == "tier bound (overdrive"* ]]
    [[ "${lines[1]}" == "→ applies to NEW spawns"* ]]
    [[ "$output" != *"lifts the worker cap so the executor"* ]]
    [[ "$output" != *"carries a backend"* ]]
    tier_set worker claude:sonnet
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == "tier role bound  worker = orca:sonnet" ]]
    [[ "${lines[1]}" == "→ applies to NEW spawns"* ]]
    tier_set opus sonnet
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[1]}" == "→ applies to NEW spawns"* ]]
}

@test "tier-set help (and a bare tier-set) carry the explanation the skill file no longer repeats" {
    tier_set help
    [ "$status" -eq 0 ]
    [[ "$output" == *"lifts the worker cap so the executor runs the TOP model"* ]]
    [[ "$output" == *"/tier recon openrouter"* ]]
    [[ "$output" == *"/tier auth openrouter"* ]]
    "$TSET" fable >/dev/null
    tier_set
    [ "$status" -eq 0 ]
    [[ "$output" == *"orchestrator (top)   = fable"* ]]
    [[ "$output" == *"lifts the worker cap so the executor runs the TOP model"* ]]
    # the skill body is the passthrough only
    run grep -c "lifts the worker cap so the executor" "$REPO_ROOT/config/claude-commands/tier.md"
    [ "$output" = "0" ]
    run grep -c "verbatim" "$REPO_ROOT/config/claude-commands/tier.md"
    [ "$output" = "1" ]
}
