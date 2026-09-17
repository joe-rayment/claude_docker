#!/usr/bin/env bats
#
# Acceptance contract for claude-orca-avp: `claude-dev --teardown` removes
# the .git directory it created, so a folder can be folded into a larger
# repository and pushed. provision.d/55-git-init gives a folder that was
# never a repository a single root commit whose subject starts with
# "claude_orca: seed commit"; teardown removes .git only when the folder is
# the repository's toplevel, the history has exactly one root commit and
# that root carries the seed marker -- otherwise .git stays and teardown
# says why in one line. User commits on top of a seed root still lose .git
# (that is the ask). graphify-out/ (claude-orca-gwl's output) goes too.
# Real git, docker stubbed exactly as tests/teardown-orca-residue.bats does.

load helpers/setup

# Amends the fixture root commit (make_project's "init") into the marker
# commit 55-git-init writes, so the repo is seed-rooted the way a folder
# that got its .git from claude_orca is.
seed_root() {
    git -C "$1" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty --amend -m "claude_orca: seed commit (empty)"
}

@test "teardown removes .git from a seed-rooted repo, and removes graphify-out" {
    mkdir -p "$PROJECT_DIR"
    make_project "$PROJECT_DIR"
    seed_root "$PROJECT_DIR"

    mkdir -p "$PROJECT_DIR/graphify-out"
    printf 'graph\n' > "$PROJECT_DIR/graphify-out/graph.txt"

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --teardown
    [ "$status" -eq 0 ]

    [ ! -e "$PROJECT_DIR/.git" ]
    [ ! -e "$PROJECT_DIR/graphify-out" ]
    [[ "$output" == *"removed .git (claude_orca created it)"* ]]
}

@test "teardown keeps .git when the root commit is the user's, and says why" {
    mkdir -p "$PROJECT_DIR"
    make_project "$PROJECT_DIR"

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --teardown
    [ "$status" -eq 0 ]

    [ -d "$PROJECT_DIR/.git" ]
    [[ "$output" == *"kept .git ("* ]]
    [[ "$output" != *"removed .git"* ]]
}

@test "teardown removes .git from a seed-rooted repo with two user commits on top" {
    mkdir -p "$PROJECT_DIR"
    make_project "$PROJECT_DIR"
    seed_root "$PROJECT_DIR"

    printf 'one\n' > "$PROJECT_DIR/one.txt"
    git -C "$PROJECT_DIR" add one.txt
    git -C "$PROJECT_DIR" -c user.email=test@example.com -c user.name=test \
        commit --quiet -m "user commit one"
    printf 'two\n' > "$PROJECT_DIR/two.txt"
    git -C "$PROJECT_DIR" add two.txt
    git -C "$PROJECT_DIR" -c user.email=test@example.com -c user.name=test \
        commit --quiet -m "user commit two"

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --teardown
    [ "$status" -eq 0 ]

    [ ! -e "$PROJECT_DIR/.git" ]
    [[ "$output" == *"removed .git (claude_orca created it)"* ]]
}

@test "teardown keeps everything in a folder nested inside a larger repo" {
    outer="$BATS_TEST_TMPDIR/outer"
    mkdir -p "$outer"
    git -C "$outer" init --quiet -b main >/dev/null 2>&1
    git -C "$outer" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m "the larger repo" >/dev/null 2>&1

    # The folder sits inside the larger repo and is not a repository of
    # its own -- bootstrap still registers it (git init is a fixture step
    # make_project adds, not something bootstrap itself does).
    mkdir -p "$outer/project"
    printf 'mine\n' > "$outer/project/keep.txt"
    STUB_UNAME_S="${STUB_UNAME_S:-Darwin}" STUB_UNAME_M="${STUB_UNAME_M:-arm64}" \
        bash "$REPO_ROOT/bootstrap.sh" "$outer/project" >/dev/null

    cd "$outer/project"
    run "$outer/project/.claude-dev/bin/claude-dev" --teardown
    [ "$status" -eq 0 ]

    # The larger repo's .git is untouched, the folder never grew one, and
    # the user's file survives.
    [ -d "$outer/.git" ]
    [ ! -e "$outer/project/.git" ]
    [ "$(cat "$outer/project/keep.txt")" = "mine" ]
    [[ "$output" != *"removed .git"* ]]
}