#!/usr/bin/env bats
#
# 55-git-init -- the folder is a git repository with a commit on main (or
# master) by the time 60-orca-repo-add hands it to Orca.
#
# Reproduced 2026-09-13 against Orca 1.4.197: `orca repo add` rejects a
# folder that is not a repository ("Not a valid git repository"), accepts a
# `git init`ed one with no commits, and then every "Create worktree" on it
# fails "Could not resolve a default base ref for this repo" -- the app
# shows that as "No base branch found". Orca resolves the base from
# origin/HEAD, origin/main, origin/master, refs/heads/main and
# refs/heads/master and nothing else, so a bootstrapped folder that was
# never a repository showed up as a project nobody could open a workspace
# in. Nothing before this step ever ran `git init` or a first commit.
#
# The step's one promise is a repository with at least one commit on a
# branch Orca can base on. What it never does: touch the user's own files
# (only the seeds go into the commit, and only when they exist), rename a
# branch that already has commits, `git init` over a .git that git cannot
# read, or reach into a parent folder's repository.
#
# Assertions are `[ ]` and functions, never a bare `[[ ]]` (run-tests.sh).

load helpers/setup

STEP="${BATS_TEST_DIRNAME}/../scripts/container/provision.d/55-git-init"
PROVISION_D="${BATS_TEST_DIRNAME}/../scripts/container/provision.d"

# The step as the runner starts it: PROJECT_DIR set and nothing else
# inherited. `env -i` also strips the GIT_AUTHOR_*/GIT_COMMITTER_*
# overrides a developer's shell may carry, which would otherwise decide the
# identity case for us. HOME is a fresh empty directory unless the case
# seeds a .gitconfig of its own; anything after it is extra NAME=value
# pairs for env.
git_init_step() {  # git_init_step <project> [home] [NAME=value ...]
    local d="$1" h="${2:-}"
    shift
    if [ $# -gt 0 ]; then shift; fi
    [ -n "$h" ] || h="$BATS_TEST_TMPDIR/empty-home"
    mkdir -p "$h"
    env -i PATH="$PATH" HOME="$h" PROJECT_DIR="$d" "$@" bash "$STEP"
}

# A folder that is not a repository, holding a file of the user's own and
# the two seeds 50-seed-project leaves behind (the .gitignore block as
# seed_gitignore writes it since claude-orca-e8m, orca.yaml included).
plain_folder() {  # plain_folder [name]
    local d="$BATS_TEST_TMPDIR/${1:-proj}"
    mkdir -p "$d"
    printf 'x,y\n1,2\n' > "$d/data.csv"
    printf '# claude_orca\n.claude-dev/\nattachments/\norca.yaml\n' > "$d/.gitignore"
    printf 'scripts:\n  setup: bash .claude-dev/template/scripts/container/seed-project.sh\n' > "$d/orca.yaml"
    printf '%s\n' "$d"
}

# `git init` on a branch and nothing else: the shape `orca repo add`
# accepts but no workspace can be created in.
unborn_repo() {  # unborn_repo <name> <branch>
    local d="$BATS_TEST_TMPDIR/$1"
    mkdir -p "$d"
    git -C "$d" init -q -b "$2" >/dev/null 2>&1
    printf 'scripts: {}\n' > "$d/orca.yaml"
    printf '%s\n' "$d"
}

commit_count() { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }
head_branch() { git -C "$1" symbolic-ref --short -q HEAD; }
tracked() { git -C "$1" ls-files | LC_ALL=C sort | paste -sd' ' -; }

says() {  # says <needle>: the last run's output contains it
    case "$output" in
        *"$1"*) return 0 ;;
    esac
    echo "expected the output to say '$1': $output"
    return 1
}

@test "a plain folder becomes a repository on main with one seed commit, and the user's file stays untracked" {
    local d
    d="$(plain_folder)"
    run git_init_step "$d"
    [ "$status" -eq 0 ]
    says "initialised"
    [ -d "$d/.git" ]
    [ "$(head_branch "$d")" = "main" ]
    [ "$(commit_count "$d")" = "1" ]
    # claude-orca-e8m: orca.yaml is ignored by the seeded .gitignore now, so
    # the seed commit carries .gitignore alone and orca.yaml shows nowhere.
    [ "$(tracked "$d")" = ".gitignore" ]
    run git -C "$d" status --porcelain
    [ "$output" = "?? data.csv" ]
}

@test "an unborn repository on master gets its seed commit on master, not renamed" {
    local d
    d="$(unborn_repo onmaster master)"
    run git_init_step "$d"
    [ "$status" -eq 0 ]
    [ "$(head_branch "$d")" = "master" ]
    [ "$(commit_count "$d")" = "1" ]
    case "$output" in
        *moved*) echo "master must not be renamed: $output"; return 1 ;;
    esac
}

@test "an unborn repository on trunk is moved to main first, and the output says so" {
    local d
    d="$(unborn_repo ontrunk trunk)"
    run git_init_step "$d"
    [ "$status" -eq 0 ]
    says "moved"
    says "trunk"
    [ "$(head_branch "$d")" = "main" ]
    [ "$(commit_count "$d")" = "1" ]
    run git -C "$d" show-ref --verify -q refs/heads/trunk
    [ "$status" -ne 0 ]
}

@test "a repository that already has commits is left exactly as it is" {
    local d before
    d="$(plain_folder withcommits)"
    git -C "$d" init -q -b feature >/dev/null 2>&1
    git -C "$d" add -- data.csv
    git -C "$d" -c user.name=test -c user.email=test@example.com \
        commit -q -m "the user's own history" >/dev/null 2>&1
    before="$(git -C "$d" rev-parse HEAD)"
    run git_init_step "$d"
    [ "$status" -eq 0 ]
    says "nothing to do"
    [ "$(git -C "$d" rev-parse HEAD)" = "$before" ]
    [ "$(head_branch "$d")" = "feature" ]
    [ "$(commit_count "$d")" = "1" ]
}

@test "running it twice leaves exactly one commit, and the second run says nothing to do" {
    local d
    d="$(plain_folder twice)"
    run git_init_step "$d"
    [ "$status" -eq 0 ]
    run git_init_step "$d"
    [ "$status" -eq 0 ]
    says "nothing to do"
    [ "$(commit_count "$d")" = "1" ]
}

@test "the identity is claude_orca@localhost with no gitconfig, and the configured one when there is" {
    local d h
    d="$(plain_folder noidentity)"
    run git_init_step "$d"
    [ "$status" -eq 0 ]
    [ "$(git -C "$d" log -1 --format='%an <%ae>')" = "claude_orca <claude_orca@localhost>" ]

    d="$(plain_folder identity)"
    h="$BATS_TEST_TMPDIR/jo-home"
    mkdir -p "$h"
    printf '[user]\n\tname = Jo\n\temail = jo@example.com\n' > "$h/.gitconfig"
    run git_init_step "$d" "$h"
    [ "$status" -eq 0 ]
    [ "$(git -C "$d" log -1 --format='%an <%ae>')" = "Jo <jo@example.com>" ]
}

@test "with no seeds at all it makes an empty commit rather than none" {
    local d="$BATS_TEST_TMPDIR/bare"
    mkdir -p "$d"
    run git_init_step "$d"
    [ "$status" -eq 0 ]
    [ "$(commit_count "$d")" = "1" ]
    [ -z "$(git -C "$d" ls-files)" ]
    [ "$(git -C "$d" log -1 --format='%s')" = "claude_orca: seed commit (empty)" ]
}

@test "a file of the user's own already staged stays staged and out of the seed commit" {
    local d
    d="$(unborn_repo staged main)"
    printf 'secret\n' > "$d/notes.txt"
    git -C "$d" add -- notes.txt
    run git_init_step "$d"
    [ "$status" -eq 0 ]
    [ "$(commit_count "$d")" = "1" ]
    # claude-orca-e8m: orca.yaml is out of the pathspec, so a folder whose
    # only seed is an ignored orca.yaml gets an empty commit.
    [ -z "$(git -C "$d" ls-tree --name-only HEAD)" ]
    [ "$(git -C "$d" diff --cached --name-only)" = "notes.txt" ]
}

@test "a subfolder of a repository with commits is nothing to do, and gets no nested .git" {
    local top d before
    top="$BATS_TEST_TMPDIR/mono"
    mkdir -p "$top/apps/thisone"
    git -C "$top" init -q -b main >/dev/null 2>&1
    git -C "$top" -c user.name=test -c user.email=test@example.com \
        commit -q --allow-empty -m init >/dev/null 2>&1
    before="$(git -C "$top" rev-parse HEAD)"
    d="$top/apps/thisone"
    printf 'scripts: {}\n' > "$d/orca.yaml"
    run git_init_step "$d"
    [ "$status" -eq 0 ]
    says "nothing to do"
    [ ! -e "$d/.git" ]
    [ "$(git -C "$top" rev-parse HEAD)" = "$before" ]
    [ -z "$(git -C "$top" ls-files)" ]
}

@test "a .git that git cannot read is reported in git's own words and never re-initialised" {
    local d
    d="$(unborn_repo dubious main)"
    run git_init_step "$d" "" GIT_TEST_ASSUME_DIFFERENT_OWNER=1
    [ "$status" -eq 1 ]
    says "dubious ownership"
    says "cannot read the repository"
    [ "$(commit_count "$d")" = "0" ]
    [ -d "$d/.git" ]
}

@test "the step is executable and runs after 50-seed-project, before 60-orca-repo-add" {
    local n50 n55 n60
    [ -x "$STEP" ]
    n50="$(ls -1 "$PROVISION_D" | LC_ALL=C sort | grep -nx '50-seed-project' | cut -d: -f1)"
    n55="$(ls -1 "$PROVISION_D" | LC_ALL=C sort | grep -nx '55-git-init' | cut -d: -f1)"
    n60="$(ls -1 "$PROVISION_D" | LC_ALL=C sort | grep -nx '60-orca-repo-add' | cut -d: -f1)"
    [ -n "$n50" ] && [ -n "$n55" ] && [ -n "$n60" ]
    [ "$n50" -lt "$n55" ]
    [ "$n55" -lt "$n60" ]
}

@test "a .beads directory seeded like bd init is committed minus what its own .gitignore ignores" {
    local d
    d="$(plain_folder beads)"
    mkdir -p "$d/.beads/dolt/data"
    printf 'prefix: co\n' > "$d/.beads/config.yaml"
    printf '{"id":"co-1"}\n' > "$d/.beads/issues.jsonl"
    printf 'dolt/\n' > "$d/.beads/.gitignore"
    printf 'binary\n' > "$d/.beads/dolt/data/noms"
    run git_init_step "$d"
    [ "$status" -eq 0 ]
    says "seed commit"
    says ".beads"
    [ "$(commit_count "$d")" = "1" ]
    [ "$(tracked "$d")" = ".beads/.gitignore .beads/config.yaml .beads/issues.jsonl .gitignore" ]
    run git -C "$d" status --porcelain
    [ "$output" = "?? data.csv" ]
}

# --- claude-orca-1te: the safe.directory remedy -----------------------------
#
# The mounted project root can read as owned by root (uid 0) even though the
# agent owns everything under it; git then refuses the folder ("detected
# dubious ownership") and every git call in it dies. GIT_TEST_ASSUME_DIFFERENT_OWNER=1
# stands in for that: git 2.43 treats every repository as owned by someone
# else. Each case runs the step with HOME at a scratch dir and the variable
# set, passing PROJECT_DIR explicitly, so the only escape is the step's own
# remedy -- PROJECT_DIR in the global git config's safe.directory before its
# first git call.

@test "under simulated dubious ownership a fresh folder still becomes a repository with a commit on main" {
    # Guards: claude-orca-1te -- the step must mark PROJECT_DIR a
    #   safe.directory in the global git config before its first git call,
    #   so a folder whose mount reads as uid 0 still gets its seed commit.
    # Fails if: the step runs git before adding safe.directory -- init
    #   succeeds but the seed commit dies with "detected dubious ownership"
    #   and the step exits 1.
    # Run: bats tests/provision-git-init.bats -f "simulated dubious ownership a fresh"
    local d h
    d="$(plain_folder dubious-fresh)"
    h="$BATS_TEST_TMPDIR/dubious-fresh-home"
    run git_init_step "$d" "$h" GIT_TEST_ASSUME_DIFFERENT_OWNER=1
    [ "$status" -eq 0 ]
    [ -d "$d/.git" ]
    [ "$(head_branch "$d")" = "main" ]
    [ "$(commit_count "$d")" = "1" ]
}

@test "under simulated dubious ownership an existing repository with commits is nothing to do" {
    # Guards: claude-orca-1te -- a folder that is already a repository must
    #   be recognised once PROJECT_DIR is marked safe, never reported as a
    #   repository git cannot read.
    # Fails if: the step's first git call still runs before safe.directory
    #   -- rev-parse dies with "dubious ownership", the step takes the
    #   "git cannot read the repository" exit and fails.
    # Run: bats tests/provision-git-init.bats -f "simulated dubious ownership an existing"
    local d h before
    d="$(plain_folder dubious-existing)"
    git -C "$d" init -q -b main >/dev/null 2>&1
    git -C "$d" add -- data.csv
    git -C "$d" -c user.name=test -c user.email=test@example.com \
        commit -q -m "the user's own history" >/dev/null 2>&1
    before="$(git -C "$d" rev-parse HEAD)"
    h="$BATS_TEST_TMPDIR/dubious-existing-home"
    run git_init_step "$d" "$h" GIT_TEST_ASSUME_DIFFERENT_OWNER=1
    [ "$status" -eq 0 ]
    says "nothing to do"
    [ "$(git -C "$d" rev-parse HEAD)" = "$before" ]
}

@test "under simulated dubious ownership running it twice leaves exactly one safe.directory line for the project" {
    # Guards: claude-orca-1te -- the remedy is idempotent: a second run of
    #   the step adds no second safe.directory entry to the global git
    #   config.
    # Fails if: the step adds safe.directory unconditionally -- the second
    #   run leaves two identical lines in $HOME/.gitconfig.
    # Run: bats tests/provision-git-init.bats -f "exactly one safe.directory"
    local d h
    d="$(plain_folder dubious-twice)"
    h="$BATS_TEST_TMPDIR/dubious-twice-home"
    run git_init_step "$d" "$h" GIT_TEST_ASSUME_DIFFERENT_OWNER=1
    [ "$status" -eq 0 ]
    run git_init_step "$d" "$h" GIT_TEST_ASSUME_DIFFERENT_OWNER=1
    [ "$status" -eq 0 ]
    [ "$(grep -cxF -- "$d" "$h/.gitconfig")" = "1" ]
}
