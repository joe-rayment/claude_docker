#!/usr/bin/env bats
bats_require_minimum_version 1.5.0   # `run --separate-stderr` (tier-set cost)
# tier-hooks.bats — the spend-enforcement / tier-reminder hooks:
#   tier-gate      PreToolUse[Agent]     default-cheap model for generic spawns
#   tier-reconcile UserPromptSubmit/SessionStart  agent bindings track .model
#   workflow-lint  PreToolUse[Workflow]  deny scripts whose agent() omits model
#   cost-mirror    UserPromptSubmit      by-model session spend line
#   tier-prime     SessionStart/PreCompact  tier trio + protocol restatement
# All fail OPEN: any malformed/missing input path must be silent exit 0.
# Plus tier-derive itself — the ladder those hooks read, including the
# --overdrive worker-cap lift. It is not a hook and does not fail open:
# usage is exit 2, an off-ladder top is exit 3 with no output.
# Plus tier-set's `overdrive` mode — the /tier engine that makes that lift
# sticky (.env.TIER_OVERDRIVE) and writes the worker/recon frontmatter.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

GATE="$REPO_ROOT/scripts/tier-gate.sh"
LINT="$REPO_ROOT/scripts/workflow-lint.sh"
MIRROR="$REPO_ROOT/scripts/cost-mirror.py"
DERIVE="$REPO_ROOT/scripts/tier-derive.sh"
PRIME="$REPO_ROOT/scripts/tier-prime.sh"
DOCKERFILE="$REPO_ROOT/Dockerfile"
SETTINGS_JSON="$REPO_ROOT/config/claude-settings.json"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    SETTINGS="$BATS_TEST_TMPDIR/settings.json"
    printf '{"model":"claude-fable-5[1m]"}\n' > "$SETTINGS"
    export TIER_GATE_SETTINGS="$SETTINGS"
    export TIER_GATE_DERIVE="$DERIVE"
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-state"
    # tier-prime appends the router rubric when `lane` is installed; point
    # it at a path that cannot exist so the pre-lane assertions below stay
    # exact regardless of whether the image has lane on PATH. The lane
    # tests override this explicitly.
    export TIER_PRIME_LANE="$BATS_TEST_TMPDIR/no-such-lane"
    # same reason for cost-mirror's lane join: point LANE_STATE_DIR at a dir
    # that does not exist so no test ever reads (or is perturbed by) the live
    # ~/.claude/cache/lane/log.jsonl this container is actively writing. The
    # lane tests below override this explicitly.
    export LANE_STATE_DIR="$BATS_TEST_TMPDIR/no-such-lane-state"
    # the aggregate report resolves "which session" from this when no
    # transcript names one; these suites run INSIDE a live session that sets
    # it, so clear it and let the lane tests set it where they mean to.
    unset CLAUDE_CODE_SESSION_ID
    # pin billing mode to "api" so pre-existing assertions are independent of
    # whatever real credentials/env this container happens to run under;
    # billing-mode-specific tests below override this explicitly
    export COST_MIRROR_BILLING="api"
    # cost-mirror reads .env.TIER_OVERDRIVE (tier-set owns that flag) to decide
    # whether the "saved" counterfactual is still true; point it at the same
    # scratch settings file the gate tests use so no assertion here ever
    # depends on whether THIS container happens to be running overdriven.
    export COST_MIRROR_SETTINGS_PATH="$SETTINGS"
}

gate() { sh "$GATE"; }
lint() { sh "$LINT"; }
mirror() { python3 "$MIRROR"; }

# ── tier-derive ──────────────────────────────────────────────────────────────

@test "tier-derive --overdrive: a fable top lifts the worker to fable, recon stays haiku" {
    run sh "$DERIVE" --overdrive fable
    [ "$status" -eq 0 ]
    # the cap is lifted for the WORKER only; recon is still derived from the
    # capped worker (sonnet), so it does not inflate to sonnet-class
    [ "$output" = "claude-fable-5 claude-fable-5 claude-haiku-4-5-20251001" ]
}

@test "tier-derive --overdrive: an opus top lifts the worker to opus, recon stays haiku" {
    run sh "$DERIVE" --overdrive opus
    [ "$status" -eq 0 ]
    [ "$output" = "claude-opus-5 claude-opus-5 claude-haiku-4-5-20251001" ]
}

@test "tier-derive --overdrive: sonnet lifts to sonnet/haiku, haiku is a no-op" {
    run sh "$DERIVE" --overdrive sonnet
    [ "$status" -eq 0 ]
    [ "$output" = "claude-sonnet-5 claude-sonnet-5 claude-haiku-4-5-20251001" ]
    # the bottom rung has nothing to lift: overdrive changes nothing
    run sh "$DERIVE" --overdrive haiku
    [ "$status" -eq 0 ]
    [ "$output" = "claude-haiku-4-5-20251001 claude-haiku-4-5-20251001 claude-haiku-4-5-20251001" ]
}

@test "tier-derive --overdrive: a dated or [variant] top keeps its EXACT value in both the top and worker slots" {
    run sh "$DERIVE" --overdrive claude-opus-4-8-20260101
    [ "$status" -eq 0 ]
    [ "$output" = "claude-opus-4-8-20260101 claude-opus-4-8-20260101 claude-haiku-4-5-20251001" ]
    run sh "$DERIVE" --overdrive 'sonnet[1m]'
    [ "$status" -eq 0 ]
    [ "$output" = "sonnet[1m] sonnet[1m] claude-haiku-4-5-20251001" ]
    run sh "$DERIVE" --overdrive 'claude-fable-5[1m]'
    [ "$status" -eq 0 ]
    [ "$output" = "claude-fable-5[1m] claude-fable-5[1m] claude-haiku-4-5-20251001" ]
}

@test "tier-derive --overdrive: an off-ladder top still exits 3 with no output" {
    run sh "$DERIVE" --overdrive gpt-5
    [ "$status" -eq 3 ]
    [ -z "$output" ]
    run sh "$DERIVE" --overdrive best
    [ "$status" -eq 3 ]
    [ -z "$output" ]
}

@test "tier-derive --overdrive: no model argument is a usage error, and the usage text names the flag" {
    run sh "$DERIVE" --overdrive
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: tier-derive"* ]]
    run sh "$DERIVE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--overdrive"* ]]
}

@test "tier-derive: plain (no flag) derivation is byte-identical to the capped ladder" {
    run sh "$DERIVE" fable
    [ "$status" -eq 0 ]
    [ "$output" = "claude-fable-5 claude-sonnet-5 claude-haiku-4-5-20251001" ]
    run sh "$DERIVE" opus
    [ "$status" -eq 0 ]
    [ "$output" = "claude-opus-5 claude-sonnet-5 claude-haiku-4-5-20251001" ]
    run sh "$DERIVE" sonnet
    [ "$status" -eq 0 ]
    [ "$output" = "claude-sonnet-5 claude-haiku-4-5-20251001 claude-haiku-4-5-20251001" ]
    run sh "$DERIVE" haiku
    [ "$status" -eq 0 ]
    [ "$output" = "claude-haiku-4-5-20251001 claude-haiku-4-5-20251001 claude-haiku-4-5-20251001" ]
    run sh "$DERIVE" claude-opus-4-8-20260101
    [ "$status" -eq 0 ]
    [ "$output" = "claude-opus-4-8-20260101 claude-sonnet-5 claude-haiku-4-5-20251001" ]
    run sh "$DERIVE" 'sonnet[1m]'
    [ "$status" -eq 0 ]
    [ "$output" = "sonnet[1m] claude-haiku-4-5-20251001 claude-haiku-4-5-20251001" ]
    run sh "$DERIVE" gpt-5
    [ "$status" -eq 3 ]
    [ -z "$output" ]
}

@test "tier-derive: --rank and --name are unaffected by the overdrive flag's existence" {
    run sh "$DERIVE" --rank fable
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
    run sh "$DERIVE" --rank gpt-5
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    run sh "$DERIVE" --name opus
    [ "$status" -eq 0 ]
    [ "$output" = "Opus 5" ]
    run sh "$DERIVE" --name gpt-5
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# ── tier-set (overdrive) ─────────────────────────────────────────────────────

TSET="$REPO_ROOT/scripts/tier-set.sh"

tier_set_fixture() {  # scratch settings (.model = $1) + executor/scout frontmatter
    TS="$BATS_TEST_TMPDIR/tier-set-settings.json"
    TS_AGENTS="$BATS_TEST_TMPDIR/tier-set-agents"
    mkdir -p "$TS_AGENTS"
    printf -- '---\nname: executor\nmodel: claude-sonnet-5\n---\nDo the slice.\n' > "$TS_AGENTS/executor.md"
    printf -- '---\nname: scout\nmodel: claude-haiku-4-5-20251001\n---\nGo look.\n' > "$TS_AGENTS/scout.md"
    printf '{"model":"%s"}\n' "$1" > "$TS"
}

tier_set() {  # run tier-set against the fixture — never the real ~/.claude
    # TIER_DERIVE pins the REPO tier-derive: the baked /usr/local/bin copy has
    # no --overdrive until the next image rebuild. TIER_NO_PROBE keeps every
    # case off the network (a probe is a real `claude -p` round trip).
    run env TIER_SETTINGS="$TS" TIER_AGENTS_DIR="$TS_AGENTS" TIER_DERIVE="$DERIVE" \
        TIER_NO_PROBE=1 sh "$TSET" "$@"
}

fm_of() {  # frontmatter `model:` value of an agent file
    grep -m1 '^model:' "$1" | sed 's/^model:[[:space:]]*//'
}

@test "tier-set overdrive: lifts the worker to the top, leaves recon at haiku, sets TIER_OVERDRIVE" {
    tier_set_fixture claude-fable-5
    tier_set overdrive
    [ "$status" -eq 0 ]
    [ "$(fm_of "$TS_AGENTS/executor.md")" = "claude-fable-5" ]
    # recon is derived from the CAPPED worker, so it never inflates with it
    [ "$(fm_of "$TS_AGENTS/scout.md")" = "claude-haiku-4-5-20251001" ]
    jq -e '.env.TIER_OVERDRIVE == "1"' "$TS"
    # the top itself is not re-bound: overdrive moves the worker seat only
    jq -e '.model == "claude-fable-5"' "$TS"
    # the confirmation names the mode and how to clear it
    [[ "$output" == *"overdrive"* ]]
    [[ "$output" == *"a 1-arg /tier <top> clears"* ]]
    # only the model: line moved — the rest of the agent file is intact
    grep -q '^name: executor$' "$TS_AGENTS/executor.md"
    grep -q 'Do the slice.' "$TS_AGENTS/executor.md"
}

@test "tier-set overdrive: a following 1-arg bind clears TIER_OVERDRIVE and restores the capped worker" {
    tier_set_fixture claude-fable-5
    tier_set overdrive
    [ "$status" -eq 0 ]
    jq -e '.env.TIER_OVERDRIVE == "1"' "$TS"
    [ "$(fm_of "$TS_AGENTS/executor.md")" = "claude-fable-5" ]

    # one obvious reset: a 1-arg bind clears BOTH sticky flags
    tier_set sonnet
    [ "$status" -eq 0 ]
    jq -e '.model == "claude-sonnet-5"' "$TS"
    jq -e '(.env // {}) | has("TIER_OVERDRIVE") | not' "$TS"
    jq -e '(.env // {}) | has("TIER_EXPLICIT_PIN") | not' "$TS"
    [ "$(fm_of "$TS_AGENTS/executor.md")" = "claude-haiku-4-5-20251001" ]
    [ "$(fm_of "$TS_AGENTS/scout.md")" = "claude-haiku-4-5-20251001" ]
}

@test "tier-set overdrive: a 2-arg explicit pin clears TIER_OVERDRIVE and sets TIER_EXPLICIT_PIN" {
    tier_set_fixture claude-fable-5
    tier_set overdrive
    [ "$status" -eq 0 ]
    jq -e '.env.TIER_OVERDRIVE == "1"' "$TS"

    # literal ids win — the pin takes the worker slot back
    tier_set opus haiku
    [ "$status" -eq 0 ]
    jq -e '.env.TIER_EXPLICIT_PIN == "1"' "$TS"
    jq -e '(.env // {}) | has("TIER_OVERDRIVE") | not' "$TS"
    [ "$(fm_of "$TS_AGENTS/executor.md")" = "claude-haiku-4-5-20251001" ]
    [ "$(fm_of "$TS_AGENTS/scout.md")" = "claude-haiku-4-5-20251001" ]
}

@test "tier-set overdrive: taking overdrive after an explicit pin drops the pin — one owner for the worker slot" {
    tier_set_fixture claude-sonnet-5
    tier_set fable sonnet haiku
    [ "$status" -eq 0 ]
    jq -e '.env.TIER_EXPLICIT_PIN == "1"' "$TS"

    tier_set overdrive
    [ "$status" -eq 0 ]
    jq -e '.env.TIER_OVERDRIVE == "1"' "$TS"
    jq -e '(.env // {}) | has("TIER_EXPLICIT_PIN") | not' "$TS"
    [ "$(fm_of "$TS_AGENTS/executor.md")" = "claude-fable-5" ]
    [ "$(fm_of "$TS_AGENTS/scout.md")" = "claude-haiku-4-5-20251001" ]
}

@test "tier-set overdrive: an off-ladder .model leaves both bindings untouched and never sets the flag" {
    tier_set_fixture my-custom-router
    before_e=$(cat "$TS_AGENTS/executor.md")
    before_c=$(cat "$TS_AGENTS/scout.md")
    tier_set overdrive
    [ "$status" -ne 0 ]
    [[ "$output" == *"off-ladder"* ]]
    [ "$(cat "$TS_AGENTS/executor.md")" = "$before_e" ]
    [ "$(cat "$TS_AGENTS/scout.md")" = "$before_c" ]
    jq -e '(.env // {}) | has("TIER_OVERDRIVE") | not' "$TS"
    jq -e '.model == "my-custom-router"' "$TS"
}

@test "tier-set overdrive: a [variant] .model keeps its exact value in the worker slot and is never re-probed" {
    tier_set_fixture 'claude-fable-5[1m]'
    # a `claude` stub that ALWAYS fails: overdrive re-derives a top that is
    # already bound, so it must not probe at all — a probe here would cost a
    # multi-second round trip and could silently degrade .model underneath us
    stub_dir="$BATS_TEST_TMPDIR/tier-set-bin"
    mkdir -p "$stub_dir"
    printf '#!/bin/sh\nexit 1\n' > "$stub_dir/claude"
    chmod +x "$stub_dir/claude"
    run env TIER_SETTINGS="$TS" TIER_AGENTS_DIR="$TS_AGENTS" TIER_DERIVE="$DERIVE" \
        PATH="$stub_dir:$PATH" sh "$TSET" overdrive
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARNING"* ]]
    [ "$(fm_of "$TS_AGENTS/executor.md")" = "claude-fable-5[1m]" ]
    [ "$(fm_of "$TS_AGENTS/scout.md")" = "claude-haiku-4-5-20251001" ]
    jq -e '.model == "claude-fable-5[1m]"' "$TS"
    jq -e '.env.TIER_OVERDRIVE == "1"' "$TS"
}

@test "tier-set overdrive: purges the legacy picker env vars and preserves unrelated settings" {
    tier_set_fixture claude-opus-5
    jq '.env = {"KEEP":"1","CLAUDE_CODE_SUBAGENT_MODEL":"bad","ANTHROPIC_DEFAULT_SONNET_MODEL":"x"}
        | .permissions = {"allow":["WebSearch"]}' "$TS" > "$TS.x"
    mv "$TS.x" "$TS"
    tier_set overdrive
    [ "$status" -eq 0 ]
    jq -e '.env.KEEP == "1"' "$TS"
    jq -e '.env.TIER_OVERDRIVE == "1"' "$TS"
    jq -e '(.env | has("CLAUDE_CODE_SUBAGENT_MODEL")) | not' "$TS"
    jq -e '(.env | keys | map(select(startswith("ANTHROPIC_DEFAULT"))) | length) == 0' "$TS"
    jq -e '.permissions.allow == ["WebSearch"]' "$TS"
    [ "$(fm_of "$TS_AGENTS/executor.md")" = "claude-opus-5" ]
}

@test "tier-set show: names overdrive and reports the LIFTED trio, not the capped one" {
    tier_set_fixture claude-fable-5
    tier_set overdrive
    [ "$status" -eq 0 ]
    tier_set show
    [ "$status" -eq 0 ]
    [[ "$output" == *"overdrive"* ]]
    # the reported trio must match what is actually bound
    [[ "$output" == *"claude-fable-5 claude-fable-5 claude-haiku-4-5-20251001"* ]]
    [[ "$output" != *"claude-fable-5 claude-sonnet-5 claude-haiku-4-5-20251001"* ]]
}

@test "tier-set overdrive: a bad frontmatter precondition binds nothing — no flag, no settings write" {
    # the ordering property: every slot is checked BEFORE the settings write, so
    # a failure can never leave a sticky flag behind that blocks later repair
    tier_set_fixture claude-fable-5
    printf -- '---\nname: scout\n---\nGo look.\n' > "$TS_AGENTS/scout.md"
    before_s=$(cat "$TS")
    tier_set overdrive
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing bound"* ]]
    [ "$(cat "$TS")" = "$before_s" ]
    [ "$(fm_of "$TS_AGENTS/executor.md")" = "claude-sonnet-5" ]
}

@test "tier-set overdrive: with no top bound it refuses rather than guessing one" {
    tier_set_fixture claude-fable-5
    printf '{}\n' > "$TS"
    before_e=$(cat "$TS_AGENTS/executor.md")
    tier_set overdrive
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing bound"* ]]
    jq -e '. == {}' "$TS"
    [ "$(cat "$TS_AGENTS/executor.md")" = "$before_e" ]

    # a missing settings file is refused too, and is NOT created on the way out
    rm -f "$TS"
    tier_set overdrive
    [ "$status" -ne 0 ]
    [ ! -f "$TS" ]
    [ "$(cat "$TS_AGENTS/executor.md")" = "$before_e" ]
}

# ── tier-set cost (the /tier cost spend report) ──────────────────────────────

# TIER_COST_MIRROR pins the REPO cost-mirror in every case below, exactly as
# TIER_DERIVE pins the repo tier-derive above and for the same reason: the
# baked /usr/local/bin copy is a build artifact that lags the working tree,
# and these assertions are about THIS tree's wrapper, not that snapshot.
# MIRROR_BIN swaps in a stub where the case is about the hand-off itself
# rather than about the report.
tier_cost() {  # `tier-set cost …` against the fixture — never the real ~/.claude
    run env TIER_SETTINGS="$TS" TIER_AGENTS_DIR="$TS_AGENTS" TIER_DERIVE="$DERIVE" \
        TIER_COST_MIRROR="${MIRROR_BIN:-$MIRROR}" TIER_NO_PROBE=1 sh "$TSET" cost "$@"
}

tier_cost_err() {  # same, with stderr captured apart from stdout
    run --separate-stderr env TIER_SETTINGS="$TS" TIER_AGENTS_DIR="$TS_AGENTS" \
        TIER_DERIVE="$DERIVE" TIER_COST_MIRROR="${MIRROR_BIN:-$MIRROR}" \
        TIER_NO_PROBE=1 sh "$TSET" cost "$@"
}

cost_projects() {  # a two-session corpus for the report to have something to say
    CDIR="$BATS_TEST_TMPDIR/cost-projects"
    mkdir -p "$CDIR/proj-a" "$CDIR/proj-b"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":10}}}\n' \
        > "$CDIR/proj-a/sess-a.jsonl"
    printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":20}}}\n' \
        > "$CDIR/proj-b/sess-b.jsonl"
    export COST_MIRROR_PROJECTS_DIR="$CDIR"
}

argv_stub() {  # a cost-mirror stand-in that prints its argv, one argument per line
    MIRROR_BIN="$BATS_TEST_TMPDIR/mirror-stub.py"
    cat > "$MIRROR_BIN" <<'PY'
#!/usr/bin/env python3
import sys
for a in sys.argv[1:]:
    print(a)
PY
    chmod +x "$MIRROR_BIN"
}

@test "tier-set cost: renders byte-for-byte what cost-mirror --report renders" {
    tier_set_fixture claude-fable-5
    cost_projects
    # cold and symmetric: a bare --report writes a scan cache and lifetime.json,
    # so each run gets its OWN state dir instead of reading the other's leftovers
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-direct"
    run python3 "$MIRROR" --report
    [ "$status" -eq 0 ]
    direct="$output"
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-wrapped"
    tier_cost
    [ "$status" -eq 0 ]
    [ "$output" = "$direct" ]
    # a wrapper that printed a banner of its own, or swallowed the table, differs above
    [[ "$output" == *"cost-mirror report"* ]]
    [[ "$output" == *"TOTAL"* ]]
}

@test "tier-set cost: trailing arguments reach cost-mirror --report verbatim, never an allowlist" {
    tier_set_fixture claude-fable-5
    argv_stub
    # --csv does not exist on the report yet (beads_claude_docker-fbi): a
    # transparent pass-through carries it anyway, with no second change here
    tier_cost --csv /tmp/rows.csv --since 7d
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--report" ]
    [ "${lines[1]}" = "--csv" ]
    [ "${lines[2]}" = "/tmp/rows.csv" ]
    [ "${lines[3]}" = "--since" ]
    [ "${lines[4]}" = "7d" ]
    [ "${#lines[@]}" -eq 5 ]
}

@test "tier-set cost: a glob or space-bearing argument survives the hand-off unmangled" {
    tier_set_fixture claude-fable-5
    argv_stub
    # $* (or an unquoted $@) splits "two words" in half and expands a* against
    # the cwd; the decoy makes that expansion deterministic instead of depending
    # on whatever happens to sit in the directory bats was started from
    cd "$BATS_TEST_TMPDIR"
    touch a-decoy
    tier_cost --session 'a*' --note 'two words'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--report" ]
    [ "${lines[1]}" = "--session" ]
    [ "${lines[2]}" = "a*" ]
    [ "${lines[3]}" = "--note" ]
    [ "${lines[4]}" = "two words" ]
    [ "${#lines[@]}" -eq 5 ]
}

@test "tier-set cost --since/--session: identical to the same flags on cost-mirror --report" {
    tier_set_fixture claude-fable-5
    cost_projects
    touch -d "3 days ago" "$CDIR/proj-a/sess-a.jsonl"

    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-since-direct"
    run python3 "$MIRROR" --report --since 1d
    [ "$status" -eq 0 ]
    since_direct="$output"
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-since-wrapped"
    tier_cost --since 1d
    [ "$status" -eq 0 ]
    [ "$output" = "$since_direct" ]
    # the flag really narrowed — without this both sides could agree and be wrong
    [[ "$output" == *"sess-b"* ]]
    [[ "$output" != *"sess-a"* ]]

    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-sess-direct"
    run python3 "$MIRROR" --report --session sess-b
    [ "$status" -eq 0 ]
    sess_direct="$output"
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-sess-wrapped"
    tier_cost --session sess-b
    [ "$status" -eq 0 ]
    [ "$output" = "$sess_direct" ]
    [[ "$output" == *"sess-b"* ]]
}

@test "tier-set cost: a failing report propagates its exit status and its stderr, unfiltered" {
    tier_set_fixture claude-fable-5
    export COST_MIRROR_PROJECTS_DIR="$BATS_TEST_TMPDIR/cost-empty"
    mkdir -p "$COST_MIRROR_PROJECTS_DIR"
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-fail"
    tier_cost_err
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"no transcript files found"* ]]

    # a bad flag VALUE is the report's own complaint, still on stderr, still nonzero
    tier_cost_err --since notaday
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"--since expects"* ]]
}

@test "tier-set cost: a missing cost-mirror fails loud instead of exiting 0 with nothing" {
    tier_set_fixture claude-fable-5
    MIRROR_BIN="$BATS_TEST_TMPDIR/no-such-cost-mirror"
    tier_cost
    [ "$status" -ne 0 ]
    [[ "$output" == *"cost-mirror"* ]]
}

@test "tier-set cost: binds nothing — 'cost' is a subcommand, never a model id" {
    tier_set_fixture claude-fable-5
    cost_projects
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-nobind"
    before_s=$(cat "$TS")
    before_e=$(cat "$TS_AGENTS/executor.md")
    before_c=$(cat "$TS_AGENTS/scout.md")
    tier_cost
    [ "$status" -eq 0 ]
    [ "$(cat "$TS")" = "$before_s" ]
    [ "$(cat "$TS_AGENTS/executor.md")" = "$before_e" ]
    [ "$(cat "$TS_AGENTS/scout.md")" = "$before_c" ]
}

@test "tier-set cost: the subcommand shadows no binding form — bare, 1-arg, 3-arg and overdrive still bind" {
    tier_set_fixture claude-fable-5
    tier_set
    [ "$status" -eq 0 ]
    [[ "$output" == *"orchestrator (settings model)"* ]]
    [[ "$output" == *"worker / executor (frontmatter)"* ]]
    [[ "$output" == *"recon / scout (frontmatter)"* ]]
    [[ "$output" == *"derived trio for top=claude-fable-5"* ]]

    tier_set opus
    [ "$status" -eq 0 ]
    jq -e '.model == "claude-opus-5"' "$TS"
    [ "$(fm_of "$TS_AGENTS/executor.md")" = "claude-sonnet-5" ]
    [ "$(fm_of "$TS_AGENTS/scout.md")" = "claude-haiku-4-5-20251001" ]

    tier_set opus sonnet haiku
    [ "$status" -eq 0 ]
    jq -e '.env.TIER_EXPLICIT_PIN == "1"' "$TS"
    [ "$(fm_of "$TS_AGENTS/executor.md")" = "claude-sonnet-5" ]

    tier_set overdrive
    [ "$status" -eq 0 ]
    jq -e '.env.TIER_OVERDRIVE == "1"' "$TS"
    [ "$(fm_of "$TS_AGENTS/executor.md")" = "claude-opus-5" ]
}

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

gate_generic() {  # a generic, model-less Agent spawn through the gate
    run sh -c 'printf %s "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"prompt\":\"p\"}}" | sh '"$GATE"
}

@test "tier-gate: TIER_OVERDRIVE=1 injects the LIFTED top, never the capped sonnet-class worker" {
    printf '{"model":"claude-fable-5","env":{"TIER_OVERDRIVE":"1"}}\n' > "$SETTINGS"
    gate_generic
    [ "$status" -eq 0 ]
    # the Agent tool takes family ALIASES only, so the lift reads as `fable`;
    # the concrete lifted id is named in the systemMessage
    echo "$output" | jq -e '.hookSpecificOutput.updatedInput.model == "fable"'
    echo "$output" | jq -e '.systemMessage | contains("claude-fable-5")'
    echo "$output" | jq -e '.hookSpecificOutput.updatedInput.prompt == "p"'
    # control: the SAME top with the flag absent is still capped
    printf '{"model":"claude-fable-5"}\n' > "$SETTINGS"
    gate_generic
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"'
}

@test "tier-gate: an overdriven top keeps its EXACT variant/dated id through the alias mapping" {
    # under overdrive the worker slot is the top VERBATIM, so --rank is fed a
    # user-shaped id for the first time — it must still resolve to an alias
    printf '{"model":"claude-fable-5[1m]","env":{"TIER_OVERDRIVE":"1"}}\n' > "$SETTINGS"
    gate_generic
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.updatedInput.model == "fable"'
    echo "$output" | jq -e '.systemMessage | contains("claude-fable-5[1m]")'
    printf '{"model":"claude-opus-4-8-20260101","env":{"TIER_OVERDRIVE":"1"}}\n' > "$SETTINGS"
    gate_generic
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.updatedInput.model == "opus"'
    echo "$output" | jq -e '.systemMessage | contains("claude-opus-4-8-20260101")'
}

@test "tier-gate: only the exact flag value \"1\" lifts the cap" {
    for v in 0 true yes ""; do
        printf '{"model":"claude-fable-5","env":{"TIER_OVERDRIVE":"%s"}}\n' "$v" > "$SETTINGS"
        gate_generic
        [ "$status" -eq 0 ]
        echo "$output" | jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"'
    done
}

@test "tier-gate: overdrive fails open — an off-ladder top or a derive that rejects --overdrive injects nothing" {
    printf '{"model":"my-custom-router","env":{"TIER_OVERDRIVE":"1"}}\n' > "$SETTINGS"
    gate_generic
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # the stale/baked shape: --overdrive is unknown, so it lands in the model
    # slot and comes back off-ladder (exit 3). Fail open — NEVER fall back to
    # the capped worker, which would silently revert the lift.
    stub="$BATS_TEST_TMPDIR/derive-no-overdrive"
    printf '#!/bin/sh\ncase "$1" in --overdrive) exit 3 ;; --rank) echo 2 ;; *) echo "claude-fable-5 claude-sonnet-5 claude-haiku-4-5-20251001" ;; esac\n' > "$stub"
    chmod +x "$stub"
    export TIER_GATE_DERIVE="$stub"
    printf '{"model":"claude-fable-5","env":{"TIER_OVERDRIVE":"1"}}\n' > "$SETTINGS"
    gate_generic
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # the same stub with the flag absent: the capped path is untouched by any of this
    printf '{"model":"claude-fable-5"}\n' > "$SETTINGS"
    gate_generic
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.updatedInput.model == "sonnet"'
}

@test "tier-gate: overdrive never overrides an explicit model, and still leaves named roles alone" {
    printf '{"model":"claude-fable-5","env":{"TIER_OVERDRIVE":"1"}}\n' > "$SETTINGS"
    run sh -c 'printf %s "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"model\":\"haiku\",\"prompt\":\"p\"}}" | sh '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run sh -c 'printf %s "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"scout\",\"prompt\":\"p\"}}" | sh '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── tier-reconcile ───────────────────────────────────────────────────────────

RECON="$REPO_ROOT/scripts/tier-reconcile.sh"

tier_reconcile_fixture() {  # scratch settings (.model = $1) + executor/scout frontmatter
    TR="$BATS_TEST_TMPDIR/tier-reconcile-settings.json"
    TR_AGENTS="$BATS_TEST_TMPDIR/tier-reconcile-agents"
    mkdir -p "$TR_AGENTS"
    printf -- '---\nname: executor\nmodel: claude-sonnet-5\n---\nDo the slice.\n' > "$TR_AGENTS/executor.md"
    printf -- '---\nname: scout\nmodel: claude-haiku-4-5-20251001\n---\nGo look.\n' > "$TR_AGENTS/scout.md"
    printf '{"model":"%s"}\n' "$1" > "$TR"
}

tier_reconcile() {  # run the hook against the fixture — never the real ~/.claude
    # TIER_DERIVE pins the REPO tier-derive: the baked /usr/local/bin copy has
    # no --overdrive until the next image rebuild. $1 overrides it (stub cases).
    run env TIER_SETTINGS="$TR" TIER_AGENTS_DIR="$TR_AGENTS" TIER_DERIVE="${1:-$DERIVE}" sh "$RECON"
}

tr_env() {  # merge .env.<key> = <value> into the fixture settings
    jq --arg k "$1" --arg v "$2" '.env = ((.env // {}) + {($k): $v})' "$TR" > "$TR.x"
    mv "$TR.x" "$TR"
}

@test "tier-reconcile: TIER_OVERDRIVE=1 binds the executor to the lifted top and leaves scout cheap" {
    tier_reconcile_fixture claude-fable-5
    tr_env TIER_OVERDRIVE 1
    tier_reconcile
    [ "$status" -eq 0 ]
    # a UserPromptSubmit hook's stdout is injected into the prompt: stay silent
    [ -z "$output" ]
    [ "$(fm_of "$TR_AGENTS/executor.md")" = "claude-fable-5" ]
    # recon is derived from the CAPPED worker, so the lift never drags it up
    [ "$(fm_of "$TR_AGENTS/scout.md")" = "claude-haiku-4-5-20251001" ]
    # idempotent: the next prompt's run is a no-op, not a flap back to the cap
    tier_reconcile
    [ "$status" -eq 0 ]
    [ "$(fm_of "$TR_AGENTS/executor.md")" = "claude-fable-5" ]
    # only the model: line moved — the rest of the agent file is intact
    grep -q '^name: executor$' "$TR_AGENTS/executor.md"
    grep -q 'Do the slice.' "$TR_AGENTS/executor.md"
}

@test "tier-reconcile: with the flag absent the capped worker is restored — the revert overdrive must survive" {
    tier_reconcile_fixture claude-fable-5
    printf -- '---\nname: executor\nmodel: claude-fable-5\n---\nDo the slice.\n' > "$TR_AGENTS/executor.md"
    tier_reconcile
    [ "$status" -eq 0 ]
    [ "$(fm_of "$TR_AGENTS/executor.md")" = "claude-sonnet-5" ]
    [ "$(fm_of "$TR_AGENTS/scout.md")" = "claude-haiku-4-5-20251001" ]
}

@test "tier-reconcile: only the exact flag value \"1\" lifts the cap" {
    for v in 0 true yes; do
        tier_reconcile_fixture claude-fable-5
        printf -- '---\nname: executor\nmodel: claude-fable-5\n---\nDo the slice.\n' > "$TR_AGENTS/executor.md"
        tr_env TIER_OVERDRIVE "$v"
        tier_reconcile
        [ "$status" -eq 0 ]
        [ "$(fm_of "$TR_AGENTS/executor.md")" = "claude-sonnet-5" ]
    done
}

@test "tier-reconcile: overdrive FOLLOWS a /model change — a derivation rule, not a frozen value" {
    tier_reconcile_fixture claude-fable-5
    tr_env TIER_OVERDRIVE 1
    tier_reconcile
    [ "$status" -eq 0 ]
    [ "$(fm_of "$TR_AGENTS/executor.md")" = "claude-fable-5" ]
    # /model moves the top; the next run lifts to the NEW top, not the old one
    jq '.model = "claude-opus-5"' "$TR" > "$TR.x"
    mv "$TR.x" "$TR"
    tier_reconcile
    [ "$status" -eq 0 ]
    [ "$(fm_of "$TR_AGENTS/executor.md")" = "claude-opus-5" ]
    [ "$(fm_of "$TR_AGENTS/scout.md")" = "claude-haiku-4-5-20251001" ]
    # a [variant] top keeps its exact id in the worker seat
    jq '.model = "claude-fable-5[1m]"' "$TR" > "$TR.x"
    mv "$TR.x" "$TR"
    tier_reconcile
    [ "$status" -eq 0 ]
    [ "$(fm_of "$TR_AGENTS/executor.md")" = "claude-fable-5[1m]" ]
}

@test "tier-reconcile: TIER_EXPLICIT_PIN still wins over TIER_OVERDRIVE and skips derivation entirely" {
    tier_reconcile_fixture claude-fable-5
    tr_env TIER_OVERDRIVE 1
    tr_env TIER_EXPLICIT_PIN 1
    before_e=$(cat "$TR_AGENTS/executor.md")
    before_c=$(cat "$TR_AGENTS/scout.md")
    tier_reconcile
    [ "$status" -eq 0 ]
    [ "$(cat "$TR_AGENTS/executor.md")" = "$before_e" ]
    [ "$(cat "$TR_AGENTS/scout.md")" = "$before_c" ]
}

@test "tier-reconcile: overdrive fails open — off-ladder top, a derive rejecting --overdrive, missing settings" {
    tier_reconcile_fixture my-custom-router
    tr_env TIER_OVERDRIVE 1
    before_e=$(cat "$TR_AGENTS/executor.md")
    tier_reconcile
    [ "$status" -eq 0 ]
    [ "$(cat "$TR_AGENTS/executor.md")" = "$before_e" ]

    # a derive with no --overdrive support (the stale baked shape) changes
    # NOTHING — never a silent fall back to the capped worker, which would be
    # exactly the revert this slice exists to kill
    stub="$BATS_TEST_TMPDIR/recon-derive-no-overdrive"
    printf '#!/bin/sh\ncase "$1" in --overdrive) exit 3 ;; *) echo "claude-fable-5 claude-sonnet-5 claude-haiku-4-5-20251001" ;; esac\n' > "$stub"
    chmod +x "$stub"
    tier_reconcile_fixture claude-fable-5
    printf -- '---\nname: executor\nmodel: claude-fable-5\n---\nDo the slice.\n' > "$TR_AGENTS/executor.md"
    tr_env TIER_OVERDRIVE 1
    tier_reconcile "$stub"
    [ "$status" -eq 0 ]
    [ "$(fm_of "$TR_AGENTS/executor.md")" = "claude-fable-5" ]

    # a missing settings file is a silent no-op, and is never created
    rm -f "$TR"
    tier_reconcile
    [ "$status" -eq 0 ]
    [ ! -f "$TR" ]
}

@test "tier-reconcile: the legacy env-var purge still runs under overdrive, and never eats the flag" {
    tier_reconcile_fixture claude-fable-5
    jq '.env = {"KEEP":"1","TIER_OVERDRIVE":"1","CLAUDE_CODE_SUBAGENT_MODEL":"bad","ANTHROPIC_DEFAULT_SONNET_MODEL":"x"}' "$TR" > "$TR.x"
    mv "$TR.x" "$TR"
    tier_reconcile
    [ "$status" -eq 0 ]
    jq -e '(.env | has("CLAUDE_CODE_SUBAGENT_MODEL")) | not' "$TR"
    jq -e '(.env | keys | map(select(startswith("ANTHROPIC_DEFAULT"))) | length) == 0' "$TR"
    jq -e '.env.TIER_OVERDRIVE == "1"' "$TR"
    jq -e '.env.KEEP == "1"' "$TR"
    [ "$(fm_of "$TR_AGENTS/executor.md")" = "claude-fable-5" ]
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
    [[ "$output" == *"register a CHECK/PASS-IF acceptance contract"* ]]
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

@test "tier-prime: TIER_OVERDRIVE=1 states the lift on the same single trio line" {
    # overdrive is expensive and must never run silently: the SessionStart trio
    # line has to say so itself, on ONE line, and name the way out.
    setup_prime_agents
    printf '{"model":"claude-fable-5[1m]","env":{"TIER_OVERDRIVE":"1"}}\n' > "$SETTINGS"
    run "$PRIME"
    [ "$status" -eq 0 ]
    expected='tier → orchestrator(settings model)=claude-fable-5[1m]  executor=claude-sonnet-5  scout=claude-haiku-4-5-20251001 | verifier+oracle inherit the session model | OVERDRIVE: worker cap lifted — /tier <top> to clear'
    [ "$output" = "$expected" ]
    [ "${#lines[@]}" -eq 1 ]
    # a compaction must not launder the notice out either
    run "$PRIME" --full
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"OVERDRIVE: worker cap lifted"* ]]
}

@test "tier-prime: only the exact flag value \"1\" states overdrive — the trio line is otherwise byte-identical" {
    setup_prime_agents
    expected='tier → orchestrator(settings model)=claude-fable-5[1m]  executor=claude-sonnet-5  scout=claude-haiku-4-5-20251001 | verifier+oracle inherit the session model'
    for v in 0 true yes ""; do
        printf '{"model":"claude-fable-5[1m]","env":{"TIER_OVERDRIVE":"%s"}}\n' "$v" > "$SETTINGS"
        run "$PRIME"
        [ "$status" -eq 0 ]
        [ "$output" = "$expected" ]
    done
    printf '{"model":"claude-fable-5[1m]"}\n' > "$SETTINGS"
    run "$PRIME"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
}

@test "tier-prime: default mode appends the short lane line when lane is installed" {
    setup_prime_agents
    export TIER_PRIME_LANE="$REPO_ROOT/scripts/lane.sh"
    run "$PRIME"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "tier → orchestrator(settings model)="* ]]
    [[ "$output" == *"[lane] route first"* ]]
    [[ "$output" == *"express: inline, no ceremony"* ]]
    [[ "$output" != *"Ties go to the LIGHTER lane"* ]]
}

@test "tier-prime: --full appends the full lane rubric (a compaction must not lose the router)" {
    setup_prime_agents
    export TIER_PRIME_LANE="$REPO_ROOT/scripts/lane.sh"
    run "$PRIME" --full
    [ "$status" -eq 0 ]
    [[ "$output" == *"standing authorization"* ]]
    [[ "$output" == *"[lane] Route first"* ]]
    [[ "$output" == *"Ties go to the LIGHTER lane"* ]]
    [[ "$output" == *"the request AS ASKED"* ]]
}

@test "tier-prime: an absent lane binary changes nothing — output is the pre-lane text in both modes" {
    setup_prime_agents
    export TIER_PRIME_LANE="$BATS_TEST_TMPDIR/definitely-not-installed"
    run "$PRIME"
    [ "$status" -eq 0 ]
    expected='tier → orchestrator(settings model)=claude-fable-5[1m]  executor=claude-sonnet-5  scout=claude-haiku-4-5-20251001 | verifier+oracle inherit the session model'
    [ "$output" = "$expected" ]
    run "$PRIME" --full
    [ "$status" -eq 0 ]
    [[ "$output" == *"standing authorization"* ]]
    [[ "$output" != *"[lane]"* ]]
}

@test "config/claude-settings.json: UserPromptSubmit resets the lane before the tier reconciler runs" {
    jq -e '[.hooks.UserPromptSubmit[].hooks[].command] | any(contains("lane --reset"))' "$SETTINGS_JSON"
    run jq -r '[.hooks.UserPromptSubmit[].hooks[].command] | map(select(contains("lane --reset") or contains("tier-reconcile"))) | length' "$SETTINGS_JSON"
    [ "$output" = "2" ]
    run jq -r '[.hooks.UserPromptSubmit[].hooks[].command] | map(contains("lane --reset")) | index(true)' "$SETTINGS_JSON"
    [ "$output" = "0" ]
}

@test "config/claude-settings.json: the dispatch echo sources its tail from lane, keeping the static tail as the pre-lane fallback" {
    jq -e '[.hooks.UserPromptSubmit[].hooks[].command] | any(contains("lane --prime --short"))' "$SETTINGS_JSON"
    jq -e '[.hooks.UserPromptSubmit[].hooks[].command] | any(contains("dispatch: recon→scout"))' "$SETTINGS_JSON"
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
    # lifetime data alone. That LIFETIME_VERSION has since been bumped to 4
    # in its own right (the row ledger) and now reads the same as
    # STATE_VERSION is a numeric coincidence across two namespaces, not a
    # coupling: different files, checked independently.
    mk_transcript
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR" > /dev/null
    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"
    [ -f "$LIFETIME" ]
    jq -e '.v == 4' "$LIFETIME"
    jq -e 'any(.sessions[]; .tokens_out == 10)' "$LIFETIME"
}

@test "cost-mirror: a pre-fix lifetime.json (old LIFETIME_VERSION, poisoned doubled counters) is rebuilt clean, not carried forward" {
    mkdir -p "$COST_MIRROR_STATE_DIR"
    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"
    printf '{"v":2,"sessions":{"deadsess|main|claude-opus-5":{"in":0,"out":99999999,"cr":0,"w5":0,"w1":0,"project":"ghost","mtime":1,"tp":"/nope.jsonl","sessionId":"deadsess"}}}' \
        > "$LIFETIME"
    mk_transcript
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR" > /dev/null
    jq -e '.v == 4' "$LIFETIME"
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

@test "cost-mirror: de-dup ring eviction no longer re-doubles in/cache-r/cache-w (bd-zjb) — n=8 intervening ids" {
    # DEDUP_RING is 8: a message.id whose two rows are separated by >=8
    # OTHER distinct ids used to fall off the live ring silently, and its
    # later row was then indistinguishable from an untracked id's genuine
    # first row -- counted in full a SECOND time. n=7 intervening ids stays
    # inside the ring (no eviction: correct baseline, asserted first); n=8
    # crosses it. Before the bd-zjb fix, the n=8 case below reported
    # in=2000000 (doubled) at $10 -- confirmed by reverting the fix locally
    # and re-running this exact test, which failed on both assertions; see
    # the slice report for that before/after. After the fix it reports
    # in=1000000 at $5.00, matching n=7 on the dollar figure exactly (output
    # keeps a small, accepted, dollar-negligible residual — see
    # DEDUP_EVICTED_RING's comment in cost-mirror.py — which is why this
    # test does not also assert an exact "out" value).
    TP7="$BATS_TEST_TMPDIR/proj-ring7/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-ring7"
    {
        printf '{"message":{"id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":10}}}\n'
        for i in 0 1 2 3 4 5 6; do
            printf '{"message":{"id":"msg_F%s","model":"claude-opus-5","usage":{"input_tokens":0,"output_tokens":0}}}\n' "$i"
        done
        printf '{"message":{"id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":20}}}\n'
    } > "$TP7"
    run python3 "$MIRROR" --report "$TP7"
    [ "$status" -eq 0 ]
    MAIN_LINE=$(echo "$output" | grep '^main')
    read -r -a F7 <<< "$MAIN_LINE"
    [ "${F7[2]}" = "1000000" ]  # in — 7 intervening ids: ring not evicted
    [ "${F7[6]}" = '$5.00' ]

    TP8="$BATS_TEST_TMPDIR/proj-ring8/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-ring8"
    {
        printf '{"message":{"id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":10}}}\n'
        for i in 0 1 2 3 4 5 6 7; do
            printf '{"message":{"id":"msg_F%s","model":"claude-opus-5","usage":{"input_tokens":0,"output_tokens":0}}}\n' "$i"
        done
        printf '{"message":{"id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":20}}}\n'
    } > "$TP8"
    run python3 "$MIRROR" --report "$TP8"
    [ "$status" -eq 0 ]
    MAIN_LINE=$(echo "$output" | grep '^main')
    read -r -a F8 <<< "$MAIN_LINE"
    [ "${F8[2]}" = "1000000" ]  # in — 8 intervening ids: must NOT double to 2000000
    [ "${F8[6]}" = '$5.00' ]    # actual $ — must NOT double to $10
}

@test "cost-mirror: cross-file duplication — a message.id shared between a main-transcript sidechain row and a co-located subagent file is counted ONCE (bd-6vy, session-scoped dedup)" {
    # Inverted from the prior "IS counted twice today (documented
    # structural limitation, bd-zjb)" pin: the dedup ring used to live in
    # per-FILE fstate (scan_session gave each scanned file, main transcript
    # included, its own independent files_state[path] entry), so there was
    # no cross-file correlation by message.id at all. If the SAME response
    # was logged in two places (here: an isSidechain:true row inline in the
    # main transcript, and a full row in a co-located
    # subagents/agent-x.jsonl sharing that row's message.id), each file's
    # independent ring saw it as that file's own first (and only) row for
    # the id and counted it in full -- so the total came out at double the
    # true response. Before bd-6vy this test asserted exactly that doubled
    # total (in=600000/out=200/cache-r=100000, 2x the single response's true
    # 300000/100/50000) as a known limitation, confirmed empirically for
    # bd-zjb -- not observed firing in any real transcript on the machines
    # checked then (0 isSidechain rows in any top-level transcript on disk),
    # only shown reachable in principle. bd-6vy promotes the dedup ring from
    # per-file to per-session (see scan_session/scan_file's dedup_state and
    # the module docstring's "De-dup promoted to per-SESSION" section): one
    # ring, homed in the main transcript's own fstate, shared by every file
    # scan_session scans for that session, so the second row (whichever file
    # it lands in) is now recognised as a repeat of the first and correctly
    # suppressed -- the total below asserts the TRUE undoubled values.
    TP="$BATS_TEST_TMPDIR/proj-crossfile/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-crossfile/sess/subagents"
    printf '{"isSidechain":true,"message":{"id":"msg_shared","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":300000,"output_tokens":100,"cache_read_input_tokens":50000}}}\n' \
        > "$TP"
    printf '{"message":{"id":"msg_shared","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":300000,"output_tokens":100,"cache_read_input_tokens":50000}}}\n' \
        > "$BATS_TEST_TMPDIR/proj-crossfile/sess/subagents/agent-x.jsonl"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    WORKER_LINE=$(echo "$output" | grep '^worker ')
    read -r -a F <<< "$WORKER_LINE"
    [ "${F[2]}" = "300000" ]   # in  — the single response's true value, not 2x
    [ "${F[3]}" = "100" ]      # out — the single response's true value, not 2x
    [ "${F[4]}" = "50000" ]    # cache-r — the single response's true value, not 2x
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

@test "cost-mirror: end-to-end regression — dedup + flat subagent + nested workflow subagent sum to a known exact dollar total (bd-zjb)" {
    # Pins the arithmetic the bd-zjb inflation investigation could NOT fault:
    # a message.id group split across 3 rows (dedup must count input once and
    # take the group's max/final output, not sum every row), a flat
    # subagents/*.jsonl worker, and a subagents/workflows/<wf>/*.jsonl nested
    # worker, all priced and summed to one hand-computed TOTAL. If a future
    # change reintroduces per-row (rather than per-message.id) counting, or
    # double-scans a file, or drops the recursive workflow glob, this total
    # moves and the test fails on an unambiguous exact figure rather than a
    # fuzzy "looks about right".
    #
    # main (claude-opus-5, $5 in / $25 out per MTok): one response split into
    # 3 rows sharing message.id "msg_A" -- input repeats 200000 on every row
    # (dedup: counted ONCE, not x3), output is cumulative 4000, 4000, 44000
    # (dedup: counted as the group's max/final 44000, not summed to 52000).
    #   cost = (200000*5 + 44000*25) / 1e6                       = $2.10
    # worker:executor (claude-haiku-4-5-20251001, $1 in / $5 out per MTok):
    # one flat subagents/agent-w1.jsonl row, no message.id (standalone, never
    # deduped) -- input 500000, output 100000.
    #   cost = (500000*1 + 100000*5) / 1e6                       = $1.00
    # worker (bare -- no sidecar, claude-fable-5, $10 in / $50 out per MTok):
    # one NESTED subagents/workflows/wf1/agent-w2.jsonl row -- input 10000,
    # output 2000. Bare "worker", not "worker:executor", proves this row is
    # attributed separately from the flat subagent above, not folded into it.
    #   cost = (10000*10 + 2000*50) / 1e6                        = $0.20
    # TOTAL actual $                                              = $3.30
    TP="$BATS_TEST_TMPDIR/proj-e2e/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-e2e/sess/subagents/workflows/wf1"
    {
        printf '{"message":{"id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":200000,"output_tokens":4000}}}\n'
        printf '{"message":{"id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":200000,"output_tokens":4000}}}\n'
        printf '{"message":{"id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":200000,"output_tokens":44000}}}\n'
    } > "$TP"
    printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":500000,"output_tokens":100000}}}\n' \
        > "$BATS_TEST_TMPDIR/proj-e2e/sess/subagents/agent-w1.jsonl"
    printf '{"agentType":"executor"}' \
        > "$BATS_TEST_TMPDIR/proj-e2e/sess/subagents/agent-w1.meta.json"
    printf '{"message":{"model":"claude-fable-5","usage":{"input_tokens":10000,"output_tokens":2000}}}\n' \
        > "$BATS_TEST_TMPDIR/proj-e2e/sess/subagents/workflows/wf1/agent-w2.jsonl"

    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]

    MAIN_LINE=$(echo "$output" | grep '^main')
    read -r -a M <<< "$MAIN_LINE"
    [ "${M[2]}" = "200000" ]   # in — deduped to one copy, not 600000
    [ "${M[3]}" = "44000" ]    # out — group max/final, not summed to 52000
    [ "${M[6]}" = '$2.10' ]

    EXEC_LINE=$(echo "$output" | grep '^worker:executor')
    read -r -a E <<< "$EXEC_LINE"
    [ "${E[6]}" = '$1.00' ]

    BARE_LINE=$(echo "$output" | grep '^worker ')
    read -r -a B <<< "$BARE_LINE"
    [ "${B[6]}" = '$0.20' ]

    TOTAL_LINE=$(echo "$output" | grep '^TOTAL')
    read -r -a T <<< "$TOTAL_LINE"
    [ "${T[5]}" = '$3.30' ]
}

@test "cost-mirror: PRICING_TABLE prefix order resolves opus/sonnet-5/sonnet/unknown unambiguously (unit-level, not by eye)" {
    # bd-zjb criterion 3: prefix matching is ordered (first match wins), so a
    # mis-ordered or overly broad prefix could silently misprice a whole
    # family. Checked directly against rates_for(), not by eyeballing the
    # table: a real opus id resolves to the flat opus rate; a generic sonnet
    # id (sonnet-4-family) must NOT match the specific "claude-sonnet-5"
    # entry and so must be date-independent; a "claude-sonnet-5..." id MUST
    # route through the specific entry's _sonnet5_rates() callable rather
    # than falling through to the generic "claude-sonnet-" rate (checked by
    # cross-calling _sonnet5_rates() directly, so this stays a valid check on
    # either side of the 2026-09-01 intro-pricing cutoff -- see the dedicated
    # cutoff test above for the callable's own date-boundary correctness);
    # and a model matching no prefix at all falls through to None rather than
    # guessing.
    run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('cost_mirror_under_test', '$MIRROR')
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)

def rate_pair(model):
    r = cm.rates_for(model)
    return (r['in'], r['out']) if r else None

assert rate_pair('claude-opus-4-6-20260101') == (5.0, 25.0), 'opus family mispriced'
assert rate_pair('claude-sonnet-4-5-20250929') == (3.0, 15.0), 'generic sonnet must not hit the sonnet-5 entry'
assert rate_pair('claude-sonnet-5-20260101') == cm._sonnet5_rates(), 'sonnet-5 must route through the specific entry, not the generic fallback'
assert rate_pair('claude-haiku-4-5-20251001') == (1.0, 5.0), 'haiku family mispriced'
assert rate_pair('claude-mythos-5') == (10.0, 50.0), 'mythos family mispriced'
assert cm.rates_for('claude-totally-unknown-model-9') is None, 'unknown model must fall through to None, not guess'
print('ALL PREFIX ORDER CASES OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ALL PREFIX ORDER CASES OK"* ]]
}

@test "cost-mirror: baked-path pricing (snapshot absent) — Opus 4/4.1 at 15/75, Opus 4.5+ at 5/25, Claude 3-era ids non-None (bd-1dm)" {
    # bd-1dm: fix for Opus family pricing in the FALLBACK path. With the
    # litellm snapshot present, these resolve correctly. This test exercises
    # the baked path (PRICING_TABLE) by suppressing the snapshot, verifying
    # that the table correctly prices:
    # - Opus 4 and Opus 4.1 at 15/75 USD/MTok (not the flattened 5/25)
    # - Opus 4.5 and Opus 5 remain at 5/25
    # - Claude 3-era models are non-None (not missing)
    run python3 -c "
import os
import importlib.util

# Suppress the snapshot to force baked-path resolution
os.environ['COST_MIRROR_PRICING_PATH'] = '$BATS_TEST_TMPDIR/nonexistent-snapshot.json'

spec = importlib.util.spec_from_file_location('cost_mirror_under_test', '$MIRROR')
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)

def rate_pair(model):
    r = cm.rates_for(model)
    return (r['in'], r['out']) if r else None

# Opus 4 and 4.1 should be 15/75 in baked path
assert rate_pair('claude-opus-4-20250514') == (15.0, 75.0), f'Opus 4 should be 15/75, got {rate_pair(\"claude-opus-4-20250514\")}'
assert rate_pair('claude-opus-4-1') == (15.0, 75.0), f'Opus 4.1 should be 15/75, got {rate_pair(\"claude-opus-4-1\")}'

# Opus 4.5 and 5 should remain at 5/25
assert rate_pair('claude-opus-4-5-20250929') == (5.0, 25.0), f'Opus 4.5 should be 5/25, got {rate_pair(\"claude-opus-4-5-20250929\")}'
assert rate_pair('claude-opus-5-20260101') == (5.0, 25.0), f'Opus 5 should be 5/25, got {rate_pair(\"claude-opus-5-20260101\")}'

# Claude 3-era models should be non-None in baked path
assert cm.rates_for('claude-3-opus-20240229') is not None, 'Claude 3 Opus should be non-None'
assert cm.rates_for('claude-3-7-sonnet-20250219') is not None, 'Claude 3.7 Sonnet should be non-None'
assert cm.rates_for('claude-3-haiku-20240307') is not None, 'Claude 3 Haiku should be non-None'

print('BAKED PATH PRICING OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BAKED PATH PRICING OK"* ]]
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

@test "cost-mirror: render_report sorts rows within a side by actual dollar cost, not token volume (bd-cro)" {
    # fable ($10/$50 per MTok) at LOW volume must outrank haiku ($1/$5 per
    # MTok) at HIGHER volume once cost, not volume, drives the order -- this
    # is exactly the case the old -(out + cr) key got backwards.
    #   fable-5: out=100000 -> $5.00  (volume 100000)
    #   haiku:   out=500000 -> $2.50  (volume 500000 -- MORE than fable's)
    #   opus-5:  out=60000  -> $1.50  (volume 60000)
    # old volume order:  haiku(500k) > fable(100k) > opus(60k)
    # new cost order:    fable($5.00) > haiku($2.50) > opus($1.50)
    TP="$BATS_TEST_TMPDIR/proj-costsort/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-costsort"
    {
        printf '{"message":{"model":"claude-fable-5","usage":{"output_tokens":100000}}}\n'
        printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":500000}}}\n'
        printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":60000}}}\n'
    } > "$TP"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    ORDER=$(echo "$output" | grep '^main' | awk '{print $2}' | tr '\n' ' ')
    [ "$ORDER" = "fable-5 haiku-4-5-20251001 opus-5 " ]
}

@test "cost-mirror: unpriced models sort to the bottom of their side regardless of volume, tiebroken by model id (bd-cro)" {
    # claude-alpha-1 is unpriced but carries a MASSIVE volume -- proving the
    # old -(out+cr) key would have put it first, while the new cost key
    # (cost() == 0.0 for an unpriced model, already the minimum any row can
    # sort to) correctly puts it last, tied with the other unpriced row
    # claude-zeta-9 and broken alphabetically by model id.
    TP="$BATS_TEST_TMPDIR/proj-unpriced/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-unpriced"
    {
        printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":200000}}}\n'
        printf '{"message":{"model":"claude-alpha-1","usage":{"output_tokens":999999999}}}\n'
        printf '{"message":{"model":"claude-zeta-9","usage":{"output_tokens":1}}}\n'
    } > "$TP"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    ORDER=$(echo "$output" | grep '^main' | awk '{print $2}' | tr '\n' ' ')
    [ "$ORDER" = "haiku-4-5-20251001 alpha-1? zeta-9? " ]
}

@test "cost-mirror --report: row order is deterministic across repeated runs on identical input (bd-cro)" {
    TP="$BATS_TEST_TMPDIR/proj-determinism/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-determinism"
    {
        printf '{"message":{"model":"claude-fable-5","usage":{"output_tokens":100000}}}\n'
        printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":500000}}}\n'
        printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":60000}}}\n'
        printf '{"message":{"model":"claude-alpha-1","usage":{"output_tokens":999999999}}}\n'
        printf '{"message":{"model":"claude-zeta-9","usage":{"output_tokens":1}}}\n'
    } > "$TP"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    FIRST="$output"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    SECOND="$output"
    diff <(echo "$FIRST") <(echo "$SECOND")
    [ "$FIRST" = "$SECOND" ]
}

@test "cost-mirror: side grouping still wins over cost -- main is listed before a far pricier worker row (bd-cro)" {
    TP="$BATS_TEST_TMPDIR/proj-grouping/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-grouping/sess/subagents"
    printf '{"message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000}}}\n' > "$TP"
    printf '{"message":{"model":"claude-fable-5","usage":{"output_tokens":1000000}}}\n' \
        > "$BATS_TEST_TMPDIR/proj-grouping/sess/subagents/agent-w1.jsonl"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    SIDES=$(echo "$output" | grep -E '^(main|worker)' | awk '{print $1}' | tr '\n' ' ')
    [ "$SIDES" = "main worker " ]
}

@test "cost-mirror: a model-in-name spawn (new naming convention) still labels as bare worker:<role>, not fragmented (bd-8ty)" {
    # bd-8ty's convention: name = "<role>-<model-slug>[-<topic>]", e.g.
    # "executor-sonnet-5-cost" -- a REAL sidecar shape seen live in this
    # container. agentType carries the name, customAgentType the true role;
    # _agent_label must still resolve "executor", not "executor-sonnet-5-cost".
    TP="$BATS_TEST_TMPDIR/proj-namedconv/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-namedconv/sess/subagents"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":10}}}\n' > "$TP"
    printf '{"message":{"model":"claude-sonnet-5","usage":{"output_tokens":40000}}}\n' \
        > "$BATS_TEST_TMPDIR/proj-namedconv/sess/subagents/agent-x1.jsonl"
    printf '{"agentType":"executor-sonnet-5-cost","name":"executor-sonnet-5-cost","customAgentType":"executor"}' \
        > "$BATS_TEST_TMPDIR/proj-namedconv/sess/subagents/agent-x1.meta.json"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    ROLE_LINE=$(echo "$output" | grep '^worker:executor')
    [ -n "$ROLE_LINE" ]
    [[ "$output" != *"worker:executor-sonnet-5-cost"* ]]
}

@test "cost-mirror: a model:inherit role (verifier/oracle) shows the resolved model, never the literal 'inherit' (bd-8ty)" {
    # Mirrors a REAL live sidecar this container produced:
    # {"agentType":"verifier-opus-5-resume","customAgentType":"verifier"}.
    # message.model in the transcript is always the API-resolved id, never
    # the frontmatter's "inherit" -- no code change was needed for this;
    # this pins that fact.
    # NOTE: the fixture dir is deliberately NOT named "*inherit*" -- render_report's
    # header line prints the transcript path verbatim, so that substring would
    # leak into $output and produce a false positive on the check below.
    TP="$BATS_TEST_TMPDIR/proj-modelrole/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-modelrole/sess/subagents"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":10}}}\n' > "$TP"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":50000}}}\n' \
        > "$BATS_TEST_TMPDIR/proj-modelrole/sess/subagents/agent-v1.jsonl"
    printf '{"agentType":"verifier-opus-5-resume","name":"verifier-opus-5-resume","customAgentType":"verifier"}' \
        > "$BATS_TEST_TMPDIR/proj-modelrole/sess/subagents/agent-v1.meta.json"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    ROLE_LINE=$(echo "$output" | grep '^worker:verifier')
    [ -n "$ROLE_LINE" ]
    [[ "$ROLE_LINE" == *"opus-5"* ]]
    [[ "$output" != *"inherit"* ]]
}

@test "cost-mirror: pricing math — known token counts across two models produce the exact dollar clause" {
    mk_pricing_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"~\$26 · ~\$53 at fable-5 → saved ~\$27"* ]]
}

@test "cost-mirror: under overdrive the savings counterfactual is replaced by an explicit n/a marker" {
    # `tier-set overdrive` lifts the worker cap (.env.TIER_OVERDRIVE="1"), so
    # "what this would have cost at the top model" stops being a
    # counterfactual — the worker IS the top model. This fixture's real $27 of
    # historical savings must not keep printing as if delegation were still
    # buying anything.
    mk_pricing_transcript
    printf '{"model":"claude-fable-5","env":{"TIER_OVERDRIVE":"1"}}\n' > "$SETTINGS"
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"~\$26 · tier savings n/a (OVERDRIVE)"* ]]
    [[ "$output" != *"saved ~\$"* ]]
    [[ "$output" != *"at fable-5"* ]]
}

@test "cost-mirror: without the exact flag value \"1\" the hook dollar clause is byte-identical to today" {
    mk_pricing_transcript
    for v in 0 true yes ""; do
        printf '{"model":"claude-fable-5","env":{"TIER_OVERDRIVE":"%s"}}\n' "$v" > "$SETTINGS"
        run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
        [ "$status" -eq 0 ]
        [[ "$output" == *"~\$26 · ~\$53 at fable-5 → saved ~\$27"* ]]
        [[ "$output" != *"OVERDRIVE"* ]]
    done
    # an unreadable/absent settings file is the same as flag-off, never a crash
    rm -f "$SETTINGS"
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

# ── cost-mirror: the row ledger (immutable rows carrying their own rates) ───

mk_sonnet_projects() {
    # One sonnet-5-only session: 1M in + 1M out, so the report's dollars move
    # VISIBLY when the intro price lapses at SONNET5_INTRO_CUTOFF (2/10 ->
    # 3/15 USD/MTok, i.e. $12 -> $18) unless the persisted rows carry the
    # rates that priced them. No "timestamp" field, so every row lands in the
    # NA bucket (-1) and the ledger key is stable run to run.
    SONDIR="$BATS_TEST_TMPDIR/sonnet-projects"
    mkdir -p "$SONDIR/proj-s"
    printf '{"message":{"model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":1000000}}}\n' \
        > "$SONDIR/proj-s/sess-s.jsonl"
    export COST_MIRROR_PROJECTS_DIR="$SONDIR"
}

report_on_date() {
    # The aggregate report with the module's clock pinned to $1 (ISO date),
    # so a pricing cutoff can be crossed deterministically instead of
    # depending on when the suite happens to run. Both endpoints of every
    # comparison below are pinned for that reason -- a test that compared a
    # pinned date against "now" would quietly change meaning the day the real
    # clock passes the cutoff. Patching the module's `date` global covers
    # every clock read that can move a dollar figure (_sonnet5_rates, and
    # render_report's intro-pricing note).
    python3 -c "
import importlib.util, sys
from datetime import date as _date
spec = importlib.util.spec_from_file_location('cost_mirror_under_test', '$MIRROR')
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)
class _Pinned(_date):
    @classmethod
    def today(cls):
        return _date.fromisoformat('$1')
cm.date = _Pinned
sys.exit(cm.run_report([]))
"
}

@test "cost-mirror: lifetime.json is a v4 ledger of session|side|model|bucket rows carrying the rates that priced them" {
    mk_transcript
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR" > /dev/null
    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"
    [ -f "$LIFETIME" ]
    jq -e '.v == 4' "$LIFETIME"
    # no row in this fixture carries a timestamp, so every row shares the NA
    # bucket -- the key still NAMES the bucket, unlike v3's collapsed
    # "<session>|<side>|<model>", which is the dimension this slice restores
    jq -e '.sessions["sess|main|claude-opus-5|-1"].tokens_out == 10' "$LIFETIME"
    jq -e '.sessions["sess|main|claude-opus-5|-1"].tokens_cr == 100' "$LIFETIME"
    jq -e '.sessions["sess|main|claude-opus-5|-1"].bucket == -1' "$LIFETIME"
    jq -e '.sessions["sess|main|claude-opus-5|-1"].rate_out == 25' "$LIFETIME"
    jq -e '.sessions["sess|main|claude-opus-5|-1"].cost_out == (10 * 25 / 1000000)' "$LIFETIME"
    jq -e '.sessions["sess|main|claude-opus-5|-1"].pricing_source == "baked"' "$LIFETIME"
    jq -e '.sessions["sess|main|claude-opus-5|-1"].pricing_id == "baked:claude-opus-"' "$LIFETIME"
    # the sidechain row in the main transcript and the subagent file share
    # one side/model/bucket, so they are ONE row (5 + 7 out, 50 + 70 cache-r)
    jq -e '.sessions["sess|worker|claude-haiku-4-5-20251001|-1"].tokens_out == 12' "$LIFETIME"
    jq -e '.sessions["sess|worker|claude-haiku-4-5-20251001|-1"].tokens_cr == 120' "$LIFETIME"
}

@test "cost-mirror: every persisted ledger row's dollars reconcile to its own tokens at its own frozen rates" {
    mk_all_projects
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"
    jq -e '[.sessions[] | select(.rate_in != null)] | length >= 2' "$LIFETIME"
    # a row is arithmetically self-contained: every cost is that row's own
    # tokens at that row's own rate, and cost_total is the sum of the five.
    # 1e-9 absorbs float noise and nothing else.
    jq -e '[.sessions[] | select(.rate_in != null) | (["in","out","cr","w5","w1"][]) as $k | ((.["cost_" + $k] - (.["tokens_" + $k] * .["rate_" + $k] / 1000000)) | fabs) > 1e-9] | any | not' "$LIFETIME"
    jq -e '[.sessions[] | select(.rate_in != null) | ((.cost_total - ([.cost_in, .cost_out, .cost_cr, .cost_w5, .cost_w1] | add)) | fabs) > 1e-9] | any | not' "$LIFETIME"
}

@test "cost-mirror: a message.id group collapses to ONE ledger row — tokens_out the group max, tokens_in counted once" {
    # Same shape as the de-dup report test above (three rows, one message.id,
    # cumulative output_tokens). Asserted on the PERSISTED row this time: a
    # ledger that re-derived rows from transcript rows rather than from the
    # already-deduped bucket counters would write 150 in / 577 out here. No
    # timestamps, so all three rows share the NA bucket and cannot split.
    DEDUPDIR="$BATS_TEST_TMPDIR/dedup-projects"
    mkdir -p "$DEDUPDIR/proj-d"
    {
        printf '{"message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":50,"output_tokens":3,"cache_read_input_tokens":100}}}\n'
        printf '{"message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":50,"output_tokens":3,"cache_read_input_tokens":100}}}\n'
        printf '{"message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":50,"output_tokens":571,"cache_read_input_tokens":100}}}\n'
    } > "$DEDUPDIR/proj-d/sess-d.jsonl"
    export COST_MIRROR_PROJECTS_DIR="$DEDUPDIR"
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"
    jq -e '[.sessions | keys[] | select(startswith("sess-d|main|claude-opus-5"))] | length == 1' "$LIFETIME"
    jq -e '.sessions["sess-d|main|claude-opus-5|-1"].tokens_in == 50' "$LIFETIME"
    jq -e '.sessions["sess-d|main|claude-opus-5|-1"].tokens_out == 571' "$LIFETIME"
    jq -e '.sessions["sess-d|main|claude-opus-5|-1"].tokens_cr == 100' "$LIFETIME"
}

@test "cost-mirror: a v3 lifetime.json migrates in place to v4 legacy rows — marked unknown, never back-filled with rates" {
    mkdir -p "$COST_MIRROR_STATE_DIR"
    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"
    printf '{"v":3,"sessions":{"deadsess|main|claude-sonnet-5":{"in":10,"out":20,"cr":30,"w5":40,"w1":50,"project":"ghost","mtime":1,"tp":"/nope.jsonl","sessionId":"deadsess"}}}' \
        > "$LIFETIME"
    mk_transcript
    sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR" > /dev/null
    jq -e '.v == 4' "$LIFETIME"
    # the v3 row survives as ONE legacy row per (session, side, model): its
    # counters renamed, never reinterpreted as bucket-level, and never given
    # rates it was not priced with
    jq -e '.sessions["deadsess|main|claude-sonnet-5"].tokens_out == 20' "$LIFETIME"
    jq -e '.sessions["deadsess|main|claude-sonnet-5"].side == "main"' "$LIFETIME"
    jq -e '.sessions["deadsess|main|claude-sonnet-5"].model == "claude-sonnet-5"' "$LIFETIME"
    jq -e '.sessions["deadsess|main|claude-sonnet-5"].bucket == null' "$LIFETIME"
    jq -e '.sessions["deadsess|main|claude-sonnet-5"].pricing_source == "unknown"' "$LIFETIME"
    jq -e '.sessions["deadsess|main|claude-sonnet-5"].rate_in == null' "$LIFETIME"
    jq -e '.sessions["deadsess|main|claude-sonnet-5"].cost_total == null' "$LIFETIME"
}

@test "cost-mirror --report: a re-run past the sonnet-5 cutoff reports the SAME historical dollars over unchanged transcripts" {
    mk_sonnet_projects
    run report_on_date 2026-08-15
    [ "$status" -eq 0 ]
    BEFORE=$(echo "$output" | grep '^TOTAL')
    [[ "$BEFORE" == *'$12'* ]]
    run report_on_date 2026-09-15
    [ "$status" -eq 0 ]
    AFTER=$(echo "$output" | grep '^TOTAL')
    [ "$BEFORE" = "$AFTER" ]
    # control: the same transcript priced COLD past the cutoff really does
    # cost more, so the equality above is a frozen ledger rather than a clock
    # that never moved
    rm -rf "$COST_MIRROR_STATE_DIR"
    run report_on_date 2026-09-15
    [ "$status" -eq 0 ]
    COLD=$(echo "$output" | grep '^TOTAL')
    [[ "$COLD" == *'$18'* ]]
}

@test "cost-mirror --report: a scanned row is priced from the rates the LEDGER carries, not from today's table" {
    mk_sonnet_projects
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    [[ "$output" == *'$12'* ]]
    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"
    ROW="sess-s|main|claude-sonnet-5|-1"
    # rewrite the frozen out-rate to a figure no pricing table would ever
    # produce; a report that re-derives from rates_for ignores it entirely
    jq --arg row "$ROW" '.sessions[$row].rate_out = 100' "$LIFETIME" > "$LIFETIME.edited"
    mv "$LIFETIME.edited" "$LIFETIME"
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    TOTAL=$(echo "$output" | grep '^TOTAL')
    [[ "$TOTAL" == *'$102'* ]]
    # and the rescan REPLACED the row without re-pricing it: the frozen rate
    # survives, its cost recomputed from that rate
    jq -e --arg row "$ROW" '.sessions[$row].rate_out == 100' "$LIFETIME"
    jq -e --arg row "$ROW" '.sessions[$row].cost_out == 100' "$LIFETIME"
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

# ── cost-mirror: complexity-router lane join ────────────────────────────────
#
# scripts/lane.sh appends one row per declaration to
# $LANE_STATE_DIR/log.jsonl. cost-mirror joins that log on two surfaces: a
# trailing " | lane last-turn: <x>" segment on the per-prompt hook line, and
# a "lanes" section beneath --report. The fixture is built by DRIVING lane.sh
# rather than hand-writing JSON, so these tests pin the format lane actually
# emits (including a genuine "escalated":true) instead of an assumed one.

LANE="$REPO_ROOT/scripts/lane.sh"

mk_lane_log() {
    # 4 declarations across 2 sessions, exactly one of them an escalation
    # (session "sess": express -> deep), plus two unparseable lines — one
    # mid-log, one as the very last line, so the newest-first scan has to
    # skip junk before it finds the row it wants.
    export LANE_STATE_DIR="$BATS_TEST_TMPDIR/lane"
    CLAUDE_CODE_SESSION_ID=sess bash "$LANE" express --why one > /dev/null
    CLAUDE_CODE_SESSION_ID=sess bash "$LANE" deep --why two > /dev/null
    printf 'THIS LINE IS NOT JSON\n' >> "$LANE_STATE_DIR/log.jsonl"
    CLAUDE_CODE_SESSION_ID=other bash "$LANE" standard --why three > /dev/null
    CLAUDE_CODE_SESSION_ID=sess bash "$LANE" standard --why four > /dev/null
    printf '["not","an","object"]\n' >> "$LANE_STATE_DIR/log.jsonl"
}

# collapse the report's column padding so assertions can name a row's cells
# without hard-coding ljust/rjust widths
squash() { echo "$1" | tr -s ' '; }

@test "cost-mirror: hook line carries this session's newest lane, skipping junk and other sessions' rows" {
    mk_transcript
    mk_lane_log
    run sh -c 'printf "{\"transcript_path\":\"%s\",\"session_id\":\"sess\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"| lane last-turn: standard"* ]]
}

@test "cost-mirror: a session that has never declared reads lane last-turn: unset" {
    mk_transcript
    mk_lane_log
    run sh -c 'printf "{\"transcript_path\":\"%s\",\"session_id\":\"fresh\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"| lane last-turn: unset"* ]]
}

@test "cost-mirror: a missing lane log omits the lane segment rather than reporting unset" {
    mk_transcript
    run sh -c 'printf "{\"transcript_path\":\"%s\",\"session_id\":\"sess\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[cost-mirror] this session"* ]]
    [[ "$output" != *"lane last-turn"* ]]
}

@test "cost-mirror: no session_id in the event omits the lane segment without erroring" {
    mk_transcript
    mk_lane_log
    run sh -c 'printf "{\"transcript_path\":\"%s\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[cost-mirror] this session"* ]]
    [[ "$output" != *"lane last-turn"* ]]
}

@test "cost-mirror: the lane segment follows the drift segment on one line, both present" {
    export HOME="$BATS_TEST_TMPDIR/home-lane"
    mkdir -p "$HOME/.claude/cache/delegation-gate"
    printf '{"max_streak":4,"warns":1,"denies":0}' > "$HOME/.claude/cache/delegation-gate/sess.json"
    mk_transcript
    mk_lane_log
    run sh -c 'printf "{\"transcript_path\":\"%s\",\"session_id\":\"sess\"}" "'"$TP"'" | python3 '"$MIRROR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"| inline: max streak 4 · 1 warn | lane last-turn: standard"* ]]
}

@test "cost-mirror --report: lanes section counts this session's declarations and all-time" {
    mk_transcript
    mk_lane_log
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    squashed=$(squash "$output")
    [[ "$squashed" == *"lanes (complexity router — declaration log) — session sess"* ]]
    [[ "$squashed" == *"express 1 1"* ]]
    [[ "$squashed" == *"standard 1 2"* ]]
    [[ "$squashed" == *"deep 1 1"* ]]
    [[ "$squashed" == *"declarations 3 4"* ]]
}

@test "cost-mirror --report: lanes section reports the escalation count and rate against the target band" {
    mk_transcript
    mk_lane_log
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    squashed=$(squash "$output")
    [[ "$squashed" == *"escalations 1 1"* ]]
    [[ "$squashed" == *"escalation rate 33.3% 25.0%"* ]]
    [[ "$squashed" == *"target 5–15% (<5% classifying heavy? · >20% express too greedy?)"* ]]
}

@test "cost-mirror --report: a session with no declarations shows n/a, never a divide-by-zero" {
    mk_lane_log
    TP2="$BATS_TEST_TMPDIR/proj2/nolanes.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj2"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":10}}}\n' > "$TP2"
    run python3 "$MIRROR" --report "$TP2"
    [ "$status" -eq 0 ]
    squashed=$(squash "$output")
    [[ "$squashed" == *"escalation rate n/a 25.0%"* ]]
    [[ "$squashed" == *"declarations 0 4"* ]]
}

@test "cost-mirror --report: a missing lane log omits the lanes section entirely" {
    mk_transcript
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cost-mirror report —"* ]]
    [[ "$output" != *"lanes (complexity router"* ]]
}

@test "cost-mirror --report: a lane log of nothing but junk omits the section and still exits 0" {
    mk_transcript
    export LANE_STATE_DIR="$BATS_TEST_TMPDIR/lane-junk"
    mkdir -p "$LANE_STATE_DIR"
    printf 'NOT JSON\n{oops\n' > "$LANE_STATE_DIR/log.jsonl"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    [[ "$output" != *"lanes (complexity router"* ]]
}

@test "cost-mirror --report: reading the lane log creates no lane state (read-only report)" {
    mk_transcript
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    [ ! -e "$LANE_STATE_DIR" ]
}

@test "cost-mirror --report --all: the lanes section resolves the session from CLAUDE_CODE_SESSION_ID" {
    mk_all_projects
    mk_lane_log
    CLAUDE_CODE_SESSION_ID=other run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    squashed=$(squash "$output")
    [[ "$squashed" == *"— session other"* ]]
    [[ "$squashed" == *"standard 1 2"* ]]
    [[ "$squashed" == *"express 0 1"* ]]
}

@test "cost-mirror --report --all: with no session resolvable the section still reports all-time" {
    mk_all_projects
    mk_lane_log
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    squashed=$(squash "$output")
    [[ "$squashed" == *"— no session resolved"* ]]
    [[ "$squashed" == *"declarations 0 4"* ]]
}

@test "cost-mirror --report --all: an absent CLAUDE_CODE_SESSION_ID falls back to lane's last-session file" {
    mk_all_projects
    mk_lane_log
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    printf 'sess\n' > "$LANE_STATE_DIR/last-session"
    run python3 "$MIRROR" --report --all
    [ "$status" -eq 0 ]
    [[ "$(squash "$output")" == *"— session sess"* ]]
}

# ── cost-mirror: pricing snapshot (fetched rates + provenance) ──────────────
#
# bd-cit: rates_for() used to derive every cache rate from a hardcoded input
# rate (cr=in*0.1, w5=in*1.25, w1=in*2.0) against a static PRICING_TABLE, with
# nothing recording where a figure came from or when. It now resolves a fetched
# snapshot first, falls back to that same baked table, and returns provenance
# (source/fetched_at/pricing_id) alongside the five rates so a row ledger can
# cite what priced it. The snapshot lives in a SUBDIRECTORY of the state dir
# (pricing/snapshot.json) so it stays invisible to the "$COST_MIRROR_STATE_DIR"/*.json
# globs the state-schema tests above use.
#
# Every case here is hermetic: the source payload is served over file:// so the
# transform is exercised end to end without a network, and the "unreachable"
# case points at a refused port rather than waiting on a real timeout.

mk_litellm_payload() {
    # A litellm model_prices_and_context_window.json in miniature. Deliberately
    # mixed: two complete Anthropic first-party entries, one bedrock variant of
    # the same model at a different price, one Anthropic entry missing the
    # cache fields, one non-Anthropic model, and litellm's own schema-doc
    # placeholder — only the two complete Anthropic entries may survive.
    # $1 overrides claude-opus-5's per-token input cost (for the TTL test).
    PAYLOAD="$BATS_TEST_TMPDIR/litellm.json"
    local opus_in="${1:-5e-06}"
    cat > "$PAYLOAD" <<EOF
{
  "sample_spec": {"litellm_provider": "one of the providers"},
  "claude-opus-5": {
    "litellm_provider": "anthropic",
    "input_cost_per_token": $opus_in,
    "output_cost_per_token": 2.5e-05,
    "cache_read_input_token_cost": 5e-07,
    "cache_creation_input_token_cost": 6.25e-06,
    "cache_creation_input_token_cost_above_1hr": 1e-05
  },
  "claude-sonnet-5": {
    "litellm_provider": "anthropic",
    "input_cost_per_token": 2e-06,
    "output_cost_per_token": 1e-05,
    "cache_read_input_token_cost": 2e-07,
    "cache_creation_input_token_cost": 2.5e-06,
    "cache_creation_input_token_cost_above_1hr": 4e-06
  },
  "bedrock/anthropic.claude-opus-5": {
    "litellm_provider": "bedrock",
    "input_cost_per_token": 9.9e-05,
    "output_cost_per_token": 9.9e-05,
    "cache_read_input_token_cost": 9.9e-05,
    "cache_creation_input_token_cost": 9.9e-05,
    "cache_creation_input_token_cost_above_1hr": 9.9e-05
  },
  "claude-4-opus-20250514": {
    "litellm_provider": "anthropic",
    "input_cost_per_token": 1.5e-05,
    "output_cost_per_token": 7.5e-05
  },
  "gpt-4o": {
    "litellm_provider": "openai",
    "input_cost_per_token": 2.5e-06,
    "output_cost_per_token": 1e-05,
    "cache_read_input_token_cost": 1.25e-06,
    "cache_creation_input_token_cost": 1.25e-06,
    "cache_creation_input_token_cost_above_1hr": 1.25e-06
  }
}
EOF
    export COST_MIRROR_PRICING_URL="file://$PAYLOAD"
}

mk_pricing_snapshot() {
    # A ready-made snapshot in the shape --refresh-pricing writes, with the
    # REAL litellm USD/MTok figures for the ladder (verified 2026-08-25) —
    # except claude-opus-4-6, deliberately set to a price the baked table
    # cannot produce (baked "claude-opus-" is 5/25) so "snapshot wins" and
    # longest-prefix resolution are both proven by one assertion.
    SNAP="$COST_MIRROR_STATE_DIR/pricing/snapshot.json"
    mkdir -p "$(dirname "$SNAP")"
    cat > "$SNAP" <<'EOF'
{
  "schema": 1,
  "fetched_at": "2026-08-25T12:00:00+00:00",
  "source": "litellm",
  "url": "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json",
  "rates": {
    "claude-opus-5":              {"in": 5.0,  "out": 25.0, "cr": 0.5, "w5": 6.25,  "w1": 10.0},
    "claude-sonnet-5":            {"in": 2.0,  "out": 10.0, "cr": 0.2, "w5": 2.5,   "w1": 4.0},
    "claude-fable-5":             {"in": 10.0, "out": 50.0, "cr": 1.0, "w5": 12.5,  "w1": 20.0},
    "claude-haiku-4-5-20251001":  {"in": 1.0,  "out": 5.0,  "cr": 0.1, "w5": 1.25,  "w1": 2.0},
    "claude-opus-4-6":            {"in": 7.5,  "out": 37.5, "cr": 0.75, "w5": 9.375, "w1": 15.0}
  }
}
EOF
}

@test "cost-mirror: pricing snapshot — with no snapshot, rates_for returns today's baked figures unchanged and marks them 'baked'" {
    # The no-dollar-movement half of bd-cit's contract, on the path every
    # install starts on (nothing fetched yet). sonnet-5 is cross-called
    # against _sonnet5_rates() rather than hardcoded, so this stays valid on
    # either side of the 2026-09-01 intro-pricing cutoff.
    run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('cost_mirror_under_test', '$MIRROR')
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)

def five(model):
    r = cm.rates_for(model)
    return [r[k] for k in cm.COUNTER_KEYS]

def derived(rin, rout):
    return [rin, rout, rin * 0.1, rin * 1.25, rin * 2.0]

assert five('claude-opus-5') == derived(5.0, 25.0), 'opus-5 moved'
assert five('claude-fable-5') == derived(10.0, 50.0), 'fable-5 moved'
assert five('claude-haiku-4-5-20251001') == derived(1.0, 5.0), 'haiku moved'
assert five('claude-sonnet-5') == derived(*cm._sonnet5_rates()), 'sonnet-5 moved'

r = cm.rates_for('claude-opus-5')
assert r['source'] == 'baked', r['source']
assert r['fetched_at'] is None, r['fetched_at']
assert r['pricing_id'] == 'baked:claude-opus-', r['pricing_id']
assert cm.rates_for('claude-sonnet-5')['pricing_id'] == 'baked:claude-sonnet-5'
assert cm.rates_for('claude-totally-unknown-model-9') is None, 'unknown model must still be None, not a provenance stub'
print('BAKED FALLBACK OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BAKED FALLBACK OK"* ]]
}

@test "cost-mirror: pricing snapshot — a snapshot wins over the baked table, resolves by longest prefix, and carries litellm provenance" {
    mk_pricing_snapshot
    run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('cost_mirror_under_test', '$MIRROR')
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)

r = cm.rates_for('claude-opus-5')
assert [r[k] for k in cm.COUNTER_KEYS] == [5.0, 25.0, 0.5, 6.25, 10.0], r
assert r['source'] == 'litellm', r['source']
assert r['fetched_at'] == '2026-08-25T12:00:00+00:00', r['fetched_at']
assert r['pricing_id'] == 'litellm:claude-opus-5', r['pricing_id']

# dated real-world id -> longest snapshot key that prefixes it; the value is
# one the baked 'claude-opus-' entry (5/25) could never produce, so this
# proves the snapshot won rather than coinciding with the table
d = cm.rates_for('claude-opus-4-6-20260205')
assert [d[k] for k in cm.COUNTER_KEYS] == [7.5, 37.5, 0.75, 9.375, 15.0], d
assert d['pricing_id'] == 'litellm:claude-opus-4-6', d['pricing_id']

# a variant-annotated id still prefix-matches
assert cm.rates_for('claude-fable-5[1m]')['pricing_id'] == 'litellm:claude-fable-5'

# a model the snapshot does not carry falls through to the baked table IN THE
# SAME PROCESS -- resolution is per-model, not all-or-nothing
m = cm.rates_for('claude-mythos-5')
assert [m[k] for k in cm.COUNTER_KEYS] == [10.0, 50.0, 1.0, 12.5, 20.0], m
assert m['source'] == 'baked', m['source']
assert m['pricing_id'] == 'baked:claude-mythos-', m['pricing_id']

# unknown to both is still None
assert cm.rates_for('claude-totally-unknown-model-9') is None
print('SNAPSHOT RESOLUTION OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SNAPSHOT RESOLUTION OK"* ]]
}

@test "cost-mirror: pricing snapshot — real litellm figures move no dollars: snapshot and baked rates agree on the ladder" {
    # The citation-not-a-repricing claim, checked mechanically rather than by
    # eye: the same five values are read twice in one process, once with the
    # snapshot visible and once with it hidden, and compared.
    mk_pricing_snapshot
    run python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('cost_mirror_under_test', '$MIRROR')
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)

def five(model):
    r = cm.rates_for(model)
    return [r[k] for k in cm.COUNTER_KEYS]

snap = {m: five(m) for m in ('claude-opus-5', 'claude-sonnet-5', 'claude-fable-5', 'claude-haiku-4-5-20251001')}
assert cm.rates_for('claude-opus-5')['source'] == 'litellm'

os.environ['COST_MIRROR_PRICING_PATH'] = '$BATS_TEST_TMPDIR/no-such-snapshot.json'
baked = {m: five(m) for m in snap}
assert cm.rates_for('claude-opus-5')['source'] == 'baked'

for m in ('claude-opus-5', 'claude-fable-5', 'claude-haiku-4-5-20251001'):
    assert snap[m] == baked[m], (m, snap[m], baked[m])

# sonnet-5 is the one entry whose baked price is date-switched
# (SONNET5_INTRO_CUTOFF, 2026-09-01). While the intro price holds, litellm and
# the table agree exactly; from the cutoff the table reverts to 3/15 and a
# snapshot still quoting the intro 2/10 legitimately differs -- snapshot-first
# is the specified precedence, so assert the agreement only where it is real.
if cm._sonnet5_rates() == (2.00, 10.00):
    assert snap['claude-sonnet-5'] == baked['claude-sonnet-5'], (snap, baked)
else:
    assert snap['claude-sonnet-5'] == [2.0, 10.0, 0.2, 2.5, 4.0], snap
print('NO DOLLAR MOVEMENT OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO DOLLAR MOVEMENT OK"* ]]
}

@test "cost-mirror: pricing snapshot — --refresh-pricing writes a schema-tagged snapshot, converting per-token to USD/MTok and filtering to first-party Anthropic" {
    mk_litellm_payload
    run python3 "$MIRROR" --refresh-pricing
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    SNAP="$COST_MIRROR_STATE_DIR/pricing/snapshot.json"
    [ -f "$SNAP" ]
    jq -e '.schema == 1' "$SNAP"
    jq -e '.source == "litellm"' "$SNAP"
    jq -e --arg u "$COST_MIRROR_PRICING_URL" '.url == $u' "$SNAP"
    jq -e '.fetched_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$SNAP"
    # x1e6, and no float noise: 5e-07/token must land on exactly 0.5, not
    # 0.4999999999999999
    jq -e '.rates["claude-opus-5"] == {"in":5.0,"out":25.0,"cr":0.5,"w5":6.25,"w1":10.0}' "$SNAP"
    jq -e '.rates["claude-sonnet-5"] == {"in":2.0,"out":10.0,"cr":0.2,"w5":2.5,"w1":4.0}' "$SNAP"
    # exactly the two complete first-party entries: no bedrock variant, no
    # entry missing cache fields (cost() indexes all five), no other provider,
    # no schema-doc placeholder
    jq -e '(.rates | keys | sort) == ["claude-opus-5","claude-sonnet-5"]' "$SNAP"
    # and the freshly written snapshot is what rates_for now cites
    run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('cost_mirror_under_test', '$MIRROR')
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)
r = cm.rates_for('claude-opus-5')
assert r['source'] == 'litellm', r
assert [r[k] for k in cm.COUNTER_KEYS] == [5.0, 25.0, 0.5, 6.25, 10.0], r
print('REFRESH OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"REFRESH OK"* ]]
}

@test "cost-mirror: pricing snapshot — --refresh-pricing is TTL-gated: a fresh snapshot is left alone, an expired one is refetched" {
    mk_litellm_payload
    run python3 "$MIRROR" --refresh-pricing
    [ "$status" -eq 0 ]
    SNAP="$COST_MIRROR_STATE_DIR/pricing/snapshot.json"
    jq -e '.rates["claude-opus-5"]["in"] == 5.0' "$SNAP"
    # source now says something different; a within-TTL refresh must not notice
    mk_litellm_payload 8e-06
    run python3 "$MIRROR" --refresh-pricing
    [ "$status" -eq 0 ]
    jq -e '.rates["claude-opus-5"]["in"] == 5.0' "$SNAP"
    # TTL 0 means "always stale"
    COST_MIRROR_PRICING_TTL=0 run python3 "$MIRROR" --refresh-pricing
    [ "$status" -eq 0 ]
    jq -e '.rates["claude-opus-5"]["in"] == 8.0' "$SNAP"
}

@test "cost-mirror: pricing snapshot — an unreachable source exits 0 fast, leaves the previous snapshot intact, and never blocks rates_for" {
    # No snapshot yet + nowhere to fetch from: the refresh must fail open
    # (silent, exit 0, no half-written file) and rates_for must still answer
    # from the baked table, marked as such, without touching the network.
    export COST_MIRROR_PRICING_URL="http://127.0.0.1:1/nope.json"
    START=$SECONDS
    run python3 "$MIRROR" --refresh-pricing
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ $((SECONDS - START)) -lt 5 ]
    [ ! -f "$COST_MIRROR_STATE_DIR/pricing/snapshot.json" ]
    run python3 -c "
import importlib.util, time
spec = importlib.util.spec_from_file_location('cost_mirror_under_test', '$MIRROR')
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)
t0 = time.time()
r = cm.rates_for('claude-opus-5')
elapsed = time.time() - t0
assert elapsed < 2.0, elapsed
assert [r[k] for k in cm.COUNTER_KEYS] == [5.0, 25.0, 0.5, 6.25, 10.0], r
assert r['source'] == 'baked', r
print('OFFLINE OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OFFLINE OK"* ]]

    # now with a good snapshot already on disk: a failed refresh leaves it
    # byte-identical rather than clobbering it with nothing
    mk_pricing_snapshot
    BEFORE=$(md5sum "$SNAP" | awk '{print $1}')
    COST_MIRROR_PRICING_TTL=0 run python3 "$MIRROR" --refresh-pricing
    [ "$status" -eq 0 ]
    [ "$(md5sum "$SNAP" | awk '{print $1}')" = "$BEFORE" ]
}

@test "cost-mirror: pricing snapshot — a malformed, wrong-schema, or unreadable snapshot is ignored, never fatal" {
    SNAP="$COST_MIRROR_STATE_DIR/pricing/snapshot.json"
    mkdir -p "$(dirname "$SNAP")"
    printf 'THIS IS NOT JSON\n' > "$SNAP"
    run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('cost_mirror_under_test', '$MIRROR')
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)
r = cm.rates_for('claude-opus-5')
assert r['source'] == 'baked', r
assert [r[k] for k in cm.COUNTER_KEYS] == [5.0, 25.0, 0.5, 6.25, 10.0], r
print('MALFORMED OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MALFORMED OK"* ]]
    # a FUTURE schema is not readable either -- ignore it rather than guess at
    # a shape this version does not know
    printf '{"schema":99,"fetched_at":"2026-08-25T12:00:00+00:00","source":"litellm","url":"x","rates":{"claude-opus-5":{"in":99.0,"out":99.0,"cr":99.0,"w5":99.0,"w1":99.0}}}\n' > "$SNAP"
    run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('cost_mirror_under_test', '$MIRROR')
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)
r = cm.rates_for('claude-opus-5')
assert r['source'] == 'baked', r
assert r['in'] == 5.0, r
print('SCHEMA GUARD OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SCHEMA GUARD OK"* ]]
}

@test "cost-mirror: SessionStart hook refresh — hook exits 0 with network up and advances fetched_at" {
    mk_litellm_payload
    SNAP="$COST_MIRROR_STATE_DIR/pricing/snapshot.json"
    # First refresh: creates snapshot
    run python3 "$MIRROR" --refresh-pricing
    [ "$status" -eq 0 ]
    [ -f "$SNAP" ]
    FIRST_FETCHED=$(jq -r '.fetched_at' "$SNAP")
    # wait a moment to ensure timestamps differ
    sleep 1
    # Second refresh with TTL=0 to force a new fetch
    COST_MIRROR_PRICING_TTL=0 run python3 "$MIRROR" --refresh-pricing
    [ "$status" -eq 0 ]
    SECOND_FETCHED=$(jq -r '.fetched_at' "$SNAP")
    [ "$FIRST_FETCHED" != "$SECOND_FETCHED" ]
}

@test "cost-mirror: SessionStart hook refresh — hook exits 0 with egress blocked, snapshot untouched, no traceback" {
    mk_litellm_payload
    mk_pricing_snapshot
    SNAP="$COST_MIRROR_STATE_DIR/pricing/snapshot.json"
    BEFORE=$(md5sum "$SNAP" | awk '{print $1}')
    # Block network traffic by pointing URL to unreachable address
    export COST_MIRROR_PRICING_URL="http://127.0.0.1:1/nope.json"
    # Force a refresh attempt by disabling TTL
    export COST_MIRROR_PRICING_TTL=0
    START=$SECONDS
    run python3 "$MIRROR" --refresh-pricing
    ELAPSED=$((SECONDS - START))
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ $ELAPSED -lt 5 ]
    AFTER=$(md5sum "$SNAP" | awk '{print $1}')
    [ "$BEFORE" = "$AFTER" ]
}

@test "cost-mirror: SessionStart hook refresh — COST_MIRROR_DISABLE=1 exits 0 without fetching" {
    mk_litellm_payload
    SNAP="$COST_MIRROR_STATE_DIR/pricing/snapshot.json"
    mkdir -p "$(dirname "$SNAP")"
    export COST_MIRROR_DISABLE=1
    run python3 "$MIRROR" --refresh-pricing
    [ "$status" -eq 0 ]
    [ ! -f "$SNAP" ]
}

@test "cost-mirror: SessionStart hook is defined in config/claude-settings.json, invokes --refresh-pricing, is backgrounded and timeout-capped" {
    # This test READS the hook command from config/claude-settings.json to verify
    # the SessionStart entry itself, not just that --refresh-pricing works.
    # It discriminates between: (1) a bare --refresh-pricing flag existing, and
    # (2) the new SessionStart hook entry that INVOKES it.

    # Extract the SessionStart refresh-pricing hook command from the settings
    hook_cmd=$(jq -r '[.hooks.SessionStart[].hooks[] | select(.command | contains("cost-mirror") and contains("refresh-pricing"))] | .[0].command' "$SETTINGS_JSON")
    # Must find the hook in the JSON, not just have --refresh-pricing flag somewhere
    [ "$hook_cmd" != "null" ]

    # Verify the hook contains the three key properties: timeout cap, flag, and backgrounded
    [[ "$hook_cmd" =~ "timeout 3" ]]
    [[ "$hook_cmd" =~ "refresh-pricing" ]]
    # Must match the trailing backgrounding ampersand, not just any & (e.g. 2>&1)
    [[ "$hook_cmd" =~ "& exit 0; }; exit 0" ]]

    mk_litellm_payload
    SNAP="$COST_MIRROR_STATE_DIR/pricing/snapshot.json"

    # Run the hook command extracted from the settings file.
    # The hook does two things: runs in background (the & at the end) and exits 0 immediately.
    # We need to run it and wait for the background job to complete.
    run bash -c "cd '$REPO_ROOT' && $hook_cmd"
    [ "$status" -eq 0 ]

    # Bounded polling: wait up to 8s for snapshot to appear (timeout 3 + network/fs latency)
    timeout 8 bash -c "until [ -f '$SNAP' ]; do sleep 0.1; done"
    [ "$?" -eq 0 ] || {
      echo "Snapshot not created within 8 seconds"
      exit 1
    }
    [ -f "$SNAP" ]
    FIRST_FETCHED=$(jq -r '.fetched_at' "$SNAP")
    [ "$FIRST_FETCHED" != "null" ]
}

@test "cost-mirror: SessionStart hook backgrounding assertion is not vacuous — fails when trailing & is stripped" {
    # Verify the fixed assertion [[ "$hook_cmd" =~ "& exit 0; }; exit 0" ]] actually tests backgrounding,
    # not just matching "&" (which would pass even with 2>&1 redirections and no trailing &).

    # Extract the real hook command
    hook_cmd=$(jq -r '[.hooks.SessionStart[].hooks[] | select(.command | contains("cost-mirror") and contains("refresh-pricing"))] | .[0].command' "$SETTINGS_JSON")
    [ "$hook_cmd" != "null" ]

    # The real hook should pass the fixed assertion (includes backgrounding)
    [[ "$hook_cmd" =~ "& exit 0; }; exit 0" ]]

    # Now test with a deliberately broken version: remove the trailing & from the refresh-pricing branch
    # The assertion should fail because the backgrounding is gone
    broken_hook="${hook_cmd//' & exit 0; }; exit 0'/' exit 0; }; exit 0'}"

    # The fixed (end-anchored) assertion should NOT match the broken version
    if [[ "$broken_hook" =~ "& exit 0; }; exit 0" ]]; then
      # This is what we want to avoid — the old vacuous assertion would pass even here
      echo "ERROR: Assertion matched despite stripped &"
      exit 1
    fi
    # If we get here, the assertion correctly fails on the broken version ✓
}

@test "cost-mirror: SessionStart hook PATH fallback is gated on --refresh-pricing flag support" {
    # Gap 1: verify that a cost-mirror on PATH without --refresh-pricing support is NOT invoked.
    # The gating mechanism: c=$(command -v cost-mirror 2>/dev/null) && "$c" --help 2>/dev/null | grep -q refresh-pricing
    # This test creates a scenario where the git repo path is not available, so the hook falls back to PATH.
    # Then it verifies that a stub without the flag is skipped, and a stub with the flag is invoked.

    # Setup: create a fake PATH with cost-mirror stubs
    FAKE_BIN="$BATS_TEST_TMPDIR/fake-bin"
    mkdir -p "$FAKE_BIN"
    SENTINEL_NO_FLAG="$BATS_TEST_TMPDIR/sentinel-no-flag"
    SENTINEL_WITH_FLAG="$BATS_TEST_TMPDIR/sentinel-with-flag"

    # Stub 1: cost-mirror that lacks --refresh-pricing in its help output
    cat > "$FAKE_BIN/cost-mirror" <<EOF
#!/bin/sh
# This stub does NOT advertise --refresh-pricing
case "\$1" in
  --help)
    echo "Usage: cost-mirror [--report] [--other-flag]"
    echo "A mock cost-mirror without --refresh-pricing support"
    exit 0
    ;;
  --refresh-pricing)
    # If invoked, write a sentinel so the test can detect it
    touch "$SENTINEL_NO_FLAG"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
    chmod +x "$FAKE_BIN/cost-mirror"

    mk_litellm_payload
    SNAP="$COST_MIRROR_STATE_DIR/pricing/snapshot.json"

    # Extract the hook command from settings
    hook_cmd=$(jq -r '[.hooks.SessionStart[].hooks[] | select(.command | contains("cost-mirror") and contains("refresh-pricing"))] | .[0].command' "$SETTINGS_JSON")
    [ "$hook_cmd" != "null" ]

    # Test 1: Run the hook in a non-git directory (so git rev-parse fails)
    # so the first branch fails and it falls back to PATH.
    # The stub lacks the flag, so the gated branch should be skipped.
    NO_GIT_DIR="$BATS_TEST_TMPDIR/no-git"
    mkdir -p "$NO_GIT_DIR"
    # Put fake-bin first in PATH so our stub cost-mirror is found, but keep rest of PATH for grep/etc
    bash -c "export PATH='$FAKE_BIN':\$PATH; cd '$NO_GIT_DIR' && $hook_cmd"
    [ "$?" -eq 0 ]
    [ ! -f "$SENTINEL_NO_FLAG" ]

    # Test 2: Create a stub that DOES advertise --refresh-pricing and verify it IS invoked
    cat > "$FAKE_BIN/cost-mirror" <<EOF
#!/bin/sh
# This stub DOES advertise --refresh-pricing
case "\$1" in
  --help)
    echo "Usage: cost-mirror [--report] [--refresh-pricing] [--other-flag]"
    echo "A mock cost-mirror WITH --refresh-pricing support"
    exit 0
    ;;
  --refresh-pricing)
    # If invoked, write a sentinel so the test can detect it
    touch "$SENTINEL_WITH_FLAG"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
    chmod +x "$FAKE_BIN/cost-mirror"

    # Run the hook from the non-git directory again, so it falls back to PATH.
    # The stub DOES support --refresh-pricing, so the gated branch should be taken.
    bash -c "export PATH='$FAKE_BIN':\$PATH; cd '$NO_GIT_DIR' && $hook_cmd"
    [ "$?" -eq 0 ]
    # Wait for background job (timeout 3 + execution time) to write sentinel
    sleep 2
    [ -f "$SENTINEL_WITH_FLAG" ]
}

@test "cost-mirror: SessionStart hook PATH fallback --help probe is timeout-gated to prevent stdin-block hang" {
    # Critical: the --help probe must not stall the hook if the stub blocks on stdin.
    # The gate: timeout 1 "$c" --help </dev/null 2>/dev/null | grep -q refresh-pricing
    # This test verifies: timeout 1 (caps hang at 1s) + </dev/null (prevents stdin block).

    # Setup: create a fake PATH with a cost-mirror stub that blocks on stdin
    FAKE_BIN="$BATS_TEST_TMPDIR/fake-bin-hang"
    mkdir -p "$FAKE_BIN"
    NO_GIT_DIR="$BATS_TEST_TMPDIR/no-git-hang"
    mkdir -p "$NO_GIT_DIR"

    # Stub that blocks on stdin when --help is called (waits for input on EOF)
    # Without timeout 1, this would hang for 60s+ (bash default read timeout).
    # Without </dev/null, stdin left open allows the stub to block.
    cat > "$FAKE_BIN/cost-mirror" <<'EOF'
#!/bin/sh
case "$1" in
  --help)
    # Attempt to read from stdin: blocks until EOF or timeout
    # With </dev/null this is EOF immediately; without it, blocks indefinitely
    read -t 30 line || true
    # If we get here, we weren't blocked (timeout or EOF reached)
    echo "Usage: cost-mirror [--report] [--refresh-pricing]"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
    chmod +x "$FAKE_BIN/cost-mirror"

    mk_litellm_payload

    # Extract the hook command from settings (now with timeout 1 and </dev/null)
    hook_cmd=$(jq -r '[.hooks.SessionStart[].hooks[] | select(.command | contains("cost-mirror") and contains("refresh-pricing"))] | .[0].command' "$SETTINGS_JSON")
    [ "$hook_cmd" != "null" ]
    # Verify the fix is in place: grep for timeout 1 and </dev/null
    [[ "$hook_cmd" =~ "timeout 1" ]]
    [[ "$hook_cmd" =~ "</dev/null" ]]

    # Run the hook with the blocking stub on PATH
    # With timeout 1 + </dev/null, should exit quickly (within 2s)
    # Without it, would hang for ~30s (the read timeout in the stub)
    START=$SECONDS
    bash -c "export PATH='$FAKE_BIN':\$PATH; cd '$NO_GIT_DIR' && $hook_cmd"
    EXIT_CODE=$?
    ELAPSED=$((SECONDS - START))

    # Verify: hook exited quickly (well under the stub's 30s read timeout)
    [ "$EXIT_CODE" -eq 0 ]
    [ $ELAPSED -lt 5 ]
}

# ── cost-mirror --report --csv ───────────────────────────────────────────────

mk_csv_corpus() {
    # The mid-session /tier-change fixture (mk_epoch_transcript), re-homed
    # under its own projects dir so the AGGREGATE report — the path --csv has
    # to work in — picks it up. Its dollars are hand-computed and asserted
    # above: actual $50, at-top $90, saved $40, spread over main and worker
    # rows in two different tier epochs. That is what makes the reconciliation
    # below a check against KNOWN figures rather than against the code's own
    # output agreeing with itself.
    mk_epoch_transcript
    CSVDIR="$BATS_TEST_TMPDIR/csv-projects"
    mkdir -p "$CSVDIR"
    mv "$BATS_TEST_TMPDIR/proj-epoch" "$CSVDIR/proj-epoch"
    TP="$CSVDIR/proj-epoch/sess.jsonl"
    export COST_MIRROR_PROJECTS_DIR="$CSVDIR"
}

reconcile_csv() {  # $1 = CSV, $2 = the rendered report from the SAME run
    # Sums the CSV's own numbers per (side, model) and checks each against the
    # cell the table printed for that pair — which is the entire point of the
    # export. The sum is formatted with the renderer's own fmt_usd rule (whole
    # dollars at >= $10, cents below), so "equal to the cent" is checked at
    # the precision the table actually prints. Also compares the two KEY SETS:
    # equal grand totals with unequal key sets is two errors cancelling.
    python3 - "$1" "$2" <<'PY'
import collections
import csv
import sys

def fmt_usd(x):
    sign = "-" if x < 0 else ""
    x = abs(x)
    return f"{sign}${x:.0f}" if x >= 10 else f"{sign}${x:.2f}"

rows = list(csv.DictReader(open(sys.argv[1])))
assert rows, "CSV holds no rows at all"

act = collections.defaultdict(float)
epo = collections.defaultdict(float)
for r in rows:
    key = (r["side"], r["model"].replace("claude-", ""))
    act[key] += float(r["cost_total"])
    epo[key] += float(r["cost_at_epoch"])
    five = 0.0
    for c in ("in", "out", "cr", "w5", "w1"):
        want = float(r["tokens_" + c]) * float(r["rate_" + c]) / 1e6
        got = float(r["cost_" + c])
        assert abs(got - want) < 1e-9, ("cost_" + c, key, got, want)
        five += got
    assert abs(float(r["cost_total"]) - five) < 1e-9, ("cost_total", key, r["cost_total"], five)

table = {}
total = None
for line in open(sys.argv[2]):
    parts = line.split()
    if line.startswith("TOTAL"):
        total = parts
    elif len(parts) == 9 and parts[6].lstrip("-").startswith("$"):
        table[(parts[0], parts[1].rstrip("?"))] = (parts[6], parts[7])

assert table, "no data rows parsed out of the rendered report"
assert set(table) == set(act), ("key sets differ", sorted(set(table) ^ set(act)))
for key, (cell_actual, cell_at_top) in table.items():
    assert fmt_usd(act[key]) == cell_actual, ("actual $", key, fmt_usd(act[key]), cell_actual)
    assert fmt_usd(epo[key]) == cell_at_top, ("at-top $", key, fmt_usd(epo[key]), cell_at_top)

assert total is not None, "no TOTAL row in the rendered report"
assert fmt_usd(sum(act.values())) == total[5], ("grand actual", fmt_usd(sum(act.values())), total[5])
assert fmt_usd(sum(epo.values())) == total[6], ("grand at-top", fmt_usd(sum(epo.values())), total[6])
print(f"RECONCILED {len(rows)} rows in {len(act)} groups")
PY
}

@test "cost-mirror --report --csv: one row per ledger row, header first, w5 and w1 never collapsed" {
    mk_csv_corpus
    OUT="$BATS_TEST_TMPDIR/rows.csv"
    run python3 "$MIRROR" --report --csv "$OUT"
    [ "$status" -eq 0 ]
    # --csv is an EXTRA surface, never a replacement: the table still prints
    [[ "$output" == *"TOTAL"* ]]
    [ -f "$OUT" ]
    # the ledger's columns verbatim, in a stable order. cache-write stays TWO
    # columns here; the rendered table collapses w5 + w1 into one (:2390).
    HEADER=$(head -1 "$OUT")
    [ "$HEADER" = "session_id,side,model,bucket,epoch_model,project,mtime,tp,tokens_in,tokens_out,tokens_cr,tokens_w5,tokens_w1,rate_in,rate_out,rate_cr,rate_w5,rate_w1,rate_epoch_in,rate_epoch_out,rate_epoch_cr,rate_epoch_w5,rate_epoch_w1,cost_in,cost_out,cost_cr,cost_w5,cost_w1,cost_total,cost_at_epoch,pricing_source,pricing_fetched_at,pricing_id" ]
    LEDGER=$(jq '.sessions | length' "$COST_MIRROR_STATE_DIR/lifetime.json")
    [ "$LEDGER" -gt 1 ]
    ROWS=$(( $(wc -l < "$OUT") - 1 ))
    [ "$ROWS" -eq "$LEDGER" ]
    # provenance travels with every row: a reader can see whether it was
    # priced from the fetched snapshot or the baked fallback
    [[ "$(tail -1 "$OUT")" == *",baked,"* ]]
    # --csv=<path> is the same flag, same output, exactly as --since=/--session=
    EQ="$BATS_TEST_TMPDIR/rows-eq.csv"
    run python3 "$MIRROR" --report "--csv=$EQ"
    [ "$status" -eq 0 ]
    run diff "$OUT" "$EQ"
    [ "$status" -eq 0 ]
}

@test "cost-mirror --report --csv: every rendered dollar reconciles to the CSV rows behind it" {
    mk_csv_corpus
    OUT="$BATS_TEST_TMPDIR/rows.csv"
    REP="$BATS_TEST_TMPDIR/report.txt"
    # ONE invocation for both artifacts: the aggregate path rescans and
    # re-persists as it runs, so a report and a CSV from two separate runs are
    # two snapshots of a moving corpus, not one snapshot seen twice
    run sh -c "python3 '$MIRROR' --report --csv '$OUT' > '$REP'"
    [ "$status" -eq 0 ]
    # the hand-computed epoch figures from the test above, still true here
    TOTAL_LINE=$(grep '^TOTAL' "$REP")
    [[ "$TOTAL_LINE" == *'$50'* ]]
    [[ "$TOTAL_LINE" == *'$90'* ]]
    run reconcile_csv "$OUT" "$REP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RECONCILED"* ]]
}

@test "cost-mirror --report --csv: composes with --since and with --session" {
    mk_csv_corpus
    mkdir -p "$CSVDIR/proj-old"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":10}}}\n' \
        > "$CSVDIR/proj-old/sess-old.jsonl"
    touch -d "3 days ago" "$CSVDIR/proj-old/sess-old.jsonl"

    OUT="$BATS_TEST_TMPDIR/since.csv"
    run python3 "$MIRROR" --report --since 1d --csv "$OUT"
    [ "$status" -eq 0 ]
    # the CSV's scope is the REPORT's scope: --since narrowed both
    SINCE_CSV=$(cat "$OUT")
    [[ "$SINCE_CSV" == *"proj-epoch"* ]]
    [[ "$SINCE_CSV" != *"sess-old"* ]]

    OUT2="$BATS_TEST_TMPDIR/session.csv"
    run python3 "$MIRROR" --report --session sess-old --csv "$OUT2"
    [ "$status" -eq 0 ]
    SESS_CSV=$(cat "$OUT2")
    [[ "$SESS_CSV" == *"sess-old"* ]]
    [[ "$SESS_CSV" != *"proj-epoch"* ]]
}

@test "cost-mirror --report: an unrecognised flag is a clear error, not a bogus transcript lookup" {
    mk_csv_corpus
    run python3 "$MIRROR" --report --nonsense
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option"* ]]
    [[ "$output" == *"--nonsense"* ]]
    # the old failure mode: an unknown flag fell through to positional[] and
    # was then looked up as a transcript path
    [[ "$output" != *"transcript not found"* ]]
    # the error names what IS valid — the whole reason --report --help was
    # unreadable rather than merely unsupported
    [[ "$output" == *"--csv"* ]]
    [[ "$output" == *"--since"* ]]
    run python3 "$MIRROR" --report --help
    [ "$status" -eq 1 ]
    [[ "$output" != *"transcript not found"* ]]
    [[ "$output" == *"--session"* ]]
    # a valueless --csv says so, exactly as --since/--session do
    run python3 "$MIRROR" --report --csv
    [ "$status" -eq 1 ]
    [[ "$output" == *"--csv requires a path"* ]]
    # ...including when the next token is the NEXT flag, which would
    # otherwise be silently swallowed as a filename
    run python3 "$MIRROR" --report --csv --since 7d
    [ "$status" -eq 1 ]
    [[ "$output" == *"--csv requires a path"* ]]
    # a transcript path still works, and is still the only positional
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
}

@test "cost-mirror --report --csv: nothing is rounded or truncated relative to the ledger" {
    LONGDIR="$BATS_TEST_TMPDIR/long-projects"
    PROJ="-Users-someone-code-a-very-deeply-nested-project-directory-name"
    SESSID="0f7c9a12-3b4d-4e5f-8a9b-0c1d2e3f4a5b"
    mkdir -p "$LONGDIR/$PROJ"
    printf '{"message":{"model":"claude-opus-5","usage":{"output_tokens":3}}}\n' \
        > "$LONGDIR/$PROJ/$SESSID.jsonl"
    export COST_MIRROR_PROJECTS_DIR="$LONGDIR"
    OUT="$BATS_TEST_TMPDIR/long.csv"
    REP="$BATS_TEST_TMPDIR/long.txt"
    run sh -c "python3 '$MIRROR' --report --csv '$OUT' > '$REP'"
    [ "$status" -eq 0 ]
    RENDERED=$(cat "$REP")
    ROW=$(tail -1 "$OUT")
    # the table ellipsises the project name (:2136) and prints 8 id chars
    # (:2196); the CSV is the audit surface and does neither
    [[ "$RENDERED" == *"…"* ]]
    [[ "$RENDERED" != *"$PROJ"* ]]
    [[ "$ROW" == *"$PROJ"* ]]
    [[ "$ROW" == "$SESSID,"* ]]
    # 3 out at opus-5's $25/MTok is $0.000075 — the table rounds it to $0.00,
    # the CSV carries the figure the ledger actually holds
    [[ "$RENDERED" == *'$0.00'* ]]
    [[ "$ROW" == *",7.5e-05,"* ]]
}

@test "cost-mirror --report --csv: a migrated legacy row exports as-is — unknown, never back-filled" {
    mk_csv_corpus
    mkdir -p "$COST_MIRROR_STATE_DIR"
    printf '{"v":3,"sessions":{"deadsess|main|claude-sonnet-5":{"in":10,"out":20,"cr":30,"w5":40,"w1":50,"project":"ghost","mtime":1,"tp":"/nope.jsonl","sessionId":"deadsess"}}}' \
        > "$COST_MIRROR_STATE_DIR/lifetime.json"
    OUT="$BATS_TEST_TMPDIR/legacy.csv"
    run python3 "$MIRROR" --report --csv "$OUT"
    [ "$status" -eq 0 ]
    ROW=$(grep '^deadsess,' "$OUT")
    [ -n "$ROW" ]
    # tokens survive; bucket, every rate and every cost stay EMPTY. "This
    # row's price is unknown" is itself audit output, and a back-filled rate
    # would fabricate exactly the provenance the ledger exists to keep honest.
    [ "$(echo "$ROW" | cut -d, -f9)" = "10" ]
    [ "$(echo "$ROW" | cut -d, -f13)" = "50" ]
    [ "$(echo "$ROW" | cut -d, -f4)" = "" ]
    [ "$(echo "$ROW" | cut -d, -f14)" = "" ]
    [ "$(echo "$ROW" | cut -d, -f19)" = "" ]
    [ "$(echo "$ROW" | cut -d, -f24)" = "" ]
    [ "$(echo "$ROW" | cut -d, -f29)" = "" ]
    [ "$(echo "$ROW" | cut -d, -f30)" = "" ]
    [ "$(echo "$ROW" | cut -d, -f31)" = "unknown" ]
}

# ── tier-set defect fixes ────────────────────────────────────────────────────

@test "tier-set: unknown single argument exits non-zero and leaves settings/executor/scout byte-unchanged" {
    tier_set_fixture claude-fable-5
    # Hash the three files before
    before_s=$(sha256sum "$TS" | awk '{print $1}')
    before_e=$(sha256sum "$TS_AGENTS/executor.md" | awk '{print $1}')
    before_c=$(sha256sum "$TS_AGENTS/scout.md" | awk '{print $1}')

    # Try to bind an unknown single argument (not a model id, not a subcommand)
    tier_set notamodel
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown"* ]]

    # Verify the three files are byte-unchanged
    after_s=$(sha256sum "$TS" | awk '{print $1}')
    after_e=$(sha256sum "$TS_AGENTS/executor.md" | awk '{print $1}')
    after_c=$(sha256sum "$TS_AGENTS/scout.md" | awk '{print $1}')

    [ "$before_s" = "$after_s" ]
    [ "$before_e" = "$after_e" ]
    [ "$before_c" = "$after_c" ]
}

@test "tier-set cost: prefers repo copy over stale PATH copy when available" {
    tier_set_fixture claude-fable-5
    cost_projects

    # Create a stale cost-mirror stub on PATH (older than repo copy). It
    # emits a SENTINEL that cannot appear in any legitimate cost-mirror
    # output, so the sentinel's PRESENCE in $output is the only reliable
    # proof the stale copy actually ran. (A prior version of this test
    # branched on exit status and asserted the stub's own stderr contained
    # the substring "cost-mirror" in the failure branch — but the stub's
    # error message "ERROR: stale cost-mirror was invoked" itself contains
    # that substring, so "refused the stale copy" and "silently ran the
    # stale copy" were indistinguishable and the case passed either way.)
    STALE_DIR="$BATS_TEST_TMPDIR/stale-bin"
    mkdir -p "$STALE_DIR"
    SENTINEL="STALE_MIRROR_WAS_INVOKED_7f3ac2e9b1"
    cat > "$STALE_DIR/cost-mirror" <<PY
#!/usr/bin/env python3
import sys
print("$SENTINEL", file=sys.stderr)
sys.exit(1)
PY
    chmod +x "$STALE_DIR/cost-mirror"

    # Run tier-set cost with the stale copy on PATH but repo copy available
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-stale-test"
    run env TIER_SETTINGS="$TS" TIER_AGENTS_DIR="$TS_AGENTS" TIER_DERIVE="$DERIVE" \
        TIER_COST_MIRROR="" TIER_NO_PROBE=1 PATH="$STALE_DIR:$PATH" sh "$TSET" cost

    # The only assertion that proves non-silence: the sentinel must be
    # absent from $output, unconditionally — not gated behind a branch on
    # $status, which is how the previous version let both outcomes through.
    [[ "$output" != *"$SENTINEL"* ]]
}

@test "cost-mirror: pricing snapshot — stale snapshot (older than read-side max-age) loses to baked table (bead beads_claude_docker-zrx exposure a)" {
    # Exposure (a): a snapshot older than the read-side max-age should be ignored
    # in favour of the baked table, independent of the fetch TTL.
    mk_pricing_snapshot
    SNAP="$COST_MIRROR_STATE_DIR/pricing/snapshot.json"

    # Modify the snapshot to be old (past max-age)
    # The snapshot will have fetched_at = 2026-08-25T12:00:00+00:00
    # We'll test with a snapshot that is much older than the max-age
    jq '.fetched_at = "2020-01-01T00:00:00+00:00"' "$SNAP" > "$SNAP.new" && mv "$SNAP.new" "$SNAP"

    run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('cost_mirror_under_test', '$MIRROR')
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)

# With a stale snapshot (over max-age), baked table should win
r = cm.rates_for('claude-opus-5')
assert r['source'] == 'baked', f'Expected source=baked for stale snapshot, got {r[\"source\"]}'
assert r['pricing_id'] == 'baked:claude-opus-', f'Expected pricing_id=baked:claude-opus-, got {r[\"pricing_id\"]}'

# Fresh snapshot should still win (created just now)
# Reset the snapshot to fresh
snap2 = cm._load_pricing_snapshot()
# Clear the cache to force reload
cm._PRICING_CACHE = (None, None)

# Now create a fresh snapshot - should win over baked
import os, json
os.makedirs(os.path.dirname('$SNAP'), exist_ok=True)
snap_fresh = {
    'schema': 1,
    'fetched_at': '2026-08-26T12:00:00+00:00',
    'source': 'litellm',
    'url': 'https://example.com/prices.json',
    'rates': {
        'claude-opus-5': {'in': 5.0, 'out': 25.0, 'cr': 0.5, 'w5': 6.25, 'w1': 10.0}
    }
}
with open('$SNAP', 'w') as f:
    json.dump(snap_fresh, f)

# Clear cache and reload
cm._PRICING_CACHE = (None, None)
r2 = cm.rates_for('claude-opus-5')
assert r2['source'] == 'litellm', f'Expected source=litellm for fresh snapshot, got {r2[\"source\"]}'
assert [r2[k] for k in cm.COUNTER_KEYS] == [5.0, 25.0, 0.5, 6.25, 10.0]

print('STALE MAX-AGE OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE MAX-AGE OK"* ]]
}

@test "cost-mirror: pricing snapshot — date-aware callable pricing table wins over snapshot disagreement (bead beads_claude_docker-zrx exposure b)" {
    # Exposure (b): when a callable PRICING_TABLE entry (like _sonnet5_rates)
    # disagrees with the snapshot, the date-aware local value should win.
    # Test case: past SONNET5_INTRO_CUTOFF (2026-09-01), snapshot should NOT
    # win if it still quotes the intro price.

    mk_pricing_snapshot
    SNAP="$COST_MIRROR_STATE_DIR/pricing/snapshot.json"

    # Modify snapshot to have intro pricing but current date is past cutoff
    jq '.rates["claude-sonnet-5"] = {"in": 2.0, "out": 10.0, "cr": 0.2, "w5": 2.5, "w1": 4.0} | .fetched_at = "2026-09-02T11:00:00+00:00"' "$SNAP" > "$SNAP.new" && mv "$SNAP.new" "$SNAP"

    # Use faketime to set the clock to 2026-09-02 (past the cutoff)
    # The disagreement rule should detect that:
    # - snapshot says 2/10 (intro price)
    # - _sonnet5_rates() returns 3/15 (post-cutoff price)
    # - They disagree, so baked (3/15) wins
    cat > "$BATS_TEST_TMPDIR/test_exposure_b.py" << 'PYEOF'
import importlib.util, os
spec = importlib.util.spec_from_file_location('cost_mirror_under_test', os.environ.get('MIRROR'))
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)

# Clear cache to force reload
cm._PRICING_CACHE = (None, None)

# At this point, the snapshot has the intro 2/10 but local date-aware logic
# should return 3/15 (the post-cutoff rate)
# This test will FAIL if only a max-age is implemented, because:
# - The snapshot is fresh (fetched 1 hour ago)
# - Max-age won't help here
# - Only the disagreement rule will catch this

# faketime must have moved the clock past SONNET5_INTRO_CUTOFF for this test
# to exercise the disagreement rule at all. If the LD_PRELOAD no-ops (observed
# under suite load, bead beads_claude_docker-zrx), date.today() falls back to
# the real pre-cutoff date, _sonnet5_rates() returns the intro 2/10, that
# AGREES with the snapshot, the disagreement rule never fires, and the
# assertions below would fail with a confusing pricing mismatch instead of
# this clear cause.
assert cm.date.today() >= cm.SONNET5_INTRO_CUTOFF, (
    f'faketime did not apply: today={cm.date.today()}, expected on/after {cm.SONNET5_INTRO_CUTOFF}'
)

r = cm.rates_for('claude-sonnet-5')

# The snapshot has 2/10, but we should get 3/15 from the date-aware rule
assert r['source'] == 'baked', f'Expected source=baked (date-aware override), got {r["source"]}'
assert r['in'] == 3.0, f'Expected in=3.0 (post-cutoff), got {r["in"]}'
assert r['out'] == 15.0, f'Expected out=15.0 (post-cutoff), got {r["out"]}'
# Pin all five COUNTER_KEYS, not just in/out: cr/w5/w1 are derived from the
# baked in-rate (x0.1 / x1.25 / x2.0) and were dropped here at 52bd3e4 despite
# being asserted at RED-AT (bead beads_claude_docker-zrx). isclose (not ==) is
# required, not cosmetic: 3.0 * 0.1 == 0.30000000000000004 in IEEE 754, so an
# exact-equality restore of the original RED-AT list would itself fail.
import math
expected = {'in': 3.0, 'out': 15.0, 'cr': 0.3, 'w5': 3.75, 'w1': 6.0}
for k in cm.COUNTER_KEYS:
    assert math.isclose(r[k], expected[k]), f'Expected {k}={expected[k]}, got {r[k]}'

print('DISAGREEMENT RULE OK')
PYEOF
    run env COST_MIRROR_PRICING_PATH="$SNAP" MIRROR="$MIRROR" faketime '2026-09-02 12:00:00' python3 "$BATS_TEST_TMPDIR/test_exposure_b.py"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DISAGREEMENT RULE OK"* ]]
}

@test "cost-mirror: pricing snapshot — case (b) non-vacuity: disagreement rule is not redundant with max-age (bead beads_claude_docker-zrx)" {
    # Prove that case (b) - the disagreement rule - is NOT satisfied by max-age alone.
    # We do this by temporarily removing the disagreement rule, keeping only max-age,
    # and showing case (b) goes RED.

    mk_pricing_snapshot
    SNAP="$COST_MIRROR_STATE_DIR/pricing/snapshot.json"

    # Modify snapshot to have intro pricing and FRESH timestamp past cutoff
    jq '.rates["claude-sonnet-5"] = {"in": 2.0, "out": 10.0, "cr": 0.2, "w5": 2.5, "w1": 4.0} | .fetched_at = "2026-09-02T11:00:00+00:00"' "$SNAP" > "$SNAP.new" && mv "$SNAP.new" "$SNAP"

    # First, run with the disagreement rule in place (should pass)
    cat > "$BATS_TEST_TMPDIR/test_with_disagree.py" << 'PYEOF'
import importlib.util, os
spec = importlib.util.spec_from_file_location('cost_mirror_under_test', os.environ.get('MIRROR'))
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)
cm._PRICING_CACHE = (None, None)
# See exposure-b test above: faketime must actually move the clock past
# cutoff or this degrades to a confusing pricing mismatch instead of a clear
# cause (bead beads_claude_docker-zrx).
assert cm.date.today() >= cm.SONNET5_INTRO_CUTOFF, (
    f'faketime did not apply: today={cm.date.today()}, expected on/after {cm.SONNET5_INTRO_CUTOFF}'
)
r = cm.rates_for('claude-sonnet-5')
assert r['source'] == 'baked' and r['in'] == 3.0, f'WITH disagreement rule: {r}'
print('WITH DISAGREEMENT RULE: PASS')
PYEOF
    run env COST_MIRROR_PRICING_PATH="$SNAP" MIRROR="$MIRROR" faketime '2026-09-02 12:00:00' python3 "$BATS_TEST_TMPDIR/test_with_disagree.py"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WITH DISAGREEMENT RULE: PASS"* ]]

    # Now test WITHOUT disagreement rule (stub it out) - should fail
    # We'll modify the module to skip the disagreement check
    cat > "$BATS_TEST_TMPDIR/test_without_disagree.py" << 'PYEOF'
import importlib.util, os
spec = importlib.util.spec_from_file_location('cost_mirror_under_test', os.environ.get('MIRROR'))
cm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cm)

# Stub out the disagreement rule by replacing rates_for to NOT check disagreement
def rates_for_no_disagreement(model):
    '''rates_for without the disagreement rule check'''
    if not model:
        return None
    snap = cm._load_pricing_snapshot()
    if snap:
        # Check max-age (exposure a) but NOT disagreement rule (exposure b)
        snap_ts = cm._parse_ts(snap.get('fetched_at'))
        if snap_ts is not None:
            import time
            snap_age_seconds = time.time() - snap_ts
            if snap_age_seconds > cm.PRICING_MAX_AGE_SECONDS:
                snap = None

    if snap:
        hit = cm._snapshot_rates(model, snap)
        if hit:
            key, vals = hit
            # NO disagreement check here - snapshot wins if fresh
            source = snap['source']
            vals['source'] = source
            vals['fetched_at'] = snap['fetched_at']
            vals['pricing_id'] = f'{source}:{key}'
            return vals

    for prefix, spec in cm.PRICING_TABLE:
        if model.startswith(prefix):
            rin, rout = spec() if callable(spec) else spec
            return {
                'in': rin, 'out': rout, 'cr': rin * 0.1, 'w5': rin * 1.25, 'w1': rin * 2.0,
                'source': 'baked', 'fetched_at': None, 'pricing_id': f'baked:{prefix}',
            }
    return None

cm.rates_for = rates_for_no_disagreement
cm._PRICING_CACHE = (None, None)
r = cm.rates_for('claude-sonnet-5')
# Without disagreement rule, snapshot should win (even though it disagrees)
assert r['source'] == 'litellm' and r['in'] == 2.0, f'WITHOUT disagreement rule: {r}'
print('WITHOUT DISAGREEMENT RULE: CORRECTLY FAILS (case b is not vacuous)')
PYEOF
    run env COST_MIRROR_PRICING_PATH="$SNAP" MIRROR="$MIRROR" faketime '2026-09-02 12:00:00' python3 "$BATS_TEST_TMPDIR/test_without_disagree.py"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WITHOUT DISAGREEMENT RULE: CORRECTLY FAILS"* ]]
}

@test "cost-mirror: render_report marks rows spanning multiple epoch_model with a visible indicator" {
    # Multi-epoch fixture: a session crossing from opus-5 to haiku-4-5
    # The mk_epoch_transcript fixture creates multiple side|model combinations
    # with different epoch_model values for the same grouped row.
    # Main rows in different epochs will aggregate to show different epoch_model values.
    CSVDIR="$BATS_TEST_TMPDIR/csv-mark-projects"
    mkdir -p "$CSVDIR"
    mkdir -p "$BATS_TEST_TMPDIR/proj-mark"
    TP="$BATS_TEST_TMPDIR/proj-mark/sess.jsonl"
    {
        # worker BEFORE any main row (inside clamped-backward epoch)
        printf '{"isSidechain":true,"timestamp":"2026-07-28T23:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
        # opus-5 epoch: first main row
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-opus-5","usage":{"output_tokens":1000000}}}\n'
        # worker inside opus-5 epoch
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:01:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
        # haiku-4-5 epoch: /tier downgrade
        printf '{"timestamp":"2026-07-29T00:10:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
        # worker inside haiku-4-5 epoch
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:11:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
        # worker AFTER last main row (inside clamped-forward epoch)
        printf '{"isSidechain":true,"timestamp":"2026-07-29T01:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
    } > "$TP"

    # Verify render_report shows a marker for the multi-epoch main rows
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]

    # The main side should have rows from multiple epochs: opus-5 and haiku-4-5
    # These should be grouped as separate lines when rendered, but the worker row
    # which spans epochs should have a visible marker
    WORKER_LINE=$(echo "$output" | grep '^worker')
    # A multi-epoch worker line should show a marker (e.g., *, †, or similar)
    # This test verifies the marker is present and visible
    [[ "$WORKER_LINE" == *"†"* || "$WORKER_LINE" == *"*"* || "$WORKER_LINE" =~ [a-zA-Z0-9][\*†] ]]
}

@test "cost-mirror: render_all_sessions_table marks sessions spanning multiple epoch_model with a visible indicator" {
    # Setup multi-epoch session for aggregate report
    CSVDIR="$BATS_TEST_TMPDIR/csv-mark-all-projects"
    mkdir -p "$CSVDIR/proj-mark-all"
    TP="$CSVDIR/proj-mark-all/sess.jsonl"
    {
        # worker BEFORE any main row
        printf '{"isSidechain":true,"timestamp":"2026-07-28T23:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
        # opus-5 main row
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-opus-5","usage":{"output_tokens":1000000}}}\n'
        # haiku-4-5 main row (tier change)
        printf '{"timestamp":"2026-07-29T00:10:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
    } > "$TP"

    export COST_MIRROR_PROJECTS_DIR="$CSVDIR"

    # Run aggregate report which uses render_all_sessions_table
    run python3 "$MIRROR" --report
    [ "$status" -eq 0 ]

    # The multi-epoch session should show a visible marker (distinct from single-epoch)
    # in the render_all_sessions_table output
    [[ "$output" == *"proj-mark-all"* ]]
    # Extract the session line from proj-mark-all (might have marker)
    SESSION_LINE=$(echo "$output" | grep "proj-mark-all" | head -1)
    # A multi-epoch session should have a marker
    [[ "$SESSION_LINE" == *"†"* || "$SESSION_LINE" == *"*"* || "$SESSION_LINE" =~ [a-zA-Z0-9][\*†] ]]
}

@test "cost-mirror: single-epoch sessions render unchanged without any marker" {
    # Verify single-epoch sessions maintain byte-identical output (no marker)
    CSVDIR="$BATS_TEST_TMPDIR/csv-single-epoch-projects"
    mkdir -p "$CSVDIR/proj-single"
    TP="$CSVDIR/proj-single/sess.jsonl"
    {
        # All rows use the same model (single epoch)
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-opus-5","usage":{"output_tokens":1000000}}}\n'
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:01:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"output_tokens":1000000}}}\n'
    } > "$TP"

    export COST_MIRROR_PROJECTS_DIR="$CSVDIR"

    # Run aggregate report
    run python3 "$MIRROR" --report
    [ "$status" -eq 0 ]

    # Extract the single-epoch session line
    SESSION_LINE=$(echo "$output" | grep "proj-single.*sess" | head -1)
    # A single-epoch session should NOT have a multi-epoch marker
    # (it may have other content, but not the epoch-span marker)
    [[ "$SESSION_LINE" != *"†"* ]]
}

@test "cost-mirror --report: every token cell in render_report stays numeric, even on a multi-epoch row — the marker lives on its own annotation line" {
    # bd-q6c corrective slice 3: the FIRST fix for the epoch-span marker
    # fused it onto the "in" token count ("0†"), which the verifier
    # correctly refused (not byte-identical, not numeric). This pins the
    # replacement: the flagged row's own 9 fields stay pristine and the
    # marker moves to a separate annotation line directly below it.
    mk_epoch_transcript
    REP="$BATS_TEST_TMPDIR/numeric.txt"
    run sh -c "python3 '$MIRROR' --report '$TP' > '$REP'"
    [ "$status" -eq 0 ]

    # `read -a` against a multi-line grep capture only ever consumes the
    # FIRST line, so this is the worker row's own line, never the
    # annotation line appended directly below it (both start with "worker").
    WORKER_LINE=$(grep '^worker' "$REP" | head -1)
    read -r -a WL <<< "$WORKER_LINE"
    [ "${#WL[@]}" -eq 9 ]
    [[ "$WORKER_LINE" != *"†"* ]]
    [ "${WL[6]}" = '$20' ]
    [ "${WL[7]}" = '$60' ]
    [ "${WL[8]}" = '$40' ]

    run python3 - "$REP" <<'PY'
import re
import sys

data_rows = 0
for line in open(sys.argv[1]):
    m = re.match(
        r'^(main|worker\S*)\s+(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$',
        line,
    )
    if m:
        data_rows += 1
        for tok in m.groups()[2:6]:
            assert tok.isdigit(), ("non-numeric token cell", line)
    elif line.startswith("worker") and "†" in line:
        # the annotation line itself: must never look like a 9-field data
        # row to reconcile_csv's own heuristic (len(parts) == 9 and
        # parts[6] starting with "$"), or a future re-wording of the note
        # could silently poison --csv reconciliation again
        parts = line.split()
        looks_like_row = len(parts) == 9 and parts[6].lstrip("-").startswith("$")
        assert not looks_like_row, ("annotation line parses as a data row", parts)
assert data_rows == 3, ("expected 2 main rows + 1 worker row", data_rows)
print(f"OK: {data_rows} numeric data rows, annotation line not row-shaped")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

@test "cost-mirror --report: overdrive marks at-top and saved columns as n/a (OVERDRIVE)" {
    # When TIER_OVERDRIVE=1, the at-top and saved columns should show "n/a (OVERDRIVE)"
    # since under overdrive the worker IS the top model, so there's no savings to report.
    TP="$BATS_TEST_TMPDIR/proj-overdrive/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-overdrive"
    {
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-fable-5","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":400000,"ephemeral_1h_input_tokens":100000}}}}\n'
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:01:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":2000000,"output_tokens":200000}}}\n'
    } > "$TP"

    # Setup settings file with TIER_OVERDRIVE=1
    mkdir -p "$BATS_TEST_TMPDIR/settings"
    SETTINGS_OVERDRIVE="$BATS_TEST_TMPDIR/settings/settings-overdrive.json"
    printf '{"env":{"TIER_OVERDRIVE":"1"}}' > "$SETTINGS_OVERDRIVE"

    export COST_MIRROR_SETTINGS_PATH="$SETTINGS_OVERDRIVE"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]

    # Check that at-top and saved columns show "n/a (OVERDRIVE)"
    # The output should contain this marker in the at-top and saved columns
    [[ "$output" == *"n/a (OVERDRIVE)"* ]]

    # TOTAL line should also have n/a (OVERDRIVE) in the at-top and saved positions
    TOTAL_LINE=$(echo "$output" | grep '^TOTAL')
    [[ "$TOTAL_LINE" == *"n/a (OVERDRIVE)"* ]]
}

@test "cost-mirror --report: with TIER_OVERDRIVE off, output is byte-identical to baseline" {
    # Verify that without overdrive flag, the report is byte-identical
    TP="$BATS_TEST_TMPDIR/proj-no-overdrive/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-no-overdrive"
    {
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-fable-5","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":400000,"ephemeral_1h_input_tokens":100000}}}}\n'
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:01:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":2000000,"output_tokens":200000}}}\n'
    } > "$TP"

    # Run without overdrive flag (settings file missing or with flag off)
    mkdir -p "$BATS_TEST_TMPDIR/settings-baseline"
    SETTINGS_BASELINE="$BATS_TEST_TMPDIR/settings-baseline/settings.json"
    printf '{}' > "$SETTINGS_BASELINE"

    export COST_MIRROR_SETTINGS_PATH="$SETTINGS_BASELINE"
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    BASELINE_OUTPUT="$output"

    # Run again to verify byte-identical output
    run python3 "$MIRROR" --report "$TP"
    [ "$status" -eq 0 ]
    [ "$output" = "$BASELINE_OUTPUT" ]

    # Verify the normal columns are still there (not n/a)
    TOTAL_LINE=$(echo "$output" | grep '^TOTAL')
    # Should contain dollar signs, not "n/a (OVERDRIVE)"
    [[ "$TOTAL_LINE" =~ \$ ]]
    [[ "$TOTAL_LINE" != *"n/a (OVERDRIVE)"* ]]
}

@test "cost-mirror --report: overdrive columns are wide enough that money and marker never fuse" {
    # Regression for bead gu4's reopen: "n/a (OVERDRIVE)" (15 chars) and the
    # header's "at-top \$ (n/a)" / "saved \$ (n/a)" (14/13 chars) overran the
    # plain 10-char money column. rjust never truncates an oversized value,
    # so the marker ran straight into its neighbour with no gap at all --
    # "\$230n/a (OVERDRIVE)n/a (OVERDRIVE)" in raw piped text, on EVERY row
    # including TOTAL, and in the header itself
    # ("actual \$*at-top \$ (n/a)saved \$ (n/a)"). The old test only checked
    # substring presence, never layout, so a green suite never saw it.
    TP="$BATS_TEST_TMPDIR/proj-overdrive-width/sess.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/proj-overdrive-width"
    {
        printf '{"timestamp":"2026-07-29T00:00:00Z","message":{"model":"claude-fable-5","usage":{"input_tokens":1156,"output_tokens":659967,"cache_read_input_tokens":117634736,"cache_creation":{"ephemeral_5m_input_tokens":3000000,"ephemeral_1h_input_tokens":992524}}}}\n'
        printf '{"isSidechain":true,"timestamp":"2026-07-29T00:01:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":166,"output_tokens":2883,"cache_read_input_tokens":397872,"cache_creation":{"ephemeral_5m_input_tokens":50000,"ephemeral_1h_input_tokens":23768}}}}\n'
    } > "$TP"

    mkdir -p "$BATS_TEST_TMPDIR/settings"
    SETTINGS_OVERDRIVE="$BATS_TEST_TMPDIR/settings/settings-width.json"
    printf '{"env":{"TIER_OVERDRIVE":"1"}}' > "$SETTINGS_OVERDRIVE"

    export COST_MIRROR_SETTINGS_PATH="$SETTINGS_OVERDRIVE"
    REP="$BATS_TEST_TMPDIR/overdrive-report.txt"
    run sh -c "python3 '$MIRROR' --report '$TP' > '$REP'"
    [ "$status" -eq 0 ]

    run python3 - "$REP" <<'PY'
import re
import sys

text = open(sys.argv[1]).read()
lines = text.splitlines()

# 1) No occurrence of the marker may be glued to its neighbour: the
# character immediately before/after "n/a (OVERDRIVE)" must be
# whitespace or a line boundary, on every line it appears (header,
# every side|model row, and TOTAL).
positions = [m.start() for m in re.finditer(re.escape("n/a (OVERDRIVE)"), text)]
assert positions, "no overdrive markers found in report"
for pos in positions:
    before = text[pos - 1] if pos > 0 else "\n"
    assert before in " \n", ("marker glued to preceding text", text[max(0, pos - 20):pos + 20])
    end = pos + len("n/a (OVERDRIVE)")
    after = text[end] if end < len(text) else "\n"
    assert after in " \n", ("marker glued to following text", text[pos:end + 20])

# 2) header/data/TOTAL rows in the table all derive their length from the
# SAME `widths` tuple in render_report, so a non-overflowing render makes
# them all exactly the length of the header (a separator dash-line is the
# same length by construction). An overflowing cell in ANY of them would
# make that row LONGER than the header -- rjust/ljust only pad, they
# never truncate.
header_line = next(l for l in lines if l.startswith("side "))
row_lines = [
    l for l in lines
    if (l.startswith("main") or l.startswith("worker") or l.startswith("TOTAL"))
    and "†" not in l
]
assert row_lines, "no data/TOTAL rows found"
for l in row_lines:
    assert len(l) == len(header_line), ("row overflowed the table width", len(l), len(header_line), l)

print(f"OK: {len(positions)} markers all separated, {len(row_lines)} rows match header width {len(header_line)}")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

@test "cost-mirror --report --csv: leading-punctuation identifier cells are neutralised for Excel formula injection prevention" {
    # Project directory names here lead with '-' (e.g., '-workspace', '-tmp-...')
    # Written raw into CSV, a cell starting '-', '=', '+' or '@' is read by Excel as a formula.
    # Fix: prefix such cells with a single quote for identifier columns only.
    CSVDIR="$BATS_TEST_TMPDIR/csv-formula-inject"
    mkdir -p "$CSVDIR/-workspace"
    TP="$CSVDIR/-workspace/sess.jsonl"
    {
        printf '{"message":{"model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":400000,"ephemeral_1h_input_tokens":100000}}}}\n'
        printf '{"isSidechain":true,"message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":2000000,"output_tokens":200000}}}\n'
    } > "$TP"

    export COST_MIRROR_PROJECTS_DIR="$CSVDIR"
    OUT="$BATS_TEST_TMPDIR/formula-inject.csv"
    run python3 "$MIRROR" --report --csv "$OUT"
    [ "$status" -eq 0 ]

    # Check that the project column (which starts with '-workspace') is neutralised
    # It should have a single quote prefix or be properly quoted
    CSV_CONTENT=$(cat "$OUT")
    # The project column should be neutralised (starts with ' or is properly escaped)
    [[ "$CSV_CONTENT" == *"'-workspace"* ]]

    # Also verify numeric columns are not affected
    NUMERIC_LINE=$(tail -1 "$OUT")
    [[ "$NUMERIC_LINE" =~ [0-9] ]]
}
