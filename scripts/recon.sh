#!/usr/bin/env bash
#
# recon -- a bead-less, synchronous, READ-ONLY headless opencode run on the
# recon role bound in tier.json (claude-orca-424.1). A recon question has no
# bead, so nothing could send it to the tier's recon backend: every scout of
# the week before this ran on an in-process model while tier.json said
# orca:opencode:<model>[@<variant>]. This command takes the question on the
# command line (or --prompt-file), runs `opencode run` headless on the bound
# model with edit/write and git push denied, prints the answer's text parts
# on stdout, one summary line on stderr, and hands a delegate-shaped receipt
# to cost-mirror's ledger (fail-open, like delegate.sh). It runs in the
# project's working tree as it stands -- uncommitted changes included, no
# worktree -- and NEVER writes <run>/openrouter-guard.env: dispatched
# workers source that file when their terminal starts, and rewriting it
# would hand them this read-only config.
#
# The run follows the provider in the recon role's model: an openrouter/
# model rides the local OpenRouter guard the workers do, an openai/ model
# runs on the user's ChatGPT subscription through opencode's own login, no
# guard involved (claude-orca-c3p.2).
#
# Exit codes:
#   0 / opencode's own exit code -- the run happened (124 when timed out)
#   3 -- the recon backend is not orca:opencode, the guard token is
#        missing, or OpenAI is not signed in for an openai/ model:
#        spawn a scout (Agent tool, subagent_type "scout") instead; the
#        same knowing fallback orca-dispatch uses
#   64 -- usage
#   124 -- the run was killed after the timeout
#
# Env:
#   RECON_STATE_FILE               tier.json to read (tests; else
#                                  tier_state_file() from lib/paths.sh)
#   RECON_RUN_DIR                  run dir for the launch config, logs and
#                                  receipts (tests; else run_dir())
#   CLAUDE_ORCA_RECON_TIMEOUT_S    default timeout in seconds (else 600)
#   CLAUDE_ORCA_GUARD_PORT         the guard's loopback port (else 4141)
#
# Usage:
#   recon [--timeout <s>] [--dir <path>] <question ...>
#   recon [--timeout <s>] [--dir <path>] --prompt-file <file>

set -u

# Resolve through a symlink chain (e.g. bin/recon -> ../scripts/recon.sh)
# to this script's real directory, so lib/paths.sh resolves whether this is
# invoked via the repo copy or the .claude-dev/template/bin/ symlink.
_resolve_script_path() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        local link dir
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(case "$src" in (*/*) cd "${src%/*}/" ;; esac && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}
SCRIPT_DIR="$(_s="$(_resolve_script_path)"; case "$_s" in (*/*) cd "${_s%/*}/" ;; esac && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/tier-roles.sh
. "$SCRIPT_DIR/lib/tier-roles.sh"
# shellcheck source=lib/opencode-launch.sh
. "$SCRIPT_DIR/lib/opencode-launch.sh"

usage() {
    cat <<'USAGE'
usage: recon [--timeout <s>] [--dir <path>] <question ...>
       recon [--timeout <s>] [--dir <path>] --prompt-file <file>
USAGE
}

usage_err() {
    [ -n "${1:-}" ] && printf '%s\n' "$1" >&2
    usage >&2
    exit 64
}

OPT_TIMEOUT="" OPT_DIR="" OPT_PROMPT_FILE="" QUESTION=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0 ;;
        --timeout)
            [ $# -ge 2 ] || usage_err "recon: --timeout needs a value"
            case "$2" in
                ''|*[!0-9]*) usage_err "recon: --timeout needs a whole number of seconds" ;;
            esac
            OPT_TIMEOUT="$2"; shift 2 ;;
        --dir)
            [ $# -ge 2 ] || usage_err "recon: --dir needs a value"
            OPT_DIR="$2"; shift 2 ;;
        --prompt-file)
            [ $# -ge 2 ] || usage_err "recon: --prompt-file needs a value"
            OPT_PROMPT_FILE="$2"; shift 2 ;;
        --)
            shift
            while [ $# -gt 0 ]; do
                QUESTION="${QUESTION:+$QUESTION }$1"
                shift
            done ;;
        -*)
            usage_err "recon: unknown option: $1" ;;
        *)
            QUESTION="${QUESTION:+$QUESTION }$1"
            shift ;;
    esac
done

if [ -n "$OPT_PROMPT_FILE" ]; then
    [ -f "$OPT_PROMPT_FILE" ] || usage_err "recon: --prompt-file '$OPT_PROMPT_FILE' not found"
    QUESTION="$(cat "$OPT_PROMPT_FILE")"
fi
[ -n "$QUESTION" ] || usage_err "recon: no question given"

# 1. The recon role bound in tier.json. Anything that is not
#    orca:opencode -- a missing file, the subagent backend, a non-opencode
#    agent -- is the exit-3 knowing fallback: a scout spawn via the Agent
#    tool is the way this question gets answered on those bindings.
STATE_FILE="${RECON_STATE_FILE:-$(tier_state_file 2>/dev/null || true)}"
BACKEND="" AGENT="" MODEL="" VARIANT=""
if [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
    BACKEND="$(tier_role_field "$STATE_FILE" recon backend)"
    AGENT="$(tier_role_field "$STATE_FILE" recon agent)"
    MODEL="$(tier_role_field "$STATE_FILE" recon model)"
    VARIANT="$(tier_role_field "$STATE_FILE" recon variant)"
fi
if [ -z "$BACKEND" ] || [ "$BACKEND" != "orca" ] || [ "$AGENT" != "opencode" ]; then
    shown="${BACKEND:-unbound}"
    label="$AGENT"
    [ -n "$MODEL" ] && label="$label $MODEL"
    [ -n "$VARIANT" ] && label="$label@$VARIANT"
    printf 'recon: recon backend is %s (%s) -- spawn a scout (Agent tool, subagent_type "scout") for this question\n' \
        "$shown" "$label" >&2
    exit 3
fi

# 2. The credential. RD is computed either way -- the launch config and
#    logs live there. An openai/ model needs no guard: opencode's own
#    ChatGPT login serves it, so readiness is the auth store, and an
#    unsigned-in folder is the same exit-3 knowing fallback as a down
#    guard. An openrouter/ model (and anything else) rides the same local
#    guard the workers do; a missing or empty token means the guard is
#    down and the run would fail anyway -- say so and fall back.
RD="${RECON_RUN_DIR:-$(run_dir 2>/dev/null || true)}"
TOKEN=""
case "$MODEL" in
    openai/*)
        if ! tier_openai_ready; then
            printf 'recon: OpenAI is not signed in in this folder (/tier auth openai) -- spawn a scout\n' >&2
            exit 3
        fi
        if [ -z "$RD" ]; then
            printf 'recon: no run dir for the launch config -- spawn a scout\n' >&2
            exit 3
        fi
        resolved="$(tier_openai_resolve "$MODEL" 2>&1)" || {
            printf 'recon: %s -- spawn a scout\n' "$resolved" >&2
            exit 3
        }
        MODEL="$resolved"
        ;;
    *)
        TOKEN_FILE="$RD/openrouter-guard.token"
        [ -n "$RD" ] && [ -f "$TOKEN_FILE" ] && TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
        if [ -z "$TOKEN" ]; then
            printf 'recon: no OpenRouter guard token at %s -- the guard is down; spawn a scout\n' \
                "$TOKEN_FILE" >&2
            exit 3
        fi
        ;;
esac

# 3. The launch config: the ONE writer orca_opencode_command
#    (scripts/lib/opencode-launch.sh) uses, pinned read-only -- edit/write
#    denied, git push denied -- with the reasoning-effort variant carried
#    when the role has one. The guard base URL rides in only for an
#    openrouter/ model; openrouter-guard.env is deliberately NOT written
#    here (see the header).
SLUG="$(printf '%s' "$MODEL" | tr '/:' '-')"
[ -n "$VARIANT" ] && SLUG="${SLUG}-${VARIANT}"
CFG_DIR="$RD/opencode-launch"
mkdir -p "$CFG_DIR"
CFG="$CFG_DIR/recon-$SLUG.json"
PORT="${CLAUDE_ORCA_GUARD_PORT:-4141}"
case "$MODEL" in
    openrouter/*) opencode_launch_config "$MODEL" "$VARIANT" readonly "$CFG" \
                      "http://127.0.0.1:$PORT/api/v1" ;;
    *)            opencode_launch_config "$MODEL" "$VARIANT" readonly "$CFG" ;;
esac
chmod 600 "$CFG" 2>/dev/null || true

# 4. The prompt: the read-only recon preamble, a blank line, then the
#    question verbatim.
PREAMBLE='You are doing read-only recon for an orchestrator that will act on your findings without re-reading the files itself. Answer with concrete file:line references for every claim; state negative results explicitly ("X appears nowhere under src/"); compact bullets, verbatim snippets only when the exact text is load-bearing; answer the question asked, at the size asked, then stop. Your permissions deny edits. You are a recon worker, not the orchestrator: the CLAUDE.md rules about lanes, beads, delegation and message shape do not apply to you -- declare no lane, file nothing, and print only the answer.'
PROMPT="$PREAMBLE

$QUESTION"

# The working tree as it stands: --dir wins, else the project dir.
if [ -n "$OPT_DIR" ]; then
    DIR="$OPT_DIR"
else
    DIR="$(claude_orca_root 2>/dev/null || true)"
    [ -n "$DIR" ] || DIR="$(project_dir 2>/dev/null || true)"
fi
[ -n "$DIR" ] || usage_err "recon: no project directory to run in -- pass --dir"

# 5. The run, in the foreground, with the timeout as a background watchdog
#    (orca-worker-run.sh's pattern; coreutils `timeout` is absent on macOS).
#    opencode's stdout+stderr go to the log; the credential and the config
#    ride in this one process's environment -- the token never touches a
#    command line, a log or a receipt. An openai/ run carries no
#    OPENROUTER_API_KEY at all (the ChatGPT login lives in opencode's own
#    auth store), so any ambient one is stripped from the environment.
LOG_DIR="$RD/recon"
mkdir -p "$LOG_DIR"
STEM="$(date -u +%Y%m%dT%H%M%SZ)-$$-$SLUG"
LOG="$LOG_DIR/$STEM.log"
RECEIPT="$LOG_DIR/$STEM.receipt.json"

TIMEOUT_S="${CLAUDE_ORCA_RECON_TIMEOUT_S:-600}"
[ -n "$OPT_TIMEOUT" ] && TIMEOUT_S="$OPT_TIMEOUT"

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_EPOCH="$(date +%s)"
FLAG="$LOG_DIR/.timedout.$$"
rm -f "$FLAG"
: >"$LOG"
case "$MODEL" in
    openai/*)
        env -u OPENROUTER_API_KEY OPENCODE_CONFIG="$CFG" \
            opencode run -m "$MODEL" --dir "$DIR" --auto --format json "$PROMPT" >"$LOG" 2>&1 &
        ;;
    *)
        OPENROUTER_API_KEY="$TOKEN" OPENCODE_CONFIG="$CFG" \
            opencode run -m "$MODEL" --dir "$DIR" --auto --format json "$PROMPT" >"$LOG" 2>&1 &
        ;;
esac
OC_PID=$!
(
    elapsed=0
    while [ "$elapsed" -lt "$TIMEOUT_S" ]; do
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done
    if kill -0 "$OC_PID" 2>/dev/null; then
        printf '1' >"$FLAG"
        kill "$OC_PID" 2>/dev/null
    fi
) &
WD_PID=$!
EXIT_CODE=0
wait "$OC_PID" || EXIT_CODE=$?
kill "$WD_PID" 2>/dev/null
wait "$WD_PID" 2>/dev/null
TIMED_OUT=0
[ -f "$FLAG" ] && TIMED_OUT=1
rm -f "$FLAG"
chmod 600 "$LOG" 2>/dev/null || true

# 6. Output: stdout is the joined .part.text of every text event; stderr
#    gets one summary line. Both parsed off the log -- opencode's own
#    stderr is interleaved into it, so every line is parsed with a
#    fromjson try/catch, the way delegate.sh reads its logs.
jq -R -r -s '
    split("\n")
    | map(select(length > 0))
    | map(try fromjson catch empty)
    | map(select(. != null))
    | map(select(.type == "text") | .part.text)
    | join("\n")' "$LOG" 2>/dev/null

TI=0 TO=0 TR=0 USD=0
IFS="$(printf '\t')" read -r TI TO TR USD <<SUMS_EOF
$(jq -R -r -s '
    split("\n")
    | map(select(length > 0))
    | map(try fromjson catch empty)
    | map(select(. != null))
    | [ ([.[] | select(.type == "step_finish") | (.part.tokens.input // 0)] | add // 0),
        ([.[] | select(.type == "step_finish") | (.part.tokens.output // 0)] | add // 0),
        ([.[] | select(.type == "step_finish") | (.part.tokens.reasoning // 0)] | add // 0),
        ([.[] | select(.type == "step_finish") | (.part.cost // empty)] | add // 0
          | (. * 1000000 | round) / 1000000) ]
    | @tsv' "$LOG" 2>/dev/null || printf '0\t0\t0\t0')
SUMS_EOF
TI="${TI:-0}" TO="${TO:-0}" TR="${TR:-0}" USD="${USD:-0}"

# 7. The receipt, in delegate.sh's shape, then the same fail-open hand-off
#    to cost-mirror's delegate ledger delegate.sh does.
FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
WALL=$(( $(date +%s) - START_EPOCH ))
JOB_ID="recon-$(date +%s)-$(printf '%03x%03x' $((RANDOM % 4096)) $((RANDOM % 4096)))"
( umask 077 && jq -n \
    --arg job "$JOB_ID" \
    --arg model "$MODEL" \
    --argjson tokens_in "$TI" \
    --argjson tokens_out "$TO" \
    --argjson wall_seconds "$WALL" \
    --argjson usd "$USD" \
    --argjson exit_code "$EXIT_CODE" \
    --arg started_at "$STARTED_AT" \
    --arg finished_at "$FINISHED_AT" \
    --arg variant "$VARIANT" \
    '{
        job: $job, route: "recon", model: $model,
        bead: null, branch: null,
        tokens_in: $tokens_in, tokens_out: $tokens_out,
        wall_seconds: $wall_seconds, usd: $usd,
        exit_code: $exit_code,
        started_at: $started_at, finished_at: $finished_at,
        variant: (if $variant == "" then null else $variant end)
    }' >"$RECEIPT" )
chmod 600 "$RECEIPT" 2>/dev/null || true

COST_MIRROR="$SCRIPT_DIR/../python/cost-mirror.py"
COST_IMPL="$SCRIPT_DIR/../python/cost_mirror.py"
if [ -f "$COST_MIRROR" ] && [ -f "$COST_IMPL" ] \
    && grep -q -- "ingest-delegate-receipt" "$COST_IMPL" 2>/dev/null; then
    python3 "$COST_MIRROR" --ingest-delegate-receipt "$RECEIPT" >/dev/null 2>&1 || true
fi

# 6b. The summary (stderr) and the exit code.
if [ "$TIMED_OUT" -eq 1 ]; then
    printf 'recon: timed out after %ss (log %s)\n' "$TIMEOUT_S" "$LOG" >&2
    exit 124
fi
MODEL_LABEL="$MODEL"
[ -n "$VARIANT" ] && MODEL_LABEL="${MODEL_LABEL}@${VARIANT}"
printf 'recon: %s · %ss · in %s out %s reasoning %s · $%s · log %s\n' \
    "$MODEL_LABEL" "$WALL" "$TI" "$TO" "$TR" "$USD" "$LOG" >&2
exit "$EXIT_CODE"