#!/usr/bin/env bash
# session-title — UserPromptSubmit hook: on a worktree session's first
# prompt, rename the tmux window to a short kebab slug of that prompt, so
# fleet windows read as what they're doing instead of an adjective-noun
# worktree name. See .claude/plans/worktree-sessions.md and
# beads_claude_docker-7bam.
#
# Slug: first four words of the prompt after dropping stop words (a an
# the to of for and or in on with please can you my this that it),
# letters and digits only per word, lowercase, kebab-joined, truncated to
# 24 chars without a trailing dash.
#
# State: one flag file per session under $FLEET_STATE_DIR (default
# $HOME/.claude/cache/fleet), named <sanitized-session-id>.titled --
# presence means this session's window has already been (successfully)
# renamed; same sanitize/state-dir pattern as scripts/lane.sh and
# scripts/outbound-guard.sh. Written only once an actual rename happens,
# so a first prompt with no nameable words (every token a stop word, or
# no letters/digits at all) leaves the session untitled and eligible to
# try again on its next prompt, rather than being silently skipped
# forever.
#
# MUST fail open, like every hook here: never a non-zero exit, silent on
# malformed stdin, a missing TMUX_PANE, a pane path outside
# .claude/worktrees/, or any tmux/git/python failure along the way --
# this must never break prompt submit.
set -u

STATE_DIR="${FLEET_STATE_DIR:-${HOME:-}/.claude/cache/fleet}"

sanitize_id() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9._-'
}

state_file() {
    printf '%s/%s.titled\n' "$STATE_DIR" "$1"
}

# Stop words dropped before counting a prompt's first four words.
STOP_WORDS="a an the to of for and or in on with please can you my this that it"

[ -n "${TMUX_PANE:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

[ -t 0 ] && exit 0
payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

has_sid=$(printf '%s' "$payload" | jq -r 'has("session_id")' 2>/dev/null) || exit 0
[ "$has_sid" = "true" ] || exit 0
sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
sid=$(sanitize_id "$sid")
[ -n "$sid" ] || exit 0

has_prompt=$(printf '%s' "$payload" | jq -r 'has("prompt")' 2>/dev/null) || exit 0
[ "$has_prompt" = "true" ] || exit 0
prompt=$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null) || exit 0
[ -n "$prompt" ] || exit 0

f=$(state_file "$sid")
[ -f "$f" ] && exit 0

pane_path=$(tmux display -p -t "$TMUX_PANE" '#{pane_current_path}' 2>/dev/null) || exit 0
[ -n "$pane_path" ] || exit 0
case "$pane_path" in
    */.claude/worktrees/*) ;;
    *) exit 0 ;;
esac

window_id=$(tmux display -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null) || exit 0
[ -n "$window_id" ] || exit 0

slug=$(printf '%s' "$prompt" | STOP_WORDS="$STOP_WORDS" python3 -c '
import os
import re
import sys

stop = set(os.environ.get("STOP_WORDS", "").split())
text = sys.stdin.read()
words = []
for tok in text.split():
    w = re.sub(r"[^A-Za-z0-9]", "", tok).lower()
    if not w or w in stop:
        continue
    words.append(w)
    if len(words) == 4:
        break
slug = "-".join(words)[:24].rstrip("-")
sys.stdout.write(slug)
' 2>/dev/null) || exit 0

[ -n "$slug" ] || exit 0

tmux rename-window -t "$window_id" "$slug" 2>/dev/null || exit 0

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
: > "$f" 2>/dev/null

exit 0
