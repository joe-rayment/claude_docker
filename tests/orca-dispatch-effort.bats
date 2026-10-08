#!/usr/bin/env bats
#
# orca-dispatch carries a role's reasoning effort to a Claude worker through
# worker-start --effort, on Claude's own scale. The runtime is the stub in
# tests/helpers/orca-stub.bash.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
DISPATCH="$REPO_ROOT/scripts/orca-dispatch.sh"

setup() {
    . "$BATS_TEST_DIRNAME/helpers/orca-stub.bash"
    orca_stub_init
    export CLAUDE_ORCA_ROOT="$BATS_TEST_TMPDIR/root"
    export TIER_STATE_FILE="$BATS_TEST_TMPDIR/no-such-tier.json"
    export CLAUDE_ORCA_DISPATCH_STAGGER_MS=0
    mkdir -p "$CLAUDE_ORCA_ROOT/.claude-dev/run/orchestration/dispatch"
    orca_stub_reply orchestration-run-create \
        '{"ok":true,"result":{"run":{"id":"run1","coordinator_handle":"term_coord"}}}'
    orca_stub_reply orchestration-task-create \
        '{"ok":true,"result":{"task":{"id":"t1"}}}'
    orca_stub_reply orchestration-worker-start \
        '{"ok":true,"result":{"dispatchId":"d1","state":"running",
          "effects":[{"kind":"terminal","id":"term_w1"}],
          "launch":{"effective":{"agent":"claude","model":"sonnet"}}}}'
}

@test "a Claude worker's effort reaches worker-start as --effort, minimal read as low" {
    # Guards: /tier ... sonnet@<effort> on an orca Claude worker is not
    #   dropped -- worker-start gets --effort, mapped onto Claude's scale.
    # Fails if: orca-dispatch stops passing --effort, or passes "minimal".
    # Run: bats tests/orca-dispatch-effort.bats
    run "$DISPATCH" b1 --worker --agent claude --model sonnet --variant minimal
    [ "$status" -eq 0 ]
    orca_stub_calls 'worker-start' | grep -q -F -e '--effort low'

    run "$DISPATCH" b2 --worker --agent claude --model sonnet
    [ "$status" -eq 0 ]
    ! orca_stub_calls 'worker-start' | tail -1 | grep -q -F -e '--effort'
}
