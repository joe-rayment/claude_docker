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

# Skip welcome in tmux teammate panes (but show in the primary pane).
# The entrypoint auto-starts tmux, so $TMUX is always set.
# Only show welcome in pane 1 of window 1 (the user's main pane).
if [ -n "$TMUX" ]; then
    _pane_idx=$(tmux display-message -p '#{pane_index}' 2>/dev/null || echo "1")
    _win_idx=$(tmux display-message -p '#{window_index}' 2>/dev/null || echo "1")
    if [ "$_win_idx" != "1" ] || [ "$_pane_idx" != "1" ]; then
        return 2>/dev/null || exit 0
    fi
    unset _pane_idx _win_idx
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
if command -v bd &>/dev/null && command -v dolt &>/dev/null; then
    if [ -d "/workspace/.beads" ] && [ -f "/workspace/.beads/metadata.json" ]; then
        # Beads is configured — ensure Dolt server is running, then check status
        if ! timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/3307" 2>/dev/null; then
            /usr/local/bin/start-dolt >/dev/null 2>&1 || true
        fi
        if timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/3307" 2>/dev/null; then
            bead_count=$(cd /workspace && bd list --format count 2>/dev/null)
            bead_count="${bead_count:-0}"  # empty means 0 issues
            if [ "$bead_count" -gt 0 ] 2>/dev/null; then
                echo -e "  ${C_GREEN}[✓]${C_RESET} Beads: ${bead_count} issues tracked"
            else
                echo -e "  ${C_GREEN}[✓]${C_RESET} Beads: Initialized"
            fi
            BEADS_OK=true
        else
            echo -e "  ${C_YELLOW}[!]${C_RESET} Beads: Dolt server not ready — run ${C_BOLD}start-dolt${C_RESET}"
            if [ -s /tmp/.dolt-server.log ]; then
                echo -e "        ${C_DIM}$(tail -1 /tmp/.dolt-server.log)${C_RESET}"
            fi
            BEADS_OK=false
        fi
    else
        echo -e "  ${C_DIM}[ ]${C_RESET} Beads: Not initialized — run ${C_BOLD}menu${C_RESET} to set up"
        BEADS_OK=false
    fi
else
    BEADS_OK=true  # bd/dolt not available, nothing to set up
fi

echo ""

# Determine if we need guided setup or quick menu
NEEDS_SETUP=false
if [ "$CLAUDE_OK" = false ] || [ "$GIT_OK" = false ] || [ "$BEADS_OK" = false ]; then
    NEEDS_SETUP=true
fi

# First time users or users needing setup get the full guided experience
if [ ! -f "$FIRST_TIME" ] || [ "$NEEDS_SETUP" = true ]; then
    # Create marker BEFORE setup so Ctrl+C doesn't cause the first-time
    # flow to re-trigger on every subsequent container start.
    # If setup fails for a real reason (not user interrupt), remove the
    # marker so the user gets another chance on next start.
    touch "$FIRST_TIME"
    _setup_rc=0
    /usr/local/bin/guided-setup.sh || _setup_rc=$?
    # 130 = SIGINT (Ctrl+C), 0 = success — keep the marker
    # Anything else = real failure — remove marker to allow retry
    if [ "$_setup_rc" -ne 0 ] && [ "$_setup_rc" -ne 130 ]; then
        rm -f "$FIRST_TIME"
    fi
    unset _setup_rc
else
    # Returning user: skip auth steps, go straight to menu
    /usr/local/bin/guided-setup.sh --menu-only
    echo ""
fi
