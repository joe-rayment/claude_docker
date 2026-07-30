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
    jq -e '.warned_at == 0' "$(state_file s3)"
}

# ── warn cadence ─────────────────────────────────────────────────────────────

@test "warn-only mode: WARN_AT-th call fires the note once, calls 5-7 stay silent, streak 8/16 warn again (repeat cadence)" {
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_WARN_AT=4
    export DELEGATION_GATE_WARN_EVERY=4
    for i in 1 2 3; do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s4\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s4\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("4 consecutive")'
    for i in 5 6 7; do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s4\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s4\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("8 consecutive")'
    for i in 9 10 11; do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s4\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s4\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("12 consecutive")'
    for i in 13 14 15; do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s4\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s4\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("16 consecutive")'
}

@test "env override: DELEGATION_GATE_WARN_AT=2 fires the note at streak 2" {
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_WARN_AT=2
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s9\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s9\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("2 consecutive")'
}

@test "warn (legacy alias for warn-only) still fires and never denies" {
    export DELEGATION_GATE_MODE=warn
    export DELEGATION_GATE_WARN_AT=1
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s9b\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
}

@test "escalated warn text: tier2 phrase at streak 8, tier3 phrase at streak 24 (WARN_EVERY=1)" {
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_WARN_AT=4
    export DELEGATION_GATE_WARN_EVERY=1
    for i in $(seq 1 8); do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s10\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
    done
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("standing request")'
    echo "$output" | jq -e '(.hookSpecificOutput.additionalContext | test("re-billed")) == false'
    for i in $(seq 9 24); do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s10\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
    done
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("re-billed")'
}

@test "Agent reset clears the warned_at watermark: next warn after reset is tier-1 text again" {
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_WARN_AT=4
    export DELEGATION_GATE_WARN_EVERY=1
    for i in $(seq 1 8); do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s11\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    done
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("standing request")'
    run sh -c 'jq -cn "{tool_name:\"Agent\",session_id:\"s11\",agent_id:null,tool_input:{subagent_type:\"scout\",prompt:\"p\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    for i in 1 2 3; do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s11\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ -z "$output" ]
    done
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s11\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("4 consecutive")'
    echo "$output" | jq -e '(.hookSpecificOutput.additionalContext | test("standing request")) == false'
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
    export DELEGATION_GATE_WARN_AT=99  # isolate the deny-at-streak behavior from the (separately tested) warn cadence
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

# ── guard mode (new default) ────────────────────────────────────────────────

@test "guard mode (default when unset) denies a Write to /workspace/src/x.py naming the executor" {
    run sh -c 'jq -cn "{tool_name:\"Write\",session_id:\"s12\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("executor")'
}

@test "guard mode: unrecognized DELEGATION_GATE_MODE value also denies (never silently weakens)" {
    export DELEGATION_GATE_MODE=bogus-typo
    run sh -c 'jq -cn "{tool_name:\"Write\",session_id:\"s12b\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "guard mode allows a Write to \$HOME/.claude/plans/x.md (plan carve-out)" {
    export DELEGATION_GATE_MODE=guard
    run sh -c 'jq -cn "{tool_name:\"Write\",session_id:\"s13\",agent_id:null,tool_input:{file_path:(env.HOME+\"/.claude/plans/x.md\")}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "guard mode allows a Write to any path containing /.claude/plans/ (git-root-relative plan dir)" {
    export DELEGATION_GATE_MODE=guard
    run sh -c 'jq -cn "{tool_name:\"Write\",session_id:\"s14\",agent_id:null,tool_input:{file_path:\"/workspace/.claude/plans/y.md\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "guard mode allows an Edit under the harness auto-memory dir (~/.claude/projects/*/memory/)" {
    export DELEGATION_GATE_MODE=guard
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s15\",agent_id:null,tool_input:{file_path:(env.HOME+\"/.claude/projects/-workspace/memory/foo.md\")}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "guard mode denies a NotebookEdit with no resolvable path (carve-out must be proven)" {
    export DELEGATION_GATE_MODE=guard
    run sh -c 'jq -cn "{tool_name:\"NotebookEdit\",session_id:\"s15b\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "guard mode allows a Read even at streak 20 (reads are never denied under guard)" {
    export DELEGATION_GATE_MODE=guard
    for i in $(seq 1 20); do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s16\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
    done
    jq -e '.streak == 20' "$(state_file s16)"
    jq -e '.denies == 0' "$(state_file s16)"
}

@test "enforce mode still denies a Read once it reaches DENY_AT (guard's floor plus the read-streak deny)" {
    export DELEGATION_GATE_MODE=enforce
    export DELEGATION_GATE_DENY_AT=8
    for i in 1 2 3 4 5 6 7; do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s17\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    done
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s17\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("scout")'
}

@test "warn-only mode denies nothing, even an Edit or a Read well past DENY_AT" {
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_DENY_AT=1
    export DELEGATION_GATE_WARN_AT=1
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s18\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    for i in 1 2 3 4 5 6 7 8; do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s18b\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
    done
    jq -e '.denies == 0' "$(state_file s18b)"
}

# ── legacy state migration and drift metrics ────────────────────────────────

@test "legacy state {streak:5,warned:true} migrates warned_at=5 without re-warning until cadence is due" {
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_WARN_AT=4
    export DELEGATION_GATE_WARN_EVERY=8
    mkdir -p "$HOME/.claude/cache/delegation-gate"
    printf '{"streak":5,"warned":true}' > "$(state_file s19)"
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s19\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.streak == 6' "$(state_file s19)"
    jq -e '.warned_at == 5' "$(state_file s19)"
    for i in 1 2 3 4 5 6; do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s19\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ -z "$output" ]
    done
    jq -e '.streak == 12' "$(state_file s19)"
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s19\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    jq -e '.streak == 13' "$(state_file s19)"
}

@test "missing new keys in an old state file default to 0" {
    mkdir -p "$HOME/.claude/cache/delegation-gate"
    printf '{"streak":2}' > "$(state_file s19b)"
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_WARN_AT=99
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s19b\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    jq -e '.warned_at == 0' "$(state_file s19b)"
    jq -e '.max_streak == 3' "$(state_file s19b)"
    jq -e '.warns == 0' "$(state_file s19b)"
    jq -e '.denies == 0' "$(state_file s19b)"
}

@test "max_streak, warns, and denies survive an Agent reset (only streak/warned_at reset)" {
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_WARN_AT=2
    export DELEGATION_GATE_WARN_EVERY=1
    for i in 1 2 3; do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s20\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    done
    jq -e '.max_streak == 3' "$(state_file s20)"
    jq -e '.warns == 2' "$(state_file s20)"
    run sh -c 'jq -cn "{tool_name:\"Agent\",session_id:\"s20\",agent_id:null,tool_input:{subagent_type:\"scout\",prompt:\"p\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.streak == 0' "$(state_file s20)"
    jq -e '.warned_at == 0' "$(state_file s20)"
    jq -e '.max_streak == 3' "$(state_file s20)"
    jq -e '.warns == 2' "$(state_file s20)"
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

@test "exempt Bash: leading cd then bd is exempt (cd /workspace && bd close)" {
    export DELEGATION_GATE_MODE=enforce
    export DELEGATION_GATE_DENY_AT=1
    run sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s6a\",agent_id:null,tool_input:{command:\"cd /workspace && bd close x --reason y\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$(state_file s6a)" ]
}

@test "exempt Bash: leading cd then git push via semicolon is exempt (cd /a; git push)" {
    export DELEGATION_GATE_MODE=enforce
    export DELEGATION_GATE_DENY_AT=1
    run sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s6b\",agent_id:null,tool_input:{command:\"cd /a; git push\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$(state_file s6b)" ]
}

@test "exempt Bash: multiline session-close sequence is exempt" {
    export DELEGATION_GATE_MODE=enforce
    export DELEGATION_GATE_DENY_AT=1
    run sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s6c\",agent_id:null,tool_input:{command:\"cd /workspace\ngit add -A\ngit commit -m x\ngit push\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$(state_file s6c)" ]
}

@test "mixed Bash: exempt segments plus a non-exempt cat is NOT exempt (increments streak)" {
    export DELEGATION_GATE_MODE=enforce
    export DELEGATION_GATE_DENY_AT=99
    run sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s6d\",agent_id:null,tool_input:{command:\"cd /w && bd ready && cat /etc/passwd\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.streak == 1' "$(state_file s6d)"
}

@test "exempt Bash: bare cd with no other command is exempt (pure navigation)" {
    export DELEGATION_GATE_MODE=enforce
    export DELEGATION_GATE_DENY_AT=1
    run sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s6e\",agent_id:null,tool_input:{command:\"cd /tmp\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$(state_file s6e)" ]
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
