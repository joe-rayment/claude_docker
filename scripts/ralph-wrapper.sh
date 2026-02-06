#!/bin/bash
#
# Ralph Wrapper - Git Branch Workflow for Ralph Loop
#
# Wraps ralph execution with full git automation:
# - Ensures work happens on a feature branch (creates one if needed)
# - Creates safety checkpoint commit before loop starts
# - Generates AI commit message and commits when loop completes
# - Pushes to GitHub after each commit
# - Shows clear merge instructions when done
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

# Stage tracked changes and new files, respecting .gitignore
# Excludes common secret/sensitive file patterns
stage_changes() {
    # Stage modified tracked files
    git add -u

    # Stage new untracked files (respects .gitignore), but exclude secrets
    git ls-files --others --exclude-standard \
        | grep -v -E '(\.env$|\.env\.|credentials|\.secret|\.key$|\.pem$|\.p12$|\.pfx$|\.jks$|id_rsa|id_ed25519)' \
        | xargs -r git add --
}

# Get the main/default branch name
get_main_branch() {
    local branch
    branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
    if [ -n "$branch" ]; then
        echo "$branch"
    elif git rev-parse --verify --quiet main >/dev/null 2>&1; then
        echo "main"
    else
        echo "master"
    fi
}

# Push current branch to remote, setting upstream if needed
push_to_remote() {
    local branch=$(git branch --show-current)
    if ! git remote | grep -q .; then
        echo -e "  ${C_DIM}No remote configured, skipping push${C_RESET}"
        return 0
    fi

    if git push 2>/dev/null; then
        echo -e "  ${C_GREEN}✓${C_RESET} Pushed to origin/$branch"
    elif git push -u origin "$branch" 2>/dev/null; then
        echo -e "  ${C_GREEN}✓${C_RESET} Pushed to origin/$branch (upstream set)"
    else
        echo -e "  ${C_YELLOW}!${C_RESET} Push failed — check remote access (try 'gh auth setup-git')"
    fi
}

# Ensure we're on a feature branch, not main/master
ensure_feature_branch() {
    local current_branch=$(git branch --show-current)
    local main_branch=$(get_main_branch)

    if [ "$current_branch" != "$main_branch" ]; then
        echo -e "  ${C_GREEN}✓${C_RESET} On branch: ${C_BOLD}$current_branch${C_RESET}"
        return 0
    fi

    # We're on main — create a feature branch
    echo -e "  ${C_YELLOW}!${C_RESET} Currently on ${C_BOLD}$main_branch${C_RESET} — Ralph should work on a feature branch"
    echo ""

    # Generate branch name from date and ralph context
    local default_branch="ralph/$(date +%Y%m%d-%H%M%S)"
    read -p "  Branch name [$default_branch]: " branch_name
    branch_name="${branch_name:-$default_branch}"

    git checkout -b "$branch_name"
    echo -e "  ${C_GREEN}✓${C_RESET} Created and switched to: ${C_BOLD}$branch_name${C_RESET}"
}

# Create a checkpoint commit before running ralph
create_checkpoint() {
    echo -e "${C_BLUE}Checking git status...${C_RESET}"

    if ! is_git_repo; then
        echo -e "  ${C_DIM}Not a git repository, skipping git automation${C_RESET}"
        return 0
    fi

    # Ensure we're on a feature branch
    ensure_feature_branch

    if ! has_uncommitted_changes; then
        echo -e "  ${C_GREEN}✓${C_RESET} Working tree clean, no checkpoint needed"
        return 0
    fi

    echo -e "  ${C_YELLOW}!${C_RESET} Uncommitted changes detected"
    echo ""
    echo -e "${C_BLUE}Creating safety checkpoint...${C_RESET}"

    stage_changes
    git commit -m "checkpoint: before ralph loop"

    if [ $? -eq 0 ]; then
        echo -e "  ${C_GREEN}✓${C_RESET} Checkpoint created"
        push_to_remote
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
    local commit_msg
    if ! commit_msg=$(echo "$changes_summary" | claude -p "Generate a concise git commit message for these changes.
Start with 'ralph:' prefix. Be specific about what was implemented.
Keep it under 72 characters for the first line.
Only output the commit message, nothing else." --output-format text 2>/dev/null) || [ -z "$commit_msg" ]; then
        commit_msg="ralph: automated changes from ralph loop"
    fi

    echo -e "  ${C_GREEN}→${C_RESET} $commit_msg"

    echo ""
    echo -e "${C_BLUE}Committing and pushing...${C_RESET}"

    stage_changes
    git commit -m "$commit_msg"

    if [ $? -eq 0 ]; then
        echo -e "  ${C_GREEN}✓${C_RESET} Changes committed"
        push_to_remote
    else
        echo -e "  ${C_RED}✗${C_RESET} Commit failed"
        return 1
    fi
}

# Show merge instructions when Ralph is done
show_merge_instructions() {
    if ! is_git_repo; then
        return
    fi

    local current_branch=$(git branch --show-current)
    local main_branch=$(get_main_branch)

    # Only show if we're on a feature branch
    if [ "$current_branch" = "$main_branch" ]; then
        return
    fi

    local commit_count=$(git rev-list --count "$main_branch".."$current_branch" 2>/dev/null || echo "?")

    echo ""
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_BOLD}  Branch ready for review${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo ""
    echo -e "  Branch:  ${C_BOLD}$current_branch${C_RESET}"
    echo -e "  Commits: ${C_BOLD}$commit_count${C_RESET} ahead of $main_branch"
    echo ""
    echo -e "  ${C_BOLD}To merge:${C_RESET}"
    echo -e "    git checkout $main_branch && git merge $current_branch"
    echo ""
    echo -e "  ${C_BOLD}Or create a PR:${C_RESET}"
    echo -e "    gh pr create --fill"
    echo ""
    echo -e "  ${C_BOLD}To review changes first:${C_RESET}"
    echo -e "    git diff $main_branch...$current_branch"
    echo ""
}

# Main execution
main() {
    echo ""
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_BOLD}  Ralph Loop${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo ""

    # Step 1: Ensure feature branch + checkpoint commit
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

    # Step 3: Always try to commit remaining changes (even on non-zero exit)
    if has_uncommitted_changes 2>/dev/null; then
        create_completion_commit
    else
        echo ""
        if [ $ralph_exit_code -ne 0 ]; then
            echo -e "${C_YELLOW}Ralph exited with code $ralph_exit_code${C_RESET}"
        fi
        echo -e "${C_DIM}No uncommitted changes${C_RESET}"
    fi

    # Step 4: Show merge instructions
    show_merge_instructions

    return $ralph_exit_code
}

main "$@"
