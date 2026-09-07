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

# macOS ships bash 3.2 and bats inherits it -- and under 3.2 a failing
# `[[ ... ]]` (and a failing `! cmd`) does NOT trip errexit: the test body
# carries on and the test passes. Measured on a Mac on 2026-09-07: of the
# five assertion forms this suite uses, `[ ]`, `grep -q` and a function
# call fail the test as intended, while `[[ ]]` and `!` are ignored unless
# they happen to be the last command in the body. A suite that is mostly
# `[[ ]]` is therefore mostly decorative on the one platform this template
# ships for. So: run bats under a bash 4+ if the box has one, and say so
# plainly if it does not.
BATS_BIN="$(command -v bats)"
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    NEWER_BASH=""
    # CLAUDE_ORCA_BATS_BASH first so the re-exec below is exercisable on a
    # box that has only bash 3.2 (which is every stock Mac).
    for candidate in "${CLAUDE_ORCA_BATS_BASH:-}" \
                     /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash; do
        if [ -x "$candidate" ] \
           && [ "$("$candidate" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ]; then
            NEWER_BASH="$candidate"
            break
        fi
    done
    if [ -n "$NEWER_BASH" ]; then
        echo "==> bash ${BASH_VERSION%%(*} ignores failing [[ ]] assertions; running bats under $NEWER_BASH"
        # PATH, not just the interpreter: bats re-execs itself as
        # `bats-exec-suite` and `bats-exec-file`, both `#!/usr/bin/env
        # bash`, so naming the interpreter here would move THIS process to
        # bash 4+ and leave every test body back on 3.2 -- a guard that
        # reports the hole closed while it is open.
        exec env PATH="$(dirname "$NEWER_BASH"):$PATH" \
            "$NEWER_BASH" "$BATS_BIN" "$TEST_DIR"/*.bats
    fi
    echo "WARNING: this is bash ${BASH_VERSION%%(*}, where a failing '[[ ]]' or" >&2
    echo "         '!' assertion does not fail its test. Much of this suite is" >&2
    echo "         written that way, so a green run here proves less than it" >&2
    echo "         looks like. Install a newer bash (brew install bash) to get" >&2
    echo "         the assertions back." >&2
fi

bats "$TEST_DIR"/*.bats
