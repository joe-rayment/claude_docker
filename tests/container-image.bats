#!/usr/bin/env bats
#
# v3 S1b acceptance contract (claude-orca-qa2.6) -- FROZEN from RED-AT
# onward. How the image gets Orca.
#
# The first multi-arch build published amd64 and then died on the arm64
# leg with `./orca.AppImage: Exec format error`: an AppImage's runtime
# carries the "AI\x02" magic in its ELF e_ident padding, and QEMU's binfmt
# pattern does not match it, so the self-extractor cannot run under
# emulation at all. The release .deb has no such problem -- apt is the
# same path every other layer already takes under QEMU.
#
# Static by design. This box cannot build containers (no mount
# namespaces), so what is checkable here is the recipe: the right asset
# for each architecture, the symlink the entrypoint's default depends on,
# and the absence of any build step that would have to EXECUTE a 200 MB
# emulated Electron binary. Whether the image really works is CI's job --
# .github/workflows/image.yml runs scripts/container/smoke.sh in it.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DOCKERFILE="$REPO_ROOT/Dockerfile"

# The Orca layer alone: from its ARG to the blank line that ends the
# block. Scoping the positive assertions this way keeps them from being
# satisfied by some unrelated line elsewhere in the file.
orca_layer() {
    sed -n '/^ARG ORCA_VERSION=/,/^$/p' "$DOCKERFILE"
}

# Build steps only -- comments explain the AppImage history and must stay
# free to say so.
run_steps() {
    grep -v '^[[:space:]]*#' "$DOCKERFILE"
}

@test "the Dockerfile installs Orca 1.4.197 from the release .deb for the build architecture, links /opt/orca to /opt/Orca, and never executes the Orca binary at build time" {
    [ -f "$DOCKERFILE" ]

    # One pin, and it is a version, never 'latest'.
    run grep -qE '^ARG ORCA_VERSION=1\.4\.197[[:space:]]*$' "$DOCKERFILE"
    [ "$status" -eq 0 ]

    local layer
    layer="$(orca_layer)"
    [ -n "$layer" ]

    # The asset is the release .deb, named from the pin...
    printf '%s\n' "$layer" | grep -qE 'orca-ide_\$\{ORCA_VERSION\}_\$\{[A-Za-z_][A-Za-z0-9_]*\}\.deb'
    # ...and both published architectures map to their real asset:
    # orca-ide_1.4.197_amd64.deb and orca-ide_1.4.197_arm64.deb.
    printf '%s\n' "$layer" | grep -qE 'x86_64\|amd64\)[^;]*=amd64'
    printf '%s\n' "$layer" | grep -qE 'arm64\|aarch64\)[^;]*=arm64'

    # Installed through apt, which resolves the package's own Depends
    # (gtk/nss/at-spi/xdotool/xclip/xvfb) instead of this file guessing at
    # them -- not unpacked by hand.
    printf '%s\n' "$layer" | grep -qE 'apt-get install[^;]*orca\.deb'

    # The package lands in /opt/Orca, but ORCA_BIN's default and every
    # doc say /opt/orca; the symlink is what makes both true.
    printf '%s\n' "$layer" | grep -qE 'ln -s[a-zA-Z]*[[:space:]]+/opt/Orca[[:space:]]+/opt/orca([[:space:]]|;|$)'
    run grep -qE '(^|[[:space:]])ORCA_BIN=/opt/orca/orca-ide' "$DOCKERFILE"
    [ "$status" -eq 0 ]

    # The CLI the entrypoint's `orca repo add` reaches, and the stamp
    # claude-dev --doctor reads.
    printf '%s\n' "$layer" | grep -q '/usr/local/bin/orca'
    printf '%s\n' "$layer" | grep -q '/opt/orca/VERSION'

    # No AppImage extraction: that is the step QEMU cannot run.
    run bash -c "grep -v '^[[:space:]]*#' '$DOCKERFILE' | grep -n 'appimage-extract'"
    [ "$status" -ne 0 ]

    # And nothing invokes the Orca binary or its CLI during the build --
    # `orca-ide --version` under emulation is slow, proves nothing about
    # the target machine, and is exactly what a cross build must not need.
    run bash -c "grep -v '^[[:space:]]*#' '$DOCKERFILE' | grep -nE 'orca-ide[[:space:]]+-'"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}
