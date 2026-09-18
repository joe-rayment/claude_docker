#!/usr/bin/env bash
# session-end-audit.sh — SessionEnd hook: dev-log a note when the session
# ends with a dirty git tree, and run worktree-gc so work stranded in
# worktrees and branches is dev-logged too. Reads the hook JSON payload
# from stdin for `cwd` (falls back to $PWD); silent and fail-open on any
# error so it can never break session teardown.
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

if [ -n "$status_lines" ]; then
    count="$(printf '%s\n' "$status_lines" | grep -c .)" || count=0
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch="unknown"
    command -v dev-log >/dev/null 2>&1 && \
        dev-log change "session ended with dirty tree: ${count} file(s) on ${branch}" "uncommitted changes present at SessionEnd" >/dev/null 2>&1
fi

# Even a clean tree can strand work in a worktree or on a branch the live
# version does not contain; the sweep reports each one STRANDED and the
# line is dev-logged so it survives the session. Fail-open: the audit's
# exit stays 0 whatever worktree-gc finds.
gc="$SCRIPT_DIR/worktree-gc.sh"
if [ -x "$gc" ]; then
    gc_out="$("$gc" --quiet --project "$cwd" 2>/dev/null)" || true
    while IFS= read -r line; do
        case "$line" in
            STRANDED*)
                command -v dev-log >/dev/null 2>&1 && \
                    dev-log change "session ended with stranded work: $line" \
                        "worktree-gc reported stranded work at SessionEnd" >/dev/null 2>&1
                ;;
        esac
    done <<EOF
$gc_out
EOF
fi

exit 0
