#!/bin/bash
# Claude Code statusline — model, context, branch, weekly usage
# Receives JSON session data on stdin

input=$(cat)

# Parse from statusline JSON
model=$(echo "$input" | jq -r '.model.display_name // "unknown"')
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | awk '{printf "%d", $1}')

# Git branch
branch=$(git -C /workspace rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

# Weekly usage from cache (run: claude-usage <weekly%> ["reset info"])
usage_file="/tmp/claude-usage.json"
if [ -f "$usage_file" ]; then
    weekly_pct=$(jq -r '.weekly_pct // "?"' "$usage_file")
    weekly_reset=$(jq -r '.weekly_reset // ""' "$usage_file")
else
    weekly_pct="?"
    weekly_reset=""
fi

# Build context bar (10 dots)
filled=$((ctx_pct / 10))
empty=$((10 - filled))
bar=""
for ((i=0; i<filled; i++)); do bar+="●"; done
for ((i=0; i<empty; i++)); do bar+="○"; done

# Color a percentage by severity
color_pct() {
    local pct="$1"
    if [ "$pct" = "?" ]; then
        printf "\033[90m?\033[0m"
    elif [ "$pct" -ge 90 ] 2>/dev/null; then
        printf "\033[31m%d%%\033[0m" "$pct"
    elif [ "$pct" -ge 70 ] 2>/dev/null; then
        printf "\033[33m%d%%\033[0m" "$pct"
    else
        printf "\033[32m%d%%\033[0m" "$pct"
    fi
}

# Weekly label
weekly="weekly: $(color_pct "$weekly_pct")"

# Single line: model | context bar % | branch | weekly %
printf "\033[32m%s\033[0m | \033[33m%s\033[0m %d%% | \033[36m%s\033[0m | %b\n" \
    "$model" "$bar" "$ctx_pct" "$branch" "$weekly"
