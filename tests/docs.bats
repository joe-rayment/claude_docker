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

@test "README contains the gh api bootstrap one-liner for joe-rayment/claude_orca and documents claude-dev --doctor, --update, --teardown" {
    [ -f "$README_MD" ]
    run grep -F -- "gh api repos/joe-rayment/claude_orca/contents/bootstrap.sh" "$README_MD"
    [ "$status" -eq 0 ]
    run grep -F -- 'Accept: application/vnd.github.raw' "$README_MD"
    [ "$status" -eq 0 ]
    for flag in "claude-dev --doctor" "claude-dev --update" \
                "claude-dev --teardown"; do
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

# --- V5 (claude-orca-qt9.5), re-pointed to v3 by claude-orca-qa2.3 -------

@test "README documents how it starts, the VM boundary and the folder's own config, and no doc mentions ~/.claude-orca as a current location" {
    # How you actually start it: one command, then a browser tab.
    grep -qF -- "gh api repos/joe-rayment/claude_orca/contents/bootstrap.sh" "$README_MD"
    grep -qi -- "browser" "$README_MD"
    grep -qF -- "./claude-dev shell" "$README_MD"

    # The boundary, named, with the runtime that enforces it.
    grep -qF -- "container system start" "$README_MD"
    grep -qi -- "virtual machine" "$README_MD"
    grep -qF -- "/home/agent" "$README_MD"

    # ... and what crosses it: the project, the folder home, read-only extras.
    grep -qF -- ".claude-dev/home" "$README_MD"
    grep -qi -- "read-only" "$README_MD"
    grep -qF -- "127.0.0.1" "$README_MD"

    # The claude-orca.json knobs that size it and widen it.
    local knob
    for knob in "claude-orca.json" "extraMounts" "cpus" "memory" "port"; do
        grep -qF -- "$knob" "$README_MD"
    done

    # Nothing from v2 is still advertised.
    ! grep -qF -- "Orca.app" "$README_MD"
    ! grep -qF -- "sandbox.json" "$README_MD"
    ! grep -qiE -- "seatbelt|sandbox-exec" "$README_MD"

    # ~/.claude-orca may appear ONLY as the v1 leftover -- never as a place
    # anything lives now.
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

# --- V6 (claude-orca-riu.6): one story for the default stack -------------

# First line number matching a fixed string, or "" when absent.
first_line_of() {
    grep -n -F -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}

@test "README opens by naming the assumed stack: Claude Code master, OpenRouter workers, Orca coordination on by default" {
    local head
    head="$(sed -n '1,45p' "$README_MD")"
    local term
    for term in "Claude Code" "OpenRouter" "Orca"; do
        case "$head" in
            *"$term"*) ;;
            *) printf 'opening does not mention %s\n' "$term"; return 1 ;;
        esac
    done
    # The claim itself, not just the three product names.
    printf '%s' "$head" | grep -qiE 'master|orchestrat'
    printf '%s' "$head" | grep -qiE 'worker'
    printf '%s' "$head" | grep -qiE 'on by default|by default'
}

@test "the quickstart runs bootstrap, then signing in inside Orca -- all before the reference sections" {
    grep -qE '^## Quickstart' "$README_MD"
    local boot signin ref
    boot="$(first_line_of "$README_MD" 'gh api repos/joe-rayment/claude_orca/contents/bootstrap.sh')"
    signin="$(first_line_of "$README_MD" 'Sign in to Claude')"
    ref="$(grep -n -E '^## What is isolated' "$README_MD" | head -1 | cut -d: -f1)"
    [ -n "$boot" ] && [ -n "$signin" ] && [ -n "$ref" ]
    [ "$boot" -lt "$signin" ] || { printf 'bootstrap (%s) not before sign-in (%s)\n' "$boot" "$signin"; return 1; }
    [ "$signin" -lt "$ref" ] || { printf 'sign-in (%s) not before reference sections (%s)\n' "$signin" "$ref"; return 1; }
    # v3 (claude-orca-qa2.3): there is no walk-through left to name -- the
    # one command IS the whole install.
    ! grep -qiE 'guided walk-through' "$README_MD"
    ! grep -qF -- './claude-dev setup' "$README_MD"
}

@test "exactly one page explains cheap workers without losing quality, with a real worked example, and the README points at it" {
    local f hits=0
    for f in "$README_MD" "$KB_DIR"/*.md; do
        if grep -qE '^#+ .*[Cc]heap workers without losing quality' "$f"; then
            hits=$((hits + 1))
        fi
    done
    [ "$hits" -eq 1 ] || { printf 'expected 1 "cheap workers" section, found %s\n' "$hits"; return 1; }

    local routes="$KB_DIR/DELEGATION_ROUTES.md"
    grep -qE '^#+ .*[Cc]heap workers without losing quality' "$routes"
    # A worked sequence in commands this repo actually has.
    grep -qF -- 'bd create' "$routes"
    grep -qF -- '--acceptance' "$routes"
    grep -qF -- 'delegate run --route deepseek --bead' "$routes"
    grep -qF -- 'delegate report' "$routes"
    # ... and the quality half of the claim: contracts and the checker stay
    # on the strong model.
    grep -qiE 'verifier' "$routes"

    # The README sends the reader there rather than re-telling it.
    grep -qF -- 'DELEGATION_ROUTES.md' "$README_MD"
}

@test "nothing still calls the Orca CLI mode opt-in, in docs or in the code comments that describe it" {
    local files=("$README_MD" "$CLAUDE_MD" "$AGENTS_MD" \
                 "$REPO_ROOT/config/orca-cli-addendum.md") f hits=""
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$KB_DIR" -type f -name '*.md' | sort)

    for f in "${files[@]}"; do
        if grep -q -i -E -- 'opt-in Orca CLI|opt-in orchestration' "$f"; then
            hits="$hits$f"$'\n'
        fi
    done
    [ -z "$hits" ] || {
        printf 'stale "opt-in" framing:\n%s' "$hits"
        return 1
    }
}
