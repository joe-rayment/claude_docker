#!/bin/bash

# Claude Docker Launcher
# Copied to project root as ./claude-dev by bootstrap.sh
# Usage:
#   ./claude-dev              Build if needed, start if needed, exec into container
#   ./claude-dev --update     Pull latest .claude-dev/, rebuild image, re-copy launcher
#   ./claude-dev --rebuild    Force rebuild (no cache)
#   ./claude-dev --stop       Stop the container
#   ./claude-dev --status     Show container status

set -e

# Colors
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_BOLD="\033[1m"
C_RESET="\033[0m"

# Self-discover paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DEV_DIR="$SCRIPT_DIR/.claude-dev"
COMPOSE_FILE="$CLAUDE_DEV_DIR/docker-compose.yml"

# Validate .claude-dev/ exists
if [ ! -d "$CLAUDE_DEV_DIR" ]; then
    echo -e "${C_RED}Error: .claude-dev/ not found at $CLAUDE_DEV_DIR${C_RESET}"
    echo "Run the bootstrap script first:"
    echo "  gh api repos/joe-rayment/claude_docker/contents/bootstrap.sh -H 'Accept: application/vnd.github.raw' | bash"
    exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
    echo -e "${C_RED}Error: docker-compose.yml not found at $COMPOSE_FILE${C_RESET}"
    echo "Run the bootstrap script to regenerate it."
    exit 1
fi

# Read container name and image tag from docker-compose.yml
CONTAINER_NAME=$(grep 'container_name:' "$COMPOSE_FILE" | head -1 | sed 's/.*container_name: *//' | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]')
IMAGE_TAG=$(grep '^\s*image:' "$COMPOSE_FILE" | head -1 | sed 's/.*image: *//' | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]')

if [ -z "$CONTAINER_NAME" ]; then
    echo -e "${C_RED}Error: Could not read container_name from $COMPOSE_FILE${C_RESET}"
    exit 1
fi

IMAGE_TAG="${IMAGE_TAG:-claude-code-dev:latest}"

# Helper: run docker compose with the correct file and project name.
# The -p flag ensures compose operations are scoped to THIS project only,
# preventing one project's compose commands from tearing down another's containers.
# (Without -p, the project name defaults to the directory name "claude-dev",
# which is the same for every project.)
dc() {
    docker compose -f "$COMPOSE_FILE" -p "$CONTAINER_NAME" "$@"
}

# Helper: check if container is running
is_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]
}

# Helper: check if container exists (running or stopped)
container_exists() {
    docker inspect "$CONTAINER_NAME" &>/dev/null
}

# Helper: check if image exists
image_exists() {
    docker image inspect "$IMAGE_TAG" &>/dev/null
}

# Helper: record the current git SHA after a successful build
record_build_sha() {
    git -C "$CLAUDE_DEV_DIR" rev-parse HEAD > "$CLAUDE_DEV_DIR/.last-build-sha" 2>/dev/null || true
}

# Helper: check if repo has changed since last build
repo_has_changed() {
    local current_sha last_build_sha
    current_sha=$(git -C "$CLAUDE_DEV_DIR" rev-parse HEAD 2>/dev/null) || return 1
    last_build_sha=$(cat "$CLAUDE_DEV_DIR/.last-build-sha" 2>/dev/null) || return 0
    [ "$current_sha" != "$last_build_sha" ]
}

# Helper: check for upstream updates (rate-limited, silent on failure)
check_for_updates() {
    local check_file="$CLAUDE_DEV_DIR/.last-update-check"
    local check_interval=14400  # 4 hours

    # Rate limit
    if [ -f "$check_file" ]; then
        local last_check now
        last_check=$(cat "$check_file" 2>/dev/null || echo "0")
        now=$(date +%s)
        if [ $((now - last_check)) -lt $check_interval ]; then
            return 0
        fi
    fi

    date +%s > "$check_file" 2>/dev/null || true

    # Fetch silently with 5s timeout — skip on slow/offline networks
    local fetch_ok=false
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 git -C "$CLAUDE_DEV_DIR" fetch --quiet 2>/dev/null && fetch_ok=true
    else
        # Fallback: background fetch with manual kill
        ( git -C "$CLAUDE_DEV_DIR" fetch --quiet 2>/dev/null & GIT_PID=$!
          ( sleep 5 && kill "$GIT_PID" 2>/dev/null ) &
          wait "$GIT_PID" 2>/dev/null
        ) && fetch_ok=true
    fi
    if ! $fetch_ok; then
        return 0
    fi

    local local_sha remote_sha
    local_sha=$(git -C "$CLAUDE_DEV_DIR" rev-parse HEAD 2>/dev/null) || return 0
    remote_sha=$(git -C "$CLAUDE_DEV_DIR" rev-parse origin/main 2>/dev/null) || return 0

    if [ "$local_sha" != "$remote_sha" ]; then
        if git -C "$CLAUDE_DEV_DIR" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
            echo ""
            echo -e "  ${C_YELLOW}Update available${C_RESET} — run ${C_BOLD}./claude-dev --update${C_RESET} to get the latest environment"
            echo ""
        fi
    fi
}

# Helper: warn if active Claude sessions are running; returns 1 if user declines teardown
warn_active_sessions() {
    if is_running; then
        local active_sessions
        active_sessions=$(docker exec "$CONTAINER_NAME" sh -c 'ps aux | grep -c "[c]laude"' 2>/dev/null || echo "0")
        if [ "$active_sessions" -gt 0 ]; then
            echo -e "${C_YELLOW}⚠${C_RESET}  ${C_BOLD}${active_sessions} active Claude session(s)${C_RESET} detected in ${CONTAINER_NAME}."
            echo -n "   Tear down container anyway? [y/N] "
            read -r reply
            if [[ ! "$reply" =~ ^[Yy]$ ]]; then
                echo -e "   ${C_YELLOW}Aborted.${C_RESET}"
                return 1
            fi
        fi
    fi
    return 0
}

# Helper: build image
build_image() {
    local extra_args=()
    if [ -n "$1" ]; then
        extra_args+=("$1")
    fi
    local build_sha
    build_sha=$(git -C "$CLAUDE_DEV_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    echo -e "${C_YELLOW}→${C_RESET} Building image..."
    dc build --quiet --build-arg BUILD_SHA="$build_sha" "${extra_args[@]}"
    echo -e "${C_GREEN}✓${C_RESET} Image built"
}

# Helper: start container
start_container() {
    echo -e "${C_YELLOW}→${C_RESET} Starting container..."
    dc up -d
    echo -e "${C_GREEN}✓${C_RESET} Container ${C_BOLD}${CONTAINER_NAME}${C_RESET} started"
}

# Helper: exec into container
# If a tmux session is running (from the entrypoint), attach to it.
# This puts the user into the same tmux session where agent panes live.
# Retries briefly in case the container just started and the entrypoint
# hasn't reached the tmux startup line yet.
exec_into() {
    echo -e "${C_GREEN}✓${C_RESET} Entering ${C_BOLD}${CONTAINER_NAME}${C_RESET}..."
    # Retry briefly: the entrypoint may not have reached tmux startup yet.
    # 8 attempts × 0.3s = ~2.4s max wait (enough for entrypoint to finish).
    local attempts=0
    while [ $attempts -lt 8 ]; do
        if docker exec "$CONTAINER_NAME" tmux has-session -t main 2>/dev/null; then
            exec docker exec -it "$CONTAINER_NAME" tmux attach-session -t main
        fi
        sleep 0.3
        attempts=$((attempts + 1))
    done
    # Fallback: tmux not available (opt-out, config error, etc.)
    exec docker exec -it "$CONTAINER_NAME" /bin/zsh
}

# --- Commands ---

cmd_default() {
    check_for_updates

    # Build if image doesn't exist, or rebuild if repo has changed
    if ! image_exists; then
        echo -e "${C_YELLOW}→${C_RESET} First run — building image (this may take a few minutes)..."
        build_image
        record_build_sha
    elif repo_has_changed; then
        # Check for active sessions before tearing down the container
        if warn_active_sessions; then
            echo -e "${C_YELLOW}→${C_RESET} Environment updated — rebuilding image..."
            if is_running || container_exists; then
                dc down 2>/dev/null || true
            fi
            build_image
            record_build_sha
        fi
        # If warn_active_sessions returned 1 (user declined), skip rebuild and just exec in
    fi

    # Start if not running
    if ! is_running; then
        # If container exists but stopped, remove it first for clean start
        if container_exists; then
            dc down 2>/dev/null || true
        fi
        start_container
    else
        echo -e "${C_GREEN}✓${C_RESET} Container ${C_BOLD}${CONTAINER_NAME}${C_RESET} already running"
    fi

    exec_into
}

cmd_update() {
    echo -e "${C_BOLD}${C_BLUE}Updating claude-dev environment...${C_RESET}"

    # Check for active sessions before tearing down
    if ! warn_active_sessions; then
        return 0
    fi

    # Pull latest from git (reset to match upstream; .claude-dev/ is a managed clone)
    echo -e "${C_YELLOW}→${C_RESET} Pulling latest changes..."
    git -C "$CLAUDE_DEV_DIR" fetch --quiet origin main
    git -C "$CLAUDE_DEV_DIR" reset --hard --quiet origin/main

    # Regenerate docker-compose.yml from updated template (picks up fixes like project name scoping)
    if [ -f "$CLAUDE_DEV_DIR/docker-compose.yml.template" ]; then
        local volume_name
        volume_name=$(grep -A1 '^volumes:' "$COMPOSE_FILE" 2>/dev/null | tail -1 | sed 's/:.*//' | tr -d '[:space:]')
        local project_name
        project_name=$(echo "$CONTAINER_NAME" | sed 's/-claude-dev$//')
        volume_name="${volume_name:-${project_name}-agent-home}"
        sed -e "s|\${CONTAINER_NAME}|${CONTAINER_NAME}|g" \
            -e "s|\${VOLUME_NAME}|${volume_name}|g" \
            -e "s|\${IMAGE_TAG}|${IMAGE_TAG}|g" \
            -e "s|\${PROJECT_NAME}|${project_name}|g" \
            "$CLAUDE_DEV_DIR/docker-compose.yml.template" > "$COMPOSE_FILE"
        echo -e "${C_GREEN}✓${C_RESET} Regenerated docker-compose.yml"
    fi

    # Rebuild image
    build_image
    record_build_sha

    # Re-copy launcher
    cp "$CLAUDE_DEV_DIR/scripts/launcher.sh" "$SCRIPT_DIR/claude-dev"
    chmod +x "$SCRIPT_DIR/claude-dev"
    echo -e "${C_GREEN}✓${C_RESET} Launcher updated"

    # Stop old container so next ./claude-dev creates fresh one from new image
    if is_running || container_exists; then
        echo -e "${C_YELLOW}→${C_RESET} Stopping old container..."
        dc down 2>/dev/null || true
    fi

    echo ""
    echo -e "\033[2mNote: Auth, git config, and history are preserved in the volume.\033[0m"
    echo -e "${C_GREEN}✓ Update complete${C_RESET}"

    # Start fresh container and exec in
    start_container
    exec_into
}

cmd_rebuild() {
    echo -e "${C_BOLD}${C_BLUE}Force rebuilding image (no cache)...${C_RESET}"

    # Check for active sessions before tearing down
    if ! warn_active_sessions; then
        return 0
    fi

    # Stop if running
    if is_running || container_exists; then
        echo -e "${C_YELLOW}→${C_RESET} Stopping container..."
        dc down 2>/dev/null || true
    fi

    build_image "--no-cache"
    record_build_sha

    echo ""
    echo -e "\033[2mNote: Auth, git config, and history are preserved in the volume.\033[0m"
    echo -e "${C_GREEN}Rebuild complete.${C_RESET} Run ${C_BOLD}./claude-dev${C_RESET} to start."
}

cmd_stop() {
    if is_running || container_exists; then
        echo -e "${C_YELLOW}→${C_RESET} Stopping container..."
        dc down
        echo -e "${C_GREEN}✓${C_RESET} Container stopped"
    else
        echo -e "${C_YELLOW}Container is not running${C_RESET}"
    fi
}

cmd_status() {
    echo -e "${C_BOLD}Container:${C_RESET} $CONTAINER_NAME"
    local build_sha
    build_sha=$(docker inspect --format='{{index .Config.Labels "build.sha"}}' "$IMAGE_TAG" 2>/dev/null || echo "unknown")
    echo -e "${C_BOLD}Build SHA:${C_RESET} $build_sha"
    if is_running; then
        HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "no healthcheck")
        echo -e "${C_BOLD}Status:${C_RESET}    ${C_GREEN}running${C_RESET} (health: $HEALTH)"
        echo ""
        docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.ID}}\t{{.Status}}\t{{.Ports}}"
    elif container_exists; then
        echo -e "${C_BOLD}Status:${C_RESET}    ${C_YELLOW}stopped${C_RESET}"
    else
        echo -e "${C_BOLD}Status:${C_RESET}    ${C_RED}not created${C_RESET}"
    fi
}

cmd_help() {
    echo -e "${C_BOLD}Claude Docker Launcher${C_RESET}"
    echo ""
    echo "Usage: ./claude-dev [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  (none)       Build if needed, start if needed, exec into container"
    echo "  --update     Pull latest .claude-dev/, rebuild image, update launcher"
    echo "  --rebuild    Force rebuild image (no cache)"
    echo "  --stop       Stop the container"
    echo "  --status     Show container status"
    echo "  --help       Show this help"
}

# --- Main ---

case "${1:-}" in
    --update)     cmd_update ;;
    --rebuild)    cmd_rebuild ;;
    --stop)       cmd_stop ;;
    --status)     cmd_status ;;
    --help|-h)    cmd_help ;;
    "")           cmd_default ;;
    *)
        echo -e "${C_RED}Unknown option: $1${C_RESET}"
        cmd_help
        exit 1
        ;;
esac
