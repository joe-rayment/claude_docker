#!/bin/bash
set -e

# Colors
C_BLUE='\033[0;34m'
C_BOLD='\033[1m'
C_YELLOW='\033[1;33m'
C_RESET='\033[0m'

echo -e "${C_BOLD}${C_BLUE}Claude Code Logs${C_RESET}"
echo ""

# Menu
PS3="Select action: "
select choice in "View latest debug log" "Export latest to workspace" "List all sessions" "View session transcript" "Exit"; do
    case $choice in
        "View latest debug log")
            if [ -f ~/.claude/debug/latest ]; then
                less ~/.claude/debug/latest
            else
                echo -e "${C_YELLOW}No debug logs found yet${C_RESET}"
            fi
            ;;
        "Export latest to workspace")
            if [ -f ~/.claude/debug/latest ]; then
                mkdir -p /home/agent/.claude/exported-logs
                cp ~/.claude/debug/latest "/home/agent/.claude/exported-logs/session-$(date +%Y%m%d-%H%M%S).log"
                echo "Exported to ~/.claude/exported-logs/"
            else
                echo -e "${C_YELLOW}No debug logs found yet${C_RESET}"
            fi
            ;;
        "List all sessions")
            ls -lht ~/.claude/debug/ | head -20
            ;;
        "View session transcript")
            echo "Available transcripts:"
            local_transcripts=$(find ~/.claude/projects -name "*.jsonl" -type f 2>/dev/null | tail -10)
            if [ -z "$local_transcripts" ]; then
                echo "No session transcripts found"
            else
                echo "$local_transcripts"
                read -p "Enter path: " transcript_path
                if [ -f "$transcript_path" ]; then
                    less "$transcript_path"
                else
                    echo "File not found: $transcript_path"
                fi
            fi
            ;;
        "Exit")
            break
            ;;
    esac
done
