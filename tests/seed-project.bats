#!/usr/bin/env bats
#
# seed-project.sh -- the project seeding, out of the boot's critical path.
#
# It used to live inside the entrypoint, which is PID 1: every line of it
# sat on the path that has to bring the folder up, and it ran before
# there was a terminal to watch it in. It is one script with one caller now,
# provision.d/50-seed-project, which runs on every start so a folder never
# depends on a hook having fired to have a tracker in it. The template no
# longer ships or runs Orca, so it seeds no orca.yaml and adds no Orca
# ignore lines; a file or line of that kind that a project already has is
# the project's and stays exactly as it is.
#
# Assertions are `[ ]` and functions, never a bare `[[ ]]` (run-tests.sh).

load helpers/setup

SEED="${BATS_TEST_DIRNAME}/../scripts/container/seed-project.sh"

seed() { PROJECT_DIR="$1" bash "$SEED"; }

fresh_project() {
    local d="$BATS_TEST_TMPDIR/${1:-proj}"
    mkdir -p "$d"
    git -C "$d" init --quiet -b main >/dev/null 2>&1
    printf '%s\n' "$d"
}

@test "it seeds the gitignore block and attachments, no orca.yaml, and says what it did" {
    local d
    d="$(fresh_project)"
    run seed "$d"
    [ "$status" -eq 0 ]

    grep -qF '# claude_orca' "$d/.gitignore"
    grep -qxF '.claude-dev/' "$d/.gitignore"
    grep -qxF 'attachments/' "$d/.gitignore"
    [ -d "$d/attachments" ]
    # This template no longer ships or runs Orca: nothing seeds its file.
    [ ! -e "$d/orca.yaml" ]
    case "$output" in
        *orca.yaml*) echo "the log still talks about orca.yaml: $output"; return 1 ;;
    esac
}

# claude-orca-e8m: the local-only artefacts the tooling leaves in a folder
# (graphify output, Python caches) must be in the seeded .gitignore, so a
# seeded folder can stage everything or push to GitHub without shipping
# them. The Orca desktop app's files (Orca.app/, .orca/, .orca-worktrees/,
# orca.yaml) are NOT added any more: the template no longer ships Orca.
@test "the seeded .gitignore carries graphify-out/ and __pycache__/ and adds no Orca lines" {
    local d
    d="$(fresh_project)"
    run seed "$d"
    [ "$status" -eq 0 ]
    for pattern in 'graphify-out/' '__pycache__/'; do
        grep -qxF "$pattern" "$d/.gitignore"
    done
    for pattern in 'Orca.app/' '.orca/' '.orca-worktrees/' 'orca.yaml'; do
        if grep -qxF "$pattern" "$d/.gitignore"; then
            echo "the seeded .gitignore still adds: $pattern"
            return 1
        fi
    done

    # And they work: in a git-inited seeded folder that has been through
    # the seed commit (55-git-init), neither of them shows up as untracked.
    mkdir -p "$d/graphify-out" "$d/__pycache__"
    : > "$d/graphify-out/x"
    : > "$d/__pycache__/x"
    git -C "$d" add .gitignore
    git -C "$d" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false \
        commit -q --no-verify -m seed -- .gitignore
    run git -C "$d" status --short
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a .gitignore that already has Orca lines keeps every one of them, byte for byte" {
    local d
    d="$(fresh_project)"
    # The user's own file, from before the template dropped Orca: seeding
    # appends what is missing and never strips a line.
    printf 'node_modules/\n.orca/\n.orca-worktrees/\norca.yaml\nOrca.app/\n' > "$d/.gitignore"
    seed "$d" >/dev/null
    for pattern in 'node_modules/' '.orca/' '.orca-worktrees/' 'orca.yaml' 'Orca.app/'; do
        grep -qxF "$pattern" "$d/.gitignore"
    done
    # Exactly once each: seeding added none and duplicated none.
    run grep -cxF '.orca/' "$d/.gitignore"
    [ "$output" = "1" ]
    # The user's lines are still the file's first lines, in order.
    run head -n 5 "$d/.gitignore"
    [ "$output" = "$(printf 'node_modules/\n.orca/\n.orca-worktrees/\norca.yaml\nOrca.app/')" ]
}

# What an earlier template seeded into orca.yaml, byte for byte. It is a
# user's file now: seeding neither rewrites nor deletes it, which the cases
# below pin.
PREVIOUSLY_SEEDED_ORCA_YAML='# Orca reads this file from the repo root. `scripts.setup` runs in a
# terminal when a workspace is created, so the work below is watchable and
# is not on the critical path of the container'"'"'s boot.
#
# Seeded by claude_orca on this folder'"'"'s first start, and yours from here
# on -- nothing rewrites it. The script it calls is idempotent.
scripts:
  setup: bash /opt/claude-orca/scripts/container/seed-project.sh 2>/dev/null || bash .claude-dev/template/scripts/container/seed-project.sh
'

@test "an orca.yaml an earlier template seeded is left byte-identical, and the log never mentions it" {
    local d
    d="$(fresh_project)"
    printf '%s' "$PREVIOUSLY_SEEDED_ORCA_YAML" > "$d/orca.yaml"
    cp "$d/orca.yaml" "$d/orca.yaml.before"
    run seed "$d"
    [ "$status" -eq 0 ]
    cmp -s "$d/orca.yaml" "$d/orca.yaml.before"
    case "$output" in
        *orca.yaml*) echo "the log talks about orca.yaml: $output"; return 1 ;;
    esac
}

@test "the same file with one extra line is left byte-identical too" {
    local d
    d="$(fresh_project)"
    printf '%s' "$PREVIOUSLY_SEEDED_ORCA_YAML" > "$d/orca.yaml"
    printf '  extra: true\n' >> "$d/orca.yaml"
    cp "$d/orca.yaml" "$d/orca.yaml.before"
    run seed "$d"
    [ "$status" -eq 0 ]
    cmp -s "$d/orca.yaml" "$d/orca.yaml.before"
}

@test "running it twice changes nothing the second time" {
    local d before after
    d="$(fresh_project)"
    seed "$d" >/dev/null
    before="$(find "$d" -type f -not -path '*/.git/*' -exec shasum {} + | sort | shasum)"
    seed "$d" >/dev/null
    after="$(find "$d" -type f -not -path '*/.git/*' -exec shasum {} + | sort | shasum)"
    [ "$before" = "$after" ]
}

@test "an orca.yaml the project already has is never overwritten" {
    local d
    d="$(fresh_project)"
    printf 'scripts:\n  setup: make bootstrap\n' > "$d/orca.yaml"
    cp "$d/orca.yaml" "$d/orca.yaml.before"
    seed "$d" >/dev/null
    cmp -s "$d/orca.yaml" "$d/orca.yaml.before"
}

@test "a beads snapshot is restored, and an existing issues.jsonl is left alone" {
    local d
    d="$(fresh_project)"
    mkdir -p "$d/.claude-dev-snapshots/20260101-000000"
    printf '{"id":"from-snapshot"}\n' > "$d/.claude-dev-snapshots/20260101-000000/issues.jsonl"

    seed "$d" >/dev/null
    grep -qF 'from-snapshot' "$d/.beads/issues.jsonl"

    # ... and a second run must not overwrite what is now there.
    printf '{"id":"live"}\n' > "$d/.beads/issues.jsonl"
    seed "$d" >/dev/null
    grep -qF 'live' "$d/.beads/issues.jsonl"
}

@test "it exits 0 and says so when there is no bd on PATH" {
    local d shadow
    d="$(fresh_project)"
    shadow="$BATS_TEST_TMPDIR/nobd"
    mkdir -p "$shadow"
    # helpers/setup.bash sets CLAUDE_ORCA_SKIP_BEADS for the whole suite,
    # and that short-circuits before the bd lookup this case is about.
    run env -u CLAUDE_ORCA_SKIP_BEADS PATH="$shadow:/usr/bin:/bin" PROJECT_DIR="$d" bash "$SEED"
    [ "$status" -eq 0 ]
    case "$output" in
        *"not on PATH"*) ;;
        *) echo "expected it to name the missing bd: $output"; return 1 ;;
    esac
}

@test "with no project at all it exits 0 rather than failing its caller" {
    run env -u PROJECT_DIR -u CLAUDE_ORCA_ROOT bash -c "cd / && bash '$SEED'"
    [ "$status" -eq 0 ]
}

@test "run from inside a project with no PROJECT_DIR, it finds the folder by walking up" {
    local d
    d="$(fresh_project)"
    mkdir -p "$d/.claude-dev" "$d/deep/deeper"
    run env -u PROJECT_DIR -u CLAUDE_ORCA_ROOT bash -c "cd '$d/deep/deeper' && bash '$SEED'"
    [ "$status" -eq 0 ]
    # It found the folder (not the cwd): the seeded block landed in the
    # project's own .gitignore, two levels above where it ran.
    grep -qxF 'attachments/' "$d/.gitignore"
    [ ! -e "$d/deep/deeper/.gitignore" ]
}

# Re-registered by claude-orca-88v (supersedes the seed-project contract
# for this one case) when S4, claude-orca-dbu.4, moved the call site: the
# intent is verbatim -- the entrypoint calls it, and it can never take PID
# 1 down -- and only the structure it asserts has changed. seed-project.sh
# is provision.d/50-seed-project now, reached through provision-run.sh
# after the container is up, and "never dies when it fails" is a stronger
# claim there than it was here: the runner records every step's exit code
# and exits 0 regardless, so the failure cannot propagate at all.
@test "the entrypoint calls it, and never dies when it fails" {
    local ep="${BATS_TEST_DIRNAME}/../scripts/container/entrypoint.sh"
    local runner="${BATS_TEST_DIRNAME}/../scripts/container/provision-run.sh"
    local step="${BATS_TEST_DIRNAME}/../scripts/container/provision.d/50-seed-project"

    # The chain: entrypoint -> provision-run.sh -> 50-seed-project ->
    # seed-project.sh.
    run grep -nF 'provision-run.sh' "$ep"
    [ "$status" -eq 0 ]
    [ -x "$runner" ]
    [ -x "$step" ]
    run grep -nF 'seed-project.sh' "$step"
    [ "$status" -eq 0 ]

    # No call site on that chain can take PID 1 down with it: the runner
    # captures each step's exit code into run/provision/<step>.status and
    # exits 0 whatever happened.
    run grep -nE '^exit 0$' "$runner"
    [ "$status" -eq 0 ]
    run grep -nF '.status' "$runner"
    [ "$status" -eq 0 ]

    # And the four seedings it replaced are gone from the entrypoint.
    run grep -cE '^(seed_gitignore|restore_beads_snapshot)\(\)' "$ep"
    [ "$output" = "0" ]
}

@test "CLAUDE_ORCA_SKIP_BEADS=1 is honoured here, since this is where the tracker is made now" {
    local d
    d="$(fresh_project skipbeads)"
    run env PROJECT_DIR="$d" CLAUDE_ORCA_SKIP_BEADS=1 bash "$SEED"
    [ "$status" -eq 0 ]
    [ ! -e "$d/.beads" ]

    # ... and a snapshot is still restored, because that is not the same
    # thing as creating a tracker: it is not losing what a teardown saved.
    mkdir -p "$d/.claude-dev-snapshots/20260101-000000"
    printf '{"id":"kept"}\n' > "$d/.claude-dev-snapshots/20260101-000000/issues.jsonl"
    run env PROJECT_DIR="$d" CLAUDE_ORCA_SKIP_BEADS=1 bash "$SEED"
    [ "$status" -eq 0 ]
    grep -qF 'kept' "$d/.beads/issues.jsonl"
}

@test "an orca.yaml that is a SYMLINK is left alone: still a link, its target unchanged" {
    local d outside
    d="$(fresh_project)"
    # The target holds the content an earlier template seeded. Seeding no
    # longer touches orca.yaml at all, so a link out of the folder is never
    # followed or written through (claude-orca-bbd kept this as a standing
    # check: this folder's tooling writes inside this folder only).
    outside="$BATS_TEST_TMPDIR/outside-target.yaml"
    printf '%s' "$PREVIOUSLY_SEEDED_ORCA_YAML" > "$outside"
    cp "$outside" "$outside.before"
    ln -s "$outside" "$d/orca.yaml"

    seed "$d" >/dev/null

    [ -L "$d/orca.yaml" ]
    # cmp, not a string compare: "$(cat ...)" strips the trailing newline
    # the fixture carries, so compare the bytes.
    cmp -s "$outside" "$outside.before"
}
