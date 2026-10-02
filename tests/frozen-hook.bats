#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# frozen-hook.bats — git pre-commit hook that enforces a bead's FROZEN
# contract for every agent, Claude-side or not: once a RED-AT sha exists on
# the bead, no commit may touch the FROZEN paths. Modelled on
# tests/contract-gate.bats (stub bd first on PATH; fail-open when tooling
# is missing).
#
# claude-orca-cdu: the hook lives in a PRIVATE hooks dir per worktree
# (<abs-git-dir>/claude-orca-hooks), switched on for a commit through git's
# env config — frozen_hook_env prints the assignments, and every commit in
# this file runs through them, the way a dispatched worker's processes run.

LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/lib/frozen-hook.sh"
# shellcheck source=../scripts/lib/frozen-hook.sh
. "$LIB"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"

    FIX="$BATS_TEST_TMPDIR/fixture"
    git init -q "$FIX"
    git -C "$FIX" config user.email worker@example.com
    git -C "$FIX" config user.name worker
    mkdir -p "$FIX/tests" "$FIX/scripts"
    echo base > "$FIX/impl.sh"
    echo test > "$FIX/tests/x.bats"
    git -C "$FIX" add -A
    git -C "$FIX" commit -qm "base"

    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    write_bd_stub
    export PATH="$STUB_DIR:/usr/local/bin:/usr/bin:/bin"

    export CLAUDE_ORCA_BEAD="claude-orca-2m5"
    # Default stub answers: the FROZEN line lives in the description, the
    # RED-AT sha in the notes (as `bd update --append-notes` writes it).
    export FAKE_BD_DESC="notes. FROZEN: tests/x.bats from RED-AT on."
    export FAKE_BD_NOTES="RED-AT: $(git -C "$FIX" rev-parse HEAD)"

    FROZEN_HOOK_DIR=""
}

# A fake `bd` that answers `bd show <bead>` with plain text built from
# $FAKE_BD_DESC / $FAKE_BD_NOTES, so the hook's extraction is exercised
# against the shapes `bd show` really prints.
write_bd_stub() {
    cat > "$STUB_DIR/bd" <<'EOF'
#!/bin/sh
if [ "$1" = "show" ]; then
    printf 'title\n\n%s\n\nNOTES\n%s\n' "$FAKE_BD_DESC" "$FAKE_BD_NOTES"
    exit 0
fi
exit 1
EOF
    chmod +x "$STUB_DIR/bd"
}

# hooked_git <hooks-dir> <git args...> -- run git with <hooks-dir> switched
# on as core.hooksPath through git's env config, using exactly the three
# assignments frozen_hook_env prints -- the way every dispatched worker's
# git processes run.
hooked_git() {
    local dir="$1"; shift
    local assignments=() line
    while IFS= read -r line; do
        assignments+=("$line")
    done < <(frozen_hook_env "$dir")
    env "${assignments[@]}" git "$@"
}

commit_fixture() {
    git -C "$FIX" add -A
    hooked_git "$FROZEN_HOOK_DIR" -C "$FIX" commit -qm "$1" \
        2> "$BATS_TEST_TMPDIR/commit.err"
}

@test "hook blocks a commit touching a FROZEN path once RED-AT exists" {
    # Guards: the core contract -- after the bead carries a RED-AT sha, a
    #   commit staging a FROZEN path is refused with the bd supersede line.
    # Fails if: the generated hook stops reading its bead id from its own
    #   dir, or loses the FROZEN-path refusal.
    # Run: bats tests/frozen-hook.bats -f 'blocks a commit'
    FROZEN_HOOK_DIR="$(install_frozen_hook "$FIX" "claude-orca-2m5")"
    echo edit > "$FIX/tests/x.bats"
    run commit_fixture "edit frozen test"
    [ "$status" -ne 0 ]
    grep -q "bd supersede" "$BATS_TEST_TMPDIR/commit.err"
    grep -q "tests/x.bats" "$BATS_TEST_TMPDIR/commit.err"
}

@test "hook lets a commit touching only the implementation through" {
    # Guards: the refusal is scoped to the bead's FROZEN paths -- ordinary
    #   implementation work must never be blocked.
    # Fails if: the hook starts refusing commits that touch no FROZEN path.
    # Run: bats tests/frozen-hook.bats -f 'only the implementation'
    FROZEN_HOOK_DIR="$(install_frozen_hook "$FIX" "claude-orca-2m5")"
    echo impl > "$FIX/impl.sh"
    run commit_fixture "edit impl"
    [ "$status" -eq 0 ]
}

@test "hook is fail-open before any RED-AT exists" {
    # Guards: fail-open -- with no RED-AT sha on the bead the hook must
    #   never block, because tooling must not gate ordinary commits.
    # Fails if: a bead without a RED-AT note starts refusing commits.
    # Run: bats tests/frozen-hook.bats -f 'before any RED-AT'
    FAKE_BD_NOTES="no red note yet"
    FROZEN_HOOK_DIR="$(install_frozen_hook "$FIX" "claude-orca-2m5")"
    echo edit > "$FIX/tests/x.bats"
    run commit_fixture "edit frozen test, no RED yet"
    [ "$status" -eq 0 ]
}

@test "hook is fail-open with no bd on PATH" {
    # Guards: fail-open -- a worker whose PATH lacks bd (fresh container, a
    #   stripped runner env) must still be able to commit.
    # Fails if: the hook hard-depends on bd being resolvable.
    # Run: bats tests/frozen-hook.bats -f 'no bd on PATH'
    PATH_SAVE="$PATH"
    export PATH="/usr/bin:/bin"
    FROZEN_HOOK_DIR="$(install_frozen_hook "$FIX" "claude-orca-2m5")"
    echo edit > "$FIX/tests/x.bats"
    run commit_fixture "edit frozen test, no bd"
    [ "$status" -eq 0 ]
    export PATH="$PATH_SAVE"
}

@test "an existing user pre-commit hook is chained, not clobbered" {
    # Guards: a repo with its own pre-commit (in .git/hooks, no
    #   core.hooksPath) keeps it: the generated hook runs it first and the
    #   installer never renames or removes it.
    # Fails if: the installer clobbers .git/hooks/pre-commit (the old
    #   pre-commit.orig rename) or the generated hook stops chaining.
    # Run: bats tests/frozen-hook.bats -f 'chained, not clobbered'
    printf '#!/bin/sh\ntouch "%s/user-ran"\n' "$BATS_TEST_TMPDIR" > "$FIX/.git/hooks/pre-commit"
    chmod +x "$FIX/.git/hooks/pre-commit"
    FROZEN_HOOK_DIR="$(install_frozen_hook "$FIX" "claude-orca-2m5")"
    echo impl > "$FIX/impl.sh"
    run commit_fixture "chained"
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/user-ran" ]
    [ -f "$FIX/.git/hooks/pre-commit" ]
    [ ! -e "$FIX/.git/hooks/pre-commit.orig" ]
}

@test "install_frozen_hook is idempotent: twice leaves one hook, no stray orig, bead id intact" {
    # Guards: two installs in the same worktree (a re-dispatch) must leave
    #   exactly one generated hook and the bead id file.
    # Fails if: a re-install accumulates pre-commit.orig files or loses the
    #   bead id.
    # Run: bats tests/frozen-hook.bats -f 'idempotent'
    FROZEN_HOOK_DIR="$(install_frozen_hook "$FIX" "claude-orca-2m5")"
    install_frozen_hook "$FIX" "claude-orca-2m5" >/dev/null
    count="$(find "$FROZEN_HOOK_DIR" -maxdepth 1 -name 'pre-commit*' | wc -l)"
    [ "$count" -eq 1 ]
    [ -f "$FROZEN_HOOK_DIR/pre-commit" ]
    [ "$(cat "$FROZEN_HOOK_DIR/claude-orca-bead")" = "claude-orca-2m5" ]
}

@test "a stale absolute core.hooksPath with a linked worktree: install succeeds into the worktree's private git dir, repo untouched" {
    # Guards: claude-orca-cdu -- this repo's .git/config carries the stale
    #   core.hooksPath=/workspace/.beads/hooks and the old installer's
    #   mkdir into it failed ('Permission denied'), leaving dispatches into
    #   an Orca-created worktree with no frozen hook at all. The hook must
    #   land in the worktree's private git dir instead, with repo config
    #   and tracked files untouched.
    # Fails if: the installer targets the repo's own hooks dir again,
    #   changes core.hooksPath, or writes a tracked file anywhere.
    # Run: bats tests/frozen-hook.bats -f 'stale absolute core.hooksPath'
    stale="$BATS_TEST_TMPDIR/stale-hooks"
    git -C "$FIX" config core.hooksPath "$stale"
    git -C "$FIX" worktree add -q "$BATS_TEST_TMPDIR/linked" -b linked-side

    run install_frozen_hook "$BATS_TEST_TMPDIR/linked" "claude-orca-2m5"
    [ "$status" -eq 0 ]
    FROZEN_HOOK_DIR="$output"
    wt_gitdir="$(git -C "$BATS_TEST_TMPDIR/linked" rev-parse --absolute-git-dir)"
    [ "$FROZEN_HOOK_DIR" = "$wt_gitdir/claude-orca-hooks" ]
    [ -f "$FROZEN_HOOK_DIR/pre-commit" ]

    echo edit > "$BATS_TEST_TMPDIR/linked/tests/x.bats"
    git -C "$BATS_TEST_TMPDIR/linked" add -A
    run hooked_git "$FROZEN_HOOK_DIR" -C "$BATS_TEST_TMPDIR/linked" \
        commit -qm "edit frozen test in a linked worktree"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/commit.err"
    grep -q "bd supersede" "$BATS_TEST_TMPDIR/commit.err"
    grep -q "tests/x.bats" "$BATS_TEST_TMPDIR/commit.err"

    # the same commit WITHOUT the env config goes through: the repo's own
    # (nonexistent) hooksPath yields no hook, so nothing blocks it
    run git -C "$BATS_TEST_TMPDIR/linked" commit -qm "no env, goes through"
    [ "$status" -eq 0 ]

    [ "$(git -C "$FIX" config core.hooksPath)" = "$stale" ]
    [ -z "$(git -C "$FIX" status --porcelain)" ]
    [ -z "$(git -C "$BATS_TEST_TMPDIR/linked" status --porcelain)" ]
}

@test "with the env, a non-frozen commit still runs the repo's own pre-commit hook (chain via claude-orca-chain)" {
    # Guards: the private hooks dir must not REPLACE the repo's own hooks:
    #   the installer records them in claude-orca-chain and the generated
    #   hook runs that pre-commit first, its failure still aborting.
    # Fails if: the generated hook stops chaining to the dir recorded in
    #   claude-orca-chain, or the installer renames/clobbers the user hook.
    # Run: bats tests/frozen-hook.bats -f 'chain via claude-orca-chain'
    own="$BATS_TEST_TMPDIR/own-hooks"
    mkdir -p "$own"
    printf '#!/bin/sh\ntouch "%s/user-ran"\n' "$BATS_TEST_TMPDIR" > "$own/pre-commit"
    chmod +x "$own/pre-commit"
    git -C "$FIX" config core.hooksPath "$own"

    FROZEN_HOOK_DIR="$(install_frozen_hook "$FIX" "claude-orca-2m5")"
    echo impl > "$FIX/impl.sh"
    run commit_fixture "chained through the private dir"
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/user-ran" ]
    [ -f "$own/pre-commit" ]
}

@test "two worktrees installed for two different beads keep their own bead ids" {
    # Guards: parallel dispatches into sibling worktrees must not share one
    #   claude-orca-bead file -- the old shared-hooks-dir design let one
    #   install overwrite another's bead id (claude-orca-cdu).
    # Fails if: both worktrees' private dirs land in the same place or end
    #   up carrying the same bead id.
    # Run: bats tests/frozen-hook.bats -f 'two different beads'
    git -C "$FIX" worktree add -q "$BATS_TEST_TMPDIR/wt-a" -b wa
    git -C "$FIX" worktree add -q "$BATS_TEST_TMPDIR/wt-b" -b wb
    d1="$(install_frozen_hook "$BATS_TEST_TMPDIR/wt-a" "bead-one")"
    d2="$(install_frozen_hook "$BATS_TEST_TMPDIR/wt-b" "bead-two")"
    [ -n "$d1" ] && [ -n "$d2" ]
    [ "$d1" != "$d2" ]
    [ "$(cat "$d1/claude-orca-bead")" = "bead-one" ]
    [ "$(cat "$d2/claude-orca-bead")" = "bead-two" ]
}
