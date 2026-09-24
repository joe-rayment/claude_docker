#!/usr/bin/env bash
#
# context-meter.sh -- PostToolUse/PreToolUse hook (context-meter --post /
# --pre), claude-orca-7lz.1. Meters a Claude Code SUB-AGENT's own
# transcript after each tool call: answer quality drops past roughly 30%
# of an agent's window, so a soft [context-meter] notice appears from
# CLAUDE_ORCA_CONTEXT_BUDGET on and every tool call is refused from
# CLAUDE_ORCA_CONTEXT_CEILING on. The main loop (no agent_id on its
# payload) is never metered; a fresh agent relays from the HANDOFF block
# a metered agent's final report ends with.
#
# Fails open everywhere: no jq, unparsable stdin, a missing transcript or
# a non-numeric setting all exit 0 with no output.

set -u

MODE="${1:-}"
case "$MODE" in
    --post|--pre) ;;
    *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

IN=$(cat 2>/dev/null) || exit 0
[ -n "$IN" ] || exit 0

# Main loop only. A populated agent_id is the one positive subagent
# signal (see python/delegation_gate.py's is_main_loop() for the
# evidence); absence -- or an empty string -- means the main loop.
AGENT_ID=$(printf '%s' "$IN" | jq -r '.agent_id // empty' 2>/dev/null) || exit 0
[ -n "$AGENT_ID" ] || exit 0

# Settings, read from the environment (claude-orca-7lz's shared contract):
# a value that is not a non-negative integer falls back to its default.
is_nonneg_int() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

BUDGET="${CLAUDE_ORCA_CONTEXT_BUDGET:-30}"
is_nonneg_int "$BUDGET" || BUDGET=30
[ "$BUDGET" -eq 0 ] && exit 0

CEILING="${CLAUDE_ORCA_CONTEXT_CEILING:-40}"
is_nonneg_int "$CEILING" || CEILING=40

TRANSCRIPT_PATH=$(printf '%s' "$IN" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0
[ -n "$TRANSCRIPT_PATH" ] || exit 0

# The sub-agent's own transcript sits beside the main session transcript:
# "${transcript_path%.jsonl}/subagents/agent-${agent_id}.jsonl", with a
# sibling agent-${agent_id}.meta.json.
BASE="${TRANSCRIPT_PATH%.jsonl}"
SUB_T="$BASE/subagents/agent-${AGENT_ID}.jsonl"
[ -f "$SUB_T" ] || exit 0
META="$BASE/subagents/agent-${AGENT_ID}.meta.json"

# The LAST row with .type=="assistant" and a .message.usage object. Only
# the tail is read -- this must stay cheap on a long-running transcript.
ROW=$(tail -n 400 "$SUB_T" 2>/dev/null | jq -c 'select(.type=="assistant" and (.message.usage? != null))' 2>/dev/null | tail -n 1) || exit 0
[ -n "$ROW" ] || exit 0

CONTEXT=$(printf '%s' "$ROW" | jq -r '
    (.message.usage.input_tokens // 0) +
    (.message.usage.cache_read_input_tokens // 0) +
    (.message.usage.cache_creation_input_tokens // 0) +
    (.message.usage.output_tokens // 0)
' 2>/dev/null) || exit 0
is_nonneg_int "$CONTEXT" || exit 0

WINDOW="${CLAUDE_ORCA_CONTEXT_WINDOW:-0}"
is_nonneg_int "$WINDOW" || WINDOW=0

if [ "$WINDOW" -le 0 ]; then
    ROW_MODEL=$(printf '%s' "$ROW" | jq -r '.message.model // empty' 2>/dev/null)
    META_MODEL=""
    [ -f "$META" ] && META_MODEL=$(jq -r '.model // empty' "$META" 2>/dev/null)
    WINDOW=200000
    case "$META_MODEL" in *'[1m]'*) WINDOW=1000000 ;; esac
    if [ "$WINDOW" -eq 200000 ]; then
        case "$ROW_MODEL" in *'[1m]'*) WINDOW=1000000 ;; esac
    fi
fi
[ "$WINDOW" -gt 0 ] || exit 0

PCT=$(( CONTEXT * 100 / WINDOW ))

# The HANDOFF template, shared byte-for-byte by the SOFT NOTICE and the HARD
# REFUSAL (claude-orca-7lz's shared contract, revised by claude-orca-7lz.6).
HANDOFF_BLOCK="HANDOFF
done: <what is finished, with file:line>
left: <what remains, in order>
facts: <file:line facts the next agent must not re-derive>
next:
relay: this agent is finished -- start a fresh one from this block; never message or resume it."

hard_refusal_text() {
    printf '[context-meter] context is at %s%% of this agent'"'"'s window, past the %s%% ceiling: tool calls are refused. Write your final report now and stop. If work remains, end it with this block:\n%s' \
        "$1" "$CEILING" "$HANDOFF_BLOCK"
}

if [ "$MODE" = "--post" ]; then
    if [ "$PCT" -ge "$CEILING" ]; then
        TEXT="$(hard_refusal_text "$PCT")"
        jq -n --arg t "$TEXT" '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$t}}' 2>/dev/null || exit 0
        exit 0
    fi
    [ "$PCT" -ge "$BUDGET" ] || exit 0
    TEXT="[context-meter] context is at ${PCT}% of this agent's window (budget ${BUDGET}%); past this point answer quality drops. Stop exploring: finish the step in hand and stop. If work remains, end your final report with this block; if the task is complete, just report.
${HANDOFF_BLOCK}"
    jq -n --arg t "$TEXT" '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$t}}' 2>/dev/null || exit 0
    exit 0
fi

# --pre
[ "$PCT" -ge "$CEILING" ] || exit 0
REASON="$(hard_refusal_text "$PCT")"
jq -n --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}' 2>/dev/null || exit 0
exit 0
