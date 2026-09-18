#!/usr/bin/env bats
#
# orca-spool-detach.bats -- the mg8 regression (claude-orca-csh): the real
# mailbox spooler that orca-dispatch starts must neither hold the caller's
# descriptors (bats-core waits on fd 3, so a spooler that inherits it keeps
# the whole test run open) nor outlive its Run's dispatch dir.
#
# FROZEN from RED-AT onward.
#
#   case 1  orca-dispatch under the stub with the stub's no-op spool shim
#           unset takes the REAL launch path: a spooler starts, and once
#           the test root is removed it is gone within seconds -- and the
#           test returns, because nothing holds fd 3 (run this file under
#           `timeout 60`; a leaked descriptor shows up as a hang).
#   case 2  a spooler whose dispatch dir is deleted exits within 5 s.
#   case 3  with the stub's spool shim, orca-dispatch starts no real
#           spooler process at all.
#
# Every test scopes its spoolers to its own --from handle, so the pgrep
# assertions and the teardown can never touch a real spooler of a live Run
# outside the test.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
WAIT="$REPO_ROOT/scripts/orca-wait.sh"
DISPATCH="$REPO_ROOT/scripts/orca-dispatch.sh"

setup() {
    # shellcheck source=helpers/orca-stub.bash
    . "$BATS_TEST_DIRNAME/helpers/orca-stub.bash"
    orca_stub_init

    export CLAUDE_ORCA_ROOT="$BATS_TEST_TMPDIR/root"
    export TIER_STATE_FILE="$BATS_TEST_TMPDIR/no-such-tier.json"
    export CLAUDE_ORCA_DISPATCH_STAGGER_MS=0
    export CLAUDE_ORCA_WAIT_POLL_S=1
    ODIR="$CLAUDE_ORCA_ROOT/.claude-dev/run/orchestration"
    mkdir -p "$ODIR/dispatch"
    printf '%s\n' '{"run_id":"run1","coordinator_handle":"term_coord"}' \
        >"$ODIR/run.json"
    orca_stub_reply orchestration-run-create \
        '{"ok":true,"result":{"run":{"id":"run1","coordinator_handle":"term_coord"}}}'
    orca_stub_reply orchestration-task-create \
        '{"ok":true,"result":{"task":{"id":"t1"}}}'
    orca_stub_reply orchestration-worker-start \
        '{"ok":true,"result":{"dispatchId":"d1","state":"dispatched",
          "effects":[{"kind":"terminal","id":"term_w1"}],
          "launch":{"effective":{"agent":"claude","model":"sonnet"}}}}'
    orca_stub_reply orchestration-check \
        '{"ok":true,"result":{"count":0,"messages":[],"deliveryId":""}}'
    NOW="$(date +%s)"
}

teardown() {
    # scoped to the per-test handles: a real spooler of a live Run outside
    # the test never matches these
    pkill -f 'orca-wait.sh --spool --from term_spool1' 2>/dev/null || true
    pkill -f 'orca-wait.sh --spool --from term_spool2' 2>/dev/null || true
    pkill -f 'orca-wait.sh --spool --from term_spool3' 2>/dev/null || true
}

# spool_pid_gone <pattern> [<deadline_s>] -- return 1 when a process
# matching <pattern> is still alive after <deadline_s> seconds.
spool_pid_gone() {
    local pattern="$1" deadline=$(( $(date +%s) + ${2:-5} ))
    while pgrep -f "$pattern" >/dev/null 2>&1; do
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 0.2
    done
    return 0
}

@test "case 1: orca-dispatch with the stub shim unset starts a real spooler that exits once the test root is removed" {
    unset CLAUDE_ORCA_SPOOL_CMD
    if command -v timeout >/dev/null 2>&1; then
        run timeout 60 "$DISPATCH" b1 --agent claude --model sonnet \
            --worktree "path:$CLAUDE_ORCA_ROOT" --from term_spool1
    else
        run "$DISPATCH" b1 --agent claude --model sonnet \
            --worktree "path:$CLAUDE_ORCA_ROOT" --from term_spool1
    fi
    [ "$status" -eq 0 ]

    # a real spooler for this handle came up
    deadline=$(( $(date +%s) + 10 ))
    until pgrep -f 'orca-wait.sh --spool --from term_spool1' >/dev/null 2>&1; do
        [ "$(date +%s)" -lt "$deadline" ] ||
            fail "orca-dispatch started no real spooler"
        sleep 0.2
    done

    # removing the test root removes the spooler's dispatch dir: it must
    # exit at once instead of looping forever, reparented to init
    rm -rf "$CLAUDE_ORCA_ROOT"
    run spool_pid_gone 'orca-wait.sh --spool --from term_spool1' 5
    [ "$status" -eq 0 ]
}

@test "case 2: a spooler whose dispatch dir is deleted exits within 5 s" {
    orca_stub_dispatch_record "$CLAUDE_ORCA_ROOT" s2 "$(jq -n -c \
        --argjson s "$((NOW - 1))" \
        '{bead:"b1", dispatch_id:"s2", task_id:"t1", terminal:"term_s2",
          state:"running", started_at:$s, worktree_path:""}')"
    "$WAIT" --spool --from term_spool2 --poll 1 --stall-after 60 \
        </dev/null >/dev/null 2>&1 &
    spid=$!
    kill -0 "$spid" 2>/dev/null || fail "spooler did not start"

    rm -rf "$ODIR/dispatch"
    deadline=$(( $(date +%s) + 5 ))
    while kill -0 "$spid" 2>/dev/null; do
        [ "$(date +%s)" -lt "$deadline" ] ||
            fail "spooler still alive 5 s after its dispatch dir was deleted"
        sleep 0.2
    done
}

@test "case 3: with the stub's spool shim, orca-dispatch starts no real spooler process at all" {
    if command -v timeout >/dev/null 2>&1; then
        run timeout 60 "$DISPATCH" b1 --agent claude --model sonnet \
            --worktree "path:$CLAUDE_ORCA_ROOT" --from term_spool3
    else
        run "$DISPATCH" b1 --agent claude --model sonnet \
            --worktree "path:$CLAUDE_ORCA_ROOT" --from term_spool3
    fi
    [ "$status" -eq 0 ]

    # the no-op shim is what orca-dispatch launched
    [ -s "$ORCA_STUB_DIR/spool-shim.log" ]
    # and no real spooler process exists for this handle
    if pgrep -f 'orca-wait.sh --spool --from term_spool3' >/dev/null 2>&1; then
        fail "orca-dispatch started a real spooler under the stub"
    fi
}
