#!/usr/bin/env bats
#
# context-meter.bats -- acceptance contract for claude-orca-7lz.1 (the
# Claude-side sub-agent context meter). FROZEN from RED-AT onward.
#
# scripts/context-meter.sh is a PostToolUse/PreToolUse hook, invoked as
# context-meter --post / --pre, that meters a Claude Code sub-agent's OWN
# transcript after each tool call and enforces claude-orca-7lz's shared
# contract: a soft [context-meter] notice from CLAUDE_ORCA_CONTEXT_BUDGET
# (default 30%) on, a hard tool-call refusal from CLAUDE_ORCA_CONTEXT_CEILING
# (default 40%) on. The main loop (no agent_id on its hook payload) is
# never metered.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
METER="$REPO_ROOT/scripts/context-meter.sh"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    S="$BATS_TEST_TMPDIR/s"
    mkdir -p "$S/sess/subagents"
    : > "$S/sess.jsonl"
    SUB_T="$S/sess/subagents/agent-a1.jsonl"
    META="$S/sess/subagents/agent-a1.meta.json"
    : > "$SUB_T"
}

# usage_row input cache_read cache_creation output [model] -- one assistant
# transcript row carrying a usage object, appended to the sub-agent's own
# transcript.
usage_row() {
    local input="$1" cache_read="$2" cache_creation="$3" output="$4" model="${5:-sonnet}"
    jq -cn --argjson input "$input" --argjson cr "$cache_read" --argjson cc "$cache_creation" \
        --argjson output "$output" --arg model "$model" \
        '{type:"assistant", message:{model:$model, usage:{input_tokens:$input, cache_read_input_tokens:$cr, cache_creation_input_tokens:$cc, output_tokens:$output}}}' >> "$SUB_T"
}

write_meta() {
    jq -cn --arg model "$1" '{agentType:"scout", model:$model}' > "$META"
}

sub_payload() {
    jq -cn --arg s "$S/sess.jsonl" --arg aid "${1:-a1}" \
        '{tool_name:"Bash", agent_id:$aid, agent_type:"scout", transcript_path:$s}'
}

main_payload() {
    jq -cn --arg s "$S/sess.jsonl" '{tool_name:"Bash", transcript_path:$s}'
}

# meter <--post|--pre> [ENVVAR=val ...] -- runs the pinned script exactly
# as the WORKER RULES require: env -i, an isolated HOME, stdin carrying
# $PAYLOAD.
meter() {
    local mode="$1"; shift
    run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR/h" "$@" bash "$METER" "$mode" <<<"$PAYLOAD"
}

@test "1 main loop (no agent_id) at 90% context: no output from --post or --pre, exit 0" {
    PAYLOAD="$(main_payload)"
    meter --post
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    meter --pre
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "2 sub-agent at 20% (40000 tokens): --post prints nothing" {
    write_meta sonnet
    usage_row 40000 0 0 0
    PAYLOAD="$(sub_payload)"
    meter --post
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "3 sub-agent at 35% (70000 tokens): --post prints the soft notice" {
    write_meta sonnet
    usage_row 70000 0 0 0
    PAYLOAD="$(sub_payload)"
    meter --post
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"'
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    case "$ctx" in
        "[context-meter] context is at 35% of this agent's window (budget 30%)"*) ;;
        *) false ;;
    esac
    printf '%s\n' "$ctx" | grep -qx 'HANDOFF'
    printf '%s\n' "$ctx" | grep -q '^relay: '
}

@test "4 sub-agent at 35% (70000 tokens): --pre prints nothing" {
    write_meta sonnet
    usage_row 70000 0 0 0
    PAYLOAD="$(sub_payload)"
    meter --pre
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "5 sub-agent at 45% (90000 tokens): --pre denies with the ceiling reason" {
    write_meta sonnet
    usage_row 90000 0 0 0
    PAYLOAD="$(sub_payload)"
    meter --pre
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    reason="$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
    case "$reason" in *"at 45%"*) ;; *) false ;; esac
    case "$reason" in *"past the 40% ceiling"*) ;; *) false ;; esac
}

@test "6 meta model opus[1m] widens the window: 90000 tokens is 9%, --post prints nothing" {
    write_meta 'opus[1m]'
    usage_row 90000 0 0 0
    PAYLOAD="$(sub_payload)"
    meter --post
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "7 CLAUDE_ORCA_CONTEXT_WINDOW overrides the lookup: 35000/100000 is 35%" {
    write_meta sonnet
    usage_row 35000 0 0 0
    PAYLOAD="$(sub_payload)"
    meter --post CLAUDE_ORCA_CONTEXT_WINDOW=100000
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    case "$ctx" in *"at 35%"*) ;; *) false ;; esac
}

@test "8 CLAUDE_ORCA_CONTEXT_BUDGET=0 turns the meter off entirely" {
    write_meta sonnet
    usage_row 180000 0 0 0
    PAYLOAD="$(sub_payload)"
    meter --post CLAUDE_ORCA_CONTEXT_BUDGET=0
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    meter --pre CLAUDE_ORCA_CONTEXT_BUDGET=0
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "9 CLAUDE_ORCA_CONTEXT_BUDGET=10: 24000 tokens is 12%, above the lowered budget" {
    write_meta sonnet
    usage_row 24000 0 0 0
    PAYLOAD="$(sub_payload)"
    meter --post CLAUDE_ORCA_CONTEXT_BUDGET=10
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    case "$ctx" in *"at 12%"*) ;; *) false ;; esac
    case "$ctx" in *"budget 10%"*) ;; *) false ;; esac
}

@test "10 a non-numeric CLAUDE_ORCA_CONTEXT_BUDGET falls back to the 30% default" {
    write_meta sonnet
    usage_row 70000 0 0 0
    PAYLOAD="$(sub_payload)"
    meter --post CLAUDE_ORCA_CONTEXT_BUDGET=abc
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    case "$ctx" in *"at 35%"*) ;; *) false ;; esac
    case "$ctx" in *"budget 30%"*) ;; *) false ;; esac
}

@test "11 only the LAST usage row counts, not a running sum" {
    write_meta sonnet
    usage_row 160000 0 0 0
    usage_row 20000 0 0 0
    PAYLOAD="$(sub_payload)"
    meter --post
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "12 context sums all four usage fields" {
    write_meta sonnet
    usage_row 1 50000 10000 2000
    PAYLOAD="$(sub_payload)"
    meter --post
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    case "$ctx" in *"at 31%"*) ;; *) false ;; esac
}

@test "13 fails open: missing sub-agent transcript, and separately unparsable stdin" {
    write_meta sonnet
    rm -f "$SUB_T"
    PAYLOAD="$(sub_payload)"
    meter --post
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR/h" bash "$METER" --post <<<"not json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "14 config/claude-settings.json carries the PostToolUse and PreToolUse hook entries" {
    run jq -e '.hooks.PostToolUse[] | select(.matcher == "" and any(.hooks[]; .command // "" | contains("bin/context-meter\" --post")))' "$REPO_ROOT/config/claude-settings.json"
    [ "$status" -eq 0 ]
    run jq -e '.hooks.PreToolUse[] | select(.matcher == "" and any(.hooks[]; .command // "" | contains("bin/context-meter\" --pre")))' "$REPO_ROOT/config/claude-settings.json"
    [ "$status" -eq 0 ]
}

@test "15 bin/context-meter symlinks to the script; scout/executor/verifier carry the Context budget section" {
    link="$(readlink "$REPO_ROOT/bin/context-meter")"
    [ "$link" = "../scripts/context-meter.sh" ]
    for f in scout executor verifier; do
        grep -q '## Context budget' "$REPO_ROOT/config/agents/$f.md"
        grep -q '\[context-meter\]' "$REPO_ROOT/config/agents/$f.md"
    done
}

@test "16 --pre at 45%: the deny reason carries the HANDOFF template" {
    write_meta sonnet
    usage_row 90000 0 0 0
    PAYLOAD="$(sub_payload)"
    meter --pre
    [ "$status" -eq 0 ]
    reason="$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
    case "$reason" in
        *"Write your final report now and stop. If work remains, end it with this block:"*) ;;
        *) false ;;
    esac
    printf '%s\n' "$reason" | grep -qx 'HANDOFF'
    printf '%s\n' "$reason" | grep -q '^relay: '
}

@test "17 --post at 45% is the HARD REFUSAL (no budget text); --post at 35% still says 'just report'" {
    write_meta sonnet
    usage_row 90000 0 0 0
    PAYLOAD="$(sub_payload)"
    meter --post
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    case "$ctx" in *"past the 40% ceiling"*) ;; *) false ;; esac
    printf '%s\n' "$ctx" | grep -qx 'HANDOFF'
    case "$ctx" in *"(budget 30%)"*) false ;; esac

    usage_row 70000 0 0 0
    PAYLOAD="$(sub_payload)"
    meter --post
    [ "$status" -eq 0 ]
    ctx2="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    case "$ctx2" in *"if the task is complete, just report"*) ;; *) false ;; esac
}

# Guards:   an agent over its context budget gets the full notice (with the
#           HANDOFF template) once, then a one-line reminder, instead of the
#           same ~500 bytes on every tool call.
# Fails if: the reminder repeats the whole notice, never comes, or the
#           marker from one agent silences another.
# Run:      bats -f 'full notice once' tests/context-meter.bats
@test "18 --post past the budget: full notice once per agent, then a one-line reminder" {
    write_meta sonnet
    usage_row 70000 0 0 0
    PAYLOAD="$(sub_payload)"
    meter --post
    first="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    printf '%s\n' "$first" | grep -qx 'HANDOFF'
    meter --post
    [ "$status" -eq 0 ]
    second="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    case "$second" in "[context-meter] still at 35%"*) ;; *) false ;; esac
    ! printf '%s\n' "$second" | grep -qx 'HANDOFF'
    [ "$(printf '%s\n' "$second" | wc -l)" -eq 1 ]
}
