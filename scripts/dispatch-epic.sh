#!/usr/bin/env bash
#
# dispatch-epic.sh -- run a whole epic in waves, with no Orca in the loop
# (claude-orca-9bh.3; plan .claude/plans/ghostty.md). The epic runner,
# built on scripts/dispatch.sh and the job.json files worker-run keeps.
# `dispatch --epic <epic> ...` execs this.
#
#   dispatch-epic --epic <epic-id> [--agent claude|opencode] [--model <id>]
#
# Children are the epic's open non-epic beads (`bd list --parent`). A child
# is ready when every open `blocks` blocker of it has settled DONE in this
# run (or is already closed in bd). Ready children are dispatched together
# (one wave), except that a child whose description/acceptance text names a
# path (x.sh, x.bats, x.md, x.json, x.yml) a running or just-picked child
# also names waits ("serialising"). In flight never exceeds workers_max
# (worker-run's slot flock still enforces it). All slices share ONE epic
# worktree, $CLAUDE_ORCA_WORKTREES_DIR|~/worktrees/<epic> on work/<epic>
# (one branch for the whole epic); EPIC READY names that branch.
#
# Waiting is a poll of each in-flight job's job.json state every
# CLAUDE_ORCA_EPIC_POLL_S (5) seconds; no progress for CLAUDE_ORCA_EPIC_IDLE_S
# (2700) seconds gives up on the workers still out (they are left running).
# A blocker whose worker FAILED never clears its dependents.
#
# Stdout, one line per event: `wave N: <ids>` · `serialising <id> (shares
# <token> with <id>)` · `done <id>` · `failed <id>` · `question <id> ...` ·
# `<id> blocked-by-failed <blocker>` · `waiting <id> on <blocker>`, then ONE
# of: `EPIC READY <epic> <branch>` (and a note on the epic bead) · `EPIC
# BLOCKED <epic> failed=<ids>` · `EPIC STALLED <epic> waiting=<ids>`.
#
# Exit codes: 0 ready (or no open children) · 1 usage/environment · 3 a
# slice failed (EPIC BLOCKED) · 5 stalled (nothing dispatchable, or idle).
#
# bash 3.2 clean (scripts/lint-bash32.sh scans all of scripts/): per-bead
# state lives in files under a temp dir, not in associative arrays.

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

note() { printf '%s\n' "$*" >&2; }
die()  { printf 'dispatch-epic: %s\n' "$*" >&2; exit "${2:-1}"; }
emit() { printf '%s\n' "$*"; }

EPIC=""; AGENT=""; MODEL=""
POLL="${CLAUDE_ORCA_EPIC_POLL_S:-5}"
IDLE_S="${CLAUDE_ORCA_EPIC_IDLE_S:-2700}"
case "$IDLE_S" in ''|*[!0-9]*) IDLE_S=2700 ;; esac

while [ "$#" -gt 0 ]; do
    case "$1" in
        --epic)  EPIC="${2:-}"; shift ;;
        --agent) AGENT="${2:-}"; shift ;;
        --model) MODEL="${2:-}"; shift ;;
        -h|--help) sed -n '3,34p' "$(_resolve_script_path)"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done
[ -n "$EPIC" ] || die "usage: dispatch --epic <epic-id> [--agent X] [--model Y]"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v bd >/dev/null 2>&1 || die "bd is required"
ROOT="$(orch_root)" || die "no project root: set CLAUDE_ORCA_ROOT"
DISPATCH_SH="$SCRIPT_DIR/dispatch.sh"
[ -x "$DISPATCH_SH" ] || die "no dispatch.sh beside me ($DISPATCH_SH)"
CAP="$(workers_max "$ROOT")"
ST="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-epic.XXXXXX")" || die "cannot make a temp dir"
trap 'rm -rf "$ST"' EXIT

KIDS=""; INFLIGHT=""; PICK=""; FAILED=""; WAVE=0; STALL=0; REAPED=0

st_get() { cat "$ST/s.$1" 2>/dev/null; }
st_set() { printf '%s' "$2" >"$ST/s.$1"; }

bead_tokens() {
    printf '%s' "$1" |
        grep -oE '[A-Za-z0-9_./-]+\.(sh|bats|md|json|yml)' 2>/dev/null |
        sort -u | tr '\n' ' '
}

load_epic() {
    local kids bead bj
    orch_bead_json "$ROOT" "$EPIC" >/dev/null || die "no such epic: $EPIC (bd show failed in $ROOT)"
    kids="$( (cd "$ROOT" && bd list --parent "$EPIC" -n 0 --json 2>/dev/null) |
        jq -r '.[]? | select(.status != "closed") | select(.issue_type != "epic") | .id' 2>/dev/null)"
    for bead in $kids; do
        bj="$(orch_bead_json "$ROOT" "$bead")" || continue
        printf '%s' "$bj" | jq -r '[.dependencies[]? | select(.dependency_type == "blocks")
            | select(.status != "closed") | .id] | join(" ")' >"$ST/b.$bead" 2>/dev/null
        bead_tokens "$(printf '%s' "$bj" |
            jq -r '(.description // "") + "\n" + (.acceptance_criteria // "")')" >"$ST/t.$bead"
        st_set "$bead" pending
        KIDS="$KIDS $bead"
    done
    note "epic $EPIC: $(printf '%s' "$KIDS" | wc -w | tr -d ' ') open children, cap $CAP"
}

# One worktree for the whole epic, cut from main like dispatch.sh's `new`.
epic_worktree() {
    local branch="work/$EPIC" base=HEAD
    WT="${CLAUDE_ORCA_WORKTREES_DIR:-$HOME/worktrees}/$EPIC"
    if [ -d "$WT" ]; then note "worktree $WT exists; reusing it"; return 0; fi
    mkdir -p "$(dirname "$WT")" || die "cannot create $(dirname "$WT")"
    if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$ROOT" worktree add "$WT" "$branch" >&2 || die "git worktree add $WT $branch failed"
    else
        git -C "$ROOT" show-ref --verify --quiet refs/heads/main && base=main
        git -C "$ROOT" worktree add -b "$branch" "$WT" "$base" >&2 ||
            die "git worktree add -b $branch $WT $base failed"
    fi
}

# blocker_state <id> -> done | failed | wait
blocker_state() {
    local b="$1" s
    if [ -f "$ST/s.$b" ]; then
        case "$(st_get "$b")" in done) echo done ;; failed|blocked) echo failed ;; *) echo wait ;; esac
        return 0
    fi
    [ -f "$ST/x.$b" ] && { echo done; return 0; }
    s="$( (cd "$ROOT" 2>/dev/null && bd show "$b" --json 2>/dev/null) |
        jq -r 'if type == "array" then .[0] else . end | .status // ""' 2>/dev/null)"
    if [ "$s" = closed ]; then : >"$ST/x.$b"; echo done; else echo wait; fi
}

# classify <bead> -> ready | wait | blocked <failed-blocker>
classify() {
    local b s w=0
    for b in $(cat "$ST/b.$1"); do
        s="$(blocker_state "$b")"
        [ "$s" = failed ] && { printf 'blocked %s' "$b"; return 0; }
        [ "$s" = wait ] && w=1
    done
    [ "$w" = 0 ] && echo ready || echo wait
}

# Pending children with a failed/blocked blocker become `blocked`, to a fixpoint.
settle_blocked() {
    local bead c changed=1
    while [ "$changed" = 1 ]; do
        changed=0
        for bead in $KIDS; do
            [ "$(st_get "$bead")" = pending ] || continue
            c="$(classify "$bead")"
            case "$c" in blocked*)
                st_set "$bead" blocked; changed=1
                emit "$bead blocked-by-failed ${c#blocked }" ;;
            esac
        done
    done
}

# shared_token <bead> -> "<token> <holder>" when it names a path a running
# or just-picked bead names.
shared_token() {
    local h t
    for h in $INFLIGHT $PICK; do
        for t in $(cat "$ST/t.$1"); do
            case " $(cat "$ST/t.$h") " in *" $t "*) printf '%s %s' "$t" "$h"; return 0 ;; esac
        done
    done
    return 1
}

select_wave() {
    local bead sh n
    PICK=""
    n="$(printf '%s' "$INFLIGHT" | wc -w | tr -d ' ')"
    for bead in $KIDS; do
        [ "$(st_get "$bead")" = pending ] || continue
        [ "$(classify "$bead")" = ready ] || continue
        [ "$n" -ge "$CAP" ] && break
        if sh="$(shared_token "$bead")"; then
            if [ ! -e "$ST/n.$bead.${sh#* }" ]; then
                : >"$ST/n.$bead.${sh#* }"
                emit "serialising $bead (shares ${sh% *} with ${sh#* })"
            fi
            continue
        fi
        PICK="$PICK $bead"; n=$(( n + 1 ))
    done
}

dispatch_bead() {
    local bead="$1" out rc job args
    args=("$bead" --worktree "path:$WT")
    [ -n "$AGENT" ] && args=("${args[@]}" --agent "$AGENT")
    [ -n "$MODEL" ] && args=("${args[@]}" --model "$MODEL")
    out="$("$DISPATCH_SH" "${args[@]}" </dev/null)"; rc=$?
    job="$(printf '%s\n' "$out" | tail -1 | jq -r '.job // empty' 2>/dev/null)"
    if [ "$rc" -ne 0 ] || [ -z "$job" ]; then
        st_set "$bead" failed; FAILED="$FAILED $bead"
        emit "failed $bead (dispatch exited $rc)"
        return 1
    fi
    st_set "$bead" inflight; INFLIGHT="$INFLIGHT $bead"
    printf '%s' "$(workers_dir "$ROOT")/$job" >"$ST/j.$bead"
}

# Read each in-flight job's state; settle the ones that reported.
reap() {
    local bead state left=""
    REAPED=0
    for bead in $INFLIGHT; do
        state="$(jq -r '.state // ""' "$(cat "$ST/j.$bead")/job.json" 2>/dev/null)"
        case "$state" in
            done)  st_set "$bead" done; emit "done $bead"; REAPED=1 ;;
            failed|stopped) st_set "$bead" failed; FAILED="$FAILED $bead"; emit "failed $bead"; REAPED=1 ;;
            question)
                if [ ! -e "$ST/q.$bead" ]; then
                    : >"$ST/q.$bead"; REAPED=1
                    emit "question $bead (answer: workers reply $bead \"<text>\")"
                fi
                left="$left $bead" ;;
            *) rm -f "$ST/q.$bead"; left="$left $bead" ;;
        esac
    done
    INFLIGHT="$left"
}

unfinished() {
    local bead out=""
    for bead in $KIDS; do
        case "$(st_get "$bead")" in pending|inflight) out="$out $bead" ;; esac
    done
    printf '%s' "$out"
}

epic_worktree
load_epic
[ -n "${KIDS# }" ] || { note "epic $EPIC has no open children -- nothing to run"; exit 0; }
LAST="$(date +%s)"
while :; do
    settle_blocked
    select_wave
    if [ -n "${PICK# }" ]; then
        WAVE=$(( WAVE + 1 )); emit "wave $WAVE: ${PICK# }"
        for bead in $PICK; do dispatch_bead "$bead"; done
        settle_blocked
        [ -z "${INFLIGHT# }" ] && continue
    fi
    if [ -z "${INFLIGHT# }" ]; then
        [ -z "$(unfinished)" ] && break
        for bead in $(unfinished); do
            emit "waiting $bead on $(for b in $(cat "$ST/b.$bead"); do
                [ "$(blocker_state "$b")" = done ] || { printf '%s' "$b"; break; }; done)"
        done
        STALL=1; break
    fi
    sleep "$POLL"
    reap
    if [ "$REAPED" = 1 ]; then LAST="$(date +%s)"
    elif [ $(( $(date +%s) - LAST )) -ge "$IDLE_S" ]; then
        note "no worker reported for ${IDLE_S}s; giving up on:$INFLIGHT (left running)"
        STALL=1; break
    fi
done

if [ -n "${FAILED# }" ]; then
    emit "EPIC BLOCKED $EPIC failed=$(printf '%s' "${FAILED# }" | tr ' ' ',')"; exit 3
fi
if [ "$STALL" = 1 ]; then
    emit "EPIC STALLED $EPIC waiting=$(printf '%s' "$(unfinished)" | sed 's/^ //; s/ /,/g')"; exit 5
fi
BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"; [ -n "$BRANCH" ] || BRANCH=HEAD
orch_note_bead "$ROOT" "$EPIC" \
    "DISPATCH EPIC merge_ready branch=$BRANCH -- every slice done; merge after review"
emit "EPIC READY $EPIC $BRANCH"
exit 0
