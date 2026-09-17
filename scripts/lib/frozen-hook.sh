#!/usr/bin/env bash
#
# frozen-hook.sh — enforce a bead's FROZEN contract in git, for every agent
# (claude-orca-2m5). The Claude-side PreToolUse contract-gate only reaches
# Claude workers; opencode/codex/gemini run none of this repo's hooks, so a
# frozen test file could be edited after its RED commit. A pre-commit hook
# reaches all of them, because they all commit through git.
#
#   install_frozen_hook <worktree-dir> <bead-id>
#
# Installs <git-path>/hooks/pre-commit (shared hooks dir for a linked
# worktree resolves through `git rev-parse --git-path hooks`). An existing
# non-ours hook is chained: renamed to pre-commit.orig and run first, its
# failure still aborting the commit. Idempotent: a second call replaces the
# generated hook in place and rewrites the bead id file.
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
# claude-orca frozen-hook v1 (generated; edits are overwritten by the installer)
gp="$(git rev-parse --git-path hooks 2>/dev/null)" || exit 0
orig="$gp/pre-commit.orig"
if [ -f "$orig" ]; then
    "$orig" "$@" || exit $?
fi
bead="${CLAUDE_ORCA_BEAD:-}"
if [ -z "$bead" ] && [ -f "$gp/claude-orca-bead" ]; then
    bead="$(cat "$gp/claude-orca-bead" 2>/dev/null)"
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

# install_frozen_hook <worktree-dir> <bead-id> — write the pre-commit hook
# into the worktree's hooks dir and record the bead id for the hook to read.
# Returns non-zero only when the worktree is not a git repository; the
# callers in orca-dispatch/delegate treat that as "nothing to protect".
install_frozen_hook() {
    [ "$#" -eq 2 ] || return 1
    wt="$1"; bead="$2"
    [ -n "$wt" ] && [ -n "$bead" ] || return 1
    # Everything runs from inside the worktree: `git rev-parse --git-path
    # hooks` answers worktree-relative, and in a linked worktree the
    # caller's cwd may not even contain a `.git` (it is a file there).
    (
        cd "$wt" || exit 1
        hooks="$(git rev-parse --git-path hooks 2>/dev/null)" || exit 1
        mkdir -p "$hooks" || exit 1

        printf '%s\n' "$bead" > "$hooks/claude-orca-bead"

        # The frozen contract counts pre-commit* files: one hook means no
        # pre-commit.orig after a re-install, and git's pre-commit.sample
        # (created by init's template) does not get to pretend to be a hook.
        rm -f "$hooks/pre-commit.sample"

        target="$hooks/pre-commit"
        if [ -f "$target" ] && grep -q "$_FROZEN_HOOK_MARKER" "$target" 2>/dev/null; then
            : # ours already; fall through and regenerate it
        elif [ -e "$target" ] || [ -L "$target" ]; then
            # A user hook: chain it (run first, failure aborts) rather than clobber.
            mv -f "$target" "$hooks/pre-commit.orig"
        fi

        frozen_hook_body > "$target"
        chmod +x "$target"
    )
}
