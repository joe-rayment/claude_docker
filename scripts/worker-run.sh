#!/usr/bin/env bash
#
# worker-run.sh -- run ONE turn of ONE headless worker, with no Orca in the
# loop (claude-orca-9bh.1; plan .claude/plans/ghostty.md "Workers without
# Orca"). dispatch.sh starts it detached on a job directory; `workers reply`
# starts it again with --resume. It is the whole worker lifecycle:
#
#   worker-run.sh <jobdir> [--resume <session-id> --message <text>]
#
#   <jobdir> = <root>/.claude-dev/run/workers/<job>/ with job.json + spec.md
#   (written by dispatch). One turn = wait for a free slot, run the agent in
#   the job's worktree, write the receipt, tell the orchestrator.
#
# In order:
#   1. Slot: at most workers_max (CLAUDE_ORCA_MAX_WORKERS | .maxWorkers |
#      3) turns run at once. A slot is an flock on fd 9 over
#      <workers>/slots/<n>.lock, held for the whole turn and released on
#      exit (the agent gets `9>&-`, so only this process holds it). With no
#      free slot job.json says "queued" and we poll every
#      CLAUDE_ORCA_SLOT_POLL_S (default 1) seconds.
#   2. Run (nice -n 10, in job.json dir): claude -p ... stream-json with the
#      spec on stdin, or opencode run --format json with the spec as the
#      prompt (guard env sourced from orca_opencode_command's env file, so
#      the key is never on argv). stdout appends to log.jsonl, stderr to
#      runner.log. CLAUDE_ORCA_WORKER_CMD replaces the claude/opencode
#      binary (the test seam; the arguments are still the agent's own).
#   3. Receipt: receipt.json (receipt-N.json for turn N >= 2) with session
#      id, tokens, usd, changed files and the final message; job.json gets
#      state done | question (a `QUESTION:` line) | failed (exit != 0).
#   4. Tell: a WORKER_DONE note on the bead (best effort) and ONE line in
#      orchestration/inbox.jsonl (worker_done | question | worker_failed).
#
# TERM/INT: kill the agent, job.json state "stopped", release the slot,
# exit 143 (`workers stop` relies on it).
#
# Exit codes: the agent's own exit code · 2 usage/env error (no job dir or
# job.json, unknown agent, bad flags) · 143 stopped.
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
# shellcheck source=lib/orca-orch.sh
. "$SCRIPT_DIR/lib/orca-orch.sh"
# shellcheck source=lib/frozen-hook.sh
. "$SCRIPT_DIR/lib/frozen-hook.sh"

note() { printf 'worker-run: %s\n' "$*" >&2; }
die()  { printf 'worker-run: %s\n' "$*" >&2; exit "${2:-2}"; }

JOBDIR=""; RESUME_SID=""; MESSAGE=""; HAVE_MSG=0; HAVE_RESUME=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --resume)  [ "$#" -ge 2 ] || die "--resume needs a session id"
                   RESUME_SID="$2"; HAVE_RESUME=1; shift ;;
        --message) [ "$#" -ge 2 ] || die "--message needs a text"
                   MESSAGE="$2"; HAVE_MSG=1; shift ;;
        -h|--help) sed -n '3,40p' "$(_resolve_script_path)"; exit 0 ;;
        -*)        die "unknown flag: $1" ;;
        *)         [ -z "$JOBDIR" ] && JOBDIR="$1" || die "unexpected argument: $1" ;;
    esac
    shift
done

[ -n "$JOBDIR" ] || die "usage: worker-run.sh <jobdir> [--resume <session-id> --message <text>]"
[ -d "$JOBDIR" ] || die "no such job directory: $JOBDIR"
JOBDIR="$(cd "$JOBDIR" && pwd)"
[ -f "$JOBDIR/job.json" ] || die "no job.json in $JOBDIR"
jq -e 'type == "object"' "$JOBDIR/job.json" >/dev/null 2>&1 || die "job.json is not a JSON object: $JOBDIR/job.json"
if [ "$HAVE_RESUME" = 1 ] || [ "$HAVE_MSG" = 1 ]; then
    [ "$HAVE_RESUME" = 1 ] && [ "$HAVE_MSG" = 1 ] || die "--resume and --message go together"
    [ -n "$RESUME_SID" ] || die "--resume needs a non-empty session id"
    [ -n "$MESSAGE" ] || die "--message needs a non-empty text"
else
    [ -f "$JOBDIR/spec.md" ] || die "no spec.md in $JOBDIR"
fi

# jf <key> -- one job.json field as text ("" when absent or null).
jf() { jq -r --arg k "$1" '(.[$k] // "") | tostring' "$JOBDIR/job.json" 2>/dev/null; }

JOB="$(jf job)"; [ -n "$JOB" ] || JOB="${JOBDIR##*/}"
BEAD="$(jf bead)"; AGENT="$(jf agent)"; MODEL="$(jf model)"
VARIANT="$(jf variant)"; EFFORT="$(jf effort)"; DIR="$(jf dir)"; HOOKS="$(jf frozen_hooks)"
case "$AGENT" in
    claude|opencode) ;;
    *) die "unknown agent '$AGENT' in $JOBDIR/job.json (claude or opencode)" ;;
esac
[ -n "$DIR" ] && [ -d "$DIR" ] || die "job dir is not a directory: '$DIR'"

case "$JOBDIR" in
    */.claude-dev/run/workers/*) ROOT="${JOBDIR%/.claude-dev/run/workers/*}" ;;
    *) ROOT="$(orch_root)" || die "cannot resolve the project root for $JOBDIR" ;;
esac
RUN_DIR="$ROOT/.claude-dev/run"

t="$(jf turns)"; case "$t" in ''|*[!0-9]*) t=0 ;; esac
TURN=$(( t + 1 ))
LOG="$JOBDIR/log.jsonl"

# --- stop: TERM/INT kills the agent, marks the job, frees the slot -----------

CHILD=""
slot_release() { exec 9>&-; }
on_term() {
    local i=0
    trap '' TERM INT
    if [ -n "$CHILD" ]; then
        kill -TERM -- "-$CHILD" 2>/dev/null
        kill -TERM "$CHILD" 2>/dev/null
        while kill -0 "$CHILD" 2>/dev/null && [ "$i" -lt 25 ]; do sleep 0.2; i=$(( i + 1 )); done
        kill -KILL -- "-$CHILD" 2>/dev/null
        kill -KILL "$CHILD" 2>/dev/null
        wait "$CHILD" 2>/dev/null
    fi
    workers_job_set "$JOBDIR" state '"stopped"'
    slot_release
    exit 143
}
trap on_term TERM INT

# --- 1. the slot ------------------------------------------------------------

SLOTS="$(workers_dir "$ROOT")/slots"
SLOT=0
slot_acquire() {
    local max i queued=0
    if ! command -v flock >/dev/null 2>&1; then
        note "flock is missing: the slot cap is not enforced"
        return 0
    fi
    max="$(workers_max "$ROOT")"
    mkdir -p "$SLOTS" || die "cannot create $SLOTS" 1
    while :; do
        i=1
        while [ "$i" -le "$max" ]; do
            exec 9>"$SLOTS/$i.lock" || die "cannot open slot lock $SLOTS/$i.lock" 1
            if flock -n 9; then SLOT="$i"; return 0; fi
            exec 9>&-
            i=$(( i + 1 ))
        done
        if [ "$queued" = 0 ]; then
            queued=1
            workers_job_set "$JOBDIR" pid "$$"   # so list/stop can find a queued runner
            workers_job_set "$JOBDIR" state '"queued"'
        fi
        sleep "${CLAUDE_ORCA_SLOT_POLL_S:-1}"
    done
}
slot_acquire

# --- 2. the run --------------------------------------------------------------

STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_EPOCH="$(date +%s)"
BASE="$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" || BASE=""
workers_job_set "$JOBDIR" state '"running"'
workers_job_set "$JOBDIR" pid "$$"
workers_job_set "$JOBDIR" slot "$SLOT"
workers_job_set "$JOBDIR" started "\"$STARTED\""
if [ "$TURN" = 1 ]; then
    workers_job_set "$JOBDIR" base "$(jq -n --arg b "$BASE" '$b')"
fi

# The command line: CMD is the agent (or the CLAUDE_ORCA_WORKER_CMD stub in
# its place -- the arguments stay the agent's own), PREFIX what runs it.
CMD=()
add() { CMD[${#CMD[@]}]="$1"; }
BIN="${CLAUDE_ORCA_WORKER_CMD:-}"
STDIN_FILE=/dev/null
GUARD_TOKEN=""; ENVF=""
case "$AGENT" in
    claude)
        [ -n "$BIN" ] || BIN=claude
        add "$BIN"; add -p
        if [ -n "$MODEL" ]; then add --model; add "$MODEL"; fi
        if [ -n "$EFFORT" ]; then add --effort; add "$EFFORT"; fi
        add --output-format; add stream-json; add --verbose
        add --permission-mode; add bypassPermissions
        if [ "$HAVE_RESUME" = 1 ]; then
            add --resume; add "$RESUME_SID"
            STDIN_FILE="$JOBDIR/message-$TURN.md"
            ( umask 077; printf '%s\n' "$MESSAGE" >"$STDIN_FILE" )
        else
            STDIN_FILE="$JOBDIR/spec.md"
        fi
        ;;
    opencode)
        [ -n "$BIN" ] || BIN=opencode
        # The guard env (OPENROUTER_API_KEY, OPENCODE_CONFIG ...) is written
        # by the shared composer and sourced for the agent only; the key is
        # never on argv. Its stdout (a TUI command string) is not ours.
        mkdir -p "$RUN_DIR"
        if ! orca_opencode_command "$MODEL" "$RUN_DIR" "$VARIANT" >/dev/null; then
            workers_job_set "$JOBDIR" state '"failed"'; slot_release
            die "cannot compose the opencode launch env under $RUN_DIR" 1
        fi
        ENVF="$RUN_DIR/openrouter-guard.env"
        GUARD_TOKEN="$( set -a; . "$ENVF" >/dev/null 2>&1; printf '%s' "${OPENROUTER_API_KEY:-}" )"
        add "$BIN"; add run
        if [ "$HAVE_RESUME" = 1 ]; then add -s; add "$RESUME_SID"; fi
        if [ -n "$MODEL" ]; then add -m; add "$MODEL"; fi
        add --dir; add "$DIR"; add --auto; add --format; add json
        if [ -n "$VARIANT" ]; then add --variant; add "$VARIANT"; fi
        if [ "$HAVE_RESUME" = 1 ]; then add "$MESSAGE"; else add "$(cat "$JOBDIR/spec.md")"; fi
        ;;
esac

PREFIX=(env -u CLAUDE_CODE_CHILD_SESSION)
if command -v nice >/dev/null 2>&1; then PREFIX=(nice -n 10 "${PREFIX[@]}"); fi
if command -v setsid >/dev/null 2>&1; then PREFIX=(setsid "${PREFIX[@]}"); fi

: >>"$LOG"
OFF="$(wc -c <"$LOG" 2>/dev/null | tr -d ' ')"
case "$OFF" in ''|*[!0-9]*) OFF=0 ;; esac

# The agent runs in the background so a TERM reaches the trap at once; its
# own group (setsid) lets the trap take its children down with it, and
# `9>&-` keeps the slot lock held by this process alone.
(
    cd "$DIR" || exit 126
    if [ -n "$HOOKS" ]; then
        while IFS= read -r kv; do
            [ -n "$kv" ] && export "$kv"
        done <<<"$(frozen_hook_env "$HOOKS")"
    fi
    if [ -n "$ENVF" ]; then set -a; . "$ENVF"; set +a; fi
    exec "${PREFIX[@]}" "${CMD[@]}"
) <"$STDIN_FILE" >>"$LOG" 2>>"$JOBDIR/runner.log" 9>&- &
CHILD=$!
wait "$CHILD"
RC=$?
CHILD=""

ENDED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
WALL=$(( $(date +%s) - START_EPOCH ))

# --- 3. receipt --------------------------------------------------------------

# Literal replace of the guard token (python: sed would need the secret
# escaped as both a BRE and a replacement). opencode jobs only.
redact_secret() {
    local file="$1" secret="$2"
    if [ -z "$secret" ] || [ ! -f "$file" ]; then return 0; fi
    python3 - "$file" "$secret" <<'PYEOF'
import sys
path, secret = sys.argv[1], sys.argv[2]
with open(path, "r", errors="replace") as f:
    data = f.read()
if secret and secret in data:
    with open(path, "w") as f:
        f.write(data.replace(secret, "***REDACTED***"))
PYEOF
}
redact_secret "$LOG" "$GUARD_TOKEN"
redact_secret "$JOBDIR/runner.log" "$GUARD_TOKEN"

SEG="$(mktemp "$JOBDIR/.seg.XXXXXX")"
tail -c +"$(( OFF + 1 ))" "$LOG" >"$SEG" 2>/dev/null
PARSED="$(jq -R -s --arg agent "$AGENT" '
    def num: if type == "number" then . else 0 end;
    (split("\n") | map(select(length > 0) | try fromjson catch empty)
        | map(select(type == "object"))) as $ev
    | (if $agent == "claude" then
        ([$ev[] | select(.type == "result")] | last) as $r
        | { session: ([$ev[] | (.session_id // empty)] | first // ""),
            text: (($r.result // null)
                   // ([$ev[] | select(.type == "assistant") | (.message.content // [])[]
                         | select(.type == "text") | .text] | last) // ""),
            tin: (($r.usage.input_tokens // 0) | num),
            tout: (($r.usage.output_tokens // 0) | num),
            usd: (($r.total_cost_usd // 0) | num) }
      else
        [$ev[] | select(.type == "step_finish")] as $sf
        | { session: ([$ev[] | (.sessionID // .part.sessionID // empty)] | first // ""),
            text: ([$ev[] | select(.type == "text") | (.part.text // empty)] | last // ""),
            tin: ([$sf[] | ((.part.tokens.input // 0) | num)] | add // 0),
            tout: ([$sf[] | ((.part.tokens.output // 0) | num)] | add // 0),
            usd: ([$sf[] | ((.part.cost // 0) | num)] | add // 0) }
      end)
    | .text as $s
    | ($s | split("\n") | map(select(startswith("QUESTION:")))) as $q
    | . + { question: (($q | length) > 0),
            summary: (if ($q | length) > 0 and (($s[0:2000] | contains($q[0])) | not)
                      then $s[0:1500] + "\n...\n" + ($q | join("\n"))
                      else $s[0:2000] end) }
' "$SEG" 2>/dev/null)"
rm -f "$SEG"
printf '%s' "$PARSED" | jq -e 'type == "object"' >/dev/null 2>&1 ||
    PARSED='{"session":"","tin":0,"tout":0,"usd":0,"question":false,"summary":""}'
pf() { printf '%s' "$PARSED" | jq -r ".$1"; }

SESSION_ID="$(pf session)"
[ -n "$SESSION_ID" ] || SESSION_ID="${RESUME_SID:-$(jf session_id)}"
if [ -n "$BASE" ]; then
    FILES="$(git -C "$DIR" diff --name-only "$BASE..HEAD" 2>/dev/null |
        jq -R -s -c 'split("\n") | map(select(length > 0))')"
fi
[ -n "${FILES:-}" ] || FILES='[]'

if [ "$RC" -ne 0 ]; then STATE=failed
elif [ "$(pf question)" = true ]; then STATE=question
else STATE=done; fi

if [ "$TURN" = 1 ]; then RECEIPT="$JOBDIR/receipt.json"; else RECEIPT="$JOBDIR/receipt-$TURN.json"; fi
jq -n --argjson p "$PARSED" --argjson files "$FILES" --argjson rc "$RC" --argjson wall "$WALL" \
    --arg job "$JOB" --arg bead "$BEAD" --arg agent "$AGENT" --arg model "$MODEL" \
    --arg started "$STARTED" --arg ended "$ENDED" --arg sid "$SESSION_ID" '
    {job: $job, bead: (if $bead == "" then null else $bead end), agent: $agent,
     model: $model, exit: $rc, started: $started, ended: $ended, wall_s: $wall,
     session_id: $sid, tokens_in: $p.tin, tokens_out: $p.tout, usd: $p.usd,
     files: $files, summary: $p.summary}' >"$RECEIPT"
redact_secret "$RECEIPT" "$GUARD_TOKEN"

if [ -n "$SESSION_ID" ]; then
    workers_job_set "$JOBDIR" session_id "$(jq -n --arg s "$SESSION_ID" '$s')"
fi
workers_job_set "$JOBDIR" turns "$TURN"
workers_job_set "$JOBDIR" last_receipt "$(jq -n --arg r "$RECEIPT" '$r')"
workers_job_set "$JOBDIR" exit "$RC"
workers_job_set "$JOBDIR" state "\"$STATE\""

# --- 4. tell the orchestrator -----------------------------------------------

SUMMARY="$(pf summary)"
if [ -n "$BEAD" ]; then
    orch_note_bead "$ROOT" "$BEAD" "WORKER_DONE job=$JOB outcome=$STATE receipt=$RECEIPT
$(printf '%s' "$SUMMARY" | cut -c1-400)"
fi

TITLE=""
if [ -n "$BEAD" ]; then
    TITLE="$(orch_bead_json "$ROOT" "$BEAD" 2>/dev/null | jq -r '.title // ""' 2>/dev/null)"
fi
[ -n "$TITLE" ] || TITLE="${BEAD:-$JOB}"
BODY="$SUMMARY"
[ -n "$BODY" ] || BODY="worker exited with code $RC and said nothing (see $JOBDIR/runner.log)"
case "$STATE" in
    question) MTYPE=question ;;
    failed)   MTYPE=worker_failed ;;
    *)        MTYPE=worker_done ;;
esac
LINE="$(jq -n -c --arg type "$MTYPE" --arg job "$JOB" --arg subject "$TITLE" --arg body "$BODY" \
    --arg bead "$BEAD" --arg agent "$AGENT" --arg model "$MODEL" --arg outcome "$STATE" \
    --argjson files "$FILES" --arg receipt "$RECEIPT" \
    --arg reply "workers reply $JOB \"<answer>\"" '
    {type: $type, msg_id: $job, from: "worker-run", subject: $subject, body: $body,
     task_id: $job, dispatch_id: $job, bead: $bead, agent: $agent, model: $model,
     outcome: $outcome, files: $files, released: true, terminal_closed: true,
     handoff: null, job: $job, receipt: $receipt}
    + (if $type == "question" then {reply_with: $reply} else {} end)')"
workers_inbox_append "$ROOT" "$LINE" || note "could not append to the inbox under $ROOT"

# --- 5. release the slot and go ----------------------------------------------

slot_release
exit "$RC"
