#!/usr/bin/env bash
# branch-guard — PreToolUse hook (matcher Bash) enforcing this template's
# branch discipline (claude-orca-yd9): solo development lands on main, in
# the one working tree the user is looking at, so the agent never starts a
# branch unprompted. Same shape as scripts/outbound-guard.sh: hook JSON on
# stdin, exit 0 silently for anything that is not a Bash command payload,
# deny by printing the hookSpecificOutput JSON (permissionDecision: "deny")
# and exiting 0 — the JSON is what blocks, never the exit code.
#
# Denied (word-boundary, anywhere in the command text, including after
# && / ; / | and inside $( )):
#   git checkout -b/-B <x>
#   git switch -c/-C/--create <x>
#   git worktree add ...
#   git branch <name>   (a first non-option argument, unless one of the
#                       delete/move/copy/list/filter flags is present:
#                       d D m M c C a r l v vv list merged no-merged
#                       contains show-current format)
#   git switch <name>   (switch only ever takes a branch; main, master
#                       and the lone dash pass)
#   git checkout <name> (a single bare word that is not main/master/dash,
#                       contains no "--", AND is a real local branch per
#                       `git show-ref --verify refs/heads/<n>` in the
#                       payload's .cwd, else $PWD) — so `git checkout
#                       somefile`, `git checkout -- path`,
#                       `git checkout HEAD~1 -- path` and
#                       `git checkout <sha> -- path` all pass.
#
# Escape hatch: the command text contains the token BRANCH_OK=1 (as an env
# prefix, e.g. `BRANCH_OK=1 git switch -c x`) -> allowed.
#
# Never denied: git branch with no name or with the flags above; git
# worktree list/remove/prune; git merge; git switch/checkout main|master;
# git log/diff/status/rebase and every other verb; git push (outbound-guard
# owns that); anything that is not a git invocation.
#
# MUST fail open, like every hook here: malformed/empty stdin, a non-Bash
# tool, a payload without a command, jq absent — all exit 0 with no output.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

# deny <reason> — emit the PreToolUse hookSpecificOutput deny JSON and exit
# 0 (same contract as scripts/outbound-guard.sh's deny(): a jq construction
# failure still fails open rather than leaving the hook non-zero).
# lib/hook.sh sits next to this file's directory whether it runs as
# scripts/branch-guard.sh or through bin/branch-guard (bin/lib links to
# scripts/lib), so no symlink resolution is needed to find it.
case "${BASH_SOURCE[0]}" in
    (*/*) . "${BASH_SOURCE[0]%/*}/lib/hook.sh" ;;
    (*)   . ./lib/hook.sh ;;
esac
deny() {
    hook_deny "$1"
    exit 0
}

DENY_REASON="branch-guard: this template is solo development on main — the live version the user sees is main's working tree, so work hidden on a branch is invisible to them. Create a branch only when the user asked or a delegated slice needs isolation: prefix the command with BRANCH_OK=1 to proceed, and merge it back into main before the turn ends (worktree-gc reports what is stranded)."

deny_branch() {
    deny "$DENY_REASON"
}

is_assignment() {
    case "$1" in
        [A-Za-z_]*=*) return 0 ;;
        *) return 1 ;;
    esac
}

PAYLOAD_CWD="$PWD"

branch_exists() {
    command -v git >/dev/null 2>&1 || return 1
    git -C "$PAYLOAD_CWD" show-ref --verify --quiet "refs/heads/$1" 2>/dev/null
}

check_checkout() {
    local name="" arg
    for arg in "$@"; do
        [ "$arg" = "--" ] && return 0
        case "$arg" in
            -b|-B) deny_branch ;;
            -*) : ;;
            *) [ -n "$name" ] || name="$arg" ;;
        esac
    done
    [ -n "$name" ] || return 0
    case "$name" in
        main|master|-|*--*) return 0 ;;
    esac
    branch_exists "$name" && deny_branch
    return 0
}

check_switch() {
    local name="" arg
    for arg in "$@"; do
        case "$arg" in
            -c|-C|--create) deny_branch ;;
            --) return 0 ;;
            -*) : ;;
            *) [ -n "$name" ] || name="$arg" ;;
        esac
    done
    [ -n "$name" ] || return 0
    case "$name" in
        -|main|master) return 0 ;;
    esac
    deny_branch
}

check_branch() {
    local name="" arg
    for arg in "$@"; do
        case "$arg" in
            -d|-D|-m|-M|-c|-C|-a|-r|-l|-v|-vv) return 0 ;;
            --list|--merged|--no-merged|--contains|--show-current|--format) return 0 ;;
            --merged=*|--no-merged=*|--contains=*|--format=*) return 0 ;;
            --) return 0 ;;
            -*) : ;;
            *) [ -n "$name" ] || name="$arg" ;;
        esac
    done
    [ -n "$name" ] || return 0
    deny_branch
}

check_worktree() {
    [ $# -ge 1 ] || return 0
    [ "$1" = "add" ] && deny_branch
    return 0
}

# check_segment — decide one command segment (the command text split at the
# shell operators, so a branch creation after &&/;/|/& or inside $( ) is
# still seen as its own git invocation). Leading env assignments are
# skipped, global git options (git -C d / -c k=v / --git-dir …) are
# stepped over, and only the four guarded verbs are examined. Anything
# else — including every non-git command — falls through as allowed.
check_segment() {
    local seg="$1" sub
    set -f
    set -- $seg
    set +f
    while [ $# -gt 0 ] && is_assignment "$1"; do
        shift
    done
    [ $# -ge 1 ] || return 0
    [ "$1" = "git" ] || return 0
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            -C|-c|--git-dir|--work-tree|--namespace)
                [ $# -ge 2 ] || return 0
                shift 2
                ;;
            --git-dir=*|--work-tree=*|--namespace=*|--no-pager|--bare|--no-replace-objects)
                shift
                ;;
            *)
                break
                ;;
        esac
    done
    [ $# -ge 1 ] || return 0
    sub="$1"
    shift
    case "$sub" in
        checkout) check_checkout "$@" ;;
        switch)   check_switch "$@" ;;
        branch)   check_branch "$@" ;;
        worktree) check_worktree "$@" ;;
    esac
    return 0
}

# ── PreToolUse (matcher Bash; JSON on stdin) ────────────────────────────────

[ -t 0 ] && exit 0
payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# One jq call: tool name, cwd, then the command (which may span lines) and
# a "." so nothing empty falls off the end of $(...).
fields=$(printf '%s' "$payload" | jq -r '(if has("tool_name") then .tool_name else "" end | tostring),
    (.cwd? // "" | tostring), (.tool_input.command? // ""), "."' 2>/dev/null) || exit 0
tool_name=${fields%%$'\n'*}; fields=${fields#*$'\n'}
cwd=${fields%%$'\n'*}; fields=${fields#*$'\n'}
cmd=${fields%.}; cmd=${cmd%$'\n'}
while [ "${cmd%$'\n'}" != "$cmd" ]; do cmd=${cmd%$'\n'}; done   # as $(...) would
[ "$tool_name" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] && PAYLOAD_CWD="$cwd"

# Fold tabs to spaces so a tab between tokens can't hide a match (same
# defensive step scripts/outbound-guard.sh takes before its rules run).
cmd_norm=${cmd//$'\t'/ }

# Every rule below is about a `git` command; most Bash calls have none.
case "$cmd_norm" in *git*) ;; *) exit 0 ;; esac

# Escape hatch: BRANCH_OK=1 anywhere in the command text, word-bounded, as
# an env prefix or after an operator.
if printf '%s' "$cmd_norm" | grep -Eq '(^|[^A-Za-z0-9_-])BRANCH_OK=1([^A-Za-z0-9_-]|$)'; then
    exit 0
fi

# Split into segments at the shell operators (GNU sed, one class per pass;
# an operator between characters simply starts a new segment).
segments=$(printf '%s\n' "$cmd_norm" | sed -e 's/[;&|`]/\n/g' -e 's/[$](/\n/g' -e 's/[(){}]/\n/g')

while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    check_segment "$seg"
done <<EOF
$segments
EOF

exit 0
