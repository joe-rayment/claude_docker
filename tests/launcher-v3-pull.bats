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
