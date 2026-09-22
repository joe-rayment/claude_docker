#!/usr/bin/env bats
#
# recon-routing-docs.bats -- claude-orca-424.3 acceptance contract, FROZEN
# from RED-AT onward. Recon follows its backend: every place that tells
# the orchestrator how recon is routed says `recon "<question>"` (a Bash
# call; the sibling bead ships the command) when the recon role's backend
# is orca, a `scout` spawn otherwise. Text-only bead: the one behaviour
# change is `recon` joining delegation-gate's exempt-command alternation
# (case 4).

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

USER_MEMORY="$REPO_ROOT/config/claude-user-memory.md"
KB_TIERED="$REPO_ROOT/knowledge-base/TIERED_ORCHESTRATION.md"
GATE="$REPO_ROOT/python/delegation-gate.py"
PRIME="$REPO_ROOT/scripts/tier-prime.sh"
SCOUT_MD="$REPO_ROOT/config/agents/scout.md"
FANOUT_JS="$REPO_ROOT/config/workflows/recon-fanout.js"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    # Never trust ambient harness env: the hook cases below pin their
    # state by HOME/CLAUDE_CONFIG_DIR/CLAUDE_ORCA_ROOT fixtures instead.
    unset PROJECT_DIR BEADS_DIR CLAUDE_ORCA_ROOT
}

@test "the rulebook routes recon by backend" {
    grep -qF 'recon "<question>"' "$USER_MEMORY"
    ! grep -qF 'checkers and recon stay in-process' "$USER_MEMORY"
    words=$(wc -w < "$USER_MEMORY")
    [ "$words" -le 1300 ]
}

@test "the knowledge base explains the orca-backed recon path" {
    count=$(grep -cF 'recon "<question>"' "$KB_TIERED")
    [ "$count" -ge 3 ]
    grep -q 'run_in_background' "$KB_TIERED"
}

@test "the delegation-gate nudge names the recon backend" {
    ! grep -qF 'recon to a scout,' "$GATE"
    grep -qF 'recon "<question>"' "$GATE"
}

@test "a recon Bash call is exempt from the delegation-gate streak" {
    # Run the way tests/delegation-gate.bats runs its exempt-command
    # cases (the `bd ready` one): enforce mode, deny at 2, and a Bash
    # payload whose command is a recon call -- silent, and the streak
    # never even gets a state file.
    export HOME="$BATS_TEST_TMPDIR/home"
    export CLAUDE_CONFIG_DIR="$HOME/.claude"
    mkdir -p "$HOME"
    export LANE_STATE_DIR="$BATS_TEST_TMPDIR/lane-state"
    sid="s-recon-routing"
    for i in 1 2 3 4; do
        run sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"'"$sid"'\",agent_id:null,tool_input:{command:\"recon \\\"where is X configured?\\\"\"}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    [ ! -f "$HOME/.claude/cache/delegation-gate/$sid.json" ]
}

@test "the tier banner names recon for an orca-backed recon role" {
    export CLAUDE_ORCA_ROOT="$BATS_TEST_TMPDIR/root"
    export CLAUDE_CONFIG_DIR="$CLAUDE_ORCA_ROOT/.claude"
    mkdir -p "$CLAUDE_ORCA_ROOT/.claude-dev/run" "$CLAUDE_CONFIG_DIR"
    STATE_FILE="$CLAUDE_ORCA_ROOT/.claude-dev/run/tier.json"
    jq -n '{top:"fable", worker:"sonnet", recon:"haiku",
            roles:{
              worker:  {backend:"subagent", agent:"claude",   model:"sonnet"},
              recon:   {backend:"orca",     agent:"opencode",
                        model:"openrouter/openai/gpt-5.6-luna", variant:"high"},
              checker: {backend:"subagent", agent:"claude",   model:"opus"}},
            pinned:false, overdrive:false}' > "$STATE_FILE"
    TIER_PRIME_STATE_FILE="$STATE_FILE" run "$PRIME" </dev/null
    [ "$status" -eq 0 ]
    backends_line="$(printf '%s\n' "$output" | grep '^\[tier\] backends:')"
    [ -n "$backends_line" ]
    [[ "$backends_line" == *'recon "<question>"'* ]]
}

@test "scout.md points at recon when the backend is orca" {
    grep -qF 'recon "<question>"' "$SCOUT_MD"
    grep -q '^model: haiku$' "$SCOUT_MD"
}

@test "recon-fanout declares itself the in-process form" {
    # meta stays a pure literal, so its description line is greppable.
    grep -F 'recon "<question>"' "$FANOUT_JS" | grep -F 'description:'
}
