# Guards: `workers` (list/wait/reply/tail/stop) reads the job dirs and the inbox honestly, with no Orca anywhere -- and the slot cap really queues extra dispatches
# Fails if: list miscounts running/queued or hides a dead pid, wait double-delivers or skips an inbox line, a stall is reported twice, reply resumes a running job, or stop leaves the worker alive
# Run: bats tests/workers-cli.bats
# bats file_tags=size:medium

bats_require_minimum_version 1.5.0

setup() {
    FIX="$BATS_TEST_TMPDIR"
    WORKERS="$BATS_TEST_DIRNAME/../scripts/workers.sh"
    ROOTD="$FIX/proj"; WD="$ROOTD/.claude-dev/run/workers"; OD="$ROOTD/.claude-dev/run/orchestration"
    mkdir -p "$WD" "$OD" "$FIX/home" "$FIX/bin" "$FIX/wt"
    export PROJECT_DIR="$ROOTD" CLAUDE_ORCA_ROOT="$ROOTD" HOME="$FIX/home"
    export CLAUDE_ORCA_MAX_WORKERS=2 CLAUDE_ORCA_UNTIL_POLL_S=0.1 TIER_STATE_FILE="$FIX/tier.json"
    unset CLAUDE_ORCA_STALL_S CLAUDE_ORCA_WORKER_RUN CLAUDE_ORCA_WORKER_CMD
    BG=""
}

teardown() { [ -z "$BG" ] || kill $BG 2>/dev/null || true; }

# mkjob <job> <bead> <state> <pid> <created> -- a hand-written job dir
mkjob() {
    mkdir -p "$WD/$1"
    jq -n --arg job "$1" --arg bead "$2" --arg state "$3" --arg pid "$4" --argjson created "$5" \
        '{job:$job,bead:$bead,agent:"claude",model:"m1",state:$state,created:$created}
         + (if $pid == "" then {} else {pid: ($pid|tonumber)} end)' >"$WD/$1/job.json"
}
deadpid() { sleep 0 & local p=$!; wait "$p"; printf '%s' "$p"; }

@test "list: header counts, newest first, dead pid, --json" {
    sleep 30 & BG=$!
    mkjob old-1 b-old done "" 100
    mkjob dead-1 b-dead running "$(deadpid)" 200
    mkjob new-1 b-new running "$BG" 300
    mkjob q-1 b-q queued "$BG" 400
    run "$WORKERS" list
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | sed -n 1p)" = "workers 1/2 running · 1 queued" ]
    [ "$(printf '%s\n' "$output" | sed -n '2,$p' | awk '{print $1}' | tr '\n' ' ')" = "q-1 new-1 dead-1 old-1 " ]
    printf '%s\n' "$output" | grep -E '^dead-1 .* running +dead ' >/dev/null
    printf '%s\n' "$output" | grep -E '^new-1 .* claude:m1 +running +[0-9]+ ' >/dev/null
    run "$WORKERS" list --json
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 4 ]
    printf '%s\n' "$output" | sed -n 3p | jq -e '.job == "dead-1" and .dead == true and .pid == null' >/dev/null
}

@test "wait: bare read prints once and advances the cursor, --until blocks then times out" {
    printf '{"type":"worker_done","bead":"a"}\n{"type":"worker_done","bead":"b"}\n' >"$OD/inbox.jsonl"
    run "$WORKERS" wait
    [ "$status" -eq 0 ]; [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
    run "$WORKERS" wait
    [ "$status" -eq 0 ]; [ -z "$output" ]
    (sleep 1; printf '{"type":"worker_done","bead":"c"}\n' >>"$OD/inbox.jsonl") & BG=$!
    run "$WORKERS" wait --until 5
    [ "$status" -eq 0 ]
    [ "$output" = '{"type":"worker_done","bead":"c"}' ]
    run "$WORKERS" wait --until 1
    [ "$status" -eq 4 ]; [ -z "$output" ]
}

@test "wait: a silent running job gets ONE stalled line" {
    mkjob s-1 b-s running "$$" 100
    : >"$WD/s-1/log.jsonl"; touch -d '2 hours ago' "$WD/s-1/log.jsonl"
    export CLAUDE_ORCA_STALL_S=1
    run "$WORKERS" wait
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.type == "stalled" and .dispatch_id == "s-1" and .bead == "b-s" and .idle_s > 3000' >/dev/null
    [ -e "$WD/s-1/stall.reported" ]
    run "$WORKERS" wait
    [ -z "$output" ]
    [ "$(grep -c stalled "$OD/inbox.jsonl")" -eq 1 ]
}

@test "reply: no session -> 2, running -> 3, otherwise the runner gets --resume and --message" {
    mkjob r-1 b-r done "" 100
    run "$WORKERS" reply r-1 "go on"
    [ "$status" -eq 2 ]
    printf '#!/bin/sh\nprintf "%%s|" "$@" >"%s/runner-args"\n' "$FIX" >"$FIX/runner.sh"; chmod +x "$FIX/runner.sh"
    export CLAUDE_ORCA_WORKER_RUN="$FIX/runner.sh"
    jq '.session_id = "sess-9"' "$WD/r-1/job.json" >"$FIX/j" && mv "$FIX/j" "$WD/r-1/job.json"
    run "$WORKERS" reply r-1 "go on please"
    [ "$status" -eq 0 ]
    [ "$output" = '{"job":"r-1","state":"resumed"}' ]
    for _ in $(seq 40); do [ -s "$FIX/runner-args" ] && break; sleep 0.05; done
    [ "$(cat "$FIX/runner-args")" = "$WD/r-1|--resume|sess-9|--message|go on please|" ]
    run "$WORKERS" reply r-1 "again"
    [ "$status" -eq 3 ]
}

@test "tail: renders a claude stream and ends when the job is done; --raw passes it through" {
    mkjob t-1 b-t done "" 100
    cat >"$WD/t-1/log.jsonl" <<'EOF'
{"type":"system","subtype":"init","session_id":"s"}
{"type":"assistant","message":{"content":[{"type":"text","text":"hello there"},{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}
not json
{"type":"result","result":"all done","session_id":"s"}
EOF
    run timeout 10 "$WORKERS" tail t-1
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'assistant: hello there\ntool: Bash {"command":"ls -la"}\nresult: all done')" ]
    run timeout 10 "$WORKERS" tail b-t --raw
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 4 ]
}

@test "stop: TERMs a sleeping setsid worker, marks it stopped, writes worker_stopped" {
    setsid sh -c "echo \$\$ >'$FIX/pid'; exec sleep 60" </dev/null >/dev/null 2>&1 &
    for _ in $(seq 40); do [ -s "$FIX/pid" ] && break; sleep 0.05; done
    pid="$(cat "$FIX/pid")"; BG="$pid"
    mkjob k-1 b-k running "$pid" 100
    run "$WORKERS" stop k-1
    [ "$status" -eq 0 ]
    ! kill -0 "$pid" 2>/dev/null
    [ "$(jq -r .state "$WD/k-1/job.json")" = stopped ]
    jq -e '.type == "worker_stopped" and .job == "k-1" and .bead == "b-k"' "$OD/inbox.jsonl" >/dev/null
}

@test "four dispatches with maxWorkers=2: 2 running + 2 queued, then all done with 4 worker_done lines" {
    git -C "$ROOTD" init -q -b main
    git -C "$ROOTD" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
    printf '#!/bin/sh\nprintf '"'"'[{"id":"%%s","title":"T","description":"D","acceptance_criteria":"","notes":""}]\\n'"'"' "$2"\n' >"$FIX/bin/bd"
    chmod +x "$FIX/bin/bd"
    printf '#!/bin/sh\ncat >/dev/null\nsleep 3\necho '"'"'{"type":"result","result":"ok","session_id":"s1"}'"'"'\n' >"$FIX/agent.sh"
    chmod +x "$FIX/agent.sh"
    export PATH="$FIX/bin:$PATH" CLAUDE_ORCA_WORKER_CMD="$FIX/agent.sh" CLAUDE_ORCA_WORKTREES_DIR="$FIX/wt"
    export CLAUDE_ORCA_SLOT_POLL_S=0.2
    for n in 1 2 3 4; do
        "$BATS_TEST_DIRNAME/../scripts/dispatch.sh" "demo-$n" >/dev/null 2>&1
    done
    for _ in $(seq 40); do
        out="$("$WORKERS" list)"
        [ "$(printf '%s\n' "$out" | grep -c ' queued ')" -eq 2 ] && break
        sleep 0.1
    done
    echo "$out"
    [ "$(printf '%s\n' "$out" | head -1)" = "workers 2/2 running · 2 queued" ]
    [ "$(printf '%s\n' "$out" | grep -c ' queued ')" -eq 2 ]
    [ "$(printf '%s\n' "$out" | grep -c '^demo-.* running ')" -eq 2 ]
    for _ in $(seq 200); do
        [ "$(grep -c worker_done "$OD/inbox.jsonl" 2>/dev/null)" -ge 4 ] && break
        sleep 0.1
    done
    [ "$(grep -c worker_done "$OD/inbox.jsonl")" -eq 4 ]
    out="$("$WORKERS" list)"; echo "$out"
    [ "$(printf '%s\n' "$out" | grep -c ' done ')" -eq 4 ]
}
