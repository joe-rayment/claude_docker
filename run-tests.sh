#!/bin/bash

# Test runner for Claude Dev container experience tests
# Usage: run-tests.sh [smoke|experience|multi-project|all]

set -e

TEST_DIR="/opt/claude-dev/tests"
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
        bats "$TEST_DIR/smoke.bats" "$TEST_DIR/experience.bats" "$TEST_DIR/multi-project.bats"
        ;;
    *)
        echo "Usage: run-tests.sh [smoke|experience|multi-project|all]" >&2
        exit 1
        ;;
esac
