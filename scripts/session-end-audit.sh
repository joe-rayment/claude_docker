#!/usr/bin/env bash
# session-end-audit.sh — SessionEnd hook: dev-log a note when the session
# ends with a dirty git tree. Reads the hook JSON payload from stdin for
# `cwd` (falls back to $PWD); silent and fail-open on any error so it can
# never break session teardown.
set -u

payload="$(cat 2>/dev/null || true)"

cwd=""
if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
    if printf '%s' "$payload" | jq -e 'has("cwd")' >/dev/null 2>&1; then
        cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)" || cwd=""
    fi
fi
[ -n "$cwd" ] || cwd="$PWD"

command -v git >/dev/null 2>&1 || exit 0
[ -d "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

status_lines="$(git status --porcelain 2>/dev/null)" || exit 0
[ -n "$status_lines" ] || exit 0

count="$(printf '%s\n' "$status_lines" | grep -c .)" || count=0
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch="unknown"

command -v dev-log >/dev/null 2>&1 && \
    dev-log change "session ended with dirty tree: ${count} file(s) on ${branch}" "uncommitted changes present at SessionEnd" >/dev/null 2>&1

exit 0
