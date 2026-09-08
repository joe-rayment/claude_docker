#!/usr/bin/env bash
# card-view.sh -- the panel: draws the current card and nothing else. It
# clears the screen and repaints on every draw, so the pane can never
# scroll and there is never more than one card visible. Repaints when the
# card file's mtime changes and on SIGWINCH (a resize); otherwise it
# sleeps. Every line is clipped to the pane width, and the card body is
# clipped to the pane height.
#
# Fails open: no CARD_FILE yet, no tput -- draw what can be drawn (a
# placeholder, a guessed size) and keep going. This is a display, not a
# hook, but the same rule applies: never the reason anything stops.
set -uo pipefail

CARD_FILE="${CARD_FILE:-${PROJECT_DIR:-/workspace/claude-orca}/.claude-dev/run/card.md}"

resized=1
orig_stty=""
if [ -t 1 ]; then
    orig_stty="$(stty -g 2>/dev/null || true)"
    # A raw newline is one row here, not a row-plus-carriage-return: leaves
    # every clipped line exactly as wide as it was drawn.
    stty -onlcr 2>/dev/null || true
fi

label() { printf '\033[38;5;244m%s\033[0m' "$1"; }

draw() {
    local cols rows body
    cols="$(tput cols 2>/dev/null || echo 60)"
    rows="$(tput lines 2>/dev/null || echo 24)"
    case "$cols" in *[!0-9]*|"") cols=60 ;; esac
    case "$rows" in *[!0-9]*|"") rows=24 ;; esac
    [ "$cols" -gt 76 ] && cols=76
    [ "$cols" -lt 10 ] && cols=10
    [ "$rows" -lt 4 ] && rows=4

    # One clear + one repaint: never an append, so the pane cannot scroll.
    printf '\033[H\033[2J'
    printf '\033[38;5;244m┌%s┐\033[0m\n' "$(printf '─%.0s' $(seq 1 $((cols - 2))))"

    if [ -f "$CARD_FILE" ]; then body="$(cat "$CARD_FILE" 2>/dev/null)"; else body="(no card yet)"; fi
    printf '%s\n' "$body" | head -n $((rows - 4)) | while IFS= read -r line; do
        line="${line:0:$((cols - 4))}"
        case "$line" in
            NOW:*|WHY:*|DONE:*|NEXT:*|SNAG:*)
                printf '\033[38;5;244m│\033[0m %s\033[38;5;250m%s\033[0m\n' \
                    "$(label "${line%%:*}:")" "${line#*:}" ;;
            @*) printf '\033[38;5;244m│ %s\033[0m\n' "$line" ;;
            *)  printf '\033[38;5;244m│\033[0m \033[38;5;250m%s\033[0m\n' "$line" ;;
        esac
    done

    printf '\033[38;5;244m└%s┘\033[0m\n' "$(printf '─%.0s' $(seq 1 $((cols - 2))))"
}

stamp() { stat -c %Y "$CARD_FILE" 2>/dev/null || stat -f %m "$CARD_FILE" 2>/dev/null || echo 0; }

on_winch() { resized=1; }
trap on_winch WINCH
printf '\033[?25l' 2>/dev/null                       # no cursor in a panel
restore() {
    printf '\033[?25h\n' 2>/dev/null
    [ -n "$orig_stty" ] && stty "$orig_stty" 2>/dev/null
    exit 0
}
trap restore INT TERM EXIT

last=""
while :; do
    now="$(stamp)"
    if [ "$now" != "$last" ] || [ "$resized" -eq 1 ]; then
        last="$now"
        resized=0
        draw
    fi
    sleep 0.5
done
