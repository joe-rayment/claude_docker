#!/bin/bash
# Claude Code statusline — model, context, branch, usage limits.
# Receives JSON session data on stdin. One jq call reads every field and one
# awk call formats every number: this runs after every assistant message.
#
# Usage limits come from the `rate_limits` Claude Code puts in this JSON for
# claude.ai subscribers (after the session's first reply); "?" until then.
# They used to be fetched from the OAuth usage API with the stored token --
# no longer needed, and no script here reads that token any more.

input=$(cat)

# One field per line, then "." so an empty last field survives $(...).
f=$(printf '%s' "$input" | jq -r '
    (.model.display_name // "unknown"),
    (.context_window.used_percentage // 0),
    (.prompt_cache.hit_ratio // ""),
    (.context_window.remaining_percentage // ""),
    (.cost.total_cost_usd // ""),
    (.rate_limits.five_hour.used_percentage // "?"),
    (.rate_limits.seven_day.used_percentage // "?"),
    "." | tostring | gsub("\n"; " ")' 2>/dev/null)
model=${f%%$'\n'*}; f=${f#*$'\n'}
ctx_raw=${f%%$'\n'*}; f=${f#*$'\n'}
cache_hit_raw=${f%%$'\n'*}; f=${f#*$'\n'}
ctx_remaining_raw=${f%%$'\n'*}; f=${f#*$'\n'}
cost_raw=${f%%$'\n'*}; f=${f#*$'\n'}
session_raw=${f%%$'\n'*}; f=${f#*$'\n'}
weekly_raw=${f%%$'\n'*}

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

# "-" marks an optional segment whose field is absent.
read -r ctx_pct session_pct weekly_pct cache_pct ctx_remaining_pct cost_fmt < <(
    awk -v c="$ctx_raw" -v s="$session_raw" -v w="$weekly_raw" \
        -v h="$cache_hit_raw" -v r="$ctx_remaining_raw" -v k="$cost_raw" '
    function i(x) { return sprintf("%d", x) }
    BEGIN {
        printf "%s %s %s %s %s %s\n", i(c),
            (s == "?" ? "?" : i(s)), (w == "?" ? "?" : i(w)),
            (h == "" ? "-" : sprintf("%d", h * 100)),
            (r == "" ? "-" : i(r)),
            (k == "" ? "-" : sprintf("$%.2f", k))
    }')

# Build context bar (10 dots)
filled=$((ctx_pct / 10))
empty=$((10 - filled))
bar=""
for ((i=0; i<filled; i++)); do bar+="●"; done
for ((i=0; i<empty; i++)); do bar+="○"; done

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
    if [ "$1" = "?" ]; then
        color_by_threshold "?" "?" 70 90
    else
        color_by_threshold "$1" "$1%" 70 90
    fi
}

# Flat color for the optional segments: cache-hit and context-remaining are
# "higher is better", so the severity ramp doesn't apply.
color_flat() {
    printf "\033[34m%s\033[0m" "$1"
}

ctx_display=$(color_by_threshold "$ctx_pct" "$bar $ctx_pct%" 40 75)

# Optional segments (Claude Code >=2.1.251): each is omitted, not shown
# empty, when its field is absent.
extra=""
[ "$cache_pct" != "-" ] && extra="${extra:+$extra | }$(color_flat "cache ${cache_pct}%")"
[ "$ctx_remaining_pct" != "-" ] && extra="${extra:+$extra | }$(color_flat "ctx ${ctx_remaining_pct}%")"
[ "$cost_fmt" != "-" ] && extra="${extra:+$extra | }$(color_flat "$cost_fmt")"

line=$(printf "\033[32m%s\033[0m | %s | \033[36m%s\033[0m | session: %s | weekly: %s" \
    "$model" "$ctx_display" "$branch" \
    "$(color_pct "$session_pct")" "$(color_pct "$weekly_pct")")
[ -n "$extra" ] && line="$line | $extra"
printf "%s\n" "$line"
