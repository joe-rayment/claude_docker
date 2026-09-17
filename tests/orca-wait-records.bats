#!/usr/bin/env bats
#
# orca-wait's dispatch records (claude-orca-bvm): a finished dispatch must
# leave its record "done", a closed bead must not be nudged, and a nudged-
# again fallback must not end a wait while another dispatch is still live.
#
# FROZEN from RED-AT onward. Nothing here touches a real Orca runtime: the
# CLI is the stub in tests/helpers/orca-stub.bash, which replays canned JSON
# per subcommand and logs every argv.

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
    NOW="$(date +%s)"
}

record() {
    orca_stub_dispatch_record "$CLAUDE_ORCA_ROOT" "$1" "$2"
}

worker_done_msg() {  # <disp> <term>
    printf '{"ok":true,"result":{"count":1,"deliveryId":"del1","messages":[
      {"type":"worker_done","id":"m1","subject":"done","from_handle":"%s",
       "payload":{"taskId":"t1","dispatchId":"%s","outcome":"succeeded",
                  "filesModified":["a.sh"]}}]}}' "$2" "$1"
}

@test "a worker_done marks its dispatch record done with the outcome, finished_at and released=true" {
    record x1 "$(jq -n -c --argjson s "$((NOW - 100))" \
        '{bead:"b1", dispatch_id:"x1", task_id:"t1", terminal:"term_x1",
          state:"running", started_at:$s, worktree_path:""}')"
    orca_stub_reply_nth orchestration-check 1 "$(worker_done_msg x1 term_x1)"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]

    run jq -e '.state == "done" and .outcome == "succeeded"' \
        "$ODIR/dispatch/x1.json"
    [ "$status" -eq 0 ]
    run jq -e --argjson n "$NOW" '.finished_at >= ($n - 5) and .released == true' \
        "$ODIR/dispatch/x1.json"
    [ "$status" -eq 0 ]
}

@test "a --keep wait marks the record done with released=false and does not release" {
    record x2 "$(jq -n -c --argjson s "$((NOW - 100))" \
        '{bead:"b1", dispatch_id:"x2", task_id:"t1", terminal:"term_x2",
          state:"running", started_at:$s, worktree_path:""}')"
    orca_stub_reply_nth orchestration-check 1 "$(worker_done_msg x2 term_x2)"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60 --keep
    [ "$status" -eq 0 ]

    run jq -e '.state == "done" and .released == false' \
        "$ODIR/dispatch/x2.json"
    [ "$status" -eq 0 ]
    [ -z "$(orca_stub_calls 'worker-release')" ]
}

@test "a nudged-again dispatch is marked stalled and the wait goes on while another dispatch is live" {
    # y: quiet for 2h and already nudged once -- the next scan is the
    # nudged-again fallback.  z: fresh, still working.
    record y1 "$(jq -n -c --argjson s "$((NOW - 7200))" --argjson n "$((NOW - 7200))" \
        '{bead:"b1", dispatch_id:"y1", task_id:"t1", terminal:"term_y1",
          state:"ready", started_at:$s, nudged_at:$n, worktree_path:""}')"
    record z1 "$(jq -n -c --argjson s "$((NOW - 10))" \
        '{bead:"b1", dispatch_id:"z1", task_id:"t1", terminal:"term_z1",
          state:"ready", started_at:$s, worktree_path:""}')"

    run "$WAIT" --poll-loop --timeout-ms 2000 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    out="$output"

    # exactly one fallback line, for y1, and then the timeout, not an exit
    lines="$(printf '%s\n' "$out" | grep -c '"type":"stalled"' || true)"
    [ "$lines" = "1" ]
    line="$(printf '%s\n' "$out" | grep '"type":"stalled"' | head -1)"
    run jq -e '.dispatch_id == "y1" and .nudged == true' <<<"$line"
    [ "$status" -eq 0 ]
    printf '%s\n' "$out" | grep -q -e '"type":"timeout"'

    run jq -e '.state == "stalled"' "$ODIR/dispatch/y1.json"
    [ "$status" -eq 0 ]
    run jq -e '.state == "ready"' "$ODIR/dispatch/z1.json"
    [ "$status" -eq 0 ]

    # a worker that was already nudged is not nudged a second time
    [ -z "$(orca_stub_calls 'terminal send')" ]
}

@test "the nudged-again fallback still ends the wait when no other dispatch is live" {
    wt="$BATS_TEST_TMPDIR/wt-quiet"
    orca_stub_git_fixture "$wt" "2020-01-01T00:00:00 +0000"
    record y2 "$(jq -n -c --argjson s "$((NOW - 7200))" --argjson n "$((NOW - 7200))" --arg wt "$wt" \
        '{bead:"b1", dispatch_id:"y2", task_id:"t1", terminal:"term_y2",
          state:"running", started_at:$s, nudged_at:$n, worktree_path:$wt,
          model:"sonnet"}')"

    run "$WAIT" --poll-loop --timeout-ms 5000 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    out="$output"

    line="$(printf '%s\n' "$out" | grep '"type":"stalled"' | head -1)"
    [ -n "$line" ]
    run jq -e '.dispatch_id == "y2" and .nudged == true' <<<"$line"
    [ "$status" -eq 0 ]
    ! printf '%s\n' "$out" | grep -q -e '"type":"timeout"'
}

@test "a dispatch whose bead is closed is marked done and never nudged" {
    printf '%s\n' '{"id":"b1","title":"probe slice","status":"closed",
                    "description":"d","acceptance_criteria":"CHECK: true"}' \
        >"$ORCA_STUB_DIR/bead.json"
    record c1 "$(jq -n -c --argjson s "$((NOW - 7200))" \
        '{bead:"b1", dispatch_id:"c1", task_id:"t1", terminal:"term_c1",
          state:"ready", started_at:$s, worktree_path:""}')"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    wait_out="$output"

    # never nudged: the record is marked done on sight of the closed bead
    [ -z "$(orca_stub_calls 'terminal send')" ]
    run jq -e '.state == "done" and (.finished_at // 0) > 0' \
        "$ODIR/dispatch/c1.json"
    [ "$status" -eq 0 ]
    printf '%s\n' "$wait_out" | grep -q "bead is closed -- marking the dispatch done"
}

@test "a failed bd lookup leaves a record alone" {
    rm -f "$ORCA_STUB_DIR/bead.json"
    record c2 "$(jq -n -c --argjson s "$((NOW - 7200))" \
        '{bead:"bx", dispatch_id:"c2", task_id:"t1", terminal:"term_c2",
          state:"ready", started_at:$s, worktree_path:""}')"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60 --no-nudge
    [ "$status" -eq 0 ]

    run jq -e '.state == "ready"' "$ODIR/dispatch/c2.json"
    [ "$status" -eq 0 ]
}
