#!/usr/bin/env bats
#
# 15-claude-on-path -- `claude` on PATH is one Claude Code: the home's native
# install (~/.local/bin/claude -> ~/.local/share/claude/versions/<v>), never
# older than the image's /opt/claude/claude. `claude update` only ever moves
# that link. So a missing, broken, non-native or older link is re-seeded
# from the image's binary into versions/<v>, and a newer one is kept. See
# the step's header for the three stale-copy cases this replaces, measured
# with real binaries.
#
# Assertions are `[ ]` and functions, never a bare `[[ ]]` (run-tests.sh).

STEP="${BATS_TEST_DIRNAME}/../scripts/container/provision.d/15-claude-on-path"

setup() {
    H="$BATS_TEST_TMPDIR/home"
    V="$H/.local/share/claude/versions"
    IMG="$BATS_TEST_TMPDIR/opt-claude"
    PROJ="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$H/.local/bin" "$V" "$IMG" "$PROJ/.claude-dev/run"
}

# The step as the runner starts it, pointed at the fixture image dir and
# home -- never the real /opt/claude or ~/.local.
claude_step() {
    env -i PATH="$PATH" HOME="$H" PROJECT_DIR="$PROJ" \
        CLAUDE_ORCA_CLAUDE_DIR="$IMG" bash "$STEP"
}

image_claude() {  # image_claude <version>
    printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$1" > "$IMG/claude"
    chmod +x "$IMG/claude"
    printf '%s\n' "$1" > "$IMG/VERSION"
}

home_claude() {  # home_claude <version> -- what `claude update` leaves
    printf '#!/bin/sh\necho "%s (Claude Code, home)"\n' "$1" > "$V/$1"
    chmod +x "$V/$1"
    ln -sfn "$V/$1" "$H/.local/bin/claude"
}

link_target() { readlink "$H/.local/bin/claude"; }

# The link is the native layout, pointing at a copy of the image's binary.
assert_seeded() {  # assert_seeded <version>
    [ "$(link_target)" = "$V/$1" ]
    cmp -s "$IMG/claude" "$V/$1"
    run "$H/.local/bin/claude" --version
    [ "$output" = "$1 (Claude Code)" ]
}

@test "an older home install is re-seeded from the image into versions/" {
    image_claude 2.1.280
    home_claude 2.1.99
    run claude_step
    [ "$status" -eq 0 ]
    assert_seeded 2.1.280
    [ -x "$V/2.1.99" ]
}

@test "no home install: the image's claude is seeded as a native install" {
    image_claude 2.1.280
    run claude_step
    [ "$status" -eq 0 ]
    assert_seeded 2.1.280
}

@test "a link at the image's binary (not the native layout) is re-seeded" {
    image_claude 2.1.280
    ln -sfn "$IMG/claude" "$H/.local/bin/claude"
    run claude_step
    [ "$status" -eq 0 ]
    assert_seeded 2.1.280
}

@test "a broken home link is re-seeded" {
    image_claude 2.1.280
    ln -sfn "$V/2.1.50" "$H/.local/bin/claude"
    run claude_step
    [ "$status" -eq 0 ]
    assert_seeded 2.1.280
}

@test "the comparison is by version, not by string: a home 2.1.100 beats an image 2.1.99" {
    image_claude 2.1.99
    home_claude 2.1.100
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$V/2.1.100" ]
}

@test "a newer home install (claude update since the build) is kept" {
    image_claude 2.1.280
    home_claude 2.1.281
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$V/2.1.281" ]
    run "$H/.local/bin/claude" --version
    [ "$output" = "2.1.281 (Claude Code, home)" ]
}

@test "the same version on both sides is left alone" {
    image_claude 2.1.280
    home_claude 2.1.280
    run claude_step
    [ "$status" -eq 0 ]
    run "$H/.local/bin/claude" --version
    [ "$output" = "2.1.280 (Claude Code, home)" ]
}

@test "a second run after seeding is a no-op" {
    image_claude 2.1.280
    claude_step
    touch -d '2020-01-01' "$V/2.1.280"
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$V/2.1.280" ]
    [ "$(stat -c %Y "$V/2.1.280")" = "$(date -d '2020-01-01' +%s)" ]
}

@test "no image claude: the home install is left alone" {
    home_claude 2.1.99
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$V/2.1.99" ]
}

@test "a plain file at ~/.local/bin/claude is not replaced and the step fails loudly" {
    image_claude 2.1.280
    printf '#!/bin/sh\necho "2.1.99 (Claude Code)"\n' > "$H/.local/bin/claude"
    chmod +x "$H/.local/bin/claude"
    run claude_step
    [ "$status" -eq 1 ]
    [ ! -L "$H/.local/bin/claude" ]
    echo "$output" | grep -q "shadows the image's 2.1.280"
}
