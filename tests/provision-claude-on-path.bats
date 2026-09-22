#!/usr/bin/env bats
#
# 15-claude-on-path -- `claude` on PATH is the newest Claude Code the
# container holds. `claude-dev --update` builds the latest into the image,
# but a `claude update` run once in the container leaves a native install
# in the bind-mounted home (~/.local/bin/claude ->
# ~/.local/share/claude/versions/<v>). That install comes first on PATH and
# outlives every rebuild, so before this step the update never reached a
# terminal.
#
# Assertions are `[ ]` and functions, never a bare `[[ ]]` (run-tests.sh).

STEP="${BATS_TEST_DIRNAME}/../scripts/container/provision.d/15-claude-on-path"

setup() {
    H="$BATS_TEST_TMPDIR/home"
    IMG="$BATS_TEST_TMPDIR/opt-claude"
    PROJ="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$H/.local/bin" "$H/.local/share/claude/versions" "$IMG" "$PROJ/.claude-dev/run"
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
    local v="$H/.local/share/claude/versions/$1"
    printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$1" > "$v"
    chmod +x "$v"
    ln -sf "$v" "$H/.local/bin/claude"
}

link_target() { readlink "$H/.local/bin/claude"; }

@test "an older home install is repointed at the image's newer claude" {
    image_claude 2.1.280
    home_claude 2.1.99
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$IMG/claude" ]
    run "$H/.local/bin/claude" --version
    [ "$output" = "2.1.280 (Claude Code)" ]
}

@test "the comparison is by version, not by string: a home 2.1.100 beats an image 2.1.99" {
    image_claude 2.1.99
    home_claude 2.1.100
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$H/.local/share/claude/versions/2.1.100" ]
}

@test "a newer home install (claude update since the build) is kept" {
    image_claude 2.1.280
    home_claude 2.1.281
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$H/.local/share/claude/versions/2.1.281" ]
    echo "$output" | grep -q "keeping"
}

@test "the same version on both sides is left alone" {
    image_claude 2.1.280
    home_claude 2.1.280
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$H/.local/share/claude/versions/2.1.280" ]
}

@test "no home install: nothing is created" {
    image_claude 2.1.280
    run claude_step
    [ "$status" -eq 0 ]
    [ ! -e "$H/.local/bin/claude" ]
    [ ! -L "$H/.local/bin/claude" ]
}

@test "a broken home link is repointed at the image's claude" {
    image_claude 2.1.280
    ln -sf "$H/.local/share/claude/versions/2.1.50" "$H/.local/bin/claude"
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$IMG/claude" ]
}

@test "a second run after the repoint is a no-op" {
    image_claude 2.1.280
    home_claude 2.1.99
    claude_step
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$IMG/claude" ]
    echo "$output" | grep -q "is the image's 2.1.280"
}

@test "no image claude: the home install is left alone" {
    home_claude 2.1.99
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$H/.local/share/claude/versions/2.1.99" ]
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
