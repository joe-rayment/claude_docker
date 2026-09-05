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

@test "README contains the gh api bootstrap one-liner for joe-rayment/claude_orca and documents claude-dev --doctor, --update, --teardown, --uninstall" {
    [ -f "$README_MD" ]
    run grep -F -- "gh api repos/joe-rayment/claude_orca/contents/bootstrap.sh" "$README_MD"
    [ "$status" -eq 0 ]
    run grep -F -- 'Accept: application/vnd.github.raw' "$README_MD"
    [ "$status" -eq 0 ]
    for flag in "claude-dev --doctor" "claude-dev --update" \
                "claude-dev --teardown" "claude-dev --uninstall"; do
        run grep -F -- "$flag" "$README_MD"
        [ "$status" -eq 0 ]
    done
}

@test "knowledge-base/README.md indexes SANDBOX.md, ORCA_INTEGRATION.md, CONFIG_SYNC.md, DELEGATION_ROUTES.md, TEARDOWN_RECOVERY.md and each exists" {
    [ -f "$KB_README" ]
    for doc in SANDBOX.md ORCA_INTEGRATION.md CONFIG_SYNC.md \
               DELEGATION_ROUTES.md TEARDOWN_RECOVERY.md; do
        [ -f "$KB_DIR/$doc" ]
        run grep -F -- "$doc" "$KB_README"
        [ "$status" -eq 0 ]
    done
}

@test "no doc mentions Docker Desktop, tmux, fleet, or /workspace as the project path" {
    local files=("$README_MD" "$CLAUDE_MD" "$AGENTS_MD")
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$KB_DIR" -type f -name '*.md' | sort)

    local f term hits=""
    for f in "${files[@]}"; do
        for term in "Docker Desktop" "tmux" "fleet" "/workspace"; do
            if grep -F -i -q -- "$term" "$f"; then
                hits="$hits${f}: ${term}"$'\n'
            fi
        done
    done
    [ -z "$hits" ] || {
        printf 'residue found:\n%s' "$hits"
        return 1
    }
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

# --- V5 (claude-orca-qt9.5): the v2 documentation ------------------------

@test "README documents the double-click launch, both sandbox layers and their exceptions, and no doc mentions ~/.claude-orca as a current location" {
    # How you actually start it in v2: the bundle in the project root.
    grep -qi -- "double-click" "$README_MD"
    grep -qF -- "Orca.app" "$README_MD"
    grep -qF -- "./claude-dev open" "$README_MD"

    # Both layers, named, each with the mechanism that enforces it.
    grep -qF -- "Layer 1" "$README_MD"
    grep -qF -- "Layer 2" "$README_MD"
    grep -qF -- "sandbox-exec" "$README_MD"
    grep -qF -- "srt" "$README_MD"

    # ... and the exceptions each layer keeps or cuts.
    grep -qi -- "clipboard" "$README_MD"
    grep -qi -- "keychain" "$README_MD"
    grep -qi -- "apple events" "$README_MD"

    # The sandbox.json knobs that narrow or widen them.
    local knob
    for knob in "orca.profileExceptions" "orca.keychain" "orca.cli"; do
        grep -qF -- "$knob" "$README_MD"
    done

    # Nothing retired is still advertised, and the probe count is current.
    ! grep -qF -- "transcriptSymlink" "$README_MD"
    ! grep -qiE -- "thirteen probes|13 probes|13 sandbox probes" "$README_MD"
    ! grep -qF -- "state/config-hash" "$README_MD"

    # ~/.claude-orca may appear ONLY as the v1 leftover that --uninstall
    # and --remove-v1 remove -- never as a place anything lives now.
    local files=("$README_MD" "$CLAUDE_MD" "$AGENTS_MD") f line hits=""
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$KB_DIR" -type f -name '*.md' | sort)

    for f in "${files[@]}"; do
        while IFS= read -r line; do
            case "$line" in
                *v1*|*leftover*|*pre-v2*) ;;
                *) hits="$hits${f}: ${line}"$'\n' ;;
            esac
        done < <(grep -F -- '~/.claude-orca' "$f" || true)
    done
    [ -z "$hits" ] || {
        printf 'stale ~/.claude-orca references:\n%s' "$hits"
        return 1
    }
}
