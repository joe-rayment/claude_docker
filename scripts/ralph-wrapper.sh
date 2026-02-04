#!/bin/bash
#
# Ralph Wrapper - Git Automation for Ralph Loop
#
# Wraps ralph execution with automatic git commits:
# - Creates safety checkpoint commit before loop starts
# - Generates AI commit message and commits when loop completes
#
# Usage:
#   ralph-wrapper.sh [ralph arguments...]
#
# Examples:
#   ralph-wrapper.sh              # Run ralph with git automation
#   ralph-wrapper.sh --resume     # Resume with git automation
#

# Colors
C_RED="\e[31m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_BLUE="\e[34m"
C_BOLD="\e[1m"
C_DIM="\e[2m"
C_RESET="\e[0m"

# Check if we're in a git repository
is_git_repo() {
    git rev-parse --is-inside-work-tree &>/dev/null
}

# Check if there are uncommitted changes
has_uncommitted_changes() {
    ! git diff-index --quiet HEAD -- 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard)" ]
}

# Create a checkpoint commit before running ralph
create_checkpoint() {
    echo -e "${C_BLUE}Checking git status...${C_RESET}"

    if ! is_git_repo; then
        echo -e "  ${C_DIM}Not a git repository, skipping checkpoint${C_RESET}"
        return 0
    fi

    if ! has_uncommitted_changes; then
        echo -e "  ${C_GREEN}✓${C_RESET} Working tree clean, no checkpoint needed"
        return 0
    fi

    echo -e "  ${C_YELLOW}!${C_RESET} Uncommitted changes detected"
    echo ""
    echo -e "${C_BLUE}Creating safety checkpoint...${C_RESET}"

    git add -A
    git commit -m "checkpoint: before ralph loop"

    if [ $? -eq 0 ]; then
        echo -e "  ${C_GREEN}✓${C_RESET} Checkpoint created"
    else
        echo -e "  ${C_RED}✗${C_RESET} Failed to create checkpoint"
        return 1
    fi
}

# Generate commit message using Claude and commit changes
create_completion_commit() {
    echo ""
    echo -e "${C_BLUE}Ralph completed. Checking for changes...${C_RESET}"

    if ! is_git_repo; then
        echo -e "  ${C_DIM}Not a git repository, skipping commit${C_RESET}"
        return 0
    fi

    if ! has_uncommitted_changes; then
        echo -e "  ${C_DIM}No changes to commit${C_RESET}"
        return 0
    fi

    # Get count of changed files
    local changed_files=$(git status --porcelain | wc -l | tr -d ' ')
    echo -e "  ${C_GREEN}✓${C_RESET} ${changed_files} files changed"

    echo ""
    echo -e "${C_BLUE}Generating commit message with Claude...${C_RESET}"

    # Get diff summary for commit message generation
    local diff_stat=$(git diff --stat HEAD 2>/dev/null)
    local diff_names=$(git diff --name-only HEAD 2>/dev/null)
    local untracked=$(git ls-files --others --exclude-standard)

    # Combine for context
    local changes_summary="Changed files:
$diff_names

New files:
$untracked

Diff stats:
$diff_stat"

    # Use Claude to generate commit message
    local commit_msg=$(echo "$changes_summary" | claude -p "Generate a concise git commit message for these changes.
Start with 'ralph:' prefix. Be specific about what was implemented.
Keep it under 72 characters for the first line.
Only output the commit message, nothing else." --output-format text 2>/dev/null)

    # Fallback if Claude fails
    if [ -z "$commit_msg" ] || [ $? -ne 0 ]; then
        commit_msg="ralph: automated changes from ralph loop"
    fi

    echo -e "  ${C_GREEN}→${C_RESET} $commit_msg"

    echo ""
    echo -e "${C_BLUE}Committing automatically...${C_RESET}"

    git add -A
    git commit -m "$commit_msg"

    if [ $? -eq 0 ]; then
        echo -e "  ${C_GREEN}✓${C_RESET} Changes committed"
    else
        echo -e "  ${C_RED}✗${C_RESET} Commit failed"
        return 1
    fi
}

# Main execution
main() {
    echo ""
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_BOLD}  Ralph Loop with Git Automation${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo ""

    # Step 1: Create checkpoint commit if needed
    create_checkpoint
    if [ $? -ne 0 ]; then
        echo -e "${C_RED}Failed to create checkpoint. Aborting.${C_RESET}"
        exit 1
    fi

    echo ""
    echo -e "${C_BLUE}Starting Ralph autonomous loop...${C_RESET}"
    echo ""

    # Step 2: Run ralph with all passed arguments
    ralph "$@"
    local ralph_exit_code=$?

    # Step 3: Create completion commit if ralph succeeded
    if [ $ralph_exit_code -eq 0 ]; then
        create_completion_commit
    else
        echo ""
        echo -e "${C_YELLOW}Ralph exited with code $ralph_exit_code${C_RESET}"
        echo -e "${C_DIM}Skipping automatic commit due to non-zero exit${C_RESET}"
    fi

    echo ""
    echo -e "${C_GREEN}Done!${C_RESET}"

    return $ralph_exit_code
}

main "$@"
