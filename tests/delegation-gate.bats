#!/usr/bin/env bats
# delegation-gate.bats — PreToolUse hook that counts consecutive inline
# work-tool calls made by the MAIN LOOP ONLY and, by mode, warns or denies
# once a streak crosses a threshold. Must fail OPEN on any malformed/
# unrecognized input.
#
# Main-loop discriminator (STEP 0, empirical): the hypothesis that a
# subagent's PreToolUse payload carries "/subagents/" in transcript_path
# was DISPROVEN by a live probe (scratchpad/gateprobe/) — transcript_path
# is identical for main-loop and subagent calls. The real discriminator is
# agent_id/agent_type: ABSENT on real main-loop calls, populated on subagent calls. Tests
# below use agent_id as the discriminator and include a regression guard
# (see "transcript_path is NOT the discriminator") locking in that finding.

GATE=/workspace/scripts/delegation-gate.py

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
}

gate() { python3 "$GATE"; }

state_file() {
    echo "$HOME/.claude/cache/delegation-gate/$1.json"
}

# ── main-loop counting ──────────────────────────────────────────────────────

@test "main-loop Read increments streak in state file (REAL payload shape: agent_id key ABSENT)" {
    # Real v2.1.220 main-loop payloads carry NO agent_id key at all. The
    # originally shipped gate read key-absence as "subagent, don't gate"
    # and therefore never fired on real traffic — this fixture is the
    # regression guard: absence MUST count as main loop.
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s1\",tool_input:{file_path:\"/x\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.streak == 1' "$(state_file s1)"
}

@test "main-loop Read with agent_id:null (legacy/alternate shape) also counts" {
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s1b\",agent_id:null,tool_input:{file_path:\"/x\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.streak == 1' "$(state_file s1b)"
}

@test "subagent call (agent_id set) is skipped: no state change, empty output" {
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s2\",agent_id:\"a1\",agent_type:\"scout\",tool_input:{file_path:\"/x\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$(state_file s2)" ]
}

@test "transcript_path is NOT the discriminator: a /subagents/ path with agent_id null still counts as main loop" {
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s2b\",agent_id:null,transcript_path:\"/p/s/subagents/agent-1.jsonl\",tool_input:{file_path:\"/x\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    jq -e '.streak == 1' "$(state_file s2b)"
}

@test "Agent payload resets an existing streak" {
    for i in 1 2 3; do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s3\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    done
    jq -e '.streak == 3' "$(state_file s3)"
    run sh -c 'jq -cn "{tool_name:\"Agent\",session_id:\"s3\",agent_id:null,tool_input:{subagent_type:\"scout\",prompt:\"p\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.streak == 0' "$(state_file s3)"
    jq -e '.warned == false' "$(state_file s3)"
}

# ── warn mode ────────────────────────────────────────────────────────────────

@test "warn mode: WARN_AT-th call fires the note once, the call after stays silent" {
    export DELEGATION_GATE_MODE=warn
    export DELEGATION_GATE_WARN_AT=4
    for i in 1 2 3; do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s4\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s4\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("4 consecutive")'
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s4\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "env override: DELEGATION_GATE_WARN_AT=2 fires the note at streak 2" {
    export DELEGATION_GATE_MODE=warn
    export DELEGATION_GATE_WARN_AT=2
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s9\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s9\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("2 consecutive")'
}

# ── enforce mode ─────────────────────────────────────────────────────────────

@test "enforce: Edit is always denied naming the executor" {
    export DELEGATION_GATE_MODE=enforce
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s5a\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("executor")'
}

@test "enforce: Read at DENY_AT is denied naming scout; Read below DENY_AT is allowed" {
    export DELEGATION_GATE_MODE=enforce
    export DELEGATION_GATE_DENY_AT=8
    for i in 1 2 3 4 5 6 7; do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s5b\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    jq -e '.streak == 7' "$(state_file s5b)"
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s5b\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("scout")'
}

# ── exemptions and mode=off ─────────────────────────────────────────────────

@test "exempt Bash (bd ready) passes silently at any streak and does not increment" {
    export DELEGATION_GATE_MODE=enforce
    export DELEGATION_GATE_DENY_AT=2
    for i in 1 2 3 4; do
        run sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s6\",agent_id:null,tool_input:{command:\"bd ready\"}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    [ ! -f "$(state_file s6)" ]
}

@test "mode=off: silent allow for everything, including Edit and a past-threshold Read" {
    export DELEGATION_GATE_MODE=off
    export DELEGATION_GATE_DENY_AT=1
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s7\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s7\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── robustness ───────────────────────────────────────────────────────────────

@test "junk stdin fails open: exit 0, no output" {
    run sh -c 'printf %s "NOT JSON" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "GC: a state file aged 8+ days is removed on the next invocation; a fresh one survives" {
    mkdir -p "$HOME/.claude/cache/delegation-gate"
    OLD="$(state_file old-session)"
    printf '{"streak":3,"warned":false}' > "$OLD"
    touch -d "8 days ago" "$OLD"
    FRESH="$(state_file fresh-session)"
    printf '{"streak":1,"warned":false}' > "$FRESH"
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"gc-trigger\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ ! -f "$OLD" ]
    [ -f "$FRESH" ]
}
