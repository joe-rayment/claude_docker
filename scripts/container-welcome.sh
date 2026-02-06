#!/bin/bash

# Container Welcome Script
# Displays status and launches guided setup

# Colors
C_RED="\e[31m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_BLUE="\e[34m"
C_BOLD="\e[1m"
C_DIM="\e[2m"
C_RESET="\e[0m"

# State files
FIRST_TIME="/home/agent/.first-login"

# Only for interactive shells
if [ ! -t 0 ]; then
    return 2>/dev/null || exit 0
fi

# Skip welcome in tmux panes (e.g., ralph --monitor)
if [ -n "$TMUX" ]; then
    return 2>/dev/null || exit 0
fi

# Only show welcome once per container start (not every docker exec / new tab)
# The session marker is in /tmp which is cleared on container restart
SESSION_MARKER="/tmp/.claude-dev-welcome-shown"
if [ -f "$SESSION_MARKER" ]; then
    return 2>/dev/null || exit 0
fi
touch "$SESSION_MARKER"

# Header
if command -v figlet &> /dev/null; then
    echo -e "${C_BLUE}$(figlet -f slant 'Claude Dev' 2>/dev/null || echo 'Claude Development Container')${C_RESET}"
else
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_BOLD}  Claude Code Development Container${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
fi
echo ""

# Status section
echo -e "${C_BOLD}Status:${C_RESET}"

# Claude authentication (file check only — no network call)
if [ -f "/home/agent/.claude/credentials" ]; then
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

# GitHub authentication (file check only — no network call)
if [ -f "/home/agent/.config/gh/hosts.yml" ]; then
    echo -e "  ${C_GREEN}[✓]${C_RESET} GitHub: Authenticated"
    GITHUB_OK=true
else
    echo -e "  ${C_YELLOW}[!]${C_RESET} GitHub: Not authenticated"
    GITHUB_OK=false
fi

# Ralph status (check for .ralph/PROMPT.md)
if [ -f "/workspace/.ralph/PROMPT.md" ]; then
    echo -e "  ${C_GREEN}[✓]${C_RESET} Ralph: Initialized"
    RALPH_OK=true
else
    echo -e "  ${C_DIM}[ ]${C_RESET} Ralph: Not initialized ${C_DIM}(optional)${C_RESET}"
    RALPH_OK=false
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
    # Returning user — just show a hint, no disappearing menu
    echo -e "${C_DIM}Commands: ${C_RESET}${C_BOLD}menu${C_RESET}${C_DIM} (setup)  ${C_RESET}${C_BOLD}cs${C_RESET}${C_DIM} (claude)  ${C_RESET}${C_BOLD}ralph-run${C_RESET}${C_DIM} (ralph loop)${C_RESET}"
    echo ""
fi
