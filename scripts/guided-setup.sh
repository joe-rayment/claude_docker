#!/bin/bash

# Guided Setup - Interactive menu for Claude Docker environment

# Colors
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_RESET="\033[0m"

# State detection functions
is_claude_authenticated() {
    [ -f "/home/agent/.claude/.credentials.json" ]
}

is_git_configured() {
    git config user.name &>/dev/null && git config user.email &>/dev/null
}

is_github_authenticated() {
    [ -f "/home/agent/.config/gh/hosts.yml" ]
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
    echo -e "  Run ${C_BOLD}claude${C_RESET}, type ${C_BOLD}/login${C_RESET}, then ${C_BOLD}/exit${C_RESET} to return."
    read -p "Launch Claude now? (y/n): " choice
    if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
        claude
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
    echo ""
    echo -e "  Run ${C_BOLD}claude${C_RESET} and then type ${C_BOLD}/login${C_RESET} to authenticate."
    echo -e "  After authenticating, type ${C_BOLD}/exit${C_RESET} to return here."
    echo ""

    while true; do
        read -p "Press ENTER to launch Claude (then type /login): " _
        claude
        echo ""
        if is_claude_authenticated; then
            echo -e "${C_GREEN}✓${C_RESET} Claude authenticated successfully"
            return 0
        fi
        echo -e "${C_YELLOW}⚠${C_RESET} Claude credentials not found."
        echo -e "  Launch ${C_BOLD}claude${C_RESET}, type ${C_BOLD}/login${C_RESET}, then ${C_BOLD}/exit${C_RESET} to return."
        echo ""
        read -p "Try again? (y/n): " retry
        if [ "$retry" = "n" ] || [ "$retry" = "N" ]; then
            echo -e "${C_YELLOW}⚠${C_RESET} Dropping to shell. Run ${C_BOLD}claude${C_RESET} and type ${C_BOLD}/login${C_RESET} when ready."
            return 1
        fi
    done
}

# Prompt for Git configuration
prompt_git_config() {
    echo ""
    echo -e "${C_BOLD}Git Configuration${C_RESET}"
    echo ""
    read -p "Configure Git? (y/n/a=skip all): " choice

    case "$choice" in
        y|Y)
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
            ;;
        a|A)
            skip_remaining=true  # Intentionally global — signals main() to skip remaining steps
            ;;
    esac
}

# Prompt for GitHub authentication
prompt_github_auth() {
    echo ""
    echo -e "${C_BOLD}GitHub Authentication${C_RESET}"
    echo -e "${C_DIM}This enables pushing, PRs, and issue imports.${C_RESET}"
    echo -e "${C_DIM}(This step opens a browser — it may take a moment. Press Ctrl+C to skip.)${C_RESET}"
    echo ""
    read -p "Authenticate with GitHub? (y/n/a=skip all): " choice

    if [ "$choice" = "a" ] || [ "$choice" = "A" ]; then
        skip_remaining=true  # Intentionally global — signals main() to skip remaining steps
        return
    fi
    if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
        echo ""
        echo -e "${C_YELLOW}→${C_RESET} Starting GitHub login. Follow the prompts below."
        echo -e "${C_DIM}  If this hangs, press Ctrl+C to skip and run 'gh auth login' later.${C_RESET}"
        echo ""
        trap 'echo ""; echo -e "${C_YELLOW}⚠${C_RESET} Skipped. Run ${C_BOLD}gh auth login${C_RESET} later."; trap - INT; return' INT
        gh auth login
        trap - INT
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
    local dep_count
    dep_count="$(get_dependency_count)"

    if [ "$dep_count" -eq 0 ]; then
        return
    fi

    echo ""
    echo -e "${C_BOLD}Dependencies Detected${C_RESET}"
    /usr/local/bin/detect-dependencies.sh
    echo ""
    read -p "Install dependencies now? (y/n): " choice

    if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
        while IFS= read -r cmd; do
            local mgr="${cmd%% *}"
            if ! command -v "$mgr" &>/dev/null; then
                echo ""
                echo -e "${C_RED}✗${C_RESET} Skipping: ${cmd} (${mgr} not found)"
                continue
            fi
            echo ""
            echo -e "${C_YELLOW}→${C_RESET} Running: ${cmd}"
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
        echo -e "  ${C_BOLD}[2]${C_RESET} View logs"
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
                view-logs
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

# Show quick menu for returning users
show_quick_menu() {
    while true; do
        echo ""
        echo -e "${C_BOLD}Quick Start${C_RESET}"
        echo ""
        echo -e "  ${C_BOLD}[1]${C_RESET} Start Claude (interactive)"
        echo -e "  ${C_BOLD}[m]${C_RESET} Full menu"
        echo -e "  ${C_BOLD}[s]${C_RESET} Shell"
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
            m|M)
                show_main_menu
                return
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

    # Remaining setup steps — user can skip individual steps or all at once
    # skip_remaining is intentionally NOT local — set by prompt functions for cross-function communication
    skip_remaining=false

    if ! is_git_configured; then
        needs_setup=true
        if [ "$skip_remaining" = false ]; then
            prompt_git_config
        fi
    fi

    if ! is_github_authenticated && [ "$skip_remaining" = false ]; then
        needs_setup=true
        prompt_github_auth
    fi

    local dep_count
    dep_count="$(get_dependency_count)"
    if [ "$dep_count" -gt 0 ] && [ "$skip_remaining" = false ]; then
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
    if [ "$1" = "--menu-only" ]; then
        show_quick_menu
    else
        main "$@"
    fi
fi
