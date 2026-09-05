#!/usr/bin/env bats
# agent-report-relay.bats — named/teammate agent spawns (mailbox mode) go
# idle without their final text reaching the orchestrator. Every agent
# definition must instruct the agent to SendMessage its full report to
# "main" as its last action when it was spawned with a name, and the
# spawn-naming paragraph in the rulebook must say so too.
# Regression coverage for beads_claude_docker-7cr.
#
# S7 port (claude-orca-3sk.7) drops the "deployed ~/.claude/agents/*.md"
# and "deployed ~/.claude/CLAUDE.md" cases: there is no fixed deployed
# location any more (config-sync.sh mirrors config/ into each project's
# own .claude-dev/home/.claude/ -- see tests/config-sync.bats, FROZEN),
# so "the repo template" and "the deployed copy" are no longer two things
# to check separately for a byte-identical mirror. The rulebook phrase
# check is reworded to this repo's actual wording ("deliver by
# SendMessage to \"main\"", not the old "deliver by mailbox").

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

# ── per-agent: repo template carries the report-delivery instruction ───────

@test "agent-report-relay: config/agents/scout.md carries report-delivery instruction" {
    grep -q "Report delivery" "$REPO_ROOT/config/agents/scout.md"
    grep -q 'to: "main"' "$REPO_ROOT/config/agents/scout.md"
}

@test "agent-report-relay: config/agents/executor.md carries report-delivery instruction" {
    grep -q "Report delivery" "$REPO_ROOT/config/agents/executor.md"
    grep -q 'to: "main"' "$REPO_ROOT/config/agents/executor.md"
}

@test "agent-report-relay: config/agents/verifier.md carries report-delivery instruction" {
    grep -q "Report delivery" "$REPO_ROOT/config/agents/verifier.md"
    grep -q 'to: "main"' "$REPO_ROOT/config/agents/verifier.md"
}

@test "agent-report-relay: config/agents/oracle.md carries report-delivery instruction" {
    grep -q "Report delivery" "$REPO_ROOT/config/agents/oracle.md"
    grep -q 'to: "main"' "$REPO_ROOT/config/agents/oracle.md"
}

@test "agent-report-relay: config/agents/professor.md carries report-delivery instruction" {
    grep -q "Report delivery" "$REPO_ROOT/config/agents/professor.md"
    grep -q 'to: "main"' "$REPO_ROOT/config/agents/professor.md"
}

@test "agent-report-relay: config/agents/bead-auditor.md carries report-delivery instruction" {
    grep -q "Report delivery" "$REPO_ROOT/config/agents/bead-auditor.md"
    grep -q 'to: "main"' "$REPO_ROOT/config/agents/bead-auditor.md"
}

# ── protocol text: naming paragraph carries the mailbox-delivery sentence ──

@test "agent-report-relay: config/claude-user-memory.md naming paragraph carries the deliver-to-main sentence" {
    grep -q 'named spawns deliver by SendMessage to "main"' "$REPO_ROOT/config/claude-user-memory.md"
}
