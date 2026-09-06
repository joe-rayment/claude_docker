#!/usr/bin/env bats
#
# Acceptance contract for claude-orca-qa2.8 -- FROZEN from RED-AT onward.
#
# A stock gh OAuth token (repo, read:org, gist, workflow) cannot pull the
# private ghcr.io/joe-rayment/claude_orca image: the registry login
# succeeds and the manifest fetch is denied. The pull->build fallback in
# qa2.2 covers that, but only after the user watches a login and a failing
# pull. So the launcher reads the token's scopes first -- from the
# X-Oauth-Scopes response header of `gh api -i user`, the one source whose
# format does not move between gh versions -- and goes straight to the
# local build with one printed line when read:packages is absent.
#
# The gh stub answers `api -i user` with headers; CLAUDE_ORCA_TEST_GH_SCOPES
# pins the scope list (default includes read:packages).

load helpers/setup

@test "register builds the image locally with one printed line when the gh token lacks read:packages, and pulls when it has it" {
    # --- no read:packages: no login, no pull, one line, then a build ---
    export CLAUDE_ORCA_TEST_GH_SCOPES="repo, read:org, gist, workflow"

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    [[ "$output" == *"gh token lacks read:packages -- building the image locally (one-time, several minutes). For the prebuilt image next time: gh auth refresh -s read:packages"* ]]

    ! grep -q "^image pull " "$CONTAINER_STUB_LOG"
    ! grep -q "^registry login " "$CONTAINER_STUB_LOG"
    build="$(grep "^build " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$build" == *"-t ghcr.io/joe-rayment/claude_orca:"* ]]
    [[ "$build" == *"-f $primary/.claude-dev/template/Dockerfile"* ]]

    # The doctor names where this folder's image came from.
    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"image source"* ]]
    [[ "$output" == *"built"* ]]

    # --- with read:packages: login and pull as before, no build ---
    export CLAUDE_ORCA_TEST_GH_SCOPES="repo, read:org, workflow, read:packages"
    : > "$CONTAINER_STUB_LOG"
    mkdir -p "$BATS_TEST_TMPDIR/project2"
    second="$(abspath "$BATS_TEST_TMPDIR/project2")"
    run make_project_v3 "$second"
    [ "$status" -eq 0 ]

    [[ "$output" != *"lacks read:packages"* ]]
    grep -q "^registry login " "$CONTAINER_STUB_LOG"
    grep -q "^image pull ghcr.io/joe-rayment/claude_orca:" "$CONTAINER_STUB_LOG"
    ! grep -q "^build " "$CONTAINER_STUB_LOG"

    run bash -c "cd '$second' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"image source"* ]]
    [[ "$output" == *"pulled"* ]]
}

# A `container build` that fails (Apple's builder VM with no DNS: apt-get
# cannot resolve ports.ubuntu.com, exit 100) used to return 0 anyway --
# errexit is off inside a function called under `|| return 1`, and the build
# was not the function's last command -- so registration went on to run a
# container off an image that was never built.
@test "a failed local build stops register before any container run" {
    export CLAUDE_ORCA_TEST_GH_SCOPES="repo, read:org, gist, workflow"
    export CLAUDE_ORCA_TEST_BUILD_FAIL=1

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -ne 0 ]

    [[ "$output" == *"'container build' failed"* ]]
    [[ "$output" == *"Temporary failure resolving"* ]]
    [[ "$output" == *"container system stop && container system start"* ]]

    ! grep -q "^run " "$CONTAINER_STUB_LOG"
    [[ "$output" != *"Waiting for Orca"* ]]
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

# Apple's builder VM sometimes comes up with no resolver, so apt-get inside
# the Dockerfile cannot reach ports.ubuntu.com. `container build --dns <ip>`
# hands it one, which is cheaper than making the user restart the service.
@test "a build that lost DNS is retried once with --dns and register continues" {
    export CLAUDE_ORCA_TEST_GH_SCOPES="repo, read:org, gist, workflow"
    export CLAUDE_ORCA_TEST_BUILD_FAIL=dns

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    [[ "$output" == *"retrying the build with --dns"* ]]
    [ "$(grep -c "^build " "$CONTAINER_STUB_LOG")" -eq 2 ]
    retry="$(grep "^build " "$CONTAINER_STUB_LOG" | tail -1)"
    [[ "$retry" == *"--dns 1.1.1.1"* ]]
    [[ "$retry" == *"-t ghcr.io/joe-rayment/claude_orca:"* ]]

    # And the build's own output is kept for the next command to read.
    grep -q "Temporary failure resolving" "$primary/.claude-dev/run/build.log"
}

# "refusing insecure credential exchange" is what ghcr.io says when STORED
# keychain credentials are sent to its token endpoint and rejected -- a
# stale login from an earlier run, curable without a several-minute build.
@test "a stale keychain login is cleared and the pull retried" {
    export CLAUDE_ORCA_TEST_PULL_FAIL=stale

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    [[ "$output" == *"refusing insecure credential exchange"* ]]
    [[ "$output" == *"credentials in your keychain were rejected"* ]]
    grep -q "^registry logout ghcr.io" "$CONTAINER_STUB_LOG"
    [ "$(grep -c "^registry login " "$CONTAINER_STUB_LOG")" -eq 2 ]
    [ "$(grep -c "^image pull " "$CONTAINER_STUB_LOG")" -eq 2 ]
    ! grep -q "^build " "$CONTAINER_STUB_LOG"

    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pulled"* ]]
}

# The scope is one browser round trip; the fallback build is several
# minutes. So when there is a terminal to ask on, ask.
@test "register grants read:packages in place when a terminal is available, then pulls" {
    export CLAUDE_ORCA_TEST_GH_SCOPES="repo, read:org, gist, workflow"
    export CLAUDE_ORCA_TEST_TTY=1
    export STUB_GH_REFRESH_MARK="$BATS_TEST_TMPDIR/gh-refreshed"

    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    grep -q "gh auth refresh -h github.com -s read:packages" "$STUB_LOG"
    grep -q "^registry login " "$CONTAINER_STUB_LOG"
    grep -q "^image pull " "$CONTAINER_STUB_LOG"
    ! grep -q "^build " "$CONTAINER_STUB_LOG"
    [[ "$output" != *"lacks read:packages"* ]]
}
