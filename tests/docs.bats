#!/usr/bin/env bats
#
# docs.bats -- S11 (claude-orca-3sk.22). The shipped documentation: the
# README's bootstrap one-liner and lifecycle flags, the knowledge-base
# index and its five new pages, the no-residue scan over every doc
# (nothing from the Docker/tmux era survives), and the CLAUDE.md /
# AGENTS.md project sections staying byte-identical.
#
# Grep-style, like the old template's tests/docs-worktree.bats: these are
# claims about text that must be there (or must not), not about behaviour.
#
# claude-orca-qa2.3 re-points the v2 assertions below onto v3 (the container
# VM), leaving each case's question intact -- this file is FROZEN under the
# closed riu.6, and this bead only changes the answers it looks for.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

README_MD="$REPO_ROOT/README.md"
KB_DIR="$REPO_ROOT/knowledge-base"
KB_README="$KB_DIR/README.md"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
AGENTS_MD="$REPO_ROOT/AGENTS.md"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

# Extracts the marker-delimited project sections shared by CLAUDE.md and
# AGENTS.md. Markers (not "from heading X to EOF") because both files also
# carry tool-generated blocks that differ between them.
project_sections() {
    sed -n '/<!-- BEGIN PROJECT SECTIONS -->/,/<!-- END PROJECT SECTIONS -->/p' "$1"
}

@test "CLAUDE.md and AGENTS.md carry the same project sections" {
    [ -f "$CLAUDE_MD" ]
    [ -f "$AGENTS_MD" ]
    local a b
    a="$(project_sections "$CLAUDE_MD")"
    b="$(project_sections "$AGENTS_MD")"
    [ -n "$a" ]
    [ "$a" = "$b" ]
    # The sections themselves, not just the markers.
    for heading in "## Build & Test" "## Architecture Overview" \
                   "## Conventions & Patterns"; do
        case "$a" in
            *"$heading"*) ;;
            *) printf 'missing section: %s\n' "$heading"; return 1 ;;
        esac
    done
}

# --- V5 (claude-orca-qt9.5), re-pointed to v3 by claude-orca-qa2.3 -------

# --- V6 (claude-orca-riu.6): one story for the default stack -------------

# First line number matching a fixed string, or "" when absent.
first_line_of() {
    grep -n -F -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}
