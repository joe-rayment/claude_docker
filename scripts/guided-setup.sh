#!/bin/bash

# Guided Setup - Interactive menu for Claude Docker environment

# Colors
C_RED="\e[31m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_BLUE="\e[34m"
C_BOLD="\e[1m"
C_DIM="\e[2m"
C_RESET="\e[0m"

# State detection functions
is_claude_authenticated() {
    [ -f "/home/agent/.claude/credentials" ] || claude auth status &>/dev/null
}

is_git_configured() {
    git config user.name &>/dev/null && git config user.email &>/dev/null
}

is_github_authenticated() {
    gh auth status &>/dev/null
}

is_ralph_ready() {
    [ -f "/workspace/.ralph/PROMPT.md" ]
}

get_dependency_count() {
    # Use cached count from container-welcome.sh if available
    if [ -f "/tmp/.dep-count-cache" ]; then
        cat /tmp/.dep-count-cache
    else
        /usr/local/bin/detect-dependencies.sh --count 2>/dev/null || echo "0"
    fi
}

# Require Claude authentication before running Claude-dependent commands
# Offers to authenticate if not already done; returns 1 on failure/skip
require_claude_auth() {
    if is_claude_authenticated; then
        return 0
    fi
    echo ""
    echo -e "${C_YELLOW}⚠${C_RESET} Claude is not authenticated. This action requires authentication."
    read -p "Authenticate now? (y/n): " choice
    if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
        claude auth login
        if is_claude_authenticated; then
            echo -e "${C_GREEN}✓${C_RESET} Claude authenticated successfully"
            return 0
        else
            echo -e "${C_RED}✗${C_RESET} Authentication failed."
            return 1
        fi
    fi
    return 1
}

# Prompt for Claude authentication (mandatory — loops until authenticated)
prompt_claude_auth() {
    echo ""
    echo -e "${C_BOLD}Claude Authentication${C_RESET}"
    echo -e "${C_DIM}Claude authentication is required to use this environment.${C_RESET}"
    echo -e "${C_DIM}This will open a browser window to authenticate.${C_RESET}"

    while true; do
        echo ""
        read -p "Press ENTER to authenticate with Claude: " _
        claude auth login
        echo ""
        if is_claude_authenticated; then
            echo -e "${C_GREEN}✓${C_RESET} Claude authenticated successfully"
            return 0
        fi
        echo -e "${C_RED}✗${C_RESET} Authentication failed. Please try again."
        echo -e "${C_DIM}(You can also run 'claude auth login' manually from the shell later)${C_RESET}"
        read -p "Retry? (y/n): " retry
        if [ "$retry" = "n" ] || [ "$retry" = "N" ]; then
            echo -e "${C_YELLOW}⚠${C_RESET} Dropping to shell. Run ${C_BOLD}claude auth login${C_RESET} when ready."
            return 1
        fi
    done
}

# Prompt for Git configuration
prompt_git_config() {
    echo ""
    echo -e "${C_BOLD}Git Configuration${C_RESET}"
    echo ""
    read -p "Configure Git? (y/n): " choice

    if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
        read -p "  Name: " git_name
        read -p "  Email: " git_email

        if [ -n "$git_name" ]; then
            git config --global user.name "$git_name"
        fi
        if [ -n "$git_email" ]; then
            git config --global user.email "$git_email"
        fi

        echo ""
        echo -e "${C_GREEN}✓${C_RESET} Git configured"
    fi
}

# Prompt for GitHub authentication
prompt_github_auth() {
    echo ""
    echo -e "${C_BOLD}GitHub Authentication${C_RESET}"
    echo -e "${C_DIM}This enables pushing, PRs, and issue imports.${C_RESET}"
    echo ""
    read -p "Authenticate with GitHub? (y/n): " choice

    if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
        gh auth login
        echo ""
        if is_github_authenticated; then
            echo -e "${C_GREEN}✓${C_RESET} GitHub authenticated successfully"
        else
            echo -e "${C_YELLOW}⚠${C_RESET} Authentication may have failed. Try 'gh auth login' manually."
        fi
    fi
}

# Prompt for dependency installation
prompt_install_deps() {
    local dep_count=$(get_dependency_count)

    if [ "$dep_count" -eq 0 ]; then
        return
    fi

    echo ""
    echo -e "${C_BOLD}Dependencies Detected${C_RESET}"
    /usr/local/bin/detect-dependencies.sh
    echo ""
    read -p "Install dependencies now? (y/n/s to skip): " choice

    if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
        while IFS= read -r cmd; do
            # Extract the package manager (first word of the command)
            local mgr="${cmd%% *}"
            if ! command -v "$mgr" &>/dev/null; then
                echo ""
                echo -e "${C_RED}✗${C_RESET} Skipping: $cmd (${mgr} not found)"
                continue
            fi
            echo ""
            echo -e "${C_YELLOW}→${C_RESET} Running: $cmd"
            (cd /workspace && $cmd)
        done < <(/usr/local/bin/detect-dependencies.sh --commands)
        echo ""
        echo -e "${C_GREEN}✓${C_RESET} Dependencies installed"
    fi
}

# Show main menu
show_main_menu() {
    while true; do
        echo ""
        echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
        echo -e "${C_BOLD}  What would you like to do?${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
        echo ""
        echo -e "  ${C_BOLD}[1]${C_RESET} Start Claude (interactive)"
        echo -e "  ${C_BOLD}[2]${C_RESET} Initialize Ralph (ralph-enable)"
        echo -e "  ${C_BOLD}[3]${C_RESET} Edit project spec (.ralph/PROMPT.md)"
        echo -e "  ${C_BOLD}[4]${C_RESET} Edit task list (.ralph/fix_plan.md)"
        echo -e "  ${C_BOLD}[5]${C_RESET} Run Ralph (branch + auto-commit + push)"
        echo -e "  ${C_BOLD}[6]${C_RESET} View logs"
        echo -e "  ${C_BOLD}[7]${C_RESET} Refresh task list from spec"
        echo -e "  ${C_BOLD}[s]${C_RESET} Skip to shell"
        echo ""
        read -p "Choice: " choice

        case "$choice" in
            1)
                echo ""
                if require_claude_auth; then
                    claude --dangerously-skip-permissions
                    echo ""
                    echo -e "${C_DIM}Type ${C_RESET}${C_BOLD}menu${C_RESET}${C_DIM} for options${C_RESET}"
                    return
                fi
                ;;
            2)
                echo ""
                ralph-enable
                ;;
            3)
                echo ""
                if [ -f "/workspace/.ralph/PROMPT.md" ]; then
                    hx /workspace/.ralph/PROMPT.md
                else
                    echo -e "${C_YELLOW}⚠${C_RESET} .ralph/PROMPT.md not found. Run 'ralph-enable' first."
                fi
                ;;
            4)
                echo ""
                if [ -f "/workspace/.ralph/fix_plan.md" ]; then
                    hx /workspace/.ralph/fix_plan.md
                else
                    echo -e "${C_YELLOW}⚠${C_RESET} .ralph/fix_plan.md not found. Run 'ralph-enable' first."
                fi
                ;;
            5)
                echo ""
                if require_claude_auth; then
                    if command -v tmux &>/dev/null; then
                        ralph-tmux
                    else
                        /usr/local/bin/ralph-wrapper.sh
                    fi
                    echo ""
                    echo -e "${C_DIM}Type ${C_RESET}${C_BOLD}menu${C_RESET}${C_DIM} for options${C_RESET}"
                    return
                fi
                ;;
            6)
                echo ""
                view-logs
                ;;
            7)
                echo ""
                if require_claude_auth; then
                    /usr/local/bin/ralph-refresh
                fi
                ;;
            s|S|"")
                echo ""
                return
                ;;
            *)
                echo -e "${C_RED}Invalid choice${C_RESET}"
                ;;
        esac
    done
}

# Show quick menu for returning users (with timeout)
show_quick_menu() {
    while true; do
        echo ""
        echo -e "${C_BOLD}Quick Start${C_RESET} ${C_DIM}(auto-skip in 3s, press 's' to skip now)${C_RESET}"
        echo ""
        echo -e "  ${C_BOLD}[1]${C_RESET} Start Claude (interactive)"
        echo -e "  ${C_BOLD}[2]${C_RESET} Run Ralph (branch + auto-commit + push)"
        echo -e "  ${C_BOLD}[m]${C_RESET} Full menu"
        echo -e "  ${C_BOLD}[s]${C_RESET} Shell"
        echo ""

        # Read with timeout
        read -t 3 -p "Choice: " choice || choice="timeout"

        case "$choice" in
            1)
                echo ""
                if require_claude_auth; then
                    claude --dangerously-skip-permissions
                    echo ""
                    echo -e "${C_DIM}Type ${C_RESET}${C_BOLD}menu${C_RESET}${C_DIM} for options${C_RESET}"
                    return
                fi
                ;;
            2)
                echo ""
                if require_claude_auth; then
                    if command -v tmux &>/dev/null; then
                        ralph-tmux
                    else
                        /usr/local/bin/ralph-wrapper.sh
                    fi
                    echo ""
                    echo -e "${C_DIM}Type ${C_RESET}${C_BOLD}menu${C_RESET}${C_DIM} for options${C_RESET}"
                    return
                fi
                ;;
            m|M)
                show_main_menu
                return
                ;;
            s|S|""|timeout)
                echo ""
                return
                ;;
            *)
                echo -e "${C_RED}Invalid choice${C_RESET}"
                ;;
        esac
    done
}

# Main function - orchestrates the guided setup flow
main() {
    local needs_setup=false

    # Claude auth is mandatory — if it fails, drop to shell
    if ! is_claude_authenticated; then
        needs_setup=true
        if ! prompt_claude_auth; then
            # User chose to drop to shell
            return
        fi
    fi

    if ! is_git_configured; then
        needs_setup=true
        prompt_git_config
    fi

    # GitHub authentication (after git config)
    if ! is_github_authenticated; then
        needs_setup=true
        prompt_github_auth
    fi

    # Always offer dependency installation if detected
    local dep_count=$(get_dependency_count)
    if [ "$dep_count" -gt 0 ]; then
        needs_setup=true
        prompt_install_deps
    fi

    # Show appropriate menu
    if [ "$needs_setup" = true ] || [ ! -f "/home/agent/.first-login" ]; then
        show_main_menu
    else
        show_quick_menu
    fi
}

# Run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
