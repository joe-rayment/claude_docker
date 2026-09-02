#!/usr/bin/env bats

# rulebook.bats — beads_claude_docker-bw66 (B3 of the "one rulebook" plan,
# .claude/plans/instruction-surface-fix.md): config/claude-user-memory.md
# is now the complete, short behavioural rulebook that ships to every
# project as ~/.claude/CLAUDE.md; this repo's own CLAUDE.md keeps only
# repo-specific facts; AGENTS.md is a pointer. Enforces the word budgets,
# the seven now-banned phrases from the pre-rewrite text, the seven
# required Appendix A headings, and that no '## ' heading is duplicated
# across CLAUDE.md and config/claude-user-memory.md — every rule stated
# once, in the file that ships.
#
# Companion test suites (not run from here — see the bead's own report):
# tests/smoke.bats and tests/acceptance-contracts.bats assert on CLAUDE.md
# content moved by this rewrite; tests/b56o's future heading whitelist
# (beads_claude_docker-b56o) is a separate, later check.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
USER_MEMORY="$REPO_ROOT/config/claude-user-memory.md"
AGENTS_MD="$REPO_ROOT/AGENTS.md"

# The seven phrases the pre-rewrite text carried (Opus Answer Protocol,
# the old file-count lane trigger, the old verifier-per-bead phrasing, the
# override-by-name paragraphs, bd's push boilerplate, the environment-
# limitation escape hatch) — none may survive the rewrite in either file.
BANNED_PHRASES=(
    'overrides, by name'
    'physically painful'
    'Work is not done until pushed'
    'verifier` per bead'
    '≥3 files'
    'environment limitation'
    'Opus Answer Protocol'
)

# Appendix A's seven section headings (two are matched as prefixes: the
# shipped headings are "## Push and deploy are the user's actions" and
# "## Delegation — roles, not models").
REQUIRED_HEADINGS=(
    '## Sandbox vs. your systems'
    '## Push and deploy'
    '## Ownership'
    '## Finishing a message'
    '## Beads'
    '## Lanes'
    '## Delegation'
)

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

@test "rulebook: config/claude-user-memory.md is at most 1000 words" {
    local words
    words=$(wc -w < "$USER_MEMORY")
    [ "$words" -le 1000 ]
}

@test "rulebook: CLAUDE.md is at most 1700 words" {
    local words
    words=$(wc -w < "$CLAUDE_MD")
    [ "$words" -le 1700 ]
}

@test "rulebook: AGENTS.md is at most 200 words" {
    local words
    words=$(wc -w < "$AGENTS_MD")
    [ "$words" -le 200 ]
}

@test "rulebook: none of the seven banned phrases appear in CLAUDE.md" {
    for phrase in "${BANNED_PHRASES[@]}"; do
        run grep -F -- "$phrase" "$CLAUDE_MD"
        [ "$status" -ne 0 ]
    done
}

@test "rulebook: none of the seven banned phrases appear in config/claude-user-memory.md" {
    for phrase in "${BANNED_PHRASES[@]}"; do
        run grep -F -- "$phrase" "$USER_MEMORY"
        [ "$status" -ne 0 ]
    done
}

@test "rulebook: config/claude-user-memory.md contains all seven required headings" {
    for heading in "${REQUIRED_HEADINGS[@]}"; do
        run grep -F -- "$heading" "$USER_MEMORY"
        [ "$status" -eq 0 ]
    done
}

@test "rulebook: no '## ' heading text is shared between CLAUDE.md and config/claude-user-memory.md" {
    grep -E '^## ' "$CLAUDE_MD" | sort > "$BATS_TEST_TMPDIR/claude-headings.txt"
    grep -E '^## ' "$USER_MEMORY" | sort > "$BATS_TEST_TMPDIR/memory-headings.txt"
    run comm -12 "$BATS_TEST_TMPDIR/claude-headings.txt" "$BATS_TEST_TMPDIR/memory-headings.txt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
