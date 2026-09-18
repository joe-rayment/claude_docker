#!/usr/bin/env bats
#
# orca-worker-run against a REAL opencode --format json stream
# (claude-orca-pld). The frozen tests/orca-worker-run.bats stub prints a
# canned event shape; the live probe (task_e72f28763358, 2026-09-18) showed
# the real one: {"type":"step_start"|"tool_use"|"step_finish"|"text",
# "timestamp":<ms>,"sessionID":...,"part":{...}}, tokens and cost inside
# step_finish part.tokens/part.cost, assistant text in text part.text.
#
# The stub opencode here cats tests/fixtures/opencode-run-real.jsonl --
# the real 33 KB log from the live probe, no secrets in it.
#
# FROZEN from RED-AT onward.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
WORKER_RUN="$REPO_ROOT/scripts/orca-worker-run.sh"
FIXTURE="$REPO_ROOT/tests/fixtures/opencode-run-real.jsonl"

setup() {
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin"
    export ORCA_STUB_LOG="$T/orca-calls.log"
    export CM_LOG="$T/cost-mirror.log"
    export STUB_LOG="$T/opencode-stub.log"
    : >"$ORCA_STUB_LOG"; : >"$CM_LOG"; : >"$STUB_LOG"
    export STUB_MODEL="openrouter/zai/glm-4.5-air"
    export CLAUDE_ORCA_WORKER_DISPATCH_WAIT_S=1
    export FIXTURE

    # opencode: prints the real stream from the fixture, commits a file.
    cat >"$T/bin/opencode" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
cat "$FIXTURE"
dir=""; prev=""
for a in "$@"; do
    [ "$prev" = "--dir" ] && dir="$a"
    prev="$a"
done
printf 'made by the worker\n' >"$dir/made-by-worker.txt"
STUB
    chmod +x "$T/bin/opencode"

    cat >"$T/bin/orca-ide" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ORCA_STUB_LOG"
printf '{"ok":true}\n'
STUB
    chmod +x "$T/bin/orca-ide"

    cat >"$T/bin/cost-mirror" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CM_LOG"
STUB
    chmod +x "$T/bin/cost-mirror"

    PATH="$T/bin:$PATH"
    export PATH

    # A real git repo as the worktree, one commit on HEAD.
    WT="$T/worktree"
    export WT
    git init -q "$WT"
    git -C "$WT" config user.email t@t
    git -C "$WT" config user.name t
    printf 'base\n' >"$WT/README.md"
    git -C "$WT" add -A
    git -C "$WT" commit -qm init

    RUN_DIR="$T/run"
    mkdir -p "$RUN_DIR"
    printf "OPENROUTER_API_KEY='tok_supersecret123'\n" \
        >"$RUN_DIR/openrouter-guard.env"
    chmod 600 "$RUN_DIR/openrouter-guard.env"
    printf 'do the slice\n' >"$T/spec.txt"
    export RUN_DIR
    TASK="task_pld1"
    export TASK
}

# done_line -- the last worker_done argv the Orca CLI stub recorded.
done_line() {
    grep 'worker_done' "$ORCA_STUB_LOG" | tail -1
}

# run_worker -- run the worker script against the fixture stream.
run_worker() {
    run "$WORKER_RUN" --task "$TASK" --spec "$T/spec.txt" \
        --model "$STUB_MODEL" --dir "$WT" --run-dir "$RUN_DIR" \
        --bead claude-orca-pld
}

@test "worker-run writes a receipt from a real opencode stream with summed tokens and usd" {
    run_worker
    [ "$status" -eq 0 ]
    local r="$RUN_DIR/orchestration/workers/$TASK.receipt.json"
    [ -f "$r" ]
    local exp_in exp_out
    exp_in="$(jq -s '[.[] | select(.type == "step_finish")
        | (.part.tokens.input // 0)] | add' "$FIXTURE")"
    exp_out="$(jq -s '[.[] | select(.type == "step_finish")
        | (.part.tokens.output // 0)] | add' "$FIXTURE")"
    run jq -e --argjson tin "$exp_in" --argjson tout "$exp_out" '
        .task_id == "task_pld1" and .bead == "claude-orca-pld"
        and .exit_code == 0 and .tokens_in == $tin and .tokens_out == $tout
        and .usd > 0' "$r"
    [ "$status" -eq 0 ]
    grep -qF -- "--ingest-delegate-receipt $r" "$CM_LOG"
}

@test "worker-run's worker_done body is the last text event's part.text" {
    run_worker
    [ "$status" -eq 0 ]
    local last_text prefix
    last_text="$(jq -s '[.[] | select(.type == "text") | .part.text]
        | last' "$FIXTURE")"
    [ -n "$last_text" ]
    prefix="${last_text:0:20}"
    local line
    line="$(done_line)"
    grep -qF -- "--body $prefix" <<<"$line"
}

@test "worker-run still writes a receipt with zeros and one stderr line when the stream has no usage" {
    # An empty stream: nothing to parse at all.
    : >"$T/empty.jsonl"
    FIXTURE="$T/empty.jsonl"
    run --separate-stderr "$WORKER_RUN" --task "$TASK" --spec "$T/spec.txt" \
        --model "$STUB_MODEL" --dir "$WT" --run-dir "$RUN_DIR" \
        --bead claude-orca-pld
    [ "$status" -eq 0 ]
    local r="$RUN_DIR/orchestration/workers/$TASK.receipt.json"
    [ -f "$r" ]
    run jq -e '.exit_code == 0 and .tokens_in == 0
        and .tokens_out == 0 and .usd == 0' "$r"
    [ "$status" -eq 0 ]
    [ "${#stderr_lines[@]}" -eq 1 ]
    [[ "${stderr_lines[0]}" == *"could not parse token usage from"* ]]
}
