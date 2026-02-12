#!/bin/bash
# Claude Code statusline — model, context, branch, live usage limits
# Receives JSON session data on stdin

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "unknown"')
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | awk '{printf "%d", $1}')
branch=$(git -C /workspace rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

# Build context bar (10 dots)
filled=$((ctx_pct / 10))
empty=$((10 - filled))
bar=""
for ((i=0; i<filled; i++)); do bar+="●"; done
for ((i=0; i<empty; i++)); do bar+="○"; done

# Fetch usage limits (cached 60s)
cache="/tmp/claude-usage-cache.json"
max_age=60
refresh=1

if [ -f "$cache" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    [ "$age" -lt "$max_age" ] && refresh=0
fi

if [ "$refresh" -eq 1 ]; then
    token=$(jq -r '.claudeAiOauth.accessToken' /home/agent/.claude/.credentials.json 2>/dev/null)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        curl -s --max-time 5 \
            -H "Accept: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.1.39" \
            "https://api.anthropic.com/api/oauth/usage" > "${cache}.tmp" 2>/dev/null
        if jq -e '.five_hour' "${cache}.tmp" >/dev/null 2>&1; then
            mv "${cache}.tmp" "$cache"
        else
            rm -f "${cache}.tmp"
        fi
    fi
fi

session_pct="?"
weekly_pct="?"
if [ -f "$cache" ]; then
    session_pct=$(jq -r '.five_hour.utilization // 0' "$cache" | awk '{printf "%d", $1}')
    weekly_pct=$(jq -r '.seven_day.utilization // 0' "$cache" | awk '{printf "%d", $1}')
fi

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

printf "\033[32m%s\033[0m | \033[33m%s\033[0m %d%% | \033[36m%s\033[0m | session: %s | weekly: %s\n" \
    "$model" "$bar" "$ctx_pct" "$branch" \
    "$(color_pct "$session_pct")" "$(color_pct "$weekly_pct")"
