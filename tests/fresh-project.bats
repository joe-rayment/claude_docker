#!/usr/bin/env bats

# fresh-project.bats — beads_claude_docker-b56o (B6 of the "one rulebook"
# plan, no longer in the repo): scripts/rules-effective.sh
# is the integration probe for the whole plan — it prints what a FRESH,
# user-shaped project actually loads (config/claude-user-memory.md, the
# file that ships, plus every SessionStart hook's stdout, run against a
# throwaway project), so a rule that only landed in this repo's own
# CLAUDE.md (never shipped) shows up here as a missing string, not a guess.
#
# S7 port (claude-orca-3sk.7) drops two cases: this repo's own CLAUDE.md
# pointing editors at config/claude-user-memory.md (this repo's CLAUDE.md
# is a beads-workflow doc with its own, independently-authored structure
# and carries no such sentence) and the BEADS INTEGRATION block strip
# (scripts/rules-effective.sh no longer runs entrypoint.sh's
# normalize_beads_integration_block -- entrypoint.sh has no equivalent
# here, see .claude/plans/orca-port.md S3.2 -- so a pre-existing project
# CLAUDE.md's own BEADS INTEGRATION block reaches the probe's output
# unstripped; that is a real, disclosed scope change, not a bug).

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

PROBE="$REPO_ROOT/scripts/rules-effective.sh"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

@test "fresh-project: scripts/rules-effective.sh exits 0 against a temp empty project" {
    run "$PROBE"
    [ "$status" -eq 0 ]
}

@test "fresh-project: output contains the shipped rulebook's Sandbox, Push, and Lanes headings plus the lane declaration" {
    run "$PROBE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"## Sandbox vs. your systems"* ]]
    [[ "$output" == *"## Push and deploy"* ]]
    [[ "$output" == *"## Lanes"* ]]
    [[ "$output" == *"lane express|standard|deep"* ]]
}
