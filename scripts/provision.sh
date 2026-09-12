#!/usr/bin/env bash
#
# provision -- what this folder's start actually did, and how to do one bit
# of it again (S5, claude-orca-dbu.5).
#
# S4 moved everything folder-shaped out of the blocking boot and into
# numbered idempotent steps under scripts/container/provision.d/, each one
# leaving run/provision/<step>.log and .status behind. That made the faults
# survivable. It did not make them VISIBLE: two files per step in a
# directory nobody opens is a report with no reader, and the only repair on
# offer was "start the folder again", which re-runs all seven steps to fix
# one of them.
#
# So this is the reader, and the one-step repair:
#
#   provision status              one row per step -- name, ok/FAILED, when,
#                                 the last line of its log. Exits non-zero
#                                 when any step failed, so it is usable as
#                                 the condition of a script.
#   provision status --failed     the failed rows only, and NOTHING at all
#                                 when none failed. This is the SessionStart
#                                 hook's spelling: a clean folder must not
#                                 spend a line of every session saying so.
#                                 Always exits 0 -- a hook never fails a
#                                 session over what it found.
#   provision status --tsv        <verdict>TAB<name>TAB<detail> rows, the
#                                 shape scripts/container/verify-folder.sh
#                                 answers in, so `claude-dev --doctor` on
#                                 the Mac can print the same rows it does.
#   provision run <step> [...]    re-run exactly those steps, rewriting
#                                 their log and status. Exits with the
#                                 worst status the re-run left behind --
#                                 provision-run.sh itself always exits 0
#                                 (its caller is PID 1), which is right for
#                                 a boot and useless to a person.
#
# It reads run/provision/, which is on the bind-mounted project, so it
# answers the same from inside the container and from a checkout.
#
# bash 3.2 clean, like everything else under scripts/.

set -u

# Resolve through a symlink chain (e.g. bin/provision -> ../scripts/provision.sh)
# to this script's real directory, so lib/paths.sh and the runner beside it
# resolve whether this is invoked via the repo copy or the
# .claude-dev/template/bin/ symlink.
_resolve_script_path() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        local link dir
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(cd "$(dirname "$src")" && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}
SCRIPT_DIR="$(cd "$(dirname "$(_resolve_script_path)")" && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"

RUNNER="$SCRIPT_DIR/container/provision-run.sh"
STEPS_DIR="${CLAUDE_ORCA_PROVISION_STEPS:-$SCRIPT_DIR/container/provision.d}"

# The folder. $PROJECT_DIR is what the container exports; CLAUDE_ORCA_ROOT
# is what the hooks and the test suite set; the walk-up in lib/paths.sh is
# for a plain terminal in a checkout.
ROOT="${CLAUDE_ORCA_ROOT:-${PROJECT_DIR:-}}"
[ -n "$ROOT" ] || ROOT="$(claude_orca_root 2>/dev/null)" || ROOT=""
PROVISION_DIR="${CLAUDE_ORCA_PROVISION_DIR:-}"
if [ -z "$PROVISION_DIR" ]; then
    if [ -z "$ROOT" ]; then
        echo "provision: no bootstrapped project here (set CLAUDE_ORCA_ROOT)" >&2
        exit 1
    fi
    PROVISION_DIR="$ROOT/.claude-dev/run/provision"
fi

usage() {
    cat <<'USAGE'
provision status [--failed] [--tsv]   what each provisioning step did
provision run <step> [...]            re-run exactly those steps

The steps live in scripts/container/provision.d/ and write
.claude-dev/run/provision/<step>.{log,status} every time the folder starts.
USAGE
}

# When a status file was written -- i.e. when that step last ran.
when_of() {  # when_of <file>
    date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null && return 0
    stat -c '%y' "$1" 2>/dev/null | cut -c1-19 && return 0
    printf '%s\n' '-'
}

# The one line worth printing out of a step's log.
#
# For a step that passed, that is its last line. For a step that FAILED it
# is the last line that looks like the failure, and only then the last line
# -- because a step whose last act is to print another `ok` is exactly what
# this is for: setup.sh --check ends on "[check] ok locale en_US.UTF-8
# generated" whichever of its fourteen checks failed, and a hook that
# quotes that line has reported nothing.
#
# Tabs and control characters go, because a --tsv row is split on tabs and
# a log line is arbitrary program output; long lines are cut, because this
# prints on every session start.
last_line() {  # last_line <log file> [failed]
    local f="$1" failed="${2:-}" line=""
    if [ -f "$f" ]; then
        if [ -n "$failed" ]; then
            line="$(grep -Ei 'fail|error|cannot|not ok|missing|denied|no such|refused|timed out|unable|fatal' \
                        "$f" 2>/dev/null | tail -1)"
        fi
        [ -n "$line" ] || line="$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1)"
        line="$(printf '%s' "$line" | tr '\t\r' '  ' | tr -d '\000-\037')"
        if [ "${#line}" -gt 160 ]; then
            line="$(printf '%s' "$line" | cut -c1-160)..."
        fi
    fi
    printf '%s\n' "$line"
}

cmd_status() {
    local failed_only=0 tsv=0 arg
    for arg in "$@"; do
        case "$arg" in
            --failed) failed_only=1 ;;
            --tsv)    tsv=1 ;;
            -h|--help) usage; return 0 ;;
            *) echo "provision status: unknown option: $arg" >&2; return 2 ;;
        esac
    done

    local f name st when last verdict rc=0 rows=0 failures=0 body=""
    for f in "$PROVISION_DIR"/*.status; do
        [ -f "$f" ] || continue
        name="$(basename "$f" .status)"
        st="$(tr -d '[:space:]' < "$f" 2>/dev/null)"
        [ -n "$st" ] || st="?"
        when="$(when_of "$f")"
        rows=$((rows + 1))

        if [ "$st" = "0" ]; then
            verdict=ok
            last="$(last_line "$PROVISION_DIR/$name.log")"
        else
            verdict=FAILED
            rc=1
            failures=$((failures + 1))
            last="$(last_line "$PROVISION_DIR/$name.log" failed)"
        fi
        if [ "$failed_only" = "1" ] && [ "$verdict" = "ok" ]; then
            continue
        fi

        if [ "$tsv" = "1" ]; then
            # verify-folder.sh's vocabulary, so the doctor's row printer
            # needs no second case for these.
            if [ "$verdict" = "ok" ]; then
                printf 'ok\t%s\t%s\n' "$name" "ok -- $when${last:+ -- $last}"
            else
                printf 'FAIL\t%s\t%s\n' "$name" "exit $st at $when${last:+ -- $last}"
            fi
        elif [ "$failed_only" = "1" ]; then
            printf '[provision] %s FAILED (exit %s) at %s%s\n' \
                "$name" "$st" "$when" "${last:+ -- $last}"
            printf '[provision] re-run it with: provision run %s (log: %s)\n' \
                "$name" "$PROVISION_DIR/$name.log"
        else
            body="$body$(printf '  %-7s %-22s %s  %s' \
                "$verdict" "$name" "$when" "$last")
"
        fi
    done

    if [ "$rows" -eq 0 ]; then
        # Nothing has provisioned this folder yet. That is a fact about a
        # folder that has not started, not a fault to shout about at a
        # session start.
        [ "$failed_only" = "1" ] && return 0
        [ "$tsv" = "1" ] && return 0
        echo "[provision] no step has run in this folder yet ($PROVISION_DIR is empty)"
        return 0
    fi

    # A hook: whatever it found, the session starts.
    [ "$failed_only" = "1" ] && return 0
    [ "$tsv" = "1" ] && return "$rc"

    if [ "$failures" -eq 0 ]; then
        printf '[provision] %s step(s), all ok -- %s\n' "$rows" "$PROVISION_DIR"
    else
        printf '[provision] %s step(s), %s FAILED -- `provision run <step>` re-runs one\n' \
            "$rows" "$failures"
    fi
    printf '%s' "$body"
    return "$rc"
}

cmd_run() {
    if [ "$#" -lt 1 ]; then
        echo "provision run: which step? (provision status lists them)" >&2
        return 2
    fi
    local want rc=0 st
    for want in "$@"; do
        case "$want" in
            */*|.|..) echo "provision run: not a step name: $want" >&2; return 2 ;;
        esac
        if [ ! -x "$STEPS_DIR/$want" ]; then
            echo "provision run: no such step: $want (looked in $STEPS_DIR)" >&2
            return 2
        fi
    done

    # One runner, one place that knows how a step is run: the log, the
    # status, the timeout and the guard key's routing all stay exactly
    # where the boot puts them.
    PROJECT_DIR="$ROOT" bash "$RUNNER" "$@" || rc=$?

    # ... and then the honest exit code, which the runner cannot give us:
    # it always exits 0, because its caller is PID 1 of the container.
    for want in "$@"; do
        st="$(tr -d '[:space:]' < "$PROVISION_DIR/$want.status" 2>/dev/null)"
        [ "$st" = "0" ] || rc=1
    done
    return "$rc"
}

sub="${1:-status}"
[ "$#" -gt 0 ] && shift
case "$sub" in
    status)         cmd_status "$@" ;;
    run)            cmd_run "$@" ;;
    -h|--help|help) usage ;;
    *)              usage >&2; exit 2 ;;
esac
exit $?
