#!/bin/bash
#
# Ralph Wiggum - Simple Autonomous Loop for Claude Code
#
# This implements the recommended approach: a simple bash loop that runs
# Claude in headless mode with fresh context each iteration.
#
# Usage:
#   ralph [OPTIONS] [spec-file]
#
# Options:
#   -n, --max-iterations N   Maximum iterations (default: 0 = unlimited)
#   -h, --help               Show this help message
#
# Examples:
#   ralph                      # Run with SPEC.md, unlimited iterations
#   ralph -n 10                # Run max 10 iterations
#   ralph -n 20 myspec.md      # Custom spec file, max 20 iterations

set -e

# Colors
C_RED="\e[31m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_BLUE="\e[34m"
C_BOLD="\e[1m"
C_RESET="\e[0m"

# Defaults
MAX_ITERATIONS=0
SPEC_FILE="SPEC.md"
ITERATION=0

# Help message
show_help() {
    cat << EOF
${C_BOLD}Ralph Wiggum - Simple Autonomous Loop${C_RESET}

${C_BOLD}Usage:${C_RESET}
  ralph [OPTIONS] [spec-file]

${C_BOLD}Options:${C_RESET}
  -n, --max-iterations N   Maximum iterations (default: unlimited)
  -h, --help               Show this help message

${C_BOLD}Examples:${C_RESET}
  ralph                    Run with SPEC.md, unlimited iterations
  ralph -n 10              Run max 10 iterations
  ralph -n 20 myspec.md    Custom spec file, max 20 iterations

${C_BOLD}How it works:${C_RESET}
  Each iteration runs: cat SPEC.md | claude --print

  Claude sees a fresh context every time. The spec file and your
  codebase (via git) are the source of truth, not conversation history.

${C_BOLD}Best practices:${C_RESET}
  • ${C_YELLOW}ALWAYS${C_RESET} use --max-iterations (start with 10-20)
  • Git commit before running (safety checkpoint)
  • Keep specs focused - leave room for implementation
  • Use PLAN.md for task tracking

${C_BOLD}Stop the loop:${C_RESET}
  Press Ctrl+C at any time.

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--max-iterations)
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo -e "${C_RED}Error: Unknown option $1${C_RESET}"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            SPEC_FILE="$1"
            shift
            ;;
    esac
done

# Validation
if [ ! -f "$SPEC_FILE" ]; then
    echo -e "${C_RED}Error: Spec file '$SPEC_FILE' not found${C_RESET}"
    echo ""
    echo "Create a spec file first. Run 'ralph-init' to set up a new project,"
    echo "or specify a different spec file: ralph myspec.md"
    exit 1
fi

# Warning if no max iterations
if [ "$MAX_ITERATIONS" -eq 0 ]; then
    echo -e "${C_YELLOW}⚠ WARNING: No --max-iterations set. Loop will run until Ctrl+C.${C_RESET}"
    echo -e "  Recommended: ralph ${C_BOLD}-n 10${C_RESET} (start with 10-20 iterations)"
    echo ""
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted. Use: ralph -n 10"
        exit 1
    fi
fi

# Check for uncommitted changes
if [ -d ".git" ]; then
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        echo -e "${C_YELLOW}⚠ WARNING: You have uncommitted changes.${C_RESET}"
        echo "  Recommended: git commit before running Ralph (safety checkpoint)"
        echo ""
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted. Commit your changes first."
            exit 1
        fi
    fi
fi

# Header
echo ""
echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo -e "${C_BOLD}  Ralph Wiggum - Autonomous Loop${C_RESET}"
echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo ""
echo -e "Spec file: ${C_BOLD}$SPEC_FILE${C_RESET}"
if [ "$MAX_ITERATIONS" -gt 0 ]; then
    echo -e "Max iterations: ${C_BOLD}$MAX_ITERATIONS${C_RESET}"
else
    echo -e "Max iterations: ${C_YELLOW}unlimited${C_RESET}"
fi
echo -e "Stop: ${C_BOLD}Ctrl+C${C_RESET}"
echo ""
echo -e "${C_GREEN}Starting loop...${C_RESET}"
echo ""

# The loop
while :; do
    ITERATION=$((ITERATION + 1))

    # Check max iterations
    if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ITERATION" -gt "$MAX_ITERATIONS" ]; then
        echo ""
        echo -e "${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
        echo -e "${C_GREEN}✓ Max iterations ($MAX_ITERATIONS) reached. Stopping.${C_RESET}"
        echo -e "${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
        break
    fi

    echo -e "${C_BLUE}━━━ Iteration $ITERATION$([ "$MAX_ITERATIONS" -gt 0 ] && echo "/$MAX_ITERATIONS") ━━━${C_RESET}"
    echo ""

    # Run Claude in headless mode with fresh context
    # --print outputs the response without interactive mode
    # --dangerously-skip-permissions allows autonomous operation
    cat "$SPEC_FILE" | claude --dangerously-skip-permissions --print

    echo ""

    # Brief pause between iterations (allows Ctrl+C window)
    sleep 2
done

echo ""
echo -e "${C_BOLD}Ralph loop completed.${C_RESET}"
echo "Review the changes with: git diff"
