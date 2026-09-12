#!/usr/bin/env bats
#
# orca-wait's stall watch (claude-orca-8a0.1, slice A of claude-orca-8a0).
#
# FROZEN from RED-AT onward. Nothing here touches a real Orca runtime: the
# CLI is the stub in tests/helpers/orca-stub.bash, which replays canned JSON
# per subcommand and logs every argv, so an assertion about "it nudged the
# worker" is an assertion about the argv orca-wait actually produced.

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

# the stalled receipt, if there is one
stalled_line() {
    printf '%s\n' "$1" | grep -e '"type":"stalled"' | head -1
}

record() {
    orca_stub_dispatch_record "$CLAUDE_ORCA_ROOT" "$1" "$2"
}

@test "orca-wait reports a stalled dispatch after stall-after seconds with no heartbeat, commit or file change" {
    record d1 "$(jq -n -c --argjson s "$((NOW - 1000))" \
        '{bead:"b1", dispatch_id:"d1", task_id:"t1", terminal:"term_w1",
          state:"running", started_at:$s, worktree_path:"", model:"sonnet"}')"

    run "$WAIT" --timeout-ms 1 --poll 1 --stall-after 60 --no-nudge
    [ "$status" -eq 0 ]
    out="$output"

    line="$(stalled_line "$out")"
    [ -n "$line" ]
    run jq -e '.type == "stalled" and .bead == "b1" and .dispatch_id == "d1"' <<<"$line"
    [ "$status" -eq 0 ]
    run jq -e '.terminal == "term_w1" and (.idle_s >= 900)' <<<"$line"
    [ "$status" -eq 0 ]
    run jq -e '.nudge | test("orca terminal send --terminal term_w1")' <<<"$line"
    [ "$status" -eq 0 ]
    run jq -e '.nudge | test("--enter")' <<<"$line"
    [ "$status" -eq 0 ]

    # --no-nudge means the receipt names the nudge but nothing was sent
    calls="$(orca_stub_calls 'terminal send')"
    [ -z "$calls" ]
}

@test "orca-wait nudges a stalled worker once through its terminal and records nudged_at" {
    record d2 "$(jq -n -c --argjson s "$((NOW - 1000))" \
        '{bead:"b1", dispatch_id:"d2", task_id:"t1", terminal:"term_w2",
          state:"ready", started_at:$s, worktree_path:""}')"

    run "$WAIT" --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]

    sends="$(orca_stub_calls 'terminal send')"
    [ -n "$sends" ]
    [ "$(printf '%s\n' "$sends" | wc -l | tr -d ' ')" = "1" ]
    printf '%s\n' "$sends" | grep -q -e '--terminal term_w2'
    printf '%s\n' "$sends" | grep -q -e '--enter'
    printf '%s\n' "$sends" | grep -q -e 'heartbeat'

    rec="$ODIR/dispatch/d2.json"
    run jq -e --argjson n "$NOW" '.nudged_at >= ($n - 5)' "$rec"
    [ "$status" -eq 0 ]
}

@test "orca-wait prints the Agent-tool fallback when a nudged worker stalls again" {
    wt="$BATS_TEST_TMPDIR/wt-quiet"
    orca_stub_git_fixture "$wt" "2020-01-01T00:00:00 +0000"

    record d3 "$(jq -n -c --argjson s "$((NOW - 1000))" \
        --argjson n "$((NOW - 500))" --arg wt "$wt" \
        '{bead:"b1", dispatch_id:"d3", task_id:"t1", terminal:"term_w3",
          state:"running", started_at:$s, nudged_at:$n, worktree_path:$wt,
          model:"sonnet"}')"

    run "$WAIT" --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    out="$output"

    line="$(stalled_line "$out")"
    [ -n "$line" ]
    run jq -e '.type == "stalled" and .nudged == true' <<<"$line"
    [ "$status" -eq 0 ]
    run jq -e --arg wt "$wt" '.worktree_path == $wt' <<<"$line"
    [ "$status" -eq 0 ]
    run jq -e '.fallback | test("SUBAGENT FALLBACK")' <<<"$line"
    [ "$status" -eq 0 ]
    run jq -e '.fallback | test("WORKER RULES")' <<<"$line"
    [ "$status" -eq 0 ]

    # a worker that was already nudged is not nudged a second time
    calls="$(orca_stub_calls 'terminal send')"
    [ -z "$calls" ]
}

@test "orca-wait treats a heartbeat, a new commit or a changed file as activity" {
    # (a) a heartbeat message in the batch is activity for its dispatch
    record h1 "$(jq -n -c --argjson s "$((NOW - 1000))" \
        '{bead:"b1", dispatch_id:"h1", task_id:"t1", terminal:"term_h1",
          state:"running", started_at:$s, worktree_path:""}')"
    orca_stub_reply_nth orchestration-check 1 \
        '{"ok":true,"result":{"count":1,"deliveryId":"del1","messages":[
          {"type":"heartbeat","id":"m1","subject":"alive","from_handle":"term_h1",
           "payload":{"taskId":"t1","dispatchId":"h1"}}]}}'

    run "$WAIT" --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    out="$output"
    [ -z "$(stalled_line "$out")" ]
    # a heartbeat is a stderr note, never a receipt of its own
    ! printf '%s\n' "$out" | grep -q -e '"type":"heartbeat"'
    run jq -e --argjson n "$NOW" '.last_activity >= ($n - 5)' \
        "$ODIR/dispatch/h1.json"
    [ "$status" -eq 0 ]

    # (b) a fresh HEAD commit in the worktree is activity
    rm -f "$ODIR/dispatch/h1.json" "$ORCA_STUB_DIR"/.count.* \
        "$ORCA_STUB_DIR/orchestration-check.1.json"
    wtb="$BATS_TEST_TMPDIR/wt-commit"
    orca_stub_git_fixture "$wtb"
    record h2 "$(jq -n -c --argjson s "$((NOW - 1000))" --arg wt "$wtb" \
        '{bead:"b1", dispatch_id:"h2", task_id:"t1", terminal:"term_h2",
          state:"running", started_at:$s, worktree_path:$wt}')"
    run "$WAIT" --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    [ -z "$(stalled_line "$output")" ]

    # (c) an old HEAD but a file changed just now is activity
    rm -f "$ODIR/dispatch/h2.json" "$ORCA_STUB_DIR"/.count.*
    wtc="$BATS_TEST_TMPDIR/wt-dirty"
    orca_stub_git_fixture "$wtc" "2020-01-01T00:00:00 +0000"
    echo two >>"$wtc/file.txt"
    record h3 "$(jq -n -c --argjson s "$((NOW - 1000))" --arg wt "$wtc" \
        '{bead:"b1", dispatch_id:"h3", task_id:"t1", terminal:"term_h3",
          state:"running", started_at:$s, worktree_path:$wt}')"
    run "$WAIT" --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]
    [ -z "$(stalled_line "$output")" ]
}

@test "the worker rules tell the worker to heartbeat" {
    # shellcheck source=../scripts/lib/orca-orch.sh
    . "$REPO_ROOT/scripts/lib/orca-orch.sh"
    spec="$(orch_spec '{"title":"probe","description":"d","acceptance_criteria":"CHECK: true"}' b1)"
    printf '%s\n' "$spec" | grep -q -F -e '--type heartbeat'
    printf '%s\n' "$spec" | grep -q -F -e '--subject alive'
    printf '%s\n' "$spec" | grep -q -F -e 'every 5 minutes'
}
