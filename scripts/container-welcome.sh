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
    echo -e "${C_GREEN}✓${C_RESET} Ralph Wiggum: ${C_BOLD}Ready${C_RESET} (simple bash loop)"
else
    echo -e "${C_YELLOW}⚠${C_RESET} Ralph Wiggum: ${C_BOLD}Not Configured${C_RESET}"
    echo -e "  Run: ${C_BOLD}ralph-init${C_RESET} to set up"
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

${C_BOLD}Setup Order:${C_RESET}

${C_YELLOW}1.${C_RESET} Authenticate with Claude:
   ${C_BOLD}claude auth login${C_RESET}

${C_YELLOW}2.${C_RESET} Configure Git:
   ${C_BOLD}git config --global user.name "Your Name"${C_RESET}
   ${C_BOLD}git config --global user.email "your@email.com"${C_RESET}

${C_YELLOW}3.${C_RESET} Start coding:
   ${C_BOLD}cs${C_RESET}    (Start Claude, skip permissions)
   ${C_BOLD}csd${C_RESET}   (With debug logging)

${C_BOLD}Ralph Wiggum (Autonomous Development):${C_RESET}

${C_YELLOW}1.${C_RESET} Initialize:  ${C_BOLD}ralph-init${C_RESET}
${C_YELLOW}2.${C_RESET} Edit spec:   ${C_BOLD}ralph-spec${C_RESET}   (or hx SPEC.md)
${C_YELLOW}3.${C_RESET} Plan:        ${C_BOLD}cs${C_RESET}           (bidirectional planning with Claude)
${C_YELLOW}4.${C_RESET} Edit plan:   ${C_BOLD}ralph-plan${C_RESET}   (or hx PLAN.md)
${C_YELLOW}5.${C_RESET} Commit:      ${C_BOLD}git add -A && git commit -m "checkpoint"${C_RESET}
${C_YELLOW}6.${C_RESET} Run loop:    ${C_BOLD}ralph -n 10${C_RESET}  (10 iterations)

${C_BOLD}Key Principle:${C_RESET} Fresh context each iteration. The spec is truth.

${C_BOLD}IntelliShell:${C_RESET}
  ${C_BOLD}Ctrl+Space${C_RESET}   Search saved commands
  ${C_BOLD}Ctrl+B${C_RESET}       Bookmark current command

${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}
EOF
    touch "$FIRST_TIME"
else
    # Returning user - brief message
    echo -e "${C_BOLD}Quick Start:${C_RESET}"
    echo -e "  ${C_BOLD}cs${C_RESET}           Start Claude"
    echo -e "  ${C_BOLD}ralph -n 10${C_RESET}  Run autonomous loop (10 iterations)"
    echo -e "  ${C_BOLD}ralph-init${C_RESET}   Set up Ralph for a project"
    echo -e "  ${C_BOLD}view-logs${C_RESET}    View Claude logs"
fi

echo ""
