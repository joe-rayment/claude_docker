#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# contract-gate.bats — PreToolUse(Bash) hook that warns (or, in enforce mode,
# denies) a `bd close` run against a bead that has no acceptance contract or
# no recorded `VERIFIED: PASS` note. Modelled on tests/delegation-gate.bats.
#
# FROZEN per beads_claude_docker-smo's acceptance contract: this file must
# not be edited after its RED commit. If a test here turns out to be wrong,
# stop and report — do not edit it.
#
# A fake `bd` binary is staged ahead of the real one on PATH for every test
# except (h), which deliberately excludes it to prove the fail-open path.
# The fake `bd show <id> --json` responds with acceptance_criteria/notes
# taken from $FAKE_BD_ACCEPTANCE/$FAKE_BD_NOTES, and (for case f/the
# "ignored entirely" check) touches $FAKE_BD_MARKER whenever it is invoked
# at all, so a test can prove the gate never shelled out to bd.

GATE=/workspace/scripts/contract-gate.py

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

# (b) mode=warn on a bead with no contract prints a warning to stderr and exits 0.
@test "(b) mode=warn, no contract: warns on stderr, exits 0" {
    export CONTRACT_GATE_MODE=warn
    export FAKE_BD_ACCEPTANCE=""
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

# (d) mode=enforce with no contract emits hookSpecificOutput.permissionDecision == deny.
@test "(d) mode=enforce, no contract: emits a deny decision" {
    export CONTRACT_GATE_MODE=enforce
    export FAKE_BD_ACCEPTANCE=""
    export FAKE_BD_NOTES=""
    run --separate-stderr sh -c 'jq -cn "{tool_name:\"Bash\",session_id:\"s4\",tool_input:{command:\"bd close beads_claude_docker-smo --reason done\"}}" | python3 '"$GATE"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
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
    export FAKE_BD_ACCEPTANCE=""
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
    export FAKE_BD_ACCEPTANCE=""
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
        *)      acc=''
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
    export FAKE_BD_ACCEPTANCE=""
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
