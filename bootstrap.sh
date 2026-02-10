#!/bin/bash

# Claude Docker Bootstrap Script
# Run from any project directory with:
#   gh api repos/joe-rayment/claude_docker/contents/bootstrap.sh -H "Accept: application/vnd.github.raw" | bash
# Or specify a project path:
#   gh api repos/joe-rayment/claude_docker/contents/bootstrap.sh -H "Accept: application/vnd.github.raw" | bash -s -- /path/to/project

set -e

# Colors
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_RESET="\033[0m"

echo -e "${C_BOLD}${C_BLUE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Claude Docker Bootstrap"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${C_RESET}"

# Parse arguments
PROJECT_DIR="$PWD"

for arg in "$@"; do
    if [ -d "$arg" ]; then
        PROJECT_DIR="$(cd "$arg" && pwd)" || {
            echo -e "${C_RED}Error: Cannot access directory: $arg${C_RESET}"
            exit 1
        }
    else
        echo -e "${C_RED}Error: Directory does not exist: $arg${C_RESET}"
        exit 1
    fi
done
cd "$PROJECT_DIR"

# Check Docker is installed
if ! command -v docker &> /dev/null; then
    echo -e "${C_RED}Error: Docker is not installed${C_RESET}"
    echo "Please install Docker Desktop first:"
    echo "  macOS: brew install --cask docker"
    echo "  Linux: https://docs.docker.com/engine/install/"
    exit 1
fi

# Check Docker is running
if ! docker info &> /dev/null; then
    echo -e "${C_RED}Error: Docker is not running${C_RESET}"
    echo "Please start Docker Desktop and try again"
    exit 1
fi

echo -e "${C_GREEN}✓${C_RESET} Docker is running"

# Check git is installed
if ! command -v git &> /dev/null; then
    echo -e "${C_RED}Error: Git is not installed${C_RESET}"
    echo "Please install git first"
    exit 1
fi

echo -e "${C_GREEN}✓${C_RESET} Git is available"

# Get project name from project directory
RAW_PROJECT_NAME=$(basename "$PROJECT_DIR")

# Sanitize project name: lowercase, replace spaces/special chars with hyphens, remove consecutive hyphens
PROJECT_NAME=$(echo "$RAW_PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')

# Ensure we have a valid name
if [ -z "$PROJECT_NAME" ]; then
    PROJECT_NAME="project"
fi

CONTAINER_NAME="${PROJECT_NAME}-claude-dev"
VOLUME_NAME="${PROJECT_NAME}-agent-home"
CLONE_DIR=".claude-dev"
REPO_URL="https://github.com/joe-rayment/claude_docker.git"

# Check for container name collision with a different project
EXISTING_WORKSPACE=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)
if [ -n "$EXISTING_WORKSPACE" ] && [ "$EXISTING_WORKSPACE" != "$PROJECT_DIR" ]; then
    echo ""
    echo -e "${C_YELLOW}⚠${C_RESET}  Container '${CONTAINER_NAME}' already exists for a different project:"
    echo "   Existing: $EXISTING_WORKSPACE"
    echo "   Requested: $PROJECT_DIR"
    echo ""
    echo "   Options:"
    echo "     1. Stop the existing container first: docker stop $CONTAINER_NAME"
    echo "     2. Rename this project directory to get a unique container name"
    exit 1
fi

echo ""
echo -e "${C_BOLD}Project:${C_RESET}   $RAW_PROJECT_NAME"
echo -e "${C_BOLD}Container:${C_RESET} $CONTAINER_NAME"
echo -e "${C_BOLD}Volume:${C_RESET}    $VOLUME_NAME"
echo ""

# Clone or update repo
if [ -d "$CLONE_DIR" ]; then
    echo -e "${C_YELLOW}→${C_RESET} Updating existing .claude-dev..."
    cd "$CLONE_DIR"
    git fetch --quiet origin main
    git reset --hard origin/main --quiet
    cd ..
else
    echo -e "${C_YELLOW}→${C_RESET} Cloning Claude Docker environment..."
    git clone --quiet "$REPO_URL" "$CLONE_DIR"
fi

echo -e "${C_GREEN}✓${C_RESET} Repository ready"

# Generate docker-compose.yml from template with project-specific names
cd "$CLONE_DIR"
IMAGE_TAG="claude-code-dev:${PROJECT_NAME}"

export CONTAINER_NAME VOLUME_NAME IMAGE_TAG PROJECT_NAME
sed -e "s|\${CONTAINER_NAME}|${CONTAINER_NAME}|g" \
    -e "s|\${VOLUME_NAME}|${VOLUME_NAME}|g" \
    -e "s|\${IMAGE_TAG}|${IMAGE_TAG}|g" \
    -e "s|\${PROJECT_NAME}|${PROJECT_NAME}|g" \
    docker-compose.yml.template > docker-compose.yml

echo -e "${C_GREEN}✓${C_RESET} Generated docker-compose.yml"

# Helper: check if container is running
is_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]
}

# Helper: check if container exists (running or stopped)
container_exists() {
    docker inspect "$CONTAINER_NAME" &>/dev/null
}

# Helper: warn if active Claude sessions are running; returns 1 if user declines
warn_active_sessions() {
    if is_running; then
        local active_sessions
        active_sessions=$(docker exec "$CONTAINER_NAME" sh -c 'ps aux | grep -c "[c]laude"' 2>/dev/null || echo "0")
        if [ "$active_sessions" -gt 0 ]; then
            echo -e "${C_YELLOW}⚠${C_RESET}  ${C_BOLD}${active_sessions} active Claude session(s)${C_RESET} detected."
            echo -n "   Restart container anyway? [y/N] "
            read -r reply
            if [[ ! "$reply" =~ ^[Yy]$ ]]; then
                return 1
            fi
        fi
    fi
    return 0
}

# Capture current image ID before building (empty if image doesn't exist yet)
OLD_IMAGE_ID=$(docker image inspect "$IMAGE_TAG" --format='{{.Id}}' 2>/dev/null || echo "")

# Always build — Docker layer caching makes this fast when nothing changed
echo ""
echo -e "${C_YELLOW}→${C_RESET} Building image..."
BUILD_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
docker compose -f docker-compose.yml -p "$CONTAINER_NAME" build --quiet --build-arg BUILD_SHA="$BUILD_SHA"
echo -e "${C_GREEN}✓${C_RESET} Image built"

# Record build SHA for auto-rebuild detection
git rev-parse HEAD > .last-build-sha 2>/dev/null || true

# Compare image IDs to decide whether to restart
NEW_IMAGE_ID=$(docker image inspect "$IMAGE_TAG" --format='{{.Id}}' 2>/dev/null || echo "")

if is_running; then
    if [ "$OLD_IMAGE_ID" = "$NEW_IMAGE_ID" ]; then
        echo -e "${C_GREEN}✓${C_RESET} Container already running (image unchanged)"
    else
        echo -e "${C_YELLOW}→${C_RESET} Image changed — restart needed"
        if warn_active_sessions; then
            docker compose -f docker-compose.yml -p "$CONTAINER_NAME" down 2>/dev/null || true
            docker compose -f docker-compose.yml -p "$CONTAINER_NAME" up -d
            echo -e "${C_GREEN}✓${C_RESET} Container restarted with new image"
        else
            echo -e "${C_GREEN}✓${C_RESET} Container still running (restart skipped)"
        fi
    fi
elif container_exists; then
    echo -e "${C_YELLOW}→${C_RESET} Starting stopped container..."
    docker compose -f docker-compose.yml -p "$CONTAINER_NAME" up -d
    echo -e "${C_GREEN}✓${C_RESET} Container started"
else
    echo -e "${C_YELLOW}→${C_RESET} Starting container..."
    docker compose -f docker-compose.yml -p "$CONTAINER_NAME" up -d
    echo -e "${C_GREEN}✓${C_RESET} Container started"
fi

# Install launcher to project root
cd "$PROJECT_DIR"
cp "$CLONE_DIR/scripts/launcher.sh" "claude-dev"
chmod +x "claude-dev"
echo -e "${C_GREEN}✓${C_RESET} Installed ./claude-dev launcher"

# Add .claude-dev/ and claude-dev to project .gitignore if not already present
GITIGNORE="$PROJECT_DIR/.gitignore"
touch "$GITIGNORE"
if ! grep -qxF '.claude-dev/' "$GITIGNORE"; then
    echo '.claude-dev/' >> "$GITIGNORE"
fi
if ! grep -qxF 'claude-dev' "$GITIGNORE"; then
    echo 'claude-dev' >> "$GITIGNORE"
fi
if ! grep -qxF '.mcp.json' "$GITIGNORE"; then
    echo '.mcp.json' >> "$GITIGNORE"
fi
if ! grep -qxF '.claude/logs/' "$GITIGNORE"; then
    echo '.claude/logs/' >> "$GITIGNORE"
fi
echo -e "${C_GREEN}✓${C_RESET} Updated .gitignore"

echo ""
echo -e "${C_BOLD}${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo -e "${C_BOLD}  Container Ready!${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo ""
echo -e "Enter your container with:"
echo ""
echo -e "  ${C_BOLD}./claude-dev${C_RESET}"
echo ""
