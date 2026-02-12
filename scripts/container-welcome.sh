#!/bin/bash
set -e

# Container Welcome Script
# Displays status and launches guided setup

# Colors
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RESET='\033[0m'

# State files
FIRST_TIME="/home/agent/.first-login"

# Only for interactive shells
if [ ! -t 0 ]; then
    return 2>/dev/null || exit 0
fi

# Skip welcome in tmux panes
if [ -n "$TMUX" ]; then
    return 2>/dev/null || exit 0
fi

# Only show welcome once per container start (not every docker exec / new tab)
# The session marker is in /tmp which is cleared on container restart
SESSION_MARKER="/tmp/.claude-dev-welcome-shown"
if [ -f "$SESSION_MARKER" ]; then
    # If Claude isn't authenticated, trigger auth — nothing else works without it
    if [ ! -f "/home/agent/.claude/.credentials.json" ]; then
        echo ""
        echo -e "${C_YELLOW}⚠${C_RESET}  Claude is not authenticated."
        echo -e "  Run ${C_BOLD}claude${C_RESET} and then type ${C_BOLD}/login${C_RESET} to connect."
    fi
    # Returning session — show compact command hint with project name
    echo ""
    if [ -n "$CLAUDE_PROJECT_NAME" ]; then
        echo -e "${C_BOLD}${C_BLUE}[${CLAUDE_PROJECT_NAME}]${C_RESET} ${C_DIM}Commands: ${C_RESET}${C_BOLD}menu${C_RESET}${C_DIM} (setup)  ${C_RESET}${C_BOLD}cs${C_RESET}${C_DIM} (claude)${C_RESET}"
    else
        echo -e "${C_DIM}Commands: ${C_RESET}${C_BOLD}menu${C_RESET}${C_DIM} (setup)  ${C_RESET}${C_BOLD}cs${C_RESET}${C_DIM} (claude)${C_RESET}"
    fi
    echo ""
    return 2>/dev/null || exit 0
fi
touch "$SESSION_MARKER"

# Header — show project name if available
HEADER_TITLE="Claude Dev"
if [ -n "$CLAUDE_PROJECT_NAME" ]; then
    HEADER_TITLE="${CLAUDE_PROJECT_NAME} — Claude Dev"
fi

echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo -e "${C_BOLD}  ${HEADER_TITLE}${C_RESET}"
echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo ""

# Status section
echo -e "${C_BOLD}Status:${C_RESET}"

# Claude authentication (file check only — no network call)
if [ -f "/home/agent/.claude/.credentials.json" ]; then
    echo -e "  ${C_GREEN}[✓]${C_RESET} Claude: Authenticated"
    CLAUDE_OK=true
else
    echo -e "  ${C_YELLOW}[!]${C_RESET} Claude: Not authenticated"
    CLAUDE_OK=false
fi

# Git configuration
if git config user.name &> /dev/null && git config user.email &> /dev/null; then
    echo -e "  ${C_GREEN}[✓]${C_RESET} Git: Configured ($(git config user.name))"
    GIT_OK=true
else
    echo -e "  ${C_YELLOW}[!]${C_RESET} Git: Not configured"
    GIT_OK=false
fi

# GitHub authentication (validate token with timeout)
if timeout 3 gh auth status &>/dev/null 2>&1; then
    echo -e "  ${C_GREEN}[✓]${C_RESET} GitHub: Authenticated"
    GITHUB_OK=true
elif [ -f "/home/agent/.config/gh/hosts.yml" ]; then
    echo -e "  ${C_YELLOW}[!]${C_RESET} GitHub: Token expired — run ${C_BOLD}gh auth login${C_RESET}"
    GITHUB_OK=false
else
    echo -e "  ${C_YELLOW}[!]${C_RESET} GitHub: Not authenticated"
    GITHUB_OK=false
fi

# Dependency detection (cache result to /tmp for guided-setup.sh to reuse)
DEP_COUNT=$(/usr/local/bin/detect-dependencies.sh --count 2>/dev/null || echo "0")
echo "$DEP_COUNT" > /tmp/.dep-count-cache
if [ "$DEP_COUNT" -gt 0 ]; then
    # Check if node_modules or other install indicators exist
    if [ -d "/workspace/node_modules" ] || [ -d "/workspace/venv" ] || [ -d "/workspace/.venv" ] || [ -d "/workspace/vendor" ]; then
        echo -e "  ${C_GREEN}[✓]${C_RESET} Dependencies: Installed"
        DEPS_INSTALLED=true
    else
        echo -e "  ${C_DIM}[ ]${C_RESET} Dependencies: ${DEP_COUNT} detected (not installed)"
        DEPS_INSTALLED=false
    fi
else
    DEPS_INSTALLED=true  # Nothing to install
fi

# Beads agent memory status
if command -v bd &>/dev/null; then
    if [ -d "/workspace/.beads" ]; then
        bead_count=$(cd /workspace && bd list --format count 2>/dev/null || echo "")
        if [ -n "$bead_count" ] && [ "$bead_count" -gt 0 ] 2>/dev/null; then
            echo -e "  ${C_GREEN}[✓]${C_RESET} Beads: ${bead_count} issues tracked"
        else
            echo -e "  ${C_GREEN}[✓]${C_RESET} Beads: Initialized"
        fi
    else
        echo -e "  ${C_DIM}[ ]${C_RESET} Beads: Not initialized"
    fi
fi

echo ""

# Determine if we need guided setup or quick menu
NEEDS_SETUP=false
if [ "$CLAUDE_OK" = false ] || [ "$GIT_OK" = false ]; then
    NEEDS_SETUP=true
fi

# First time users or users needing setup get the full guided experience
if [ ! -f "$FIRST_TIME" ] || [ "$NEEDS_SETUP" = true ]; then
    /usr/local/bin/guided-setup.sh
    touch "$FIRST_TIME"
else
    # Returning user: skip auth steps, go straight to menu
    /usr/local/bin/guided-setup.sh --menu-only
    echo ""
fi
