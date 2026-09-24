#!/usr/bin/env bats
#
# The Orca relay + reaper (claude-orca-7lz.3): a worker_done report whose
# body carries a HANDOFF block is saved to the bead's notes and the receipt
# names orca-dispatch as the way to continue it; orch_spec folds the last
# HANDOFF back into the next dispatch's spec; the stall scan releases (and
# closes the terminal of) a worker it gives up on instead of leaving it
# resident.
#
# FROZEN from RED-AT onward. Nothing here touches a real Orca runtime: the
# CLI is the stub in tests/helpers/orca-stub.bash, which replays canned JSON
# per subcommand and logs every argv, so an assertion about "worker-release
# was called" is an assertion about the argv orca-wait actually produced.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
WAIT="$REPO_ROOT/scripts/orca-wait.sh"

setup() {
    # shellcheck source=helpers/orca-stub.bash
    . "$BATS_TEST_DIRNAME/helpers/orca-stub.bash"
    orca_stub_init

    export CLAUDE_ORCA_ROOT="$BATS_TEST_TMPDIR/root"
    ODIR="$CLAUDE_ORCA_ROOT/.claude-dev/run/orchestration"
    mkdir -p "$ODIR/dispatch"
    printf '%s\n' '{"run_id":"run1","coordinator_handle":"term_coord"}' \
        >"$ODIR/run.json"
    orca_stub_reply orchestration-check \
        '{"ok":true,"result":{"count":0,"messages":[],"deliveryId":""}}'
    orca_stub_reply orchestration-worker-release \
        '{"ok":true,"result":{"state":"retained"}}'
    NOW="$(date +%s)"
}

record() {
    orca_stub_dispatch_record "$CLAUDE_ORCA_ROOT" "$1" "$2"
}

# worker_done_msg <disp> <term> <body-json-string>
worker_done_msg() {
    printf '{"ok":true,"result":{"count":1,"deliveryId":"del1","messages":[
      {"type":"worker_done","id":"m1","subject":"done","from_handle":"%s",
       "body":%s,
       "payload":{"taskId":"t1","dispatchId":"%s","outcome":"succeeded",
                  "filesModified":["a.sh"]}}]}}' "$2" "$3" "$1"
}

stalled_line() {
    printf '%s\n' "$1" | grep -e '"type":"stalled"' | head -1
}

worker_done_line() {
    printf '%s\n' "$1" | grep -e '"type":"worker_done"' | head -1
}

@test "worker_done whose body ends with a HANDOFF block relays it to the bead notes and the receipt" {
    body=$'done: read the files\nleft: nothing\nfacts: f.sh:1\nHANDOFF\ndone: read the files\nleft: wire it up\nfacts: f.sh:1\nnext: wire it up\nrelay: this agent is finished -- start a fresh one from this block; never message or resume it.'
    record d1 "$(jq -n -c --argjson s "$((NOW - 100))" \
        '{bead:"b1", dispatch_id:"d1", task_id:"t1", terminal:"term_d1",
          state:"running", started_at:$s, worktree_path:""}')"
    orca_stub_reply_nth orchestration-check 1 \
        "$(worker_done_msg d1 term_d1 "$(jq -n --arg b "$body" '$b')")"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    out="$output"

    notes="$(grep -A20 -e 'bd update' "$ORCA_STUB_LOG")"
    printf '%s\n' "$notes" | grep -q -e 'HANDOFF-AT '
    printf '%s\n' "$notes" | grep -q -e 'next: wire it up'

    line="$(worker_done_line "$out")"
    [ -n "$line" ]
    run jq -e '.handoff == true' <<<"$line"
    [ "$status" -eq 0 ]
    run jq -e '.relay_with == "orca-dispatch b1"' <<<"$line"
    [ "$status" -eq 0 ]

    run jq -e '.handoff == true and .state == "done"' "$ODIR/dispatch/d1.json"
    [ "$status" -eq 0 ]

    calls="$(orca_stub_calls 'worker-release')"
    [ -n "$calls" ]
}

@test "worker_done without a HANDOFF block relays nothing" {
    record d2 "$(jq -n -c --argjson s "$((NOW - 100))" \
        '{bead:"b1", dispatch_id:"d2", task_id:"t1", terminal:"term_d2",
          state:"running", started_at:$s, worktree_path:""}')"
    orca_stub_reply_nth orchestration-check 1 \
        "$(worker_done_msg d2 term_d2 '"changed a.sh, ran the tests, green"')"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    out="$output"

    line="$(worker_done_line "$out")"
    [ -n "$line" ]
    run jq -e '.handoff == false' <<<"$line"
    [ "$status" -eq 0 ]
    run jq -e 'has("relay_with") | not' <<<"$line"
    [ "$status" -eq 0 ]

    notes="$(orca_stub_calls 'bd update')"
    run bash -c "printf '%s\n' \"\$1\" | grep -q -e 'HANDOFF-AT '" _ "$notes"
    [ "$status" -ne 0 ]
}

@test "a body line 'no HANDOFF needed here' is not a handoff" {
    record d3 "$(jq -n -c --argjson s "$((NOW - 100))" \
        '{bead:"b1", dispatch_id:"d3", task_id:"t1", terminal:"term_d3",
          state:"running", started_at:$s, worktree_path:""}')"
    orca_stub_reply_nth orchestration-check 1 \
        "$(worker_done_msg d3 term_d3 '"no HANDOFF needed here"')"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    out="$output"

    line="$(worker_done_line "$out")"
    [ -n "$line" ]
    run jq -e '.handoff == false' <<<"$line"
    [ "$status" -eq 0 ]
}

@test "orch_spec folds the last of two HANDOFF-AT notes in before WORKER RULES" {
    # shellcheck source=../scripts/lib/orca-orch.sh
    . "$REPO_ROOT/scripts/lib/orca-orch.sh"
    notes='HANDOFF-AT 2026-09-23T01:00:00Z dispatch=d1
done: first pass
left: more
facts: a.sh:1
next: first-next-line
relay: this agent is finished -- start a fresh one from this block; never message or resume it.
ORCA WORKER_DONE outcome=succeeded task=t2 dispatch=d2 files=a.sh
worker two report
HANDOFF-AT 2026-09-23T02:00:00Z dispatch=d2
done: second pass
left: less
facts: b.sh:2
next: second-next-line
relay: this agent is finished -- start a fresh one from this block; never message or resume it.'
    bj="$(jq -n --arg n "$notes" \
        '{title:"probe", description:"d", acceptance_criteria:"CHECK: true", notes:$n}')"
    spec="$(orch_spec "$bj" b1)"

    count="$(printf '%s\n' "$spec" | grep -c -e 'CONTINUE FROM HANDOFF')"
    [ "$count" = "1" ]
    printf '%s\n' "$spec" | grep -q -e 'next: second-next-line'
    run bash -c "printf '%s\n' \"\$1\" | grep -q -e 'next: first-next-line'" _ "$spec"
    [ "$status" -ne 0 ]

    before="$(printf '%s\n' "$spec" | grep -n -e 'CONTINUE FROM HANDOFF' | head -1 | cut -d: -f1)"
    after="$(printf '%s\n' "$spec" | grep -n -e 'WORKER RULES' | head -1 | cut -d: -f1)"
    [ -n "$before" ]
    [ -n "$after" ]
    [ "$before" -lt "$after" ]
}

@test "orch_spec without HANDOFF-AT is byte-identical to the same bead without notes" {
    # shellcheck source=../scripts/lib/orca-orch.sh
    . "$REPO_ROOT/scripts/lib/orca-orch.sh"
    bj_plain='{"title":"probe","description":"d","acceptance_criteria":"CHECK: true"}'
    bj_notes='{"title":"probe","description":"d","acceptance_criteria":"CHECK: true","notes":"ORCA WORKER_DONE outcome=succeeded task=t1 dispatch=d1 files=a.sh\nno handoff here"}'

    spec_plain="$(orch_spec "$bj_plain" b1)"
    spec_notes="$(orch_spec "$bj_notes" b1)"
    [ "$spec_plain" = "$spec_notes" ]
}

@test "stall scan on a closed bead releases the worker and closes its terminal before marking the record done" {
    printf '%s\n' '{"id":"b1","title":"probe slice","status":"closed",
                    "description":"d","acceptance_criteria":"CHECK: true"}' \
        >"$ORCA_STUB_DIR/bead.json"
    record c1 "$(jq -n -c --argjson s "$((NOW - 7200))" \
        '{bead:"b1", dispatch_id:"c1", task_id:"t1", terminal:"term_c1",
          state:"ready", started_at:$s, worktree_path:""}')"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]

    calls="$(orca_stub_calls 'worker-release')"
    [ -n "$calls" ]
    closes="$(orca_stub_calls 'terminal close')"
    [ -n "$closes" ]
    printf '%s\n' "$closes" | grep -q -e '--terminal term_c1'

    run jq -e '.reaped == true and .state == "done"' "$ODIR/dispatch/c1.json"
    [ "$status" -eq 0 ]
}

@test "a first stall neither releases nor closes a terminal" {
    record e1 "$(jq -n -c --argjson s "$((NOW - 1000))" \
        '{bead:"b1", dispatch_id:"e1", task_id:"t1", terminal:"term_e1",
          state:"running", started_at:$s, worktree_path:""}')"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]

    [ -z "$(orca_stub_calls 'worker-release')" ]
    [ -z "$(orca_stub_calls 'terminal close')" ]
}

@test "a second stall of a headless record releases and closes before the fallback receipt" {
    wt="$BATS_TEST_TMPDIR/wt-headless"
    orca_stub_git_fixture "$wt" "2020-01-01T00:00:00 +0000"
    record f1 "$(jq -n -c --argjson s "$((NOW - 1000))" \
        --argjson n "$((NOW - 500))" --arg wt "$wt" \
        '{bead:"b1", dispatch_id:"f1", task_id:"t1", terminal:"term_f1",
          state:"running", started_at:$s, nudged_at:$n, worktree_path:$wt,
          model:"sonnet", mode:"headless"}')"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    out="$output"

    calls="$(orca_stub_calls 'worker-release')"
    [ -n "$calls" ]
    closes="$(orca_stub_calls 'terminal close')"
    [ -n "$closes" ]
    printf '%s\n' "$closes" | grep -q -e '--terminal term_f1'

    line="$(stalled_line "$out")"
    [ -n "$line" ]
    run jq -e '.fallback | test("SUBAGENT FALLBACK")' <<<"$line"
    [ "$status" -eq 0 ]

    run jq -e '.reaped == true' "$ODIR/dispatch/f1.json"
    [ "$status" -eq 0 ]
}

@test "10 a HANDOFF block whose left: value is 'None.' is not a handoff" {
    body=$'HANDOFF\ndone: read the files\nleft: None.\nfacts: f.sh:1\nnext:\nrelay: this agent is finished -- start a fresh one from this block; never message or resume it.'
    record d10 "$(jq -n -c --argjson s "$((NOW - 100))" \
        '{bead:"b1", dispatch_id:"d10", task_id:"t1", terminal:"term_d10",
          state:"running", started_at:$s, worktree_path:""}')"
    orca_stub_reply_nth orchestration-check 1 \
        "$(worker_done_msg d10 term_d10 "$(jq -n --arg b "$body" '$b')")"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    out="$output"

    line="$(worker_done_line "$out")"
    [ -n "$line" ]
    run jq -e '.handoff == false' <<<"$line"
    [ "$status" -eq 0 ]
    run jq -e 'has("relay_with") | not' <<<"$line"
    [ "$status" -eq 0 ]

    run jq -e '.handoff == true' "$ODIR/dispatch/d10.json"
    [ "$status" -ne 0 ]

    notes="$(orca_stub_calls 'bd update')"
    run bash -c "printf '%s\n' \"\$1\" | grep -q -e 'HANDOFF-AT '" _ "$notes"
    [ "$status" -ne 0 ]
}

@test "11 a HANDOFF block whose left: value is '  -  ' is not a handoff either" {
    body=$'HANDOFF\ndone: read the files\nleft:   -  \nfacts: f.sh:1\nnext:\nrelay: this agent is finished -- start a fresh one from this block; never message or resume it.'
    record d11 "$(jq -n -c --argjson s "$((NOW - 100))" \
        '{bead:"b1", dispatch_id:"d11", task_id:"t1", terminal:"term_d11",
          state:"running", started_at:$s, worktree_path:""}')"
    orca_stub_reply_nth orchestration-check 1 \
        "$(worker_done_msg d11 term_d11 "$(jq -n --arg b "$body" '$b')")"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    out="$output"

    line="$(worker_done_line "$out")"
    [ -n "$line" ]
    run jq -e '.handoff == false' <<<"$line"
    [ "$status" -eq 0 ]
    run jq -e 'has("relay_with") | not' <<<"$line"
    [ "$status" -eq 0 ]

    notes="$(orca_stub_calls 'bd update')"
    run bash -c "printf '%s\n' \"\$1\" | grep -q -e 'HANDOFF-AT '" _ "$notes"
    [ "$status" -ne 0 ]
}

@test "--keep on a second stall releases nothing and closes no terminal" {
    wt="$BATS_TEST_TMPDIR/wt-keep"
    orca_stub_git_fixture "$wt" "2020-01-01T00:00:00 +0000"
    record g1 "$(jq -n -c --argjson s "$((NOW - 1000))" \
        --argjson n "$((NOW - 500))" --arg wt "$wt" \
        '{bead:"b1", dispatch_id:"g1", task_id:"t1", terminal:"term_g1",
          state:"running", started_at:$s, nudged_at:$n, worktree_path:$wt,
          model:"sonnet"}')"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60 --keep
    [ "$status" -eq 0 ]

    [ -z "$(orca_stub_calls 'worker-release')" ]
    [ -z "$(orca_stub_calls 'terminal close')" ]
}
