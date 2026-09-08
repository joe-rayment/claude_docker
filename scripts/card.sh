#!/usr/bin/env bash
#
# card.sh -- control for the index-card panel beside this terminal
# (claude-orca-ao7.1, design claude-orca-ao7). Subcommands:
#
#   card on          split THIS terminal, run card-view.sh in the new pane,
#                     rename it CARD, record the pane handle and "on" state
#   card off          close the recorded pane, record "off" state
#   card toggle       flip on<->off
#   card status       print the current state and recorded pane, one line
#   card autostart    the SessionStart entry point: `on` when the state is
#                     on or unset (default on), nothing when it is off, and
#                     never a second pane while the recorded one is live
#
# This terminal's own identity comes from ORCA_PANE_KEY ("<tabId>:<leafId>",
# set by Orca in every terminal's environment): the leafId half is matched
# against `orca terminal list --json` to find this terminal's own handle.
#
# FAILS OPEN, ALWAYS -- this runs from a SessionStart hook. No
# ORCA_PANE_KEY, no orca CLI on PATH, an unreachable runtime, a stale
# handle: print ONE explanatory line and exit 0. Never a non-zero exit.
# jq is used when present; python3 is the fallback (same idiom as
# lane.sh's --reset), then a plain-sed best effort -- never a hard
# dependency on either.
#
# State lives under $PROJECT_DIR/.claude-dev/run (created if missing):
#   card.state  "on" or "off"; absent means on
#   card.pane   the recorded pane's terminal handle
#
# bash 3.2 clean (scripts/lint-bash32.sh scans all of scripts/).

set -u

_resolve_script_path() {
    local src="${BASH_SOURCE[0]}" link dir
    while [ -L "$src" ]; do
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(cd "$(dirname "$src")" && pwd)"; src="$dir/$link" ;;
        esac
    done
    printf '%s' "$src"
}
SCRIPT_DIR="$(cd "$(dirname "$(_resolve_script_path)")" && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"

RUN_DIR="${PROJECT_DIR:-/workspace/claude-orca}/.claude-dev/run"
STATE_FILE="$RUN_DIR/card.state"
PANE_FILE="$RUN_DIR/card.pane"
VIEW="$SCRIPT_DIR/card-view.sh"

# stderr, not stdout: several of these run inside `handle="$(_own_handle)"`
# style command substitutions, where a stdout write would be swallowed into
# the captured value instead of reaching the terminal.
note() { printf '%s\n' "$*" >&2; }

# ── JSON helpers: jq, then python3, then a plain-sed best effort ────────────

_handle_for_leaf() {
    local json="$1" leaf="$2"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r --arg l "$leaf" \
            '(.result.terminals // []) | map(select(.leafId == $l)) | (.[0].handle // empty)' \
            2>/dev/null
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" | python3 -c '
import json, sys
leaf = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for t in (data.get("result") or {}).get("terminals") or []:
    if t.get("leafId") == leaf:
        print(t.get("handle") or "")
        break
' "$leaf" 2>/dev/null
        return 0
    fi
    printf '%s' "$json" | grep -o "{[^{}]*\"leafId\":\"$leaf\"[^{}]*}" 2>/dev/null |
        sed -n 's/.*"handle":"\([^"]*\)".*/\1/p' | head -1
}

_terminal_is_live() {
    local handle="$1" json
    command -v orca >/dev/null 2>&1 || return 1
    json="$(orca terminal list --json 2>/dev/null)" || true
    [ -n "$json" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -e --arg h "$handle" \
            '(.result.terminals // []) | any(.handle == $h)' >/dev/null 2>&1
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" | python3 -c '
import json, sys
h = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for t in (data.get("result") or {}).get("terminals") or []:
    if t.get("handle") == h:
        sys.exit(0)
sys.exit(1)
' "$handle" 2>/dev/null
        return $?
    fi
    printf '%s' "$json" | grep -q "\"handle\":\"$handle\""
}

_split_handle() {
    local json="$1"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r '.result.split.handle // empty' 2>/dev/null
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(((data.get("result") or {}).get("split") or {}).get("handle") or "")
' 2>/dev/null
        return 0
    fi
    printf '%s' "$json" | sed -n 's/.*"split":{"handle":"\([^"]*\)".*/\1/p'
}

# ── state: card.state (on/off, absent means on) + card.pane (the handle) ───

_read_state() {
    local s
    if [ -f "$STATE_FILE" ]; then
        s="$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null)"
        case "$s" in on|off) printf '%s' "$s"; return 0 ;; esac
    fi
    printf 'on'
}

_write_state() {
    mkdir -p "$RUN_DIR" 2>/dev/null || return 1
    printf '%s' "$1" > "$STATE_FILE" 2>/dev/null
}

_read_pane() {
    [ -f "$PANE_FILE" ] && tr -d '[:space:]' < "$PANE_FILE" 2>/dev/null
    return 0
}

_write_pane() {
    mkdir -p "$RUN_DIR" 2>/dev/null || return 1
    printf '%s' "$1" > "$PANE_FILE" 2>/dev/null
}

_clear_pane() {
    rm -f "$PANE_FILE" 2>/dev/null
    return 0
}

# ── resolve THIS terminal's own handle from ORCA_PANE_KEY ──────────────────

_own_handle() {
    local key="${ORCA_PANE_KEY:-}" leaf list_json h
    if [ -z "$key" ]; then
        note "[card] no ORCA_PANE_KEY in this terminal -- skipping"
        return 1
    fi
    if ! command -v orca >/dev/null 2>&1; then
        note "[card] no orca CLI on PATH -- skipping"
        return 1
    fi
    leaf="${key#*:}"
    list_json="$(orca terminal list --json 2>/dev/null)" || true
    if [ -z "$list_json" ]; then
        note "[card] orca runtime unreachable -- skipping"
        return 1
    fi
    h="$(_handle_for_leaf "$list_json" "$leaf")"
    if [ -z "$h" ]; then
        note "[card] could not resolve this terminal's own handle -- skipping"
        return 1
    fi
    printf '%s' "$h"
    return 0
}

# ── subcommands ──────────────────────────────────────────────────────────

cmd_on() {
    local handle pane result new_handle
    pane="$(_read_pane)"
    if [ -n "$pane" ] && _terminal_is_live "$pane"; then
        _write_state on
        note "[card] on -- already open (pane $pane)"
        return 0
    fi
    handle="$(_own_handle)" || return 0
    result="$(orca terminal split --terminal "$handle" --direction vertical \
        --command "$VIEW" --json 2>/dev/null)" || true
    new_handle="$(_split_handle "$result")"
    if [ -z "$new_handle" ]; then
        note "[card] could not open the card pane -- skipping"
        return 0
    fi
    orca terminal rename --terminal "$new_handle" --title CARD >/dev/null 2>&1 || true
    _write_pane "$new_handle"
    _write_state on
    note "[card] on (pane $new_handle)"
}

cmd_off() {
    local pane
    pane="$(_read_pane)"
    if [ -n "$pane" ] && command -v orca >/dev/null 2>&1; then
        orca terminal close --terminal "$pane" >/dev/null 2>&1 || true
    fi
    _clear_pane
    _write_state off
    note "[card] off"
}

cmd_toggle() {
    if [ "$(_read_state)" = "off" ]; then
        cmd_on
    else
        cmd_off
    fi
}

cmd_status() {
    local state pane
    state="$(_read_state)"
    pane="$(_read_pane)"
    if [ -n "$pane" ]; then
        note "[card] $state (pane $pane)"
    else
        note "[card] $state (no pane recorded)"
    fi
}

cmd_autostart() {
    [ "$(_read_state)" = "off" ] && return 0
    cmd_on
}

case "${1:-}" in
    on)        cmd_on ;;
    off)       cmd_off ;;
    toggle)    cmd_toggle ;;
    status)    cmd_status ;;
    autostart) cmd_autostart ;;
    *)
        cat <<'EOF'
usage: card on|off|toggle|status|autostart
EOF
        ;;
esac
exit 0
