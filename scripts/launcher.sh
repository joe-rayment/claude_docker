#!/bin/bash

# Claude Docker Launcher
# Copied to project root as ./claude-dev by bootstrap.sh
# Usage:
#   ./claude-dev            Build if needed, start if needed, exec into container
#   ./claude-dev --update   Pull latest .claude-dev/, rebuild image, re-copy launcher
#   ./claude-dev --rebuild  Force rebuild (no cache)
#   ./claude-dev --stop     Stop the container
#   ./claude-dev --status   Show container status

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
    echo "  curl -fsSL https://raw.githubusercontent.com/joe-rayment/claude_docker/main/bootstrap.sh | bash"
    exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
    echo -e "${C_RED}Error: docker-compose.yml not found at $COMPOSE_FILE${C_RESET}"
    echo "Run the bootstrap script to regenerate it."
    exit 1
fi

# Read container name from docker-compose.yml
CONTAINER_NAME=$(grep 'container_name:' "$COMPOSE_FILE" | head -1 | sed 's/.*container_name: *//' | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]')

if [ -z "$CONTAINER_NAME" ]; then
    echo -e "${C_RED}Error: Could not read container_name from $COMPOSE_FILE${C_RESET}"
    exit 1
fi

# Helper: run docker compose with the correct file
dc() {
    docker compose -f "$COMPOSE_FILE" "$@"
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
    docker image inspect claude-code-dev:latest &>/dev/null
}

# Helper: build image
build_image() {
    local extra_args="$1"
    echo -e "${C_YELLOW}→${C_RESET} Building image..."
    dc build --quiet $extra_args
    echo -e "${C_GREEN}✓${C_RESET} Image built"
}

# Helper: start container
start_container() {
    echo -e "${C_YELLOW}→${C_RESET} Starting container..."
    dc up -d
    echo -e "${C_GREEN}✓${C_RESET} Container ${C_BOLD}${CONTAINER_NAME}${C_RESET} started"
}

# Helper: exec into container
exec_into() {
    echo -e "${C_GREEN}✓${C_RESET} Entering ${C_BOLD}${CONTAINER_NAME}${C_RESET}..."
    exec docker exec -it "$CONTAINER_NAME" /bin/zsh
}

# --- Commands ---

cmd_default() {
    # Build if image doesn't exist
    if ! image_exists; then
        echo -e "${C_YELLOW}→${C_RESET} First run — building image (this may take a few minutes)..."
        build_image
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

    # Pull latest from git
    echo -e "${C_YELLOW}→${C_RESET} Pulling latest changes..."
    cd "$CLAUDE_DEV_DIR"
    git pull
    cd "$SCRIPT_DIR"

    # Rebuild image
    build_image

    # Re-copy launcher
    cp "$CLAUDE_DEV_DIR/scripts/launcher.sh" "$SCRIPT_DIR/claude-dev"
    chmod +x "$SCRIPT_DIR/claude-dev"
    echo -e "${C_GREEN}✓${C_RESET} Launcher updated"

    echo ""
    echo -e "${C_GREEN}Update complete.${C_RESET} Run ${C_BOLD}./claude-dev${C_RESET} to start."
}

cmd_rebuild() {
    echo -e "${C_BOLD}${C_BLUE}Force rebuilding image (no cache)...${C_RESET}"

    # Stop if running
    if is_running || container_exists; then
        echo -e "${C_YELLOW}→${C_RESET} Stopping container..."
        dc down 2>/dev/null || true
    fi

    build_image "--no-cache"

    echo ""
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
    if is_running; then
        echo -e "${C_BOLD}Status:${C_RESET}    ${C_GREEN}running${C_RESET}"
        echo ""
        docker ps --filter "name=$CONTAINER_NAME" --format "table {{.ID}}\t{{.Status}}\t{{.Ports}}"
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
    echo "  (none)      Build if needed, start if needed, exec into container"
    echo "  --update    Pull latest .claude-dev/, rebuild image, update launcher"
    echo "  --rebuild   Force rebuild image (no cache)"
    echo "  --stop      Stop the container"
    echo "  --status    Show container status"
    echo "  --help      Show this help"
}

# --- Main ---

case "${1:-}" in
    --update)   cmd_update ;;
    --rebuild)  cmd_rebuild ;;
    --stop)     cmd_stop ;;
    --status)   cmd_status ;;
    --help|-h)  cmd_help ;;
    "")         cmd_default ;;
    *)
        echo -e "${C_RED}Unknown option: $1${C_RESET}"
        cmd_help
        exit 1
        ;;
esac
