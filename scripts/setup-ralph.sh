#!/bin/bash
#
# Ralph Wiggum Setup Wizard
#
# Sets up the simple bash loop approach to Ralph Wiggum.
# No plugins required - just a spec file and the ralph command.
#

# Colors
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_BLUE="\e[34m"
C_BOLD="\e[1m"
C_RESET="\e[0m"

# State tracking
RALPH_READY="/home/agent/.ralph-ready"

echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo -e "${C_BOLD}  Ralph Wiggum Setup Wizard${C_RESET}"
echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo ""
echo "This sets up Ralph Wiggum - the simple bash loop approach."
echo "No plugins needed. Just a spec file and fresh context each iteration."
echo ""

# Step 1: Check we're in a valid project directory
echo -e "${C_BOLD}[Step 1/4]${C_RESET} Checking project directory..."

if [ ! -d "/workspace" ]; then
    echo -e "${C_YELLOW}⚠${C_RESET} Not in workspace. Changing to /workspace..."
    cd /workspace
fi

# Initialize git if needed
if [ ! -d ".git" ]; then
    echo -e "${C_YELLOW}⚠${C_RESET} Not a git repository. Initializing..."
    git init
    echo -e "${C_GREEN}✓${C_RESET} Git repository initialized"
else
    echo -e "${C_GREEN}✓${C_RESET} Git repository exists"
fi

# Step 2: Create SPEC.md if needed
echo ""
echo -e "${C_BOLD}[Step 2/4]${C_RESET} Setting up spec file..."

if [ -f "SPEC.md" ]; then
    echo -e "${C_BLUE}ℹ${C_RESET} SPEC.md already exists - keeping it"
else
    if [ -f "/home/agent/.config/SPEC.md.template" ]; then
        cp /home/agent/.config/SPEC.md.template SPEC.md
    else
        cat > SPEC.md << 'EOF'
# Project Specification

## Context

[What is this project? What problem does it solve?]

## Requirements

1. [Specific requirement]
2. [Another requirement]

## Technical Constraints

```
Build:  [your build command]
Test:   [your test command]
Lint:   [your lint command]
```

## Completion Criteria

- [ ] All requirements implemented
- [ ] All tests pass
- [ ] No lint errors

## Current Task

See PLAN.md for implementation tasks.

---

**INSTRUCTIONS FOR CLAUDE:**

1. Read PLAN.md for the next unchecked task
2. Complete ONE task
3. Mark it complete in PLAN.md
4. Exit

If all tasks done and criteria met, output "TASK COMPLETE".
EOF
    fi
    echo -e "${C_GREEN}✓${C_RESET} Created SPEC.md"
fi

# Step 3: Create PLAN.md if needed
echo ""
echo -e "${C_BOLD}[Step 3/4]${C_RESET} Setting up plan file..."

if [ -f "PLAN.md" ]; then
    echo -e "${C_BLUE}ℹ${C_RESET} PLAN.md already exists - keeping it"
else
    if [ -f "/home/agent/.config/PLAN.md.template" ]; then
        cp /home/agent/.config/PLAN.md.template PLAN.md
    else
        cat > PLAN.md << 'EOF'
# Implementation Plan

## Current Phase

[Phase name]

## Tasks

- [ ] Task 1: [Specific task]
- [ ] Task 2: [Another task]

## Completed

- [x] Set up Ralph Wiggum

---

Complete ONE task per iteration. Mark done when complete.
EOF
    fi
    echo -e "${C_GREEN}✓${C_RESET} Created PLAN.md"
fi

# Step 4: Done
echo ""
echo -e "${C_BOLD}[Step 4/4]${C_RESET} Setup complete!"
echo ""
echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo -e "${C_GREEN}✓ Ralph Wiggum is ready${C_RESET}"
echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo ""
echo -e "${C_BOLD}The Workflow:${C_RESET}"
echo ""
echo -e "  ${C_YELLOW}1.${C_RESET} Edit your spec:        ${C_BOLD}hx SPEC.md${C_RESET}"
echo -e "  ${C_YELLOW}2.${C_RESET} Plan with Claude:      ${C_BOLD}cs${C_RESET}  (bidirectional planning)"
echo -e "  ${C_YELLOW}3.${C_RESET} Edit your plan:        ${C_BOLD}hx PLAN.md${C_RESET}"
echo -e "  ${C_YELLOW}4.${C_RESET} Commit (checkpoint):   ${C_BOLD}git add -A && git commit -m \"Before Ralph\"${C_RESET}"
echo -e "  ${C_YELLOW}5.${C_RESET} Run Ralph:             ${C_BOLD}ralph -n 10${C_RESET}"
echo -e "  ${C_YELLOW}6.${C_RESET} Review:                ${C_BOLD}git diff${C_RESET}"
echo ""
echo -e "${C_BOLD}Key Principles:${C_RESET}"
echo ""
echo -e "  • ${C_BOLD}Fresh context${C_RESET} - Each iteration starts clean"
echo -e "  • ${C_BOLD}Spec is truth${C_RESET} - Not conversation history"
echo -e "  • ${C_BOLD}You own it${C_RESET}    - Read every line of your spec"
echo -e "  • ${C_BOLD}Keep it small${C_RESET} - Leave room for implementation"
echo ""
echo -e "${C_BOLD}Quick Commands:${C_RESET}"
echo ""
echo -e "  ${C_BOLD}ralph -n 10${C_RESET}      Run 10 iterations"
echo -e "  ${C_BOLD}ralph --help${C_RESET}    Show all options"
echo -e "  ${C_BOLD}ralph-spec${C_RESET}      Edit SPEC.md"
echo -e "  ${C_BOLD}ralph-plan${C_RESET}      Edit PLAN.md"
echo ""

touch "$RALPH_READY"
echo "$(date)" >> "$RALPH_READY"
