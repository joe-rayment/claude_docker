#!/usr/bin/env bats
#
# recon (claude-orca-424.1): the bead-less, synchronous, read-only headless
# opencode run on the tier's recon backend -- question on the command line,
# answer on stdout, cost in the delegate ledger. Nothing here touches a real
# runtime: opencode is a stub on PATH that logs its argv one per line,
# records OPENROUTER_API_KEY / OPENCODE_CONFIG / PWD, prints a canned
# --format json event stream (two text parts, one step_finish carrying
# tokens and cost), sleeps $STUB_SLEEP and exits $STUB_EXIT.
#
# The fixture is a scratch project (a .claude-dev/claude-orca.json marker so
# paths.sh resolves it) with its own .claude-dev/run: the guard token, a
# sentinel openrouter-guard.env that must come out byte-identical, and a
# tier.json binding recon to orca:opencode:gpt-5.6-luna@high. Ambient
# PROJECT_DIR, CLAUDE_ORCA_ROOT and BEADS_DIR are unset first, and the
# script under test is pinned by path -- never trusted to PATH.
#
# FROZEN from RED-AT onward.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME:-.}/.." && pwd)"
RECON="$REPO_ROOT/scripts/recon.sh"

setup() {
    T="$BATS_TEST_TMPDIR"
    unset PROJECT_DIR CLAUDE_ORCA_ROOT BEADS_DIR
    unset OPENROUTER_API_KEY OPENCODE_CONFIG
    unset CLAUDE_ORCA_RECON_TIMEOUT_S CLAUDE_ORCA_GUARD_PORT
    unset STUB_EXIT STUB_SLEEP

    PROJECT="$T/project"
    RUN="$PROJECT/.claude-dev/run"
    mkdir -p "$RUN"
    printf '{"name":"fixture","version":"0"}\n' >"$PROJECT/.claude-dev/claude-orca.json"
    printf 'sk-or-test-TOKEN' >"$RUN/openrouter-guard.token"
    printf 'SENTINEL-DO-NOT-TOUCH\n' >"$RUN/openrouter-guard.env"
    cp "$RUN/openrouter-guard.env" "$T/guard.env.sentinel"

    cat >"$RUN/tier.json" <<'JSON'
{
  "top": "fable",
  "roles": {
    "recon": {
      "backend": "orca",
      "agent": "opencode",
      "model": "openrouter/openai/gpt-5.6-luna",
      "pinned": true,
      "variant": "high"
    }
  }
}
JSON
    export RECON_STATE_FILE="$RUN/tier.json"
    export RECON_RUN_DIR="$RUN"
    export PROJECT_DIR="$PROJECT"
    # recon.sh hands every receipt to cost-mirror (fail-open); without this
    # the stub receipts land in the REAL ledger at
    # ~/.claude/cache/cost-mirror/lifetime.json (claude-orca-424.4).
    export COST_MIRROR_STATE_DIR="$T/cost-mirror"

    mkdir -p "$T/bin"
    export STUB_LOG="$T/opencode-stub.log"
    export STUB_ENV="$T/opencode-stub.env"
    rm -f "$STUB_LOG" "$STUB_ENV"
    cat >"$T/bin/opencode" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    printf '%s\n' "$a" >>"$STUB_LOG"
done
{
    printf 'OPENROUTER_API_KEY=%s\n' "$OPENROUTER_API_KEY"
    printf 'OPENCODE_CONFIG=%s\n' "$OPENCODE_CONFIG"
    printf 'PWD=%s\n' "$PWD"
} >>"$STUB_ENV"
if [ -n "${STUB_ANSWER_WORD:-}" ]; then
    # Answer with the question's last word, so two concurrent runs asking
    # different questions can be told apart in their captured stdout.
    last_arg=""
    for a in "$@"; do last_arg="$a"; done
    printf '%s\n' "{\"type\":\"text\",\"part\":{\"text\":\"ANSWER-${last_arg##* }\"}}"
fi
printf '%s\n' '{"type":"text","part":{"text":"- scripts/a.sh:12 does X"}}'
printf '%s\n' '{"type":"step_finish","part":{"tokens":{"input":10,"output":20,"reasoning":5},"cost":0.001}}'
printf '%s\n' '{"type":"text","part":{"text":"- nothing under src/ matches"}}'
sleep "${STUB_SLEEP:-0}"
exit "${STUB_EXIT:-0}"
STUB
    chmod +x "$T/bin/opencode"
    export PATH="$T/bin:$PATH"

    cd "$PROJECT"
}

@test "runs opencode headless on the recon model in the project dir" {
    run --separate-stderr "$RECON" "which callers use tier_role_field under scripts/"
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' "$STUB_LOG")" = "run" ]
    [ "$(sed -n '2p' "$STUB_LOG")" = "-m" ]
    [ "$(sed -n '3p' "$STUB_LOG")" = "openrouter/openai/gpt-5.6-luna" ]
    [ "$(sed -n '4p' "$STUB_LOG")" = "--dir" ]
    [ "$(sed -n '5p' "$STUB_LOG")" = "$PROJECT" ]
    [ "$(sed -n '6p' "$STUB_LOG")" = "--auto" ]
    [ "$(sed -n '7p' "$STUB_LOG")" = "--format" ]
    [ "$(sed -n '8p' "$STUB_LOG")" = "json" ]
    last="$(tail -n 1 "$STUB_LOG")"
    grep -q "which callers use tier_role_field under scripts/" <<<"$last"
}

@test "stdout is the joined text parts" {
    run --separate-stderr "$RECON" "q"
    [ "$status" -eq 0 ]
    [ "$output" = "- scripts/a.sh:12 does X
- nothing under src/ matches" ]
}

@test "the guard token and a read-only launch config reach opencode through the environment" {
    run --separate-stderr "$RECON" "q"
    [ "$status" -eq 0 ]
    grep -q '^OPENROUTER_API_KEY=sk-or-test-TOKEN$' "$STUB_ENV"
    cfg="$(sed -n 's/^OPENCODE_CONFIG=//p' "$STUB_ENV")"
    [ -n "$cfg" ]
    [[ "$cfg" == "$RUN/opencode-launch/"recon-*.json ]]
    [ "$(jq -r '.permission.edit' "$cfg")" = "deny" ]
    [ "$(jq -r '.permission.write' "$cfg")" = "deny" ]
    [ "$(jq -r '.provider.openrouter.models["openai/gpt-5.6-luna"].options.reasoning.effort' "$cfg")" = "high" ]
    [[ "$(jq -r '.provider.openrouter.options.baseURL' "$cfg")" == *"4141"* ]]
    mode="$(stat -c %a "$cfg" 2>/dev/null || stat -f %Lp "$cfg")"
    [ "$mode" = "600" ]
}

@test "the shared guard env file is never touched" {
    run --separate-stderr "$RECON" "q"
    [ "$status" -eq 0 ]
    cmp -s "$RUN/openrouter-guard.env" "$T/guard.env.sentinel"
}

@test "the summary line, the log and the receipt carry the tokens and cost" {
    run --separate-stderr "$RECON" "q"
    [ "$status" -eq 0 ]
    grep -q "in 10 out 20 reasoning 5" <<<"$stderr"
    grep -q '\$0\.001' <<<"$stderr"
    log="$(awk '{print $NF}' <<<"$stderr")"
    [ -f "$log" ]
    grep -q 'step_finish' "$log"
    receipt="$(ls "$RUN"/recon/*.receipt.json)"
    [ "$(jq -r '.tokens_in' "$receipt")" = "10" ]
    [ "$(jq -r '.tokens_out' "$receipt")" = "20" ]
    [ "$(jq -r '.usd' "$receipt")" = "0.001" ]
    [ "$(jq -r '.route' "$receipt")" = "recon" ]
    [ "$(jq -r '.model' "$receipt")" = "openrouter/openai/gpt-5.6-luna" ]
    [ "$(jq -r '.variant' "$receipt")" = "high" ]
    ! grep -r 'sk-or-test-TOKEN' "$RUN/recon" "$RUN/opencode-launch"
}

@test "a subagent-backed recon role is the scout fallback" {
    jq '.roles.recon.backend = "subagent"' "$RUN/tier.json" >"$RUN/tier.json.new"
    mv -f "$RUN/tier.json.new" "$RUN/tier.json"
    run --separate-stderr "$RECON" "q"
    [ "$status" -eq 3 ]
    grep -q "scout" <<<"$stderr"
    [ ! -e "$STUB_LOG" ]
}

@test "no tier.json and no guard token are the same fallback" {
    rm -f "$RUN/tier.json"
    run --separate-stderr "$RECON" "q"
    [ "$status" -eq 3 ]
    grep -q "unbound" <<<"$stderr"
    [ ! -e "$STUB_LOG" ]

    cat >"$RUN/tier.json" <<'JSON'
{ "roles": { "recon": { "backend": "orca", "agent": "opencode",
  "model": "openrouter/openai/gpt-5.6-luna", "pinned": true, "variant": "high" } } }
JSON
    rm -f "$RUN/openrouter-guard.token"
    run --separate-stderr "$RECON" "q"
    [ "$status" -eq 3 ]
    grep -q "guard is down" <<<"$stderr"
    [ ! -e "$STUB_LOG" ]
}

@test "no question is a usage error" {
    run "$RECON"
    [ "$status" -eq 64 ]
}

@test "--prompt-file and --dir" {
    printf 'list every caller of orca_call and whether it checks the reply\n' >"$T/q.txt"
    run --separate-stderr "$RECON" --prompt-file "$T/q.txt" --dir /some/other/dir
    [ "$status" -eq 0 ]
    last="$(tail -n 1 "$STUB_LOG")"
    grep -q "list every caller of orca_call" <<<"$last"
    dir="$(awk 'seen {print; exit} {seen = ($0 == "--dir")}' "$STUB_LOG")"
    [ "$dir" = "/some/other/dir" ]
}

@test "opencode's exit code is the exit code, and a timeout is 124" {
    export STUB_EXIT=7
    run --separate-stderr "$RECON" "q"
    [ "$status" -eq 7 ]

    rm -f "$STUB_LOG"
    export STUB_EXIT=0 STUB_SLEEP=5
    run --separate-stderr "$RECON" --timeout 1 "q"
    [ "$status" -eq 124 ]
    grep -q "timed out" <<<"$stderr"
}

# Guards: two recon runs launched in the same second (the normal
# run_in_background fan-out) each get their own log under <run>/recon/ and
# each print their own answer, not one clobbered by the other's.
# Fails if: recon.sh's STEM has no per-process part, so same-second calls
# on the same model share one log/receipt -- each truncates the shared log
# and parses the other's events.
# Run: bats tests/recon.bats -f 'same-second'
@test "two same-second runs each get their own log and their own answer" {
    export STUB_ANSWER_WORD=1
    "$RECON" "which callers check tier-roles-first alpha" >"$T/out1" 2>"$T/err1" &
    p1=$!
    "$RECON" "which callers check tier-roles-first zebra" >"$T/out2" 2>"$T/err2" &
    p2=$!
    wait "$p1"; s1=$?
    wait "$p2"; s2=$?
    [ "$s1" -eq 0 ]
    [ "$s2" -eq 0 ]
    grep -q 'ANSWER-alpha' "$T/out1"
    grep -q 'ANSWER-zebra' "$T/out2"
    ! grep -q 'ANSWER-zebra' "$T/out1"
    ! grep -q 'ANSWER-alpha' "$T/out2"
    logs=("$RUN"/recon/*.log)
    [ "${#logs[@]}" -eq 2 ]
}