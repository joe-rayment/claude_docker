#!/usr/bin/env bats
#
# claude-orca-vm1: 'orca skills install --local' (provision.d/75-orca-skills)
# writes .agents/skills/orchestration/, the .claude/skills/orchestration
# symlink and skills-lock.json into the PROJECT root, so the seeded
# .gitignore has to carry those three exact paths -- and teardown has to
# un-seed exactly what the seed wrote. The ignore is exact
# (.claude/skills/orchestration, never .claude/skills/): a user's own
# project skills must stay visible to git.
#
# Assertions are `[ ]` and functions, never a bare `[[ ]]` (run-tests.sh).

load helpers/setup

SEED="${BATS_TEST_DIRNAME}/../scripts/container/seed-project.sh"

# helpers/setup.bash defines setup(); preserve it under another name before
# this file's own setup() shadows it, so the standard fixture still applies.
__helper_setup="$(declare -f setup | sed '1s/^setup ()/helper_per_test_setup ()/')"
eval "$__helper_setup"

setup() {
    # This suite can itself be running inside a claude-orca container, which
    # sets PROJECT_DIR/CLAUDE_ORCA_ROOT/BEADS_DIR for its OWN real project.
    # Leaving any set could point the seed at /workspace/claude-orca; the
    # file must only ever touch throwaway folders.
    unset PROJECT_DIR
    unset CLAUDE_ORCA_ROOT
    unset CLAUDE_ORCA_HOST_DIR
    unset CLAUDE_ORCA_HOST_PROJECT_DIR
    unset BEADS_DIR
    helper_per_test_setup
}

fresh_project() {
    local d="$BATS_TEST_TMPDIR/${1:-proj}"
    mkdir -p "$d"
    git -C "$d" init --quiet -b main >/dev/null 2>&1
    printf '%s\n' "$d"
}

seed() { PROJECT_DIR="$1" bash "$SEED"; }

assert_line_once() {
    run grep -cxF "$1" "$2"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "a fresh folder's seeded .gitignore carries the three orca-skills paths" {
    local d
    d="$(fresh_project orca-skills-fresh)"
    run seed "$d"
    [ "$status" -eq 0 ]
    assert_line_once '.agents/skills/orchestration/' "$d/.gitignore"
    assert_line_once '.claude/skills/orchestration' "$d/.gitignore"
    assert_line_once 'skills-lock.json' "$d/.gitignore"
}

@test "a folder seeded before this change gains exactly the three missing lines" {
    local d
    d="$(fresh_project orca-skills-old)"
    {
        printf 'node_modules/\n'
        printf '\n'
        printf '# claude_orca\n'
        printf '%s\n' \
            '.claude-dev/' '.claude-dev-snapshots/' '/claude-dev' \
            'Orca.app/' '.mcp.json' 'attachments/' '.claude/logs/' \
            '.orca/' '.orca-worktrees/' 'orca.yaml' \
            'graphify-out/' '__pycache__/'
    } > "$d/.gitignore"

    run seed "$d"
    [ "$status" -eq 0 ]
    assert_line_once '.agents/skills/orchestration/' "$d/.gitignore"
    assert_line_once '.claude/skills/orchestration' "$d/.gitignore"
    assert_line_once 'skills-lock.json' "$d/.gitignore"
    grep -qxF 'node_modules/' "$d/.gitignore"

    cp "$d/.gitignore" "$BATS_TEST_TMPDIR/gitignore.after-first-seed"
    run seed "$d"
    [ "$status" -eq 0 ]
    cmp -s "$d/.gitignore" "$BATS_TEST_TMPDIR/gitignore.after-first-seed"
}

@test "git stops reporting the three paths and still reports the user's own skill" {
    local d
    d="$(fresh_project orca-skills-git)"
    mkdir -p "$d/.agents/skills/orchestration" "$d/.claude/skills/mine"
    printf 'skill\n' > "$d/.agents/skills/orchestration/SKILL.md"
    ln -s ../../.agents/skills/orchestration "$d/.claude/skills/orchestration"
    printf '{}\n' > "$d/skills-lock.json"
    printf 'mine\n' > "$d/.claude/skills/mine/SKILL.md"

    run seed "$d"
    [ "$status" -eq 0 ]
    git -C "$d" add .gitignore
    git -C "$d" -c user.name=t -c user.email=t@example.com \
        -c commit.gpgsign=false commit -q --no-verify -m seed -- .gitignore

    run git -C "$d" status --porcelain --untracked-files=all
    [ "$status" -eq 0 ]
    case "$output" in
        *".agents/skills/orchestration"*|*".claude/skills/orchestration"*|*"skills-lock.json"*)
            echo "the three seeded paths must be ignored, got: $output"; return 1 ;;
    esac
    case "$output" in
        *".claude/skills/mine/SKILL.md"*) ;;
        *) echo "the user's own skill must stay visible, got: $output"; return 1 ;;
    esac
}

@test "teardown un-seeds what the seed wrote, byte for byte" {
    mkdir -p "$PROJECT_DIR"
    printf 'node_modules/\n' > "$PROJECT_DIR/.gitignore"
    cp "$PROJECT_DIR/.gitignore" "$BATS_TEST_TMPDIR/gitignore.original"

    make_project "$PROJECT_DIR"

    # Container provisioning writes the seed into the mounted folder --
    # the same body provision.d/50-seed-project runs, against the real
    # script from this working tree.
    run env PROJECT_DIR="$PROJECT_DIR" bash "$REPO_ROOT/scripts/container/seed-project.sh"
    [ "$status" -eq 0 ]
    grep -qxF '.claude/skills/orchestration' "$PROJECT_DIR/.gitignore"

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --teardown
    [ "$status" -eq 0 ]
    cmp -s "$PROJECT_DIR/.gitignore" "$BATS_TEST_TMPDIR/gitignore.original"
}