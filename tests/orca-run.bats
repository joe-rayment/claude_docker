#!/usr/bin/env bats
#
# orca-run -- parallel waves across epics, against a REAL Orca runtime
# (claude-orca-qa2.16, plan .claude/plans/orca-orchestration.md "Parallel
# by default").
#
# The harness is tests/orca-dispatch.bats's: one headless `orca-ide
# --serve` under xvfb-run over a throwaway git project with its own beads
# database, one coordinator bash terminal, and a teardown that kills only
# this run's daemon. Nothing is stubbed -- every id in the assertions came
# out of the running runtime, and the "workers" are bash panes that report
# `worker_done` for themselves exactly as a real worker does.
#
# orca-run blocks until its epics settle, so each test starts it in the
# background, then drives the panes: poll the dispatch records it writes,
# and send one worker_done per new dispatch. What the test asserts is
# orca-run's own event stream (one compact JSON object per line on
# stdout), whose ORDER is the claim under test -- a dependent bead's
# `dispatch` event must come after its dependency's `worker_done`.
#
# Unix domain socket paths cap out around 100 chars, so the user-data dir
# is /tmp/oo-XXXXXX and the project /tmp/op-XXXXXX -- never BATS_TMPDIR.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

setup_file() {
    # The container points BEADS_DIR at the workspace's own tracker; the
    # throwaway project below must init its own, not refuse to.
    unset BEADS_DIR
    command -v xvfb-run >/dev/null 2>&1 || skip "xvfb-run is not installed"
    command -v jq >/dev/null 2>&1 || skip "jq is not installed"
    command -v bd >/dev/null 2>&1 || skip "bd is not installed"

    local app cli
    app="${ORCA_BIN:-/opt/orca/orca-ide}"
    [ -x "$app" ] || skip "no Orca app binary at $app"
    cli="$(command -v orca-ide 2>/dev/null || true)"
    [ -n "$cli" ] || cli=/opt/orca/resources/bin/orca-ide
    [ -x "$cli" ] || skip "no Orca CLI at $cli"

    local ud proj port
    ud="$(mktemp -d /tmp/oo-XXXXXX)"
    proj="$(mktemp -d /tmp/op-XXXXXX)"

    (
        cd "$proj" || exit 1
        git init -q .
        git config user.email orca@test
        git config user.name orca
        echo hi >README.md
        git add -A
        git commit -qm init
        bd init --prefix wave >/dev/null 2>&1
    ) || skip "could not build the throwaway project"

    mkdir -p "$proj/.claude-dev/run"

    # 6830+ is this suite's range: sibling suites boot their own serve.
    port="$(python3 -c 'import socket
for p in range(6830, 6900):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p))
    except OSError:
        s.close()
        continue
    print(p)
    s.close()
    break')"
    [ -n "$port" ] || skip "no free port in 6830-6899"

    local log="$ud/serve.log"
    setsid xvfb-run -a "$app" --no-sandbox --disable-gpu \
        --disable-software-rasterizer --disable-dev-shm-usage \
        --user-data-dir="$ud" --serve --port "$port" \
        --project-root "$proj" >"$log" 2>&1 </dev/null &
    local pid=$!

    local i ready=0
    for i in $(seq 1 180); do
        if grep -q "Orca server ready" "$log" 2>/dev/null; then ready=1; break; fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if [ "$ready" != "1" ]; then
        kill -TERM -"$pid" 2>/dev/null
        skip "orca serve never became ready: $(tail -5 "$log" 2>/dev/null)"
    fi

    export ORCA_USER_DATA_PATH="$ud"
    "$cli" repo add --path "$proj" --json >/dev/null 2>&1 </dev/null 3>&-

    local coord
    coord="$("$cli" terminal create --worktree "path:$proj" --title coord \
        --command bash --json 2>/dev/null </dev/null 3>&- |
        jq -r '.result.terminal.handle')"
    if [ -z "$coord" ] || [ "$coord" = "null" ]; then
        kill -TERM -"$pid" 2>/dev/null
        skip "could not create a coordinator terminal"
    fi

    {
        echo "ORCA_CLI=$cli"
        echo "ORCA_UD=$ud"
        echo "ORCA_PROJ=$proj"
        echo "ORCA_PORT=$port"
        echo "ORCA_SERVE_PID=$pid"
        echo "ORCA_COORD=$coord"
    } >"$BATS_FILE_TMPDIR/env"
}

teardown_file() {
    [ -f "$BATS_FILE_TMPDIR/env" ] || return 0
    # shellcheck disable=SC1091
    . "$BATS_FILE_TMPDIR/env"
    [ -n "${ORCA_SERVE_PID:-}" ] && kill -TERM -"$ORCA_SERVE_PID" 2>/dev/null
    sleep 1
    [ -n "${ORCA_SERVE_PID:-}" ] && kill -KILL -"$ORCA_SERVE_PID" 2>/dev/null
    # Orca's daemon is spawned detached and holds whatever descriptors it
    # inherited -- including bats' own stdin -- so bats would never see
    # EOF. The token path matches only this run's daemon.
    [ -n "${ORCA_UD:-}" ] &&
        pkill -f "daemon-v36.sock --token $ORCA_UD/daemon" 2>/dev/null
    return 0
}

setup() {
    [ -f "$BATS_FILE_TMPDIR/env" ] || skip "no live Orca runtime"
    # shellcheck disable=SC1091
    . "$BATS_FILE_TMPDIR/env"
    export ORCA_USER_DATA_PATH="$ORCA_UD"
    export CLAUDE_ORCA_ROOT="$ORCA_PROJ"
    RUN_SH="$REPO_ROOT/scripts/orca-run.sh"
    ODIR="$ORCA_PROJ/.claude-dev/run/orchestration"
    DDIR="$ODIR/dispatch"
    LOG="$BATS_TEST_TMPDIR/run.log"
    ERR="$BATS_TEST_TMPDIR/run.err"
    : >"$LOG"
    : >"$ERR"
}

# --- helpers -------------------------------------------------------------

orca() { "$ORCA_CLI" "$@" </dev/null 3>&-; }

bd_here() { ( cd "$ORCA_PROJ" && bd "$@" ); }

bd_id() { jq -r 'if type == "array" then .[0].id else .id end'; }

mkepic() { bd_here create --title "$1" -t epic -p 1 --json | bd_id; }

# mkbead <parent> <title> <description> [acceptance]
mkbead() {
    if [ -n "${4:-}" ]; then
        bd_here create --title "$2" -d "$3" --acceptance "$4" \
            -t task -p 1 --parent "$1" --json | bd_id
    else
        bd_here create --title "$2" -d "$3" -t task -p 1 \
            --parent "$1" --json | bd_id
    fi
}

# Dispatch records already on disk: earlier tests share this project, so
# every test tells the driver which ones are not its own.
dispatch_ids() { ls "$DDIR" 2>/dev/null | sed 's/\.json$//'; }

# The event stream: one compact JSON object per line, plus the plain
# "EPIC READY" lines, which grep '^{' drops.
events() { grep '^{' "$LOG" 2>/dev/null || true; }

# dispatch/worker_done in the order orca-run emitted them.
seq_of() {
    events | jq -r 'select(.event == "dispatch" or .event == "worker_done")
        | "\(.event):\(.bead)"'
}

# 1-based position of "<event>:<bead>" in that stream, 0 when absent.
pos() {
    local n
    n="$(seq_of | grep -n -x -F "$1" | head -1 | cut -d: -f1)"
    [ -n "$n" ] || n=0
    printf '%s' "$n"
}

count_events() {
    events | jq -r --arg e "$1" 'select(.event == $e) | .bead' | wc -l | tr -d ' '
}

wave_beads() {
    events | jq -r --argjson w "$1" \
        'select(.event == "dispatch" and .wave == $w) | .bead' | sort | tr '\n' ' '
}

sorted() { printf '%s\n' "$@" | sort | tr '\n' ' '; }

# wait_dispatches <pid> <n> <secs> -- block until orca-run has emitted n
# dispatch events, or until it exits.
wait_dispatches() {
    local pid="$1" want="$2" deadline
    deadline=$(( $(date +%s) + $3 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ "$(count_events dispatch)" -ge "$want" ]; then return 0; fi
        if ! kill -0 "$pid" 2>/dev/null; then return 1; fi
        sleep 2
    done
    return 1
}

# drive <pid> <n> <secs> [dispatch-id ...] -- answer the next n dispatches,
# each from its own pane, the way a real worker reports for itself. The
# trailing ids are the records that were already there before this test
# started. An orca-run that has already exited ends the loop after one last
# sweep, so a broken run fails the assertion instead of burning the budget.
drive() {
    local pid="$1" want="$2" secs="$3" seen deadline n=0 alive=1 f d b t term
    shift 3
    seen=" $* "
    deadline=$(( $(date +%s) + secs ))
    while [ "$n" -lt "$want" ] && [ "$(date +%s)" -lt "$deadline" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then alive=0; fi
        for f in "$DDIR"/*.json; do
            [ -f "$f" ] || continue
            d="$(basename "$f" .json)"
            case "$seen" in *" $d "*) continue ;; esac
            b="$(jq -r '.bead // ""' "$f")"
            t="$(jq -r '.task_id // ""' "$f")"
            term="$(jq -r '.terminal // ""' "$f")"
            seen="$seen$d "
            [ -n "$t" ] && [ -n "$term" ] || continue
            orca terminal send --terminal "$term" --enter --json --text \
                "orca-ide orchestration send --type worker_done --subject \"$b done\" --body ok --task-id $t --dispatch-id $d --outcome succeeded --files-modified README.md --json" \
                >/dev/null 2>&1 || true
            n=$(( n + 1 ))
        done
        if [ "$alive" -eq 0 ]; then break; fi
        if [ "$n" -lt "$want" ]; then sleep 2; fi
    done
    printf '%s' "$n"
}

# wait_exit <pid> <secs> -- orca-run's exit code in WAIT_RC; a run that
# will not end is killed so the suite fails on the code instead of
# hanging. It must run in the test shell itself, never inside $(...):
# `wait` only knows the shell's own children, and in a command-substitution
# subshell it answers -1 for the test's background orca-run.
wait_exit() {
    local deadline rc=0
    deadline=$(( $(date +%s) + $2 ))
    while kill -0 "$1" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 2
    done
    if kill -0 "$1" 2>/dev/null; then
        kill -TERM "$1" 2>/dev/null
        sleep 1
    fi
    wait "$1" || rc=$?
    WAIT_RC="$rc"
}

# --- the waves -----------------------------------------------------------

@test "orca-run dispatches all ready beads of an epic in one wave and dependents only after their dependency reports worker_done" {
    local epic a b c seen n rc
    epic="$(mkepic "wave epic")"
    a="$(mkbead "$epic" "slice A" "edit alpha.txt")"
    b="$(mkbead "$epic" "slice B" "edit bravo.txt")"
    c="$(mkbead "$epic" "slice C" "edit charlie.txt")"
    bd_here dep "$a" --blocks "$c" >/dev/null
    seen="$(dispatch_ids)"

    "$RUN_SH" --epic "$epic" --agent bash --worktree "path:$ORCA_PROJ" \
        --from "$ORCA_COORD" --timeout-ms 30000 \
        >"$LOG" 2>"$ERR" </dev/null 3>&- &
    local pid=$!

    # shellcheck disable=SC2086
    n="$(drive "$pid" 3 300 $seen)"
    [ "$n" -eq 3 ]
    wait_exit "$pid" 180; rc="$WAIT_RC"
    [ "$rc" -eq 0 ]

    # Wave 1 is exactly the two beads bd calls ready; C was blocked.
    [ "$(wave_beads 1)" = "$(sorted "$a" "$b")" ]
    [ "$(count_events dispatch)" -eq 3 ]
    [ "$(count_events worker_done)" -eq 3 ]

    # C ran in a later wave, and not before A had reported.
    local cwave
    cwave="$(events | jq -r --arg b "$c" \
        'select(.event == "dispatch" and .bead == $b) | .wave')"
    [ "$cwave" -ge 2 ]
    [ "$(pos "worker_done:$a")" -gt 0 ]
    [ "$(pos "dispatch:$c")" -gt "$(pos "worker_done:$a")" ]

    # Every dispatch is a real Orca Task and Dispatch, and the DAG went
    # into Orca too: C's Task carries A's Task in its deps.
    local atask ctask rid
    atask="$(events | jq -r --arg b "$a" \
        'select(.event == "dispatch" and .bead == $b) | .task_id')"
    ctask="$(events | jq -r --arg b "$c" \
        'select(.event == "dispatch" and .bead == $b) | .task_id')"
    [[ "$atask" == task_* ]]
    rid="$(jq -r '.run_id' "$ODIR/run.json")"
    run jq -e --arg t "$ctask" --arg d "$atask" '
        [.result.tasks[] | select(.id == $t)
         | select((.deps | fromjson) | index($d) != null)] | length == 1' \
        <(orca orchestration task-list --run "$rid" --json 2>/dev/null)
    [ "$status" -eq 0 ]
}

@test "orca-run drives two epics at once in two Orca worktrees" {
    local e1 e2 b1 b2 seen n rc tlist
    e1="$(mkepic "epic one")"
    e2="$(mkepic "epic two")"
    b1="$(mkbead "$e1" "one slice" "edit one.txt")"
    b2="$(mkbead "$e2" "two slice" "edit two.txt")"
    seen="$(dispatch_ids)"
    tlist="$BATS_TEST_TMPDIR/terminals.json"

    "$RUN_SH" --epic "$e1" --epic "$e2" --agent bash \
        --from "$ORCA_COORD" --timeout-ms 30000 \
        >"$LOG" 2>"$ERR" </dev/null 3>&- &
    local pid=$!

    # Both panes are alive and unreleased at this point: that is when
    # `terminal list` can show two worktrees each with a live worker.
    wait_dispatches "$pid" 2 300 || true
    orca terminal list --json >"$tlist" 2>/dev/null

    # shellcheck disable=SC2086
    n="$(drive "$pid" 2 300 $seen)"
    [ "$n" -eq 2 ]
    wait_exit "$pid" 240; rc="$WAIT_RC"
    [ "$rc" -eq 0 ]

    [ "$(wave_beads 1)" = "$(sorted "$b1" "$b2")" ]

    local w1 w2 t1 t2
    w1="$(jq -r '.worktree_id' "$ODIR/epics/$e1.json")"
    w2="$(jq -r '.worktree_id' "$ODIR/epics/$e2.json")"
    [ -n "$w1" ] && [ "$w1" != "null" ]
    [ -n "$w2" ] && [ "$w2" != "null" ]
    [ "$w1" != "$w2" ]
    [ "$(jq -r '.worktree_path' "$ODIR/epics/$e1.json")" \
        != "$(jq -r '.worktree_path' "$ODIR/epics/$e2.json")" ]

    t1="$(events | jq -r --arg b "$b1" \
        'select(.event == "dispatch" and .bead == $b) | .terminal')"
    t2="$(events | jq -r --arg b "$b2" \
        'select(.event == "dispatch" and .bead == $b) | .terminal')"
    run jq -e --arg h "$t1" --arg w "$w1" \
        '[.result.terminals[] | select(.handle == $h and .worktreeId == $w)]
         | length == 1' "$tlist"
    [ "$status" -eq 0 ]
    run jq -e --arg h "$t2" --arg w "$w2" \
        '[.result.terminals[] | select(.handle == $h and .worktreeId == $w)]
         | length == 1' "$tlist"
    [ "$status" -eq 0 ]
}

@test "orca-run sends merge_ready when the last task of an epic settles" {
    local epic b1 b2 seen n rc
    epic="$(mkepic "merge epic")"
    b1="$(mkbead "$epic" "merge slice one" "edit mone.txt")"
    b2="$(mkbead "$epic" "merge slice two" "edit mtwo.txt")"
    seen="$(dispatch_ids)"

    "$RUN_SH" --epic "$epic" --agent bash --worktree "path:$ORCA_PROJ" \
        --from "$ORCA_COORD" --timeout-ms 30000 \
        >"$LOG" 2>"$ERR" </dev/null 3>&- &
    local pid=$!

    # shellcheck disable=SC2086
    n="$(drive "$pid" 2 300 $seen)"
    [ "$n" -eq 2 ]
    wait_exit "$pid" 180; rc="$WAIT_RC"
    [ "$rc" -eq 0 ]
    [ "$(count_events worker_done)" -eq 2 ]

    # The human line the orchestrator reads, with a branch on it.
    local ready branch
    ready="$(grep "^EPIC READY $epic " "$LOG" | head -1)"
    [ -n "$ready" ]
    branch="${ready#EPIC READY $epic }"
    [ -n "$branch" ]

    run jq -e --arg e "$epic" --arg br "$branch" \
        'select(.event == "epic_ready") | .epic == $e and .branch == $br' \
        <(events)
    [ "$status" -eq 0 ]

    # And the message really reached the Run mailbox, typed merge_ready.
    local rid
    rid="$(jq -r '.run_id' "$ODIR/run.json")"
    run jq -e --arg e "$epic" --arg br "$branch" '
        [.result.messages[] | select(.type == "merge_ready")
         | select(.subject | contains($e)) | select(.body == $br)]
        | length >= 1' \
        <(orca orchestration check --all --types merge_ready --run "$rid" \
            --terminal "$ORCA_COORD" --json 2>/dev/null)
    [ "$status" -eq 0 ]
}

@test "orca-run serializes beads whose contracts freeze the same file" {
    local epic s1 s2 d seen n rc contract first second
    contract="CHECK: bats tests/dup.bats
PASS-IF: zero not ok
FROZEN: scripts/shared.sh
CLASS: behavior"
    epic="$(mkepic "shared file epic")"
    s1="$(mkbead "$epic" "shared one" "rework the shared helper" "$contract")"
    s2="$(mkbead "$epic" "shared two" "rework the shared helper" "$contract")"
    d="$(mkbead "$epic" "disjoint" "edit docs/delta.md")"
    seen="$(dispatch_ids)"

    "$RUN_SH" --epic "$epic" --agent bash --worktree "path:$ORCA_PROJ" \
        --from "$ORCA_COORD" --timeout-ms 30000 \
        >"$LOG" 2>"$ERR" </dev/null 3>&- &
    local pid=$!

    # shellcheck disable=SC2086
    n="$(drive "$pid" 3 300 $seen)"
    [ "$n" -eq 3 ]
    wait_exit "$pid" 180; rc="$WAIT_RC"
    [ "$rc" -eq 0 ]
    [ "$(count_events dispatch)" -eq 3 ]

    # Wave 1 carries the disjoint bead and exactly ONE of the two beads
    # that freeze scripts/shared.sh -- overlap serializes, it does not
    # stall the rest of the wave.
    first="$(events | jq -r --arg d "$d" \
        'select(.event == "dispatch" and .wave == 1 and .bead != $d) | .bead')"
    [ "$first" = "$s1" ] || [ "$first" = "$s2" ]
    if [ "$first" = "$s1" ]; then second="$s2"; else second="$s1"; fi
    [ "$(wave_beads 1)" = "$(sorted "$d" "$first")" ]

    # The second one waited for the first to report, not merely for a wave.
    [ "$(pos "worker_done:$first")" -gt 0 ]
    [ "$(pos "dispatch:$second")" -gt "$(pos "worker_done:$first")" ]
}
