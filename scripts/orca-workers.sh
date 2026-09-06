#!/usr/bin/env bash
#
# orca-workers.sh -- what is running right now, in one table
# (claude-orca-qa2.13; plan .claude/plans/orca-orchestration.md).
#
#   orca-workers [--run <run_id>] [--json]
#
# `worker-list` (terminal accounting) joined to `task-list --brief` (what
# each of those workers was asked to do) for the Run bound to this
# coordinator, with the bead id from the dispatch records beside it. Human
# table on stdout; --json prints the joined rows instead.
#
# Exit 0 · 2 usage · 3 no reachable runtime / no Run bound yet.
#
# bash 3.2 clean (scripts/lint-bash32.sh scans all of scripts/).

set -uo pipefail

_resolve_script_path() {
    local src="${BASH_SOURCE[0]}" link dir
    while [ -L "$src" ]; do
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(cd "$(dirname "$src")" && pwd)"; src="$dir/$link" ;;
        esac
    done
    printf '%s' "$src"
}
SCRIPT_DIR="$(cd "$(dirname "$(_resolve_script_path)")" && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/orca-orch.sh
. "$SCRIPT_DIR/lib/orca-orch.sh"

die() { printf 'orca-workers: %s\n' "$*" >&2; exit "${2:-2}"; }

RUN_ID=""; AS_JSON=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --run)  RUN_ID="${2:-}"; shift ;;
        --json) AS_JSON=1 ;;
        -h|--help) sed -n '3,13p' "$(_resolve_script_path)"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

command -v jq >/dev/null 2>&1 || die "jq is required"
ROOT="$(orch_root)" || die "no project root: set CLAUDE_ORCA_ROOT"
if [ -z "$RUN_ID" ]; then
    RUN_FILE="$(orch_run_file "$ROOT")"
    [ -f "$RUN_FILE" ] || die "no Run bound yet -- run orca-dispatch first" 3
    RUN_ID="$(jq -r '.run_id // ""' "$RUN_FILE")"
fi
orca_reachable || die "no Orca runtime is reachable" 3

workers="$(orca_call orchestration worker-list --run "$RUN_ID" --json)" ||
    die "worker-list failed: $(orca_error "$workers")" 3
tasks="$(orca_call orchestration task-list --brief --run "$RUN_ID" --json)" || tasks='{}'

# The bead per dispatch is ours, not the runtime's: the dispatch records
# orca-dispatch wrote are the only place the two ids meet.
beads="$(
    printf '['
    sep=""
    for f in "$(orch_dir "$ROOT")"/dispatch/*.json; do
        [ -f "$f" ] || continue
        printf '%s' "$sep"
        jq -c '{dispatch_id, bead, agent, model}' "$f"
        sep=","
    done
    printf ']'
)"

rows="$(jq -n --argjson w "$workers" --argjson t "$tasks" --argjson b "$beads" '
    ($t.result.tasks // []) as $tasks
    | ($b // []) as $beads
    | [ ($w.result.workers // [])[]
        | . as $x
        | ($tasks[] | select(.id == $x.taskId)) as $task
        | ($beads[] | select(.dispatch_id == $x.dispatchId)) // {} as $bd
        | {dispatch: $x.dispatchId, task: $x.taskId,
           bead: ($bd.bead // ""), agent: ($bd.agent // ""),
           model: ($bd.model // ""), worker: $x.workerState,
           status: $x.dispatchStatus, terminal: $x.terminalState,
           spec: (($task.task_title // $task.display_name // $task.spec // "")
                  | .[0:48])} ]')"

if [ "$AS_JSON" -eq 1 ]; then
    printf '%s\n' "$rows" | jq -c '.'
    exit 0
fi

printf 'Run %s\n' "$RUN_ID"
printf '%s\n' "$rows" | jq -r '
    (["DISPATCH", "BEAD", "AGENT", "MODEL", "WORKER", "STATUS", "TERMINAL", "TASK"]),
    (.[] | [.dispatch, (.bead // "-"), (.agent // "-"), (.model // "-"),
            .worker, .status, .terminal, .spec])
    | @tsv' | column -t -s "$(printf '\t')" 2>/dev/null ||
    printf '%s\n' "$rows" | jq -r '.[] | "\(.dispatch)\t\(.bead)\t\(.worker)\t\(.status)"'
exit 0
