#!/bin/bash

# Claude Docker Bootstrap — Thin Installer
# Downloads the launcher and optionally starts it.
#
# First-time install (either method works):
#   curl -fsSL https://raw.githubusercontent.com/joe-rayment/claude_docker/main/bootstrap.sh | bash
#   gh api repos/joe-rayment/claude_docker/contents/bootstrap.sh -H "Accept: application/vnd.github.raw" | bash
#
# Specify a project path:
#   curl -fsSL https://raw.githubusercontent.com/joe-rayment/claude_docker/main/bootstrap.sh | bash -s -- /path/to/project

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

# Check gh CLI is installed and authenticated
if ! command -v gh &> /dev/null; then
    echo -e "${C_RED}Error: GitHub CLI (gh) is not installed${C_RESET}"
    echo "Install it with: brew install gh"
    exit 1
fi
if ! gh auth status &> /dev/null; then
    echo -e "${C_RED}Error: GitHub CLI is not authenticated${C_RESET}"
    echo "Run: gh auth login"
    exit 1
fi

echo -e "${C_GREEN}✓${C_RESET} Git is available"

# Download the launcher
echo -e "${C_YELLOW}→${C_RESET} Downloading launcher..."
if ! gh api repos/joe-rayment/claude_docker/contents/scripts/launcher.sh \
    -H "Accept: application/vnd.github.raw" > "$PROJECT_DIR/claude-dev" 2>/dev/null; then
    echo -e "${C_RED}Error: Failed to download launcher${C_RESET}"
    echo "Make sure you're authenticated with gh: gh auth status"
    exit 1
fi
chmod +x "$PROJECT_DIR/claude-dev"
echo -e "${C_GREEN}✓${C_RESET} Installed ./claude-dev"

# Add entries to project .gitignore if not already present
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
if ! grep -qxF 'attachments/' "$GITIGNORE"; then
    echo 'attachments/' >> "$GITIGNORE"
fi

# Create attachments directory for drag-and-drop files
mkdir -p "$PROJECT_DIR/attachments"

echo -e "${C_GREEN}✓${C_RESET} Updated .gitignore"

echo ""
echo -e "${C_BOLD}${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo -e "${C_BOLD}  Launcher Installed!${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo ""
echo -e "Starting Claude Docker environment..."
echo ""
exec "$PROJECT_DIR/claude-dev"
