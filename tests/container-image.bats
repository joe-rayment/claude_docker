#!/usr/bin/env bats
#
# Guards:   the image carries no Orca at all, and gets its way in from
#           openssh-server; every setup.sh phase still lands in the right
#           place and `setup.sh --check` reads the box rather than a constant
# Fails if: a phases/orca.sh, an orca phase, an /opt/orca link or an Orca
#           pin comes back into setup.sh or the Dockerfile; the sshd row
#           disappears from --check; the Dockerfile grows an install step of
#           its own; or the opencode phase stops being pinned
# Run:      bats tests/container-image.bats
#
# History: this file began as the v3 S1b contract (claude-orca-qa2.6) for how
# the image gets Orca -- the release .deb, unpacked, linked to /opt/orca.
# Orca left the image (claude-orca-9bh): the Mac's terminal reaches the
# container over ssh, so the claims about Orca are now claims of ABSENCE, and
# the new claim is the sshd that replaced it. The install logic lives in
# scripts/container/setup.sh and its phases/, and the Dockerfile has to be
# empty of install steps. scripts/container/verify-rootfs.sh runs setup.sh
# for real inside an extracted Ubuntu 24.04 rootfs; whether the IMAGE works
# there is no CI to say -- the image is built on the machine that runs it, by
# `acquire_image` in scripts/launcher.sh, so scripts/container/smoke.sh is
# run by hand (see tests/mac-e2e.sh). The greps below are static by design.

# need_nonroot only -- deliberately NOT helpers/setup, whose setup_file
# builds the bootstrap stub tree this file has no use for.
load helpers/user

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DOCKERFILE="$REPO_ROOT/Dockerfile"
SETUP="$REPO_ROOT/scripts/container/setup.sh"
SMOKE="$REPO_ROOT/scripts/container/smoke.sh"

# The opencode phase alone: from its function header to the closing brace at
# column 0. Scoping the positive assertions this way keeps them from being
# satisfied by some unrelated line elsewhere in the file.
opencode_phase() {
    sed -n '/^phase_opencode()/,/^}/p' "$SETUP" "${SETUP%/*}"/phases/*.sh
}

# Build steps only -- comments explain the history and must stay free to
# name what is gone.
setup_steps() {
    cat "$SETUP" "${SETUP%/*}"/phases/*.sh | grep -v '^[[:space:]]*#'
}

@test "the image carries no Orca: no orca phase or phase file, no Orca pin, no /opt/orca, no Orca binary" {
    [ -f "$SETUP" ]

    # No phase file, and the phase list does not name one.
    [ ! -e "${SETUP%/*}/phases/orca.sh" ]
    run grep -E '^(IMAGE_|TOOLCHAIN_)?PHASES=.*(^|[" ])orca([" ]|$)' "$SETUP"
    [ "$status" -ne 0 ]
    run bash "$SETUP" --list
    [ "$status" -eq 0 ]
    [[ "$output" != *"orca"* ]]

    # Asking for it is an unknown phase, not a quiet no-op.
    run bash "$SETUP" --phase orca
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown phase: orca"* ]]

    # Build steps (not comments) never mention the Orca pin, its install
    # directory, its binary or its AppImage/.deb. "claude-orca" is this
    # project, not the app, so it is struck before the match.
    run bash -c "cat '$SETUP' '${SETUP%/*}'/phases/*.sh | grep -v '^[[:space:]]*#' | sed 's/claude[-_]orca//Ig' | grep -niE 'orca'"
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    # The Dockerfile: no ORCA_* pin or ORCA_BIN, no Orca layer, no /opt/orca.
    run bash -c "grep -v '^[[:space:]]*#' '$DOCKERFILE' | sed 's/claude[-_]orca//Ig' | grep -niE 'orca'"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "the way into the container is openssh-server: installed in the base apt set, host keys deleted from the image, port 2222 exposed" {
    [ -f "$SETUP" ]

    # In BASE_PACKAGES, which the base phase apt-installs.
    local pkgs
    pkgs="$(sed -n '/^BASE_PACKAGES="/,/"$/p' "$SETUP")"
    [ -n "$pkgs" ]
    printf '%s\n' "$pkgs" | grep -qE '(^|[[:space:]"])openssh-server([[:space:]"]|$)'

    # Its postinst generates host keys; one baked into the image would be
    # shared by every container built from it, so the base phase removes
    # them right after the install. The real key comes from the folder.
    setup_steps | grep -qE 'rm -f /etc/ssh/ssh_host_\*'

    # The Dockerfile publishes the high port the entrypoint runs sshd on.
    run grep -qE '^EXPOSE 2222([[:space:]]|$)' "$DOCKERFILE"
    [ "$status" -eq 0 ]
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
    run bash "$SETUP" --check
    [[ "$output" == *"ok    node"* ]]
    [[ "$output" == *"ok    bats"* ]]
    # gh, bd, dolt and helix follow the box too: ok where it has them, a
    # FAIL row naming them where it does not (a bare dev box has none).
    local tool
    for tool in gh bd dolt; do
        if command -v "$tool" >/dev/null 2>&1; then
            [[ "$output" == *"ok    $tool"* ]]
        else
            [[ "$output" == *"FAIL  $tool:"* ]]
        fi
    done
    if command -v hx >/dev/null 2>&1 || command -v helix >/dev/null 2>&1; then
        [[ "$output" == *"ok    helix"* ]]
    else
        [[ "$output" == *"FAIL  helix"* ]]
    fi

    # The sshd row is the way-in check: ok only where openssh-server is
    # really installed, a FAIL row naming it everywhere else. Pinning either
    # answer here would make the case lie on the other kind of box.
    if [ -x /usr/sbin/sshd ]; then
        [[ "$output" == *"ok    sshd /usr/sbin/sshd"* ]]
    else
        [[ "$output" == *"FAIL  sshd:"* ]]
    fi

    # There is no Orca row of any kind: nothing in the image to read.
    [[ "$output" != *"ok    orca"* ]]
    [[ "$output" != *"FAIL  orca"* ]]

    # The exit code is the rows': non-zero exactly when some row failed.
    if [[ "$output" == *"FAIL "* ]]; then
        [ "$status" -ne 0 ]
    else
        [ "$status" -eq 0 ]
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

    # What it proves is the way in: a real ssh login against the sshd the
    # entrypoint started. It no longer waits on, or looks for, anything of
    # Orca's (comments may say so; instructions may not).
    [[ "$smoke" == *"sshd.ready"* ]]
    [[ "$smoke" == *"smoke-ssh-ok"* ]]
    run bash -c "grep -v '^[[:space:]]*#' '$SMOKE' | grep -nE 'orca-ide|orca-web-url|WEBURL|orca repo'"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# claude-orca-qa2.11: an OpenRouter worker inside the VM is an `opencode`
# process, so opencode belongs to the image, pinned like every other phase.
# This box HAS opencode -- so --check's row is a real reading here, not a
# static grep.
@test "setup.sh installs a pinned opencode and --check reports it" {
    [ -f "$SETUP" ]

    # `--phase opencode` below is asserted to REFUSE ("must run as root").
    # As root it would not refuse: it would npm-install opencode onto the
    # box running the suite, which is both a failed assertion and a real
    # side effect.
    need_nonroot "--phase opencode would really install opencode as root"

    # One pin, a version, overridable by env like every other phase's.
    local pin phase
    pin="$(sed -n 's/^OPENCODE_VERSION="\${OPENCODE_VERSION:-\([^}]*\)}".*/\1/p' \
        "$SETUP" "${SETUP%/*}"/phases/*.sh | head -1)"
    [ -n "$pin" ]
    printf '%s' "$pin" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'

    # In PHASES, so in --list and the default all-phases run.
    phase="$(opencode_phase)"
    [ -n "$phase" ]
    run grep -qE '^PHASES="([^"]* )?opencode( [^"]*)?"$' "$SETUP"
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
