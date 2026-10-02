#!/usr/bin/env bats
#
# 15-claude-on-path -- the folder's home holds the ONLY Claude Code, in the
# native-install layout: a link at .local/bin/claude into
# .local/share/claude/versions/<v>, the same link `claude update` moves.
# Every container start the step brings it to the latest release -- pointed
# at a file:// fixture here -- downloaded and sha256-verified, never copied
# from an image. A missing, broken or non-native link is replaced; an
# up-to-date one is left alone; when the releases server is unreachable or
# malformed, what the home already has is kept, and only a home with nothing
# to keep fails loudly.
#
# Assertions are `[ ]` and functions, never a bare `[[ ]]` (run-tests.sh).

STEP="${BATS_TEST_DIRNAME}/../scripts/container/provision.d/15-claude-on-path"

setup() {
    H="$BATS_TEST_TMPDIR/home"
    V="$H/.local/share/claude/versions"
    R="$BATS_TEST_TMPDIR/releases"
    PROJ="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$H/.local/bin" "$V" "$R" "$PROJ/.claude-dev/run"
}

# The step as the runner starts it, pointed at the fixture releases dir and
# the fixture home -- never the real downloads server or the real home.
# REL_URL overrides the releases URL for the unreachable case.
claude_step() {
    env -i PATH="$PATH" HOME="$H" PROJECT_DIR="$PROJ" \
        CLAUDE_ORCA_CLAUDE_RELEASES="${REL_URL:-file://$R}" bash "$STEP"
}

# The same arch->platform spelling as the step.
case "$(uname -m)" in
    aarch64|arm64) ARCH=arm64 ;;
    x86_64|amd64)  ARCH=x64 ;;
    *)             ARCH="unsupported-$(uname -m)" ;;
esac

release() {  # release <v> -- one fixture release: a binary and its manifest
    mkdir -p "$R/$1/linux-$ARCH"
    printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$1" \
        > "$R/$1/linux-$ARCH/claude"
    chmod +x "$R/$1/linux-$ARCH/claude"
    printf '{"platforms":{"linux-%s":{"checksum":"%s"}}}\n' "$ARCH" \
        "$(sha256sum "$R/$1/linux-$ARCH/claude" | cut -d' ' -f1)" \
        > "$R/$1/manifest.json"
}

latest() {  # latest <v> -- what $RELEASES/latest serves
    printf '%s\n' "$1" > "$R/latest"
}

home_claude() {  # home_claude <v> -- what `claude update` leaves behind
    printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$1" > "$V/$1"
    chmod +x "$V/$1"
    ln -sfn "$V/$1" "$H/.local/bin/claude"
}

link_target() { readlink "$H/.local/bin/claude"; }

no_tmp_left() {
    local f
    for f in "$V"/.*claude-orca.tmp; do
        [ -e "$f" ] && return 1
    done
    return 0
}

no_dl_strays() {  # no file of either temp-file name anywhere under .local/share/claude
    local strays
    strays="$(find "$H/.local/share/claude" \
        \( -name '.claude-orca-dl.*' -o -name '.*claude-orca.tmp' \) -print)"
    [ -z "$strays" ]
}

@test "1: no home install -> the latest release is downloaded and linked" {
    release 2.1.280
    latest 2.1.280
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$V/2.1.280" ]
    cmp -s "$V/2.1.280" "$R/2.1.280/linux-$ARCH/claude"
    run "$H/.local/bin/claude" --version
    [ "$output" = "2.1.280 (Claude Code)" ]
}

@test "2: an older native install is updated to the latest release" {
    release 2.1.280
    latest 2.1.280
    home_claude 2.1.99
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$V/2.1.280" ]
    [ -x "$V/2.1.99" ]
}

@test "3: numeric order, not string order: 2.1.100 beats latest 2.1.99" {
    latest 2.1.99
    home_claude 2.1.100
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$V/2.1.100" ]
}

@test "4: an equal version is left alone" {
    latest 2.1.280
    home_claude 2.1.280
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$V/2.1.280" ]
    echo "$output" | grep -q "is current"
}

@test "5: a non-native link (at the image's old copy) is replaced" {
    release 2.1.280
    latest 2.1.280
    mkdir -p "$BATS_TEST_TMPDIR/image"
    printf '#!/bin/sh\necho "2.1.50 (Claude Code)"\n' \
        > "$BATS_TEST_TMPDIR/image/claude"
    chmod +x "$BATS_TEST_TMPDIR/image/claude"
    ln -sfn "$BATS_TEST_TMPDIR/image/claude" "$H/.local/bin/claude"
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$V/2.1.280" ]
}

@test "6: a broken link is replaced" {
    release 2.1.280
    latest 2.1.280
    ln -sfn "$V/2.1.50" "$H/.local/bin/claude"
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$V/2.1.280" ]
}

@test "7: a checksum mismatch fails and leaves the home install untouched" {
    release 2.1.280
    latest 2.1.280
    printf '{"platforms":{"linux-%s":{"checksum":"%s"}}}\n' "$ARCH" \
        "$(printf 'not claude\n' | sha256sum | cut -d' ' -f1)" \
        > "$R/2.1.280/manifest.json"
    home_claude 2.1.99
    run claude_step
    [ "$status" -eq 1 ]
    [ "$(link_target)" = "$V/2.1.99" ]
    [ ! -e "$V/2.1.280" ]
    no_tmp_left
}

@test "8: unreachable releases, home install present -> it is kept" {
    home_claude 2.1.99
    REL_URL="file:///nonexistent-dir"
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$V/2.1.99" ]
    echo "$output" | grep -q "keeping claude 2.1.99"
}

@test "9: unreachable releases and no home install -> fails loudly" {
    REL_URL="file:///nonexistent-dir"
    run claude_step
    [ "$status" -eq 1 ]
    [ ! -e "$H/.local/bin/claude" ]
    [ ! -L "$H/.local/bin/claude" ]
}

@test "10: a latest that is not a semver -> keep the home install" {
    latest '<html>'
    home_claude 2.1.99
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$V/2.1.99" ]
}

@test "11: a plain file at the link path is refused" {
    release 2.1.280
    latest 2.1.280
    printf '#!/bin/sh\necho "2.1.99 (Claude Code)"\n' > "$H/.local/bin/claude"
    chmod +x "$H/.local/bin/claude"
    run claude_step
    [ "$status" -eq 1 ]
    [ ! -L "$H/.local/bin/claude" ]
    echo "$output" | grep -q "is a file"
}

@test "12: a second run is a no-op" {
    release 2.1.280
    latest 2.1.280
    run claude_step
    [ "$status" -eq 0 ]
    touch -d '2020-01-01' "$V/2.1.280"
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(stat -c %Y "$V/2.1.280")" = "$(date -d '2020-01-01' +%s)" ]
}

@test "13: after a successful install nothing temp-like is left under .local/share/claude" {
    # Guards: the download lands in a unique temp file BESIDE versions/, is
    #   moved into place on success, and no temp file of either name
    #   survives anywhere under .local/share/claude (claude-orca-11c).
    # Fails if: a .claude-orca-dl.* or .*claude-orca.tmp file is left
    #   behind, or versions/ holds anything but the installed version.
    # Run: bats tests/provision-claude-on-path.bats
    release 2.1.280
    latest 2.1.280
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$V/2.1.280" ]
    [ "$(find "$V" -mindepth 1 | wc -l)" = "1" ]
    no_dl_strays
}

@test "14: an empty download is refused as 'came back empty', link untouched" {
    # Guards: a zero-byte body never reaches the checksum or the link --
    #   the step names emptiness on its own stderr line (claude-orca-11c).
    # Fails if: an empty body is reported as a curl failure or a checksum
    #   mismatch, or the home link is moved anyway.
    # Run: bats tests/provision-claude-on-path.bats
    release 2.1.280
    latest 2.1.280
    : > "$R/2.1.280/linux-$ARCH/claude"
    home_claude 2.1.99
    run claude_step
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'came back empty'
    [ "$(link_target)" = "$V/2.1.99" ]
    no_dl_strays
}

@test "15: a checksum mismatch names the sha256 check with want and got" {
    # Guards: a bad checksum reports its own reason -- 'failed its sha256
    #   check (want <want>, got <got>)' -- not a bare failure line
    #   (claude-orca-11c).
    # Fails if: the mismatch is reported as a curl failure, the message
    #   lacks either checksum, or the home link is moved anyway.
    # Run: bats tests/provision-claude-on-path.bats
    release 2.1.280
    latest 2.1.280
    want="$(printf 'not claude\n' | sha256sum | cut -d' ' -f1)"
    printf '{"platforms":{"linux-%s":{"checksum":"%s"}}}\n' "$ARCH" "$want" \
        > "$R/2.1.280/manifest.json"
    home_claude 2.1.99
    run claude_step
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "failed its sha256 check (want $want, got"
    [ "$(link_target)" = "$V/2.1.99" ]
    no_dl_strays
}

@test "16: a stale .<v>.claude-orca.tmp in versions/ is never read or written" {
    # Guards: the step no longer downloads to the old fixed temp name inside
    #   versions/; a file left there by an interrupted old run (or Claude
    #   Code's own installer) is neither required nor clobbered
    #   (claude-orca-11c).
    # Fails if: the step downloads to versions/.<v>.claude-orca.tmp, so the
    #   stale file is overwritten or moved away by the install.
    # Run: bats tests/provision-claude-on-path.bats
    release 2.1.280
    latest 2.1.280
    printf 'stale temp from an interrupted old run\n' > "$V/.2.1.280.claude-orca.tmp"
    run claude_step
    [ "$status" -eq 0 ]
    [ "$(link_target)" = "$V/2.1.280" ]
    cmp -s "$V/2.1.280" "$R/2.1.280/linux-$ARCH/claude"
    [ "$(cat "$V/.2.1.280.claude-orca.tmp")" = "stale temp from an interrupted old run" ]
}
