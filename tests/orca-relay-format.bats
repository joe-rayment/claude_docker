#!/usr/bin/env bats
#
# claude-orca-7lz.8: detect_handoff (scripts/orca-wait.sh) reads the HANDOFF
# blocks real models actually write -- bold markers, "## HANDOFF", a
# trailing colon, and a left: line whose value sits on the following lines
# as a list -- instead of only the exact "HANDOFF" line and a same-line
# left: value that today's rule expects.
#
# FROZEN from RED-AT onward. Exercises the real path: a worker_done message
# through $WAIT --poll-loop, asserting the receipt's .handoff and the
# HANDOFF-AT note, with the stub harness tests/orca-relay.bats uses
# (tests/helpers/orca-stub.bash). Scripts are pinned by absolute path,
# never picked up off PATH.

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

worker_done_line() {
    printf '%s\n' "$1" | grep -e '"type":"worker_done"' | head -1
}

# run_case <disp> <body> -- runs the poll loop once for <body> and leaves
# $line (the worker_done receipt) and $notes (the bd update argv log) set.
run_case() {
    local disp="$1" body="$2"
    record "$disp" "$(jq -n -c --argjson s "$((NOW - 100))" \
        '{bead:"b1", dispatch_id:$d, task_id:"t1", terminal:$t,
          state:"running", started_at:$s, worktree_path:""}' \
        --arg d "$disp" --arg t "term_$disp")"
    orca_stub_reply_nth orchestration-check 1 \
        "$(worker_done_msg "$disp" "term_$disp" "$(jq -n --arg b "$body" '$b')")"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    line="$(worker_done_line "$output")"
    [ -n "$line" ]
    notes="$(orca_stub_calls 'bd update')"
}

@test "1 bold **HANDOFF** with a bold left: on its own line is a handoff, note carries the original bold line" {
    body=$'**HANDOFF**\n**left:** read scripts/recon.sh'
    run_case d1 "$body"

    run jq -e '.handoff == true' <<<"$line"
    [ "$status" -eq 0 ]

    run bash -c "printf '%s\n' \"\$1\" | grep -q -e '\*\*HANDOFF\*\*'" _ "$notes"
    [ "$status" -eq 0 ]
}

@test "2 a heading '## HANDOFF' is a handoff" {
    body=$'## HANDOFF\nleft: read scripts/recon.sh'
    run_case d2 "$body"

    run jq -e '.handoff == true' <<<"$line"
    [ "$status" -eq 0 ]
}

@test "3 'HANDOFF:' with a trailing colon is a handoff" {
    body=$'HANDOFF:\nleft: read scripts/recon.sh'
    run_case d3 "$body"

    run jq -e '.handoff == true' <<<"$line"
    [ "$status" -eq 0 ]
}

@test "4 an empty left: whose value is a numbered list on the following lines is a handoff" {
    body=$'HANDOFF\nleft:\n1. read scripts/lib/paths.sh\n2. continue the chain\nnext: resume at paths.sh'
    run_case d4 "$body"

    run jq -e '.handoff == true' <<<"$line"
    [ "$status" -eq 0 ]
}

@test "5 an empty left: followed only by blank lines up to the next field is not a handoff" {
    body=$'HANDOFF\nleft:\n\nnext: nothing to do'
    run_case d5 "$body"

    run jq -e '.handoff == false' <<<"$line"
    [ "$status" -eq 0 ]
}

@test "6 bold '**Left:** None.' is not a handoff" {
    body=$'HANDOFF\n**Left:** None.'
    run_case d6 "$body"

    run jq -e '.handoff == false' <<<"$line"
    [ "$status" -eq 0 ]
}

@test "7 a prose line mentioning **HANDOFF** without an exact HANDOFF line is not a handoff" {
    body='we skip the **HANDOFF** step here'
    run_case d7 "$body"

    run jq -e '.handoff == false' <<<"$line"
    [ "$status" -eq 0 ]
}

@test "8 the real scout report tests/fixtures/handoff-chain-1.txt verbatim is a handoff" {
    body="$(cat "$REPO_ROOT/tests/fixtures/handoff-chain-1.txt")"
    run_case d8 "$body"

    run jq -e '.handoff == true' <<<"$line"
    [ "$status" -eq 0 ]
}

@test "9 the real scout report tests/fixtures/handoff-chain-2.txt verbatim is a handoff" {
    body="$(cat "$REPO_ROOT/tests/fixtures/handoff-chain-2.txt")"
    run_case d9 "$body"

    run jq -e '.handoff == true' <<<"$line"
    [ "$status" -eq 0 ]
}
