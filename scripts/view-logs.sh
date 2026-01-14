#!/bin/bash

# Colors
C_BLUE="\e[34m"
C_BOLD="\e[1m"
C_RESET="\e[0m"

echo -e "${C_BOLD}${C_BLUE}Claude Code Logs${C_RESET}"
echo ""

# Menu
PS3="Select action: "
select choice in "View latest debug log" "Export latest to workspace" "List all sessions" "View session transcript" "Exit"; do
    case $choice in
        "View latest debug log")
            less ~/.claude/debug/latest
            ;;
        "Export latest to workspace")
            mkdir -p /workspace/logs
            cp ~/.claude/debug/latest "/workspace/logs/session-$(date +%Y%m%d-%H%M%S).log"
            echo "Exported to /workspace/logs/"
            ;;
        "List all sessions")
            ls -lht ~/.claude/debug/ | head -20
            ;;
        "View session transcript")
            echo "Available transcripts:"
            find ~/.claude/projects -name "*.jsonl" -type f | tail -10
            read -p "Enter path: " transcript_path
            if [ -f "$transcript_path" ]; then
                less "$transcript_path"
            fi
            ;;
        "Exit")
            break
            ;;
    esac
done
