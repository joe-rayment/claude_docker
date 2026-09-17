#!/usr/bin/env bats
#
# Two coordinators in one folder keep distinct Runs (claude-orca-fyv).
#
# Seen 2026-09-12: a second Claude session's orca-dispatch wrote run.json
# with ITS Run under the first session's feet, and the first session's
# orca-wait then asked the runtime for a Run it was not bound to. The fix:
# the Run record is keyed per coordinator handle (runs/<handle>.json), the
# legacy run.json stays the empty-handle / compatibility file, and every
# reader picks the record for its own handle first. Nothing here touches a
# real runtime: the CLI is the stub in tests/helpers/orca-stub.bash, so an
# assertion about "which run did it use" is an assertion about the argv the
# tool actually produced.
#
# FROZEN from RED-AT onward.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
DISPATCH="$REPO_ROOT/scripts/orca-dispatch.sh"
WAIT="$REPO_ROOT/scripts/orca-wait.sh"
WORKERS="$REPO_ROOT/scripts/orca-workers.sh"

setup() {
    # shellcheck source=helpers/orca-stub.bash
    . "$BATS_TEST_DIRNAME/helpers/orca-stub.bash"
    orca_stub_init

    export CLAUDE_ORCA_ROOT="$BATS_TEST_TMPDIR/root"
    export TIER_STATE_FILE="$BATS_TEST_TMPDIR/no-such-tier.json"
    export CLAUDE_ORCA_DISPATCH_STAGGER_MS=0
    unset ORCA_TERMINAL_HANDLE ORCA_PANE_KEY
    ODIR="$CLAUDE_ORCA_ROOT/.claude-dev/run/orchestration"
    RUNS="$ODIR/runs"
    mkdir -p "$ODIR/dispatch"

    orca_stub_reply orchestration-task-create \
        '{"ok":true,"result":{"task":{"id":"t1"}}}'
    orca_stub_reply orchestration-worker-start \
        '{"ok":true,"result":{"dispatchId":"d1","state":"running",
          "effects":[{"kind":"terminal","id":"term_w1"}],
          "launch":{"effective":{"agent":"claude","model":"sonnet"}}}}'
}

# receipt -- the last stdout line of a dispatch (notes go to stderr)
receipt() { printf '%s\n' "$1" | tail -1; }

@test "two coordinator handles dispatching into one folder produce two run files with distinct run ids and neither overwrites the other" {
    orca_stub_reply_nth orchestration-run-create 1 \
        '{"ok":true,"result":{"run":{"id":"runA","coordinator_handle":"term_A"}}}'
    orca_stub_reply_nth orchestration-run-create 2 \
        '{"ok":true,"result":{"run":{"id":"runB","coordinator_handle":"term_B"}}}'
    orca_stub_reply_nth orchestration-worker-start 1 \
        '{"ok":true,"result":{"dispatchId":"dA","state":"running",
          "effects":[{"kind":"terminal","id":"term_wA"}],
          "launch":{"effective":{"agent":"claude","model":"sonnet"}}}}'
    orca_stub_reply_nth orchestration-worker-start 2 \
        '{"ok":true,"result":{"dispatchId":"dB","state":"running",
          "effects":[{"kind":"terminal","id":"term_wB"}],
          "launch":{"effective":{"agent":"claude","model":"sonnet"}}}}'

    run --separate-stderr "$DISPATCH" b1 --worker --agent claude --model sonnet \
        --worktree "path:$CLAUDE_ORCA_ROOT" --from term_A
    [ "$status" -eq 0 ]
    a_rcpt="$(receipt "$output")"
    run --separate-stderr "$DISPATCH" b1 --worker --agent claude --model sonnet \
        --worktree "path:$CLAUDE_ORCA_ROOT" --from term_B
    [ "$status" -eq 0 ]
    b_rcpt="$(receipt "$output")"

    [ -f "$RUNS/term_A.json" ]
    [ -f "$RUNS/term_B.json" ]
    run jq -e '.run_id == "runA" and .coordinator_handle == "term_A"' "$RUNS/term_A.json"
    [ "$status" -eq 0 ]
    run jq -e '.run_id == "runB" and .coordinator_handle == "term_B"' "$RUNS/term_B.json"
    [ "$status" -eq 0 ]
    run jq -e '.run_id == "runA"' <<<"$a_rcpt"
    [ "$status" -eq 0 ]
    run jq -e '.run_id == "runB"' <<<"$b_rcpt"
    [ "$status" -eq 0 ]
}

@test "orca-wait --from term_A passes --run runA to the stub and --from term_B passes runB, whatever the legacy run.json says" {
    orca_stub_reply orchestration-check \
        '{"ok":true,"result":{"count":0,"messages":[],"deliveryId":""}}'

    # the incident: the second coordinator's orca-dispatch left the legacy
    # file holding ITS run, and the first session's orca-wait read it
    printf '%s\n' '{"run_id":"runB","coordinator_handle":"term_B"}' >"$ODIR/run.json"
    mkdir -p "$RUNS"
    printf '%s\n' '{"run_id":"runA","coordinator_handle":"term_A"}' >"$RUNS/term_A.json"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --from term_A
    [ "$status" -eq 0 ]
    calls="$(orca_stub_calls 'orchestration check')"
    printf '%s\n' "$calls" | grep -q -F -e '--run runA'
    run grep -q -F -e '--run runB' <<<"$calls"
    [ "$status" -ne 0 ]

    # the mirror image: run.json now holds term_A's run, term_B still reads
    # its own keyed record
    printf '%s\n' '{"run_id":"runA","coordinator_handle":"term_A"}' >"$ODIR/run.json"
    printf '%s\n' '{"run_id":"runB","coordinator_handle":"term_B"}' >"$RUNS/term_B.json"
    : >"$ORCA_STUB_LOG"
    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --from term_B
    [ "$status" -eq 0 ]
    calls="$(orca_stub_calls 'orchestration check')"
    printf '%s\n' "$calls" | grep -q -F -e '--run runB'
    run grep -q -F -e '--run runA' <<<"$calls"
    [ "$status" -ne 0 ]
}

@test "with no handle at all, a pre-seeded legacy run.json is still read" {
    orca_stub_reply orchestration-check \
        '{"ok":true,"result":{"count":0,"messages":[],"deliveryId":""}}'
    printf '%s\n' '{"run_id":"runLegacy","coordinator_handle":"term_legacy"}' \
        >"$ODIR/run.json"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1
    [ "$status" -eq 0 ]
    printf '%s\n' "$(orca_stub_calls 'orchestration check')" |
        grep -q -F -e '--run runLegacy'
}

@test "a coordinator dispatching twice keeps one Run: the keyed file is reused via run-use" {
    orca_stub_reply_nth orchestration-run-create 1 \
        '{"ok":true,"result":{"run":{"id":"runA","coordinator_handle":"term_A"}}}'

    run --separate-stderr "$DISPATCH" b1 --worker --agent claude --model sonnet \
        --worktree "path:$CLAUDE_ORCA_ROOT" --from term_A
    [ "$status" -eq 0 ]
    run --separate-stderr "$DISPATCH" b1 --worker --agent claude --model sonnet \
        --worktree "path:$CLAUDE_ORCA_ROOT" --from term_A
    [ "$status" -eq 0 ]
    run jq -e '.run_id == "runA"' <<<"$(receipt "$output")"
    [ "$status" -eq 0 ]

    [ "$(orca_stub_calls 'orchestration run-create' | wc -l | tr -d ' ')" = "1" ]
    [ -n "$(orca_stub_calls 'orchestration run-use')" ]
}

@test "a coordinator handle with / or .. never names a run file" {
    # shellcheck source=../scripts/lib/orca-orch.sh
    . "$REPO_ROOT/scripts/lib/orca-orch.sh"
    run orch_run_file "$CLAUDE_ORCA_ROOT" "term/evil"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    run orch_run_file "$CLAUDE_ORCA_ROOT" "term/../evil"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    run orch_run_file "$CLAUDE_ORCA_ROOT" ".."
    [ "$status" -ne 0 ]
    run orch_run_file "$CLAUDE_ORCA_ROOT" "term_A"
    [ "$status" -eq 0 ]
    [ "$output" = "$RUNS/term_A.json" ]
    run orch_run_file "$CLAUDE_ORCA_ROOT" ""
    [ "$status" -eq 0 ]
    [ "$output" = "$ODIR/run.json" ]
}

@test "orca-dispatch refuses a handle that would escape the runs directory" {
    run --separate-stderr "$DISPATCH" b1 --worker --agent claude --model sonnet \
        --worktree "path:$CLAUDE_ORCA_ROOT" --from "term/../../evil"
    [ "$status" -eq 4 ]
    [ -e "$RUNS" ] || true
    [ "$(ls "$RUNS" 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
}

@test "orca-workers reads the keyed run of the coordinator it runs as" {
    printf '%s\n' '{"run_id":"runB","coordinator_handle":"term_B"}' >"$ODIR/run.json"
    mkdir -p "$RUNS"
    printf '%s\n' '{"run_id":"runA","coordinator_handle":"term_A"}' >"$RUNS/term_A.json"
    orca_stub_reply orchestration-worker-list '{"ok":true,"result":{"workers":[]}}'
    orca_stub_reply orchestration-task-list '{"ok":true,"result":{"tasks":[]}}'

    export ORCA_TERMINAL_HANDLE=term_A
    run "$WORKERS" --json
    [ "$status" -eq 0 ]
    calls="$(orca_stub_calls 'orchestration worker-list')"
    printf '%s\n' "$calls" | grep -q -F -e '--run runA'
    run grep -q -F -e '--run runB' <<<"$calls"
    [ "$status" -ne 0 ]
}