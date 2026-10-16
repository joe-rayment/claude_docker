#!/usr/bin/env bats
# Guards:   scripts/worker-run.sh runs one turn of one headless worker: waits for a slot, runs the agent (a stub here) in the job's worktree, writes the receipt and ONE inbox line, and stops cleanly on TERM
# Fails if: the receipt loses a field, a QUESTION:/failed run is reported as done, --resume or the opencode guard token handling is wrong, the slot cap lets a third job in, or TERM leaves the slot held
# Run:      bats tests/workers-run.bats
#
# Every case builds a throwaway project under $BATS_TEST_TMPDIR: its own
# PROJECT_DIR / CLAUDE_ORCA_ROOT / HOME, a real one-commit git repo as the
# job's worktree, a stub `bd` and a stub agent (CLAUDE_ORCA_WORKER_CMD) that
# records its argv and prints a canned stream. Nothing here reaches a real
# agent, a real bd, or /workspace/claude-orca.

WR="$BATS_TEST_DIRNAME/../scripts/worker-run.sh"

setup() {
    PROJ="$BATS_TEST_TMPDIR/proj"
    WORKERS="$PROJ/.claude-dev/run/workers"
    INBOX="$PROJ/.claude-dev/run/orchestration/inbox.jsonl"
    OUT="$BATS_TEST_TMPDIR/out"
    mkdir -p "$WORKERS" "$OUT" "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/bin"
    case "$PROJ" in "$BATS_TEST_TMPDIR"/*) ;; *) return 1 ;; esac
    export PROJECT_DIR="$PROJ" CLAUDE_ORCA_ROOT="$PROJ" HOME="$BATS_TEST_TMPDIR/home"
    export CLAUDE_ORCA_WORKER_CMD="$BATS_TEST_TMPDIR/bin/agent-stub"
    export STUB_OUT="$OUT" BD_LOG="$OUT/bd.log"
    export CLAUDE_ORCA_SLOT_POLL_S=0.2
    unset CLAUDE_ORCA_MAX_WORKERS CLAUDE_CODE_CHILD_SESSION
    # A stub `bd` first on PATH: records its argv, answers `show <id> --json`.
    cat >"$BATS_TEST_TMPDIR/bin/bd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BD_LOG"
if [ "${1:-}" = show ]; then printf '[{"title":"T"}]\n'; fi
exit 0
EOF
    # The agent stub: argv/stdin/cwd to $STUB_OUT/<what>.$STUB_TAG, then a
    # canned stream. STUB_KIND claude|opencode|opencode-finish|codex|gemini, STUB_RESULT the final text,
    # STUB_EXIT its exit code, STUB_SLEEP seconds to hang, STUB_COMMIT=<file> to
    # commit that file in its cwd, STUB_ECHO_TOKEN=<file> to echo a secret.
    cat >"$BATS_TEST_TMPDIR/bin/agent-stub" <<'EOF'
#!/usr/bin/env bash
t="${STUB_TAG:-1}"
printf '%s\n' "$@" >"$STUB_OUT/argv.$t"
pwd >"$STUB_OUT/cwd.$t"
env | sort >"$STUB_OUT/env.$t"
env | grep -c '^CLAUDE_CODE_CHILD_SESSION=' >"$STUB_OUT/childenv.$t"
[ -n "${OPENROUTER_API_KEY:-}" ] && echo 1 >"$STUB_OUT/keyenv.$t"
cat >"$STUB_OUT/stdin.$t"
if [ -n "${STUB_COMMIT:-}" ]; then
    echo new >"$STUB_COMMIT"
    git add "$STUB_COMMIT"
    git -c user.email=a@b -c user.name=t commit -q -m stub
fi
secret=""
[ -n "${STUB_ECHO_TOKEN:-}" ] && secret="$(cat "$STUB_ECHO_TOKEN")"
res="${STUB_RESULT:-all done}${secret:+ leaked:$secret}"
if [ "${STUB_KIND:-claude}" = opencode ]; then
    jq -n -c --arg t "$res" '{type:"text",sessionID:"ses_x",part:{text:$t}}'
    echo '{"type":"step_finish","part":{"tokens":{"input":3,"output":4},"cost":0.1}}'
elif [ "${STUB_KIND:-claude}" = opencode-finish ]; then
    jq -n -c --arg t "$res" '{type:"text",sessionID:"ses_x",part:{text:$t}}'
    echo '{"type":"finish","usage":{"inputTokens":21,"outputTokens":22,"cost":0.02}}'
elif [ "${STUB_KIND:-claude}" = codex ]; then
    echo '{"type":"thread.started","thread_id":"th-1"}'
    jq -n -c --arg t "$res" '{type:"item.completed",item:{id:"i1",type:"agent_message",text:$t}}'
    echo '{"type":"turn.completed","usage":{"input_tokens":31,"cached_input_tokens":0,"output_tokens":32}}'
elif [ "${STUB_KIND:-claude}" = gemini ]; then
    printf '%s\n' "$res"
    echo "gemini stderr note" >&2
else
    echo '{"type":"system","session_id":"sid-1"}'
    jq -n -c --arg r "$res" '{type:"result",result:$r,usage:{input_tokens:5,output_tokens:7},total_cost_usd:0.5}'
fi
if [ -n "${STUB_SLEEP:-}" ]; then
    sleep "$STUB_SLEEP" &
    echo $! >"$STUB_OUT/hanging.$t"
    wait
fi
exit "${STUB_EXIT:-0}"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/bd" "$BATS_TEST_TMPDIR/bin/agent-stub"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# mkjob <job> [agent] [bead] -- a job dir with job.json + spec.md over a real
# one-commit git repo; $JOBDIR / $DIR are set for the caller.
mkjob() {
    local job="$1" agent="${2:-claude}" bead="${3-bead-$1}" variant="${4:-}"
    JOBDIR="$WORKERS/$job"; DIR="$BATS_TEST_TMPDIR/wt-$job"
    mkdir -p "$JOBDIR" "$DIR"
    git -C "$DIR" init -q
    git -C "$DIR" -c user.email=a@b -c user.name=t commit -q --allow-empty -m base
    printf 'do the thing\n' >"$JOBDIR/spec.md"
    jq -n --arg job "$job" --arg bead "$bead" --arg agent "$agent" --arg dir "$DIR" \
        --arg variant "$variant" \
        '{job:$job,bead:$bead,role:"executor",agent:$agent,model:"m-1",variant:$variant,
          effort:"",dir:$dir,branch:"b",frozen_hooks:"",state:"started",created:"2026-01-01T00:00:00Z"}' \
        >"$JOBDIR/job.json"
}

jv() { jq -r "$2" "$1"; }          # jv <file> <jq-filter>

# absent [grep flags] <pattern> <file>... -- fails the case when the pattern IS
# found. (A bare `! grep` never fails a bats case unless it is the last line.)
absent() {
    local flags="-q" pat
    while [ "$#" -gt 0 ]; do
        case "$1" in -x) flags="-qx"; shift ;; --) shift; break ;; *) break ;; esac
    done
    pat="$1"; shift
    if grep $flags -e "$pat" "$@" 2>/dev/null; then echo "found '$pat' in $*" >&2; return 1; fi
    return 0
}

# alive <pid> -- running (a zombie awaiting its reaper does not count).
alive() { [ -r "/proc/$1/stat" ] && ! grep -q ') Z' "/proc/$1/stat"; }

# wait_state <jobdir> <state> -- poll job.json up to ~10 s.
wait_state() {
    local i=0
    while [ "$i" -lt 100 ]; do
        [ "$(jq -r .state "$1/job.json" 2>/dev/null)" = "$2" ] && return 0
        sleep 0.1; i=$(( i + 1 ))
    done
    return 1
}

@test "claude turn: receipt.json carries every field and job.json is marked done" {
    mkjob j1
    STUB_COMMIT=stub-file.txt run "$WR" "$JOBDIR"
    [ "$status" -eq 0 ]
    R="$JOBDIR/receipt.json"
    [ -f "$R" ]
    jq -e '.job=="j1" and .bead=="bead-j1" and .agent=="claude" and .model=="m-1" and .exit==0
           and .session_id=="sid-1" and .tokens_in==5 and .tokens_out==7 and .usd==0.5
           and .summary=="all done" and (.files==["stub-file.txt"])
           and (.started|type=="string") and (.ended|type=="string") and (.wall_s|type=="number")' "$R"
    jq -e '.state=="done" and .session_id=="sid-1" and .turns==1 and .exit==0
           and .slot==1 and (.pid|type=="number") and (.started|type=="string") and (.base|type=="string")
           and (.last_receipt|endswith("receipt.json"))' "$JOBDIR/job.json"
    # the worker commit shows up as the receipt's file list, not the base commit
    [ "$(git -C "$DIR" rev-list --count HEAD)" -eq 2 ]
}

@test "claude turn: the stub gets exactly the claude argv, the spec on stdin, the job dir as cwd" {
    mkjob j2
    run "$WR" "$JOBDIR"
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/argv.1")" = "$(printf '%s\n' -p --model m-1 --output-format stream-json --verbose --permission-mode bypassPermissions)" ]
    [ "$(cat "$OUT/stdin.1")" = "do the thing" ]
    [ "$(cat "$OUT/cwd.1")" = "$(cd "$DIR" && pwd -P)" ]
    # CLAUDE_CODE_CHILD_SESSION is stripped even when the caller has it set
    CLAUDE_CODE_CHILD_SESSION=1 STUB_TAG=2 run "$WR" "$JOBDIR"
    [ "$(cat "$OUT/childenv.2")" = "0" ]
    # stdout appended to log.jsonl, nothing of it lost between turns
    [ "$(grep -c '"type":"result"' "$JOBDIR/log.jsonl")" -eq 2 ]
}

@test "claude turn: an --effort in job.json is passed through" {
    mkjob j3
    jq '.effort="high"' "$JOBDIR/job.json" >"$JOBDIR/j.tmp" && mv "$JOBDIR/j.tmp" "$JOBDIR/job.json"
    run "$WR" "$JOBDIR"
    [ "$status" -eq 0 ]
    grep -qx -- '--effort' "$OUT/argv.1"
    grep -qx -- 'high' "$OUT/argv.1"
}

@test "inbox: one worker_done line with every schema field, bead note written, subject from bd show" {
    mkjob j4
    run "$WR" "$JOBDIR"
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$INBOX")" -eq 1 ]
    jq -e '.type=="worker_done" and .msg_id=="j4" and .from=="worker-run" and .subject=="T"
           and .body=="all done" and .task_id=="j4" and .dispatch_id=="j4" and .bead=="bead-j4"
           and .agent=="claude" and .model=="m-1" and .outcome=="done" and (.files|type=="array")
           and .released==true and .terminal_closed==true and .job=="j4"
           and (.receipt|endswith("/j4/receipt.json")) and (has("reply_with")|not)' "$INBOX"
    grep -q '^show bead-j4 --json' "$BD_LOG"
    grep -q '^update bead-j4 --append-notes WORKER_DONE job=j4 outcome=done' "$BD_LOG"
}

@test "inbox: when bd cannot name the bead the subject falls back to the bead id, then the job id" {
    mkjob j5
    printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/bd"
    run "$WR" "$JOBDIR"
    [ "$status" -eq 0 ]
    [ "$(jq -r .subject "$INBOX")" = "bead-j5" ]
    mkjob j6 claude ""
    run "$WR" "$JOBDIR"
    [ "$status" -eq 0 ]
    [ "$(tail -n1 "$INBOX" | jq -r .subject)" = "j6" ]
}

@test "question: a QUESTION: line makes state question, a question inbox line and reply_with" {
    mkjob j7
    STUB_RESULT=$'looked around\nQUESTION: which database?' run "$WR" "$JOBDIR"
    [ "$status" -eq 0 ]
    [ "$(jv "$JOBDIR/job.json" .state)" = "question" ]
    jq -e '.type=="question" and .outcome=="question" and (.body|contains("QUESTION: which database?"))
           and .reply_with=="workers reply j7 \"<answer>\""' "$INBOX"
}

@test "failure: a non-zero exit is failed / worker_failed, even when the output has a QUESTION: line" {
    mkjob j8
    STUB_EXIT=3 STUB_RESULT=$'QUESTION: really?' run "$WR" "$JOBDIR"
    [ "$status" -eq 3 ]
    [ "$(jv "$JOBDIR/job.json" .state)" = "failed" ]
    [ "$(jv "$JOBDIR/job.json" .exit)" = "3" ]
    [ "$(jv "$JOBDIR/receipt.json" .exit)" = "3" ]
    jq -e '.type=="worker_failed" and .outcome=="failed" and (has("reply_with")|not)' "$INBOX"
}

@test "failure: an agent that says nothing still gets a worker_failed body that points at runner.log" {
    mkjob j9
    printf '#!/usr/bin/env bash\necho boom >&2\nexit 5\n' >"$BATS_TEST_TMPDIR/bin/agent-stub"
    run "$WR" "$JOBDIR"
    [ "$status" -eq 5 ]
    grep -q boom "$JOBDIR/runner.log"
    jq -e '.type=="worker_failed" and (.body|contains("runner.log"))' "$INBOX"
}

@test "resume: --resume <sid> passes --resume, the message goes on stdin, receipt-2.json is the second turn's" {
    mkjob j10
    STUB_COMMIT=first.txt run "$WR" "$JOBDIR"
    [ "$status" -eq 0 ]
    STUB_TAG=2 STUB_COMMIT=second.txt run "$WR" "$JOBDIR" --resume sid-1 --message "use sqlite"
    [ "$status" -eq 0 ]
    [ "$(tail -n1 "$OUT/argv.2")" = "sid-1" ]
    grep -qx -- '--resume' "$OUT/argv.2"
    [ "$(cat "$OUT/stdin.2")" = "use sqlite" ]
    [ -f "$JOBDIR/receipt.json" ]
    [ -f "$JOBDIR/receipt-2.json" ]
    # each turn's receipt lists only that turn's files
    [ "$(jq -c .files "$JOBDIR/receipt.json")" = '["first.txt"]' ]
    [ "$(jq -c .files "$JOBDIR/receipt-2.json")" = '["second.txt"]' ]
    jq -e '.turns==2 and .state=="done" and (.last_receipt|endswith("receipt-2.json"))' "$JOBDIR/job.json"
    [ "$(wc -l <"$INBOX")" -eq 2 ]
    [ "$(tail -n1 "$INBOX" | jq -r .receipt | sed 's|.*/||')" = "receipt-2.json" ]
}

@test "usage: --resume without --message, a missing job dir, and an unknown agent all exit 2" {
    mkjob j11
    run "$WR" "$JOBDIR" --resume sid-1
    [ "$status" -eq 2 ]
    run "$WR"
    [ "$status" -eq 2 ]
    run "$WR" "$WORKERS/nope"
    [ "$status" -eq 2 ]
    jq '.agent="bogus"' "$JOBDIR/job.json" >"$JOBDIR/j.tmp" && mv "$JOBDIR/j.tmp" "$JOBDIR/job.json"
    run "$WR" "$JOBDIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown agent"* ]]
    [ ! -s "$INBOX" ]
}

# The guard token is the only key a worker ever sees; it must never reach argv,
# log.jsonl or the receipt. The stub echoes it into its stream to prove that.
mkguard() {
    mkdir -p "$PROJ/.claude-dev/run"
    printf 'guardtoken-test-123' >"$PROJ/.claude-dev/run/openrouter-guard.token"
    export STUB_KIND=opencode STUB_ECHO_TOKEN="$PROJ/.claude-dev/run/openrouter-guard.token"
}

@test "opencode: the key is in the agent's env only; argv, log.jsonl and the receipt never hold the guard token" {
    mkguard
    mkjob o1 opencode bead-o1 max
    run "$WR" "$JOBDIR"
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/keyenv.1")" = "1" ]
    [ "$(cat "$OUT/argv.1")" = "$(printf '%s\n' run -m m-1 --dir "$DIR" --auto --format json --variant max 'do the thing')" ]
    absent guardtoken-test-123 "$OUT/argv.1" "$OUT/stdin.1"
    grep -q 'leaked:' "$JOBDIR/log.jsonl"
    absent guardtoken-test-123 "$JOBDIR/log.jsonl"
    absent guardtoken-test-123 "$JOBDIR/receipt.json"
    absent guardtoken-test-123 "$INBOX"
    jq -e '.agent=="opencode" and .session_id=="ses_x" and .tokens_in==3 and .tokens_out==4 and .usd==0.1
           and (.summary|contains("leaked:"))' "$JOBDIR/receipt.json"
}

@test "opencode: no --variant flag when the job sets none, and resume passes -s <sid> with the message as the prompt" {
    mkguard
    mkjob o2 opencode
    run "$WR" "$JOBDIR"
    [ "$status" -eq 0 ]
    absent -x -- '--variant' "$OUT/argv.1"
    STUB_TAG=2 run "$WR" "$JOBDIR" --resume ses_x --message "go on"
    [ "$status" -eq 0 ]
    [ "$(sed -n 1,3p "$OUT/argv.2" | tr '\n' ' ')" = "run -s ses_x " ]
    [ "$(tail -n1 "$OUT/argv.2")" = "go on" ]
    absent guardtoken-test-123 "$JOBDIR/receipt-2.json"
    absent guardtoken-test-123 "$JOBDIR/log.jsonl"
}

@test "slots: with one slot a second job is marked queued while the first runs, then both finish" {
    export CLAUDE_ORCA_MAX_WORKERS=1
    mkjob s1; J1="$JOBDIR"
    mkjob s2; J2="$JOBDIR"
    STUB_SLEEP=2 STUB_TAG=1 "$WR" "$J1" >/dev/null 2>&1 &
    P1=$!
    wait_state "$J1" running
    [ "$(jv "$J1/job.json" .slot)" = "1" ]
    STUB_TAG=2 "$WR" "$J2" >/dev/null 2>&1 &
    P2=$!
    wait_state "$J2" queued
    # still queued, not running, while job 1 holds the only slot
    [ "$(jv "$J2/job.json" .state)" = "queued" ]
    [ ! -e "$OUT/argv.2" ]
    wait "$P1"; wait "$P2"
    [ "$(jv "$J1/job.json" .state)" = "done" ]
    [ "$(jv "$J2/job.json" .state)" = "done" ]
    [ "$(jv "$J2/job.json" .slot)" = "1" ]
    [ "$(wc -l <"$INBOX")" -eq 2 ]
}

@test "slots: six parallel runs on six slots leave six whole JSON lines in the inbox" {
    export CLAUDE_ORCA_MAX_WORKERS=6
    local n pids=""
    for n in 1 2 3 4 5 6; do
        mkjob "p$n"
        STUB_TAG="$n" "$WR" "$JOBDIR" >/dev/null 2>&1 &
        pids="$pids $!"
    done
    for n in $pids; do wait "$n"; done
    [ "$(wc -l <"$INBOX")" -eq 6 ]
    [ "$(jq -c . "$INBOX" | wc -l)" -eq 6 ]
    [ "$(jq -r .job "$INBOX" | sort | tr '\n' ' ')" = "p1 p2 p3 p4 p5 p6 " ]
    # every one of the six finished (none stuck queued or lost its state)
    [ "$(for n in 1 2 3 4 5 6; do jq -r .state "$WORKERS/p$n/job.json"; done | sort -u)" = "done" ]
}

@test "TERM: kills the agent's group, marks the job stopped, exits 143 and frees the slot" {
    export CLAUDE_ORCA_MAX_WORKERS=1
    mkjob t1; J1="$JOBDIR"
    STUB_SLEEP=30 "$WR" "$J1" >/dev/null 2>&1 &
    P1=$!
    wait_state "$J1" running
    local i=0; while [ ! -e "$OUT/hanging.1" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$(( i + 1 )); done
    [ -e "$OUT/hanging.1" ]
    PID="$(jv "$J1/job.json" .pid)"
    SLEEP_PID="$(cat "$OUT/hanging.1")"
    alive "$SLEEP_PID"
    [ "$PID" = "$P1" ]
    kill -TERM "$PID"
    local rc=0; wait "$P1" || rc=$?
    [ "$rc" -eq 143 ]
    [ "$(jv "$J1/job.json" .state)" = "stopped" ]
    # the agent's own child (the stub's sleep) did not outlive the stop
    if alive "$SLEEP_PID"; then echo "stub sleep $SLEEP_PID survived TERM" >&2; return 1; fi
    # the slot is free again: a new job runs at once instead of queueing
    mkjob t2
    STUB_TAG=2 run timeout 20 "$WR" "$JOBDIR"
    [ "$status" -eq 0 ]
    [ "$(jv "$JOBDIR/job.json" .slot)" = "1" ]
    [ "$(jv "$JOBDIR/job.json" .state)" = "done" ]
}

# ---- claude-orca-9bh.5 (A5): codex / gemini / isolated-env / merged-log jobs --

# jobset <jq-filter> [jq options] -- rewrite $JOBDIR/job.json in place.
jobset() {
    jq "${@:2}" "$1" "$JOBDIR/job.json" >"$JOBDIR/j.tmp" && mv "$JOBDIR/j.tmp" "$JOBDIR/job.json"
}

@test "codex: argv is exec --model <name> --cd <dir> --json --full-auto <spec>; the receipt reads the agent_message and turn.completed usage; --resume exits 2" {
    # Guards:   a codex job runs `codex exec` with the model's provider prefix dropped and reports the final agent message and token usage
    # Fails if: the argv order or the model name changes, the receipt takes the wrong event as the summary, or usage_found is not true
    # Run:      bats -f 'codex: argv' tests/workers-run.bats
    mkjob c1 codex
    jobset '.model="openai/gpt-5"'
    STUB_KIND=codex STUB_RESULT="codex says hi" run "$WR" "$JOBDIR"
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/argv.1")" = "$(printf '%s\n' exec --model gpt-5 --cd "$DIR" --json --full-auto "do the thing")" ]
    [ "$(cat "$OUT/cwd.1")" = "$(cd "$DIR" && pwd -P)" ]
    jq -e '.agent=="codex" and .summary=="codex says hi" and .tokens_in==31 and .tokens_out==32
           and .usage_found==true and .session_id==""' "$JOBDIR/receipt.json"
    jq -e '.state=="done"' "$JOBDIR/job.json"
    STUB_TAG=2 run "$WR" "$JOBDIR" --resume sid-1 --message hi
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot --resume"* ]]
    [ ! -e "$OUT/argv.2" ]
}

@test "gemini: argv is -m <name> --yolo -p <spec> in the job dir; the whole raw output is the summary; usage_found is false" {
    # Guards:   a gemini job runs `gemini -p` in the worktree and reports its plain-text output as the summary, with no invented token counts
    # Fails if: the flags or cwd change, the summary drops text, or a run with no usage block claims usage_found true
    # Run:      bats -f 'gemini: argv' tests/workers-run.bats
    mkjob g1 gemini
    jobset '.model="google/gemini-2.5-pro"'
    STUB_KIND=gemini STUB_RESULT="plain gemini answer" run "$WR" "$JOBDIR"
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/argv.1")" = "$(printf '%s\n' -m gemini-2.5-pro --yolo -p "do the thing")" ]
    [ "$(cat "$OUT/cwd.1")" = "$(cd "$DIR" && pwd -P)" ]
    [ "$(jv "$JOBDIR/receipt.json" .summary)" = "plain gemini answer" ]
    jq -e '.agent=="gemini" and .tokens_in==0 and .tokens_out==0 and .usage_found==false
           and .session_id==""' "$JOBDIR/receipt.json"
    # not merged: the agent's stderr stays in runner.log, out of the summary
    grep -q 'gemini stderr note' "$JOBDIR/runner.log"
    absent 'gemini stderr note' "$JOBDIR/log.jsonl" "$JOBDIR/receipt.json"
}
