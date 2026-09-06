#!/usr/bin/env bats
#
# v3 S1b acceptance contract (claude-orca-qa2.6) -- how the image gets
# Orca. Re-pointed when the install logic moved out of the Dockerfile and
# into scripts/container/setup.sh: the claims are the same, the file that
# has to satisfy them changed, and the Dockerfile now has to be empty of
# install steps.
#
# The first multi-arch build published amd64 and then died on the arm64
# leg with `./orca.AppImage: Exec format error`: an AppImage's runtime
# carries the "AI\x02" magic in its ELF e_ident padding, and QEMU's binfmt
# pattern does not match it, so the self-extractor cannot run under
# emulation at all. The release .deb has no such problem -- apt is the
# same path every other step already takes under QEMU.
#
# These greps are static by design, and they are no longer the only check:
# scripts/container/verify-rootfs.sh runs setup.sh for real inside an
# extracted Ubuntu 24.04 rootfs. Whether the IMAGE works is still CI's job
# -- .github/workflows/image.yml runs scripts/container/smoke.sh in it.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DOCKERFILE="$REPO_ROOT/Dockerfile"
SETUP="$REPO_ROOT/scripts/container/setup.sh"

# The Orca phase alone: from its function header to the closing brace at
# column 0. Scoping the positive assertions this way keeps them from being
# satisfied by some unrelated line elsewhere in the file.
orca_phase() {
    sed -n '/^phase_orca()/,/^}/p' "$SETUP"
}

# The arch mapping both the .deb name and every other asset go through.
arch_helper() {
    sed -n '/^deb_arch()/,/^}/p' "$SETUP"
}

# Build steps only -- comments explain the AppImage history and must stay
# free to say so.
setup_steps() {
    grep -v '^[[:space:]]*#' "$SETUP"
}

@test "setup.sh installs Orca 1.4.197 from the release .deb for the build architecture, links /opt/orca to /opt/Orca, and never executes the Orca binary at install time" {
    [ -f "$SETUP" ]

    # One pin, and it is a version, never 'latest'.
    run grep -qE '^ORCA_VERSION="\$\{ORCA_VERSION:-1\.4\.197\}"[[:space:]]*$' "$SETUP"
    [ "$status" -eq 0 ]

    local phase arch
    phase="$(orca_phase)"
    [ -n "$phase" ]
    arch="$(arch_helper)"
    [ -n "$arch" ]

    # The asset is the release .deb, named from the pin...
    printf '%s\n' "$phase" | grep -qE 'orca-ide_\$\{ORCA_VERSION\}_\$\{[A-Za-z_][A-Za-z0-9_]*\}\.deb'
    # ...and both published architectures map to their real asset:
    # orca-ide_1.4.197_amd64.deb and orca-ide_1.4.197_arm64.deb.
    printf '%s\n' "$arch" | grep -qE 'x86_64\|amd64\)[^;]*amd64'
    printf '%s\n' "$arch" | grep -qE 'arm64\|aarch64\)[^;]*arm64'

    # Installed through apt, which resolves the package's own Depends
    # (gtk/nss/at-spi/xdotool/xclip/xvfb) instead of this file guessing at
    # them -- not unpacked by hand.
    printf '%s\n' "$phase" | grep -qE 'apt-get install[^;]*orca\.deb'

    # The package lands in /opt/Orca, but ORCA_BIN's default and every
    # doc say /opt/orca; the symlink is what makes both true.
    printf '%s\n' "$phase" | grep -qE 'ln -s[a-zA-Z]*[[:space:]]+/opt/Orca[[:space:]]+/opt/orca([[:space:]]|;|$)'
    run grep -qE '(^|[[:space:]])ORCA_BIN=/opt/orca/orca-ide' "$DOCKERFILE"
    [ "$status" -eq 0 ]

    # The CLI the entrypoint's `orca repo add` reaches, and the stamp
    # claude-dev --doctor reads.
    printf '%s\n' "$phase" | grep -q '/usr/local/bin/orca'
    printf '%s\n' "$phase" | grep -q '/opt/orca/VERSION'

    # No AppImage extraction: that is the step QEMU cannot run.
    run bash -c "grep -v '^[[:space:]]*#' '$SETUP' | grep -n 'appimage-extract'"
    [ "$status" -ne 0 ]

    # And nothing invokes the Orca binary or its CLI during the build --
    # `orca-ide --version` under emulation is slow, proves nothing about
    # the target machine, and is exactly what a cross build must not need.
    run bash -c "grep -v '^[[:space:]]*#' '$SETUP' | grep -nE 'orca-ide[[:space:]]+-'"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "the Dockerfile installs nothing itself: no apt-get, no curl, just the two setup.sh calls" {
    # Comments are free to name what setup.sh does; instructions are not.
    run bash -c "grep -v '^[[:space:]]*#' '$DOCKERFILE' | grep -n 'apt-get'"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    run bash -c "grep -v '^[[:space:]]*#' '$DOCKERFILE' | grep -n 'curl'"
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    # Exactly two RUN instructions, and each one runs setup.sh.
    run bash -c "grep -c '^RUN' '$DOCKERFILE'"
    [ "$output" = "2" ]
    run bash -c "grep '^RUN' '$DOCKERFILE' | grep -c 'setup\.sh'"
    [ "$output" = "2" ]

    # The install layer copies the script by itself, so a change anywhere
    # else in the repo does not invalidate it.
    run grep -qE '^COPY scripts/container/setup\.sh ' "$DOCKERFILE"
    [ "$status" -eq 0 ]
    run grep -qE '^RUN /opt/claude-orca/scripts/container/setup\.sh --phase template' "$DOCKERFILE"
    [ "$status" -eq 0 ]
}

@test "setup.sh parses, and --check reports every phase's result on any box" {
    run bash -n "$SETUP"
    [ "$status" -eq 0 ]
    run bash -n "$REPO_ROOT/scripts/container/verify-rootfs.sh"
    [ "$status" -eq 0 ]

    # This box is not the image: Orca is not installed here, so --check
    # must say so and exit non-zero rather than quietly passing. The rows
    # this box DOES satisfy have to come back ok, or the check is not
    # reading anything real.
    run bash "$SETUP" --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL  orca:"* ]]
    [[ "$output" == *"ok    node"* ]]
    [[ "$output" == *"ok    gh"* ]]
    [[ "$output" == *"ok    bats"* ]]
    [[ "$output" == *"ok    bd"* ]]
    [[ "$output" == *"ok    dolt"* ]]
}

@test "setup.sh's Claude Code pin is install-claude.sh's, character for character" {
    local pin setup_pin
    pin="$(sed -n 's/^CLAUDE_CODE_VERSION="\([^"]*\)".*/\1/p' \
        "$REPO_ROOT/scripts/install-claude.sh" | head -1)"
    [ -n "$pin" ]
    setup_pin="$(sed -n 's/^CLAUDE_CODE_VERSION="\${CLAUDE_CODE_VERSION:-\([^}]*\)}".*/\1/p' \
        "$SETUP" | head -1)"
    [ "$setup_pin" = "$pin" ]
}
