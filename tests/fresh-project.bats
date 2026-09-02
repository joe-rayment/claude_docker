#!/usr/bin/env bats

# fresh-project.bats — beads_claude_docker-b56o (B6 of the "one rulebook"
# plan, .claude/plans/instruction-surface-fix.md): scripts/rules-effective.sh
# is the integration probe for the whole plan — it prints what a FRESH,
# user-shaped project actually loads (config/claude-user-memory.md, the
# file that ships, plus every SessionStart hook's stdout, run against a
# throwaway project prepared the way scripts/entrypoint.sh prepares one),
# so a rule that only landed in this repo's own CLAUDE.md (never shipped)
# shows up here as a missing string, not a guess.
#
# FROZEN per beads_claude_docker-b56o's acceptance contract: this file must
# not be edited after its RED-AT commit. If a case here turns out wrong,
# stop and report — do not edit it.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

PROBE="$REPO_ROOT/scripts/rules-effective.sh"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

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

@test "fresh-project: output does not contain any of bd's push-mandatory / bead-before-code boilerplate" {
    run "$PROBE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"NEVER skip"* ]]
    [[ "$output" != *"BEFORE writing code"* ]]
    [[ "$output" != *"Write tests for"* ]]
    [[ "$output" != *"overrides, by name"* ]]
    [[ "$output" != *'run `git push`'* ]]
    [[ "$output" != *"PUSH TO REMOTE"* ]]
    [[ "$output" != *"Work is NOT complete until"* ]]
}

@test "fresh-project: output is at most 12000 bytes" {
    run "$PROBE"
    [ "$status" -eq 0 ]
    local size
    size=$(printf '%s' "$output" | wc -c)
    [ "$size" -le 12000 ]
}

@test "fresh-project: this repo's own CLAUDE.md points editors at config/claude-user-memory.md" {
    run grep -F "Behaviour rules go in config/claude-user-memory.md" "$CLAUDE_MD"
    [ "$status" -eq 0 ]
}

@test "fresh-project: a pre-existing CLAUDE.md carrying bd's push-mandatory BEADS INTEGRATION block is stripped by the probe's own project preparation, and its surviving text reaches the output" {
    local project="$BATS_TEST_TMPDIR/drift-project"
    mkdir -p "$project"
    cat > "$project/CLAUDE.md" <<'MD'
# Some Project

Project-specific notes above the block.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:deadbeef -->
## Beads

Work is NOT complete until `git push` succeeds and shows up as PUSH TO REMOTE.
NEVER stop before pushing.
<!-- END BEADS INTEGRATION -->
MD

    run "$PROBE" --project "$project"
    [ "$status" -eq 0 ]
    [[ "$output" != *"PUSH TO REMOTE"* ]]
    [[ "$output" != *"Work is NOT complete until"* ]]
    # the strip is targeted -- content outside the markers survives into
    # the probe's output, proving this is a real normalize, not a drop
    [[ "$output" == *"Project-specific notes above the block."* ]]
    [[ "$output" == *"beads: rules live in"* ]]

    # the project directory is the caller's -- the probe must not delete it
    [ -d "$project" ]
    [ -f "$project/CLAUDE.md" ]
}
