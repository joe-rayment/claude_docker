#!/usr/bin/env bats
#
# orca-wait vs a 'retained' worker-release (claude-orca-ar8): Orca's
# worker-release can answer with a state that is not terminal (e.g.
# "retained") and leave the finished opencode worker resident at ~1 GB, so
# orca-wait closes the dispatch record's terminal itself when it sees one.
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
    orca_stub_reply worker-release \
        '{"ok":true,"result":{"state":"retained"}}'
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

@test "a retained worker-release makes orca-wait close the worker's terminal, released=true and terminal_closed=true" {
    record x1 "$(jq -n -c --argjson s "$((NOW - 100))" \
        '{bead:"b1", dispatch_id:"x1", task_id:"t1", terminal:"term_x1",
          state:"running", started_at:$s, worktree_path:""}')"
    orca_stub_reply_nth orchestration-check 1 "$(worker_done_msg x1 term_x1)"

    run "$WAIT" --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    out="$output"

    # the terminal was closed for the dispatch record's terminal
    calls="$(orca_stub_calls 'terminal close')"
    [ -n "$calls" ]
    printf '%s\n' "$calls" | grep -q -e '--terminal term_x1'

    # the note names the retained state and the close
    printf '%s\n' "$out" | grep -q "closed term_x1 (worker-release left it retained)"

    run jq -e '.state == "done" and .outcome == "succeeded" and
              .released == true and .terminal_closed == true' \
        "$ODIR/dispatch/x1.json"
    [ "$status" -eq 0 ]
}

@test "with --keep a retained worker-release closes nothing: terminal_closed=false, released=false" {
    record x2 "$(jq -n -c --argjson s "$((NOW - 100))" \
        '{bead:"b1", dispatch_id:"x2", task_id:"t1", terminal:"term_x2",
          state:"running", started_at:$s, worktree_path:""}')"
    orca_stub_reply_nth orchestration-check 1 "$(worker_done_msg x2 term_x2)"

    run "$WAIT" --timeout-ms 1 --poll 1 --stall-after 60 --keep
    [ "$status" -eq 0 ]

    [ -z "$(orca_stub_calls 'terminal close')" ]
    [ -z "$(orca_stub_calls 'worker-release')" ]
    run jq -e '.state == "done" and .released == false and
              .terminal_closed == false' "$ODIR/dispatch/x2.json"
    [ "$status" -eq 0 ]
}

@test "a terminal release state (released) closes nothing: released=true, terminal_closed=false" {
    orca_stub_reply worker-release \
        '{"ok":true,"result":{"state":"released"}}'
    record x3 "$(jq -n -c --argjson s "$((NOW - 100))" \
        '{bead:"b1", dispatch_id:"x3", task_id:"t1", terminal:"term_x3",
          state:"running", started_at:$s, worktree_path:""}')"
    orca_stub_reply_nth orchestration-check 1 "$(worker_done_msg x3 term_x3)"

    run "$WAIT" --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    out="$output"

    [ -z "$(orca_stub_calls 'terminal close')" ]
    printf '%s\n' "$out" | grep -q "released x3 (released)"
    run jq -e '.state == "done" and .released == true and
              .terminal_closed == false' "$ODIR/dispatch/x3.json"
    [ "$status" -eq 0 ]
}
