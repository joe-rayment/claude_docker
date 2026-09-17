#!/usr/bin/env bats
#
# Acceptance contract for claude-orca-aeu: `claude-dev --teardown` leaves no
# Orca residue in the folder. Orca's linked git worktrees under
# .orca-worktrees/ (each a .git FILE pointing into the root .git/worktrees)
# get staged as mode-160000 gitlinks by a plain `git add -A`, which is what
# broke a push to a fresh remote, and root .orca/ is Orca's drop state.
# Teardown removes both; the beads snapshot and attachments/ stay (they are
# documented recovery data, out of scope here). The seed ignores
# .orca/ and .orca-worktrees/ while the folder lives, and teardown's unseed
# removes exactly those seeded lines so a user's own .gitignore survives
# byte for byte.

load helpers/setup

@test "teardown removes Orca's linked worktrees and .orca, keeps the branch, leaves no untracked residue but the snapshot dir" {
    mkdir -p "$PROJECT_DIR"
    printf 'node_modules/\n*.log\n' > "$PROJECT_DIR/.gitignore"
    make_project "$PROJECT_DIR"

    mkdir -p "$PROJECT_DIR/.orca/drops"
    printf 'drop\n' > "$PROJECT_DIR/.orca/drops/x.txt"
    git -C "$PROJECT_DIR" worktree add --quiet .orca-worktrees/wt-a -b wt-a
    printf 'w\n' > "$PROJECT_DIR/.orca-worktrees/wt-a/w.txt"

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --teardown
    [ "$status" -eq 0 ]

    [ ! -e "$PROJECT_DIR/.orca-worktrees" ]
    [ ! -e "$PROJECT_DIR/.orca" ]
    [ "$(git -C "$PROJECT_DIR" worktree list | wc -l | tr -d ' ')" = "1" ]
    [ -n "$(git -C "$PROJECT_DIR" branch --list wt-a)" ]

    local residue
    residue="$(git -C "$PROJECT_DIR" status --porcelain | grep -v '.claude-dev-snapshots/' || true)"
    [ -z "$residue" ]
    [[ "$output" == *".orca-worktrees"* ]]
}

@test "teardown prunes a stale worktree entry and exits 0" {
    mkdir -p "$PROJECT_DIR"
    printf 'node_modules/\n' > "$PROJECT_DIR/.gitignore"
    make_project "$PROJECT_DIR"

    git -C "$PROJECT_DIR" worktree add --quiet .orca-worktrees/wt-b -b wt-b
    rm -rf "$PROJECT_DIR/.orca-worktrees/wt-b"

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --teardown
    [ "$status" -eq 0 ]
    [ "$(git -C "$PROJECT_DIR" worktree list | wc -l | tr -d ' ')" = "1" ]
    [ ! -e "$PROJECT_DIR/.orca-worktrees" ]
}

@test "teardown on a project that is not a git repo still removes .orca and exits 0" {
    mkdir -p "$PROJECT_DIR"
    make_project "$PROJECT_DIR"

    mkdir -p "$PROJECT_DIR/.orca/drops"
    printf 'drop\n' > "$PROJECT_DIR/.orca/drops/x.txt"
    rm -rf "$PROJECT_DIR/.git"

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --teardown
    [ "$status" -eq 0 ]
    [ ! -e "$PROJECT_DIR/.orca" ]
    [ -z "$(echo "$output" | grep -i 'fatal\|not a git repository' || true)" ]
}

@test "seed adds the .orca ignores under the marker and teardown's unseed restores the user's gitignore byte for byte" {
    mkdir -p "$PROJECT_DIR"
    printf 'node_modules/\n*.log\n' > "$PROJECT_DIR/.gitignore"
    make_project "$PROJECT_DIR"

    CLAUDE_ORCA_SKIP_BEADS=1 PROJECT_DIR="$PROJECT_DIR" \
        bash "$REPO_ROOT/scripts/container/seed-project.sh" >/dev/null

    grep -qxF '.orca/' "$PROJECT_DIR/.gitignore"
    grep -qxF '.orca-worktrees/' "$PROJECT_DIR/.gitignore"
    grep -qxF '# claude_orca' "$PROJECT_DIR/.gitignore"

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --teardown
    [ "$status" -eq 0 ]

    [ "$(cat "$PROJECT_DIR/.gitignore")" = "$(printf 'node_modules/\n*.log')" ]
}
