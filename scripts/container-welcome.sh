#!/bin/bash

# Colors
C_RED="\e[31m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_BLUE="\e[34m"
C_BOLD="\e[1m"
C_RESET="\e[0m"

# State files
RALPH_READY="/home/agent/.ralph-ready"
FIRST_TIME="/home/agent/.first-login"

# Only for interactive shells
if [ ! -t 0 ]; then
    return 2>/dev/null || exit 0
fi

# Header
if command -v figlet &> /dev/null; then
    echo -e "${C_BLUE}$(figlet -f slant 'Claude Dev' 2>/dev/null || echo 'Claude Development Container')${C_RESET}"
else
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_BOLD}  Claude Code Development Container${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
fi
echo ""

# Check Ralph setup status
if [ -f "$RALPH_READY" ]; then
    echo -e "${C_GREEN}✓${C_RESET} Ralph Wiggum: ${C_BOLD}Ready${C_RESET}"
else
    echo -e "${C_YELLOW}⚠${C_RESET} Ralph Wiggum: ${C_BOLD}Not Configured${C_RESET}"
    echo -e "  Run: ${C_BOLD}setup-ralph${C_RESET} to configure"
fi

# Check git authentication
if git config user.name &> /dev/null; then
    echo -e "${C_GREEN}✓${C_RESET} Git: Configured ($(git config user.name))"
else
    echo -e "${C_YELLOW}⚠${C_RESET} Git: Not configured"
    echo -e "  Run: ${C_BOLD}git config --global user.name \"Your Name\"${C_RESET}"
fi

# Check Claude authentication
if [ -f "/home/agent/.claude/credentials" ] || claude auth status &>/dev/null; then
    echo -e "${C_GREEN}✓${C_RESET} Claude: Authenticated"
else
    echo -e "${C_YELLOW}⚠${C_RESET} Claude: Not authenticated"
    echo -e "  Run: ${C_BOLD}claude auth login${C_RESET}"
fi

echo ""

# First time detailed instructions
if [ ! -f "$FIRST_TIME" ]; then
    cat <<EOF
${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}
  ${C_BOLD}First Time Setup${C_RESET}
${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}

${C_BOLD}Setup Order (DO IN THIS ORDER):${C_RESET}

${C_YELLOW}1.${C_RESET} Authenticate with Claude:
   ${C_BOLD}claude auth login${C_RESET}

${C_YELLOW}2.${C_RESET} Configure Git:
   ${C_BOLD}git config --global user.name "Your Name"${C_RESET}
   ${C_BOLD}git config --global user.email "your@email.com"${C_RESET}

${C_YELLOW}3.${C_RESET} Setup Ralph Wiggum (for autonomous development):
   ${C_BOLD}setup-ralph${C_RESET}

${C_YELLOW}4.${C_RESET} Start coding:
   ${C_BOLD}cs${C_RESET}    (Quick start Claude, skip permissions)
   ${C_BOLD}csd${C_RESET}   (With debug logging)

${C_BOLD}Quick Commands:${C_RESET}
  ${C_BOLD}cs${C_RESET}            - Start Claude quickly
  ${C_BOLD}setup-ralph${C_RESET}   - Setup Ralph Wiggum plugin
  ${C_BOLD}view-logs${C_RESET}     - View/export Claude logs
  ${C_BOLD}clog-latest${C_RESET}   - Quick peek at latest log

${C_BOLD}IntelliShell Shortcuts:${C_RESET}
  ${C_BOLD}Ctrl+Space${C_RESET}   - Search saved commands
  ${C_BOLD}Ctrl+B${C_RESET}       - Bookmark current command

${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}
EOF
    touch "$FIRST_TIME"
else
    # Returning user - brief message
    echo -e "${C_BOLD}Quick Start:${C_RESET} ${C_BOLD}cs${C_RESET} (Claude), ${C_BOLD}setup-ralph${C_RESET} (Ralph setup), ${C_BOLD}view-logs${C_RESET} (Logs)"
fi

echo ""
