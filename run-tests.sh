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
        # smoke, experience, and multi-project run first (matching the
        # individual lane names above); the rest follow in the order below.
        # Suites are still spelled out here (not purely globbed) because
        # tests/start-professor.bats's wiring check reads this block's
        # literal text and expects every tests/*.bats basename to appear in
        # it -- but the loop below is the real drift guard: any tests/*.bats
        # file landing without this list being updated still runs, it's
        # just appended after the named ones. (beads_claude_docker-o1w)
        suites=(
            "$TEST_DIR/smoke.bats" "$TEST_DIR/experience.bats" "$TEST_DIR/multi-project.bats"
            "$TEST_DIR/bd-guard.bats" "$TEST_DIR/context-detect.bats" "$TEST_DIR/tier-hooks.bats"
            "$TEST_DIR/hook-staging.bats" "$TEST_DIR/delegation-gate.bats" "$TEST_DIR/image-drift.bats"
            "$TEST_DIR/acceptance-contracts.bats" "$TEST_DIR/agent-report-relay.bats" "$TEST_DIR/beads-resume.bats"
            "$TEST_DIR/code-map.bats" "$TEST_DIR/contract-gate.bats" "$TEST_DIR/lane.bats"
            "$TEST_DIR/start-professor.bats" "$TEST_DIR/statusline.bats" "$TEST_DIR/egress-firewall.bats"
            "$TEST_DIR/pin-currency.bats" "$TEST_DIR/plugin-build.bats" "$TEST_DIR/workflows.bats"
        )
        for f in "$TEST_DIR"/*.bats; do
            already_listed=false
            for s in "${suites[@]}"; do
                if [ "$s" = "$f" ]; then
                    already_listed=true
                    break
                fi
            done
            if [ "$already_listed" = false ]; then
                suites+=("$f")
            fi
        done
        bats "${suites[@]}"
        ;;
    *)
        echo "Usage: run-tests.sh [smoke|experience|multi-project|all]" >&2
        exit 1
        ;;
esac
