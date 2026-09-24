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
