#!/usr/bin/env bats
#
# Acceptance contract for claude-orca-jg1 -- the recreated-container
# downgrade. The launcher builds the image at the app's Orca version
# (claude-orca-8uo.5) but told `docker run` nothing: the container's
# boot-time setup.sh then fell back to its own pin, and a recreated
# container reinstalled the pin over the image's build -- measured
# 2026-09-19 as "orca: installing 1.4.197" in a container whose image was
# built at 1.4.203. The run now carries the ONE answer the tag and the
# build arg already use: wanted_orca_version.

load helpers/setup

# helpers/setup.bash's per-test setup, kept under its own name before the
# file's setup() below shadows it.
eval "helpers_setup() $(declare -f setup | tail -n +2)"

setup() {
    # This box is itself a claude-orca container and exports these for its
    # own real runtime; left set they argue with the fixture -- ORCA_VERSION
    # with the app's version, the rest with the folder under test.
    unset ORCA_VERSION PROJECT_DIR CLAUDE_ORCA_ROOT BEADS_DIR
    helpers_setup
}

# The one line the `docker` stub logged for the invocation whose argv
# starts with $1 (its log is one line per invocation, argv joined).
ctr_line() {
    grep "^$1" "$CONTAINER_STUB_LOG" | head -1
}

@test "open passes the installed app's Orca version to docker run" {
    export CLAUDE_ORCA_APP="$(make_fake_orca_app "$BATS_TEST_TMPDIR/Applications/Orca203.app" 1.4.203)"

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    line="$(ctr_line "run ")"
    [[ "$line" == *"-e ORCA_VERSION=1.4.203"* ]]
}

@test "with no app the run carries the Dockerfile's ARG default" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    # Read rather than repeated: this file must not become another copy of
    # the version number. (The template clone is this same file, copied by
    # setup_file.)
    want="$(sed -n 's/^ARG ORCA_VERSION=\([^ ]*\).*$/\1/p' "$REPO_ROOT/Dockerfile" | head -1)"
    [ -n "$want" ]

    # The same folder on a host with no Orca.app (CLAUDE_ORCA_APP pointing
    # nowhere is an answer, on any host): --update rebuilds at the
    # Dockerfile's own default and recreates the container.
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' \
        && CLAUDE_ORCA_APP='$BATS_TEST_TMPDIR/no-such-Orca.app' ./claude-dev --update"
    [ "$status" -eq 0 ]

    line="$(ctr_line "run ")"
    [[ "$line" == *"-e ORCA_VERSION=$want"* ]]
}

@test "the run, the image tag and the build arg carry one version" {
    export CLAUDE_ORCA_APP="$(make_fake_orca_app "$BATS_TEST_TMPDIR/Applications/Orca203.app" 1.4.203)"

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    buildline="$(grep "^build " "$CONTAINER_STUB_LOG" | head -1)"
    [ -n "$buildline" ]
    [[ "$buildline" == *"--build-arg ORCA_VERSION=1.4.203"* ]]
    [[ "$buildline" == *"--tag claude-orca:latest-orca1.4.203"* ]]

    line="$(ctr_line "run ")"
    [[ "$line" == *"-e ORCA_VERSION=1.4.203"* ]]
}
# Guards: a plain ./claude-dev after the Orca app updated itself builds the
#   image for the new version instead of `docker run`-pulling a tag that
#   exists nowhere (real Mac, 2026-10-06: "pull access denied for claude-orca").
# Fails if: cmd_open_v3 stops building a missing image before it creates the container.
# Run: bats -f 'app updated' tests/launcher-orca-version-run.bats
@test "open after the app updated builds the new image before docker run" {
    export CLAUDE_ORCA_APP="$(make_fake_orca_app "$BATS_TEST_TMPDIR/Applications/Orca203.app" 1.4.203)"
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    # The app updates itself; the daemon still holds only the 1.4.203 image.
    make_fake_orca_app "$CLAUDE_ORCA_APP" 1.4.204 >/dev/null
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && CLAUDE_ORCA_TEST_IMAGE_ID=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd STUB_UNAME_S=Darwin STUB_UNAME_M=arm64 ./claude-dev"
    [ "$status" -eq 0 ]

    buildline="$(grep -n "^build " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$buildline" == *"--tag claude-orca:latest-orca1.4.204"* ]]
    runline="$(grep -n "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$runline" == *"claude-orca:latest-orca1.4.204"* ]]
    # built first, run second
    [ "${buildline%%:*}" -lt "${runline%%:*}" ]
}
