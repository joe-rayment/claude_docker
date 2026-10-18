#!/usr/bin/env bash
#
# run-tests.sh -- runs the tests/*.bats suites in this repo (S7, claude-
# orca-3sk.7). The old template's runner split smoke/experience/multi-
# project into their own lanes and pointed a TEST_DIR indirection at the
# image-baked copies (vs. the working tree during development); neither
# applies here -- there is no baked image, and every suite lives at
# tests/*.bats in the checkout being tested.
#
# SIZED, PER ~/.claude/TESTING.md (config/testing-standard.md). Every test
# is small, medium or large, by what it is allowed to do: small touches only
# its own temp files and the programs it waits for; medium may sleep, poll,
# or run background processes and localhost services; large may reach the
# network. A test or file says so with `# bats test_tags=size:medium` or
# `# bats file_tags=size:medium`; untagged counts as small. `flaky` marks a
# test that flipped with no code change -- it leaves the fast set until fixed.
#
#   ./run-tests.sh              # the fast set: small, not flaky, 60 s per test
#   ./run-tests.sh --medium     # small + medium, not flaky, 300 s per test
#   ./run-tests.sh --all        # everything, flaky included, 900 s per test
#   CLAUDE_ORCA_TEST_ALL=1 ./run-tests.sh   # the same as --all
#   bats tests/*.bats           # also still the whole suite, directly
#
# A test that hits its limit fails with "timeout after Ns": it is not the
# size it claims -- tag it larger or make it faster.
#
# PARALLEL WHEN IT CAN BE. With GNU parallel installed (brew install
# parallel), test files run side by side, one per CPU core; the cases
# inside one file still run in order. CLAUDE_ORCA_TEST_JOBS=<n> picks the
# number, CLAUDE_ORCA_TEST_JOBS=1 runs one file at a time as before.
#
# bash 3.2 compatible: macOS ships 3.2.57 and this script runs there.

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$REPO_ROOT/tests"

RUN_ALL="${CLAUDE_ORCA_TEST_ALL:-0}"
RUN_MEDIUM=0
for arg in "$@"; do
    case "$arg" in
        --all) RUN_ALL=1 ;;
        --medium) RUN_MEDIUM=1 ;;
        -h|--help)
            sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Error: unknown argument '$arg' (expected --medium or --all)." >&2
            exit 2 ;;
    esac
done

if [ "$RUN_ALL" = "1" ]; then
    SET="everything"; LIMIT=900; FILTER=""
elif [ "$RUN_MEDIUM" = "1" ]; then
    SET="small + medium, not flaky"; LIMIT=300; FILTER="!size:large,!flaky"
else
    SET="the fast set: small, not flaky"; LIMIT=60; FILTER="!size:medium,!size:large,!flaky"
fi
export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-$LIMIT}"

if ! command -v bats >/dev/null 2>&1; then
    echo "Error: bats not found." >&2
    exit 1
fi

if [ ! -d "$TEST_DIR" ]; then
    echo "Error: test directory $TEST_DIR not found." >&2
    exit 1
fi

FILES=""
for f in "$TEST_DIR"/*.bats; do
    [ -e "$f" ] || continue
    FILES="$FILES
$f"
done

# newline-separated -> argv, without arrays (bash 3.2 under set -u dislikes
# appending an expansion onto an empty one).
set --
OLDIFS="$IFS"
IFS='
'
for f in $FILES; do
    set -- "$@" "$f"
done
IFS="$OLDIFS"

if [ "$#" -eq 0 ]; then
    echo "Error: no test files selected." >&2
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
NEWER_BASH=""
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
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
    else
        echo "WARNING: this is bash ${BASH_VERSION%%(*}, where a failing '[[ ]]' or" >&2
        echo "         '!' assertion does not fail its test. Much of this suite is" >&2
        echo "         written that way, so a green run here proves less than it" >&2
        echo "         looks like. Install a newer bash (brew install bash) to get" >&2
        echo "         the assertions back." >&2
    fi
fi

NFILES=$#

# Files side by side when GNU parallel is here (bats needs it for --jobs).
JOBS="${CLAUDE_ORCA_TEST_JOBS:-}"
if [ -z "$JOBS" ]; then
    JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
fi
case "$JOBS" in ''|*[!0-9]*) JOBS=1 ;; esac
if [ "$JOBS" -gt 1 ] && [ "$#" -gt 1 ] && command -v parallel >/dev/null 2>&1; then
    set -- --jobs "$JOBS" --no-parallelize-within-files "$@"
    echo "==> running test files $JOBS at a time (CLAUDE_ORCA_TEST_JOBS=1 for one at a time)"
else
    JOBS=1
fi
if [ -n "$FILTER" ]; then
    set -- --filter-tags "$FILTER" "$@"
fi
echo "==> $SET, ${BATS_TEST_TIMEOUT}s per test"

START=$(date +%s)
STATUS=0
if [ -n "$NEWER_BASH" ]; then
    # PATH, not just the interpreter: bats re-execs itself as
    # `bats-exec-suite` and `bats-exec-file`, both `#!/usr/bin/env bash`,
    # so naming the interpreter here would move THIS process to bash 4+
    # and leave every test body back on 3.2 -- a guard that reports the
    # hole closed while it is open.
    env PATH="$(dirname "$NEWER_BASH"):$PATH" \
        "$NEWER_BASH" "$BATS_BIN" "$@" || STATUS=$?
else
    bats "$@" || STATUS=$?
fi
ELAPSED=$(( $(date +%s) - START ))

echo ""
if [ "$RUN_ALL" = "1" ]; then
    echo "==> $NFILES test files run in ${ELAPSED}s: $SET"
else
    echo "==> $NFILES test files run in ${ELAPSED}s: $SET -- larger tests: ./run-tests.sh --medium or --all"
fi

exit "$STATUS"
