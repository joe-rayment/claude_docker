#!/usr/bin/env bash
#
# orca-wait.sh -- one rolling wait on the coordinator's Run mailbox
# (claude-orca-qa2.13; plan .claude/plans/orca-orchestration.md).
#
#   orca-wait [--timeout-ms N] [--keep] [--types a,b] [--from <handle>]
#
# Blocks on `orchestration check --wait` for worker_done, escalation and
# question, then, per message:
#
#   worker_done          appends the outcome and the files to the bead the
#                        Dispatch came from, releases the worker terminal
#                        (unless --keep), and prints a receipt.
#   question|escalation  prints the receipt with the reply command; the
#                        message stays the orchestrator's to answer with
#                        `orca-reply <msg_id> <text>`.
#
# The whole batch is acknowledged once every message has been processed --
# a bound Run replays the same Delivery until it is acked, so acking late
# is what makes a crash mid-batch harmless.
#
# One single-line JSON receipt per message on stdout (a timeout prints
# {"type":"timeout",…}); human notes on stderr. Exit 0 when the wait
# completed, 2 usage, 3 no reachable runtime / no Run bound yet.
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

note() { printf '%s\n' "$*" >&2; }
die()  { printf 'orca-wait: %s\n' "$*" >&2; exit "${2:-2}"; }

TIMEOUT_MS="${CLAUDE_ORCA_WAIT_TIMEOUT_MS:-600000}"
TYPES="worker_done,escalation,question"
KEEP=0; FROM=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --timeout-ms) TIMEOUT_MS="${2:-}"; shift ;;
        --types)      TYPES="${2:-}"; shift ;;
        --from)       FROM="${2:-}"; shift ;;
        --keep)       KEEP=1 ;;
        -h|--help)    sed -n '3,24p' "$(_resolve_script_path)"; exit 0 ;;
        *)            die "unknown argument: $1" ;;
    esac
    shift
done

command -v jq >/dev/null 2>&1 || die "jq is required"
ROOT="$(orch_root)" || die "no project root: set CLAUDE_ORCA_ROOT"
RUN_FILE="$(orch_run_file "$ROOT")"
[ -f "$RUN_FILE" ] || die "no Run bound yet -- run orca-dispatch first ($RUN_FILE)" 3
RUN_ID="$(jq -r '.run_id // ""' "$RUN_FILE")"
HANDLE="$(orch_handle "$FROM")"
[ -n "$HANDLE" ] || HANDLE="$(jq -r '.coordinator_handle // ""' "$RUN_FILE")"
orca_reachable || die "no Orca runtime is reachable" 3

TERM_ARGS=()
[ -n "$HANDLE" ] && TERM_ARGS=(--terminal "$HANDLE")

out="$(orca_call orchestration check --wait --types "$TYPES" \
    --timeout-ms "$TIMEOUT_MS" --run "$RUN_ID" \
    ${TERM_ARGS[@]+"${TERM_ARGS[@]}"} --json)" || {
    die "check --wait failed: $(orca_error "$out")" 3
}

COUNT="$(orca_field "$out" '.result.count')"
[ -n "$COUNT" ] || COUNT=0
DELIVERY="$(orca_field "$out" '.result.deliveryId')"

if [ "$COUNT" -eq 0 ]; then
    note "no worker message within ${TIMEOUT_MS}ms"
    jq -n -c --arg ms "$TIMEOUT_MS" '{type: "timeout", waited_ms: ($ms|tonumber)}'
    exit 0
fi

# One receipt per message. `jq -c` per line keeps this a plain read loop --
# no arrays of JSON in bash.
printf '%s' "$out" | jq -c '.result.messages[]' | while IFS= read -r msg; do
    mtype="$(printf '%s' "$msg" | jq -r '.type // ""')"
    mid="$(printf '%s' "$msg" | jq -r '.id // ""')"
    subject="$(printf '%s' "$msg" | jq -r '.subject // ""')"
    body="$(printf '%s' "$msg" | jq -r '.body // ""')"
    from_h="$(printf '%s' "$msg" | jq -r '.from_handle // ""')"
    payload="$(printf '%s' "$msg" | jq -r '.payload // ""')"
    pj="$(printf '%s' "$payload" | jq -c . 2>/dev/null)"
    [ -n "$pj" ] || pj='{}'

    task_id="$(printf '%s' "$pj" | jq -r '.taskId // ""')"
    disp_id="$(printf '%s' "$pj" | jq -r '.dispatchId // ""')"
    outcome="$(printf '%s' "$pj" | jq -r '.outcome // ""')"
    files="$(printf '%s' "$pj" | jq -c '.filesModified // []')"

    bead=""; model=""; agent=""
    drec="$(orch_disp_file "$ROOT" "$disp_id")"
    if [ -n "$disp_id" ] && [ -f "$drec" ]; then
        bead="$(jq -r '.bead // ""' "$drec")"
        model="$(jq -r '.model // ""' "$drec")"
        agent="$(jq -r '.agent // ""' "$drec")"
        [ -n "$task_id" ] || task_id="$(jq -r '.task_id // ""' "$drec")"
    fi

    released=false
    if [ "$mtype" = "worker_done" ]; then
        if [ -n "$bead" ]; then
            orch_note_bead "$ROOT" "$bead" \
                "ORCA WORKER_DONE outcome=${outcome:-unknown} task=$task_id dispatch=$disp_id files=$(printf '%s' "$files" | jq -r 'join(",")')
$subject: $body"
        fi
        if [ "$KEEP" -eq 0 ] && [ -n "$disp_id" ]; then
            if rel="$(orca_call orchestration worker-release --dispatch "$disp_id" --json)"; then
                released=true
                note "released $disp_id ($(orca_field "$rel" '.result.state'))"
            else
                note "worker-release $disp_id: $(orca_error "$rel")"
            fi
        fi
    fi

    note "$mtype from ${agent:-$from_h}${bead:+ [$bead]}: ${subject:-(no subject)}"
    jq -n -c --arg type "$mtype" --arg id "$mid" --arg from "$from_h" \
        --arg subject "$subject" --arg body "$body" --arg task "$task_id" \
        --arg disp "$disp_id" --arg bead "$bead" --arg agent "$agent" \
        --arg model "$model" --arg outcome "$outcome" \
        --argjson files "$files" --argjson released "$released" \
        --arg reply "orca-reply $mid <text>" '
        {type: $type, msg_id: $id, from: $from, subject: $subject,
         body: $body, task_id: $task, dispatch_id: $disp, bead: $bead,
         agent: $agent, model: $model, outcome: $outcome, files: $files,
         released: $released}
        + (if $type == "worker_done" then {} else {reply_with: $reply} end)'
done

if [ -n "$DELIVERY" ]; then
    orca_call orchestration check --ack "$DELIVERY" --run "$RUN_ID" \
        ${TERM_ARGS[@]+"${TERM_ARGS[@]}"} --json >/dev/null 2>&1 ||
        note "could not acknowledge delivery $DELIVERY"
fi
exit 0
