#!/usr/bin/env bash
#
# run-tests.sh -- runs every tests/*.bats suite in this repo (S7, claude-
# orca-3sk.7). The old template's runner split smoke/experience/multi-
# project into their own lanes and pointed a TEST_DIR indirection at the
# image-baked copies (vs. the working tree during development); neither
# applies here -- there is no baked image, and every suite lives at
# tests/*.bats in the checkout being tested.

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$REPO_ROOT/tests"

if ! command -v bats >/dev/null 2>&1; then
    echo "Error: bats not found." >&2
    exit 1
fi

if [ ! -d "$TEST_DIR" ]; then
    echo "Error: test directory $TEST_DIR not found." >&2
    exit 1
fi

bats "$TEST_DIR"/*.bats
