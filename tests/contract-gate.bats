#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# contract-gate.bats — PreToolUse(Bash) hook that warns (or, in enforce mode,
# denies) a `bd close` run against a bead that carries an acceptance contract
# but no recorded `VERIFIED: PASS` note. Modelled on tests/delegation-gate.bats.
#
# FROZEN per beads_claude_docker-smo's acceptance contract: this file must
# not be edited after its RED commit. If a test here turns out to be wrong,
# stop and report — do not edit it.
#
# SUPERSEDED by the user, Sept 2026: acceptance contracts became opt-in
# (config/claude-user-memory.md § Tests), so a bead with NO contract is no
# longer gated -- (b2) pins that. The cases that used "no contract" as their
# example of a failing bead now use "a contract with no PASS" instead, which
# still fails the gate; what each case checks (close shapes, modes, lanes)
# is unchanged.
#
# A fake `bd` binary is staged ahead of the real one on PATH for every test
# except (h), which deliberately excludes it to prove the fail-open path.
# The fake `bd show <id> --json` responds with acceptance_criteria/notes
# taken from $FAKE_BD_ACCEPTANCE/$FAKE_BD_NOTES, and (for case f/the
# "ignored entirely" check) touches $FAKE_BD_MARKER whenever it is invoked
# at all, so a test can prove the gate never shelled out to bd.

GATE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/python/contract-gate.py"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"

    FAKE_BD_DIR="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$FAKE_BD_DIR"
    cat > "$FAKE_BD_DIR/bd" <<'EOF'
#!/bin/sh
[ -n "$FAKE_BD_MARKER" ] && touch "$FAKE_BD_MARKER" 2>/dev/null
if [ "$1" = "show" ]; then
    id="$2"
    jq -cn --arg id "$id" --arg acc "${FAKE_BD_ACCEPTANCE:-}" --arg notes "${FAKE_BD_NOTES:-}" \
        '[{id:$id, acceptance_criteria:$acc, notes:$notes}]'
    exit 0
fi
exit 1
EOF
    chmod +x "$FAKE_BD_DIR/bd"
    export PATH="$FAKE_BD_DIR:$PATH"
    unset CONTRACT_GATE_MODE
    # beads_claude_docker-4y6: the transcript-corroboration store root. Unset
    # so a value leaking in from the invoking shell can never flip the
    # fail-open cases below; HOME is already faked above, so the DEFAULT root
    # (~/.claude/projects) is absent unless a test builds one under $HOME.
    unset CONTRACT_GATE_TRANSCRIPT_ROOT
}

gate() { python3 "$GATE"; }

# (a) mode=off is silently allow, regardless of contract state.
@test "(a) mode=off is silently allow" {
    export CONTRACT_GATE_MODE=off
    export FAKE_BD_ACCEPTANCE=""
    export FAKE_BD_NOTES=""
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s1\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

# (b) mode=warn on a bead with a contract but no PASS prints a warning to stderr and exits 0.
@test "(b) mode=warn, contract but no PASS: warns on stderr, exits 0" {
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_ACCEPTANCE=$'CHECK:   x\nPASS-IF: y'
    export FAKE_BD_NOTES=""
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s2\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"acceptance contract"* ]]
    [[ "$stderr" == *"beads_claude_docker-smo"* ]]
}

# (c) mode=warn with contract AND a VERIFIED: PASS note is silent.
@test "(c) mode=warn, contract + VERIFIED: PASS: fully silent" {
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_ACCEPTANCE=$'CHECK:   x\nPASS-IF: y'
    export FAKE_BD_NOTES=$'RED-AT: abc123 some failure output\nVERIFIED: PASS all good'
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s3\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

# (d) mode=enforce with a contract but no PASS emits hookSpecificOutput.permissionDecision == deny.
@test "(d) mode=enforce, contract but no PASS: emits a deny decision" {
    export CONTRACT_GATE_MODE=enforce
    export FAKE_BD_ACCEPTANCE=$'CHECK:   x\nPASS-IF: y'
    export FAKE_BD_NOTES=""
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s4\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

# (b2) contracts are opt-in (config/claude-user-memory.md § Tests): a bead
# with NO acceptance contract closes silently, in warn and in enforce.
@test "(b2) no contract: allowed silently in warn and enforce (contracts are opt-in)" {
    export FAKE_BD_ACCEPTANCE=""
    export FAKE_BD_NOTES=""
    for mode in warn enforce; do
        export CONTRACT_GATE_MODE=$mode
        run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s2b\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
        [ -z "$stderr" ]
    done
}

# (e) mode=enforce WITH contract + PASS allows (silent, no deny).
@test "(e) mode=enforce, contract + VERIFIED: PASS: allows silently" {
    export CONTRACT_GATE_MODE=enforce
    export FAKE_BD_ACCEPTANCE=$'CHECK:   x\nPASS-IF: y'
    export FAKE_BD_NOTES=$'VERIFIED: PASS all good'
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s5\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

# (f) a non-'bd close' Bash command is ignored entirely: no output AND the
# gate never even shells out to bd (proven via the marker file).
@test "(f) non-'bd close' command is ignored entirely (bd never invoked)" {
    export CONTRACT_GATE_MODE=enforce
    export FAKE_BD_ACCEPTANCE=""
    export FAKE_BD_NOTES=""
    export FAKE_BD_MARKER="$BATS_TEST_TMPDIR/bd-was-called"
    rm -f "$FAKE_BD_MARKER"
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s6\",tool_input:{command:\"ls -la /workspace\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    [ ! -f "$FAKE_BD_MARKER" ]
}

# (g) unparseable stdin JSON exits 0 (fail-open).
@test "(g) unparseable stdin JSON fails open: exit 0, no output" {
    run --separate-stderr sh -c 'printf %s "NOT JSON" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

# (h) bd binary unavailable exits 0 (fail-open) -- PATH deliberately excludes
# both the fake bd dir and the real /usr/local/bin/bd.
@test "(h) bd binary unavailable fails open: exit 0, no output" {
    export PATH="/usr/bin:/bin"
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s7\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

# (i) an unrecognized mode string falls back to warn, never off.
@test "(i) unrecognized mode falls back to warn, never off" {
    export CONTRACT_GATE_MODE=bogus-typo
    export FAKE_BD_ACCEPTANCE=$'CHECK:   x\nPASS-IF: y'
    export FAKE_BD_NOTES=""
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s8\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"acceptance contract"* ]]
}

# --- beads_claude_docker-p9r: the four bypass holes -------------------------
# FROZEN from this bead's RED commit too: cases (j)-(m) must not be edited
# after that commit.

# (j) `bd done <id>` is bd's own alias for `bd close <id>` (bd close --help:
# "Aliases: close, done") and must be gated identically.
@test "(j) 'bd done <id>' is gated exactly like 'bd close <id>'" {
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_ACCEPTANCE=$'CHECK:   x\nPASS-IF: y'
    export FAKE_BD_NOTES=""
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s9\",tool_input:{command:\"bd done beads_claude_docker-smo\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"acceptance contract"* ]]
    [[ "$stderr" == *"beads_claude_docker-smo"* ]]
}

# (k) a bare `bd close` / `bd done` (no id) closes the LAST-TOUCHED bead, so
# it must not be silently allowed: the gate either resolves that bead and
# checks it, or conservatively asks for an explicit bead id.
@test "(k) bare 'bd close' with no id is not silently allowed" {
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_ACCEPTANCE=""
    export FAKE_BD_NOTES=""
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s10\",tool_input:{command:\"bd close\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"explicit bead id"* ]]

    export CONTRACT_GATE_MODE=enforce
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s11\",tool_input:{command:\"bd close --reason wrapped-up\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("explicit bead id")'
}

# (k2) bare `bd done` (the alias, no id) is treated the same way.
@test "(k2) bare 'bd done' with no id is not silently allowed" {
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_ACCEPTANCE=""
    export FAKE_BD_NOTES=""
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s12\",tool_input:{command:\"bd done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"explicit bead id"* ]]
}

# (l) `bd close [id...]` takes MANY ids: a clean first id must not shield a
# bad second one. Needs an id-sensitive fake bd (setup()'s answers the same
# for every id), so the stub is overridden for this test only.
@test "(l) 'bd close id1 id2' checks every id, not just the first" {
    cat > "$FAKE_BD_DIR/bd" <<'EOF'
#!/bin/sh
if [ "$1" = "show" ]; then
    id="$2"
    case "$id" in
        *-good) acc='CHECK:   x
PASS-IF: y'
                notes='VERIFIED: PASS all clear' ;;
        *)      acc='CHECK:   x
PASS-IF: y'
                notes='' ;;
    esac
    jq -cn --arg id "$id" --arg acc "$acc" --arg notes "$notes" \
        '[{id:$id, acceptance_criteria:$acc, notes:$notes}]'
    exit 0
fi
exit 1
EOF
    chmod +x "$FAKE_BD_DIR/bd"

    export CONTRACT_GATE_MODE=warn
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s13\",tool_input:{command:\"bd close beads_x-good beads_x-bad\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"beads_x-bad"* ]]
    [[ "$stderr" != *"beads_x-good"* ]]

    export CONTRACT_GATE_MODE=enforce
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s14\",tool_input:{command:\"bd close beads_x-good beads_x-bad\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("beads_x-bad")'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("beads_x-good") | not'
}

# (m) `bd update <id> --status closed` (and `-s closed`) closes a bead
# without ever saying "close": gated the same. Any OTHER `bd update` stays
# ignored entirely -- bd is never even invoked.
@test "(m) 'bd update <id> --status closed' is gated like a close" {
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_ACCEPTANCE=$'CHECK:   x\nPASS-IF: y'
    export FAKE_BD_NOTES=""
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s15\",tool_input:{command:\"bd update beads_claude_docker-smo --status closed\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"acceptance contract"* ]]
    [[ "$stderr" == *"beads_claude_docker-smo"* ]]

    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s16\",tool_input:{command:\"bd update beads_claude_docker-smo -s closed\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"acceptance contract"* ]]
    [[ "$stderr" == *"beads_claude_docker-smo"* ]]
}

# (m2) a non-closing `bd update` is still ignored entirely: no output, and
# the gate never shells out to bd (proven via the marker file).
@test "(m2) a non-closing 'bd update' is ignored entirely (bd never invoked)" {
    export CONTRACT_GATE_MODE=enforce
    export FAKE_BD_ACCEPTANCE=""
    export FAKE_BD_NOTES=""
    export FAKE_BD_MARKER="$BATS_TEST_TMPDIR/bd-was-called"
    rm -f "$FAKE_BD_MARKER"
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s17\",tool_input:{command:\"bd update beads_claude_docker-smo --priority 1\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    [ ! -f "$FAKE_BD_MARKER" ]
}

# --- beads_claude_docker-4y6: corroborate VERIFIED: PASS against a real -----
# verifier transcript, instead of trusting the note text.
# FROZEN from this bead's RED commit too: cases (n)-(v) must not be edited
# after that commit.
#
# Fixture shape copied from a REAL transcript on this machine
# (~/.claude/projects/-workspace/<session>/subagents/agent-a51ceb8cf23d0e21d.jsonl,
# the verifier run for bead beads_claude_docker-p9r): one `type:"user"` spawn
# -prompt record whose message.content is a plain STRING, then `type:"assistant"`
# records whose message.content is an ARRAY of {type:"text",text:...} blocks,
# every record carrying "agentId". The user record deliberately includes the
# four-verdict listing ("PASS / FAIL / TAMPERED / NO-CONTRACT") that a real
# verifier spawn prompt always contains, so an implementation that greps the
# raw file for "PASS" instead of reading the ASSISTANT's verdict cannot pass
# case (q).

CORROB_ID=a51ceb8cf23d0e21d
PASS_VERDICT=$'Verdict: CONFIRMED\nContract verdict: PASS\n\nLedger\n\n1. C1 CONFIRMED | bd history | acceptance field unchanged'
FAIL_VERDICT=$'Verdict: REFUTED\nContract verdict: FAIL\n\nLedger\n\n1. C3 REFUTED | bats | exit 1, two cases red'

# fake_transcript <store-root> <agentId> <bead-id-named-in-the-prompt> <assistant-verdict-text>
fake_transcript() {
    local dir="$1/-workspace/f3a1c0de-0000-4000-8000-000000000001/subagents"
    mkdir -p "$dir"
    {
        jq -cn --arg a "$2" --arg b "$3" '{
            type:"user", agentId:$a, isSidechain:true, sessionId:"f3a1c0de",
            message:{role:"user", content:("Verify bead " + $b + " at close time. Read the contract with `bd show " + $b + "`, run your five mechanical checks, and return exactly one of the four verdicts: PASS / FAIL / TAMPERED / NO-CONTRACT.")}
        }'
        jq -cn --arg a "$2" --arg v "$4" '{
            type:"assistant", agentId:$a, attributionAgent:"verifier", sessionId:"f3a1c0de",
            message:{role:"assistant", content:[{type:"text", text:$v}]}
        }'
    } > "$dir/agent-$2.jsonl"
}

# (n) a 'VERIFIED: PASS — verifier <agentId>' note whose transcript exists,
# names the bead, and carries a PASS verdict is corroborated: silent allow in
# warn AND in enforce. [PASS-IF clause 2]
@test "(n) corroborated 'VERIFIED: PASS — verifier <id>' allows silently" {
    export CONTRACT_GATE_TRANSCRIPT_ROOT="$BATS_TEST_TMPDIR/store"
    fake_transcript "$CONTRACT_GATE_TRANSCRIPT_ROOT" "$CORROB_ID" beads_claude_docker-4y6 "$PASS_VERDICT"
    export FAKE_BD_ACCEPTANCE=$'CHECK:   bats tests/contract-gate.bats\nPASS-IF: exit 0'
    export FAKE_BD_NOTES="RED-AT: abc123
GREEN-AT: def456
VERIFIED: PASS — verifier $CORROB_ID"

    export CONTRACT_GATE_MODE=warn
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s18\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]

    export CONTRACT_GATE_MODE=enforce
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s19\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

# (o) a BARE 'VERIFIED: PASS' note (no agentId at all) with a discoverable
# transcript store is NOT verified: warn in warn mode, deny in enforce mode,
# and the reason names the missing corroboration. [PASS-IF clause 1]
@test "(o) bare 'VERIFIED: PASS' with a discoverable store is not verified" {
    export CONTRACT_GATE_TRANSCRIPT_ROOT="$BATS_TEST_TMPDIR/store"
    fake_transcript "$CONTRACT_GATE_TRANSCRIPT_ROOT" "$CORROB_ID" beads_claude_docker-4y6 "$PASS_VERDICT"
    export FAKE_BD_ACCEPTANCE=$'CHECK:   bats tests/contract-gate.bats\nPASS-IF: exit 0'
    export FAKE_BD_NOTES=$'RED-AT: abc123\nVERIFIED: PASS all good'

    export CONTRACT_GATE_MODE=warn
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s20\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"beads_claude_docker-4y6"* ]]
    [[ "$stderr" == *"transcript"* ]]
    [[ "$stderr" == *"agentId"* ]]

    export CONTRACT_GATE_MODE=enforce
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s21\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("transcript")'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("agentId")'
}

# (p) a note naming an agentId that has NO transcript in a discoverable store
# is not verified either -- the store is discoverable (another agent's
# transcript is there), the named one simply does not exist. [clause 1]
@test "(p) 'VERIFIED: PASS — verifier <id>' with no such transcript is not verified" {
    export CONTRACT_GATE_TRANSCRIPT_ROOT="$BATS_TEST_TMPDIR/store"
    fake_transcript "$CONTRACT_GATE_TRANSCRIPT_ROOT" "$CORROB_ID" beads_claude_docker-4y6 "$PASS_VERDICT"
    export FAKE_BD_ACCEPTANCE=$'CHECK:   bats tests/contract-gate.bats\nPASS-IF: exit 0'
    export FAKE_BD_NOTES='VERIFIED: PASS — verifier b0b0b0b0b0b0b0b0b'

    export CONTRACT_GATE_MODE=warn
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s22\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"beads_claude_docker-4y6"* ]]
    [[ "$stderr" == *"transcript"* ]]
    [[ "$stderr" == *"b0b0b0b0b0b0b0b0b"* ]]

    export CONTRACT_GATE_MODE=enforce
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s23\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("transcript")'
}

# (q) THE RAW-GREP TRAP: the transcript exists and names the bead, but the
# verifier's own verdict was FAIL -- the only "PASS" in the file is the
# four-verdict listing inside the spawn PROMPT. Corroboration must read the
# ASSISTANT's verdict, so this is not verified. [clause 1]
@test "(q) a FAIL-verdict transcript does not corroborate (prompt lists PASS)" {
    export CONTRACT_GATE_TRANSCRIPT_ROOT="$BATS_TEST_TMPDIR/store"
    fake_transcript "$CONTRACT_GATE_TRANSCRIPT_ROOT" "$CORROB_ID" beads_claude_docker-4y6 "$FAIL_VERDICT"
    # the prompt record really does contain the string "PASS":
    grep -q 'PASS / FAIL / TAMPERED' "$CONTRACT_GATE_TRANSCRIPT_ROOT"/-workspace/*/subagents/agent-$CORROB_ID.jsonl
    export FAKE_BD_ACCEPTANCE=$'CHECK:   bats tests/contract-gate.bats\nPASS-IF: exit 0'
    export FAKE_BD_NOTES="VERIFIED: PASS — verifier $CORROB_ID"

    export CONTRACT_GATE_MODE=warn
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s24\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"transcript"* ]]
    [[ "$stderr" == *"beads_claude_docker-4y6"* ]]

    export CONTRACT_GATE_MODE=enforce
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s25\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

# (r) a PASS-verdict transcript for a DIFFERENT bead does not corroborate this
# bead's close. [clause 1]
@test "(r) a PASS transcript for another bead does not corroborate this one" {
    export CONTRACT_GATE_TRANSCRIPT_ROOT="$BATS_TEST_TMPDIR/store"
    fake_transcript "$CONTRACT_GATE_TRANSCRIPT_ROOT" "$CORROB_ID" beads_claude_docker-p9r "$PASS_VERDICT"
    export FAKE_BD_ACCEPTANCE=$'CHECK:   bats tests/contract-gate.bats\nPASS-IF: exit 0'
    export FAKE_BD_NOTES="VERIFIED: PASS — verifier $CORROB_ID"

    export CONTRACT_GATE_MODE=warn
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s26\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"transcript"* ]]
    [[ "$stderr" == *"beads_claude_docker-4y6"* ]]

    # ... and the same transcript DOES corroborate the bead it actually names.
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s27\",tool_input:{command:\"bd close beads_claude_docker-p9r\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

# (s) FAIL OPEN when the transcript store is not discoverable: a bare
# 'VERIFIED: PASS' note allows silently, in warn AND enforce -- three shapes
# of non-discoverability (root absent, root is a regular file, root has no
# subagents/ dir anywhere). Non-discoverability must never block a close.
# [PASS-IF clause 3]
@test "(s) store absent/unreadable falls back to text-only: bare PASS allows" {
    export FAKE_BD_ACCEPTANCE=$'CHECK:   bats tests/contract-gate.bats\nPASS-IF: exit 0'
    export FAKE_BD_NOTES=$'VERIFIED: PASS all good'

    mkdir -p "$BATS_TEST_TMPDIR/emptystore/-workspace/sess"
    printf 'not a directory\n' > "$BATS_TEST_TMPDIR/filestore"

    for root in "$BATS_TEST_TMPDIR/does-not-exist" "$BATS_TEST_TMPDIR/filestore" "$BATS_TEST_TMPDIR/emptystore"; do
        export CONTRACT_GATE_TRANSCRIPT_ROOT="$root"
        for mode in warn enforce; do
            export CONTRACT_GATE_MODE="$mode"
            run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s28\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
            [ "$status" -eq 0 ]
            [ -z "$output" ]
            [ -z "$stderr" ]
        done
    done
}

# (t) the DEFAULT store root is ~/.claude/projects: with no env override and a
# store built under $HOME, corroboration works, and a bare note under that
# same discoverable store warns. [clauses 1+2]
@test "(t) default store root is ~/.claude/projects (no env override)" {
    fake_transcript "$HOME/.claude/projects" "$CORROB_ID" beads_claude_docker-4y6 "$PASS_VERDICT"
    export FAKE_BD_ACCEPTANCE=$'CHECK:   bats tests/contract-gate.bats\nPASS-IF: exit 0'
    export CONTRACT_GATE_MODE=warn

    export FAKE_BD_NOTES="VERIFIED: PASS — verifier $CORROB_ID"
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s29\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]

    export FAKE_BD_NOTES=$'VERIFIED: PASS all good'
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s30\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"transcript"* ]]
}

# (u) every pre-existing fail-open path still exits 0 SILENTLY, even with a
# discoverable store and an uncorroborated note: bd non-zero, bd emitting
# unparseable JSON, and bd hanging past the subprocess timeout. (Unparseable
# stdin and a missing bd are cases (g)/(h).) [PASS-IF clause 4]
@test "(u) bd non-zero / bad JSON / timeout still fail open silently" {
    export CONTRACT_GATE_TRANSCRIPT_ROOT="$BATS_TEST_TMPDIR/store"
    fake_transcript "$CONTRACT_GATE_TRANSCRIPT_ROOT" "$CORROB_ID" beads_claude_docker-4y6 "$PASS_VERDICT"
    export CONTRACT_GATE_MODE=enforce

    printf '#!/bin/sh\nexit 3\n' > "$FAKE_BD_DIR/bd"; chmod +x "$FAKE_BD_DIR/bd"
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s31\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]

    printf '#!/bin/sh\nprintf "{{{ not json"\n' > "$FAKE_BD_DIR/bd"; chmod +x "$FAKE_BD_DIR/bd"
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s32\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]

    printf '#!/bin/sh\nsleep 30\n' > "$FAKE_BD_DIR/bd"; chmod +x "$FAKE_BD_DIR/bd"
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s33\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

# (v) an unrecognized mode still exits 0, and (per case (i)) still behaves as
# warn rather than off: a corroborated bead under a discoverable store is
# silent. [PASS-IF clause 4]
@test "(v) unrecognized mode + corroborated transcript: exit 0, silent" {
    export CONTRACT_GATE_MODE=bogus-typo
    export CONTRACT_GATE_TRANSCRIPT_ROOT="$BATS_TEST_TMPDIR/store"
    fake_transcript "$CONTRACT_GATE_TRANSCRIPT_ROOT" "$CORROB_ID" beads_claude_docker-4y6 "$PASS_VERDICT"
    export FAKE_BD_ACCEPTANCE=$'CHECK:   bats tests/contract-gate.bats\nPASS-IF: exit 0'
    export FAKE_BD_NOTES="VERIFIED: PASS — verifier $CORROB_ID"
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s34\",tool_input:{command:\"bd close beads_claude_docker-4y6\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

# --- beads_claude_docker-bh6: BRANCH A -- resolve the bare close's target ----
# via `bd show --current --json` and check THAT bead, instead of only asking
# for an explicit id.
# FROZEN from this bead's RED commit too: cases (w)-(z) must not be edited
# after that commit.
#
# The probe recorded in bh6's notes (bd 1.0.4) established the semantics this
# branch rests on: bd keeps the pointer in `.beads/last-touched`; create,
# update, show and close all move it identically; `bd show --current --json`
# returns exactly that bead (it does NOT out-vote the pointer with an
# unrelated in_progress bead, and with the pointer gone it errors exactly
# where a bare close errors); reading --current does not move the pointer;
# and a bare `bd close` was observed closing precisely the bead --current had
# just named, on the throwaway DB and again on the real tracker.
#
# The success shape is a one-element JSON list whose empty fields are OMITTED
# (no acceptance_criteria/notes keys), so the stubs below answer --current
# with id/title/status only: the gate must resolve the id and then run its
# ordinary `bd show <id> --json` to read the contract.

RESOLVED_ID=beads_probe-lasttouched

# stage_current_stub <json-array-for---current>
# A bd whose `show --current --json` answers with the given array, whose
# `show <id> --json` answers from FAKE_BD_ACCEPTANCE/FAKE_BD_NOTES like
# setup()'s, and which logs every invocation to $FAKE_BD_LOG.
stage_current_stub() {
    export FAKE_BD_LOG="$BATS_TEST_TMPDIR/bd-invocations"
    : > "$FAKE_BD_LOG"
    export FAKE_BD_CURRENT_JSON="$1"
    cat > "$FAKE_BD_DIR/bd" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_BD_LOG"
case " $* " in
    *" --current "*)
        [ -n "$FAKE_BD_CURRENT_EXIT" ] && { printf '%s' "$FAKE_BD_CURRENT_JSON"; exit "$FAKE_BD_CURRENT_EXIT"; }
        printf '%s' "$FAKE_BD_CURRENT_JSON"
        exit 0 ;;
esac
if [ "$1" = "show" ]; then
    jq -cn --arg id "$2" --arg acc "${FAKE_BD_ACCEPTANCE:-}" --arg notes "${FAKE_BD_NOTES:-}" \
        '[{id:$id, acceptance_criteria:$acc, notes:$notes}]'
    exit 0
fi
exit 1
EOF
    chmod +x "$FAKE_BD_DIR/bd"
}

# (w) a bare `bd close` / `bd done` whose --current names an UNCONTRACTED bead
# is checked against THAT bead: warn mode warns naming it, enforce mode denies
# naming it -- and neither falls back to the old "explicit bead id" ask.
# The gate must also stay read-only: it may only ever run `bd show`.
# [BRANCH A, clause 1]
@test "(w) bare close resolves --current and checks that bead (contract, no PASS)" {
    stage_current_stub "[{\"id\":\"$RESOLVED_ID\",\"title\":\"the last touched bead\",\"status\":\"open\"}]"
    export FAKE_BD_ACCEPTANCE=$'CHECK:   x\nPASS-IF: y'
    export FAKE_BD_NOTES=""

    export CONTRACT_GATE_MODE=warn
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s35\",tool_input:{command:\"bd close\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"$RESOLVED_ID"* ]]
    [[ "$stderr" == *"acceptance contract"* ]]
    [[ "$stderr" != *"explicit bead id"* ]]

    # the bare alias, and a bare close carrying only a reason, resolve too
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s36\",tool_input:{command:\"bd done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"$RESOLVED_ID"* ]]
    [[ "$stderr" != *"explicit bead id"* ]]

    export CONTRACT_GATE_MODE=enforce
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s37\",tool_input:{command:\"bd close --reason wrapped-up\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
    echo "$output" | jq -e --arg id "$RESOLVED_ID" '.hookSpecificOutput.permissionDecisionReason | test($id)'
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("explicit bead id") | not'

    # read-only: --current was consulted, and no close/done/update was ever run
    grep -q -- '--current' "$FAKE_BD_LOG"
    ! grep -qE '^(close|done|update)\b' "$FAKE_BD_LOG"
}

# (x) a bare close whose --current names a bead WITH a contract and a
# corroborated PASS note is allowed silently, in warn and in enforce.
# [BRANCH A, clause 2]
@test "(x) bare close resolving to a contracted+corroborated bead is silent" {
    export CONTRACT_GATE_TRANSCRIPT_ROOT="$BATS_TEST_TMPDIR/store"
    fake_transcript "$CONTRACT_GATE_TRANSCRIPT_ROOT" "$CORROB_ID" "$RESOLVED_ID" "$PASS_VERDICT"
    stage_current_stub "[{\"id\":\"$RESOLVED_ID\",\"title\":\"the last touched bead\",\"status\":\"open\"}]"
    export FAKE_BD_ACCEPTANCE=$'CHECK:   bats tests/contract-gate.bats\nPASS-IF: exit 0'
    export FAKE_BD_NOTES="RED-AT: abc123
GREEN-AT: def456
VERIFIED: PASS — verifier $CORROB_ID"

    for mode in warn enforce; do
        export CONTRACT_GATE_MODE="$mode"
        run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s38\",tool_input:{command:\"bd close\"}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
        [ -z "$stderr" ]
    done
}

# (y) every way --current can fail to name a bead falls back to the EXISTING
# conservative branch (warn / deny asking for an explicit bead id) -- never a
# silent allow, and never a check of a phantom bead. Five shapes:
#   1. non-zero exit with bd's own error JSON (no pointer / pointer names a
#      deleted bead -- both observed in the probe)
#   2. --current unsupported by an older bd (unknown flag, non-zero)
#   3. an empty result list
#   4. a result whose id is empty
#   5. THE NAIVE-BD TRAP: a bd that ignores --current and echoes it straight
#      back as the id. A flag-shaped id is never a bead id, so it must not be
#      believed (this is also what keeps frozen cases (k)/(k2), whose stub
#      answers `show --current` with id "--current", passing unchanged).
# [BRANCH A, clause 3]
@test "(y) --current failing/unsupported/empty falls back to the conservative branch" {
    export FAKE_BD_ACCEPTANCE=""
    export FAKE_BD_NOTES=""

    check_conservative() {
        export CONTRACT_GATE_MODE=warn
        run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s39\",tool_input:{command:\"bd close\"}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
        [[ "$stderr" == *"explicit bead id"* ]]

        export CONTRACT_GATE_MODE=enforce
        run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s40\",tool_input:{command:\"bd close\"}}" | python3 '"$GATE"
        [ "$status" -eq 0 ]
        echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
        echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("explicit bead id")'
    }

    # 1. non-zero + bd's real error JSON
    stage_current_stub '{"error": "no current issue found (no in-progress, hooked, or recently touched issues)", "schema_version": 1}'
    export FAKE_BD_CURRENT_EXIT=1
    check_conservative

    # 2. an older bd that does not know the flag at all
    unset FAKE_BD_CURRENT_EXIT
    cat > "$FAKE_BD_DIR/bd" <<'EOF'
#!/bin/sh
case " $* " in
    *" --current "*) echo 'Error: unknown flag: --current' >&2; exit 1 ;;
esac
exit 1
EOF
    chmod +x "$FAKE_BD_DIR/bd"
    check_conservative

    # 3. an empty result list
    stage_current_stub '[]'
    check_conservative

    # 4. a result with an empty id
    stage_current_stub '[{"id":"","title":"","status":"open"}]'
    check_conservative

    # 5. a bd that echoes the flag back as the id
    stage_current_stub '[{"id":"--current","title":"","status":"open"}]'
    check_conservative
}

# (y2) bd missing from PATH entirely on a BARE close also falls back to the
# conservative ask rather than allowing. This is not a weakening of case (h):
# (h) is a close of a NAMED bead, where a broken bd has always meant "fail
# open, silent", and it still does. A bare close is the case where the gate
# cannot even learn which bead is at stake, and Branch A's contract says an
# unresolvable --current keeps the conservative branch "rather than allowing".
@test "(y2) bd missing on a bare close keeps the conservative ask" {
    export PATH="/usr/bin:/bin"
    export CONTRACT_GATE_MODE=warn
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s41\",tool_input:{command:\"bd close\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"explicit bead id"* ]]
}

# (z) mode=off still makes NO bd call at all on a bare close: resolving
# --current must happen after the mode check, not before it.
@test "(z) mode=off on a bare close invokes bd not at all" {
    export CONTRACT_GATE_MODE=off
    export FAKE_BD_MARKER="$BATS_TEST_TMPDIR/bd-was-called"
    rm -f "$FAKE_BD_MARKER"
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s42\",tool_input:{command:\"bd close\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    [ ! -f "$FAKE_BD_MARKER" ]
}

# --- beads_claude_docker-mcuw: contract-gate is lane-aware -------------------
# The gate's whole premise (register a CHECK/PASS-IF contract, corroborate
# VERIFIED: PASS) is a DEEP-lane concept; express/standard lanes explicitly
# carry no contract per the rulebook (~/.claude/CLAUDE.md § Lanes). When the
# session's lane state file (LANE_STATE_DIR, same file+shape scripts/lane.sh
# writes: <dir>/<session_id>.json, key "lane") says express or standard, the
# gate is silent -- not merely warn-suppressed but skipped before it ever
# shells out to bd, proven via the marker file exactly like cases (f)/(m2).
# Deep and "no state" (lane unresolved) keep today's behaviour unchanged.
# These cases are ADDED by beads_claude_docker-mcuw; cases (a)-(z) above are
# untouched.

# lane_state <lane-word> <session-id>: writes a lane.sh-shaped state file.
lane_state() {
    local dir="$BATS_TEST_TMPDIR/lane-state"
    mkdir -p "$dir"
    export LANE_STATE_DIR="$dir"
    jq -cn --arg lane "$1" '{lane:$lane, prev:"unset", why:"", ts:0, escalated:false}' \
        > "$dir/$2.json"
}

@test "(aa) lane=standard suppresses the missing-contract nudge entirely (warn mode, bd never invoked)" {
    lane_state standard s-lane-aa
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_ACCEPTANCE=""
    export FAKE_BD_NOTES=""
    export FAKE_BD_MARKER="$BATS_TEST_TMPDIR/bd-was-called"
    rm -f "$FAKE_BD_MARKER"
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s-lane-aa\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    [ ! -f "$FAKE_BD_MARKER" ]
}

@test "(ab) lane=express suppresses the missing-contract nudge entirely (warn mode, bd never invoked)" {
    lane_state express s-lane-ab
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_ACCEPTANCE=""
    export FAKE_BD_NOTES=""
    export FAKE_BD_MARKER="$BATS_TEST_TMPDIR/bd-was-called"
    rm -f "$FAKE_BD_MARKER"
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s-lane-ab\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    [ ! -f "$FAKE_BD_MARKER" ]
}

@test "(ac) lane=standard suppresses even in enforce mode -- allow, not deny" {
    lane_state standard s-lane-ac
    export CONTRACT_GATE_MODE=enforce
    export FAKE_BD_ACCEPTANCE=""
    export FAKE_BD_NOTES=""
    export FAKE_BD_MARKER="$BATS_TEST_TMPDIR/bd-was-called"
    rm -f "$FAKE_BD_MARKER"
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s-lane-ac\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    [ ! -f "$FAKE_BD_MARKER" ]
}

@test "(ad) lane=deep keeps today's behaviour -- the existing warn text still fires" {
    lane_state deep s-lane-ad
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_ACCEPTANCE=$'CHECK:   x\nPASS-IF: y'
    export FAKE_BD_NOTES=""
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s-lane-ad\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"acceptance contract"* ]]
    [[ "$stderr" == *"beads_claude_docker-smo"* ]]
}

@test "(ae) no lane state file at all keeps today's behaviour -- the existing warn text still fires" {
    export LANE_STATE_DIR="$BATS_TEST_TMPDIR/lane-state-empty"
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_ACCEPTANCE=$'CHECK:   x\nPASS-IF: y'
    export FAKE_BD_NOTES=""
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s-lane-ae\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"acceptance contract"* ]]
}

@test "(af) lane state file present but lane field is literally 'unset' keeps today's behaviour" {
    lane_state unset s-lane-af
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_ACCEPTANCE=$'CHECK:   x\nPASS-IF: y'
    export FAKE_BD_NOTES=""
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s-lane-af\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"acceptance contract"* ]]
}

@test "(ag) a malformed lane state file fails open to today's behaviour, not a crash" {
    dir="$BATS_TEST_TMPDIR/lane-state"
    mkdir -p "$dir"
    export LANE_STATE_DIR="$dir"
    printf 'not json at all' > "$dir/s-lane-ag.json"
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_ACCEPTANCE=$'CHECK:   x\nPASS-IF: y'
    export FAKE_BD_NOTES=""
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s-lane-ag\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"acceptance contract"* ]]
}

@test "(ah) a hook payload with no session_id keeps today's behaviour (lane cannot be resolved)" {
    lane_state standard no-session-id-cannot-match
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_ACCEPTANCE=$'CHECK:   x\nPASS-IF: y'
    export FAKE_BD_NOTES=""
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"acceptance contract"* ]]
}

@test "(ai) lane=standard also suppresses a bare 'bd close' -- never resolves --current, never touches bd" {
    lane_state standard s-lane-ai
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_MARKER="$BATS_TEST_TMPDIR/bd-was-called"
    rm -f "$FAKE_BD_MARKER"
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s-lane-ai\",tool_input:{command:\"bd close\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    [ ! -f "$FAKE_BD_MARKER" ]
}
