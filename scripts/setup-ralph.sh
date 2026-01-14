#!/bin/bash

# Colors
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_BLUE="\e[34m"
C_BOLD="\e[1m"
C_RESET="\e[0m"

# State tracking
STATE_DIR="/home/agent/.ralph-setup"
RALPH_READY="/home/agent/.ralph-ready"
mkdir -p "$STATE_DIR"

echo -e "${C_BOLD}${C_BLUE}Ralph Wiggum Setup Wizard${C_RESET}"
echo ""

# Step 1: Check jq
echo -e "${C_BOLD}[Step 1/6]${C_RESET} Checking prerequisites..."
if ! command -v jq &> /dev/null; then
    echo -e "${C_YELLOW}⚠${C_RESET} jq not found (should be installed in container)"
    echo "Contact administrator if this persists"
    exit 1
fi
echo -e "${C_GREEN}✓${C_RESET} jq installed"

# Step 2: Initialize git if needed
echo ""
echo -e "${C_BOLD}[Step 2/6]${C_RESET} Checking git repository..."
if [ ! -d "/workspace/.git" ]; then
    echo -e "${C_YELLOW}⚠${C_RESET} Not a git repository. Initializing..."
    cd /workspace
    git init
    echo -e "${C_GREEN}✓${C_RESET} Git repository initialized"
else
    echo -e "${C_GREEN}✓${C_RESET} Git repository exists"
fi

# Step 3: Install Ralph plugin
echo ""
echo -e "${C_BOLD}[Step 3/6]${C_RESET} Installing Ralph Wiggum plugin..."
echo "This will start Claude Code briefly to install the plugin."
echo ""
read -p "Press Enter to continue..."

# Create temporary command file
cat > /tmp/install-ralph.txt <<'EOF'
/plugin marketplace add anthropics/claude-code
/plugin install ralph-wiggum@claude-plugins-official
/exit
EOF

echo "Starting Claude Code to install plugin..."
claude < /tmp/install-ralph.txt 2>&1 | grep -E "(Installing|Installed|Success|Error)" || true
rm /tmp/install-ralph.txt

echo -e "${C_GREEN}✓${C_RESET} Plugin installation complete"

# Step 4: Create CLAUDE.md if not exists
echo ""
echo -e "${C_BOLD}[Step 4/6]${C_RESET} Setting up project files..."
if [ ! -f "/workspace/CLAUDE.md" ]; then
    cp /home/agent/.config/CLAUDE.md.template /workspace/CLAUDE.md 2>/dev/null || cat > /workspace/CLAUDE.md <<'EOF'
# Project Context for Claude Code

## Build & Test Commands
- Build: npm run build
- Test: npm test
- Lint: npm run lint

## Task Complete When
- [ ] All tests pass
- [ ] No lint errors
- [ ] Code is committed to git

## Coding Standards
- Follow existing code style
- Write tests for new features
- Update documentation

## Ralph Wiggum Notes
- Always use --max-iterations (start with 10-20)
- Clear success criteria in TODO.md
- Run tests before starting Ralph
- Git commit before starting Ralph (rollback point)
EOF
    echo -e "${C_GREEN}✓${C_RESET} Created CLAUDE.md"
else
    echo -e "${C_BLUE}ℹ${C_RESET} CLAUDE.md already exists"
fi

# Step 5: Create TODO.md if not exists
if [ ! -f "/workspace/TODO.md" ]; then
    cp /home/agent/.config/TODO.md.template /workspace/TODO.md 2>/dev/null || cat > /workspace/TODO.md <<'EOF'
# Project Tasks

## Current Sprint
- [ ] Example task: Add hello world function

## Backlog
- [ ] Future tasks here

## Completed
- [x] Setup development environment
- [x] Install Ralph Wiggum

---
**Ralph Tips:** Keep tasks specific, automated validation, use --max-iterations
EOF
    echo -e "${C_GREEN}✓${C_RESET} Created TODO.md"
else
    echo -e "${C_BLUE}ℹ${C_RESET} TODO.md already exists"
fi

# Step 6: Complete
echo ""
echo -e "${C_BOLD}[Step 6/6]${C_RESET} Setup complete!"
echo ""
echo -e "${C_GREEN}✓${C_RESET} Ralph Wiggum is ready to use"
echo ""
echo -e "${C_BOLD}Quick Start:${C_RESET}"
echo "  1. Edit TODO.md with a small, clear task"
echo "  2. Run: ${C_BOLD}cs${C_RESET} (starts Claude)"
echo "  3. In Claude, run: ${C_BOLD}/ralph-loop \"Complete task in TODO.md\" --max-iterations 10${C_RESET}"
echo ""
echo -e "${C_BOLD}Important Ralph Rules:${C_RESET}"
echo "  • ${C_YELLOW}ALWAYS${C_RESET} set --max-iterations (start with 10-20)"
echo "  • Make tasks small and specific"
echo "  • Commit to git before running Ralph"
echo "  • Monitor first run closely"
echo ""

touch "$RALPH_READY"
echo "$(date)" >> "$RALPH_READY"
