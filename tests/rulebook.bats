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

# ── beads_claude_docker-b56o: template-drift guard ─────────────────────────
#
# Appended by B6. CLAUDE.md (this repo's own, never shipped) may hold only
# repo-fact headings — a behaviour rule landing here instead of in
# config/claude-user-memory.md (the file that ships) is invisible to every
# user project (see .claude/plans/instruction-surface-fix.md, "Finding
# added 2026-09-02"). This whitelist makes that placement mechanical:
# adding a heading to CLAUDE.md is a deliberate act that edits this test
# too. Spellings pinned here are taken from CLAUDE.md after B3 (bw66) plus
# B6's own rename (Verification -> Acceptance Contracts), drop (Session
# Completion), and addition (Editing the template).

CLAUDE_MD_HEADINGS_WHITELIST=(
    '## Environment'
    '## Config Customization'
    '## Searching Code — `csearch`'
    '## Code Map — Structure Queries Before Grep'
    '## Stay on the Current Branch'
    '## Delegation Routes'
    '## Acceptance Contracts'
    '## Logging'
    '## Files, Screenshots & Attachments'
    '## Cleanup'
    '## Beads — Container-Specific Rules'
    '## Project Contexts'
    '## Working Inside a Larger Repo'
    '## Knowledge Base'
    '## Experience Testing'
    '## Quick Reference'
    '## Editing the template'
)

# The eight behavioural headings the pre-rewrite CLAUDE.md carried (global
# rules that now live only in config/claude-user-memory.md) — none may
# reappear here, under any spelling on this exact list.
BANNED_CLAUDE_MD_HEADINGS=(
    'Verification'
    'Ownership'
    'Answer Style'
    'Session Completion'
    'Noticed Flaws'
    'Complexity Router'
    'Model Tiering'
    'User Constraints'
)

@test "rulebook: every '## ' heading in CLAUDE.md is on the fixed whitelist" {
    while IFS= read -r heading; do
        [ -z "$heading" ] && continue
        local found=0
        for allowed in "${CLAUDE_MD_HEADINGS_WHITELIST[@]}"; do
            if [ "$heading" = "$allowed" ]; then
                found=1
                break
            fi
        done
        if [ "$found" -ne 1 ]; then
            echo "heading not on whitelist: $heading" >&2
            return 1
        fi
    done < <(grep -E '^## ' "$CLAUDE_MD")
}

@test "rulebook: none of the eight behavioural headings appear as a '## ' heading in CLAUDE.md" {
    for banned in "${BANNED_CLAUDE_MD_HEADINGS[@]}"; do
        run grep -Fx -- "## $banned" "$CLAUDE_MD"
        [ "$status" -ne 0 ]
    done
}
