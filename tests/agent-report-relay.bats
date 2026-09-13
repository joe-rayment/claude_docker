#!/usr/bin/env bats
# agent-report-relay.bats — how a subagent's report reaches its caller.
#
# Spawns are UNNAMED now (Sept 2026): the final message text of an unnamed
# spawn comes back as the task result, so the old mailbox relay — "if you
# were spawned with a name, SendMessage your report to main" — is gone from
# every agent definition and from the rulebook's spawn paragraph. A named
# spawn arrives as a wrapped teammate notice and wakes the orchestrator for
# nothing, so the instruction is now the opposite one and these tests lock
# that in: no agent definition may tell a worker to message "main", and the
# rulebook must say spawns are unnamed.
# (Was regression coverage for beads_claude_docker-7cr, whose mailbox relay
# this replaces.)

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

# ── per-agent: no definition tells a worker to message "main" ──────────────

@test "agent-report-relay: config/agents/scout.md carries report-delivery instruction and no mailbox relay" {
    grep -q "Report delivery" "$REPO_ROOT/config/agents/scout.md"
    ! grep -q 'to: "main"' "$REPO_ROOT/config/agents/scout.md"
}

@test "agent-report-relay: config/agents/executor.md carries report-delivery instruction and no mailbox relay" {
    grep -q "Report delivery" "$REPO_ROOT/config/agents/executor.md"
    ! grep -q 'to: "main"' "$REPO_ROOT/config/agents/executor.md"
}

@test "agent-report-relay: config/agents/verifier.md carries report-delivery instruction and no mailbox relay" {
    grep -q "Report delivery" "$REPO_ROOT/config/agents/verifier.md"
    ! grep -q 'to: "main"' "$REPO_ROOT/config/agents/verifier.md"
}

@test "agent-report-relay: config/agents/oracle.md carries report-delivery instruction and no mailbox relay" {
    grep -q "Report delivery" "$REPO_ROOT/config/agents/oracle.md"
    ! grep -q 'to: "main"' "$REPO_ROOT/config/agents/oracle.md"
}

@test "agent-report-relay: config/agents/professor.md carries report-delivery instruction and no mailbox relay" {
    grep -q "Report delivery" "$REPO_ROOT/config/agents/professor.md"
    ! grep -q 'to: "main"' "$REPO_ROOT/config/agents/professor.md"
}

@test "agent-report-relay: config/agents/bead-auditor.md carries report-delivery instruction and no mailbox relay" {
    grep -q "Report delivery" "$REPO_ROOT/config/agents/bead-auditor.md"
    ! grep -q 'to: "main"' "$REPO_ROOT/config/agents/bead-auditor.md"
}

@test "agent-report-relay: no agent definition tells the worker to SendMessage its report" {
    ! grep -rn 'SendMessage with' "$REPO_ROOT/config/agents/"
}

# ── protocol text: the spawn paragraph says spawns are unnamed ─────────────

@test "agent-report-relay: config/claude-user-memory.md says spawns are unnamed and names no mailbox delivery" {
    grep -q 'Spawns are unnamed' "$REPO_ROOT/config/claude-user-memory.md"
    ! grep -q 'named spawns deliver by SendMessage' "$REPO_ROOT/config/claude-user-memory.md"
}
