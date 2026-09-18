#!/usr/bin/env bats
bats_require_minimum_version 1.5.0   # `run -127` (exact-status assertion)
# start-professor.bats — coverage for scripts/start-professor.sh, the
# shortcut that execs the professor agent.
#
# S7 port (claude-orca-3sk.7): drops the run-tests.sh "all lane names
# every suite" drift guard -- this repo's run-tests.sh has no per-lane
# suite list to drift (it globs tests/*.bats directly, so there is
# nothing to keep in sync). The "cds to /workspace" case is replaced with
# two cases matching the new claude_orca_root()-based cd (lib/paths.sh):
# it cds there when resolvable, and silently stays put otherwise --
# never a hardcoded absolute path.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
START_PROFESSOR="$REPO_ROOT/scripts/start-professor.sh"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$FAKEBIN"
    CLAUDE_LOG="$BATS_TEST_TMPDIR/fake-claude.log"
    # PATH-shim fake `claude`: logs its own argv/cwd/env rather than
    # launching the real interactive CLI.
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

@test "start-professor: cds to CLAUDE_ORCA_ROOT when resolvable" {
    proj="$BATS_TEST_TMPDIR/project"
    mkdir -p "$proj"
    CLAUDE_ORCA_ROOT="$proj" PATH="$FAKEBIN:$PATH" bash "$START_PROFESSOR"
    grep -q "PWD: $proj" "$CLAUDE_LOG"
}

@test "start-professor: stays in the caller's cwd when the project root is not resolvable" {
    # The cwd decides this case, so it must not be left to chance: from the
    # suite working dir the walk-up can find a bootstrapped project (this
    # dev container's repo IS one -- a worktree's git-common-dir points at
    # the primary checkout, which has .claude-dev/claude-orca.json), and
    # there the script is right to cd. Run from a scratch dir no walk-up
    # can resolve instead -- outside every git checkout and bootstrapped
    # project on any machine.
    scratch="$BATS_TEST_TMPDIR/unresolvable-cwd"
    mkdir -p "$scratch"
    cd "$scratch"
    here="$PWD"
    env -u CLAUDE_ORCA_ROOT PATH="$FAKEBIN:$PATH" bash "$START_PROFESSOR"
    grep -q "PWD: $here" "$CLAUDE_LOG"
}

@test "start-professor: a missing claude binary fails loudly (exit 127), not silently" {
    EMPTYBIN="$BATS_TEST_TMPDIR/emptybin"
    mkdir -p "$EMPTYBIN"
    BASHBIN=$(command -v bash)
    run -127 env PATH="$EMPTYBIN" "$BASHBIN" "$START_PROFESSOR"
    [ "$status" -eq 127 ]
}
