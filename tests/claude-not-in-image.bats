#!/usr/bin/env bats
# claude-not-in-image.bats -- the image and runtime toolchain carry no
# Claude Code, and nothing on the build path resolves, pins or passes a
# Claude Code version: Claude Code arrives only through provision step 15
# (scripts/container/provision.d/15-claude-on-path). FROZEN
# (claude-orca-dbf.2): committed red against the tree that still installs
# Claude Code, then the implementation, and never edited to make an
# implementation pass.

REPO_ROOT="${BATS_TEST_DIRNAME}/.."

@test "setup.sh --list has no claude phase and still lists opencode and orca" {
    local listed
    listed="$(bash "$REPO_ROOT/scripts/container/setup.sh" --list)"
    [ -n "$listed" ]
    printf '%s\n' "$listed" | grep -qx opencode
    printf '%s\n' "$listed" | grep -qx orca
    [ "$(printf '%s\n' "$listed" | grep -cx claude)" -eq 0 ]
}

@test "no build-path reference to a Claude Code pin, phase or install script" {
    run git -C "$REPO_ROOT" grep -n -E 'CLAUDE_CODE_VERSION|/opt/claude([^-]|$)|phase_claude|opt-claude|resolve-claude-version|install-claude' -- scripts Dockerfile tests/mac-e2e.sh tests/helpers ':!scripts/container/provision.d/15-claude-on-path'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "the Dockerfile has no claude phase RUN and no CLAUDE ARG" {
    run grep -n -- '--phase claude' "$REPO_ROOT/Dockerfile"
    [ "$status" -eq 1 ]
    run grep -n 'ARG CLAUDE' "$REPO_ROOT/Dockerfile"
    [ "$status" -eq 1 ]
}

@test "the Claude pin scripts and their test are gone" {
    [ ! -f "$REPO_ROOT/scripts/install-claude.sh" ]
    [ ! -f "$REPO_ROOT/scripts/resolve-claude-version.sh" ]
    [ ! -f "$REPO_ROOT/tests/claude-version-resolve.bats" ]
}

@test "CLAUDE.md and AGENTS.md name the payload without Claude Code and point at 15-claude-on-path" {
    local f
    for f in "$REPO_ROOT/CLAUDE.md" "$REPO_ROOT/AGENTS.md"; do
        [ -f "$f" ]
        grep -q 'Orca, opencode, bd, dolt, bats' "$f"
        grep -q '15-claude-on-path' "$f"
    done
}