#!/usr/bin/env bats
#
# orca-worker-run (claude-orca-kbu): the headless opencode worker. Nothing
# here touches a real runtime -- opencode, the Orca CLI and cost-mirror are
# stubs on PATH; the worktree is a real git repo, so the changed-files
# report is a real `git diff --name-only`.
#
# The opencode stub asserts its own argv (run, -m <model>, --dir <dir>,
# --format json), prints a canned json event stream (a "text" part reading
# "did the thing", an event that echoes the guard token, one usage event
# the receipt jq can read), writes and commits made-by-worker.txt in the
# --dir, sleeps $STUB_SLEEP seconds and exits $STUB_EXIT.
#
# FROZEN from RED-AT onward.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
WORKER_RUN="$REPO_ROOT/scripts/orca-worker-run.sh"

setup() {
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin"
    export ORCA_STUB_LOG="$T/orca-calls.log"
    export CM_LOG="$T/cost-mirror.log"
    export STUB_LOG="$T/opencode-stub.log"
    : >"$ORCA_STUB_LOG"; : >"$CM_LOG"; : >"$STUB_LOG"
    export STUB_SLEEP="${STUB_SLEEP:-0}"
    export STUB_EXIT="${STUB_EXIT:-0}"
    export STUB_MODEL="openrouter/zai/glm-4.5-air"
    export CLAUDE_ORCA_WORKER_DISPATCH_WAIT_S=1

    # opencode: asserts argv, prints the event stream, commits a file.
    cat >"$T/bin/opencode" <<'STUB'
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
printf 'argv_ok=%s model=%s dir=%s fmt=%s\n' "$ok" "$model" "$dir" "$fmt" >>"$STUB_LOG"
[ "$ok" = 1 ] || exit 91
printf '%s\n' '{"type":"step-start","parts":[]}'
printf '%s\n' '{"type":"text","text":"did the thing"}'
printf '%s\n' "{\"env\":\"guard token $OPENROUTER_API_KEY in play\"}"
printf '%s\n' '{"usage":{"inputTokens":1234,"outputTokens":567,"cost":0.0123}}'
printf 'made by the worker\n' >"$dir/made-by-worker.txt"
git -C "$dir" add -A
git -C "$dir" commit -qm "worker: add made-by-worker.txt"
sleep "$STUB_SLEEP"
exit "$STUB_EXIT"
STUB
    chmod +x "$T/bin/opencode"

    # The Orca CLI: logs argv, answers ok.
    cat >"$T/bin/orca-ide" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ORCA_STUB_LOG"
printf '{"ok":true}\n'
STUB
    chmod +x "$T/bin/orca-ide"

    # cost-mirror: records argv, succeeds.
    cat >"$T/bin/cost-mirror" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CM_LOG"
STUB
    chmod +x "$T/bin/cost-mirror"

    PATH="$T/bin:$PATH"
    export PATH

    # A real git repo as the worktree, one commit on HEAD.
    WT="$T/worktree"
    export STUB_DIR="$WT"
    git init -q "$WT"
    git -C "$WT" config user.email t@t
    git -C "$WT" config user.name t
    printf 'base\n' >"$WT/README.md"
    git -C "$WT" add -A
    git -C "$WT" commit -qm init

    # The run dir: guard env (with a secret token), dispatch dir, spec.
    RUN_DIR="$T/run"
    mkdir -p "$RUN_DIR/orchestration/dispatch"
    printf "OPENROUTER_API_KEY='tok_supersecret123'\nOPENROUTER_BASE_URL='http://127.0.0.1:4141/api/v1'\nOPENCODE_CONFIG='%s/opencode-launch/model.json'\n" "$RUN_DIR" \
        >"$RUN_DIR/openrouter-guard.env"
    chmod 600 "$RUN_DIR/openrouter-guard.env"
    printf 'do the slice\n' >"$T/spec.txt"
    export RUN_DIR
    TASK="task_kbu1"
}

# write_dispatch -- one dispatch record, the way orca-dispatch writes it
# right after `orchestration dispatch`.
write_dispatch() {
    printf '{"task_id":"%s","dispatch_id":"ctx_disp9"}\n' "$TASK" \
        >"$RUN_DIR/orchestration/dispatch/ctx_disp9.json"
}

# done_line -- the last worker_done argv the Orca CLI stub recorded.
done_line() {
    grep 'worker_done' "$ORCA_STUB_LOG" | tail -1
}

@test "worker-run sends worker_done succeeded with the task id, the dispatch id read from the dispatch record, and the committed file in --files-modified" {
    write_dispatch
    run "$WORKER_RUN" --task "$TASK" --spec "$T/spec.txt" \
        --model "$STUB_MODEL" --dir "$WT" --run-dir "$RUN_DIR" \
        --bead claude-orca-kbu
    [ "$status" -eq 0 ]
    grep -q 'argv_ok=1' "$STUB_LOG"
    local line
    line="$(done_line)"
    [ -n "$line" ]
    [[ "$line" == *"--type worker_done"* ]]
    [[ "$line" == *"--task-id $TASK"* ]]
    [[ "$line" == *"--dispatch-id ctx_disp9"* ]]
    [[ "$line" == *"--outcome succeeded"* ]]
    [[ "$line" == *"--files-modified made-by-worker.txt"* ]]
    [[ "$line" == *"did the thing"* ]]
    [[ "$line" == *"claude-orca-kbu done"* ]]
}

@test "worker-run reports failed when opencode exits non-zero and still sends worker_done" {
    write_dispatch
    export STUB_EXIT=3
    run "$WORKER_RUN" --task "$TASK" --spec "$T/spec.txt" \
        --model "$STUB_MODEL" --dir "$WT" --run-dir "$RUN_DIR"
    [ "$status" -eq 3 ]
    local line
    line="$(done_line)"
    [[ "$line" == *"--task-id $TASK"* ]]
    [[ "$line" == *"--outcome failed"* ]]
}

@test "worker-run writes a receipt with tokens, usd and the exit code and hands it to cost-mirror" {
    write_dispatch
    run "$WORKER_RUN" --task "$TASK" --spec "$T/spec.txt" \
        --model "$STUB_MODEL" --dir "$WT" --run-dir "$RUN_DIR" \
        --bead claude-orca-kbu
    [ "$status" -eq 0 ]
    local r="$RUN_DIR/orchestration/workers/$TASK.receipt.json"
    [ -f "$r" ]
    run jq -e --arg t "$TASK" '
        .task_id == $t and .dispatch_id == "ctx_disp9"
        and .bead == "claude-orca-kbu" and .exit_code == 0
        and .tokens_in == 1234 and .tokens_out == 567 and .usd == 0.0123
        and .model == "openrouter/zai/glm-4.5-air"
        and (.wall_seconds | type == "number")
        and (.started_at | type == "string")
        and (.finished_at | type == "string")' "$r"
    [ "$status" -eq 0 ]
    grep -qF -- "--ingest-delegate-receipt $r" "$CM_LOG"
}

@test "worker-run sends at least one heartbeat during a long run" {
    write_dispatch
    export STUB_SLEEP=3
    run "$WORKER_RUN" --task "$TASK" --spec "$T/spec.txt" \
        --model "$STUB_MODEL" --dir "$WT" --run-dir "$RUN_DIR" \
        --heartbeat-s 1
    [ "$status" -eq 0 ]
    [ "$(grep -c -- '--type heartbeat' "$ORCA_STUB_LOG" || true)" -ge 1 ]
}

@test "worker-run proceeds with an empty dispatch id when no record appears" {
    run "$WORKER_RUN" --task "$TASK" --spec "$T/spec.txt" \
        --model "$STUB_MODEL" --dir "$WT" --run-dir "$RUN_DIR"
    [ "$status" -eq 0 ]
    local line
    line="$(done_line)"
    [[ "$line" == *"--task-id $TASK"* ]]
    [[ "$line" != *"--dispatch-id"* ]]
    [ -z "$(grep -- '--type heartbeat' "$ORCA_STUB_LOG" || true)" ]
}

@test "worker-run exits 2 with one stderr line when the guard env file is missing" {
    rm -f "$RUN_DIR/openrouter-guard.env"
    run --separate-stderr "$WORKER_RUN" --task "$TASK" --spec "$T/spec.txt" \
        --model "$STUB_MODEL" --dir "$WT" --run-dir "$RUN_DIR"
    [ "$status" -eq 2 ]
    [ "${#stderr_lines[@]}" -eq 1 ]
}

@test "worker-run redacts the guard token from the log and the receipt" {
    write_dispatch
    run "$WORKER_RUN" --task "$TASK" --spec "$T/spec.txt" \
        --model "$STUB_MODEL" --dir "$WT" --run-dir "$RUN_DIR"
    [ "$status" -eq 0 ]
    local log="$RUN_DIR/orchestration/workers/$TASK.log"
    [ -f "$log" ]
    grep -qF '***REDACTED***' "$log"
    run grep -qF 'tok_supersecret123' "$log"
    [ "$status" -ne 0 ]
    run grep -qF 'tok_supersecret123' "$RUN_DIR/orchestration/workers/$TASK.receipt.json"
    [ "$status" -ne 0 ]
}