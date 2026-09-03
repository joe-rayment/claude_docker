#!/usr/bin/env bash
# peers — SessionStart hook: print one line naming the other live Claude
# sessions on this tmux server, so side sessions coordinate by SendMessage
# instead of editing each other's files. See
# .claude/plans/worktree-sessions.md and beads_claude_docker-7bam.
#
# Prints exactly one line when inside tmux:
#   [peers] you: <branch>@<window> · live: <window> (<branch>), … · coordinate with SendMessage, not by editing their files
#   [peers] you: <branch>@<window> · no other live sessions
# Prints nothing outside tmux.
#
# "Other live Claude session" = any OTHER pane on the current tmux server
# (tmux list-panes -a, so across every session/window, not just this
# window) whose pane_current_command is literally "claude", OR whose
# pane_current_path is under a .claude/worktrees/ directory -- a worktree
# pane counts as a live fleet session even mid-build/mid-command, not only
# while "claude" is the exact foreground process. Multiple panes in the
# same window are reported once (deduped by window id) since the output
# names windows, not panes.
#
# MUST fail open, like every hook here: prints nothing and always exits 0
# outside tmux, with no $TMUX_PANE, or on any tmux/git failure along the
# way -- this must never break session start.
set -u

[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

TAB=$'\t'

# branch_of <path> — the git branch checked out at <path> via `git branch
# --show-current`, or "-" if that's empty (not a repo, detached HEAD).
branch_of() {
    local path="$1" b
    b=$(git -C "$path" branch --show-current 2>/dev/null)
    [ -n "$b" ] || b="-"
    printf '%s\n' "$b"
}

my_window=$(tmux display -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null) || exit 0
my_path=$(tmux display -p -t "$TMUX_PANE" '#{pane_current_path}' 2>/dev/null) || exit 0
[ -n "$my_window" ] || exit 0
my_branch=$(branch_of "$my_path")

peers=""
seen_windows=" "
while IFS="$TAB" read -r pane_id pane_cmd pane_path window_id window_name; do
    [ -n "$pane_id" ] || continue
    [ "$pane_id" = "$TMUX_PANE" ] && continue

    live=0
    [ "$pane_cmd" = "claude" ] && live=1
    case "$pane_path" in
        */.claude/worktrees/*) live=1 ;;
    esac
    [ "$live" -eq 1 ] || continue

    case "$seen_windows" in
        *" $window_id "*) continue ;;
    esac
    seen_windows="$seen_windows$window_id "

    branch=$(branch_of "$pane_path")
    entry="$window_name ($branch)"
    if [ -n "$peers" ]; then
        peers="$peers, $entry"
    else
        peers="$entry"
    fi
done < <(tmux list-panes -a -F "#{pane_id}${TAB}#{pane_current_command}${TAB}#{pane_current_path}${TAB}#{window_id}${TAB}#{window_name}" 2>/dev/null)

if [ -n "$peers" ]; then
    printf '[peers] you: %s@%s · live: %s · coordinate with SendMessage, not by editing their files\n' "$my_branch" "$my_window" "$peers"
else
    printf '[peers] you: %s@%s · no other live sessions\n' "$my_branch" "$my_window"
fi

exit 0
