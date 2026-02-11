#!/bin/bash
# claude-usage — update weekly usage % for statusline
# Usage:
#   claude-usage <weekly%> ["reset info"]
#   claude-usage 70 "Thu 9:59 PM"
#   claude-usage show
#   claude-usage clear

USAGE_FILE="/tmp/claude-usage.json"

case "${1:-show}" in
    show)
        if [ -f "$USAGE_FILE" ]; then
            jq -r '"  Weekly: \(.weekly_pct)%  Resets: \(.weekly_reset // "?")  Updated: \(.updated // "?")"' "$USAGE_FILE"
        else
            echo "No usage data. Run: claude-usage <weekly%> [reset_info]"
        fi
        ;;
    clear)
        rm -f "$USAGE_FILE"
        echo "Cleared."
        ;;
    *)
        weekly_pct="${1:?Usage: claude-usage <weekly%> [reset_info]}"
        weekly_reset="${2:-}"
        jq -n \
            --argjson weekly "$weekly_pct" \
            --arg reset "$weekly_reset" \
            --arg updated "$(date '+%H:%M')" \
            '{weekly_pct: $weekly, weekly_reset: $reset, updated: $updated}' \
            > "$USAGE_FILE"
        echo "weekly=${weekly_pct}%$([ -n "$weekly_reset" ] && echo " resets: $weekly_reset")"
        ;;
esac
