#!/usr/bin/env bash
#
# orca-claude-worker.sh -- the O5 proof (claude-orca-qa2.15, plan
# .claude/plans/orca-orchestration.md): a REAL bead handed from a
# coordinator terminal to a REAL Claude Code worker through orca-dispatch,
# the worker implements it and reports worker_done, and orca-wait ingests
# that report. Nothing here is stubbed -- every id in the assertions came
# out of a running Orca, and the Claude worker is a live subscription
# session inside an Orca PTY, signed in with this box's own credentials.
#
#   bash tests/e2e/orca-claude-worker.sh
#
# Prints PROOF PASS once the Claude worker's slice is done and verified on
# disk, then LAUNCH PASS once an opencode worker on an OpenRouter model has
# been launched and adopted. Exit 0 only when both printed.
#
# Not a bats file and not part of run-tests.sh: it costs real model tokens
# and up to ~25 minutes. It is run by hand, and its stdout is the evidence.
#
# Layout (short paths: AF_UNIX caps around 100 bytes and Orca binds its
# daemon socket under the user-data dir):
#   /tmp/oow-XXXXXX          the throwaway project, its own git repo + beads
#   /tmp/oow-XXXXXX/ud       Orca's user-data dir for THIS run only
#   /tmp/oow-XXXXXX/.claude-dev/home   the agent HOME the worker inherits
#
# Environment:
#   ORCA_APP        the Orca binary (default /opt/orca/orca-ide)
#   ORCA_CLI_BIN    the Orca CLI (default: orca-ide on PATH)
#   E2E_KEEP=1      leave the runtime up after the run (debugging)
#   E2E_DEADLINE_S  how long the Claude worker gets (default 1200 = 20 min)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORCA_APP="${ORCA_APP:-/opt/orca/orca-ide}"
CLI="${ORCA_CLI_BIN:-$(command -v orca-ide 2>/dev/null || true)}"
[ -n "$CLI" ] || CLI=/opt/orca/resources/bin/orca-ide
DEADLINE_S="${E2E_DEADLINE_S:-1200}"
WAIT_WINDOW_MS=120000

say()  { printf '\n=== %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
fail() {
    printf '\nPROOF FAIL: %s\n' "$*" >&2
    [ -n "${SERVE_LOG:-}" ] && [ -f "$SERVE_LOG" ] && {
        printf -- '--- tail %s\n' "$SERVE_LOG" >&2
        tail -20 "$SERVE_LOG" >&2
    }
    exit 1
}

need() { command -v "$1" >/dev/null 2>&1 || fail "$1 is required"; }
need jq; need bd; need git; need python3; need xvfb-run
[ -x "$ORCA_APP" ] || fail "no Orca binary at $ORCA_APP"
[ -x "$CLI" ] || fail "no Orca CLI at $CLI"
[ -f "$HOME/.claude/.credentials.json" ] ||
    fail "no Claude credentials at $HOME/.claude/.credentials.json to lend the worker"

PROJ="$(mktemp -d /tmp/oow-XXXXXX)" || fail "mktemp failed"
UD="$PROJ/ud"
AHOME="$PROJ/.claude-dev/home"
SERVE_LOG="$PROJ/.claude-dev/run/orca-serve.log"
EP_LOG="$PROJ/.claude-dev/entrypoint.log"
mkdir -p "$UD" "$AHOME/.claude" "$PROJ/.claude-dev/run"

SERVE_PGID=""
cleanup() {
    [ "${E2E_KEEP:-0}" = "1" ] && { info "E2E_KEEP=1: leaving $PROJ up"; return 0; }
    [ -n "$SERVE_PGID" ] && kill -TERM -"$SERVE_PGID" 2>/dev/null
    sleep 2
    [ -n "$SERVE_PGID" ] && kill -KILL -"$SERVE_PGID" 2>/dev/null
    # Orca's daemon is detached and outlives the serve's process group. The
    # token path matches THIS run's daemon only: other sessions on this box
    # have their own user-data dirs and must survive.
    pkill -f "daemon-v36.sock --token $UD/daemon" 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM

say "throwaway project at $PROJ"
(
    cd "$PROJ" || exit 1
    git init -q -b main .
    git config user.email orca-e2e@test
    git config user.name "orca e2e"
    echo "proof" > README.md
    git add -A
    git commit -qm init
    bd init --prefix proof >/dev/null 2>&1
) || fail "could not build the throwaway project"

mkbead() {
    ( cd "$PROJ" && bd create --title "$1" --description "$2" -t task -p 1 --json \
        2>/dev/null | jq -r 'if type == "array" then .[0].id else .id end' )
}
BEAD="$(mkbead "create hello.txt" \
"In this repository, create a file named hello.txt whose entire contents are the single word hello, then commit it with git. That is the whole slice.")"
[ -n "$BEAD" ] && [ "$BEAD" != "null" ] || fail "bd create produced no id"
BEAD2="$(mkbead "count the lines in README.md" \
"Report how many lines README.md has in this repository. Do not change any file.")"
[ -n "$BEAD2" ] && [ "$BEAD2" != "null" ] || fail "bd create produced no second id"
info "proof bead $BEAD, launch bead $BEAD2"

# The worker signs in as this box does: its own credentials and its own
# account, in the HOME the entrypoint is about to seed the trust and
# bypass-permissions keys into (claude-orca-qa2.17).
cp "$HOME/.claude/.credentials.json" "$AHOME/.claude/.credentials.json" ||
    fail "could not copy the Claude credentials"
chmod 600 "$AHOME/.claude/.credentials.json"
if [ -f "$HOME/.claude.json" ]; then
    jq '{oauthAccount, userID, hasCompletedOnboarding}' "$HOME/.claude.json" \
        > "$AHOME/.claude.json" 2>/dev/null || printf '{}\n' > "$AHOME/.claude.json"
fi

# Chromium on this GPU-less box loses its GPU process and then its network
# service within minutes unless everything stays in one process. The
# wrapper is also where xvfb lands: Orca's Electron main still wants an X
# display even in serve mode.
WRAP="$PROJ/orca-bin.sh"
cat > "$WRAP" <<EOF
#!/bin/sh
exec xvfb-run -a "$ORCA_APP" --in-process-gpu --no-zygote \\
    --disable-dev-shm-usage --disable-software-rasterizer "\$@"
EOF
chmod +x "$WRAP"

PORT="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"

say "starting the container entrypoint natively on port $PORT"
setsid env -u ORCA_TERMINAL_HANDLE -u ORCA_PANE_KEY \
    HOME="$AHOME" PROJECT_DIR="$PROJ" ORCA_PORT="$PORT" \
    ORCA_BIN="$WRAP" ORCA_CLI="$CLI" ORCA_USER_DATA_DIR="$UD" \
    CLAUDE_ORCA_SKIP_SETUP=1 CLAUDE_ORCA_SKIP_BEADS=1 \
    CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 CLAUDE_ORCA_WEBURL_TIMEOUT=300 \
    CLAUDE_ORCA_GIT_NAME="orca e2e" CLAUDE_ORCA_GIT_EMAIL="orca-e2e@test" \
    bash "$REPO_ROOT/scripts/container/entrypoint.sh" >"$EP_LOG" 2>&1 &
SERVE_PGID=$!

for i in $(seq 1 300); do
    grep -q "Orca server ready" "$SERVE_LOG" 2>/dev/null && break
    kill -0 "$SERVE_PGID" 2>/dev/null || break
    sleep 1
done
grep -q "Orca server ready" "$SERVE_LOG" 2>/dev/null ||
    fail "orca serve never became ready (entrypoint log: $EP_LOG)"

# The entrypoint's own handshake: the pairing URL first, then the one
# `orca repo add` that registers the folder. Both come after serve's
# "ready" line, so waiting on the log alone would race them.
for i in $(seq 1 120); do
    [ -s "$PROJ/.claude-dev/run/orca-web-url.txt" ] && break
    sleep 1
done
[ -s "$PROJ/.claude-dev/run/orca-web-url.txt" ] ||
    fail "no run/orca-web-url.txt (entrypoint log: $EP_LOG)"
info "serve ready; web url: $(cat "$PROJ/.claude-dev/run/orca-web-url.txt")"

export ORCA_USER_DATA_PATH="$UD"
export CLAUDE_ORCA_ROOT="$PROJ"
export ORCA_CLI_BIN="$CLI"
orca() { "$CLI" "$@" </dev/null 3>&-; }

# The entrypoint registers the project itself; the trust seed and this
# registration are exactly what a fresh folder gets on the Mac.
for i in $(seq 1 90); do
    grep -q "registering project with Orca" "$EP_LOG" && break
    sleep 1
done
grep -q "registering project with Orca" "$EP_LOG" ||
    fail "the entrypoint never ran repo add (log: $EP_LOG)"
grep -q "orca repo add failed" "$EP_LOG" "$SERVE_LOG" &&
    fail "the entrypoint's repo add failed -- see $SERVE_LOG"

say "coordinator terminal"
COORD="$(orca terminal create --worktree "path:$PROJ" --title coord \
    --command bash --json 2>/dev/null | jq -r '.result.terminal.handle // ""')"
[ -n "$COORD" ] && [ "$COORD" != "null" ] ||
    fail "could not create a coordinator terminal"
info "coordinator $COORD"

# --- the proof: a Claude worker does the slice ---------------------------

say "orca-dispatch $BEAD --agent claude --model sonnet"
DISP_OUT="$(bash "$REPO_ROOT/scripts/orca-dispatch.sh" "$BEAD" \
    --agent claude --model sonnet --worktree "path:$PROJ" --from "$COORD" \
    2>"$PROJ/dispatch.err")"
DISP_STATUS=$?
R1="$(printf '%s\n' "$DISP_OUT" | tail -1)"
printf '%s\n' "$R1"
[ "$DISP_STATUS" -eq 0 ] ||
    fail "orca-dispatch exited $DISP_STATUS: $(tail -3 "$PROJ/dispatch.err")"
printf '%s' "$R1" | jq -e '.agent == "claude" and .model == "sonnet"
    and (.dispatch_id | startswith("ctx_"))
    and (.terminal | startswith("term_"))' >/dev/null ||
    fail "the dispatch receipt is not a launched claude worker: $R1"
RID="$(printf '%s' "$R1" | jq -r .run_id)"
DID="$(printf '%s' "$R1" | jq -r .dispatch_id)"
WT="$(printf '%s' "$R1" | jq -r .terminal)"
info "run $RID dispatch $DID terminal $WT"

say "orca-wait, rolling windows, up to ${DEADLINE_S}s"
RECEIPTS="$PROJ/receipts.jsonl"
: > "$RECEIPTS"
START="$(date +%s)"
DONE=""
while [ "$(( $(date +%s) - START ))" -lt "$DEADLINE_S" ]; do
    bash "$REPO_ROOT/scripts/orca-wait.sh" --timeout-ms "$WAIT_WINDOW_MS" \
        --from "$COORD" 2>>"$PROJ/wait.err" >>"$RECEIPTS"
    DONE="$(jq -c -s --arg d "$DID" \
        '[.[] | select(.type == "worker_done" and .dispatch_id == $d)][0] // empty' \
        "$RECEIPTS" 2>/dev/null)"
    [ -n "$DONE" ] && break
    info "still waiting ($(( $(date +%s) - START ))s elapsed)"
done
ELAPSED="$(( $(date +%s) - START ))"
[ -n "$DONE" ] || {
    printf -- '--- worker terminal:\n'
    orca terminal read --terminal "$WT" --json 2>/dev/null |
        jq -r '.result.content // .result.text // ""' | tail -40
    fail "no worker_done for $DID within ${ELAPSED}s"
}

say "worker_done after ${ELAPSED}s"
printf '%s\n' "$DONE" | jq .
printf '%s' "$DONE" | jq -e '.outcome == "succeeded"' >/dev/null ||
    fail "the worker reported outcome $(printf '%s' "$DONE" | jq -r .outcome)"
printf '%s' "$DONE" | jq -e --arg b "$BEAD" '.bead == $b' >/dev/null ||
    fail "the worker_done was not attributed to $BEAD"

# The slice itself, on disk, in the project the worker was given.
[ -f "$PROJ/hello.txt" ] || fail "the worker did not create hello.txt"
CONTENT="$(tr -d '[:space:]' < "$PROJ/hello.txt")"
[ "$CONTENT" = "hello" ] || fail "hello.txt says '$CONTENT', not 'hello'"
git -C "$PROJ" log --oneline -- hello.txt | grep -q . ||
    fail "hello.txt was never committed"
info "hello.txt: $(cat "$PROJ/hello.txt")"
info "commit: $(git -C "$PROJ" log --oneline -1 -- hello.txt)"

# And the record the orchestrator reads later: the bead carries it.
NOTES="$(cd "$PROJ" && bd show "$BEAD" --json 2>/dev/null | jq -r '.[0].notes // ""')"
case "$NOTES" in
    *"$DID"*) : ;;
    *) fail "the bead never recorded dispatch $DID" ;;
esac
case "$NOTES" in
    *succeeded*) : ;;
    *) fail "the bead never recorded the worker_done outcome" ;;
esac

printf '\nPROOF PASS: %s -> claude/sonnet worker -> worker_done succeeded in %ss\n' \
    "$BEAD" "$ELAPSED"

# --- the launch: an opencode worker on an OpenRouter model ---------------

say "orca-dispatch $BEAD2 --agent opencode --model openrouter/qwen/qwen3-coder"
DISP2="$(bash "$REPO_ROOT/scripts/orca-dispatch.sh" "$BEAD2" \
    --agent opencode --model openrouter/qwen/qwen3-coder \
    --worktree "path:$PROJ" --from "$COORD" 2>"$PROJ/dispatch2.err")"
DISP2_STATUS=$?
R2="$(printf '%s\n' "$DISP2" | tail -1)"
printf '%s\n' "$R2"
[ "$DISP2_STATUS" -eq 0 ] ||
    fail "orca-dispatch (opencode) exited $DISP2_STATUS: $(tail -3 "$PROJ/dispatch2.err")"
printf '%s' "$R2" | jq -e '.agent == "opencode"
    and .model == "openrouter/qwen/qwen3-coder"
    and .command == "opencode --model openrouter/qwen/qwen3-coder"
    and (.dispatch_id | startswith("ctx_"))
    and (.terminal | startswith("term_"))' >/dev/null ||
    fail "the opencode dispatch receipt is wrong: $R2"
DID2="$(printf '%s' "$R2" | jq -r .dispatch_id)"
WT2="$(printf '%s' "$R2" | jq -r .terminal)"

# That command line is really running, in THIS project -- the cwd check is
# what keeps another session's opencode on this box out of the assertion.
SEEN=0
for i in $(seq 1 60); do
    for pid in $(pgrep -f 'opencode --model openrouter/qwen/qwen3-coder' 2>/dev/null); do
        if [ "$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" = "$PROJ" ]; then
            SEEN=1
            info "opencode pid $pid: $(tr '\0' ' ' < "/proc/$pid/cmdline")"
            break
        fi
    done
    [ "$SEEN" -eq 1 ] && break
    sleep 1
done
[ "$SEEN" -eq 1 ] || fail "no opencode process on that model in $PROJ"

# worker-start --terminal adopted that terminal as this Task's worker.
orca orchestration worker-list --run "$RID" --json 2>/dev/null |
    jq -e --arg d "$DID2" --arg w "$WT2" \
    '[.result.workers[] | select(.dispatchId == $d and .agentTerminalHandle == $w)]
     | length == 1' >/dev/null ||
    fail "the runtime did not adopt $WT2 as the worker for $DID2"

printf '\nLAUNCH PASS: %s -> opencode on openrouter/qwen/qwen3-coder, adopted as %s\n' \
    "$BEAD2" "$DID2"
printf 'project: %s\n' "$PROJ"
exit 0
