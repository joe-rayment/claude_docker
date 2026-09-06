#!/usr/bin/env bash
#
# orca-dispatch.sh -- hand ONE bead to ONE worker, as a first-class Orca
# session rather than an in-process sub-agent (claude-orca-qa2.13; plan
# .claude/plans/orca-orchestration.md "The orchestrator's tools").
#
#   orca-dispatch <bead-id> [--worker|--checker] [--backend orca|subagent]
#                 [--agent claude|opencode|codex|gemini|bash] [--model <id>]
#                 [--worktree current|new-child|path:<dir>|id:<wt>|…]
#                 [--task <task_id>] [--task-deps <json array>]
#                 [--from <handle>] [--timeout-ms <n>]
#
# What it does, in order: resolve the coordinator handle -> ensure ONE Run
# per coordinator (<root>/.claude-dev/run/orchestration/run.json, reused by
# run-use) -> compose the Task spec from `bd show` (title, description,
# acceptance contract, WORKER RULES) -> start the worker per agent:
#
#   claude|codex|gemini  worker-start --agent <a> --model <m>   (Orca launches
#                        the TUI in a worktree and injects the spec)
#   opencode             terminal create --command "opencode --model <m>"
#                        -> terminal wait --for tui-idle
#                        -> worker-start --terminal <handle>  (adoption: Orca
#                        does not launch opencode itself)
#   bash                 terminal create --command bash -> dispatch --to
#                        (a context-only Dispatch: a bare shell has no agent
#                        to inject into; this is what the integration test
#                        drives, and what a human-driven pane gets)
#
# Then it records task/dispatch ids on the bead, writes the dispatch record
# and prints ONE receipt (single-line JSON) on stdout. Human notes go to
# stderr, so `orca-dispatch … | jq` is always safe.
#
# Exit codes: 0 dispatched · 2 usage/bead error · 3 NOT dispatched -- the
# Agent-tool fallback spec is on stdout (unreachable runtime, or an explicit
# --backend subagent) · 4 the runtime refused the launch.
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
# shellcheck source=lib/tier-roles.sh
. "$SCRIPT_DIR/lib/tier-roles.sh"
# shellcheck source=lib/orca-orch.sh
. "$SCRIPT_DIR/lib/orca-orch.sh"

note() { printf '%s\n' "$*" >&2; }
die()  { printf 'orca-dispatch: %s\n' "$*" >&2; exit "${2:-2}"; }

BEAD=""; ROLE="worker"; BACKEND=""; AGENT=""; MODEL=""; WORKTREE=""
FROM=""; TIMEOUT_MS="${CLAUDE_ORCA_DISPATCH_TIMEOUT_MS:-90000}"
TASK_ID=""; TASK_DEPS=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --worker)   ROLE="worker" ;;
        --checker)  ROLE="checker" ;;
        --recon)    ROLE="recon" ;;
        --backend)  BACKEND="${2:-}"; shift ;;
        --agent)    AGENT="${2:-}"; shift ;;
        --model)    MODEL="${2:-}"; shift ;;
        --worktree) WORKTREE="${2:-}"; shift ;;
        --task)     TASK_ID="${2:-}"; shift ;;
        --task-deps) TASK_DEPS="${2:-}"; shift ;;
        --from)     FROM="${2:-}"; shift ;;
        --timeout-ms) TIMEOUT_MS="${2:-}"; shift ;;
        -h|--help)  sed -n '3,33p' "$(_resolve_script_path)"; exit 0 ;;
        -*)         die "unknown flag: $1" ;;
        *)          [ -z "$BEAD" ] && BEAD="$1" || die "unexpected argument: $1" ;;
    esac
    shift
done

[ -n "$BEAD" ] || die "usage: orca-dispatch <bead-id> [--worker|--checker] [--agent X --model Y]"
command -v jq >/dev/null 2>&1 || die "jq is required"

ROOT="$(orch_root)" || die "no project root: set CLAUDE_ORCA_ROOT or run inside the repo"

BEAD_JSON="$(orch_bead_json "$ROOT" "$BEAD")" ||
    die "bd show $BEAD failed in $ROOT (is beads initialised there?)"
SPEC="$(orch_spec "$BEAD_JSON" "$BEAD")"
TITLE="$(printf '%s' "$BEAD_JSON" | jq -r '.title // ""')"

# --- what should run this slice ------------------------------------------
#
# The explicit flags win; anything left open comes from the role's binding
# in tier.json (v1 files read as subagent+claude, see lib/tier-roles.sh).

STATE_FILE="${TIER_STATE_FILE:-}"
[ -n "$STATE_FILE" ] || STATE_FILE="$(tier_state_file 2>/dev/null)" || STATE_FILE=""

# tier_role's default for a v1 (or absent) tier.json is the subagent
# backend, which is the right answer for a hook deciding how to spawn -- but
# the wrong one here: being asked to dispatch IS the request for an Orca
# worker. So only a role that was actually bound to a backend in tier.json
# can send this away; anything else takes the orca path and finds out from
# the runtime whether that is possible.
if [ -z "$BACKEND" ] && [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
    BACKEND="$(jq -r --arg r "$ROLE" '.roles[$r].backend // ""' \
        "$STATE_FILE" 2>/dev/null)"
fi
[ -n "$AGENT" ] || AGENT="$(tier_role_field "$STATE_FILE" "$ROLE" agent)"
[ -n "$MODEL" ] || MODEL="$(tier_role_field "$STATE_FILE" "$ROLE" model)"
[ "$MODEL" = "inherit" ] && MODEL=""
[ -n "$BACKEND" ] || BACKEND="orca"
[ -n "$AGENT" ]   || AGENT="claude"
[ -n "$WORKTREE" ] || WORKTREE="path:$ROOT"

# An openrouter/… model is opencode's business whatever the binding says.
case "$MODEL" in
    openrouter/*) AGENT="opencode" ;;
esac
case "$AGENT" in
    openrouter) AGENT="opencode" ;;
esac

# --- no Orca to dispatch into: hand back the Agent-tool spec -------------

if [ "$BACKEND" = "subagent" ]; then
    note "backend=subagent for role $ROLE: not dispatching into Orca."
    orch_fallback "$SPEC" "$MODEL"
    exit 3
fi
if ! orca_reachable; then
    note "no Orca runtime is reachable (ORCA_USER_DATA_PATH=${ORCA_USER_DATA_PATH:-unset}); falling back."
    orch_fallback "$SPEC" "$MODEL"
    exit 3
fi

# Inside a live Orca terminal the CLI resolves its own identity, so --from
# is passed only when we actually know a handle (bash 3.2: the [@]+ guard
# is what keeps an empty array legal under set -u).
HANDLE="$(orch_handle "$FROM")"
FROM_ARGS=()
[ -n "$HANDLE" ] && FROM_ARGS=(--from "$HANDLE")

# --- one Run per coordinator ---------------------------------------------

RUN_ID="$(orch_ensure_run "$ROOT" "$HANDLE")" ||
    die "could not bind a Run for this coordinator" 4

# --- the Task ------------------------------------------------------------
#
# --task adopts a Task somebody else created (orca-run pre-creates the
# whole epic DAG so `task-list --ready` can answer "what may run now");
# without it we create one here, with --task-deps mirrored onto it.

if [ -n "$TASK_ID" ]; then
    note "using existing Task $TASK_ID"
else
    DEPS_ARGS=()
    [ -n "$TASK_DEPS" ] && DEPS_ARGS=(--deps "$TASK_DEPS")
    out="$(orca_call orchestration task-create --spec "$SPEC" \
        --task-title "$BEAD: $TITLE" --display-name "$BEAD" --run "$RUN_ID" \
        ${DEPS_ARGS[@]+"${DEPS_ARGS[@]}"} \
        ${FROM_ARGS[@]+"${FROM_ARGS[@]}"} --json)" ||
        die "task-create failed: $(orca_error "$out")" 4
    TASK_ID="$(orca_field "$out" '.result.task.id')"
    [ -n "$TASK_ID" ] || die "task-create returned no task id" 4
fi

# --- the worker ----------------------------------------------------------

TERMINAL=""; DISPATCH_ID=""; STATE=""; COMMAND=""
REQUESTED_AGENT="$AGENT"
MODEL_ARGS=()
[ -n "$MODEL" ] && MODEL_ARGS=(--model "$MODEL")

new_terminal() {
    local cmd="$1" title="$2" r
    r="$(orca_call terminal create --worktree "$WORKTREE" --title "$title" \
        --command "$cmd" --json)" || {
        die "terminal create failed: $(orca_error "$r")" 4
    }
    TERMINAL="$(orca_field "$r" '.result.terminal.handle')"
    [ -n "$TERMINAL" ] || die "terminal create returned no handle" 4
}

case "$AGENT" in
    bash|shell)
        # A bare shell has no agent CLI to inject into, so this is a
        # context-only Dispatch: the pane's occupant reports for itself.
        COMMAND="bash"
        new_terminal "bash" "$BEAD worker"
        out="$(orca_call orchestration dispatch --task "$TASK_ID" \
            --to "$TERMINAL" --run "$RUN_ID" \
            ${FROM_ARGS[@]+"${FROM_ARGS[@]}"} --json)" ||
            die "dispatch failed: $(orca_error "$out")" 4
        DISPATCH_ID="$(orca_field "$out" '.result.dispatch.id')"
        STATE="$(orca_field "$out" '.result.dispatch.status')"
        ;;
    opencode)
        [ -n "$MODEL" ] || die "--agent opencode needs --model <provider/model>"
        COMMAND="opencode --model $MODEL"
        new_terminal "$COMMAND" "$BEAD $MODEL"
        orca_call terminal wait --terminal "$TERMINAL" --for tui-idle \
            --timeout-ms 30000 --json >/dev/null 2>&1 ||
            note "opencode did not report tui-idle; adopting the terminal anyway"
        out="$(orca_call orchestration worker-start --task "$TASK_ID" \
            --terminal "$TERMINAL" --worktree "$WORKTREE" --run "$RUN_ID" \
            --timeout-ms "$TIMEOUT_MS" ${FROM_ARGS[@]+"${FROM_ARGS[@]}"} --json)" || true
        DISPATCH_ID="$(orca_field "$out" '.result.dispatchId')"
        STATE="$(orca_field "$out" '.result.state')"
        ;;
    claude|codex|gemini|cursor)
        out="$(orca_call orchestration worker-start --task "$TASK_ID" \
            --worktree "$WORKTREE" --agent "$AGENT" \
            ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} --run "$RUN_ID" \
            --timeout-ms "$TIMEOUT_MS" ${FROM_ARGS[@]+"${FROM_ARGS[@]}"} --json)" || true
        DISPATCH_ID="$(orca_field "$out" '.result.dispatchId')"
        STATE="$(orca_field "$out" '.result.state')"
        TERMINAL="$(orca_field "$out" \
            '[.result.effects[]? | select(.kind == "terminal")][0].id')"
        AGENT="$(orca_field "$out" '.result.launch.effective.agent // .result.launch.requested.agent')"
        [ -n "$AGENT" ] || AGENT="$REQUESTED_AGENT"
        m="$(orca_field "$out" '.result.launch.effective.model // .result.launch.requested.model')"
        [ -n "$m" ] && MODEL="$m"
        ;;
    *)
        die "unknown agent: $AGENT (claude|opencode|codex|gemini|bash)"
        ;;
esac

# worker-start exits non-zero and reports state "failed" when the agent
# never took the injected prompt (no login, a TUI that needs a keypress).
# The terminal and the Dispatch are real either way, and releasing them is
# orca-wait's job -- so a Dispatch with a terminal counts as launched, and
# the receipt carries the state for the orchestrator to judge.
if [ -z "$DISPATCH_ID" ] || [ -z "$TERMINAL" ]; then
    note "$(orca_error "$out")"
    die "the runtime did not start a worker for $TASK_ID" 4
fi
[ -n "$STATE" ] || STATE="dispatched"

RECEIPT="$(jq -n -c --arg bead "$BEAD" --arg run "$RUN_ID" --arg task "$TASK_ID" \
    --arg disp "$DISPATCH_ID" --arg backend "$BACKEND" --arg agent "$AGENT" \
    --arg model "$MODEL" --arg term "$TERMINAL" --arg wt "$WORKTREE" \
    --arg state "$STATE" --arg cmd "$COMMAND" \
    '{bead: $bead, run_id: $run, task_id: $task, dispatch_id: $disp,
      backend: $backend, agent: $agent, model: $model, terminal: $term,
      worktree: $wt, state: $state, command: $cmd}')"

printf '%s' "$RECEIPT" >"$(orch_disp_file "$ROOT" "$DISPATCH_ID")"
orch_note_bead "$ROOT" "$BEAD" \
    "ORCA DISPATCH run=$RUN_ID task=$TASK_ID dispatch=$DISPATCH_ID agent=$AGENT model=${MODEL:-none} state=$STATE"

note "dispatched $BEAD -> $AGENT${MODEL:+ ($MODEL)} in $TERMINAL [$STATE]"
printf '%s\n' "$RECEIPT"
