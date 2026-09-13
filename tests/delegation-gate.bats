#!/usr/bin/env bats
# delegation-gate.bats — PreToolUse hook that counts consecutive inline
# work-tool calls made by the MAIN LOOP ONLY and nudges once a streak
# crosses a threshold. Must fail OPEN on any malformed/unrecognized input.
#
# ADVISORY (Sept 2026): the gate NEVER denies, in any mode. Every path that
# used to emit permissionDecision "deny" now emits "allow" plus an
# additionalContext note prefixed "[delegation-gate]"; the "denies" counter
# stays in the state schema and stays 0. Defaults are WARN_AT=8 and
# WARN_EVERY=8; Read/Grep/Glob count half (one streak tick per two calls);
# every git/gh/bd call and any edit to a scratchpad, a plan file or the
# harness memory dir is exempt from the streak entirely.
#
# Main-loop discriminator (STEP 0, empirical): the hypothesis that a
# subagent's PreToolUse payload carries "/subagents/" in transcript_path
# was DISPROVEN by a live probe (scratchpad/gateprobe/) — transcript_path
# is identical for main-loop and subagent calls. The real discriminator is
# agent_id/agent_type: ABSENT on real main-loop calls, populated on subagent calls. Tests
# below use agent_id as the discriminator and include a regression guard
# (see "transcript_path is NOT the discriminator") locking in that finding.

GATE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/python/delegation-gate.py"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    # scratch router state, so no test can read the real session's lane
    export LANE_STATE_DIR="$BATS_TEST_TMPDIR/lane-state"
}

gate() { python3 "$GATE"; }

state_file() {
    echo "$HOME/.claude/cache/delegation-gate/$1.json"
}

# Write what scripts/lane.sh writes for `lane <lane>`: set_lane <sid> <lane>
set_lane() {
    mkdir -p "$LANE_STATE_DIR"
    printf '{"lane":"%s","prev":"unset","why":"","ts":0,"escalated":false}\n' "$2" \
        > "$LANE_STATE_DIR/$1.json"
}

# A non-exempt Bash call: the unit that still counts 1:1 toward the streak.
# Most cadence tests below use it rather than Read, which counts half.
bash_call() {
    jq -cn --arg s "$1" '{tool_name:"Bash",session_id:$s,agent_id:null,tool_input:{command:"cat /etc/hosts"}}' \
        | python3 "$GATE"
}

# ── main-loop counting ──────────────────────────────────────────────────────

@test "main-loop Bash increments streak in state file (REAL payload shape: agent_id key ABSENT)" {
    # Real v2.1.220 main-loop payloads carry NO agent_id key at all. The
    # originally shipped gate read key-absence as "subagent, don't gate"
    # and therefore never fired on real traffic — this fixture is the
    # regression guard: absence MUST count as main loop.
    run sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s1\",tool_input:{command:\"cat /etc/hosts\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.streak == 1' "$(state_file s1)"
}

@test "main-loop Read with agent_id:null (legacy/alternate shape) also counts (half weight)" {
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s1b\",agent_id:null,tool_input:{file_path:\"/x\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.streak == 0' "$(state_file s1b)"
    jq -e '.ro_pending == 1' "$(state_file s1b)"
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s1b\",agent_id:null,tool_input:{file_path:\"/x\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    jq -e '.streak == 1' "$(state_file s1b)"
    jq -e '.ro_pending == 0' "$(state_file s1b)"
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
    jq -e '.ro_pending == 1' "$(state_file s2b)"
}

@test "Agent payload resets an existing streak and the half-read carry" {
    for i in 1 2 3; do
        run bash_call s3
    done
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s3\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    jq -e '.streak == 3' "$(state_file s3)"
    jq -e '.ro_pending == 1' "$(state_file s3)"
    run sh -c 'jq -cn "{tool_name:\"Agent\",session_id:\"s3\",agent_id:null,tool_input:{subagent_type:\"scout\",prompt:\"p\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.streak == 0' "$(state_file s3)"
    jq -e '.warned_at == 0' "$(state_file s3)"
    jq -e '.ro_pending == 0' "$(state_file s3)"
}

# ── read-only half counting (Read/Grep/Glob) ────────────────────────────────

@test "read-only tools count half: Read/Grep/Glob share one carry, two calls = one streak tick" {
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_WARN_AT=99
    run sh -c 'jq -cn "{tool_name:\"Grep\",session_id:\"s60\",agent_id:null,tool_input:{pattern:\"x\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.streak == 0' "$(state_file s60)"
    run sh -c 'jq -cn "{tool_name:\"Glob\",session_id:\"s60\",agent_id:null,tool_input:{pattern:\"*\"}}" | python3 '"$GATE"
    jq -e '.streak == 1' "$(state_file s60)"
    for i in $(seq 1 6); do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s60\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
    done
    jq -e '.streak == 4' "$(state_file s60)"
}

@test "recon alone reaches the default warn at ~16 read-only calls, not 8" {
    export DELEGATION_GATE_MODE=warn-only   # defaults: WARN_AT=8, WARN_EVERY=8
    for i in $(seq 1 15); do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s61\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    jq -e '.streak == 7' "$(state_file s61)"
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s61\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("8 consecutive")'
}

# ── warn cadence ─────────────────────────────────────────────────────────────

@test "defaults are WARN_AT=8 and WARN_EVERY=8: first note at 8, next at 16" {
    export DELEGATION_GATE_MODE=warn-only
    for i in $(seq 1 7); do
        run bash_call s4d
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    run bash_call s4d
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("8 consecutive")'
    for i in $(seq 9 15); do
        run bash_call s4d
        [ -z "$output" ]
    done
    run bash_call s4d
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("16 consecutive")'
}

@test "warn-only mode: WARN_AT-th call fires the note once, 5-7 stay silent, streak 8/12/16 warn again (repeat cadence)" {
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_WARN_AT=4
    export DELEGATION_GATE_WARN_EVERY=4
    for i in 1 2 3; do
        run bash_call s4
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    run bash_call s4
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("4 consecutive")'
    for i in 5 6 7; do
        run bash_call s4
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    run bash_call s4
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("8 consecutive")'
    for i in 9 10 11; do
        run bash_call s4
        [ -z "$output" ]
    done
    run bash_call s4
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("12 consecutive")'
    for i in 13 14 15; do
        run bash_call s4
        [ -z "$output" ]
    done
    run bash_call s4
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("16 consecutive")'
}

@test "env override: DELEGATION_GATE_WARN_AT=2 fires the note at streak 2 (four reads, half weight)" {
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_WARN_AT=2
    for i in 1 2 3; do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s9\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s9\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("2 consecutive")'
}

@test "warn (legacy alias for warn-only) still fires and never denies" {
    export DELEGATION_GATE_MODE=warn
    export DELEGATION_GATE_WARN_AT=1
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s9b\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
}

@test "Agent reset clears the warned_at watermark: the next streak warns again" {
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_WARN_AT=4
    export DELEGATION_GATE_WARN_EVERY=1
    for i in $(seq 1 8); do
        run bash_call s11
    done
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("8 consecutive")'
    run sh -c 'jq -cn "{tool_name:\"Agent\",session_id:\"s11\",agent_id:null,tool_input:{subagent_type:\"scout\",prompt:\"p\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    for i in 1 2 3; do
        run bash_call s11
        [ -z "$output" ]
    done
    run bash_call s11
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("4 consecutive")'
}

# ── advisory: nothing is ever denied ────────────────────────────────────────

@test "enforce: a main-loop Edit draws the executor note as an ALLOW, never a deny" {
    export DELEGATION_GATE_MODE=enforce
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s5a\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("executor")'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("^\\[delegation-gate\\]")'
    echo "$output" | jq -e 'has("permissionDecisionReason") == false'
    jq -e '.denies == 0' "$(state_file s5a)"
}

@test "enforce: Read at the note threshold names scout, as an allow; below it is silent" {
    export DELEGATION_GATE_MODE=enforce
    export DELEGATION_GATE_DENY_AT=8
    export DELEGATION_GATE_WARN_AT=99  # isolate the note-at-streak behavior from the (separately tested) warn cadence
    for i in $(seq 1 15); do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s5b\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    jq -e '.streak == 7' "$(state_file s5b)"
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s5b\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("scout")'
    jq -e '.denies == 0' "$(state_file s5b)"
}

@test "guard mode (default when unset) notes a Write to /workspace/src/x.py naming the executor, and allows it" {
    run sh -c 'jq -cn "{tool_name:\"Write\",session_id:\"s12\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("executor")'
}

@test "guard mode: unrecognized DELEGATION_GATE_MODE value behaves like guard and still never denies" {
    export DELEGATION_GATE_MODE=bogus-typo
    run sh -c 'jq -cn "{tool_name:\"Write\",session_id:\"s12b\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("executor")'
}

@test "no payload in any mode or lane ever produces permissionDecision deny" {
    for m in guard enforce warn-only warn off bogus; do
        export DELEGATION_GATE_MODE="$m"
        export DELEGATION_GATE_DENY_AT=1
        export DELEGATION_GATE_WARN_AT=1
        for t in Edit Write NotebookEdit Read Grep Glob; do
            run sh -c 'jq -cn --arg t "'"$t"'" "{tool_name:\$t,session_id:\"s70'"$m$t"'\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
            [ "$status" -eq 0 ]
            [ -z "$output" ] || echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
        done
        run sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s70'"$m"'b\",agent_id:null,tool_input:{command:\"cat /etc/hosts\"}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ] || echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    done
}

# ── edit exemptions: plans, harness memory, scratchpad ──────────────────────

@test "a Write to \$HOME/.claude/plans/x.md is exempt: silent and not counted" {
    export DELEGATION_GATE_MODE=guard
    run sh -c 'jq -cn "{tool_name:\"Write\",session_id:\"s13\",agent_id:null,tool_input:{file_path:(env.HOME+\"/.claude/plans/x.md\")}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$(state_file s13)" ]
}

@test "any path containing /.claude/plans/ is exempt (git-root-relative plan dir)" {
    export DELEGATION_GATE_MODE=guard
    run sh -c 'jq -cn "{tool_name:\"Write\",session_id:\"s14\",agent_id:null,tool_input:{file_path:\"/workspace/.claude/plans/y.md\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$(state_file s14)" ]
}

@test "an Edit under the harness auto-memory dir (~/.claude/projects/*/memory/) is exempt" {
    export DELEGATION_GATE_MODE=guard
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s15\",agent_id:null,tool_input:{file_path:(env.HOME+\"/.claude/projects/-workspace/memory/foo.md\")}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$(state_file s15)" ]
}

@test "a Write under the session scratchpad (/tmp/claude-*/) is exempt" {
    export DELEGATION_GATE_MODE=guard
    run sh -c 'jq -cn "{tool_name:\"Write\",session_id:\"s15c\",agent_id:null,tool_input:{file_path:\"/tmp/claude-501/-workspace-x/abc/scratchpad/note.md\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$(state_file s15c)" ]
}

@test "an Edit to any path containing /scratchpad/ is exempt" {
    export DELEGATION_GATE_MODE=guard
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s15d\",agent_id:null,tool_input:{file_path:\"/workspace/proj/scratchpad/probe.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$(state_file s15d)" ]
}

@test "a NotebookEdit with no resolvable path is not exempt (the exemption must be proven) but is still allowed" {
    export DELEGATION_GATE_MODE=guard
    run sh -c 'jq -cn "{tool_name:\"NotebookEdit\",session_id:\"s15b\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("executor")'
    jq -e '.streak == 1' "$(state_file s15b)"
}

@test "guard mode allows a Read at any streak and never records a deny" {
    export DELEGATION_GATE_MODE=guard
    for i in $(seq 1 20); do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s16\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
    done
    jq -e '.streak == 10' "$(state_file s16)"
    jq -e '.denies == 0' "$(state_file s16)"
}

@test "warn-only mode notes but never denies, even an Edit or a Read well past the threshold" {
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
    run bash_call s19
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.streak == 6' "$(state_file s19)"
    jq -e '.warned_at == 5' "$(state_file s19)"
    for i in 1 2 3 4 5 6; do
        run bash_call s19
        [ -z "$output" ]
    done
    jq -e '.streak == 12' "$(state_file s19)"
    run bash_call s19
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    jq -e '.streak == 13' "$(state_file s19)"
}

@test "missing new keys in an old state file default to 0 (including ro_pending)" {
    mkdir -p "$HOME/.claude/cache/delegation-gate"
    printf '{"streak":2}' > "$(state_file s19b)"
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_WARN_AT=99
    run bash_call s19b
    [ "$status" -eq 0 ]
    jq -e '.warned_at == 0' "$(state_file s19b)"
    jq -e '.max_streak == 3' "$(state_file s19b)"
    jq -e '.warns == 0' "$(state_file s19b)"
    jq -e '.denies == 0' "$(state_file s19b)"
    jq -e '.ro_pending == 0' "$(state_file s19b)"
}

@test "max_streak, warns, and denies survive an Agent reset (only streak/warned_at/ro_pending reset)" {
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_WARN_AT=2
    export DELEGATION_GATE_WARN_EVERY=1
    for i in 1 2 3; do
        run bash_call s20
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

@test "every git invocation is exempt, not just the read-only ones" {
    export DELEGATION_GATE_MODE=enforce
    export DELEGATION_GATE_DENY_AT=1
    for c in "git worktree add /tmp/wt main" "git merge --no-ff wt/x" "git rebase main" "git commit -m x" "git push"; do
        run sh -c 'jq -cn --arg c "'"$c"'" "{tool_name:\"Bash\",session_id:\"s6f\",agent_id:null,tool_input:{command:\$c}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    [ ! -f "$(state_file s6f)" ]
}

@test "gh invocations are exempt" {
    export DELEGATION_GATE_MODE=enforce
    export DELEGATION_GATE_DENY_AT=1
    for c in "gh auth status" "gh pr list" "gh api repos/o/r/contents/x"; do
        run sh -c 'jq -cn --arg c "'"$c"'" "{tool_name:\"Bash\",session_id:\"s6g\",agent_id:null,tool_input:{command:\$c}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    [ ! -f "$(state_file s6g)" ]
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

# ── lanes (complexity router) ───────────────────────────────────────────────
#
# express means the task is small by definition, so the guard/enforce notes
# invert: the edit draws nothing and a long grind gets its own warn instead
# of the delegation nudge. Every other lane value — including a name this
# gate doesn't know and a missing state file — behaves as it always did,
# minus the denial that no longer exists anywhere.

@test "lane express: guard says nothing about a main-loop Edit to /workspace/src/x.py (streak still counted)" {
    export DELEGATION_GATE_MODE=guard
    set_lane s30 express
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s30\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.streak == 1' "$(state_file s30)"
    jq -e '.denies == 0' "$(state_file s30)"
}

@test "lane express: enforce says nothing about a Read past the threshold or a non-exempt Bash" {
    export DELEGATION_GATE_MODE=enforce
    export DELEGATION_GATE_DENY_AT=8
    set_lane s31 express
    for i in $(seq 1 16); do
        run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s31\",agent_id:null,tool_input:{}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
    done
    jq -e '.streak == 8' "$(state_file s31)"
    jq -e '.denies == 0' "$(state_file s31)"
    run bash_call s31
    [ "$status" -eq 0 ]
    jq -e '.streak == 9' "$(state_file s31)"
    jq -e '.denies == 0' "$(state_file s31)"
}

@test "lane express: the express warn fires at streak 6 and repeats at 10, and the delegation nudge is suppressed" {
    export DELEGATION_GATE_MODE=guard
    set_lane s32 express
    for i in $(seq 1 5); do
        run bash_call s32
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    run bash_call s32
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("express lane, 6 inline tool calls")'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("lane standard --why")'
    echo "$output" | jq -e '(.hookSpecificOutput.additionalContext | test("consecutive inline tool calls")) == false'
    for i in $(seq 7 9); do
        run bash_call s32
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    run bash_call s32
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("express lane, 10 inline tool calls")'
}

@test "lane standard: guard says nothing about a main-loop Edit and Write (beads_claude_docker-dl2)" {
    export DELEGATION_GATE_MODE=guard
    set_lane s33 standard
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s33\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run sh -c 'jq -cn "{tool_name:\"Write\",session_id:\"s33\",agent_id:null,tool_input:{file_path:\"/workspace/src/y.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.denies == 0' "$(state_file s33)"
}

@test "lane standard: no edit note, but the inline-streak warn still fires at WARN_AT" {
    export DELEGATION_GATE_MODE=guard
    export DELEGATION_GATE_WARN_AT=4
    export DELEGATION_GATE_WARN_EVERY=8
    set_lane s33c standard
    for i in 1 2 3; do
        run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s33c\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s33c\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("4 consecutive")'
    jq -e '.denies == 0' "$(state_file s33c)"
}

@test "lane deep: guard still notes a main-loop Edit (as an allow)" {
    export DELEGATION_GATE_MODE=guard
    set_lane s33b deep
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s33b\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("executor")'
}

@test "lane unknown value (turbo) behaves exactly like unset: guard notes the Edit" {
    export DELEGATION_GATE_MODE=guard
    set_lane s34 turbo
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s34\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("executor")'
}

@test "lane state that is unparsable JSON behaves like unset: guard notes the Edit" {
    export DELEGATION_GATE_MODE=guard
    mkdir -p "$LANE_STATE_DIR"
    printf '{"lane":"expr' > "$LANE_STATE_DIR/s34b.json"
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s34b\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("executor")'
}

@test "no lane state file at all (state dir never created) behaves like unset: guard notes the Edit" {
    export DELEGATION_GATE_MODE=guard
    [ ! -d "$LANE_STATE_DIR" ]
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s35\",agent_id:null,tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("executor")'
}

@test "lane express does not change subagent handling: an agent_id call is still skipped entirely" {
    export DELEGATION_GATE_MODE=guard
    set_lane s36 express
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s36\",agent_id:\"a1\",agent_type:\"executor\",tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$(state_file s36)" ]
}

@test "exempt Bash: a lane declaration does not count toward the streak" {
    export DELEGATION_GATE_MODE=enforce
    export DELEGATION_GATE_DENY_AT=1
    run sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s37\",agent_id:null,tool_input:{command:\"lane express --why x\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$(state_file s37)" ]
}

# ── the nudge points at the Orca dispatch loop (claude-orca-qa2.14) ─────────

@test "delegation-gate names orca-dispatch in its nudge" {
    # the repeating warn note
    export DELEGATION_GATE_MODE=warn-only
    export DELEGATION_GATE_WARN_AT=2
    run bash_call s40
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run bash_call s40
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("orca-dispatch")'

    # and the guard-mode edit note
    unset DELEGATION_GATE_MODE
    unset DELEGATION_GATE_WARN_AT
    run sh -c 'jq -cn "{tool_name:\"Write\",session_id:\"s41\",agent_id:null,tool_input:{file_path:\"/srv/app/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("orca-dispatch")'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("executor")'
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

# ── Bash: the orchestrator's other inline seat (claude-orca-8a0.3) ──────────
#
# Reading a file with `cat` costs the orchestrator exactly what reading it
# with Read costs, so the streak that notes an Edit notes a Bash call too
# once it is long enough. The exempt list (bd, git, gh, bats, lane, tier-…)
# is untouched: those are how the session steers.

@test "the delegation gate notes a main-loop Bash call past the streak threshold, and still allows it" {
    export DELEGATION_GATE_DENY_AT=3
    export DELEGATION_GATE_WARN_AT=99
    for i in 1 2; do
        run bash_call s50
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    jq -e '.streak == 2' "$(state_file s50)"
    jq -e '.denies == 0' "$(state_file s50)"

    run bash_call s50
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
    # the note names the exact spawn to use instead
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("scout")'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("executor")'
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("orca-dispatch")'
    jq -e '.denies == 0' "$(state_file s50)"

    # the exempt list still passes at any streak, and still counts for nothing
    run sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s50\",agent_id:null,tool_input:{command:\"bd ready\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.streak == 3' "$(state_file s50)"

    # lane express keeps its exemption: no Bash note there either
    set_lane s51 express
    for i in 1 2 3 4; do
        run bash_call s51
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    jq -e '.denies == 0' "$(state_file s51)"
}

@test "the delegation gate still skips subagent calls entirely" {
    export DELEGATION_GATE_DENY_AT=1
    export DELEGATION_GATE_WARN_AT=1
    export DELEGATION_GATE_MODE=enforce
    for i in 1 2 3; do
        run sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s52\",agent_id:\"a1\",agent_type:\"executor\",tool_input:{command:\"cat /etc/hosts\"}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    [ ! -f "$(state_file s52)" ]

    # …and neither its edits nor its reads leave a trace or a note
    run sh -c 'jq -cn "{tool_name:\"Edit\",session_id:\"s52\",agent_id:\"a1\",tool_input:{file_path:\"/workspace/src/x.py\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run sh -c 'jq -cn "{tool_name:\"Read\",session_id:\"s52\",agent_id:\"a1\",tool_input:{file_path:\"/x\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$(state_file s52)" ]
}

@test "guard: past the threshold the Bash note is on the cadence too -- 24 inline calls draw 3 notes (8, 16, 24), never one per call" {
    export DELEGATION_GATE_MODE=guard
    notes=0
    for i in $(seq 1 24); do
        run bash_call s-cad
        [ "$status" -eq 0 ]
        if [ -n "$output" ]; then
            echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
            notes=$((notes + 1))
            case "$i" in 8|16|24) ;; *) echo "note at call $i"; false ;; esac
        fi
    done
    [ "$notes" -eq 3 ]
}
