#!/usr/bin/env bats
#
# Acceptance contract for the build-not-pull change of 2026-09-08 --
# supersedes claude-orca-xnh's contract for this file (which superseded
# qa2.10's, which replaced qa2.8's). The image is no longer pulled from a
# registry: `acquire_image` builds it, here, from the folder's own
# template clone, with `try_build` (tests/toolchain-cache.bats owns that
# helper's own wedged/quiet/failure shapes; this file owns the choice
# `acquire_image` makes around it).
#
# WHY THIS IS A BUILD AND NOT A PULL (scripts/launcher.sh, acquire_image):
# it was a pull until 2026-09-08, from a private GHCR package, and every
# link in that chain broke in the same week -- the publishing workflow had
# failed twelve runs running, a fine-grained PAT was refused the private
# package's manifest outright, and the folder recorded "pulled" either
# way, so nothing downstream could tell a fresh image from a stale one. A
# local build has none of those failure modes: no registry, no token, no
# scope, and a cache keyed on the build inputs rather than on a workflow
# somewhere else having run.
#
# The order acquire_image tries, and the five cases below in the same
# order: local runtime backend -> nothing to acquire; CLAUDE_ORCA_IMAGE
# naming an image the daemon already holds -> use it, no build; the
# folder's template carries a Dockerfile -> build it; a failed build ->
# fall back to whatever this machine already has under that ref; nothing
# there either -> the public base image with the mounted template's own
# entrypoint, and setup.sh installs the toolchain inside the VM instead.
#
# run/image-source now holds 'built' or 'runtime' (never 'pulled' --
# nothing downstream compares against that spelling any more, only
# against 'runtime').

load helpers/setup

BASE_IMAGE="docker.io/library/ubuntu:24.04"

@test "register builds the image from the folder's own template and runs it" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    # No login and no pull -- there is no registry in this path any more.
    ! grep -q "^login " "$CONTAINER_STUB_LOG"
    ! grep -q "^pull " "$CONTAINER_STUB_LOG"

    # The build line itself: `docker build --tag <ref> <template dir>`.
    buildline="$(grep "^build " "$CONTAINER_STUB_LOG" | head -1)"
    [ -n "$buildline" ]
    [[ "$buildline" == *"--tag claude-orca:latest"* ]]
    [[ "$buildline" == *"$primary/.claude-dev/template"* ]]

    [ "$(cat "$primary/.claude-dev/run/image-source")" = "built" ]

    runline="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *"claude-orca:latest"* ]]
    [[ "$runline" != *"ghcr.io"* ]]
    [[ "$runline" != *"$BASE_IMAGE"* ]]
    [[ "$runline" != *"entrypoint.sh"* ]]

    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [[ "$output" == *"image source"* ]]
    [[ "$output" == *"built"* ]]
}

@test "a second register builds again, cheaply, rather than skipping it" {
    # docker's own layer cache is what makes a second build cheap, not
    # anything client-side here -- so the launcher always asks for one
    # rather than trying to guess whether the template changed.
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    [ "$(grep -c "^build " "$CONTAINER_STUB_LOG")" = "1" ]

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]
    [ "$(grep -c "^build " "$CONTAINER_STUB_LOG")" = "1" ]
    [ "$(cat "$primary/.claude-dev/run/image-source")" = "built" ]
}

# CLAUDE_ORCA_IMAGE names a whole image ref and wins over the IMAGE_TAG
# file. When the daemon already holds it there is nothing to build, so
# the build is skipped outright -- consulting a Dockerfile from there can
# only replace a known-good image with an unknown one. That is CI pointing
# the launcher at an image it just built, and equally anyone holding the
# image with no template to build from.
@test "CLAUDE_ORCA_IMAGE names an image the daemon already holds, and the build is skipped" {
    export CLAUDE_ORCA_IMAGE="claude-orca-local:e2e"
    # The daemon already has it -- the stub's marker file IS "present".
    printf '%s\n' "$CLAUDE_ORCA_IMAGE" > "$CONTAINER_STUB_STATE/image"

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Using the local image $CLAUDE_ORCA_IMAGE"* ]]

    ! grep -q "^build " "$CONTAINER_STUB_LOG"
    ! grep -q "^pull " "$CONTAINER_STUB_LOG"
    [ "$(cat "$primary/.claude-dev/run/image-source")" = "built" ]

    runline="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *"$CLAUDE_ORCA_IMAGE"* ]]
    [[ "$runline" != *"$BASE_IMAGE"* ]]
    [[ "$runline" != *"entrypoint.sh"* ]]

    # And a ref the daemon does NOT hold falls through to the normal
    # build, rather than pretending it is already there.
    rm -f "$CONTAINER_STUB_STATE/image"
    : > "$CONTAINER_STUB_LOG"
    mkdir -p "$BATS_TEST_TMPDIR/project2"
    second="$(abspath "$BATS_TEST_TMPDIR/project2")"
    run make_project_v3 "$second"
    [ "$status" -eq 0 ]
    grep -q -- "^build .*--tag $CLAUDE_ORCA_IMAGE " "$CONTAINER_STUB_LOG"
}

# A build can fail for reasons this machine cannot fix (disk full, a base
# layer the network cannot reach) as easily as it can succeed. With
# nothing already on the daemon under that ref, the folder still starts --
# on the public base image, installing as it goes.
@test "a failed build with no local image falls back to the base image and the mounted entrypoint" {
    export CLAUDE_ORCA_TEST_BUILD_FAIL=1

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    grep -q "^build " "$CONTAINER_STUB_LOG"
    [[ "$output" == *"The build failed"* ]]
    [[ "$output" == *"No image: the VM installs its toolchain on first start (several minutes); progress: ./claude-dev logs"* ]]

    runline="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *"$BASE_IMAGE bash /workspace/$(basename "$primary")/.claude-dev/template/scripts/container/entrypoint.sh"* ]]
    [ "$(cat "$primary/.claude-dev/run/image-source")" = "runtime" ]

    # And the same on --update: an update whose build fails moves the
    # folder onto the runtime path rather than keeping an image it cannot
    # refresh.
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]
    [ "$(cat "$primary/.claude-dev/run/image-source")" = "runtime" ]
}

# A failed build says nothing about whether the image is already HERE --
# an earlier build, or one hand-loaded onto this machine. That copy may be
# stale, but it is a working folder, which the runtime path also is not
# for free.
@test "a failed build with a local image already on this machine uses it instead of installing" {
    export CLAUDE_ORCA_TEST_BUILD_FAIL=1
    # The daemon already has an image under this folder's ref.
    printf '%s\n' "claude-orca:latest" > "$CONTAINER_STUB_STATE/image"

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    [[ "$output" == *"already on this machine"* ]]
    [ "$(cat "$primary/.claude-dev/run/image-source")" = "built" ]

    runline="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *"claude-orca:latest"* ]]
    [[ "$runline" != *"$BASE_IMAGE"* ]]
}

@test "a failed docker run stops open with an error instead of waiting for Orca" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    # Back to "registered, but no container": the next ./claude-dev creates
    # one, and this time `docker run` is the one that fails.
    name="claude-orca-$(basename "$primary")"
    rm -f "$CONTAINER_STUB_STATE/containers/$name"
    : > "$CONTAINER_STUB_LOG"
    export CLAUDE_ORCA_TEST_RUN_FAIL=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=3

    run bash -c "cd '$primary' && ./claude-dev"
    [ "$status" -ne 0 ]
    [[ "$output" == *"'docker run' failed"* ]]
    [[ "$output" != *"Waiting for Orca"* ]]
}

# A real Mac run on 2026-09-06 died here: no prebuilt image, so the folder
# took the runtime path, the launcher said "several minutes", then gave up
# after 120 s while setup.sh was still installing. The launcher's dispatch
# block runs on source, so lift the functions out of the real file rather
# than sourcing it or duplicating them here.
lift_launcher_fns() {
    local f="$1/.claude-dev/template/scripts/launcher.sh"
    sed -n '/^image_source()/,/^}/p;/^folder_installs_toolchain()/,/^}/p;/^weburl_timeout()/,/^}/p;/^wait_for_web_url()/,/^}/p' "$f"
}

# One question decides the wait: which image is this folder running?
#
# It briefly became two, while the image carried only apt and the payload
# installed into <project>/.claude-dev/toolchain -- and a folder's cache
# had to be consulted as well. That split is gone (the image carries the
# toolchain again, tests/toolchain-cache.bats says why), so the cache is
# back to being irrelevant here, and this case pins that: whatever the
# folder has cached, the runtime path waits long and the built image
# waits short.
#
# Measured on a Mac, 2026-09-07, when the cache alone decided it: a
# runtime-path recreate got 120 s for a 280 s job and the launcher gave
# up on a container that was working fine.
@test "the launcher waits 1800s on the runtime path and 120s on the built image, whatever the folder has cached" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    mkdir -p "$primary/.claude-dev/run"

    fns="$(lift_launcher_fns "$primary")"
    [ -n "$fns" ]

    ask() {
        run bash -c "unset CLAUDE_ORCA_WEBURL_TIMEOUT; $fns
weburl_timeout '$primary'"
        [ "$status" -eq 0 ]
    }
    # A folder's toolchain cache exists only on the runtime path now, but
    # a folder that once ran that way keeps the directory. It must not
    # move the answer either way.
    cache_full() {
        mkdir -p "$primary/.claude-dev/toolchain/opt-Orca"
        printf '#!/bin/sh\n' > "$primary/.claude-dev/toolchain/opt-Orca/orca-ide"
        chmod +x "$primary/.claude-dev/toolchain/opt-Orca/orca-ide"
    }
    cache_empty() { rm -rf "$primary/.claude-dev/toolchain"; }

    # The runtime path installs apt on every start and the payload on the
    # first, cache or no cache.
    printf 'runtime\n' > "$primary/.claude-dev/run/image-source"
    cache_empty; ask; [ "$output" = "1800" ]
    cache_full;  ask; [ "$output" = "1800" ]

    # The built image arrives complete: Orca serves in seconds, so
    # waiting minutes would only hide a folder that is actually broken.
    printf 'built\n' > "$primary/.claude-dev/run/image-source"
    cache_empty; ask; [ "$output" = "120" ]
    cache_full;  ask; [ "$output" = "120" ]
}

@test "CLAUDE_ORCA_WEBURL_TIMEOUT overrides both paths" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    mkdir -p "$primary/.claude-dev/run"
    fns="$(lift_launcher_fns "$primary")"

    for src in runtime built; do
        printf '%s\n' "$src" > "$primary/.claude-dev/run/image-source"
        run bash -c "export CLAUDE_ORCA_WEBURL_TIMEOUT=7; $fns
weburl_timeout '$primary'"
        [ "$status" -eq 0 ]
        [ "$output" = "7" ]
    done
}

@test "the runtime-path wait prints setup.log progress and the failure message names setup.log" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    fns="$(lift_launcher_fns "$primary")"

    # The wait itself must surface setup.log rather than sitting silent.
    # Its own scratch folder: the stub container keeps rewriting the URL
    # file in the live project, which would end the wait immediately.
    quiet="$BATS_TEST_TMPDIR/quiet"
    mkdir -p "$quiet/.claude-dev/run"
    printf 'runtime\n' > "$quiet/.claude-dev/run/image-source"
    printf '[setup] node: installing 22.x\n' > "$quiet/.claude-dev/run/setup.log"
    run bash -c "export CLAUDE_ORCA_WEBURL_TIMEOUT=2; $fns
wait_for_web_url '$quiet' 2>&1 >/dev/null"
    [ "$status" -ne 0 ]
    [[ "$output" == *"installing toolchain: [setup] node: installing 22.x"* ]]

    mkdir -p "$primary/.claude-dev/run"
    printf 'runtime\n' > "$primary/.claude-dev/run/image-source"
    printf '[setup] node: installing 22.x\n' > "$primary/.claude-dev/run/setup.log"

    # And the failure the user actually sees names the install log.
    name="claude-orca-$(basename "$primary")"
    rm -f "$CONTAINER_STUB_STATE/containers/$name"
    : > "$CONTAINER_STUB_LOG"
    rm -f "$primary/.claude-dev/run/orca-web-url.txt"
    export CLAUDE_ORCA_WEBURL_TIMEOUT=2
    export CLAUDE_ORCA_TEST_NO_URL=1
    run bash -c "cd '$primary' && ./claude-dev"
    [ "$status" -ne 0 ]
    [[ "$output" == *"did not publish a web URL within 2s"* ]]
    [[ "$output" == *"Toolchain install log:"* ]]
    [[ "$output" == *"setup.log"* ]]
}

# --- desktop Orca, S4 (claude-orca-8uo.5) --------------------------------
#
# The image and the Mac's Orca.app are one pair: Orca's protocol check is
# a hard refusal on a mismatch, not a warning, so the version the image is
# built at is the version of the app that will attach to it. The app is
# therefore an INPUT to the build -- `--build-arg ORCA_VERSION` -- and the
# version rides in the tag, so a folder whose app moved gets a different
# ref and a build rather than the image it already had under that name.
#
# With no app to read (a Mac without Orca, and every Linux host) there is
# no build arg at all: the Dockerfile's own `ARG ORCA_VERSION=` default is
# the answer, and passing it explicitly would only be a second place for
# that pin to be wrong.

# The pin as the template spells it, read rather than repeated: this file
# must not become the third copy of the version number.
template_orca_default() {
    sed -n 's/^ARG ORCA_VERSION=\([^ ]*\).*$/\1/p' "$1/.claude-dev/template/Dockerfile" | head -1
}

@test "build passes --build-arg ORCA_VERSION from the installed app" {
    # A version no default can be confused with, so the build arg can only
    # have come from the bundle.
    export CLAUDE_ORCA_APP="$(make_fake_orca_app "$BATS_TEST_TMPDIR/Applications/Orca9.app" 9.9.9)"

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    buildline="$(grep "^build " "$CONTAINER_STUB_LOG" | head -1)"
    [ -n "$buildline" ]
    [[ "$buildline" == *"--build-arg ORCA_VERSION=9.9.9"* ]]
    [[ "$buildline" == *"--tag claude-orca:latest-orca9.9.9"* ]]

    # ...and the container runs the image that build produced, not the
    # version-less ref: every reader goes through image_ref.
    runline="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *"claude-orca:latest-orca9.9.9"* ]]
}

@test "build uses the template default when no app is found" {
    export CLAUDE_ORCA_APP="$(make_fake_orca_app "$BATS_TEST_TMPDIR/Applications/Orca9.app" 9.9.9)"

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    want="$(template_orca_default "$primary")"
    [ -n "$want" ]
    [ "$want" != "9.9.9" ]

    # The same folder on a host with no Orca.app: no build arg at all, and
    # the Dockerfile's own default is what both the tag and the image are
    # at. (CLAUDE_ORCA_APP pointing nowhere is an answer, on any host.)
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' \
        && CLAUDE_ORCA_APP='$BATS_TEST_TMPDIR/no-such-Orca.app' ./claude-dev --update"
    [ "$status" -eq 0 ]

    buildline="$(grep "^build " "$CONTAINER_STUB_LOG" | head -1)"
    [ -n "$buildline" ]
    [[ "$buildline" != *"--build-arg"* ]]
    [[ "$buildline" == *"--tag claude-orca:latest-orca$want"* ]]
}

@test "the image tag changes with the Orca version" {
    app="$BATS_TEST_TMPDIR/Applications/Orca9.app"
    export CLAUDE_ORCA_APP="$(make_fake_orca_app "$app" 9.9.9)"

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    first="$(grep "^build " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$first" == *"--tag claude-orca:latest-orca9.9.9"* ]]

    # The user upgrades Orca.app. Nothing else about the folder changes --
    # same IMAGE_TAG file, same template -- and the ref it asks the daemon
    # for is a different one, which is what forces the rebuild.
    make_fake_orca_app "$app" 9.9.10 >/dev/null
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && STUB_UNAME_S=Darwin STUB_UNAME_M=arm64 ./claude-dev --update"
    [ "$status" -eq 0 ]

    second="$(grep "^build " "$CONTAINER_STUB_LOG" | head -1)"
    [ -n "$second" ]
    [[ "$second" == *"--build-arg ORCA_VERSION=9.9.10"* ]]
    [[ "$second" == *"--tag claude-orca:latest-orca9.9.10"* ]]
    [[ "$second" != *"latest-orca9.9.9"* ]]

    # The tag file is still the base of the tag -- the version is folded
    # in, it does not replace what IMAGE_TAG pins.
    [ "$(cat "$primary/.claude-dev/template/IMAGE_TAG")" = "latest" ]
}
