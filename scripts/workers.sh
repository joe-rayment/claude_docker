#!/usr/bin/env bash
#
# workers.sh -- the orchestrator's view of the headless workers, with no Orca
# in the loop (claude-orca-9bh.1; plan .claude/plans/ghostty.md "Workers
# without Orca"). `bin/workers` points here. The jobs it shows are the job
# directories dispatch.sh makes and worker-run.sh fills:
# <root>/.claude-dev/run/workers/<job>/ {job.json, spec.md, log.jsonl,
# receipt*.json, runner.log}.
#
#   workers [list] [--json]       header `workers R/MAX running · Q queued`,
#                                 then one row per job, newest first: job,
#                                 bead, agent:model, state, pid (alive|dead),
#                                 elapsed, last event. --json: one JSON line
#                                 per job instead of the table.
#   workers wait [--until <s>]    print the unread lines of the orchestration
#                                 inbox (the cursor lives in inbox.cursor);
#                                 with --until, block up to <s>
#                                 seconds for a new line (exit 4 on
#                                 silence). Also watches for stalls: a
#                                 running job whose log.jsonl has not grown
#                                 for CLAUDE_ORCA_STALL_S (600) seconds gets
#                                 ONE {"type":"stalled",...} inbox line.
#   workers reply <job> "<text>"  resume a finished/questioning job's agent
#                                 session with <text> (worker-run --resume).
#   workers tail <job> [--raw]    follow the job's log until it finishes,
#                                 readable (--raw: the jsonl as written).
#   workers stop <job>            TERM the worker, mark it stopped, say so in
#                                 the inbox.
#
# <job> is a full job id, a unique prefix of one, or a bead id (that bead's
# newest job).
#
# Environment: CLAUDE_ORCA_ROOT (project root), CLAUDE_ORCA_MAX_WORKERS,
# CLAUDE_ORCA_UNTIL_POLL_S (0.2), CLAUDE_ORCA_STALL_S (600),
# CLAUDE_ORCA_WORKER_RUN (the worker-run path `reply` starts).
#
# Exit codes: 0 ok (bare `wait` too, with nothing unread) · 2 usage, unknown
# job, or reply to a job with no session · 3 reply while the job still runs ·
# 4 wait --until ran out of seconds.
#
# bash 3.2 clean (scripts/lint-bash32.sh scans all of scripts/).

set -uo pipefail

_resolve_script_path() {
    local src="${BASH_SOURCE[0]}" link dir
    while [ -L "$src" ]; do
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(case "$src" in (*/*) cd "${src%/*}/" ;; esac && pwd)"; src="$dir/$link" ;;
        esac
    done
    printf '%s' "$src"
}
SCRIPT_DIR="$(_s="$(_resolve_script_path)"; case "$_s" in (*/*) cd "${_s%/*}/" ;; esac && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/workers.sh
. "$SCRIPT_DIR/lib/workers.sh"

note() { printf 'workers: %s\n' "$*" >&2; }
die()  { printf 'workers: %s\n' "$*" >&2; exit "${2:-2}"; }

command -v jq >/dev/null 2>&1 || die "jq is required"
ROOT="$(orch_root)" || die "no project root: set CLAUDE_ORCA_ROOT"
WDIR="$(workers_dir "$ROOT")"

# --- small helpers -------------------------------------------------------

US="$(printf '\037')"

# jfield <jobdir> <key> -- one job.json field as text ("" when absent/null).
jfield() { jq -r --arg k "$2" '(.[$k] // "") | tostring' "$1/job.json" 2>/dev/null; }

# is_active <state> -- a state worker-run / dispatch has not finished with.
is_active() { case "$1" in started|queued|running) return 0 ;; esac; return 1; }

# pid_alive <pid> -- 0 when the pid names a live process.
pid_alive() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$1" 2>/dev/null
}

# iso_epoch <2026-01-02T03:04:05Z> -- epoch seconds, GNU date then BSD date;
# empty when neither parses it.
iso_epoch() {
    [ -n "${1:-}" ] || return 0
    date -u -d "$1" +%s 2>/dev/null ||
        date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

# fmt_secs <n> -- 42s / 3m07s / 2h05m.
fmt_secs() {
    local n="${1:-0}"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -lt 60 ]; then printf '%ss' "$n"
    elif [ "$n" -lt 3600 ]; then printf '%sm%02ds' $(( n / 60 )) $(( n % 60 ))
    else printf '%sh%02dm' $(( n / 3600 )) $(( (n % 3600) / 60 )); fi
}

# job_dirs -- every job dir, newest first (by the epoch `created`, falling
# back to the dir's mtime; ties broken by name, descending).
job_dirs() {
    local d c
    [ -d "$WDIR" ] || return 0
    for d in "$WDIR"/*/; do
        d="${d%/}"
        [ -f "$d/job.json" ] || continue
        c="$(jfield "$d" created)"
        case "$c" in ''|*[!0-9]*) c="$(orch_mtime "$d/job.json")" ;; esac
        printf '%s %s\n' "${c:-0}" "$d"
    done | sort -k1,1nr -k2,2r | sed 's/^[0-9]* //'
}

# find_job <arg> -- set JOBDIR and JOB for a full job id, a bead id (that
# bead's newest job) or a unique job-id prefix; die 2 otherwise.
find_job() {
    local arg="${1:-}" d n=0 hit="" cand
    [ -n "$arg" ] || die "a job (id, unique prefix, or bead id) is required"
    case "$arg" in */*|.*) die "bad job name: $arg" ;; esac
    if [ -f "$WDIR/$arg/job.json" ]; then
        JOBDIR="$WDIR/$arg"; JOB="$arg"; return 0
    fi
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ "$(jfield "$d" bead)" = "$arg" ]; then JOBDIR="$d"; JOB="${d##*/}"; return 0; fi
    done <<EOF
$(job_dirs)
EOF
    for cand in "$WDIR/$arg"*; do
        [ -f "$cand/job.json" ] || continue
        n=$(( n + 1 )); hit="$cand"
    done
    [ "$n" -le 1 ] || die "'$arg' matches $n jobs; use a longer prefix or the full job id"
    [ "$n" -eq 1 ] || die "no such job: $arg"
    JOBDIR="$hit"; JOB="${hit##*/}"
}

# last_event <jobdir> -- one short line about the newest complete event in
# log.jsonl: its type plus the tool name or the first 60 characters of text.
# Empty when there is no log yet.
last_event() {
    [ -s "$1/log.jsonl" ] || return 0
    tail -n 20 "$1/log.jsonl" 2>/dev/null | jq -R -r '
        def clip: tostring | gsub("[\n\t]"; " ") | .[0:60];
        fromjson? | select(type == "object")
        | if .type == "assistant" then
            ((.message.content // []) | last // {}) as $b
            | "assistant " + (if $b.type == "tool_use" then ($b.name // "tool") | clip
                              else ($b.text // "") | clip end)
          elif .type == "result" then "result " + (.result // "" | clip)
          elif .type == "system" then "system " + (.subtype // "" | clip)
          elif .type == "text" then "text " + (.part.text // "" | clip)
          elif .type == "tool_use" then "tool " + (.part.tool // "" | clip)
          else (.type // "event" | clip) end' 2>/dev/null | tail -n 1
}

# job_row <jobdir> -- one record:
# job bead agent:model state pid-or-dead-or-- elapsed_s last_event, split by
# US (\037): a non-blank IFS keeps empty fields in place under `read`.
job_row() {
    local d="$1" st pid alive="-" start now end s_iso el
    st="$(jfield "$d" state)"; pid="$(jfield "$d" pid)"
    if is_active "$st" && [ -n "$pid" ]; then
        if pid_alive "$pid"; then alive="$pid"; else alive="dead"; fi
    fi
    now="$(date +%s)"
    s_iso="$(jfield "$d" started)"
    start="$(iso_epoch "$s_iso")"
    [ -n "$start" ] || start="$(jfield "$d" created)"
    case "$start" in ''|*[!0-9]*) start="$now" ;; esac
    if is_active "$st"; then end="$now"; else end="$(orch_mtime "$d/job.json")"; fi
    case "$end" in ''|*[!0-9]*) end="$now" ;; esac
    el=$(( end - start )); [ "$el" -ge 0 ] || el=0
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "${d##*/}" "$(jfield "$d" bead)" \
        "$(jfield "$d" agent):$(jfield "$d" model)" "$st" "$alive" "$el" "$(last_event "$d")"
}

# --- list ------------------------------------------------------------------

cmd_list() {
    local json=0 a rows="" row running=0 queued=0 max
    for a in "$@"; do
        case "$a" in --json) json=1 ;; *) die "list: unknown argument: $a" ;; esac
    done
    local d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        row="$(job_row "$d")"
        rows="${rows}${row}
"
    done <<EOF
$(job_dirs)
EOF
    max="$(workers_max "$ROOT")"
    while IFS="$US" read -r _j _b _am st alive _el _le; do
        [ -n "$_j" ] || continue
        [ "$alive" = "dead" ] && continue
        case "$st" in running) running=$(( running + 1 )) ;; queued|started) queued=$(( queued + 1 )) ;; esac
    done <<EOF
$rows
EOF
    if [ "$json" -eq 0 ]; then
        printf 'workers %s/%s running · %s queued\n' "$running" "$max" "$queued"
    fi
    while IFS="$US" read -r j b am st alive el le; do
        [ -n "$j" ] || continue
        if [ "$json" -eq 1 ]; then
            jq -n -c --arg job "$j" --arg bead "$b" --arg am "$am" --arg state "$st" \
                --arg pid "$alive" --arg el "$el" --arg last "$le" \
                '{job: $job, bead: $bead, agent: ($am | split(":")[0]),
                  model: ($am | split(":")[1:] | join(":")), state: $state,
                  pid: (if $pid == "-" or $pid == "dead" then null else ($pid | tonumber) end),
                  dead: ($pid == "dead"), elapsed_s: ($el | tonumber), last: $last}'
        else
            printf '%-34s %-18s %-20s %-8s %-7s %-7s %s\n' "$j" "$b" "$am" "$st" "$alive" \
                "$(fmt_secs "$el")" "$le"
        fi
    done <<EOF
$rows
EOF
}

# --- wait --------------------------------------------------------------------

# emit_unread -- print every complete inbox line past the cursor and move
# the cursor past the last one. Returns 0 when something was printed.
# A trailing partial line (a mid-append writer) is left for the next read.
# (The inbox is inbox.jsonl, the cursor is inbox.cursor, so two readers
# never double-deliver.)
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

# stall_watch -- every job in state running whose log.jsonl (job.json, before
# the first event) has not changed for CLAUDE_ORCA_STALL_S seconds (600) and
# has no stall.reported marker gets ONE inbox line and the marker. The marker
# is claimed first (noclobber), so two waiters never both report.
stall_watch() {
    local limit="${CLAUDE_ORCA_STALL_S:-600}" d m now idle bead job
    case "$limit" in ''|*[!0-9]*) limit=600 ;; esac
    now="$(date +%s)"
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        [ -e "$d/stall.reported" ] && continue
        m="$(orch_mtime "$d/log.jsonl")"
        [ -n "$m" ] || m="$(orch_mtime "$d/job.json")"
        case "$m" in ''|*[!0-9]*) continue ;; esac
        idle=$(( now - m ))
        [ "$idle" -ge "$limit" ] || continue
        [ "$(jfield "$d" state)" = "running" ] || continue
        ( set -C; : >"$d/stall.reported" ) 2>/dev/null || continue
        job="${d##*/}"; bead="$(jfield "$d" bead)"
        workers_inbox_append "$ROOT" "$(jq -n -c --arg bead "$bead" --arg job "$job" \
            --argjson idle "$idle" \
            '{type: "stalled", bead: $bead, dispatch_id: $job, job: $job, idle_s: $idle}')" ||
            rm -f "$d/stall.reported"
    done <<EOF
$(job_dirs)
EOF
}

cmd_wait() {
    local until_s="" deadline last_stall poll
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --until) case "${2:-}" in ''|*[!0-9]*) die "--until wants whole seconds" ;; esac
                     until_s="$2"; shift ;;
            *)       die "wait: unknown argument: $1" ;;
        esac
        shift
    done
    INBOX="$(orch_dir "$ROOT")/inbox.jsonl"
    CURSOR="$(orch_dir "$ROOT")/inbox.cursor"
    stall_watch
    if emit_unread; then exit 0; fi
    [ -n "$until_s" ] || exit 0
    poll="${CLAUDE_ORCA_UNTIL_POLL_S:-0.2}"
    deadline=$(( $(date +%s) + until_s ))
    last_stall="$(date +%s)"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        sleep "$poll"
        if [ $(( $(date +%s) - last_stall )) -ge 5 ]; then
            stall_watch; last_stall="$(date +%s)"
        fi
        emit_unread && exit 0
    done
    exit 4
}

# --- reply -------------------------------------------------------------------

cmd_reply() {
    [ "$#" -ge 2 ] || die "usage: workers reply <job> \"<text>\""
    local sid st runner
    find_job "$1"; shift
    sid="$(jfield "$JOBDIR" session_id)"; st="$(jfield "$JOBDIR" state)"
    if [ -z "$sid" ]; then
        die "job $JOB has no session id to resume (state: ${st:-unknown}); it records one when its turn ends" 2
    fi
    is_active "$st" && die "job $JOB is still $st; wait for it to finish, then reply" 3
    workers_job_set "$JOBDIR" state '"started"'
    workers_job_set "$JOBDIR" pid null
    runner="${CLAUDE_ORCA_WORKER_RUN:-$SCRIPT_DIR/worker-run.sh}"
    setsid nohup "$runner" "$JOBDIR" --resume "$sid" --message "$*" \
        </dev/null >>"$JOBDIR/runner.log" 2>&1 &
    jq -n -c --arg job "$JOB" '{job: $job, state: "resumed"}'
}

# --- tail --------------------------------------------------------------------

# render_log -- stdin: log.jsonl lines. stdout: assistant:/tool:/result:
# lines for claude stream-json and for opencode's text/tool_use events;
# anything else is skipped.
render_log() {
    jq -R -r '
        def flat: tostring | gsub("[\n\t]+"; " ");
        def tool($n; $i): "tool: " + ($n // "?" | flat) + " " + (($i // {}) | tojson | .[0:80]);
        fromjson? | select(type == "object")
        | if .type == "assistant" then
            ((.message.content // [])[]
             | if .type == "text" then "assistant: " + (.text // "" | flat)
               elif .type == "tool_use" then tool(.name; .input)
               else empty end)
          elif .type == "result" then "result: " + ((.result // "") | flat | .[0:200])
          elif .type == "text" then "assistant: " + (.part.text // "" | flat)
          elif .type == "tool_use" then tool(.part.tool; .part.state.input)
          else empty end' 2>/dev/null
}

cmd_tail() {
    local raw=0 name="" a seen=0 total st log pid
    for a in "$@"; do
        case "$a" in --raw) raw=1 ;; -*) die "tail: unknown flag: $a" ;; *) name="$a" ;; esac
    done
    find_job "$name"
    log="$JOBDIR/log.jsonl"
    while :; do
        # state first, then the log: the runner finishes the log before it
        # flips the state, so one more pass after "finished" drains it
        st="$(jfield "$JOBDIR" state)"; pid="$(jfield "$JOBDIR" pid)"
        total=0
        [ -f "$log" ] && total="$(wc -l <"$log" 2>/dev/null | tr -d '[:space:]')"
        if [ "${total:-0}" -gt "$seen" ]; then
            if [ "$raw" -eq 1 ]; then sed -n "$(( seen + 1 )),${total}p" "$log"
            else sed -n "$(( seen + 1 )),${total}p" "$log" | render_log; fi
            seen="$total"
        fi
        is_active "$st" || break
        if [ "$st" != "started" ] && [ -n "$pid" ] && ! pid_alive "$pid"; then
            note "job $JOB: worker $pid is gone (state still $st)"; break
        fi
        sleep 0.5
    done
}

# --- stop --------------------------------------------------------------------

cmd_stop() {
    [ "$#" -eq 1 ] || die "usage: workers stop <job>"
    local pid st bead i=0
    find_job "$1"
    st="$(jfield "$JOBDIR" state)"; pid="$(jfield "$JOBDIR" pid)"; bead="$(jfield "$JOBDIR" bead)"
    if ! is_active "$st"; then note "job $JOB is already $st"; return 0; fi
    if pid_alive "$pid"; then
        kill -TERM -- "-$pid" 2>/dev/null
        kill -TERM "$pid" 2>/dev/null
        while pid_alive "$pid" && [ "$i" -lt 25 ]; do sleep 0.2; i=$(( i + 1 )); done
        if pid_alive "$pid"; then
            kill -KILL -- "-$pid" 2>/dev/null
            kill -KILL "$pid" 2>/dev/null
        fi
    fi
    workers_job_set "$JOBDIR" state '"stopped"'
    workers_inbox_append "$ROOT" "$(jq -n -c --arg job "$JOB" --arg bead "$bead" \
        '{type: "worker_stopped", job: $job, bead: $bead}')"
    jq -n -c --arg job "$JOB" '{job: $job, state: "stopped"}'
}

# --- dispatch ------------------------------------------------------------------

CMD="${1:-list}"; [ "$#" -eq 0 ] || shift
case "$CMD" in
    list)    cmd_list "$@" ;;
    wait)    cmd_wait "$@" ;;
    reply)   cmd_reply "$@" ;;
    tail)    cmd_tail "$@" ;;
    stop)    cmd_stop "$@" ;;
    --json)  cmd_list --json "$@" ;;
    -h|--help|help) sed -n '3,41p' "$(_resolve_script_path)" ;;
    *)       die "unknown command: $CMD (list|wait|reply|tail|stop)" ;;
esac
