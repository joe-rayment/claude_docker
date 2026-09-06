#!/usr/bin/env bats
#
# orca-dispatch / orca-wait against a REAL Orca runtime (claude-orca-qa2.13,
# plan .claude/plans/orca-orchestration.md "The orchestrator's tools").
#
# setup_file boots one headless `orca-ide --serve` under xvfb-run against a
# throwaway git project with its own beads database, adds the repo and
# creates one coordinator bash terminal whose handle every test passes as
# --from. teardown_file kills only the session it started. Nothing here
# stubs the CLI: every id in the assertions came out of the running runtime.
#
# Unix domain socket paths cap out around 100 chars, so the user-data dir is
# /tmp/oo-XXXXXX and the project /tmp/op-XXXXXX -- never BATS_TMPDIR, which
# is long enough to break the runtime handshake.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

setup_file() {
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
        bd init --prefix probe >/dev/null 2>&1
    ) || skip "could not build the throwaway project"

    local bead
    bead="$(cd "$proj" && bd create --title "probe slice" \
        --description "implement the probe slice" -t task -p 1 --json \
        2>/dev/null | jq -r 'if type == "array" then .[0].id else .id end')"
    [ -n "$bead" ] && [ "$bead" != "null" ] || skip "bd create produced no id"

    mkdir -p "$proj/.claude-dev/run"

    port="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"

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
    "$cli" repo add --path "$proj" --json >/dev/null 2>&1

    local coord
    coord="$("$cli" terminal create --worktree "path:$proj" --title coord \
        --command bash --json 2>/dev/null | jq -r '.result.terminal.handle')"
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
        echo "ORCA_BEAD=$bead"
    } >"$BATS_FILE_TMPDIR/env"
}

teardown_file() {
    [ -f "$BATS_FILE_TMPDIR/env" ] || return 0
    # shellcheck disable=SC1091
    . "$BATS_FILE_TMPDIR/env"
    [ -n "${ORCA_SERVE_PID:-}" ] && kill -TERM -"$ORCA_SERVE_PID" 2>/dev/null
    sleep 1
    [ -n "${ORCA_SERVE_PID:-}" ] && kill -KILL -"$ORCA_SERVE_PID" 2>/dev/null
    # Orca's daemon is spawned detached, outlives the serve's session group
    # while worker terminals are alive, and holds whatever descriptors it
    # inherited -- including bats' own stdin, which is why bats would never
    # see EOF and never exit. The token path matches only this run's daemon.
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
    DISPATCH="$REPO_ROOT/scripts/orca-dispatch.sh"
    WAIT="$REPO_ROOT/scripts/orca-wait.sh"
    RUN_FILE="$ORCA_PROJ/.claude-dev/run/orchestration/run.json"
}

# The receipt is the LAST stdout line (human notes go to stderr).
receipt() { printf '%s\n' "$1" | tail -1; }

orca() { "$ORCA_CLI" "$@"; }

@test "orca-dispatch creates one Run per coordinator, a Task from the bead, and dispatches a bash worker that reports worker_done which orca-wait ingests and releases" {
    run --separate-stderr "$DISPATCH" "$ORCA_BEAD" --agent bash \
        --worktree "path:$ORCA_PROJ" --from "$ORCA_COORD"
    [ "$status" -eq 0 ]
    local r1
    r1="$(receipt "$output")"
    run jq -e --arg b "$ORCA_BEAD" '
        .bead == $b and (.run_id | startswith("run_"))
        and (.task_id | startswith("task_"))
        and (.dispatch_id | startswith("ctx_"))
        and (.terminal | startswith("term_")) and .agent == "bash"' <<<"$r1"
    [ "$status" -eq 0 ]

    local rid tid did wt
    rid="$(jq -r .run_id <<<"$r1")"
    tid="$(jq -r .task_id <<<"$r1")"
    did="$(jq -r .dispatch_id <<<"$r1")"
    wt="$(jq -r .terminal <<<"$r1")"

    [ -f "$RUN_FILE" ]
    run jq -e --arg r "$rid" --arg c "$ORCA_COORD" \
        '.run_id == $r and .coordinator_handle == $c' "$RUN_FILE"
    [ "$status" -eq 0 ]

    # The Task spec is composed from the bead and ends with the worker rules.
    local spec
    spec="$(orca orchestration task-list --run "$rid" --json 2>/dev/null |
        jq -r --arg t "$tid" '.result.tasks[] | select(.id == $t) | .spec')"
    [[ "$spec" == *"probe slice"* ]]
    [[ "$spec" == *"implement the probe slice"* ]]
    [[ "$spec" == *"WORKER RULES"* ]]
    [[ "$spec" == *"do not close"* ]]
    [[ "$spec" == *"worker_done"* ]]

    # One Run per coordinator: a second dispatch reuses it, with a new Task.
    run --separate-stderr "$DISPATCH" "$ORCA_BEAD" --agent bash \
        --worktree "path:$ORCA_PROJ" --from "$ORCA_COORD"
    [ "$status" -eq 0 ]
    local r2
    r2="$(receipt "$output")"
    run jq -e --arg r "$rid" --arg t "$tid" \
        '.run_id == $r and .task_id != $t' <<<"$r2"
    [ "$status" -eq 0 ]

    # The bash worker reports for itself, from its own terminal.
    orca terminal send --terminal "$wt" --enter --json --text \
        "orca-ide orchestration send --type worker_done --subject done --body ok --task-id $tid --dispatch-id $did --outcome succeeded --files-modified README.md --json" \
        >/dev/null 2>&1

    run --separate-stderr "$WAIT" --timeout-ms 60000
    [ "$status" -eq 0 ]
    local w
    w="$(receipt "$output")"
    run jq -e --arg t "$tid" --arg d "$did" --arg b "$ORCA_BEAD" '
        .type == "worker_done" and .outcome == "succeeded"
        and .task_id == $t and .dispatch_id == $d and .bead == $b
        and (.files | index("README.md")) != null
        and .released == true' <<<"$w"
    [ "$status" -eq 0 ]

    local notes
    notes="$(cd "$ORCA_PROJ" && bd show "$ORCA_BEAD" --json 2>/dev/null |
        jq -r '.[0].notes // ""')"
    [[ "$notes" == *"$tid"* ]]
    [[ "$notes" == *"$did"* ]]
    [[ "$notes" == *"succeeded"* ]]

    run jq -e --arg d "$did" '[.result.workers[] | select(.dispatchId == $d)]
        | length == 1 and (.[0].dispatchStatus == "completed")' \
        <(orca orchestration worker-list --run "$rid" --json 2>/dev/null)
    [ "$status" -eq 0 ]
}

@test "orca-dispatch starts an opencode worker with --model openrouter/ and adopts it as a supervised worker" {
    command -v opencode >/dev/null 2>&1 || skip "opencode is not installed"

    run --separate-stderr "$DISPATCH" "$ORCA_BEAD" --agent opencode \
        --model openrouter/qwen/qwen3-coder --worktree "path:$ORCA_PROJ" \
        --from "$ORCA_COORD"
    [ "$status" -eq 0 ]
    local r
    r="$(receipt "$output")"
    run jq -e '.agent == "opencode" and .model == "openrouter/qwen/qwen3-coder"
        and (.dispatch_id | startswith("ctx_"))
        and (.terminal | startswith("term_"))' <<<"$r"
    [ "$status" -eq 0 ]

    # The terminal really runs opencode bound to the OpenRouter model.
    local i seen=0
    for i in $(seq 1 30); do
        if ps -eo args | grep -F -- "opencode --model openrouter/" |
                grep -qv grep; then seen=1; break; fi
        sleep 1
    done
    [ "$seen" -eq 1 ]

    # worker-start --terminal adopted that terminal as this task's worker.
    local rid did wt
    rid="$(jq -r .run_id <<<"$r")"
    did="$(jq -r .dispatch_id <<<"$r")"
    wt="$(jq -r .terminal <<<"$r")"
    run jq -e --arg d "$did" --arg w "$wt" \
        '[.result.workers[] | select(.dispatchId == $d and .agentTerminalHandle == $w)] | length == 1' \
        <(orca orchestration worker-list --run "$rid" --json 2>/dev/null)
    [ "$status" -eq 0 ]
}

@test "orca-dispatch starts a claude worker through worker-start --agent claude --model" {
    run --separate-stderr "$DISPATCH" "$ORCA_BEAD" --agent claude \
        --model sonnet --worktree "path:$ORCA_PROJ" --from "$ORCA_COORD"
    [ "$status" -eq 0 ]
    local r
    r="$(receipt "$output")"
    run jq -e '.agent == "claude" and .model == "sonnet"
        and .backend == "orca"
        and (.dispatch_id | startswith("ctx_"))
        and (.terminal | startswith("term_"))' <<<"$r"
    [ "$status" -eq 0 ]

    local rid did wt
    rid="$(jq -r .run_id <<<"$r")"
    did="$(jq -r .dispatch_id <<<"$r")"
    wt="$(jq -r .terminal <<<"$r")"
    run jq -e --arg d "$did" --arg w "$wt" \
        '[.result.workers[] | select(.dispatchId == $d and .agentTerminalHandle == $w)] | length == 1' \
        <(orca orchestration worker-list --run "$rid" --json 2>/dev/null)
    [ "$status" -eq 0 ]
}

@test "orca-dispatch exits 3 with the Agent-tool fallback spec when the runtime is unreachable" {
    local empty="$BATS_TEST_TMPDIR/no-runtime"
    mkdir -p "$empty"
    run --separate-stderr env ORCA_USER_DATA_PATH="$empty" \
        "$DISPATCH" "$ORCA_BEAD" --agent claude --model sonnet \
        --worktree "path:$ORCA_PROJ"
    [ "$status" -eq 3 ]
    [[ "$output" == *"SUBAGENT FALLBACK: spawn Agent(subagent_type=executor"* ]]
    [[ "$output" == *"model=sonnet"* ]]
    [[ "$output" == *"probe slice"* ]]
    [[ "$output" == *"implement the probe slice"* ]]
    [[ "$output" == *"WORKER RULES"* ]]
}
