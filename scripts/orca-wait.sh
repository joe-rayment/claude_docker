#!/usr/bin/env bash
#
# orca-wait.sh -- the coordinator's rolling wait on its Run mailbox, with a
# stall watch over the workers it dispatched (claude-orca-qa2.13, stall
# watch claude-orca-8a0.1).
#
#   orca-wait [--timeout-ms N] [--keep] [--types a,b] [--from <handle>]
#             [--stall-after <sec>] [--poll <sec>] [--no-nudge]
#
# It loops on `orchestration check --wait` in --poll-sized waits until the
# overall --timeout-ms is spent, and per message:
#
#   worker_done          appends the outcome and the files to the bead the
#                        Dispatch came from, releases the worker terminal
#                        (unless --keep), and prints a receipt.
#   question|escalation  prints the receipt with the reply command; the
#                        message stays the orchestrator's to answer with
#                        `orca-reply <msg_id> <text>`.
#   heartbeat            counts as activity for its dispatch and is noted on
#                        stderr only -- no receipt, and the wait goes on.
#
# Between waits it looks at every dispatch record still in state ready /
# running / dispatched. A worker is alive if ANY of these is recent: its
# started_at, the last heartbeat/question/escalation it sent, its worktree's
# HEAD commit, or a file `git status --porcelain` lists there. Quiet for
# longer than --stall-after prints {"type":"stalled",…} and nudges the
# terminal once; a worker that stalls again after its nudge prints the
# Agent-tool fallback spec and returns 0, so the orchestrator can re-run the
# slice in-process on the same worktree.
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
TYPES="worker_done,escalation,question,heartbeat"
KEEP=0; FROM=""
STALL_AFTER="${CLAUDE_ORCA_STALL_AFTER_S:-600}"
POLL="${CLAUDE_ORCA_WAIT_POLL_S:-60}"
NUDGE=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --timeout-ms)  TIMEOUT_MS="${2:-}"; shift ;;
        --types)       TYPES="${2:-}"; shift ;;
        --from)        FROM="${2:-}"; shift ;;
        --stall-after) STALL_AFTER="${2:-}"; shift ;;
        --poll)        POLL="${2:-}"; shift ;;
        --no-nudge)    NUDGE=0 ;;
        --keep)        KEEP=1 ;;
        -h|--help)     sed -n '3,37p' "$(_resolve_script_path)"; exit 0 ;;
        *)             die "unknown argument: $1" ;;
    esac
    shift
done

case "$STALL_AFTER" in ''|*[!0-9]*) die "--stall-after wants whole seconds" ;; esac
case "$POLL" in ''|*[!0-9]*) die "--poll wants whole seconds" ;; esac
[ "$POLL" -gt 0 ] || POLL=1

command -v jq >/dev/null 2>&1 || die "jq is required"
ROOT="$(orch_root)" || die "no project root: set CLAUDE_ORCA_ROOT"
HANDLE="$(orch_handle "$FROM")"
# My coordinator's Run record: the keyed file for this handle when it has
# one, the legacy run.json otherwise (claude-orca-fyv).
RUN_FILE="$(orch_run_state_file "$ROOT" "$HANDLE")" ||
    die "refusing coordinator handle with / or ..: $HANDLE" 2
[ -f "$RUN_FILE" ] || die "no Run bound yet -- run orca-dispatch first ($RUN_FILE)" 3
RUN_ID="$(jq -r '.run_id // ""' "$RUN_FILE")"
[ -n "$HANDLE" ] || HANDLE="$(jq -r '.coordinator_handle // ""' "$RUN_FILE")"
orca_reachable || die "no Orca runtime is reachable" 3

DISP_DIR="$(orch_dir "$ROOT")/dispatch"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/orca-wait.XXXXXX")" || die "no temp dir"
trap 'rm -rf "$TMPD"' EXIT

TERM_ARGS=()
[ -n "$HANDLE" ] && TERM_ARGS=(--terminal "$HANDLE")

# --- activity ------------------------------------------------------------

# rec_touch <dispatch-id> -- a message from that worker is activity.
rec_touch() {
    local f tmp
    [ -n "${1:-}" ] || return 0
    f="$(orch_disp_file "$ROOT" "$1")"
    [ -f "$f" ] || return 0
    tmp="$f.tmp"
    jq --argjson n "$(date +%s)" '.last_activity = $n' "$f" >"$tmp" 2>/dev/null &&
        mv "$tmp" "$f"
    rm -f "$tmp"
    return 0
}

# rec_set <dispatch-id> <jq args...> -- apply a jq filter (with its options)
# to the dispatch's record atomically; a record that does not exist is left
# alone.
rec_set() {
    local id="$1" f tmp
    [ -n "$id" ] || return 0
    shift
    f="$(orch_disp_file "$ROOT" "$id")"
    [ -f "$f" ] || return 0
    tmp="$f.tmp"
    jq "$@" "$f" >"$tmp" 2>/dev/null &&
        mv "$tmp" "$f"
    rm -f "$tmp"
    return 0
}

# rec_mark_done <dispatch-id> <outcome> <released> <terminal-closed> -- a
# finished dispatch leaves its record done, so the stall scan never scans
# it again.
rec_mark_done() {
    local f
    [ -n "${1:-}" ] || return 0
    f="$(orch_disp_file "$ROOT" "$1")"
    [ -f "$f" ] || return 0
    rec_set "$1" \
        --arg o "${2:-unknown}" --argjson r "${3:-false}" \
        --argjson c "${4:-false}" \
        --argjson n "$(date +%s)" \
        '.state = "done" | .outcome = $o | .finished_at = $n |
         .released = $r | .terminal_closed = $c'
    return 0
}

# rec_activity <record file> -- the newest epoch second that says this
# worker is alive: started_at, its last message, the worktree's HEAD commit,
# or the newest mtime among the files git reports as changed there.
rec_activity() {
    local f="$1" a t wt line p
    a="$(jq -r '.started_at // 0' "$f" 2>/dev/null)"
    case "$a" in ''|*[!0-9]*) a=0 ;; esac
    t="$(jq -r '.last_activity // 0' "$f" 2>/dev/null)"
    case "$t" in ''|*[!0-9]*) t=0 ;; esac
    [ "$t" -gt "$a" ] && a="$t"
    # The nudge itself restarts the clock: "stalls again" means quiet for a
    # fresh --stall-after window after being told to carry on, not quiet on
    # the very next poll.
    t="$(jq -r '.nudged_at // 0' "$f" 2>/dev/null)"
    case "$t" in ''|*[!0-9]*) t=0 ;; esac
    [ "$t" -gt "$a" ] && a="$t"

    wt="$(jq -r '.worktree_path // ""' "$f" 2>/dev/null)"
    if [ -n "$wt" ] && [ -d "$wt" ]; then
        t="$(git -C "$wt" log -1 --format=%ct 2>/dev/null)"
        case "$t" in ''|*[!0-9]*) t=0 ;; esac
        [ "$t" -gt "$a" ] && a="$t"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            p="${line:3}"
            case "$p" in *' -> '*) p="${p##* -> }" ;; esac
            p="${p#\"}"; p="${p%\"}"
            [ -e "$wt/$p" ] || continue
            t="$(orch_mtime "$wt/$p")"
            case "$t" in ''|*[!0-9]*) continue ;; esac
            [ "$t" -gt "$a" ] && a="$t"
        done <<EOF
$(git -C "$wt" status --porcelain 2>/dev/null)
EOF
    fi
    printf '%s' "$a"
}

# --- the stall watch -----------------------------------------------------
#
# Returns 0 normally, 3 when it printed a fallback: the caller stops waiting
# so the orchestrator can re-run the slice in-process on the same worktree.
stall_scan() {
    local f now state act idle bead disp term wt model nudged
    local text cmd spec bj tmp
    now="$(date +%s)"
    for f in "$DISP_DIR"/*.json; do
        [ -f "$f" ] || continue
        state="$(jq -r '.state // ""' "$f" 2>/dev/null)"
        case "$state" in ready|running|dispatched) ;; *) continue ;; esac
        act="$(rec_activity "$f")"
        case "$act" in ''|*[!0-9]*) act=0 ;; esac
        [ "$act" -gt 0 ] || act="$now"
        idle=$(( now - act ))
        [ "$idle" -gt "$STALL_AFTER" ] || continue

        bead="$(jq -r '.bead // ""' "$f" 2>/dev/null)"
        disp="$(jq -r '.dispatch_id // ""' "$f" 2>/dev/null)"
        term="$(jq -r '.terminal // ""' "$f" 2>/dev/null)"
        wt="$(jq -r '.worktree_path // ""' "$f" 2>/dev/null)"
        model="$(jq -r '.model // ""' "$f" 2>/dev/null)"
        nudged="$(jq -r '.nudged_at // 0' "$f" 2>/dev/null)"
        case "$nudged" in ''|*[!0-9]*) nudged=0 ;; esac

        # A bead that is already closed means its worker reported and the
        # record was missed (an old orca-wait): mark it done, never nudge.
        bj=""
        if [ -n "$bead" ]; then
            bj="$(orch_bead_json "$ROOT" "$bead")" || bj=""
            if [ -n "$bj" ] &&
               [ "$(printf '%s' "$bj" | jq -r '.status // ""')" = "closed" ]; then
                note "$disp (${bead:-no bead}): bead is closed -- marking the dispatch done"
                rec_set "$disp" --argjson n "$now" \
                    '.state = "done" | .finished_at = $n |
                     .note = "bead closed; dispatch marked done by stall scan"'
                continue
            fi
        fi

        if [ "$nudged" -gt 0 ]; then
            spec=""
            [ -n "$bj" ] && spec="$(orch_spec "$bj" "$bead")"
            note "$disp (${bead:-no bead}) is still quiet ${idle}s after its nudge -- falling back to an in-process executor"
            jq -n -c --arg bead "$bead" --arg disp "$disp" --arg term "$term" \
                --argjson idle "$idle" --arg wt "$wt" \
                --arg fb "$(orch_fallback "$spec" "$model")" \
                '{type: "stalled", bead: $bead, dispatch_id: $disp,
                  terminal: $term, idle_s: $idle, nudged: true,
                  worktree_path: $wt, fallback: $fb}'
            # scanned no more, and the wait only ends if nothing else is live
            rec_set "$disp" '.state = "stalled"'
            local g gs other=0
            for g in "$DISP_DIR"/*.json; do
                [ -f "$g" ] || continue
                gs="$(jq -r '.state // ""' "$g" 2>/dev/null)"
                case "$gs" in ready|running|dispatched) other=1; break ;; esac
            done
            [ "$other" -eq 0 ] && return 3
            return 0
        fi

        text="claude-orca stall watch: you have been quiet for ${idle}s. Continue your slice now, report with orchestration send --type worker_done when it is done or you are blocked, and send a heartbeat at once: orca-ide orchestration send --type heartbeat --subject alive --dispatch-id $disp --json"
        cmd="orca terminal send --terminal $term --text \"$text\" --enter"
        note "$disp (${bead:-no bead}) has been idle ${idle}s"
        jq -n -c --arg bead "$bead" --arg disp "$disp" --arg term "$term" \
            --argjson idle "$idle" --arg nudge "$cmd" \
            '{type: "stalled", bead: $bead, dispatch_id: $disp,
              terminal: $term, idle_s: $idle, nudge: $nudge}'

        [ "$NUDGE" -eq 1 ] || continue
        [ -n "$term" ] || continue
        orca_call terminal send --terminal "$term" --text "$text" --enter \
            --json >/dev/null 2>&1 || note "could not nudge $term"
        tmp="$f.tmp"
        jq --argjson n "$now" '.nudged_at = $n' "$f" >"$tmp" 2>/dev/null &&
            mv "$tmp" "$f"
        rm -f "$tmp"
    done
    return 0
}

# --- one batch of messages -----------------------------------------------
#
# REAL_COUNT counts the messages that end the wait; a heartbeat does not.
process_batch() {
    local msgs msg mtype mid subject body from_h payload pj
    local task_id disp_id outcome files bead model agent drec released rel
    local term rel_state terminal_closed
    msgs="$TMPD/msgs.jsonl"
    printf '%s' "$1" | jq -c '.result.messages[]?' >"$msgs" 2>/dev/null
    while IFS= read -r msg; do
        [ -n "$msg" ] || continue
        released=false
        terminal_closed=false
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

        # every message from a worker proves it is alive
        rec_touch "$disp_id"

        if [ "$mtype" = "heartbeat" ]; then
            note "heartbeat from ${agent:-$from_h}${bead:+ [$bead]} (dispatch ${disp_id:-unknown}) -- still working"
            continue
        fi
        REAL_COUNT=$(( REAL_COUNT + 1 ))

        released=false
        if [ "$mtype" = "worker_done" ]; then
            if [ -n "$bead" ]; then
                orch_note_bead "$ROOT" "$bead" \
                    "ORCA WORKER_DONE outcome=${outcome:-unknown} task=$task_id dispatch=$disp_id files=$(printf '%s' "$files" | jq -r 'join(",")')
$subject: $body"
            fi
            term=""
            if [ -f "$drec" ]; then
                term="$(jq -r '.terminal // ""' "$drec")"
            fi
            terminal_closed=false
            if [ "$KEEP" -eq 0 ] && [ -n "$disp_id" ]; then
                if rel="$(orca_call orchestration worker-release --dispatch "$disp_id" --json)"; then
                    rel_state="$(orca_field "$rel" '.result.state')"
                    case "$rel_state" in
                        released|closed|gone)
                            released=true
                            note "released $disp_id ($rel_state)"
                            ;;
                        *)
                            # A non-terminal release state (e.g. "retained")
                            # leaves the finished worker resident (~1 GB per
                            # idle opencode TUI) -- close its terminal.
                            if [ -n "$term" ] &&
                               orca_call terminal close --terminal "$term" \
                                   --json >/dev/null 2>&1; then
                                released=true
                                terminal_closed=true
                                note "closed $term (worker-release left it retained)"
                            else
                                note "worker-release left $disp_id in state '$rel_state' and terminal close ${term:-<no terminal>} failed -- the worker may stay resident"
                            fi
                            ;;
                    esac
                else
                    note "worker-release $disp_id: $(orca_error "$rel")"
                fi
            fi
            # a finished dispatch never goes back under the stall watch
            [ -n "$disp_id" ] && [ -f "$drec" ] &&
                rec_mark_done "$disp_id" "${outcome:-unknown}" "$released" \
                    "$terminal_closed"
        fi

        note "$mtype from ${agent:-$from_h}${bead:+ [$bead]}: ${subject:-(no subject)}"
        jq -n -c --arg type "$mtype" --arg id "$mid" --arg from "$from_h" \
            --arg subject "$subject" --arg body "$body" --arg task "$task_id" \
            --arg disp "$disp_id" --arg bead "$bead" --arg agent "$agent" \
            --arg model "$model" --arg outcome "$outcome" \
            --argjson files "$files" --argjson released "$released" \
            --argjson closed "$terminal_closed" \
            --arg reply "orca-reply $mid <text>" '
            {type: $type, msg_id: $id, from: $from, subject: $subject,
             body: $body, task_id: $task, dispatch_id: $disp, bead: $bead,
             agent: $agent, model: $model, outcome: $outcome, files: $files,
             released: $released, terminal_closed: $closed}
            + (if $type == "worker_done" then {} else {reply_with: $reply} end)'
    done <"$msgs"
    return 0
}

# --- the rolling wait ----------------------------------------------------
#
# SPENT is the nominal time asked of the runtime, WALL the clock; the wait
# ends on whichever is larger, so a burst of heartbeats cannot spin the loop
# and a blocking check cannot overrun the caller's budget.

case "$TIMEOUT_MS" in ''|*[!0-9]*) die "--timeout-ms wants whole milliseconds" ;; esac
START_S="$(date +%s)"
SPENT=0; ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT_MS" ]; do
    REMAINING=$(( TIMEOUT_MS - ELAPSED ))
    WAIT_MS=$(( POLL * 1000 ))
    [ "$WAIT_MS" -gt "$REMAINING" ] && WAIT_MS="$REMAINING"
    [ "$WAIT_MS" -gt 0 ] || WAIT_MS=1

    out="$(orca_call orchestration check --wait --types "$TYPES" \
        --timeout-ms "$WAIT_MS" --run "$RUN_ID" \
        ${TERM_ARGS[@]+"${TERM_ARGS[@]}"} --json)" || {
        die "check --wait failed: $(orca_error "$out")" 3
    }

    COUNT="$(orca_field "$out" '.result.count')"
    case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
    DELIVERY="$(orca_field "$out" '.result.deliveryId')"

    REAL_COUNT=0
    if [ "$COUNT" -gt 0 ]; then
        process_batch "$out"
        if [ -n "$DELIVERY" ]; then
            orca_call orchestration check --ack "$DELIVERY" --run "$RUN_ID" \
                ${TERM_ARGS[@]+"${TERM_ARGS[@]}"} --json >/dev/null 2>&1 ||
                note "could not acknowledge delivery $DELIVERY"
        fi
    fi
    [ "$REAL_COUNT" -gt 0 ] && exit 0

    stall_scan
    [ "$?" -eq 3 ] && exit 0

    SPENT=$(( SPENT + WAIT_MS ))
    ELAPSED=$(( ( $(date +%s) - START_S ) * 1000 ))
    [ "$SPENT" -gt "$ELAPSED" ] && ELAPSED="$SPENT"
done

note "no worker message within ${TIMEOUT_MS}ms"
jq -n -c --arg ms "$TIMEOUT_MS" '{type: "timeout", waited_ms: ($ms|tonumber)}'
exit 0
