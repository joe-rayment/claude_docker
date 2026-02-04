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

is_ralph_ready() {
    [ -f "/home/agent/.ralph-ready" ]
}

get_dependency_count() {
    /usr/local/bin/detect-dependencies.sh --count 2>/dev/null || echo "0"
}

# Prompt for Claude authentication
prompt_claude_auth() {
    echo ""
    echo -e "${C_BOLD}Claude Authentication${C_RESET}"
    echo -e "${C_DIM}This will open a browser window to authenticate.${C_RESET}"
    echo ""
    read -p "Press ENTER to authenticate with Claude (or 's' to skip): " choice

    if [ "$choice" != "s" ] && [ "$choice" != "S" ]; then
        claude auth login
        echo ""
        if is_claude_authenticated; then
            echo -e "${C_GREEN}✓${C_RESET} Claude authenticated successfully"
        else
            echo -e "${C_YELLOW}⚠${C_RESET} Authentication may have failed. Try 'claude auth login' manually."
        fi
    fi
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
            echo ""
            echo -e "${C_YELLOW}→${C_RESET} Running: $cmd"
            eval "$cmd"
        done < <(/usr/local/bin/detect-dependencies.sh --commands)
        echo ""
        echo -e "${C_GREEN}✓${C_RESET} Dependencies installed"
    fi
}

# Show main menu
show_main_menu() {
    echo ""
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_BOLD}  What would you like to do?${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}[1]${C_RESET} Start Claude (interactive)"
    echo -e "  ${C_BOLD}[2]${C_RESET} Initialize Ralph Wiggum"
    echo -e "  ${C_BOLD}[3]${C_RESET} Edit project spec (SPEC.md)"
    echo -e "  ${C_BOLD}[4]${C_RESET} Edit project plan (PLAN.md)"
    echo -e "  ${C_BOLD}[5]${C_RESET} Run Ralph loop"
    echo -e "  ${C_BOLD}[6]${C_RESET} View logs"
    echo -e "  ${C_BOLD}[s]${C_RESET} Skip to shell"
    echo ""
    read -p "Choice: " choice

    case "$choice" in
        1)
            echo ""
            exec cs
            ;;
        2)
            echo ""
            ralph-init
            show_main_menu
            ;;
        3)
            echo ""
            if [ -f "/workspace/SPEC.md" ]; then
                hx /workspace/SPEC.md
            else
                echo -e "${C_YELLOW}⚠${C_RESET} SPEC.md not found. Run 'ralph-init' first or create it manually."
            fi
            show_main_menu
            ;;
        4)
            echo ""
            if [ -f "/workspace/PLAN.md" ]; then
                hx /workspace/PLAN.md
            else
                echo -e "${C_YELLOW}⚠${C_RESET} PLAN.md not found. Run 'ralph-init' first or create it manually."
            fi
            show_main_menu
            ;;
        5)
            echo ""
            read -p "Number of iterations (default 10): " iterations
            iterations=${iterations:-10}
            exec ralph -n "$iterations"
            ;;
        6)
            echo ""
            view-logs
            show_main_menu
            ;;
        s|S|"")
            echo ""
            return
            ;;
        *)
            echo -e "${C_RED}Invalid choice${C_RESET}"
            show_main_menu
            ;;
    esac
}

# Show quick menu for returning users (with timeout)
show_quick_menu() {
    echo ""
    echo -e "${C_BOLD}Quick Start${C_RESET} ${C_DIM}(auto-skip in 3s, press 's' to skip now)${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}[1]${C_RESET} cs - Start Claude"
    echo -e "  ${C_BOLD}[2]${C_RESET} ralph -n 10 - Run loop"
    echo -e "  ${C_BOLD}[m]${C_RESET} Full menu"
    echo -e "  ${C_BOLD}[s]${C_RESET} Shell"
    echo ""

    # Read with timeout
    read -t 3 -p "Choice: " choice || choice="timeout"

    case "$choice" in
        1)
            echo ""
            exec cs
            ;;
        2)
            echo ""
            exec ralph -n 10
            ;;
        m|M)
            show_main_menu
            ;;
        s|S|""|timeout)
            echo ""
            return
            ;;
        *)
            echo -e "${C_RED}Invalid choice${C_RESET}"
            show_quick_menu
            ;;
    esac
}

# Main function - orchestrates the guided setup flow
main() {
    local needs_setup=false

    # Check what needs to be set up
    if ! is_claude_authenticated; then
        needs_setup=true
        prompt_claude_auth
    fi

    if ! is_git_configured; then
        needs_setup=true
        prompt_git_config
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
