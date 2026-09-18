#!/usr/bin/env bats
#
# orca-dispatch's headless opencode path, orca-wait's handling of it and
# orca-worker-run's worker_done body (claude-orca-ltd). --agent opencode
# dispatches a headless orca-worker-run terminal and a context-only
# Dispatch by default; --tui keeps the old adoption path for a person who
# wants to watch. orca-wait never closes a headless terminal (it ended
# with the run) and never types a nudge into one (there is no TUI), and
# orca-worker-run sends a worker_done body without jq's surrounding JSON
# quotes.
#
# FROZEN from RED-AT onward. The runtime is the stub in
# tests/helpers/orca-stub.bash, which also stubs bd -- no real tracker and
# no real Orca. The opencode stub below is the one from
# tests/orca-worker-run.bats (claude-orca-kbu), asserting its own argv.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
DISPATCH="$REPO_ROOT/scripts/orca-dispatch.sh"
WAIT="$REPO_ROOT/scripts/orca-wait.sh"
WORKER_RUN="$REPO_ROOT/scripts/orca-worker-run.sh"
MODEL="openrouter/zai/glm-4.5-air"

setup() {
    # An Orca terminal exporting its own coordinator identity would make
    # both scripts address THAT terminal; the file has to behave as it
    # would from a clean shell (same unset as tests/orca-dispatch.bats).
    unset BEADS_DIR ORCA_TERMINAL_HANDLE ORCA_PANE_KEY ORCA_TAB_ID \
        ORCA_WORKTREE_ID ORCA_USER_DATA_PATH
    # shellcheck source=helpers/orca-stub.bash
    . "$BATS_TEST_DIRNAME/helpers/orca-stub.bash"
    orca_stub_init

    export CLAUDE_ORCA_ROOT="$BATS_TEST_TMPDIR/root"
    export TIER_STATE_FILE="$BATS_TEST_TMPDIR/no-such-tier.json"
    export CLAUDE_ORCA_DISPATCH_STAGGER_MS=0
    export CLAUDE_ORCA_WORKER_DISPATCH_WAIT_S=1
    ODIR="$CLAUDE_ORCA_ROOT/.claude-dev/run/orchestration"
    RUN_DIR="$CLAUDE_ORCA_ROOT/.claude-dev/run"
    mkdir -p "$ODIR/dispatch"
    printf '%s\n' '{"run_id":"run1","coordinator_handle":"term_coord"}' \
        >"$ODIR/run.json"

    orca_stub_reply orchestration-run-create \
        '{"ok":true,"result":{"run":{"id":"run1","coordinator_handle":"term_coord"}}}'
    orca_stub_reply orchestration-task-create \
        '{"ok":true,"result":{"task":{"id":"t1"}}}'
    orca_stub_reply terminal-create \
        '{"ok":true,"result":{"terminal":{"handle":"term_w1"}}}'
    orca_stub_reply orchestration-dispatch \
        '{"ok":true,"result":{"dispatch":{"id":"d1","status":"running"}}}'

    # orca-worker-run's opencode stub (from tests/orca-worker-run.bats):
    # asserts its argv and prints a canned json event stream whose "text"
    # part reads "did the thing".
    cat >"$ORCA_STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
model=""; dir=""; fmt=""; prev=""
for a in "$@"; do
    [ "$prev" = "-m" ] && model="$a"
    [ "$prev" = "--dir" ] && dir="$a"
    [ "$prev" = "--format" ] && fmt="$a"
    prev="$a"
done
ok=1
case " $* " in *" run "*) ;; *) ok=0 ;; esac
[ "$model" = "$STUB_MODEL" ] || ok=0
[ "$dir" = "$STUB_DIR" ] || ok=0
[ "$fmt" = "json" ] || ok=0
[ "$ok" = 1 ] || exit 91
printf '%s\n' '{"type":"step-start","parts":[]}'
printf '%s\n' '{"type":"text","text":"did the thing"}'
printf '%s\n' '{"usage":{"inputTokens":1234,"outputTokens":567,"cost":0.0123}}'
printf 'made by the worker\n' >"$dir/made-by-worker.txt"
git -C "$dir" add -A
git -C "$dir" commit -qm "worker: add made-by-worker.txt"
exit "$STUB_EXIT"
STUB
chmod +x "$ORCA_STUB_BIN/opencode"

    # A real git repo as the worktree, one commit on HEAD.
    WT="$BATS_TEST_TMPDIR/worktree"
    export STUB_DIR="$WT" STUB_MODEL="$MODEL" STUB_EXIT=0
    export STUB_LOG="$BATS_TEST_TMPDIR/opencode-stub.log"
    git init -q "$WT"
    git -C "$WT" config user.email orca@test
    git -C "$WT" config user.name orca
    printf 'base\n' >"$WT/README.md"
    git -C "$WT" add -A
    git -C "$WT" commit -qm init

    # orca-worker-run's run dir: the guard env it must source, plus the
    # spec file its --spec points at.
    printf "OPENROUTER_API_KEY='tok_supersecret123'\n" \
        >"$RUN_DIR/openrouter-guard.env"
    chmod 600 "$RUN_DIR/openrouter-guard.env"
    printf 'do the slice\n' >"$BATS_TEST_TMPDIR/spec.txt"
}

# worker_done_msg <disp> <term> -- one check --wait batch carrying a
# worker_done from that dispatch.
worker_done_msg() {
    printf '{"ok":true,"result":{"count":1,"deliveryId":"del1","messages":[
      {"type":"worker_done","id":"m1","subject":"done","from_handle":"%s",
       "payload":{"taskId":"t1","dispatchId":"%s","outcome":"succeeded",
                  "filesModified":["a.sh"]}}]}}' "$2" "$1"
}

# receipt -- the LAST stdout line (human notes go to stderr).
receipt() { printf '%s\n' "$1" | tail -1; }

@test "opencode dispatch composes a headless orca-worker-run command with the task id, spec file, model and worktree dir, and dispatches context-only (no worker-start, no tui-idle wait)" {
    run --separate-stderr "$DISPATCH" b1 --agent opencode --model "$MODEL" \
        --worktree "path:$CLAUDE_ORCA_ROOT"
    [ "$status" -eq 0 ]

    local create
    create="$(orca_stub_calls 'terminal create')"
    [ -n "$create" ]
    printf '%s\n' "$create" | grep -q -F -e "$REPO_ROOT/bin/orca-worker-run"
    printf '%s\n' "$create" | grep -q -F -e '--task t1'
    printf '%s\n' "$create" \
        | grep -q -F -e "--spec $RUN_DIR/orchestration/tasks/t1.spec.md"
    printf '%s\n' "$create" | grep -q -F -e "--model $MODEL"
    printf '%s\n' "$create" | grep -q -F -e "--dir $CLAUDE_ORCA_ROOT"
    printf '%s\n' "$create" | grep -q -F -e "--run-dir $RUN_DIR"
    printf '%s\n' "$create" | grep -q -F -e '--bead b1'
    printf '%s\n' "$create" | grep -q -F -e '--title b1 worker'

    # context-only Dispatch, exactly the bash agent's path: no adoption,
    # no TUI-idle wait
    [ -z "$(orca_stub_calls 'worker-start')" ]
    [ -z "$(orca_stub_calls 'terminal wait')" ]
    local disp
    disp="$(orca_stub_calls 'orchestration dispatch')"
    printf '%s\n' "$disp" | grep -q -F -e '--task t1 --to term_w1 --run run1'

    # the receipt line on stdout keeps its shape
    run jq -e '.bead == "b1" and .task_id == "t1" and .dispatch_id == "d1"
        and .terminal == "term_w1" and .agent == "opencode"
        and .state == "running"' <<<"$(receipt "$output")"
    [ "$status" -eq 0 ]
}

@test "the spec file exists, is mode 600 and contains the bead title" {
    run "$DISPATCH" b1 --agent opencode --model "$MODEL" \
        --worktree "path:$CLAUDE_ORCA_ROOT"
    [ "$status" -eq 0 ]
    local f="$RUN_DIR/orchestration/tasks/t1.spec.md"
    [ -f "$f" ]
    [ "$(stat -c %a "$f")" = "600" ]
    grep -q -F 'probe slice' "$f"
    grep -q -F 'WORKER RULES' "$f"
}

@test "--tui keeps the adoption path (worker-start --terminal) and records mode tui" {
    orca_stub_reply orchestration-worker-start \
        '{"ok":true,"result":{"dispatchId":"d1t","state":"running",
          "effects":[{"kind":"terminal","id":"term_t1"}],
          "worktree":{"path":"/tmp/wt-child-t1"},
          "launch":{"effective":{"agent":"opencode","model":"openrouter/zai/glm-4.5-air"}}}}'
    run --separate-stderr "$DISPATCH" b1 --agent opencode --model "$MODEL" \
        --worktree "path:$CLAUDE_ORCA_ROOT" --tui
    [ "$status" -eq 0 ]

    local ws
    ws="$(orca_stub_calls 'worker-start')"
    printf '%s\n' "$ws" | grep -q -F -e '--terminal term_w1'
    [ -z "$(orca_stub_calls 'orchestration dispatch')" ]
    printf '%s\n' "$(orca_stub_calls 'terminal wait')" \
        | grep -q -F -e 'tui-idle'

    run jq -e '.mode == "tui"' "$ODIR/dispatch/d1t.json"
    [ "$status" -eq 0 ]
}

@test "the dispatch record carries mode headless and spec_file" {
    run "$DISPATCH" b1 --agent opencode --model "$MODEL" \
        --worktree "path:$CLAUDE_ORCA_ROOT"
    [ "$status" -eq 0 ]
    run jq -e --arg sf "$RUN_DIR/orchestration/tasks/t1.spec.md" \
        '.mode == "headless" and .spec_file == $sf' "$ODIR/dispatch/d1.json"
    [ "$status" -eq 0 ]
}

@test "orca-wait skips terminal close for a headless record on worker_done" {
    orca_stub_reply orchestration-worker-release \
        '{"ok":true,"result":{"state":"retained"}}'
    orca_stub_dispatch_record "$CLAUDE_ORCA_ROOT" d1h "$(jq -n -c \
        '{bead:"b1", dispatch_id:"d1h", task_id:"t1", terminal:"term_h1",
          state:"running", mode:"headless", worktree_path:""}')"
    orca_stub_reply_nth orchestration-check 1 "$(worker_done_msg d1h term_h1)"

    run "$WAIT" --poll-loop --timeout-ms 1 --poll 1 --stall-after 60
    [ "$status" -eq 0 ]

    # a headless terminal ended with its run: worker-release runs, the
    # terminal close does not
    [ -n "$(orca_stub_calls 'worker-release')" ]
    [ -z "$(orca_stub_calls 'terminal close')" ]
    run jq -e '.state == "done" and .outcome == "succeeded"
        and .released == false and .terminal_closed == false' \
        "$ODIR/dispatch/d1h.json"
    [ "$status" -eq 0 ]
}

@test "orca-worker-run sends a worker_done body without surrounding JSON quotes" {
    printf '{"task_id":"t1","dispatch_id":"ctx_disp9"}\n' \
        >"$ODIR/dispatch/ctx_disp9.json"
    run "$WORKER_RUN" --task t1 --spec "$BATS_TEST_TMPDIR/spec.txt" \
        --model "$MODEL" --dir "$WT" --run-dir "$RUN_DIR" \
        --bead claude-orca-ltd
    [ "$status" -eq 0 ]
    local line
    line="$(grep 'worker_done' "$ORCA_STUB_LOG" | tail -1)"
    [ -n "$line" ]
    [[ "$line" == *"--task-id t1"* ]]
    [[ "$line" == *'did the thing'* ]]
    [[ "$line" != *'--body "'* ]]
}
