#!/usr/bin/env bats
#
# Acceptance contract for claude-orca-qa2.10 -- FROZEN from RED-AT onward.
# It replaces qa2.8's contract for this file: there is no `container build`
# on the Mac any more, so the cases that asserted one are gone.
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
    # `container build` is not a path the launcher has any more.
    ! grep -q "^image pull " "$CONTAINER_STUB_LOG"
    ! grep -q "^registry login " "$CONTAINER_STUB_LOG"
    ! grep -q "^build " "$CONTAINER_STUB_LOG"

    runline="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *"$BASE_IMAGE bash $primary/.claude-dev/template/scripts/container/entrypoint.sh"* ]]
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
    grep -q "^registry login " "$CONTAINER_STUB_LOG"
    grep -q "^image pull ghcr.io/joe-rayment/claude_orca:" "$CONTAINER_STUB_LOG"
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

# A scoped token is no guarantee: GHCR can refuse the manifest for reasons
# the Mac cannot fix (a revoked package, a network that eats the registry).
# The pull's own last line is the diagnosis, and the folder still starts --
# on the base image, installing as it goes.
@test "a failed pull falls back to the base image path and never runs container build" {
    export CLAUDE_ORCA_TEST_PULL_FAIL=1

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    grep -q "^image pull ghcr.io/joe-rayment/claude_orca:" "$CONTAINER_STUB_LOG"
    ! grep -q "^build " "$CONTAINER_STUB_LOG"

    # What the pull said, then what happens instead of a build.
    [[ "$output" == *"pull failed"* ]]
    [[ "$output" == *"No prebuilt image: the VM installs its toolchain on first start (several minutes); progress: ./claude-dev logs"* ]]

    runline="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *"$BASE_IMAGE bash $primary/.claude-dev/template/scripts/container/entrypoint.sh"* ]]
    [ "$(cat "$primary/.claude-dev/run/image-source")" = "runtime" ]

    # And the same on --update: an update whose pull fails moves the folder
    # onto the runtime path rather than keeping an image it cannot refresh.
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]
    ! grep -q "^build " "$CONTAINER_STUB_LOG"
    [ "$(cat "$primary/.claude-dev/run/image-source")" = "runtime" ]
}

@test "a failed container run stops open with an error instead of waiting for Orca" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    # Back to "registered, but no container": the next ./claude-dev creates
    # one, and this time `container run` is the one that fails.
    name="claude-orca-$(basename "$primary")"
    rm -f "$CONTAINER_STUB_STATE/containers/$name"
    : > "$CONTAINER_STUB_LOG"
    export CLAUDE_ORCA_TEST_RUN_FAIL=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=3

    run bash -c "cd '$primary' && ./claude-dev"
    [ "$status" -ne 0 ]
    [[ "$output" == *"'container run' failed"* ]]
    [[ "$output" != *"Waiting for Orca"* ]]
}
