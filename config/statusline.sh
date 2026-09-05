#!/bin/bash
# Claude Code statusline — model, context, branch, live usage limits
# Receives JSON session data on stdin

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "unknown"')
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | awk '{printf "%d", $1}')
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

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
    token=$(jq -r '.claudeAiOauth.accessToken' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" 2>/dev/null)
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

# Color by severity (configurable thresholds)
color_by_threshold() {
    local pct="$1" text="$2" yellow="${3:-40}" red="${4:-75}"
    if [ "$pct" = "?" ]; then
        printf "\033[90m%s\033[0m" "$text"
    elif [ "$pct" -ge "$red" ] 2>/dev/null; then
        printf "\033[31m%s\033[0m" "$text"
    elif [ "$pct" -ge "$yellow" ] 2>/dev/null; then
        printf "\033[33m%s\033[0m" "$text"
    else
        printf "\033[32m%s\033[0m" "$text"
    fi
}

# Color a usage percentage (70/90 thresholds)
color_pct() {
    color_by_threshold "$1" "$([ "$1" = "?" ] && echo "?" || printf "%d%%" "$1")" 70 90
}

# Flat (non-severity) color for the optional Claude Code >=2.1.251 segments
# below — cache-hit and context-remaining are "higher is better", unlike the
# other percentages here, so the red/yellow/green severity ramp doesn't apply.
color_flat() {
    printf "\033[34m%s\033[0m" "$1"
}

ctx_display=$(color_by_threshold "$ctx_pct" "$bar $ctx_pct%" 40 75)

# Optional segments fed by statusline JSON fields Claude Code >=2.1.251 emits:
# prompt-cache hit ratio, context-window remaining, session cost. Each field
# is read with a `// empty` fallback and a stderr guard so a field that is
# absent, null, or a differently-shaped value renders nothing rather than
# erroring; the whole segment is then omitted (not shown empty) when its
# value is unavailable, keeping output byte-identical to before when none of
# these fields are present (e.g. today, container is 2.1.247).
extra=""

cache_hit_raw=$(echo "$input" | jq -r '.prompt_cache.hit_ratio // empty' 2>/dev/null)
if [ -n "$cache_hit_raw" ]; then
    cache_pct=$(awk -v h="$cache_hit_raw" 'BEGIN{printf "%d", h*100}')
    extra="${extra:+$extra | }$(color_flat "cache ${cache_pct}%")"
fi

ctx_remaining_raw=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty' 2>/dev/null)
if [ -n "$ctx_remaining_raw" ]; then
    ctx_remaining_pct=$(awk -v p="$ctx_remaining_raw" 'BEGIN{printf "%d", p}')
    extra="${extra:+$extra | }$(color_flat "ctx ${ctx_remaining_pct}%")"
fi

cost_raw=$(echo "$input" | jq -r '.cost.total_cost_usd // empty' 2>/dev/null)
if [ -n "$cost_raw" ]; then
    cost_fmt=$(awk -v c="$cost_raw" 'BEGIN{printf "$%.2f", c}')
    extra="${extra:+$extra | }$(color_flat "$cost_fmt")"
fi

line=$(printf "\033[32m%s\033[0m | %s | \033[36m%s\033[0m | session: %s | weekly: %s" \
    "$model" "$ctx_display" "$branch" \
    "$(color_pct "$session_pct")" "$(color_pct "$weekly_pct")")
[ -n "$extra" ] && line="$line | $extra"
printf "%s\n" "$line"
