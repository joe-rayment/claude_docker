#!/bin/bash

# Test runner for Claude Dev container experience tests
# Usage: run-tests.sh [smoke|experience|multi-project|all]

set -e

# Default: the image-baked copies. When iterating on the template itself,
# point at the live sources: CLAUDE_DEV_TESTS=/workspace/tests run-tests.sh
TEST_DIR="${CLAUDE_DEV_TESTS:-/opt/claude-dev/tests}"
SUITE="${1:-all}"

if ! command -v bats &>/dev/null; then
    echo "Error: bats not found. Are you inside the container?" >&2
    exit 1
fi

if [ ! -d "$TEST_DIR" ]; then
    echo "Error: Test directory $TEST_DIR not found." >&2
    exit 1
fi

case "$SUITE" in
    smoke)
        echo "Running smoke tests..."
        bats "$TEST_DIR/smoke.bats"
        ;;
    experience)
        echo "Running experience tests..."
        bats "$TEST_DIR/experience.bats"
        ;;
    multi-project)
        echo "Running multi-project isolation tests..."
        bats "$TEST_DIR/multi-project.bats"
        ;;
    all)
        echo "Running all tests..."
        bats "$TEST_DIR/smoke.bats" "$TEST_DIR/experience.bats" "$TEST_DIR/multi-project.bats" \
             "$TEST_DIR/bd-guard.bats" "$TEST_DIR/context-detect.bats" "$TEST_DIR/tier-hooks.bats" \
             "$TEST_DIR/hook-staging.bats" "$TEST_DIR/delegation-gate.bats" "$TEST_DIR/image-drift.bats" \
             "$TEST_DIR/acceptance-contracts.bats" "$TEST_DIR/agent-report-relay.bats" "$TEST_DIR/beads-resume.bats" \
             "$TEST_DIR/code-map.bats" "$TEST_DIR/contract-gate.bats" "$TEST_DIR/lane.bats" \
             "$TEST_DIR/start-professor.bats" "$TEST_DIR/statusline.bats"
        ;;
    *)
        echo "Usage: run-tests.sh [smoke|experience|multi-project|all]" >&2
        exit 1
        ;;
esac
