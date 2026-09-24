#!/usr/bin/env bash
#
# orca-run.sh -- run whole epics in parallel waves (claude-orca-qa2.16;
# plan .claude/plans/orca-orchestration.md "Parallel by default").
#
#   orca-run --epic <bead-id> [--epic <bead-id> …] [--max-parallel N]
#            [--agent claude|opencode|codex|bash] [--model <id>]
#            [--worktree <selector>] [--from <handle>] [--timeout-ms N]
#            [--max-idle-waits N] [--dispatch-timeout-ms N]
#
# The bias is "everything independent runs at once". Per epic: take one
# top-level Orca worktree (created once, reused by exact id afterwards),
# read the epic's open children from bd, mirror their bd `blocks` edges
# into one Orca Task each (`task-create --deps`), and then loop:
#
#   dispatch every ready bead at once  ->  orca-wait  ->  record the
#   worker_done on the bead and release the worker  ->  recompute ready
#   (`task-list --ready` intersected with bd's own blockers)  ->  dispatch
#   the newly ready set.
#
# Two beads are ready but NOT run together when their acceptance contracts
# or descriptions name the same file: overlapping FROZEN paths mean one
# worker would rewrite the other's file. Everything else shares the wave.
#
# When an epic's last child settles, orca-run sends `merge_ready` to the
# Run with the epic's branch and prints `EPIC READY <epic> <branch>`.
# Merging is NOT done here -- it stays with the orchestrator, after the
# verifier.
#
# Output: one compact JSON event per line on stdout --
#   {"event":"dispatch",   wave, epic, bead, task_id, dispatch_id, terminal, …}
#   {"event":"worker_done",wave, epic, bead, outcome, task_id, dispatch_id}
#   {"event":"question"|"escalation", …}    (answer with orca-reply)
#   {"event":"epic_ready", epic, branch}    + the plain EPIC READY line
#   {"event":"done", waves, dispatched, settled, failed}
# plus a per-wave status table and every human note on stderr.
#
# Exit codes: 0 every epic settled (or there was nothing to do) · 2 usage
# · 3 no reachable runtime / no such epic · 4 the runtime refused · 5 the
# run stalled (nothing in flight and nothing dispatchable).
#
# bash 3.2 clean (scripts/lint-bash32.sh scans all of scripts/): the maps
# below are newline-separated "key<TAB>value" strings read with awk, not
# associative arrays.

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
die()  { printf 'orca-run: %s\n' "$*" >&2; exit "${2:-2}"; }
emit() { printf '%s\n' "$1"; }

EPICS=""; AGENT=""; MODEL=""; WORKTREE=""; FROM=""
MAX_PARALLEL="${CLAUDE_ORCA_MAX_PARALLEL:-4}"
TIMEOUT_MS="${CLAUDE_ORCA_RUN_TIMEOUT_MS:-900000}"
DISPATCH_TIMEOUT_MS="${CLAUDE_ORCA_DISPATCH_TIMEOUT_MS:-90000}"
MAX_IDLE=3

while [ "$#" -gt 0 ]; do
    case "$1" in
        --epic)         EPICS="$EPICS ${2:-}"; shift ;;
        --agent)        AGENT="${2:-}"; shift ;;
        --model)        MODEL="${2:-}"; shift ;;
        --worktree)     WORKTREE="${2:-}"; shift ;;
        --from)         FROM="${2:-}"; shift ;;
        --max-parallel) MAX_PARALLEL="${2:-}"; shift ;;
        --timeout-ms)   TIMEOUT_MS="${2:-}"; shift ;;
        --dispatch-timeout-ms) DISPATCH_TIMEOUT_MS="${2:-}"; shift ;;
        --max-idle-waits)      MAX_IDLE="${2:-}"; shift ;;
        -h|--help)      sed -n '3,43p' "$(_resolve_script_path)"; exit 0 ;;
        *)              die "unknown argument: $1" ;;
    esac
    shift
done

[ -n "$EPICS" ] || die "usage: orca-run --epic <bead-id> [--epic <bead-id> …]"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v bd >/dev/null 2>&1 || die "bd is required"

ROOT="$(orch_root)" || die "no project root: set CLAUDE_ORCA_ROOT"
DISPATCH_SH="$SCRIPT_DIR/orca-dispatch.sh"
WAIT_SH="$SCRIPT_DIR/orca-wait.sh"
[ -x "$DISPATCH_SH" ] || die "no orca-dispatch beside me ($DISPATCH_SH)"
[ -x "$WAIT_SH" ] || die "no orca-wait beside me ($WAIT_SH)"

orca_reachable || die "no Orca runtime is reachable (ORCA_USER_DATA_PATH=${ORCA_USER_DATA_PATH:-unset})" 3

HANDLE="$(orch_handle "$FROM")"
FROM_ARGS=()
[ -n "$HANDLE" ] && FROM_ARGS=(--from "$HANDLE")

RUN_ID="$(orch_ensure_run "$ROOT" "$HANDLE")" || die "could not bind a Run" 4

# --- the maps ------------------------------------------------------------
#
# Newline-separated "key<TAB>value" records. bash 3.2 has no associative
# arrays and macOS ships 3.2, so every lookup is one awk.

CHILDREN=""   # epic<TAB>bead
TASKMAP=""    # bead<TAB>task_id
BLOCKMAP=""   # bead<TAB>blocker,blocker,…   (bd `blocks` edges)
TOKMAP=""     # bead<TAB>tok tok …           (file paths it would touch)
WTMAP=""      # epic<TAB>worktree-selector
BRMAP=""      # epic<TAB>branch
INFLIGHT=""   # bead<TAB>dispatch_id<TAB>task_id<TAB>epic
SETTLED=" "   # space-delimited bead ids that reported (or failed to start)
FAILED=" "
EPICS_DONE=" "

map_get() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { print $2; exit }'; }
map_keys() { printf '%s\n' "$1" | awk -F'\t' 'NF { print $1 }'; }
map_vals() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { print $2 }'; }
in_set() { case "$2" in *" $1 "*) return 0 ;; esac; return 1; }

# The file paths a bead would touch: every path-looking token in its
# description and its acceptance contract (that is where FROZEN lives).
bead_tokens() {
    printf '%s' "$1" |
        grep -oE '[A-Za-z0-9_./-]+\.(sh|bats|md|json|yml)' 2>/dev/null |
        sort -u | tr '\n' ' '
}

# Do two token sets share a path? Then the two beads cannot share a wave.
overlaps() {
    local t
    for t in $1; do
        case " $2 " in *" $t "*) return 0 ;; esac
    done
    return 1
}

is_child() {
    printf '%s\n' "$CHILDREN" |
        awk -F'\t' -v b="$1" '$2 == b { f = 1 } END { exit !f }'
}

# --- one top-level Orca worktree per epic --------------------------------
#
# Epics run side by side in separate checkouts, so a wave never has two
# workers writing the same working tree. The first call creates it; every
# later worker of the epic reuses the EXACT id recorded here, which is why
# the record lives in run/ and not in memory. An explicit --worktree turns
# all of this off and puts every epic in that one selector.

epic_worktree() {
    local epic="$1" f slug out wid wpath branch
    f="$(orch_epic_file "$ROOT" "$epic")"
    if [ -n "$WORKTREE" ]; then
        WTMAP="$WTMAP$epic	$WORKTREE
"
        branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        [ -n "$branch" ] || branch="HEAD"
        BRMAP="$BRMAP$epic	$branch
"
        return 0
    fi
    mkdir -p "$(dirname "$f")" 2>/dev/null
    if [ -f "$f" ]; then
        wid="$(jq -r '.worktree_id // ""' "$f" 2>/dev/null)"
        branch="$(jq -r '.branch // ""' "$f" 2>/dev/null)"
        if [ -n "$wid" ]; then
            note "epic $epic reuses worktree $wid"
            WTMAP="$WTMAP$epic	id:$wid
"
            BRMAP="$BRMAP$epic	$branch
"
            return 0
        fi
    fi
    slug="$(printf '%s' "$epic" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9-]/-/g')"
    out="$(orca_call worktree create --name "$slug" --repo "path:$ROOT" \
        --no-parent --setup skip --json)" || {
        note "worktree create for $epic failed: $(orca_error "$out")"
        return 1
    }
    wid="$(orca_field "$out" '.result.worktree.id')"
    wpath="$(orca_field "$out" '.result.worktree.path')"
    branch="$(orca_field "$out" '.result.worktree.branch')"
    branch="${branch#refs/heads/}"
    [ -n "$wid" ] || { note "worktree create for $epic returned no id"; return 1; }
    jq -n --arg e "$epic" --arg s "$slug" --arg i "$wid" --arg p "$wpath" \
        --arg b "$branch" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{epic: $e, slug: $s, worktree_id: $i, worktree_path: $p,
          branch: $b, created: $t}' >"$f"
    note "epic $epic -> worktree $slug ($branch)"
    WTMAP="$WTMAP$epic	id:$wid
"
    BRMAP="$BRMAP$epic	$branch
"
    return 0
}

# --- the epic's children, and their DAG in Orca --------------------------

load_epic() {
    local epic="$1" kids bead bj blockers toks n=0
    kids="$( (cd "$ROOT" && bd list --parent "$epic" -n 0 --json 2>/dev/null) |
        jq -r '.[]? | select(.status != "closed")
               | select(.issue_type != "epic") | .id' 2>/dev/null)"
    [ -n "$kids" ] || { note "epic $epic has no open children"; return 1; }
    for bead in $kids; do
        bj="$(orch_bead_json "$ROOT" "$bead")" || continue
        blockers="$(printf '%s' "$bj" | jq -r '
            [.dependencies[]? | select(.dependency_type == "blocks")
             | select(.status != "closed") | .id] | join(",")' 2>/dev/null)"
        toks="$(bead_tokens "$(printf '%s' "$bj" |
            jq -r '(.description // "") + "\n" + (.acceptance_criteria // "")')")"
        CHILDREN="$CHILDREN$epic	$bead
"
        BLOCKMAP="$BLOCKMAP$bead	$blockers
"
        TOKMAP="$TOKMAP$bead	$toks
"
        n=$(( n + 1 ))
    done
    note "epic $epic: $n open children"
    return 0
}

# One Orca Task per bead, created in dependency order so a dependent can
# name its blockers' task ids in --deps. That mirrored DAG is what makes
# `task-list --ready` the coordinator's external memory.
create_tasks() {
    local epic="$1" pass bead pending remaining blockers blocker bt depids
    local ok out task spec bj title
    pending="$(map_vals "$CHILDREN" "$epic" | tr '\n' ' ')"
    for pass in 1 2 3 4 5 6 7 8 9 10; do
        [ -n "$(printf '%s' "$pending" | tr -d ' ')" ] || break
        remaining=""
        for bead in $pending; do
            ok=1; depids=""
            blockers="$(map_get "$BLOCKMAP" "$bead" | tr ',' ' ')"
            for blocker in $blockers; do
                is_child "$blocker" || continue
                bt="$(map_get "$TASKMAP" "$blocker")"
                if [ -z "$bt" ]; then ok=0; break; fi
                depids="$depids $bt"
            done
            if [ "$ok" != 1 ]; then remaining="$remaining $bead"; continue; fi
            bj="$(orch_bead_json "$ROOT" "$bead")" || continue
            spec="$(orch_spec "$bj" "$bead")"
            title="$(printf '%s' "$bj" | jq -r '.title // ""')"
            out="$(orca_call orchestration task-create --spec "$spec" \
                --task-title "$bead: $title" --display-name "$bead" \
                --deps "$(jq -n -c --arg s "$depids" \
                    '$s | split(" ") | map(select(length > 0))')" \
                --run "$RUN_ID" ${FROM_ARGS[@]+"${FROM_ARGS[@]}"} --json)" || {
                note "task-create for $bead failed: $(orca_error "$out")"
                continue
            }
            task="$(orca_field "$out" '.result.task.id')"
            [ -n "$task" ] || { note "task-create for $bead returned no id"; continue; }
            TASKMAP="$TASKMAP$bead	$task
"
        done
        pending="$remaining"
    done
    if [ -n "$(printf '%s' "$pending" | tr -d ' ')" ]; then
        note "dependency cycle among:$pending -- left without Tasks"
    fi
}

# --- the wave ------------------------------------------------------------

epic_of() {
    printf '%s\n' "$CHILDREN" | awk -F'\t' -v b="$1" '$1 != "" && $2 == b { print $1; exit }'
}
is_inflight() {
    printf '%s\n' "$INFLIGHT" | awk -F'\t' -v b="$1" '$1 == b { f = 1 } END { exit !f }'
}
inflight_count() { printf '%s\n' "$INFLIGHT" | awk -F'\t' 'NF { n++ } END { print n + 0 }'; }
inflight_tokens() {
    local b out=""
    for b in $(map_keys "$INFLIGHT"); do out="$out $(map_get "$TOKMAP" "$b")"; done
    printf '%s' "$out"
}

# A bd blocker that neither closed nor reported in this run still blocks,
# whatever Orca thinks: this is the "intersected with bd" half of ready.
blockers_clear() {
    local blocker st
    for blocker in $(map_get "$BLOCKMAP" "$1" | tr ',' ' '); do
        in_set "$blocker" "$SETTLED" && continue
        st="$( (cd "$ROOT" 2>/dev/null && bd show "$blocker" --json 2>/dev/null) |
            jq -r 'if type == "array" then .[0] else . end | .status // ""' 2>/dev/null)"
        [ "$st" = "closed" ] || return 1
    done
    return 0
}

# PICK: what may be dispatched right now, across every epic at once.
select_wave() {
    local epic bead task toks picked_toks n
    PICK=""
    n="$(inflight_count)"
    picked_toks="$(inflight_tokens)"
    for epic in $LIVE_EPICS; do
        for bead in $(map_vals "$CHILDREN" "$epic"); do
            in_set "$bead" "$SETTLED" && continue
            is_inflight "$bead" && continue
            task="$(map_get "$TASKMAP" "$bead")"
            [ -n "$task" ] || continue
            case " $READY_NOW " in *" $task "*) ;; *) continue ;; esac
            blockers_clear "$bead" || continue
            if [ "$n" -ge "$MAX_PARALLEL" ]; then
                note "max-parallel $MAX_PARALLEL reached; the rest waits"
                return 0
            fi
            toks="$(map_get "$TOKMAP" "$bead")"
            if overlaps "$toks" "$picked_toks"; then
                note "serialising $bead: it names a file a running slice names"
                continue
            fi
            picked_toks="$picked_toks $toks"
            PICK="$PICK $bead"
            n=$(( n + 1 ))
        done
    done
}

dispatch_bead() {
    local bead="$1" epic wt task out rc receipt did term agent model state args
    epic="$(epic_of "$bead")"
    wt="$(map_get "$WTMAP" "$epic")"
    task="$(map_get "$TASKMAP" "$bead")"
    args=("$bead" --task "$task" --worktree "$wt" --timeout-ms "$DISPATCH_TIMEOUT_MS")
    [ -n "$AGENT" ] && args=("${args[@]}" --agent "$AGENT")
    [ -n "$MODEL" ] && args=("${args[@]}" --model "$MODEL")
    [ -n "$HANDLE" ] && args=("${args[@]}" --from "$HANDLE")

    out="$("$DISPATCH_SH" "${args[@]}" </dev/null 3>&-)"
    rc=$?
    receipt="$(printf '%s\n' "$out" | tail -1)"
    if [ "$rc" -ne 0 ] ||
       ! printf '%s' "$receipt" | jq -e '.dispatch_id' >/dev/null 2>&1; then
        note "dispatch of $bead failed (orca-dispatch exit $rc)"
        SETTLED="$SETTLED$bead "
        FAILED="$FAILED$bead "
        emit "$(jq -n -c --arg e "$epic" --arg b "$bead" --argjson w "$WAVE" \
            '{event: "dispatch_failed", wave: $w, epic: $e, bead: $b}')"
        return 1
    fi
    did="$(printf '%s' "$receipt" | jq -r '.dispatch_id')"
    term="$(printf '%s' "$receipt" | jq -r '.terminal')"
    agent="$(printf '%s' "$receipt" | jq -r '.agent')"
    model="$(printf '%s' "$receipt" | jq -r '.model')"
    state="$(printf '%s' "$receipt" | jq -r '.state')"
    INFLIGHT="$INFLIGHT$bead	$did	$task	$epic
"
    TOTAL_D=$(( TOTAL_D + 1 ))
    emit "$(jq -n -c --arg e "$epic" --arg b "$bead" --arg t "$task" \
        --arg d "$did" --arg term "$term" --arg a "$agent" --arg m "$model" \
        --arg s "$state" --arg wt "$wt" --argjson w "$WAVE" \
        '{event: "dispatch", wave: $w, epic: $e, bead: $b, task_id: $t,
          dispatch_id: $d, terminal: $term, agent: $a, model: $m,
          state: $s, worktree: $wt}')"
    return 0
}

# One rolling wait, through orca-wait: it appends the outcome to the bead
# and releases the worker; we only have to learn who reported.
run_wait() {
    local out line mtype bead outcome task did wargs
    WAIT_GOT=0
    wargs=(--poll-loop --timeout-ms "$TIMEOUT_MS")
    [ -n "$HANDLE" ] && wargs=("${wargs[@]}" --from "$HANDLE")
    out="$("$WAIT_SH" "${wargs[@]}" </dev/null 3>&-)"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s' "$line" | jq -e 'type == "object"' >/dev/null 2>&1 || continue
        mtype="$(printf '%s' "$line" | jq -r '.type // ""')"
        [ "$mtype" = "timeout" ] && continue
        bead="$(printf '%s' "$line" | jq -r '.bead // ""')"
        outcome="$(printf '%s' "$line" | jq -r '.outcome // ""')"
        task="$(printf '%s' "$line" | jq -r '.task_id // ""')"
        did="$(printf '%s' "$line" | jq -r '.dispatch_id // ""')"
        if [ "$mtype" != "worker_done" ]; then
            emit "$(printf '%s' "$line" | jq -c --arg e "$mtype" '{event: $e} + .')"
            continue
        fi
        if [ -z "$bead" ] || ! is_child "$bead"; then
            note "worker_done for ${bead:-an unknown bead}, not one of mine"
            continue
        fi
        SETTLED="$SETTLED$bead "
        if [ "$outcome" = "failed" ]; then FAILED="$FAILED$bead "; fi
        INFLIGHT="$(printf '%s\n' "$INFLIGHT" | awk -F'\t' -v b="$bead" 'NF && $1 != b')"
        [ -n "$INFLIGHT" ] && INFLIGHT="$INFLIGHT
"
        TOTAL_S=$(( TOTAL_S + 1 ))
        WAIT_GOT=$(( WAIT_GOT + 1 ))
        emit "$(jq -n -c --arg e "$(epic_of "$bead")" --arg b "$bead" \
            --arg o "$outcome" --arg t "$task" --arg d "$did" --argjson w "$WAVE" \
            '{event: "worker_done", wave: $w, epic: $e, bead: $b, outcome: $o,
              task_id: $t, dispatch_id: $d}')"
    done <<EOF
$out
EOF
}

# The epic's last slice has settled: tell the Run, and say so on stdout.
# Merging is the orchestrator's, after the verifier -- never ours.
finish_epic() {
    local epic="$1" branch out
    branch="$(map_get "$BRMAP" "$epic")"
    [ -n "$branch" ] || branch="HEAD"
    out="$(orca_call orchestration send --type merge_ready \
        --subject "epic $epic" --body "$branch" --run "$RUN_ID" \
        ${FROM_ARGS[@]+"${FROM_ARGS[@]}"} --json)" ||
        note "merge_ready for $epic failed: $(orca_error "$out")"
    orch_note_bead "$ROOT" "$epic" \
        "ORCA RUN merge_ready branch=$branch -- every slice settled; merge after the verifier"
    emit "$(jq -n -c --arg e "$epic" --arg b "$branch" \
        '{event: "epic_ready", epic: $e, branch: $b}')"
    printf 'EPIC READY %s %s\n' "$epic" "$branch"
}

check_epics() {
    local epic bead all
    for epic in $LIVE_EPICS; do
        in_set "$epic" "$EPICS_DONE" && continue
        all=1
        for bead in $(map_vals "$CHILDREN" "$epic"); do
            in_set "$bead" "$SETTLED" || { all=0; break; }
        done
        [ "$all" = 1 ] || continue
        EPICS_DONE="$EPICS_DONE$epic "
        finish_epic "$epic"
    done
}

status_table() {
    local epic bead st
    note "--- wave $WAVE ------------------------------------------------"
    for epic in $LIVE_EPICS; do
        for bead in $(map_vals "$CHILDREN" "$epic"); do
            if in_set "$bead" "$FAILED"; then st="failed"
            elif in_set "$bead" "$SETTLED"; then st="settled"
            elif is_inflight "$bead"; then st="running"
            else st="waiting"; fi
            printf '  %-14s %-26s %s\n' "$epic" "$bead" "$st" >&2
        done
    done
}

# --- go ------------------------------------------------------------------

WAVE=0; IDLE=0; STALL=0; TOTAL_D=0; TOTAL_S=0
READY_NOW=""; PICK=""; WAIT_GOT=0; LIVE_EPICS=""

for epic in $EPICS; do
    orch_bead_json "$ROOT" "$epic" >/dev/null 2>&1 ||
        die "no such bead in $ROOT: $epic" 3
    load_epic "$epic" || continue
    epic_worktree "$epic" || die "could not place epic $epic in a worktree" 4
    create_tasks "$epic"
    LIVE_EPICS="$LIVE_EPICS $epic"
done

finish() {
    local failed
    failed="$(printf '%s' "$FAILED" | wc -w | tr -d ' ')"
    emit "$(jq -n -c --argjson w "$WAVE" --argjson d "$TOTAL_D" \
        --argjson s "$TOTAL_S" --argjson f "$failed" \
        '{event: "done", waves: $w, dispatched: $d, settled: $s, failed: $f}')"
}

if [ -z "$(printf '%s' "$LIVE_EPICS" | tr -d ' ')" ]; then
    note "nothing to run"
    finish
    exit 0
fi
if [ "$MAX_PARALLEL" -le 0 ]; then
    note "--max-parallel 0: dispatching nothing"
    finish
    exit 0
fi

while :; do
    READY_NOW="$(orca_field "$(orca_call orchestration task-list --run "$RUN_ID" \
        --ready ${FROM_ARGS[@]+"${FROM_ARGS[@]}"} --json)" \
        '[.result.tasks[]?.id] | join(" ")')"
    select_wave
    if [ -n "$(printf '%s' "$PICK" | tr -d ' ')" ]; then
        WAVE=$(( WAVE + 1 ))
        for bead in $PICK; do dispatch_bead "$bead"; done
        status_table
    fi
    check_epics

    remaining=0
    for epic in $LIVE_EPICS; do
        for bead in $(map_vals "$CHILDREN" "$epic"); do
            in_set "$bead" "$SETTLED" || remaining=1
        done
    done
    [ "$remaining" -eq 0 ] && break

    if [ "$(inflight_count)" -eq 0 ]; then
        note "nothing in flight and nothing dispatchable -- stopping"
        STALL=1
        break
    fi

    run_wait
    if [ "$WAIT_GOT" -eq 0 ]; then
        IDLE=$(( IDLE + 1 ))
        note "no worker reported within ${TIMEOUT_MS}ms ($IDLE/$MAX_IDLE)"
        if [ "$IDLE" -ge "$MAX_IDLE" ]; then
            note "giving up on $(inflight_count) worker(s) still out"
            STALL=1
            break
        fi
    else
        IDLE=0
    fi
    check_epics
done

check_epics
finish
[ "$STALL" -eq 1 ] && exit 5
exit 0
