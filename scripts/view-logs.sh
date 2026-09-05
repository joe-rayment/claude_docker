#!/bin/bash
set -e

# Resolve through a symlink chain (e.g. bin/view-logs -> ../scripts/
# view-logs.sh) to this script's real directory, so lib/paths.sh resolves
# whether this is invoked via the repo copy or the .claude-dev/template/
# bin/ symlink.
_resolve_script_path() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        local link dir
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(cd "$(dirname "$src")" && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}
SCRIPT_DIR="$(cd "$(dirname "$(_resolve_script_path)")" && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"
CONFIG_DIR="$(claude_config_dir)"

# Colors
C_BLUE='\033[0;34m'
C_BOLD='\033[1m'
C_YELLOW='\033[1;33m'
C_RESET='\033[0m'

echo -e "${C_BOLD}${C_BLUE}Claude Code Logs${C_RESET}"
echo ""

# Menu
PS3="Select action: "
select choice in "View latest debug log" "Export latest to the config dir" "List all sessions" "View session transcript" "Exit"; do
    case $choice in
        "View latest debug log")
            if [ -f "$CONFIG_DIR/debug/latest" ]; then
                less "$CONFIG_DIR/debug/latest"
            else
                echo -e "${C_YELLOW}No debug logs found yet${C_RESET}"
            fi
            ;;
        "Export latest to the config dir")
            if [ -f "$CONFIG_DIR/debug/latest" ]; then
                mkdir -p "$CONFIG_DIR/exported-logs"
                cp "$CONFIG_DIR/debug/latest" "$CONFIG_DIR/exported-logs/session-$(date +%Y%m%d-%H%M%S).log"
                echo "Exported to $CONFIG_DIR/exported-logs/"
            else
                echo -e "${C_YELLOW}No debug logs found yet${C_RESET}"
            fi
            ;;
        "List all sessions")
            ls -lht "$CONFIG_DIR/debug/" | head -20
            ;;
        "View session transcript")
            echo "Available transcripts:"
            local_transcripts=$(find "$CONFIG_DIR/projects" -name "*.jsonl" -type f 2>/dev/null | tail -10)
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
