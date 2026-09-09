#!/usr/bin/env bash
#
# card.sh -- control for the index-card panel, in a tab of its own
# (claude-orca-ao7.1, design claude-orca-ao7). Subcommands:
#
#   card on           open a CARD tab running card-view.sh, record its
#                     handle and "on" state
#   card off          close the recorded tab, record "off" state
#   card toggle       flip on<->off
#   card status       print the current state and recorded tab, one line
#   card autostart    the SessionStart entry point: `on` when the state is
#                     on or unset (default on), nothing when it is off, and
#                     never a second tab while the recorded one is live
#
# A TAB, NOT A SPLIT. This was `orca terminal split --direction vertical`
# until 2026-09-08, which put the card beside the session in the same tab
# and took its columns: every repaint re-flowed the session's own pane and
# the result was unreadable. `orca terminal create` gives the card a tab of
# its own, so nothing it does can move the text you are reading.
#
# Two things learned by running the CLI rather than reading it: `create`
# returns the handle at .result.terminal.handle (`split` used
# .result.split.handle), and it can land as a BACKGROUND handle -- running,
# but not adopted by the UI, which is a card nobody can see. Its own
# warning names the cure, `orca terminal switch`, so a background create is
# revealed with one switch and the focus handed straight back to the
# terminal that asked (ORCA_TERMINAL_HANDLE, which Orca sets in every
# terminal's environment). Both switches were verified live before this
# was written.
#
# FAILS OPEN, ALWAYS -- this runs from a SessionStart hook. No orca CLI on
# PATH, an unreachable runtime, a create the UI refuses, a stale handle:
# print ONE explanatory line and exit 0. Never a non-zero exit.
# jq is used when present; python3 is the fallback (same idiom as
# lane.sh's --reset), then a plain-sed best effort -- never a hard
# dependency on either.
#
# State lives under $PROJECT_DIR/.claude-dev/run (created if missing):
#   card.state  "on" or "off"; absent means on
#   card.tab    the recorded tab's terminal handle
#   card.pane   the pre-2026-09-08 split pane's handle, closed and removed
#               on the next `off`/`toggle` so a folder that carried one does
#               not keep a split it can no longer control
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

PROJECT_ROOT="${PROJECT_DIR:-/workspace/claude-orca}"
RUN_DIR="$PROJECT_ROOT/.claude-dev/run"
STATE_FILE="$RUN_DIR/card.state"
TAB_FILE="$RUN_DIR/card.tab"
LEGACY_PANE_FILE="$RUN_DIR/card.pane"
VIEW="$SCRIPT_DIR/card-view.sh"

# stderr, not stdout: several of these run inside `pane="$(_read_pane)"`
# style command substitutions, where a stdout write would be swallowed into
# the captured value instead of reaching the terminal.
note() { printf '%s\n' "$*" >&2; }


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

_created_handle() {
    local json="$1"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r '.result.terminal.handle // empty' 2>/dev/null
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(((data.get("result") or {}).get("terminal") or {}).get("handle") or "")
' 2>/dev/null
        return 0
    fi
    printf '%s' "$json" | sed -n 's/.*"terminal":{"handle":"\([^"]*\)".*/\1/p'
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
    [ -f "$TAB_FILE" ] && tr -d '[:space:]' < "$TAB_FILE" 2>/dev/null
    return 0
}

_write_pane() {
    mkdir -p "$RUN_DIR" 2>/dev/null || return 1
    printf '%s' "$1" > "$TAB_FILE" 2>/dev/null
}

_clear_pane() {
    rm -f "$TAB_FILE" 2>/dev/null
    return 0
}

# The split pane a folder was left holding by the pre-tab card. Closed once,
# on the first off/toggle after the upgrade, then forgotten -- without this
# it stays on screen taking the session's columns with nothing left that
# knows its handle.
_close_legacy_pane() {
    local old
    [ -f "$LEGACY_PANE_FILE" ] || return 0
    old="$(tr -d '[:space:]' < "$LEGACY_PANE_FILE" 2>/dev/null)"
    if [ -n "$old" ] && command -v orca >/dev/null 2>&1; then
        orca terminal close --terminal "$old" >/dev/null 2>&1 || true
    fi
    rm -f "$LEGACY_PANE_FILE" 2>/dev/null
    return 0
}


# Any OTHER tab called CARD. A create whose handle never made it into
# card.tab -- a crash between the two, a folder opened twice -- leaves a tab
# nothing can close, and they accumulate one per attempt. Seen live on
# 2026-09-08: two CARD terminals, one of them untracked. Title is the only
# handle we have on them, so title is what this matches.
_close_stray_cards() {
    local list keep h
    command -v orca >/dev/null 2>&1 || return 0
    keep="$(_read_pane)"
    list="$(orca terminal list --json 2>/dev/null)" || return 0
    [ -n "$list" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    for h in $(printf '%s' "$list" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for t in ((data.get("result") or {}).get("terminals") or []):
    if (t.get("title") or "").strip() == "CARD" and t.get("handle"):
        print(t["handle"])
' 2>/dev/null); do
        [ "$h" = "$keep" ] && continue
        orca terminal close --terminal "$h" >/dev/null 2>&1 || true
    done
    return 0
}

# ── subcommands ──────────────────────────────────────────────────────────

cmd_on() {
    local pane result new_handle mine
    pane="$(_read_pane)"
    if [ -n "$pane" ] && _terminal_is_live "$pane"; then
        _write_state on
        note "[card] on -- already open (tab $pane)"
        return 0
    fi
    _close_legacy_pane
    _close_stray_cards
    command -v orca >/dev/null 2>&1 || {
        note "[card] no orca CLI on PATH -- skipping"
        return 0
    }
    # --worktree keeps the tab in THIS folder's checkout rather than
    # whichever worktree the UI happens to be looking at.
    result="$(orca terminal create --worktree "path:$PROJECT_ROOT" \
        --title CARD --command "$VIEW" --json 2>/dev/null)" || true
    new_handle="$(_created_handle "$result")"
    if [ -z "$new_handle" ]; then
        note "[card] could not open the card tab -- skipping"
        return 0
    fi
    # A create that the UI could not adopt is running but invisible, which
    # is the one outcome worse than no card at all. One switch reveals it;
    # the second hands focus back, so `on` never leaves you typing into the
    # card. Both are best-effort: an unreachable runtime must not turn a
    # SessionStart hook into an error.
    mine="${ORCA_TERMINAL_HANDLE:-}"
    case "$result" in
        *'"surface": "background"'*|*'"surface":"background"'*|*'could not make it discoverable'*)
            orca terminal switch --terminal "$new_handle" >/dev/null 2>&1 || true
            [ -n "$mine" ] && { orca terminal switch --terminal "$mine" >/dev/null 2>&1 || true; }
            ;;
    esac
    _write_pane "$new_handle"
    _write_state on
    note "[card] on (tab $new_handle)"
}

cmd_off() {
    local pane
    pane="$(_read_pane)"
    if [ -n "$pane" ] && command -v orca >/dev/null 2>&1; then
        orca terminal close --terminal "$pane" >/dev/null 2>&1 || true
    fi
    _close_legacy_pane
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
