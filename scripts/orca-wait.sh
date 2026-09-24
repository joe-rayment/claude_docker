#!/usr/bin/env bash
#
# orca-wait.sh -- the coordinator's mailbox, split so the orchestrator never
# runs the poll loop in its own turns (claude-orca-mg8, redo of n3e; the
# original rolling wait was claude-orca-qa2.13, the stall watch
# claude-orca-8a0.1).
#
#   orca-wait              print and consume the unread receipt lines in
#                          run/orchestration/inbox.jsonl (the read cursor is
#                          inbox.cursor). A cheap file read: returns
#                          immediately, never calls Orca. Exit 0.
#   orca-wait --until <s>  block up to <s> seconds for the inbox to grow,
#                          polling the file (never Orca); prints and
#                          consumes the new lines, exit 0 -- or exit 4 with
#                          no output when nothing arrived in time.
#   orca-wait --spool      the spooler: run the rolling loop below forever,
#                          detached (nohup is the starter's job -- orca-
#                          dispatch starts one per Run), doing the release/
#                          close/bead-note/stall work itself and appending
#                          every receipt line to inbox.jsonl. Exits when no
#                          dispatch record has been live for
#                          CLAUDE_ORCA_SPOOL_IDLE_S seconds (default 1800)
#                          counted from the last live dispatch record, not
#                          from the spooler's start -- and at once when the
#                          dispatch dir is no longer readable
#                          (claude-orca-csh). Pid file:
#                          run/orchestration/spool.pid.
#   orca-wait --poll-loop  the original blocking wait, kept for orca-run and
#                          the e2e: the loop below with receipts on stdout,
#                          ending on the first receipt or --timeout-ms.
#
# The loop (spooler and --poll-loop) runs on `orchestration check --wait`
# in --poll-sized waits, and per message:
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
# One single-line JSON receipt per message; in --spool they are appended to
# inbox.jsonl, otherwise they go to stdout (a --poll-loop timeout prints
# {"type":"timeout",…}); human notes on stderr. Exit 0 when the wait
# completed, 2 usage, 3 no reachable runtime / no Run bound yet, 4 an
# --until that ran out of seconds.
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
SPOOL=0; POLL_LOOP=0; UNTIL_S=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --timeout-ms)  TIMEOUT_MS="${2:-}"; shift ;;
        --types)       TYPES="${2:-}"; shift ;;
        --from)        FROM="${2:-}"; shift ;;
        --stall-after) STALL_AFTER="${2:-}"; shift ;;
        --poll)        POLL="${2:-}"; shift ;;
        --no-nudge)    NUDGE=0 ;;
        --keep)        KEEP=1 ;;
        --spool)       SPOOL=1 ;;
        --poll-loop)   POLL_LOOP=1 ;;
        --until)       UNTIL_S="${2:-}"; shift ;;
        -h|--help)     sed -n '3,47p' "$(_resolve_script_path)"; exit 0 ;;
        *)             die "unknown argument: $1" ;;
    esac
    shift
done

# The reader and --until are file reads; they never reach the runtime and
# never need a Run binding, so they are handled before those checks.
MODE="reader"
[ -n "$UNTIL_S" ] && MODE="until"
[ "$SPOOL" -eq 1 ] && MODE="spool"
[ "$POLL_LOOP" -eq 1 ] && MODE="classic"
if [ "$SPOOL" -eq 1 ] && { [ "$POLL_LOOP" -eq 1 ] || [ -n "$UNTIL_S" ]; }; then
    die "--spool cannot be combined with --poll-loop or --until"
fi
[ "$POLL_LOOP" -eq 1 ] && [ -n "$UNTIL_S" ] &&
    die "--poll-loop cannot be combined with --until"

ROOT="$(orch_root)" || die "no project root: set CLAUDE_ORCA_ROOT"
ODIR="$(orch_dir "$ROOT")"
INBOX="$ODIR/inbox.jsonl"
CURSOR="$ODIR/inbox.cursor"

if [ -n "$UNTIL_S" ]; then
    case "$UNTIL_S" in ''|*[!0-9]*) die "--until wants whole seconds" ;; esac
fi

# emit_unread -- print every complete inbox line past the cursor and move
# the cursor past the last one. Returns 0 when something was printed.
# A trailing partial line (a mid-append writer) is left for the next read.
emit_unread() {
    [ -f "$INBOX" ] || return 1
    local cursor=0 size end
    [ -f "$CURSOR" ] && cursor="$(tr -dc '0-9' <"$CURSOR" 2>/dev/null)"
    case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
    size="$(wc -c <"$INBOX" 2>/dev/null | tr -d '[:space:]')"
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    # a file smaller than the cursor was truncated or rotated: replay it all
    [ "$size" -ge "$cursor" ] || cursor=0
    [ "$size" -gt "$cursor" ] || return 1
    end="$size"
    if [ -n "$(tail -c 1 "$INBOX" 2>/dev/null)" ]; then
        # no trailing newline: stop before the partial last line
        end="$(LC_ALL=C awk '{e += length($0) + 1}
                             END { print e - length($0) - 1 }' "$INBOX")"
        case "$end" in ''|*[!0-9]*) end="$size" ;; esac
    fi
    [ "$end" -gt "$cursor" ] || return 1
    tail -c "+$(( cursor + 1 ))" "$INBOX" 2>/dev/null |
        head -c "$(( end - cursor ))"
    printf '%s\n' "$end" >"$CURSOR.tmp" && mv -f "$CURSOR.tmp" "$CURSOR"
    return 0
}

if [ "$MODE" = "reader" ] || [ "$MODE" = "until" ]; then
    if emit_unread; then exit 0; fi
    if [ "$MODE" = "until" ]; then
        deadline=$(( $(date +%s) + UNTIL_S ))
        while [ "$(date +%s)" -lt "$deadline" ]; do
            sleep "${CLAUDE_ORCA_UNTIL_POLL_S:-0.2}"
            emit_unread && exit 0
        done
        exit 4
    fi
    exit 0
fi

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
SPOOL_PID_FILE="$ODIR/spool.pid"
cleanup() {
    rm -rf "$TMPD"
    if [ "$MODE" = "spool" ] && [ -f "$SPOOL_PID_FILE" ] &&
       [ "$(cat "$SPOOL_PID_FILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$SPOOL_PID_FILE"
    fi
}
trap cleanup EXIT

# In spool mode this process IS the Run's mailbox spooler: refuse a second
# one (the pid file is orca-dispatch's quick gate; this is the real one) and
# put our pid in it so the next dispatch sees a live spooler.
if [ "$MODE" = "spool" ]; then
    # bats-core waits on fd 3; a spooler that inherits it keeps the whole
    # test run open (claude-orca-csh). orca-dispatch starts us with 3>&-;
    # close it here too, for every other way of starting the spooler.
    exec 3>&-
    mkdir -p "$ODIR"
    other="$(tr -dc '0-9' <"$SPOOL_PID_FILE" 2>/dev/null)"
    if [ -n "$other" ] && [ "$other" != "$$" ] &&
       kill -0 "$other" 2>/dev/null; then
        note "spooler already running (pid $other) -- exiting"
        exit 0
    fi
    printf '%s\n' "$$" >"$SPOOL_PID_FILE"
fi

# emit_receipt <one-line json> -- receipts land in the inbox for the spooler
# (the orchestrator reads the file) and on stdout for the classic wait.
emit_receipt() {
    if [ "$MODE" = "spool" ]; then
        printf '%s\n' "$1" >>"$INBOX"
    else
        printf '%s\n' "$1"
    fi
}

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

# release_worker <disp_id> <term> <mode> [<reap>] -- calls orca
# orchestration worker-release for <disp_id> (unless KEEP=1) and, when the
# release state is not released|closed|gone, closes <term> too. Prints
# "<released> <terminal_closed>" ("true"/"false") on stdout; human notes on
# stderr.
#
# reap=0 (default, a worker that already reported worker_done): a headless
# worker's terminal ended with its run, so a non-terminal state is left
# alone for it -- today's exact behaviour.
# reap=1 (a worker the stall scan is giving up on, which has NOT finished):
# the terminal is closed whenever the state was not released|closed|gone and
# a terminal id is known, headless included, because a stalled headless run
# is still running.
# KEEP=1 skips it all, as today: nothing is called, both outputs are false.
release_worker() {
    local disp="$1" term="$2" mode="$3" reap="${4:-0}"
    local released=false terminal_closed=false rel rel_state
    if [ "$KEEP" -eq 1 ]; then
        note "kept $disp (--keep)"
        printf 'false false\n'
        return 0
    fi
    if [ -z "$disp" ]; then
        printf 'false false\n'
        return 0
    fi
    if rel="$(orca_call orchestration worker-release --dispatch "$disp" --json)"; then
        rel_state="$(orca_field "$rel" '.result.state')"
        case "$rel_state" in
            released|closed|gone)
                released=true
                note "released $disp ($rel_state)"
                ;;
            *)
                # A non-terminal release state (e.g. "retained") leaves the
                # worker resident (~1 GB per idle opencode TUI) -- close its
                # terminal. A headless worker's terminal ended with its run
                # (claude-orca-ltd) UNLESS this is a reap: a stalled headless
                # run is still running and its terminal is still open.
                if [ "$reap" -eq 0 ] && [ "$mode" = "headless" ]; then
                    note "worker-release left $disp in state '$rel_state'; headless terminal ended with the run -- nothing to close"
                elif [ -n "$term" ] &&
                     orca_call terminal close --terminal "$term" \
                         --json >/dev/null 2>&1; then
                    released=true
                    terminal_closed=true
                    note "closed $term (worker-release left it retained)"
                else
                    note "worker-release left $disp in state '$rel_state' and terminal close ${term:-<no terminal>} failed -- the worker may stay resident"
                fi
                ;;
        esac
    else
        note "worker-release $disp: $(orca_error "$rel")"
    fi
    printf '%s %s\n' "$released" "$terminal_closed"
}

# detect_handoff <body> -- prints the HANDOFF block (the line that is
# exactly "HANDOFF", surrounding whitespace allowed, through the end of
# <body>) when one is present; exit 1, no output, otherwise. "HANDOFF"
# inside a longer line is not a handoff (epic claude-orca-7lz's SHARED
# CONTRACT).
#
# claude-orca-7lz.6: a block whose left: value -- trimmed, lowercased, one
# trailing "." dropped -- says nothing is left is NOT a handoff (a missing
# left: line still IS one; relaying costs one spawn, losing work costs
# more). "nothing" is deliberately left out of the excluded set below: the
# already-FROZEN happy-path case in tests/orca-relay.bats uses "left:
# nothing" as its "work remains" fixture, predating this bead, and existing
# cases are never edited -- see this bead's final report for the conflict.
detect_handoff() {
    local block left_line left_val
    block="$(printf '%s\n' "$1" | awk '
        BEGIN { found = 0 }
        {
            trimmed = $0
            gsub(/^[ \t]+|[ \t]+$/, "", trimmed)
            if (!found && trimmed == "HANDOFF") { found = 1 }
            if (found) { print }
        }
        END { exit(found ? 0 : 1) }
    ')" || return 1
    [ -n "$block" ] || return 1

    left_line="$(printf '%s\n' "$block" | grep -m1 -e '^left:')"
    if [ -n "$left_line" ]; then
        left_val="${left_line#left:}"
        left_val="$(printf '%s' "$left_val" | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//' | tr '[:upper:]' '[:lower:]')"
        case "$left_val" in *.) left_val="${left_val%.}" ;; esac
        case "$left_val" in
            ''|none|n/a|-) return 1 ;;
        esac
    fi

    printf '%s\n' "$block"
}

# --- the stall watch -----------------------------------------------------
#
# Returns 0 normally, 3 when it printed a fallback: the caller stops waiting
# so the orchestrator can re-run the slice in-process on the same worktree.
stall_scan() {
    local f now state act idle bead disp term wt model nudged mode
    local text cmd spec bj tmp rel_out r_released r_term_closed tc_note
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
        mode="$(jq -r '.mode // ""' "$f" 2>/dev/null)"
        nudged="$(jq -r '.nudged_at // 0' "$f" 2>/dev/null)"
        case "$nudged" in ''|*[!0-9]*) nudged=0 ;; esac

        # A bead that is already closed means its worker reported and the
        # record was missed (an old orca-wait): mark it done, never nudge.
        bj=""
        if [ -n "$bead" ]; then
            bj="$(orch_bead_json "$ROOT" "$bead")" || bj=""
            if [ -n "$bj" ] &&
               [ "$(printf '%s' "$bj" | jq -r '.status // ""')" = "closed" ]; then
                rel_out="$(release_worker "$disp" "$term" "$mode" 1)"
                r_released="${rel_out%% *}"
                r_term_closed="${rel_out##* }"
                tc_note=""
                [ "$r_term_closed" = "true" ] && tc_note=", terminal closed"
                note "[reap] $disp ($bead): closed bead -- worker released$tc_note"
                note "$disp (${bead:-no bead}): bead is closed -- marking the dispatch done"
                rec_set "$disp" --argjson n "$now" --argjson tc "$r_term_closed" \
                    '.state = "done" | .finished_at = $n | .reaped = true |
                     .terminal_closed = $tc |
                     .note = "bead closed; dispatch marked done by stall scan"'
                continue
            fi
        fi

        if [ "$nudged" -gt 0 ]; then
            spec=""
            [ -n "$bj" ] && spec="$(orch_spec "$bj" "$bead")"
            # the in-process executor the fallback spawns must not share the
            # worktree with a worker that is still (nominally) live -- reap
            # it before the fallback receipt goes out.
            rel_out="$(release_worker "$disp" "$term" "$mode" 1)"
            r_released="${rel_out%% *}"
            r_term_closed="${rel_out##* }"
            tc_note=""
            [ "$r_term_closed" = "true" ] && tc_note=", terminal closed"
            note "[reap] $disp ($bead): stalled twice -- worker released$tc_note"
            note "$disp (${bead:-no bead}) is still quiet ${idle}s after its nudge -- falling back to an in-process executor"
            emit_receipt "$(jq -n -c --arg bead "$bead" --arg disp "$disp" --arg term "$term" \
                --argjson idle "$idle" --arg wt "$wt" \
                --arg fb "$(orch_fallback "$spec" "$model")" \
                '{type: "stalled", bead: $bead, dispatch_id: $disp,
                  terminal: $term, idle_s: $idle, nudged: true,
                  worktree_path: $wt, fallback: $fb}')"
            # scanned no more, and the wait only ends if nothing else is live
            rec_set "$disp" --argjson tc "$r_term_closed" \
                '.state = "stalled" | .reaped = true | .terminal_closed = $tc'
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
        emit_receipt "$(jq -n -c --arg bead "$bead" --arg disp "$disp" --arg term "$term" \
            --argjson idle "$idle" --arg nudge "$cmd" \
            '{type: "stalled", bead: $bead, dispatch_id: $disp,
              terminal: $term, idle_s: $idle, nudge: $nudge}')"

        [ "$NUDGE" -eq 1 ] || continue
        if [ "$mode" = "headless" ]; then
            # A headless worker has no TUI to type a nudge into (its
            # terminal ended with the run, claude-orca-ltd): the stall
            # report above stands, and restarting the stall clock here
            # reaches the SUBAGENT FALLBACK below exactly as a nudge does
            # for a resident TUI.
            tmp="$f.tmp"
            jq --argjson n "$now" '.nudged_at = $n' "$f" >"$tmp" 2>/dev/null &&
                mv "$tmp" "$f"
            rm -f "$tmp"
            continue
        fi
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
    local task_id disp_id outcome files bead model agent drec released
    local term terminal_closed mode
    local handoff handoff_block rel_out
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
        handoff=false
        if [ "$mtype" = "worker_done" ]; then
            handoff_block=""
            if handoff_block="$(detect_handoff "$body")" && [ -n "$handoff_block" ]; then
                handoff=true
            fi
            if [ -n "$bead" ]; then
                orch_note_bead "$ROOT" "$bead" \
                    "ORCA WORKER_DONE outcome=${outcome:-unknown} task=$task_id dispatch=$disp_id files=$(printf '%s' "$files" | jq -r 'join(",")')
$subject: $body"
                if [ "$handoff" = "true" ]; then
                    orch_note_bead "$ROOT" "$bead" \
                        "HANDOFF-AT $(date -u +%Y-%m-%dT%H:%M:%SZ) dispatch=$disp_id
$handoff_block"
                    note "[relay] $bead handed off at its context budget -- orca-dispatch $bead starts a fresh worker from the HANDOFF in its notes"
                fi
            fi
            term=""
            mode=""
            if [ -f "$drec" ]; then
                term="$(jq -r '.terminal // ""' "$drec")"
                mode="$(jq -r '.mode // ""' "$drec")"
            fi
            terminal_closed=false
            if [ -n "$disp_id" ]; then
                rel_out="$(release_worker "$disp_id" "$term" "$mode" 0)"
                released="${rel_out%% *}"
                terminal_closed="${rel_out##* }"
            fi
            # a finished dispatch never goes back under the stall watch
            [ -n "$disp_id" ] && [ -f "$drec" ] &&
                rec_mark_done "$disp_id" "${outcome:-unknown}" "$released" \
                    "$terminal_closed"
            [ "$handoff" = "true" ] && [ -n "$disp_id" ] &&
                rec_set "$disp_id" '.handoff = true'
        fi

        note "$mtype from ${agent:-$from_h}${bead:+ [$bead]}: ${subject:-(no subject)}"
        emit_receipt "$(jq -n -c --arg type "$mtype" --arg id "$mid" --arg from "$from_h" \
            --arg subject "$subject" --arg body "$body" --arg task "$task_id" \
            --arg disp "$disp_id" --arg bead "$bead" --arg agent "$agent" \
            --arg model "$model" --arg outcome "$outcome" \
            --argjson files "$files" --argjson released "$released" \
            --argjson closed "$terminal_closed" --argjson handoff "$handoff" \
            --arg relay "orca-dispatch $bead" \
            --arg reply "orca-reply $mid <text>" '
            {type: $type, msg_id: $id, from: $from, subject: $subject,
             body: $body, task_id: $task, dispatch_id: $disp, bead: $bead,
             agent: $agent, model: $model, outcome: $outcome, files: $files,
             released: $released, terminal_closed: $closed}
            + (if $type == "worker_done" then
                 {handoff: $handoff} +
                 (if $handoff then {relay_with: $relay} else {} end)
               else {reply_with: $reply} end)')"
    done <"$msgs"
    return 0
}

# --- the rolling wait ----------------------------------------------------
#
# SPENT is the nominal time asked of the runtime, WALL the clock; the wait
# ends on whichever is larger, so a burst of heartbeats cannot spin the loop
# and a blocking check cannot overrun the caller's budget. In spool mode
# there is no budget: the loop runs until no dispatch record has been live
# for SPOOL_IDLE_S seconds.

case "$TIMEOUT_MS" in ''|*[!0-9]*) die "--timeout-ms wants whole milliseconds" ;; esac
SPOOL_IDLE_S="${CLAUDE_ORCA_SPOOL_IDLE_S:-1800}"
case "$SPOOL_IDLE_S" in ''|*[!0-9]*) die "CLAUDE_ORCA_SPOOL_IDLE_S wants whole seconds" ;; esac

# live_records -- how many dispatch records are still ready/running/
# dispatched; the spooler's idle clock is reset whenever this is > 0.
live_records() {
    local f s n=0
    for f in "$DISP_DIR"/*.json; do
        [ -f "$f" ] || continue
        s="$(jq -r '.state // ""' "$f" 2>/dev/null)"
        case "$s" in ready|running|dispatched) n=$(( n + 1 )) ;; esac
    done
    printf '%s' "$n"
}

# last_live_activity -- the newest activity second among the live dispatch
# records, 0 when there is none (claude-orca-csh): the spooler's idle clock
# counts from this, so a spooler whose Run went quiet long ago -- or whose
# dispatch dir is gone entirely -- does not earn a fresh SPOOL_IDLE_S
# window on start.
last_live_activity() {
    local f s a max=0
    for f in "$DISP_DIR"/*.json; do
        [ -f "$f" ] || continue
        s="$(jq -r '.state // ""' "$f" 2>/dev/null)"
        case "$s" in ready|running|dispatched) ;; *) continue ;; esac
        a="$(rec_activity "$f")"
        case "$a" in ''|*[!0-9]*) a=0 ;; esac
        [ "$a" -gt "$max" ] && max="$a"
    done
    printf '%s' "$max"
}

START_S="$(date +%s)"
SPENT=0; ELAPSED=0
LAST_LIVE="$(date +%s)"
if [ "$MODE" = "spool" ]; then
    LAST_LIVE="$(last_live_activity)"
    case "$LAST_LIVE" in ''|*[!0-9]*) LAST_LIVE=0 ;; esac
fi

while :; do
    # The spooler's only reason to exist is the dispatch dir under its Run:
    # with no readable dispatch dir there is nothing left to watch, so exit
    # at once instead of looping forever reparented to init (claude-orca-csh).
    if [ "$MODE" = "spool" ] && [ ! -r "$DISP_DIR" ]; then
        note "dispatch dir $DISP_DIR is gone -- spooler exiting"
        exit 0
    fi
    if [ "$MODE" != "spool" ]; then
        [ "$ELAPSED" -lt "$TIMEOUT_MS" ] || break
    fi
    ITER_START="$(date +%s)"
    WAIT_MS=$(( POLL * 1000 ))
    if [ "$MODE" != "spool" ]; then
        REMAINING=$(( TIMEOUT_MS - ELAPSED ))
        [ "$WAIT_MS" -gt "$REMAINING" ] && WAIT_MS="$REMAINING"
    fi
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
    if [ "$REAL_COUNT" -gt 0 ] && [ "$MODE" != "spool" ]; then
        exit 0
    fi

    stall_scan
    if [ "$?" -eq 3 ] && [ "$MODE" != "spool" ]; then
        exit 0
    fi

    if [ "$MODE" = "spool" ]; then
        # Pace the loop to the poll interval (--poll, from
        # CLAUDE_ORCA_WAIT_POLL_S): a check that returns instantly (a
        # stub, a reaped delivery) must not become a busy spin on the
        # runtime. The old fixed 1s pace ignored the poll setting and was
        # the `sleep 0.1` seen spinning forever in the mg8 hang
        # (claude-orca-csh).
        iter_ms=$(( ( $(date +%s) - ITER_START ) * 1000 ))
        if [ "$iter_ms" -lt "$WAIT_MS" ]; then
            rem=$(( WAIT_MS - iter_ms ))
            sleep "$(( rem / 1000 )).$(printf '%03d' "$(( rem % 1000 ))")"
        fi
        if [ "$(live_records)" -gt 0 ]; then
            LAST_LIVE="$(date +%s)"
        elif [ $(( $(date +%s) - LAST_LIVE )) -ge "$SPOOL_IDLE_S" ]; then
            note "no live dispatch for ${SPOOL_IDLE_S}s -- spooler exiting"
            exit 0
        fi
    fi

    SPENT=$(( SPENT + WAIT_MS ))
    ELAPSED=$(( ( $(date +%s) - START_S ) * 1000 ))
    [ "$SPENT" -gt "$ELAPSED" ] && ELAPSED="$SPENT"
done

note "no worker message within ${TIMEOUT_MS}ms"
jq -n -c --arg ms "$TIMEOUT_MS" '{type: "timeout", waited_ms: ($ms|tonumber)}'
exit 0
