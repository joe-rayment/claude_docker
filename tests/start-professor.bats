#!/usr/bin/env bats
bats_require_minimum_version 1.5.0   # `run -127` (exact-status assertion)
# start-professor.bats — coverage for scripts/start-professor.sh (the
# `menu` shortcut that execs the professor agent), plus a wiring regression
# check: run-tests.sh's `all` lane must invoke every tests/*.bats suite,
# derived from the glob at test runtime so this stays true as suites are
# added later without anyone remembering to update this file.
# (beads_claude_docker-o1w, successor of beads_claude_docker-d49.)

START_PROFESSOR=/workspace/scripts/start-professor.sh
RUN_TESTS=/workspace/run-tests.sh
TESTS_DIR=/workspace/tests

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$FAKEBIN"
    CLAUDE_LOG="$BATS_TEST_TMPDIR/fake-claude.log"
    # PATH-shim fake `claude` per knowledge-base/GUARD_VERIFICATION.md: logs
    # its own argv/cwd/env rather than launching the real interactive CLI.
    cat > "$FAKEBIN/claude" <<EOF
#!/usr/bin/env bash
{
  echo "ARGV: \$*"
  echo "PWD: \$PWD"
  echo "CLAUDECODE: \${CLAUDECODE-<unset>}"
} >> "$CLAUDE_LOG"
EOF
    chmod +x "$FAKEBIN/claude"
}

# ── start-professor.sh behavior ─────────────────────────────────────────────

@test "start-professor: execs claude with --agent professor --dangerously-skip-permissions" {
    PATH="$FAKEBIN:$PATH" bash "$START_PROFESSOR"
    [ -f "$CLAUDE_LOG" ]
    grep -q -- "ARGV: --agent professor --dangerously-skip-permissions" "$CLAUDE_LOG"
}

@test "start-professor: unsets CLAUDECODE before exec even when set in the caller's environment" {
    CLAUDECODE=1 PATH="$FAKEBIN:$PATH" bash "$START_PROFESSOR"
    grep -q "CLAUDECODE: <unset>" "$CLAUDE_LOG"
}

@test "start-professor: cds to /workspace before exec" {
    PATH="$FAKEBIN:$PATH" bash "$START_PROFESSOR"
    grep -q "PWD: /workspace" "$CLAUDE_LOG"
}

@test "start-professor: a missing claude binary fails loudly (exit 127), not silently" {
    EMPTYBIN="$BATS_TEST_TMPDIR/emptybin"
    mkdir -p "$EMPTYBIN"
    BASHBIN=$(command -v bash)
    run -127 env PATH="$EMPTYBIN" "$BASHBIN" "$START_PROFESSOR"
    [ "$status" -eq 127 ]
}

# ── wiring: run-tests.sh all lane vs. the real tests/*.bats glob ───────────

@test "run-tests.sh: the all lane names every tests/*.bats suite (glob-derived)" {
    local block
    block=$(awk '/^[[:space:]]*all\)/,/;;/' "$RUN_TESTS")
    local missing=""
    for f in "$TESTS_DIR"/*.bats; do
        base=$(basename "$f")
        [[ "$block" == *"$base"* ]] || missing="$missing $base"
    done
    echo "missing from run-tests.sh all lane:$missing"
    [ -z "$missing" ]
}
