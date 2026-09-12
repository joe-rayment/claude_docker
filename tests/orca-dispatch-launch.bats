#!/usr/bin/env bats
#
# orca-dispatch's launch path: worktree naming, launch diagnostics and the
# fan-out stagger (claude-orca-8a0.1, slice A of claude-orca-8a0).
#
# FROZEN from RED-AT onward. The runtime here is the stub in
# tests/helpers/orca-stub.bash -- tests/orca-dispatch.bats is the one that
# drives a real xvfb'd Orca, and it is not part of this contract.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
DISPATCH="$REPO_ROOT/scripts/orca-dispatch.sh"

setup() {
    # shellcheck source=helpers/orca-stub.bash
    . "$BATS_TEST_DIRNAME/helpers/orca-stub.bash"
    orca_stub_init

    export CLAUDE_ORCA_ROOT="$BATS_TEST_TMPDIR/root"
    export TIER_STATE_FILE="$BATS_TEST_TMPDIR/no-such-tier.json"
    export CLAUDE_ORCA_DISPATCH_STAGGER_MS=0
    ODIR="$CLAUDE_ORCA_ROOT/.claude-dev/run/orchestration"
    mkdir -p "$ODIR/dispatch"

    orca_stub_reply orchestration-run-create \
        '{"ok":true,"result":{"run":{"id":"run1","coordinator_handle":"term_coord"}}}'
    orca_stub_reply orchestration-task-create \
        '{"ok":true,"result":{"task":{"id":"t1"}}}'
    orca_stub_reply orchestration-worker-start \
        '{"ok":true,"result":{"dispatchId":"d1","state":"running",
          "effects":[{"kind":"terminal","id":"term_w1"}],
          "worktree":{"path":"/tmp/wt-child-b1"},
          "launch":{"effective":{"agent":"claude","model":"sonnet"}}}}'
    NOW="$(date +%s)"
}

@test "orca-dispatch names a new-child worktree after the bead" {
    run "$DISPATCH" b1 --worker --agent claude --model sonnet --worktree new-child
    [ "$status" -eq 0 ]

    starts="$(orca_stub_calls 'worker-start')"
    [ -n "$starts" ]
    printf '%s\n' "$starts" | grep -q -F -e '--name wt/b1'

    rec="$ODIR/dispatch/d1.json"
    [ -f "$rec" ]
    run jq -e '.worktree_path == "/tmp/wt-child-b1"' "$rec"
    [ "$status" -eq 0 ]
    run jq -e --argjson n "$NOW" '.started_at >= ($n - 5)' "$rec"
    [ "$status" -eq 0 ]
}

@test "orca-dispatch reports the terminal tail and exits 3 with the fallback spec when the launch fails" {
    orca_stub_reply orchestration-worker-start \
        '{"ok":false,"error":{"code":"launch_failed","message":"agent never took the prompt"},
          "result":{"dispatchId":"df1","state":"failed",
          "effects":[{"kind":"terminal","id":"term_f1"}]}}'
    orca_stub_reply terminal-read \
        '{"ok":true,"result":{"terminal":{"lines":[
          "WARNING: Claude Code running in Bypass Permissions mode",
          "https://code.claude.com/docs/en/security",
          "",
          "agent@box:/workspace$"]}}}'

    run --separate-stderr "$DISPATCH" b1 --worker --agent claude --model sonnet
    [ "$status" -eq 3 ]

    # the Agent-tool fallback is on stdout, the same contract the
    # unreachable-runtime path already has
    printf '%s\n' "$output" | grep -q -F -e 'SUBAGENT FALLBACK'
    printf '%s\n' "$output" | grep -q -F -e 'WORKER RULES'

    # the receipt, with the reason, is on stderr
    line="$(printf '%s\n' "$stderr" | grep -e '"reason"' | head -1)"
    [ -n "$line" ]
    run jq -e '.state == "failed" and .terminal == "term_f1"' <<<"$line"
    [ "$status" -eq 0 ]
    run jq -e '.reason == "agent@box:/workspace$"' <<<"$line"
    [ "$status" -eq 0 ]

    # the terminal was read, and its tail stored on the record
    reads="$(orca_stub_calls 'terminal read')"
    printf '%s\n' "$reads" | grep -q -F -e '--terminal term_f1'
    rec="$ODIR/dispatch/df1.json"
    [ -f "$rec" ]
    run jq -e '(.launch_tail | length) == 3' "$rec"
    [ "$status" -eq 0 ]
    run jq -e '.launch_tail[0] | test("Bypass Permissions mode")' "$rec"
    [ "$status" -eq 0 ]
    run jq -e '.launch_tail[-1] == "agent@box:/workspace$"' "$rec"
    [ "$status" -eq 0 ]
}

@test "orca-dispatch staggers a dispatch that follows another within the stagger window" {
    orca_stub_dispatch_record "$CLAUDE_ORCA_ROOT" d0 \
        '{"bead":"b0","dispatch_id":"d0","state":"running"}'
    export CLAUDE_ORCA_DISPATCH_STAGGER_MS=2000

    t0="$(date +%s)"
    run --separate-stderr "$DISPATCH" b1 --worker --agent claude --model sonnet
    t1="$(date +%s)"
    [ "$status" -eq 0 ]
    [ "$((t1 - t0))" -ge 1 ]
    printf '%s\n' "$stderr" | grep -q -F -e 'stagger'
}
