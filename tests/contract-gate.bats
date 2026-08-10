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
