#!/usr/bin/env bash
#
# dispatch.sh -- hand ONE bead to ONE headless worker, with no Orca in the
# loop (claude-orca-9bh.1; plan .claude/plans/ghostty.md "Workers without
# Orca"). The orca-dispatch of the Ghostty world: it makes a worktree and a
# job directory, starts scripts/worker-run.sh on the job detached, and
# returns at once with a receipt; the result arrives later as a line in
# orchestration/inbox.jsonl.
#
#   dispatch <bead-id> [--worker|--checker] [--agent claude|opencode]
#            [--model <id>] [--variant <v>] [--effort <e>]
#            [--worktree new|main|path:<dir>] [--prompt-file <file>]
#
# What it does, in order: read the bead (`bd show`) -> compose the headless
# spec (orch_spec ... headless, or --prompt-file verbatim) -> fill what the
# flags left open from the role's binding in tier.json -> pick the worktree
# (new = $CLAUDE_ORCA_WORKTREES_DIR|~/worktrees/<bead> on work/<bead> cut from
# main; an existing dir or branch is reused) -> install the frozen-contract
# pre-commit hook there -> write <root>/.claude-dev/run/workers/<job>/
# {spec.md,job.json} -> start worker-run on it (CLAUDE_ORCA_WORKER_RUN
# overrides the path) and print ONE receipt line of JSON on stdout. Human
# notes go to stderr, so `dispatch … | jq` is always safe.
#
# Exit codes: 0 started · 1 the worktree or job dir could not be made ·
# 2 usage/bead error.
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
# shellcheck source=lib/tier-roles.sh
. "$SCRIPT_DIR/lib/tier-roles.sh"
# shellcheck source=lib/orca-orch.sh
. "$SCRIPT_DIR/lib/orca-orch.sh"
# shellcheck source=lib/frozen-hook.sh
. "$SCRIPT_DIR/lib/frozen-hook.sh"

note() { printf '%s\n' "$*" >&2; }
die()  { printf 'dispatch: %s\n' "$*" >&2; exit "${2:-2}"; }

BEAD=""; ROLE="worker"; AGENT=""; MODEL=""; VARIANT=""; EFFORT=""
WORKTREE="new"; PROMPT_FILE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --worker)      ROLE="worker" ;;
        --checker)     ROLE="checker" ;;
        --agent)       AGENT="${2:-}"; shift ;;
        --model)       MODEL="${2:-}"; shift ;;
        --variant)     VARIANT="${2:-}"; shift ;;
        --effort)      EFFORT="${2:-}"; shift ;;
        --worktree)    WORKTREE="${2:-}"; shift ;;
        --prompt-file) PROMPT_FILE="${2:-}"; shift ;;
        -h|--help)     sed -n '3,25p' "$(_resolve_script_path)"; exit 0 ;;
        -*)            die "unknown flag: $1" ;;
        *)             [ -z "$BEAD" ] && BEAD="$1" || die "unexpected argument: $1" ;;
    esac
    shift
done

[ -n "$BEAD" ] || die "usage: dispatch <bead-id> [--worker|--checker] [--agent X --model Y] [--worktree new|main|path:<dir>]"
command -v jq >/dev/null 2>&1 || die "jq is required"

ROOT="$(orch_root)" || die "no project root: set CLAUDE_ORCA_ROOT or run inside the repo"
BEAD_JSON="$(orch_bead_json "$ROOT" "$BEAD")" ||
    die "bd show $BEAD failed in $ROOT (is beads initialised there?)"
if [ -n "$PROMPT_FILE" ]; then
    [ -f "$PROMPT_FILE" ] || die "--prompt-file $PROMPT_FILE: no such file"
    SPEC="$(cat "$PROMPT_FILE")"
else
    SPEC="$(orch_spec "$BEAD_JSON" "$BEAD" headless)"
fi

# --- what should run this slice: explicit flags, else tier.json ----------

STATE_FILE="${TIER_STATE_FILE:-}"
[ -n "$STATE_FILE" ] || STATE_FILE="$(tier_state_file 2>/dev/null)" || STATE_FILE=""
[ -n "$AGENT" ]   || AGENT="$(tier_role_field "$STATE_FILE" "$ROLE" agent)"
[ -n "$MODEL" ]   || MODEL="$(tier_role_field "$STATE_FILE" "$ROLE" model)"
[ -n "$VARIANT" ] || VARIANT="$(tier_role_field "$STATE_FILE" "$ROLE" variant)"
[ "$MODEL" = "inherit" ] && MODEL=""
[ -n "$AGENT" ] || AGENT="claude"
# An openrouter/ or openai/ model is opencode's business whatever the binding says.
case "$MODEL" in openrouter/*|openai/*) AGENT="opencode" ;; esac
[ "$AGENT" = "openrouter" ] && AGENT="opencode"
if [ "$AGENT" = "opencode" ]; then
    case "$MODEL" in openai/*)
        tier_openai_ready ||
            die "OpenAI is not signed in in this folder -- run /tier auth openai, then dispatch again" 2
        MODEL="$(tier_openai_resolve "$MODEL")" ||
            die "cannot resolve $MODEL to a model your OpenAI subscription serves (see: opencode models openai)" 2 ;;
    esac
fi
if [ -z "$EFFORT" ] && [ "$AGENT" = "claude" ]; then
    EFFORT="$(tier_claude_effort "$VARIANT")"
fi

# --- the worktree --------------------------------------------------------

BRANCH=""
case "$WORKTREE" in
    main)    WT="$ROOT" ;;
    path:*)  WT="${WORKTREE#path:}"
             [ -d "$WT" ] || die "--worktree $WORKTREE: no such directory" ;;
    new)     WT="${CLAUDE_ORCA_WORKTREES_DIR:-$HOME/worktrees}/$BEAD"
             BRANCH="work/$BEAD"
             if [ -d "$WT" ]; then
                 note "worktree $WT exists; reusing it"
             else
                 mkdir -p "$(dirname "$WT")" || die "cannot create $(dirname "$WT")" 1
                 if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
                     git -C "$ROOT" worktree add "$WT" "$BRANCH" >&2 ||
                         die "git worktree add $WT $BRANCH failed" 1
                 else
                     BASE=HEAD
                     git -C "$ROOT" show-ref --verify --quiet refs/heads/main && BASE=main
                     git -C "$ROOT" worktree add -b "$BRANCH" "$WT" "$BASE" >&2 ||
                         die "git worktree add -b $BRANCH $WT $BASE failed" 1
                 fi
             fi ;;
    *)       die "--worktree must be new, main or path:<dir> (got: $WORKTREE)" ;;
esac
[ -n "$BRANCH" ] || BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)" || BRANCH=""

HOOKS=""
HOOKS="$(install_frozen_hook "$WT" "$BEAD")" ||
    { note "frozen-hook: could not install pre-commit hook into $WT"; HOOKS=""; }

# --- the job -------------------------------------------------------------

WORKERS="$(workers_dir "$ROOT")"
mkdir -p "$WORKERS" || die "cannot create $WORKERS" 1
NOW="$(date +%s)"
while :; do
    JOB="$BEAD-$NOW-$(printf '%04x' "$RANDOM")"
    mkdir "$WORKERS/$JOB" 2>/dev/null && break
done
JOBDIR="$WORKERS/$JOB"
( umask 077; printf '%s\n' "$SPEC" >"$JOBDIR/spec.md" ) || die "cannot write $JOBDIR/spec.md" 1
jq -n --arg job "$JOB" --arg bead "$BEAD" --arg role "$ROLE" --arg agent "$AGENT" \
    --arg model "$MODEL" --arg variant "$VARIANT" --arg effort "$EFFORT" \
    --arg dir "$WT" --arg branch "$BRANCH" --arg hooks "$HOOKS" --argjson created "$NOW" \
    '{job:$job,bead:$bead,role:$role,agent:$agent,model:$model,variant:$variant,
      effort:$effort,dir:$dir,branch:$branch,frozen_hooks:$hooks,state:"started",created:$created}' \
    >"$JOBDIR/job.json" || die "cannot write $JOBDIR/job.json" 1

# --- start it, detached, and say so --------------------------------------

RUNNER="${CLAUDE_ORCA_WORKER_RUN:-$SCRIPT_DIR/worker-run.sh}"
setsid nohup "$RUNNER" "$JOBDIR" </dev/null >>"$JOBDIR/runner.log" 2>&1 &
note "dispatched $BEAD as $JOB ($AGENT${MODEL:+ $MODEL}) in $WT"

jq -n -c --arg job "$JOB" --arg bead "$BEAD" --arg agent "$AGENT" --arg model "$MODEL" \
    --arg dir "$WT" --arg branch "$BRANCH" \
    '{job:$job,bead:$bead,agent:$agent,model:$model,dir:$dir,branch:$branch,state:"started"}'
