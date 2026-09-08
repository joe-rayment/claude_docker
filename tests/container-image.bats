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
# extracted Ubuntu 24.04 rootfs. Whether the IMAGE works, there is no CI
# to say any more -- the image is built on the machine that runs it, by
# `acquire_image` in scripts/launcher.sh, from the folder's own template
# clone, so scripts/container/smoke.sh is run by hand (see tests/mac-e2e.sh)
# rather than gated on a workflow.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DOCKERFILE="$REPO_ROOT/Dockerfile"
SETUP="$REPO_ROOT/scripts/container/setup.sh"
SMOKE="$REPO_ROOT/scripts/container/smoke.sh"

# The Orca phase alone: from its function header to the closing brace at
# column 0. Scoping the positive assertions this way keeps them from being
# satisfied by some unrelated line elsewhere in the file.
# phase_orca plus orca_relink, which it calls: the three symlinks moved
# into that helper when the payload moved into the folder's toolchain
# cache, because a recreated container has the payload but none of the
# links, and both the fast path and the install path have to make them.
orca_phase() {
    sed -n '/^orca_relink()/,/^}/p;/^phase_orca()/,/^}/p' "$SETUP"
}

# The opencode phase alone, scoped the same way.
opencode_phase() {
    sed -n '/^phase_opencode()/,/^}/p' "$SETUP"
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

    # UNPACKED, not apt-installed. The payload lives in the folder's
    # toolchain cache now (<project>/.claude-dev/toolchain, mounted at
    # /opt/Orca), and apt would register a package in a dpkg database that
    # dies with the container -- so the next start would find an
    # installed-but-unknown Orca. Extraction has no such memory.
    printf '%s\n' "$phase" | grep -qE 'dpkg-deb -x'
    printf '%s\n' "$phase" | grep -qE 'apt-get install[^;]*orca\.deb' && return 1

    # What apt used to do for free -- resolve the .deb's own Depends -- is
    # now phase_orcadeps hand-listing them in the image, so the .deb is
    # asked directly whether that list still covers it.
    printf '%s\n' "$phase" | grep -qE 'dpkg-deb --field .* Depends'

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

@test "the Dockerfile installs nothing itself: no apt-get, no curl, only setup.sh calls" {
    # Comments are free to name what setup.sh does; instructions are not.
    run bash -c "grep -v '^[[:space:]]*#' '$DOCKERFILE' | grep -n 'apt-get'"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    run bash -c "grep -v '^[[:space:]]*#' '$DOCKERFILE' | grep -n 'curl'"
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    # Every RUN runs setup.sh and nothing else: one for the apt half, one
    # per toolchain phase, one for the template link. The count is not
    # fixed here -- the phase list owns it (tests/toolchain-cache.bats).
    local runs setups
    runs="$(grep -c '^RUN' "$DOCKERFILE")"
    setups="$(grep '^RUN' "$DOCKERFILE" | grep -c 'setup\.sh')"
    [ "$runs" = "$setups" ] || { echo "$runs RUN lines but only $setups run setup.sh"; return 1; }
    [ "$runs" -ge 3 ]

    # The apt layer copies the script by itself, so a change anywhere else
    # in the repo does not invalidate it.
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

    # --check reads the box, never a script constant: the rows this box
    # satisfies have to come back ok, or it is not reading anything real.
    # The orca row follows the box too. A dev box has no Orca, so --check
    # must SAY so and exit non-zero rather than quietly passing; a box
    # that has grown a real Orca (this one did, for the Orca-native
    # orchestration work) must report it ok at the pinned version. Pinning
    # either answer into the test only makes the case lie on the other
    # kind of box.
    local pin have=""
    pin="$(sed -n 's/^ORCA_VERSION="\${ORCA_VERSION:-\([^}]*\)}".*/\1/p' \
        "$SETUP" | head -1)"
    [ -n "$pin" ]
    if [ -f /opt/orca/VERSION ]; then
        have="$(tr -d '[:space:]' < /opt/orca/VERSION)"
    fi

    run bash "$SETUP" --check
    [[ "$output" == *"ok    node"* ]]
    [[ "$output" == *"ok    gh"* ]]
    [[ "$output" == *"ok    bats"* ]]
    [[ "$output" == *"ok    bd"* ]]
    [[ "$output" == *"ok    dolt"* ]]

    # The web-theme row follows the box for the same reason: the image gets
    # its seed at build, but a shared dev box's /opt/Orca is left alone, so
    # pinning either answer here would make the case lie on the other kind
    # of box. Everything except that row still has to be clean.
    local themed=""
    if [[ "$output" == *"ok    orca web theme"* ]]; then themed=1; fi

    if [ "$have" = "$pin" ] && [ -x /opt/orca/orca-ide ] \
        && [ -x /opt/orca/resources/bin/orca-ide ]; then
        [[ "$output" == *"ok    orca ${pin}"* ]]
        [[ "$output" != *"FAIL  orca:"* ]]
        if [ -n "$themed" ]; then
            [[ "$output" != *"FAIL "* ]]
            [ "$status" -eq 0 ]
        else
            [[ "$output" == *"FAIL  orca web theme"* ]]
        fi
    else
        [[ "$output" == *"FAIL  orca:"* ]]
        [ "$status" -ne 0 ]
    fi
}

# startup v4 (claude-orca-qa2.10), and still true now that the image is
# built locally rather than pulled: a folder whose `docker build` cannot
# run (or fails) runs plain docker.io/library/ubuntu:24.04 with the
# mounted template's entrypoint, and setup.sh installs the toolchain
# inside the VM on that first start. Nothing on this box can run a
# container to prove that path -- there is no CI to do it either now --
# so smoke.sh is run by hand, against a real daemon, from tests/mac-e2e.sh.
# This case stays static: it asserts the shape smoke.sh needs to satisfy
# that path, not that a container actually came up.
@test "smoke.sh can prove the runtime-install path on plain ubuntu:24.04" {
    # On a base image /opt/claude-orca does not exist, so the entrypoint
    # resolves the template out of the project -- which is where smoke.sh
    # has to put the checkout it was run from. And the base image has no
    # git or curl yet, so it installs the base phase first.
    local smoke
    [ -f "$SMOKE" ]
    run bash -n "$SMOKE"
    [ "$status" -eq 0 ]
    smoke="$(cat "$SMOKE")"
    [[ "$smoke" == *".claude-dev/template"* ]]
    [[ "$smoke" == *"--phase base"* ]]
}

# claude-orca-qa2.11: an OpenRouter worker inside the VM is an `opencode`
# terminal Orca supervises (.claude/plans/orca-orchestration.md, Container
# side), so opencode belongs to the image, pinned like every other phase.
# Unlike orca, this box HAS opencode -- so --check's row is a real reading
# here, not a static grep.
@test "setup.sh installs a pinned opencode and --check reports it" {
    [ -f "$SETUP" ]

    # One pin, a version, overridable by env like every other phase's.
    local pin phase
    pin="$(sed -n 's/^OPENCODE_VERSION="\${OPENCODE_VERSION:-\([^}]*\)}".*/\1/p' \
        "$SETUP" | head -1)"
    [ -n "$pin" ]
    printf '%s' "$pin" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'

    # A phase of its own, after claude and before orca, in PHASES and so in
    # --list and the default all-phases run.
    phase="$(opencode_phase)"
    [ -n "$phase" ]
    run grep -qE '^PHASES="[^"]*claude opencode[^"]*"$' "$SETUP"
    [ "$status" -eq 0 ]
    run bash "$SETUP" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"opencode"* ]]

    # run_phase dispatches it -- a real phase that needs root, not an
    # unknown name.
    run bash "$SETUP" --phase opencode
    [ "$status" -ne 0 ]
    [[ "$output" != *"unknown phase"* ]]
    [[ "$output" == *"must run as root"* ]]

    # Installed from npm at the pin, and skipped when the box already has
    # that exact version (the same stamp-then-return shape as bats/bd/dolt).
    printf '%s\n' "$phase" | grep -qE 'npm install -g[^;]*opencode-ai@\$\{OPENCODE_VERSION\}'
    printf '%s\n' "$phase" | grep -qE 'installed_opencode'
    printf '%s\n' "$phase" | grep -qE 'already present'

    # And --check reads the version off THIS box, where opencode is real.
    run bash "$SETUP" --check
    [[ "$output" == *"ok    opencode ${pin}"* ]]
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
