#!/usr/bin/env bats

# docs-worktree.bats — beads_claude_docker-l4z6 (F5 of the worktree-session
# plan, .claude/plans/worktree-sessions.md): knowledge-base/WORKTREE_SESSIONS.md
# and knowledge-base/ORCA_SANDBOXED.md exist within their word budgets,
# knowledge-base/README.md indexes both, ORCA_SANDBOXED.md carries its
# required facts and source URLs, WORKTREE_SESSIONS.md names the shipped
# scripts/env vars/paths it documents, and CLAUDE.md's Quick Reference
# table gained cs-new/fleet-menu rows without breaking tests/rulebook.bats's
# CLAUDE.md heading whitelist (run alongside this file in the bead's own
# CHECK command, not re-implemented here).

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

KB_DIR="$REPO_ROOT/knowledge-base"
WORKTREE_MD="$KB_DIR/WORKTREE_SESSIONS.md"
ORCA_MD="$KB_DIR/ORCA_SANDBOXED.md"
README_MD="$KB_DIR/README.md"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

@test "docs-worktree: knowledge-base/WORKTREE_SESSIONS.md exists and is at most 600 words" {
    [ -f "$WORKTREE_MD" ]
    local words
    words=$(wc -w < "$WORKTREE_MD")
    [ "$words" -le 600 ]
}

@test "docs-worktree: knowledge-base/ORCA_SANDBOXED.md exists and is at most 700 words" {
    [ -f "$ORCA_MD" ]
    local words
    words=$(wc -w < "$ORCA_MD")
    [ "$words" -le 700 ]
}

@test "docs-worktree: knowledge-base/README.md indexes WORKTREE_SESSIONS.md" {
    run grep -F -- "WORKTREE_SESSIONS.md" "$README_MD"
    [ "$status" -eq 0 ]
}

@test "docs-worktree: knowledge-base/README.md indexes ORCA_SANDBOXED.md" {
    run grep -F -- "ORCA_SANDBOXED.md" "$README_MD"
    [ "$status" -eq 0 ]
}

@test "docs-worktree: ORCA_SANDBOXED.md contains the required facts" {
    for phrase in "desktop app" "Xvfb" "VNC"; do
        run grep -F -- "$phrase" "$ORCA_MD"
        [ "$status" -eq 0 ]
    done
}

@test "docs-worktree: ORCA_SANDBOXED.md cites at least three distinct https://www.onorca.dev/docs URLs" {
    local count
    count=$(grep -oE 'https://www\.onorca\.dev/docs[A-Za-z0-9/_-]*' "$ORCA_MD" | sort -u | wc -l)
    [ "$count" -ge 3 ]
}

@test "docs-worktree: WORKTREE_SESSIONS.md mentions the shipped pieces it documents" {
    for phrase in "cs-new" "fleet-menu" "peers" "BEADS_DIR" ".claude/worktrees/"; do
        run grep -F -- "$phrase" "$WORKTREE_MD"
        [ "$status" -eq 0 ]
    done
}

@test "docs-worktree: CLAUDE.md Quick Reference mentions cs-new and fleet-menu" {
    run grep -F -- "cs-new" "$CLAUDE_MD"
    [ "$status" -eq 0 ]
    run grep -F -- "fleet-menu" "$CLAUDE_MD"
    [ "$status" -eq 0 ]
}
