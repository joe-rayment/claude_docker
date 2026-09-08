#!/usr/bin/env bash
# card-hook.sh -- the Stop hook's front half.
#
# Why this exists rather than the hook calling card-update.sh directly: the
# hook's payload arrives on STDIN, and the summary the payload leads to takes
# a model call (~45s on a full turn). Backgrounding the whole thing to keep
# the turn fast would background the read as well, and a backgrounded reader
# races the parent's exit for a pipe that is about to close. So the read
# happens here, in the foreground, where it is instant -- and only the slow
# half is detached.
#
# Fails open like every hook in this template: no payload, no card-update, no
# writable temp dir -- say nothing, exit 0.

set -u

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
UPDATE="$SCRIPT_DIR/card-update.sh"

[ -x "$UPDATE" ] || exit 0
[ -t 0 ] && exit 0                       # no piped payload: nothing to summarise

payload="$(mktemp 2>/dev/null)" || exit 0
cat > "$payload" 2>/dev/null || { rm -f "$payload"; exit 0; }
if [ ! -s "$payload" ]; then
    rm -f "$payload"
    exit 0
fi

# The slow half, off the turn's critical path. setsid where it exists, so the
# model call is not killed when the session's process group goes away.
if command -v setsid >/dev/null 2>&1; then
    setsid sh -c '"$1" < "$2"; rm -f "$2"' _ "$UPDATE" "$payload" \
        >/dev/null 2>&1 &
else
    ( "$UPDATE" < "$payload"; rm -f "$payload" ) >/dev/null 2>&1 &
fi

exit 0
