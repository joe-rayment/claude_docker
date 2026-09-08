#!/usr/bin/env bash
#
# run-tests.sh -- runs the tests/*.bats suites in this repo (S7, claude-
# orca-3sk.7). The old template's runner split smoke/experience/multi-
# project into their own lanes and pointed a TEST_DIR indirection at the
# image-baked copies (vs. the working tree during development); neither
# applies here -- there is no baked image, and every suite lives at
# tests/*.bats in the checkout being tested.
#
# FAST BY DEFAULT. The whole suite is ~8 minutes, and the bulk of that is a
# handful of files that stand up real processes (a real Orca, a real local
# end-to-end start) or churn through big fixtures. Those live in SLOW_FILES
# below -- chosen by timing every file, not by guessing -- and are skipped
# unless you ask for them:
#
#   ./run-tests.sh              # the fast subset (the everyday run)
#   ./run-tests.sh --all        # every file, as before
#   CLAUDE_ORCA_TEST_ALL=1 ./run-tests.sh   # the same thing
#   bats tests/*.bats           # also still the whole suite, directly
#
# bash 3.2 compatible: macOS ships 3.2.57 and this script runs there.

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$REPO_ROOT/tests"

# Measured on this box (bats per file, seconds): orca-dispatch 44,
# orca-run 44, code-map 37, first-start-dns 33, container-entrypoint 32,
# prime-hook 31, container-image 30, bootstrap 29, fresh-project 19,
# bd-guard 18, launcher-v3-pull 16, toolchain-cache 14, update-hygiene 11.
# Everything else is under 9s and most of it under 1s. e2e-local is quick
# but starts a real local run, so it goes here too.
SLOW_FILES="
bd-guard.bats
bootstrap.bats
code-map.bats
container-entrypoint.bats
container-image.bats
e2e-local.bats
first-start-dns.bats
fresh-project.bats
launcher-v3-pull.bats
orca-dispatch.bats
orca-run.bats
prime-hook.bats
toolchain-cache.bats
update-hygiene.bats
"

RUN_ALL="${CLAUDE_ORCA_TEST_ALL:-0}"
for arg in "$@"; do
    case "$arg" in
        --all) RUN_ALL=1 ;;
        -h|--help)
            sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Error: unknown argument '$arg' (expected --all)." >&2
            exit 2 ;;
    esac
done

if ! command -v bats >/dev/null 2>&1; then
    echo "Error: bats not found." >&2
    exit 1
fi

if [ ! -d "$TEST_DIR" ]; then
    echo "Error: test directory $TEST_DIR not found." >&2
    exit 1
fi

# The file list, and the count of what got left out.
FILES=""
SKIPPED=0
for f in "$TEST_DIR"/*.bats; do
    [ -e "$f" ] || continue
    if [ "$RUN_ALL" != "1" ]; then
        base="$(basename "$f")"
        case "$SLOW_FILES" in
            *"
$base
"*) SKIPPED=$((SKIPPED + 1)); continue ;;
        esac
    fi
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
if [ "$SKIPPED" -gt 0 ]; then
    echo "==> $# test files run in ${ELAPSED}s; $SKIPPED slow file(s) skipped -- run them with ./run-tests.sh --all"
else
    echo "==> $# test files run in ${ELAPSED}s; none skipped (this was the full suite)"
fi

exit "$STATUS"
