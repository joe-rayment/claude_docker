#!/usr/bin/env bats

# Multi-project isolation tests
# Verifies that running the Docker setup for multiple projects simultaneously
# does not cause one project's containers to kill another's.
#
# Static tests (template/script checks) always run.
# Docker integration tests require a running Docker daemon and will skip otherwise.
#
# Usage:
#   bats tests/multi-project.bats
#
# What's being tested:
#   The root cause of the multi-project bug was that Docker Compose derives its
#   "project name" from the directory containing docker-compose.yml. Since every
#   project stores its compose file in .claude-dev/, they all get the project
#   name "claude-dev". When `docker compose up -d` runs for project B, Compose
#   finds project A's container (same project label) and tears it down.
#
#   The fix adds:
#   1. A top-level `name: ${CONTAINER_NAME}` in docker-compose.yml, interpolated
#      per project from a launcher-written .claude-dev/.env (unique per project).
#   2. Explicit `-f`/`-p` flags on all launcher compose commands (belt-and-suspenders).

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Helper: check if Docker daemon is reachable (not just the client binary)
_docker_daemon_available() {
    docker info &>/dev/null 2>&1
}

# Helper: write a per-project .env next to the compose file, mirroring the
# launcher's write_env_file(). docker compose auto-loads .env from the compose
# file's directory, so ${VAR} interpolation resolves without a daemon.
_write_env() {
    local project_dir="$1" container="$2" volume="$3" image="$4" project_name="$5"
    cat > "$project_dir/.claude-dev/.env" <<EOF
PROJECT_NAME=${project_name}
CONTAINER_NAME=${container}
VOLUME_NAME=${volume}
IMAGE_TAG=${image}
EOF
}

# Helper: resolve a project's compose file to JSON. `docker compose config`
# applies .env interpolation and needs only the CLI, not a running daemon.
_config_json() {
    (cd "$1/.claude-dev" && docker compose config --format json 2>/dev/null)
}

setup_file() {
    # Create two temporary project directories (no Docker needed for this)
    export PROJECT_A_DIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-test-project-a.XXXXXX")
    export PROJECT_B_DIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-test-project-b.XXXXXX")

    echo "# Project A" > "$PROJECT_A_DIR/README.md"
    echo "# Project B" > "$PROJECT_B_DIR/README.md"

    # Derive names the same way bootstrap.sh does
    export PROJECT_A_NAME=$(basename "$PROJECT_A_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
    export PROJECT_B_NAME=$(basename "$PROJECT_B_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')

    export CONTAINER_A="${PROJECT_A_NAME}-claude-dev"
    export CONTAINER_B="${PROJECT_B_NAME}-claude-dev"
    export VOLUME_A="${PROJECT_A_NAME}-agent-home"
    export VOLUME_B="${PROJECT_B_NAME}-agent-home"
    export IMAGE_A="claude-code-dev:${PROJECT_A_NAME}"
    export IMAGE_B="claude-code-dev:${PROJECT_B_NAME}"

    # Clone .claude-dev/ into both projects (using local repo, not GitHub)
    git clone --quiet "$REPO_DIR" "$PROJECT_A_DIR/.claude-dev"
    git clone --quiet "$REPO_DIR" "$PROJECT_B_DIR/.claude-dev"

    # Copy the working tree's compose file + Dockerfile (may have uncommitted
    # changes) over the cloned copies so we test the current template.
    cp "$REPO_DIR/docker-compose.yml" "$PROJECT_A_DIR/.claude-dev/docker-compose.yml"
    cp "$REPO_DIR/docker-compose.yml" "$PROJECT_B_DIR/.claude-dev/docker-compose.yml"
    cp "$REPO_DIR/Dockerfile" "$PROJECT_A_DIR/.claude-dev/Dockerfile"
    cp "$REPO_DIR/Dockerfile" "$PROJECT_B_DIR/.claude-dev/Dockerfile"

    # Write each project's .env so compose interpolation resolves per project.
    _write_env "$PROJECT_A_DIR" "$CONTAINER_A" "$VOLUME_A" "$IMAGE_A" "$PROJECT_A_NAME"
    _write_env "$PROJECT_B_DIR" "$CONTAINER_B" "$VOLUME_B" "$IMAGE_B" "$PROJECT_B_NAME"
}

teardown_file() {
    # Clean up containers and volumes if Docker is available
    if _docker_daemon_available; then
        for container in "$CONTAINER_A" "$CONTAINER_B"; do
            docker rm -f "$container" 2>/dev/null || true
        done
        for volume in "$VOLUME_A" "$VOLUME_B"; do
            docker volume rm "$volume" 2>/dev/null || true
        done
        for image in "$IMAGE_A" "$IMAGE_B"; do
            docker rmi "$image" 2>/dev/null || true
        done
    fi
    rm -rf "$PROJECT_A_DIR" "$PROJECT_B_DIR" 2>/dev/null || true
}

# ============================================================
# Static tests — always run, need only the compose CLI (no daemon)
# ============================================================

@test "docker-compose.yml has a parameterized top-level name field" {
    grep -q '^name: ${CONTAINER_NAME}' "$REPO_DIR/docker-compose.yml"
}

@test "resolved compose project names are unique per project" {
    local name_a name_b
    name_a=$(_config_json "$PROJECT_A_DIR" | jq -r '.name')
    name_b=$(_config_json "$PROJECT_B_DIR" | jq -r '.name')
    [ -n "$name_a" ] && [ "$name_a" != "null" ]
    [ -n "$name_b" ] && [ "$name_b" != "null" ]
    [ "$name_a" != "$name_b" ]
}

@test "resolved container names are unique per project" {
    local cname_a cname_b
    cname_a=$(_config_json "$PROJECT_A_DIR" | jq -r '.services["claude-dev"].container_name')
    cname_b=$(_config_json "$PROJECT_B_DIR" | jq -r '.services["claude-dev"].container_name')
    [ "$cname_a" != "$cname_b" ]
    [ "$cname_a" != "null" ]
}

@test "resolved volume names are unique per project" {
    local vol_a vol_b
    vol_a=$(_config_json "$PROJECT_A_DIR" | jq -r '.volumes["agent-home"].name')
    vol_b=$(_config_json "$PROJECT_B_DIR" | jq -r '.volumes["agent-home"].name')
    [ "$vol_a" != "$vol_b" ]
    [ "$vol_a" != "null" ]
}

@test "resolved project name matches its container name (project A)" {
    local name_val container_val
    name_val=$(_config_json "$PROJECT_A_DIR" | jq -r '.name')
    container_val=$(_config_json "$PROJECT_A_DIR" | jq -r '.services["claude-dev"].container_name')
    [ "$name_val" = "$container_val" ]
}

@test "launcher dc() scopes compose with -p container name" {
    grep -q '\-p "$CONTAINER_NAME"' "$REPO_DIR/scripts/launcher.sh"
}

@test "launcher dc() passes -f compose file" {
    grep -q '"-f" "$COMPOSE_FILE"' "$REPO_DIR/scripts/launcher.sh"
}

# ============================================================
# Docker integration tests — skip if daemon not available
# ============================================================

@test "build image for project A" {
    if ! _docker_daemon_available; then skip "Docker daemon not running"; fi
    cd "$PROJECT_A_DIR/.claude-dev"
    docker compose -f docker-compose.yml -p "$CONTAINER_A" build --quiet
}

@test "build image for project B" {
    if ! _docker_daemon_available; then skip "Docker daemon not running"; fi
    cd "$PROJECT_B_DIR/.claude-dev"
    docker compose -f docker-compose.yml -p "$CONTAINER_B" build --quiet
}

@test "start project A container" {
    if ! _docker_daemon_available; then skip "Docker daemon not running"; fi
    cd "$PROJECT_A_DIR/.claude-dev"
    docker compose -f docker-compose.yml -p "$CONTAINER_A" up -d
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_A" 2>/dev/null)" = "true" ]
}

@test "start project B — project A must still be running" {
    if ! _docker_daemon_available; then skip "Docker daemon not running"; fi

    # Confirm A is running before we start B
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_A" 2>/dev/null)" = "true" ]

    # Start B
    cd "$PROJECT_B_DIR/.claude-dev"
    docker compose -f docker-compose.yml -p "$CONTAINER_B" up -d

    # THE CRITICAL ASSERTION: A must still be running after B starts
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_A" 2>/dev/null)" = "true" ]
    # And B should be running too
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_B" 2>/dev/null)" = "true" ]
}

@test "both containers running simultaneously" {
    if ! _docker_daemon_available; then skip "Docker daemon not running"; fi
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_A" 2>/dev/null)" = "true" ]
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_B" 2>/dev/null)" = "true" ]
}

@test "compose down for project A does not affect project B" {
    if ! _docker_daemon_available; then skip "Docker daemon not running"; fi

    cd "$PROJECT_A_DIR/.claude-dev"
    docker compose -f docker-compose.yml -p "$CONTAINER_A" down

    # A should be gone
    run docker inspect "$CONTAINER_A" 2>/dev/null
    [ "$status" -ne 0 ]

    # B must still be running
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_B" 2>/dev/null)" = "true" ]
}

@test "compose down for project B cleans up" {
    if ! _docker_daemon_available; then skip "Docker daemon not running"; fi

    cd "$PROJECT_B_DIR/.claude-dev"
    docker compose -f docker-compose.yml -p "$CONTAINER_B" down

    run docker inspect "$CONTAINER_B" 2>/dev/null
    [ "$status" -ne 0 ]
}

@test "containers have different compose project labels" {
    if ! _docker_daemon_available; then skip "Docker daemon not running"; fi

    # Restart both for this test
    cd "$PROJECT_A_DIR/.claude-dev"
    docker compose -f docker-compose.yml -p "$CONTAINER_A" up -d
    cd "$PROJECT_B_DIR/.claude-dev"
    docker compose -f docker-compose.yml -p "$CONTAINER_B" up -d

    local label_a label_b
    label_a=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$CONTAINER_A" 2>/dev/null)
    label_b=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$CONTAINER_B" 2>/dev/null)

    # Labels must be different — this is the actual mechanism that prevents cross-project interference
    [ "$label_a" != "$label_b" ]
}
