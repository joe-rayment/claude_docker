#!/usr/bin/env bash
#
# frozen-hook.sh — enforce a bead's FROZEN contract in git, for every agent
# (claude-orca-2m5). The Claude-side PreToolUse contract-gate only reaches
# Claude workers; opencode/codex/gemini run none of this repo's hooks, so a
# frozen test file could be edited after its RED commit. A pre-commit hook
# reaches all of them, because they all commit through git.
#
#   install_frozen_hook <worktree-dir> <bead-id>     -> prints the hooks dir
#   frozen_hook_env <hooks-dir>                      -> the git env config
#
# The hook lives in a PRIVATE hooks dir per worktree,
# <abs-git-dir>/claude-orca-hooks — for a linked worktree that is its own
# .git/worktrees/<name>/, for the main tree the .git/ beside it — and it is
# switched on for the worker's processes only through git's env config
# (git >= 2.31: GIT_CONFIG_COUNT / GIT_CONFIG_KEY_<n> / GIT_CONFIG_VALUE_<n>
# beat repo config). No repo config is changed and no tracked file is
# touched. The shared hooks dir the first design wrote into was wrong twice
# over: it is shared by every worktree, so one claude-orca-bead file would
# be overwritten by parallel dispatches, and in this repo .beads/hooks is
# TRACKED, so writing into it would rewrite tracked files in the main tree
# — and this repo's own core.hooksPath is a stale absolute path from an
# older mount (/workspace/.beads/hooks), which is what the "mkdir:
# Permission denied" on dispatch was (claude-orca-cdu).
#
# Before anything is written, the repo's OWN hooks dir — what
# `git rev-parse --git-path hooks` answers, made absolute — is recorded in
# <dir>/claude-orca-chain. The generated pre-commit chains to that dir's
# pre-commit first when it exists, is executable and is not this same file;
# its failure still aborts the commit. Nothing in the repo's own hooks dir
# is renamed or removed. Idempotent: a second install replaces the
# generated hook and the bead id file in place.
#
# The hook itself is fail-open everywhere: no bd on PATH, no bead id, a bd
# failure, no RED-AT sha, or a sha not in this repo's history all mean exit
# 0 — tooling must never block a commit. Only this exact case fails:
#
#   RED-AT exists in this repo's history
#   AND the staged diff touches a path listed on the bead's FROZEN line(s)
#
# -> "frozen: <path> is frozen from <sha> (<bead>); do not commit changes
#     to it -- if the test is wrong, run: bd supersede <bead>"

_FROZEN_HOOK_MARKER="claude-orca frozen-hook"

# frozen_hook_body <bead-id> — print the pre-commit hook script.
frozen_hook_body() {
    cat <<'BODY'
#!/bin/sh
# claude-orca frozen-hook v2 (generated; edits are overwritten by the installer)
self_dir="$(cd "$(dirname "$0")" && pwd)"
chain="$self_dir/claude-orca-chain"
if [ -f "$chain" ]; then
    own_dir="$(cat "$chain" 2>/dev/null)"
    if [ -n "$own_dir" ] && [ -x "$own_dir/pre-commit" ]; then
        own_real="$(cd "$own_dir" && pwd)/pre-commit"
        self_real="$self_dir/pre-commit"
        if [ "$own_real" != "$self_real" ]; then
            "$own_real" "$@" || exit $?
        fi
    fi
fi
bead="${CLAUDE_ORCA_BEAD:-}"
if [ -z "$bead" ] && [ -f "$self_dir/claude-orca-bead" ]; then
    bead="$(cat "$self_dir/claude-orca-bead" 2>/dev/null)"
fi
[ -n "$bead" ] || exit 0
command -v bd >/dev/null 2>&1 || exit 0
show="$(bd show "$bead" 2>/dev/null)" || exit 0

# RED-AT sha: a note matching RED-AT[:=] <sha>, else a commit whose subject
# starts with "RED:" and mentions the bead.
sha="$(printf '%s\n' "$show" |
    sed -n 's/.*RED-AT[:=] *\([0-9a-f]\{7,40\}\).*/\1/p' |
    head -n 1)"
if [ -z "$sha" ]; then
    sha="$(git log --format='%H %s' 2>/dev/null |
        while read -r commit subject_rest; do
            case "$subject_rest" in
                RED:*) case "$subject_rest" in *" $bead"*|*"$bead,"*)
                           echo "$commit"; break ;;
                esac ;;
            esac
        done |
        head -n 1)"
fi
[ -n "$sha" ] || exit 0
git cat-file -e "${sha}^{commit}" 2>/dev/null || exit 0

paths="$(printf '%s\n' "$show" |
    grep 'FROZEN:' |
    grep -oE '[^ :]+\.(bats|sh|py|js|md)' |
    sort -u)"
[ -n "$paths" ] || exit 0

staged="$(git diff --cached --name-only 2>/dev/null)"
[ -n "$staged" ] || exit 0

for path in $paths; do
    if printf '%s\n' "$staged" | grep -Fxq "$path"; then
        printf 'frozen: %s is frozen from %s (%s); do not commit changes to it -- if the test is wrong, run: bd supersede %s\n' \
            "$path" "$sha" "$bead" "$bead" >&2
        exit 1
    fi
done
exit 0
BODY
}

# frozen_hook_env <hooks-dir> — print the three git env-config assignments
# that make the prefixed processes use <hooks-dir> as their hooks dir, one
# per line (GIT_CONFIG_* beats a repo's core.hooksPath; git >= 2.31).
frozen_hook_env() {
    [ "$#" -eq 1 ] || return 1
    [ -n "$1" ] || return 1
    printf 'GIT_CONFIG_COUNT=1\n'
    printf 'GIT_CONFIG_KEY_0=core.hooksPath\n'
    printf 'GIT_CONFIG_VALUE_0=%s\n' "$1"
}

# install_frozen_hook <worktree-dir> <bead-id> — write the pre-commit hook
# into a PRIVATE hooks dir under the worktree's absolute git dir and record
# the bead id for the hook to read. The repo's own hooks dir is recorded in
# claude-orca-chain for the generated hook to chain to. Prints the hooks
# dir on stdout. Returns non-zero only when the worktree is not a git work
# tree or the dir cannot be written; the callers in dispatch/delegate
# treat that as "nothing to protect".
install_frozen_hook() {
    [ "$#" -eq 2 ] || return 1
    wt="$1"; bead="$2"
    [ -n "$wt" ] && [ -n "$bead" ] || return 1
    # Everything runs from inside the worktree: `git rev-parse
    # --absolute-git-dir` answers the worktree's own git dir (for a linked
    # worktree, .git/worktrees/<name> in the main tree; never a path the
    # caller's cwd could not contain), and `--git-path hooks` answers the
    # hooks dir the repo's own config selects — core.hooksPath when set,
    # else .git/hooks — which is what the generated hook chains to.
    (
        cd "$wt" || exit 1
        gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || exit 1
        hooks="$gitdir/claude-orca-hooks"
        own="$(git rev-parse --git-path hooks 2>/dev/null)" || exit 1
        case "$own" in
            /*) ;;
            *) own="$PWD/$own" ;;
        esac
        mkdir -p "$hooks" || exit 1

        printf '%s\n' "$own" > "$hooks/claude-orca-chain"
        printf '%s\n' "$bead" > "$hooks/claude-orca-bead"

        frozen_hook_body > "$hooks/pre-commit"
        chmod +x "$hooks/pre-commit"
        printf '%s\n' "$hooks"
    )
}
