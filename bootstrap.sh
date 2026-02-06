#!/bin/bash

# Claude Docker Bootstrap Script
# Run from any project directory with:
#   curl -fsSL https://raw.githubusercontent.com/joe-rayment/claude_docker/main/bootstrap.sh | bash
# Or specify a project path:
#   curl -fsSL https://raw.githubusercontent.com/joe-rayment/claude_docker/main/bootstrap.sh | bash -s -- /path/to/project

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

# Generate docker-compose.yml with dynamic names
cd "$CLONE_DIR"

cat > docker-compose.yml <<EOF
services:
  claude-dev:
    build:
      context: .
      dockerfile: Dockerfile
    image: claude-code-dev:latest
    container_name: ${CONTAINER_NAME}

    # Interactive terminal
    stdin_open: true
    tty: true

    # Volume mounts
    volumes:
      # Mount your project as workspace
      - ../:/workspace
      # Persistent home directory (includes .claude, .gitconfig, .zsh_history, etc.)
      - ${VOLUME_NAME}:/home/agent

    # Network configuration
    network_mode: bridge

    # Working directory
    working_dir: /workspace

    # Health check
    healthcheck:
      test: ["CMD-SHELL", "claude auth status 2>/dev/null || exit 1"]
      interval: 60s
      timeout: 10s
      retries: 2
      start_period: 30s

    # Keep container running
    command: /bin/zsh

volumes:
  ${VOLUME_NAME}:
    driver: local
EOF

echo -e "${C_GREEN}✓${C_RESET} Generated docker-compose.yml"

# Check if image exists
if ! docker image inspect claude-code-dev:latest &> /dev/null; then
    echo ""
    echo -e "${C_YELLOW}→${C_RESET} Building container (first time, this may take a few minutes)..."
    docker compose build --quiet
    echo -e "${C_GREEN}✓${C_RESET} Container built"
else
    echo -e "${C_GREEN}✓${C_RESET} Using existing image"
fi

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
