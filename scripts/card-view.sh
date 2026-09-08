#!/usr/bin/env bash
# card-view.sh -- the panel: draws the current card and nothing else.
#
# It runs on the ALTERNATE SCREEN BUFFER. Clearing and repainting is not
# enough on its own: xterm.js pushes the cleared lines into scrollback, so
# after two draws the pane held both cards and could be scrolled back
# through -- which is the one thing an index card must not do. Nothing
# written to the alternate buffer ever reaches scrollback, so there is
# exactly one card, and no history behind it.
#
# Repaints when the card file's mtime changes and on SIGWINCH (a resize);
# otherwise it sleeps. Lines are WRAPPED to the pane width, not truncated:
# a split pane is often half the width the card is written to, and a card
# that loses its second half says less than no card. The body is clipped
# to the pane height, which is the one place where losing text beats
# scrolling.
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

    # One home + clear on the alternate buffer: never an append, and
    # nothing behind it to scroll to.
    printf '\033[H\033[2J'
    printf '\033[38;5;244m┌%s┐\033[0m\n' "$(printf '─%.0s' $(seq 1 $((cols - 2))))"

    if [ -f "$CARD_FILE" ]; then body="$(cat "$CARD_FILE" 2>/dev/null)"; else body="(no card yet)"; fi
    # Wrap first, clip to the pane height second: the height limit has to
    # count the rows that will actually be drawn, not the card's own lines.
    # fold -s breaks at spaces where it can; a single word longer than the
    # pane still gets cut, which is the only case where cutting is right.
    printf '%s\n' "$body" \
        | { fold -s -w $((cols - 4)) 2>/dev/null || cat; } \
        | head -n $((rows - 4)) | while IFS= read -r line; do
        line="${line:0:$((cols - 4))}"
        case "$line" in
            NOW:*|WHY:*|DONE:*|NEXT:*|SNAG:*)
                printf '\033[38;5;244m│\033[0m %s\033[38;5;250m%s\033[0m\n' \
                    "$(label "${line%%:*}:")" "${line#*:}" ;;
            @*) printf '\033[38;5;244m│ %s\033[0m\n' "$line" ;;
            "") printf '\033[38;5;244m│\033[0m\n' ;;
            # Anything else is the tail of a wrapped line: indent it so the
            # card still reads as five labelled facts rather than prose.
            *)  printf '\033[38;5;244m│\033[0m   \033[38;5;250m%s\033[0m\n' \
                    "${line:0:$((cols - 6))}" ;;
        esac
    done

    printf '\033[38;5;244m└%s┘\033[0m\n' "$(printf '─%.0s' $(seq 1 $((cols - 2))))"
}

stamp() { stat -c %Y "$CARD_FILE" 2>/dev/null || stat -f %m "$CARD_FILE" 2>/dev/null || echo 0; }

# The pane's size, as a single comparable string. Orca creates a pane and
# sizes its pty a moment later, so the FIRST draw can land at the terminal's
# default width and wrap to something twice as wide as the pane really is --
# which is what the first live run looked like. Watching the size rather than
# waiting for SIGWINCH alone means that first wrong draw corrects itself.
size() {
    local c r
    c="$(tput cols 2>/dev/null || echo 0)"
    r="$(tput lines 2>/dev/null || echo 0)"
    case "$c$r" in *[!0-9]*|"") printf '0x0' ;; *) printf '%sx%s' "$c" "$r" ;; esac
}

on_winch() { resized=1; }
trap on_winch WINCH
printf '\033[?1049h\033[?25l' 2>/dev/null   # alternate buffer, no cursor
restore() {
    printf '\033[?25h\033[?1049l' 2>/dev/null
    [ -n "$orig_stty" ] && stty "$orig_stty" 2>/dev/null
    exit 0
}
trap restore INT TERM EXIT

last=""
last_size=""
while :; do
    now="$(stamp)"
    now_size="$(size)"
    if [ "$now" != "$last" ] || [ "$now_size" != "$last_size" ] \
        || [ "$resized" -eq 1 ]; then
        last="$now"
        last_size="$now_size"
        resized=0
        draw
    fi
    sleep 0.5
done
