#!/usr/bin/env bats
#
# orca-wait's split into a detached spooler and a cheap reader
# (claude-orca-n3e). The orchestrator must not run the mailbox poll loop in
# its own turns: `orca-wait --spool` (started once per Run by orca-dispatch)
# runs the old loop detached and appends every receipt to
# run/orchestration/inbox.jsonl; bare `orca-wait` is a cheap file reader of
# the unread lines (cursor in inbox.cursor); `orca-wait --until <n>` blocks
# at most n seconds for the inbox to grow, on the file, not on Orca.
#
# FROZEN from RED-AT onward. Nothing here touches a real Orca runtime: the
# CLI is the stub in tests/helpers/orca-stub.bash, which replays canned JSON
# per subcommand and logs every argv.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
WAIT="$REPO_ROOT/scripts/orca-wait.sh"
DISPATCH="$REPO_ROOT/scripts/orca-dispatch.sh"

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
        '{"ok":true,"result":{"state":"released"}}'
    # what orch_ensure_run / orca-dispatch's Task step need from the stub
    orca_stub_reply orchestration-run-create \
        '{"ok":true,"result":{"run":{"id":"run_x","coordinator_handle":"term_coord"}}}'
    orca_stub_reply orchestration-task-create \
        '{"ok":true,"result":{"task":{"id":"task_x"}}}'
    NOW="$(date +%s)"
    INBOX="$ODIR/inbox.jsonl"
    CURSOR="$ODIR/inbox.cursor"
    SPOOL_PID="$ODIR/spool.pid"
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

@test "spooler: one worker_done is appended to the inbox and the record marked done while no reader runs, then the spooler exits once no record is live" {
    export CLAUDE_ORCA_SPOOL_IDLE_S=1
    record s1 "$(jq -n -c --argjson s "$((NOW - 10))" \
        '{bead:"b1", dispatch_id:"s1", task_id:"t1", terminal:"term_s1",
          state:"running", started_at:$s, worktree_path:""}')"
    orca_stub_reply_nth orchestration-check 1 "$(worker_done_msg s1 term_s1)"

    run "$WAIT" --spool --poll 1 --stall-after 60
    [ "$status" -eq 0 ]

    # exactly one receipt line in the inbox, no reader involved
    [ -f "$INBOX" ]
    [ "$(wc -l <"$INBOX" | tr -d ' ')" = "1" ]
    run jq -e '.type == "worker_done" and .dispatch_id == "s1"
              and .outcome == "succeeded" and .bead == "b1"' "$INBOX"
    [ "$status" -eq 0 ]

    # the spooler did the release and the record bookkeeping itself
    run jq -e '.state == "done" and .outcome == "succeeded" and .released == true' \
        "$ODIR/dispatch/s1.json"
    [ "$status" -eq 0 ]
    printf '%s\n' "$(orca_stub_calls 'check --ack')" | grep -q 'del1'

    # and it exited once no dispatch record was live any more
    [ -z "$(orca_stub_calls 'terminal send')" ]
}

@test "reader: bare orca-wait prints the unread inbox lines once and nothing the second time, advancing the cursor, without ever calling the CLI" {
    printf '%s\n' '{"type":"worker_done","msg_id":"m1","bead":"b1"}' \
                  '{"type":"question","msg_id":"m2","bead":"b2"}' \
        >"$INBOX"
    # the reader is a file read: no Run binding, no runtime needed
    rm -f "$ODIR/run.json"

    run "$WAIT" --timeout-ms 1
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '"type":"worker_done"')" = "1" ]
    [ "$(printf '%s\n' "$output" | grep -c '"type":"question"')" = "1" ]

    run "$WAIT" --timeout-ms 1
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    [ "$(cat "$CURSOR")" = "$(wc -c <"$INBOX" | tr -d ' ')" ]
    [ -z "$(cat "$ORCA_STUB_LOG")" ]
}

@test "--until returns within ~1s of a line arriving, and after the full n seconds with a distinct exit code when nothing does" {
    ( sleep 0.3
      printf '%s\n' '{"type":"worker_done","msg_id":"m9","bead":"b1"}' >>"$INBOX" ) &

    start="$(date +%s)"
    run "$WAIT" --until 5
    elapsed=$(( $(date +%s) - start ))
    [ "$status" -eq 0 ]
    [ "$elapsed" -le 2 ]
    printf '%s\n' "$output" | grep -q '"msg_id":"m9"'

    start="$(date +%s)"
    run "$WAIT" --until 2
    elapsed=$(( $(date +%s) - start ))
    [ "$status" -eq 4 ]
    [ "$elapsed" -ge 2 ]
    [ -z "$output" ]
}

@test "orca-dispatch starts exactly one spooler per Run: a live pid in spool.pid means no second start" {
    export CLAUDE_ORCA_DISPATCH_STAGGER_MS=0
    shim="$BATS_TEST_TMPDIR/spool-shim"
    printf '#!/usr/bin/env bash\nprintf '"'"'started %%s\n'"'"' "$*" >>"%s"\n' \
        "$BATS_TEST_TMPDIR/spool-starts" >"$shim"
    chmod +x "$shim"
    export CLAUDE_ORCA_SPOOL_CMD="$shim"

    orca_stub_reply orchestration-worker-start \
        '{"ok":true,"result":{"dispatchId":"ctx_d1","state":"dispatched",
          "effects":[{"kind":"terminal","id":"term_d1"}],
          "launch":{"effective":{"agent":"claude","model":"sonnet"}}}}'

    run --separate-stderr "$DISPATCH" b1 --agent claude --model sonnet \
        --worktree "path:$CLAUDE_ORCA_ROOT"
    [ "$status" -eq 0 ]
    [ -f "$SPOOL_PID" ]
    [ "$(wc -l <"$BATS_TEST_TMPDIR/spool-starts" | tr -d ' ')" = "1" ]

    # a live spooler: the second dispatch must not start another one
    sleep 30 & keeper=$!
    printf '%s\n' "$keeper" >"$SPOOL_PID"
    run --separate-stderr "$DISPATCH" b1 --agent claude --model sonnet \
        --worktree "path:$CLAUDE_ORCA_ROOT"
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$BATS_TEST_TMPDIR/spool-starts" | tr -d ' ')" = "1" ]
    kill "$keeper" 2>/dev/null || true
}