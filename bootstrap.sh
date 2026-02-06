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
C_RESET="\033[0m"

echo -e "${C_BOLD}${C_BLUE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Claude Docker Bootstrap"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${C_RESET}"

# Accept optional project path argument, default to $PWD
if [ -n "$1" ]; then
    if [ ! -d "$1" ]; then
        echo -e "${C_RED}Error: Directory does not exist: $1${C_RESET}"
        exit 1
    fi
    PROJECT_DIR="$(cd "$1" && pwd)" || {
        echo -e "${C_RED}Error: Cannot access directory: $1${C_RESET}"
        exit 1
    }
else
    PROJECT_DIR="$PWD"
fi
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

echo ""
echo -e "${C_BOLD}Project:${C_RESET}   $RAW_PROJECT_NAME"
echo -e "${C_BOLD}Container:${C_RESET} $CONTAINER_NAME"
echo -e "${C_BOLD}Volume:${C_RESET}    $VOLUME_NAME"
echo ""

# Clone or update repo
if [ -d "$CLONE_DIR" ]; then
    echo -e "${C_YELLOW}→${C_RESET} Updating existing .claude-dev..."
    cd "$CLONE_DIR"
    git pull --quiet
    cd ..
else
    echo -e "${C_YELLOW}→${C_RESET} Cloning Claude Docker environment..."
    git clone --quiet "$REPO_URL" "$CLONE_DIR"
fi

echo -e "${C_GREEN}✓${C_RESET} Repository ready"

# Generate docker-compose.yml from template with project-specific names
cd "$CLONE_DIR"
IMAGE_TAG="claude-code-dev:${PROJECT_NAME}"

export CONTAINER_NAME VOLUME_NAME IMAGE_TAG
sed -e "s|\${CONTAINER_NAME}|${CONTAINER_NAME}|g" \
    -e "s|\${VOLUME_NAME}|${VOLUME_NAME}|g" \
    -e "s|\${IMAGE_TAG}|${IMAGE_TAG}|g" \
    docker-compose.yml.template > docker-compose.yml

echo -e "${C_GREEN}✓${C_RESET} Generated docker-compose.yml"

# Always build — Docker layer caching makes this fast when nothing changed
echo ""
echo -e "${C_YELLOW}→${C_RESET} Building container..."
docker compose build --quiet
echo -e "${C_GREEN}✓${C_RESET} Container built"

# Record build SHA for auto-rebuild detection
git rev-parse HEAD > .last-build-sha 2>/dev/null || true

# Stop existing container if running (don't fail if it doesn't exist)
docker compose down 2>/dev/null || true

# Start container
echo -e "${C_YELLOW}→${C_RESET} Starting container..."
docker compose up -d

echo -e "${C_GREEN}✓${C_RESET} Container started"

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
