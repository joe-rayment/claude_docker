#!/usr/bin/env bash
#
# orca-worker-run.sh -- headless opencode worker for one dispatched slice
# (claude-orca-kbu). A dispatched worker must be a run that exits, never a
# resident TUI: this runs the spec with `opencode run --format json`,
# heartbeats while it runs, writes a receipt, sends worker_done and exits
# with opencode's own exit code.
#
#   orca-worker-run --task <task_id> --spec <file> --model <openrouter/...>
#                   --dir <worktree> [--run-dir <dir>] [--heartbeat-s <n>]
#                   [--bead <id>] [--env <guard-env-file>]
#
# Exit codes: opencode's exit code, or 2 for usage/environment errors.
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
# shellcheck source=lib/orca-orch.sh
. "$SCRIPT_DIR/lib/orca-orch.sh"

die() { printf 'orca-worker-run: %s\n' "$*" >&2; exit "${2:-2}"; }

TASK_ID=""; SPEC=""; MODEL=""; DIR=""; RUN_DIR=""; BEAD=""; ENV_OVERRIDE=""
HEARTBEAT_S="${CLAUDE_ORCA_WORKER_HEARTBEAT_S:-240}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --task)        TASK_ID="${2:-}"; shift ;;
        --spec)        SPEC="${2:-}"; shift ;;
        --model)       MODEL="${2:-}"; shift ;;
        --dir)         DIR="${2:-}"; shift ;;
        --run-dir)     RUN_DIR="${2:-}"; shift ;;
        --heartbeat-s) HEARTBEAT_S="${2:-}"; shift ;;
        --bead)        BEAD="${2:-}"; shift ;;
        --env)         ENV_OVERRIDE="${2:-}"; shift ;;
        -h|--help)     sed -n '3,11p' "$(_resolve_script_path)"; exit 0 ;;
        *)             die "unknown flag: $1" ;;
    esac
    shift
done

[ -n "$TASK_ID" ] || die "--task is required"
[ -n "$SPEC" ] || die "--spec is required"
[ -n "$MODEL" ] || die "--model is required"
[ -n "$DIR" ] || die "--dir is required"
[ -f "$SPEC" ] || die "spec file not found: $SPEC"
[ -d "$DIR" ] || die "worktree dir not found: $DIR"

case "$HEARTBEAT_S" in ''|*[!0-9]*) HEARTBEAT_S=240 ;; esac
[ "$HEARTBEAT_S" -ge 1 ] || HEARTBEAT_S=240

if [ -z "$RUN_DIR" ]; then
    RUN_DIR="$(run_dir 2>/dev/null)" ||
        die "no run dir resolved: pass --run-dir or run inside a bootstrapped project"
fi

# 1. Guard env: exactly what orca_opencode_command's terminal command does
#    (scripts/lib/orca-orch.sh) -- the token reaches opencode's environment
#    without ever riding the command line. --env names it explicitly (the
#    headless dispatch's composed command does, so the terminal command
#    shows what it sources); the default is the same file under --run-dir.
ENV_FILE="$RUN_DIR/openrouter-guard.env"
[ -n "$ENV_OVERRIDE" ] && ENV_FILE="$ENV_OVERRIDE"
[ -f "$ENV_FILE" ] || die "guard env file missing: $ENV_FILE"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
GUARD_TOKEN="${OPENROUTER_API_KEY:-}"

# 2. Dispatch id: orca-dispatch writes
#    <run-dir>/orchestration/dispatch/<dispatch_id>.json right after
#    `orchestration dispatch`; poll briefly for the record naming our task.
#    None appearing is not an error: worker_done still carries --task-id.
DISPATCH_ID=""
DISPATCH_WAIT="${CLAUDE_ORCA_WORKER_DISPATCH_WAIT_S:-30}"
DISPATCH_DIR="$RUN_DIR/orchestration/dispatch"
i=0
while [ "$i" -lt $(( DISPATCH_WAIT * 2 )) ]; do
    if [ -d "$DISPATCH_DIR" ]; then
        for f in "$DISPATCH_DIR"/*.json; do
            [ -f "$f" ] || continue
            if [ "$(jq -r '.task_id // ""' "$f" 2>/dev/null)" = "$TASK_ID" ]; then
                DISPATCH_ID="$(jq -r '.dispatch_id // ""' "$f" 2>/dev/null)"
                break 2
            fi
        done
    fi
    sleep 0.5
    i=$(( i + 1 ))
done

# 3. The base commit, for the changed-files report.
base="$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" || base=""

# 4. Headless run, with a heartbeat watchdog beside it.
WORKERS_DIR="$RUN_DIR/orchestration/workers"
mkdir -p "$WORKERS_DIR"
LOG="$WORKERS_DIR/$TASK_ID.log"
PROMPT="$(cat "$SPEC")"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_EPOCH="$(date +%s)"
: > "$LOG"

opencode run -m "$MODEL" --dir "$DIR" --auto --format json "$PROMPT" \
    >"$LOG" 2>&1 &
OC_PID=$!

# The watchdog sends one heartbeat every HEARTBEAT_S seconds so orca-wait's
# stall watch stays quiet while opencode runs. It stops on a flag file --
# never by polling the pid, which a zombie child would keep alive -- and it
# sleeps one second at a time so the main flow waits at most 1 s for it.
HB_FLAG="$WORKERS_DIR/$TASK_ID.heartbeat.stop"
rm -f "$HB_FLAG"
HB_PID=""
if [ -n "$DISPATCH_ID" ]; then
    (
        ticks=0
        while [ ! -f "$HB_FLAG" ]; do
            sleep 1
            [ -f "$HB_FLAG" ] && break
            ticks=$(( ticks + 1 ))
            if [ "$ticks" -ge "$HEARTBEAT_S" ]; then
                ticks=0
                orca_call orchestration send --type heartbeat --subject alive \
                    --dispatch-id "$DISPATCH_ID" --json >/dev/null 2>&1 || true
            fi
        done
    ) &
    HB_PID=$!
fi

EXIT_CODE=0
wait "$OC_PID" || EXIT_CODE=$?
: > "$HB_FLAG"
[ -n "$HB_PID" ] && wait "$HB_PID" 2>/dev/null
rm -f "$HB_FLAG"

FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
WALL_SECONDS=$(( $(date +%s) - START_EPOCH ))

# Redact the guard token before anything else reads the log (same
# literal-replace as delegate.sh's redact_secret: sed would need the secret
# escaped as both a BRE and a replacement).
redact_secret() {
    local file="$1" secret="$2"
    if [ -z "$secret" ] || [ ! -f "$file" ]; then
        return 0
    fi
    python3 - "$file" "$secret" <<'PYEOF'
import sys
path, secret = sys.argv[1], sys.argv[2]
with open(path, "r", errors="replace") as f:
    data = f.read()
if secret and secret in data:
    data = data.replace(secret, "***REDACTED***")
    with open(path, "w") as f:
        f.write(data)
PYEOF
}
redact_secret "$LOG" "$GUARD_TOKEN"

# 5. Receipt: two stream shapes (claude-orca-pld). The real opencode
#    --format json stream is {"type":"step_start"|"tool_use"|"step_finish"|
#    "text",...,"part":{...}} with tokens and cost in every step_finish
#    part -- summed over all of them. The legacy shape (and the frozen
#    test's stub) is one usage/cost event -- the last one wins. When
#    neither parses, the receipt is still written with zeros and one
#    stderr line: cost-mirror must never miss a run for a parse failure.
usage_obj="$(jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(try fromjson catch empty)
    | map(select(. != null))
    | {
        real: [.[] | select(.type == "step_finish"
                  and (((.part // {}) | has("tokens"))
                       or ((.part // {}) | has("cost"))))],
        legacy: [.[] | select((has("usage") or has("cost"))
                  and (.type != "step_finish"))]
      }
' "$LOG" 2>/dev/null)" || usage_obj='{}'
[ -n "$usage_obj" ] || usage_obj='{}'
if [ "$(jq -r '(.real | length) > 0' <<<"$usage_obj" 2>/dev/null)" = "true" ]; then
    tokens_in="$(jq -r '[.real[] | (.part.tokens.input // 0)] | add // 0' <<<"$usage_obj")"
    tokens_out="$(jq -r '[.real[] | (.part.tokens.output // 0)] | add // 0' <<<"$usage_obj")"
    usd="$(jq -r '[.real[] | (.part.cost // 0)] | add // 0' <<<"$usage_obj")"
else
    tokens_in="$(jq -r '(.legacy | last | (.usage.inputTokens // .usage.input_tokens // .usage.promptTokens // .tokens.input // .part.tokens.input)) // "null"' <<<"$usage_obj")"
    tokens_out="$(jq -r '(.legacy | last | (.usage.outputTokens // .usage.output_tokens // .usage.completionTokens // .tokens.output // .part.tokens.output)) // "null"' <<<"$usage_obj")"
    usd="$(jq -r '(.legacy | last | (.usage.cost // .cost // .part.cost)) // "null"' <<<"$usage_obj")"
    if [ "$tokens_in" = "null" ] && [ "$tokens_out" = "null" ] && [ "$usd" = "null" ]; then
        printf 'worker-run: could not parse token usage from %s\n' "$LOG" >&2
        tokens_in=0; tokens_out=0; usd=0
    fi
fi

RECEIPT="$WORKERS_DIR/$TASK_ID.receipt.json"
jq -n \
    --arg task "$TASK_ID" --arg disp "$DISPATCH_ID" --arg bead "$BEAD" \
    --arg model "$MODEL" --arg dir "$DIR" --argjson exit_code "$EXIT_CODE" \
    --argjson tokens_in "$tokens_in" --argjson tokens_out "$tokens_out" \
    --argjson usd "$usd" --argjson wall "$WALL_SECONDS" \
    --arg started "$STARTED_AT" --arg finished "$FINISHED_AT" \
    '{task_id: $task, dispatch_id: $disp,
      bead: (if $bead == "" then null else $bead end),
      model: $model, dir: $dir, exit_code: $exit_code,
      tokens_in: $tokens_in, tokens_out: $tokens_out,
      usd: $usd, wall_seconds: $wall,
      started_at: $started, finished_at: $finished}' > "$RECEIPT"
redact_secret "$RECEIPT" "$GUARD_TOKEN"

if command -v cost-mirror >/dev/null 2>&1; then
    cost-mirror --ingest-delegate-receipt "$RECEIPT" >/dev/null 2>&1 || true
fi

# 6. Report: changed files (committed diff plus status paths, deduped),
#    the last assistant text in the log, and worker_done -- sent ALWAYS:
#    a failed run reports failed, so the orchestrator is never left waiting.
files="$({ [ -n "$base" ] && git -C "$DIR" diff --name-only "$base..HEAD" 2>/dev/null
            git -C "$DIR" status --porcelain 2>/dev/null |
                awk '{ line = $0; sub(/^.../, "", line);
                       if (line ~ / -> /) sub(/.* -> /, "", line);
                       print line }'; } | sort -u | paste -sd, -)"
# -r on this one: the last value is the text itself, and Orca must
# receive it raw -- JSON-encoded it arrives wrapped in literal double
# quotes (claude-orca-ltd). The last text event's part.text is the
# worker's own summary (claude-orca-pld); the deep scan stays as the
# fallback for streams that carry text some other way.
body="$(jq -r -R -s '
    split("\n")
    | map(select(length > 0))
    | map(try fromjson catch empty)
    | map(select(. != null))
    | [([.[] | select(.type == "text") | (.part.text // empty)
         | select(length > 0)] | last // empty),
        ([.[] | [.. | objects | select(has("text")) | .text]
          | last // empty]
         | map(select(length > 0)) | last // empty)]
    | map(select(. != null and . != "" and length > 0))
    | first // empty
' "$LOG" 2>/dev/null)"
[ -n "$body" ] || body="$(grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -20)"
body="${body:0:1500}"

OUTCOME="succeeded"
[ "$EXIT_CODE" -ne 0 ] && OUTCOME="failed"
last_event="$(jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(try fromjson catch empty)
    | map(select(. != null))
    | last // {}
' "$LOG" 2>/dev/null)"
[ -n "$last_event" ] || last_event='{}'
if [ "$(jq -r 'if (.type == "error") or has("error") then "failed" else "ok" end' \
        <<<"$last_event" 2>/dev/null)" = "failed" ]; then
    OUTCOME="failed"
fi

SUBJECT="${BEAD:-$TASK_ID} done"
SEND_ARGS=(orchestration send --type worker_done --subject "$SUBJECT"
    --body "$body" --task-id "$TASK_ID" --outcome "$OUTCOME" --json)
[ -n "$DISPATCH_ID" ] && SEND_ARGS+=(--dispatch-id "$DISPATCH_ID")
[ -n "$files" ] && SEND_ARGS+=(--files-modified "$files")
orca_call "${SEND_ARGS[@]}" >/dev/null 2>&1 || true

exit "$EXIT_CODE"