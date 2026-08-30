#!/usr/bin/env bats
# agent-report-relay.bats — named/teammate agent spawns (mailbox mode) go
# idle without their final text reaching the orchestrator. Every agent
# definition must instruct the agent to SendMessage its full report to
# "main" as its last action when it was spawned with a name, and the
# spawn-naming paragraph in the delegation protocol must say so too.
# Regression coverage for beads_claude_docker-7cr.

AGENTS="scout executor verifier oracle professor bead-auditor"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

# ── per-agent: repo template carries the report-delivery instruction ───────

@test "agent-report-relay: config/agents/scout.md carries report-delivery instruction" {
    grep -q "Report delivery" /workspace/config/agents/scout.md
    grep -q 'to: "main"' /workspace/config/agents/scout.md
}

@test "agent-report-relay: config/agents/executor.md carries report-delivery instruction" {
    grep -q "Report delivery" /workspace/config/agents/executor.md
    grep -q 'to: "main"' /workspace/config/agents/executor.md
}

@test "agent-report-relay: config/agents/verifier.md carries report-delivery instruction" {
    grep -q "Report delivery" /workspace/config/agents/verifier.md
    grep -q 'to: "main"' /workspace/config/agents/verifier.md
}

@test "agent-report-relay: config/agents/oracle.md carries report-delivery instruction" {
    grep -q "Report delivery" /workspace/config/agents/oracle.md
    grep -q 'to: "main"' /workspace/config/agents/oracle.md
}

@test "agent-report-relay: config/agents/professor.md carries report-delivery instruction" {
    grep -q "Report delivery" /workspace/config/agents/professor.md
    grep -q 'to: "main"' /workspace/config/agents/professor.md
}

@test "agent-report-relay: config/agents/bead-auditor.md carries report-delivery instruction" {
    grep -q "Report delivery" /workspace/config/agents/bead-auditor.md
    grep -q 'to: "main"' /workspace/config/agents/bead-auditor.md
}

# ── per-agent: deployed copy carries the same instruction ──────────────────

@test "agent-report-relay: deployed ~/.claude/agents/scout.md carries report-delivery instruction" {
    grep -q "Report delivery" /home/agent/.claude/agents/scout.md
    grep -q 'to: "main"' /home/agent/.claude/agents/scout.md
}

@test "agent-report-relay: deployed ~/.claude/agents/executor.md carries report-delivery instruction" {
    grep -q "Report delivery" /home/agent/.claude/agents/executor.md
    grep -q 'to: "main"' /home/agent/.claude/agents/executor.md
}

@test "agent-report-relay: deployed ~/.claude/agents/verifier.md carries report-delivery instruction" {
    grep -q "Report delivery" /home/agent/.claude/agents/verifier.md
    grep -q 'to: "main"' /home/agent/.claude/agents/verifier.md
}

@test "agent-report-relay: deployed ~/.claude/agents/oracle.md carries report-delivery instruction" {
    grep -q "Report delivery" /home/agent/.claude/agents/oracle.md
    grep -q 'to: "main"' /home/agent/.claude/agents/oracle.md
}

@test "agent-report-relay: deployed ~/.claude/agents/professor.md carries report-delivery instruction" {
    grep -q "Report delivery" /home/agent/.claude/agents/professor.md
    grep -q 'to: "main"' /home/agent/.claude/agents/professor.md
}

@test "agent-report-relay: deployed ~/.claude/agents/bead-auditor.md carries report-delivery instruction" {
    grep -q "Report delivery" /home/agent/.claude/agents/bead-auditor.md
    grep -q 'to: "main"' /home/agent/.claude/agents/bead-auditor.md
}

# ── protocol text: naming paragraph carries the mailbox-delivery sentence ──

@test "agent-report-relay: config/claude-user-memory.md naming paragraph carries mailbox-delivery sentence" {
    grep -q "Named spawns deliver by mailbox" /workspace/config/claude-user-memory.md
}

@test "agent-report-relay: deployed ~/.claude/CLAUDE.md naming paragraph carries mailbox-delivery sentence" {
    grep -q "Named spawns deliver by mailbox" /home/agent/.claude/CLAUDE.md
}
