#!/usr/bin/env bats
#
# Acceptance contract for claude-orca-xnh -- FROZEN from RED-AT onward.
# It supersedes qa2.10's contract for this file (which replaced qa2.8's):
# same seven questions, and one of them has a different answer now that
# the image carries apt and the folder carries the toolchain. There is
# still no image build on the Mac, so qa2.8's cases stay gone.
#
# startup v4 (.claude/plans/startup-v4.md): the Mac side cannot be tested
# anywhere but against stubs, so it does as little as possible. Pulling the
# prebuilt image needs a gh token carrying read:packages -- a stock OAuth
# token (repo, read:org, gist, workflow) logs in to ghcr.io and is still
# denied the manifest -- and when that scope is missing, or the pull fails
# for any other reason, the folder runs the PUBLIC base image instead:
# docker.io/library/ubuntu:24.04, with the command
# `bash <project>/.claude-dev/template/scripts/container/entrypoint.sh`,
# because the folder's template clone is inside the mounted project. The
# entrypoint runs setup.sh at start, so the toolchain installs itself in
# the VM on that first start (claude-orca-qa2.9).
#
# The gh stub answers `api -i user` with headers; CLAUDE_ORCA_TEST_GH_SCOPES
# pins the scope list (default includes read:packages).

load helpers/setup

BASE_IMAGE="docker.io/library/ubuntu:24.04"

@test "without read:packages register runs docker.io/library/ubuntu:24.04 with the mounted template entrypoint instead of building" {
    export CLAUDE_ORCA_TEST_GH_SCOPES="repo, read:org, gist, workflow"

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    # One line, and it says what the first start is going to do.
    [[ "$output" == *"No prebuilt image: the VM installs its toolchain on first start (several minutes); progress: ./claude-dev logs"* ]]

    # No login and no pull that could only ever be refused -- and no build:
    # `docker build` is not a path the launcher has any more.
    ! grep -q "^pull " "$CONTAINER_STUB_LOG"
    ! grep -q "^login " "$CONTAINER_STUB_LOG"
    ! grep -q "^build " "$CONTAINER_STUB_LOG"

    runline="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *"$BASE_IMAGE bash /workspace/$(basename "$primary")/.claude-dev/template/scripts/container/entrypoint.sh"* ]]
    [[ "$runline" != *"ghcr.io/joe-rayment/claude_orca"* ]]

    # Which of the two images this folder runs, for container_create and the
    # doctor to read back.
    [ "$(cat "$primary/.claude-dev/run/image-source")" = "runtime" ]
    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [[ "$output" == *"image source"* ]]
    [[ "$output" == *"runtime"* ]]

    # --- with read:packages: login and pull, and the prebuilt image runs ---
    export CLAUDE_ORCA_TEST_GH_SCOPES="repo, read:org, workflow, read:packages"
    : > "$CONTAINER_STUB_LOG"
    mkdir -p "$BATS_TEST_TMPDIR/project2"
    second="$(abspath "$BATS_TEST_TMPDIR/project2")"
    run make_project_v3 "$second"
    [ "$status" -eq 0 ]

    [[ "$output" != *"No prebuilt image"* ]]
    grep -q "^login " "$CONTAINER_STUB_LOG"
    grep -q "^pull ghcr.io/joe-rayment/claude_orca:" "$CONTAINER_STUB_LOG"
    ! grep -q "^build " "$CONTAINER_STUB_LOG"

    second_run="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$second_run" == *"ghcr.io/joe-rayment/claude_orca:"* ]]
    [[ "$second_run" != *"$BASE_IMAGE"* ]]
    [[ "$second_run" != *"entrypoint.sh"* ]]
    [ "$(cat "$second/.claude-dev/run/image-source")" = "pulled" ]

    run bash -c "cd '$second' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"image source"* ]]
    [[ "$output" == *"pulled"* ]]
}

# CLAUDE_ORCA_IMAGE names a whole image ref and wins over the IMAGE_TAG
# file. When the daemon already holds it there is nothing to fetch, so the
# scope check, the login and the pull are all skipped: consulting GHCR from
# there can only fail and drop a working folder onto the slow runtime path.
# That is CI pointing the launcher at an image it just built, and equally
# anyone holding the image with no registry access.
@test "CLAUDE_ORCA_IMAGE runs a locally held image with no login and no pull" {
    export CLAUDE_ORCA_IMAGE="claude-orca-local:e2e"
    # The daemon already has it -- the stub's marker file IS "present".
    printf '%s\n' "$CLAUDE_ORCA_IMAGE" > "$CONTAINER_STUB_STATE/image"

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Using the local image $CLAUDE_ORCA_IMAGE"* ]]

    ! grep -q "^pull " "$CONTAINER_STUB_LOG"
    ! grep -q "^login " "$CONTAINER_STUB_LOG"
    [ "$(cat "$primary/.claude-dev/run/image-source")" = "pulled" ]

    runline="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *"$CLAUDE_ORCA_IMAGE"* ]]
    [[ "$runline" != *"ghcr.io/joe-rayment/claude_orca"* ]]
    [[ "$runline" != *"entrypoint.sh"* ]]

    # And a ref the daemon does NOT hold falls through to the normal path
    # rather than pretending: the pull is attempted as usual.
    rm -f "$CONTAINER_STUB_STATE/image"
    : > "$CONTAINER_STUB_LOG"
    mkdir -p "$BATS_TEST_TMPDIR/project2"
    second="$(abspath "$BATS_TEST_TMPDIR/project2")"
    run make_project_v3 "$second"
    [ "$status" -eq 0 ]
    grep -q "^pull $CLAUDE_ORCA_IMAGE" "$CONTAINER_STUB_LOG"
}

# A scoped token is no guarantee: GHCR can refuse the manifest for reasons
# the Mac cannot fix (a revoked package, a network that eats the registry).
# The pull's own last line is the diagnosis, and the folder still starts --
# on the base image, installing as it goes.
@test "a failed pull falls back to the base image path and never runs an image build" {
    export CLAUDE_ORCA_TEST_PULL_FAIL=1

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    grep -q "^pull ghcr.io/joe-rayment/claude_orca:" "$CONTAINER_STUB_LOG"
    ! grep -q "^build " "$CONTAINER_STUB_LOG"

    # What the pull said, then what happens instead of a build.
    [[ "$output" == *"pull failed"* ]]
    [[ "$output" == *"No prebuilt image: the VM installs its toolchain on first start (several minutes); progress: ./claude-dev logs"* ]]

    runline="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *"$BASE_IMAGE bash /workspace/$(basename "$primary")/.claude-dev/template/scripts/container/entrypoint.sh"* ]]
    [ "$(cat "$primary/.claude-dev/run/image-source")" = "runtime" ]

    # And the same on --update: an update whose pull fails moves the folder
    # onto the runtime path rather than keeping an image it cannot refresh.
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]
    ! grep -q "^build " "$CONTAINER_STUB_LOG"
    [ "$(cat "$primary/.claude-dev/run/image-source")" = "runtime" ]
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
# folder has cached, the runtime path waits long and the prebuilt image
# waits short.
#
# Measured on a Mac, 2026-09-07, when the cache alone decided it: a
# runtime-path recreate got 120 s for a 280 s job and the launcher gave
# up on a container that was working fine.
@test "the launcher waits 1800s on the runtime path and 120s on the prebuilt image, whatever the folder has cached" {
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

    # The prebuilt image arrives complete: Orca serves in seconds, so
    # waiting minutes would only hide a folder that is actually broken.
    printf 'pulled\n' > "$primary/.claude-dev/run/image-source"
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

    for src in runtime pulled; do
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

@test "a refused pull falls back to the image already on this machine before it falls back to installing" {
    # The token on a Mac can change under a folder's feet. On 2026-09-08
    # this one went from a classic OAuth token with read:packages to a
    # fine-grained PAT, which GHCR denies the private package outright --
    # so every folder from then on took the runtime path and installed a
    # toolchain for minutes, on a machine that already had the image sitting
    # in its daemon. A pull being refused says nothing about whether the
    # image is here.
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"

    # The daemon has the image; the registry says no.
    printf '%s\n' "ghcr.io/joe-rayment/claude_orca:latest" > "$CONTAINER_STUB_STATE/image"
    export CLAUDE_ORCA_TEST_PULL_FAIL=1

    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    [ "$(cat "$primary/.claude-dev/run/image-source")" = "pulled" ]
    [[ "$output" == *"already on this machine"* ]]

    # ... and it runs that image, not the base one.
    runline="$(grep '^run ' "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *"ghcr.io/joe-rayment/claude_orca:"* ]]
    [[ "$runline" != *"ubuntu:24.04"* ]]
}

@test "a refused pull with no local image still falls back to installing in the container" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"

    rm -f "$CONTAINER_STUB_STATE/image"
    export CLAUDE_ORCA_TEST_PULL_FAIL=1

    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    [ "$(cat "$primary/.claude-dev/run/image-source")" = "runtime" ]
}
