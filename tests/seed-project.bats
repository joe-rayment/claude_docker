#!/usr/bin/env bats
#
# seed-project.sh -- the project seeding, out of the boot's critical path.
#
# It used to live inside the entrypoint, which is PID 1: every line of it
# sat on the path that has to bring Orca up, and it ran before there was a
# terminal to watch it in. Orca's own `scripts.setup` (from orca.yaml, run
# in a terminal when a workspace is created) is the right home for it, so
# the body moved into one script with two callers -- Orca's hook, and the
# entrypoint as a floor, because a folder must never depend on a hook
# having fired to have a tracker in it.
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

@test "it seeds the gitignore block, attachments and orca.yaml, and says what it did" {
    local d
    d="$(fresh_project)"
    run seed "$d"
    [ "$status" -eq 0 ]

    grep -qF '# claude_orca' "$d/.gitignore"
    grep -qxF '.claude-dev/' "$d/.gitignore"
    grep -qxF 'attachments/' "$d/.gitignore"
    [ -d "$d/attachments" ]
    [ -f "$d/orca.yaml" ]
    # claude-orca-8jb: a scripts.setup key here makes Orca open a second,
    # redundant terminal on workspace creation -- provision.d/50-seed-project
    # already runs this same seeding invisibly. The seeded file is comments
    # only now.
    run grep -c 'scripts:' "$d/orca.yaml"
    [ "$output" = "0" ]
    run grep -c 'setup:' "$d/orca.yaml"
    [ "$output" = "0" ]
    run grep -c 'seed-project.sh' "$d/orca.yaml"
    [ "$output" = "0" ]
}

# claude-orca-8jb: the exact content the template used to seed, byte for
# byte, kept here so the migration case below can reproduce it. This is
# NOT the current seeded content -- it is history, for the safety check.
PREVIOUSLY_SEEDED_ORCA_YAML='# Orca reads this file from the repo root. `scripts.setup` runs in a
# terminal when a workspace is created, so the work below is watchable and
# is not on the critical path of the container'"'"'s boot.
#
# Seeded by claude_orca on this folder'"'"'s first start, and yours from here
# on -- nothing rewrites it. The script it calls is idempotent.
scripts:
  setup: bash /opt/claude-orca/scripts/container/seed-project.sh 2>/dev/null || bash .claude-dev/template/scripts/container/seed-project.sh
'

@test "MIGRATION: an orca.yaml byte-identical to the previously-seeded content is replaced" {
    local d
    d="$(fresh_project)"
    printf '%s' "$PREVIOUSLY_SEEDED_ORCA_YAML" > "$d/orca.yaml"
    seed "$d" >/dev/null
    run grep -c 'scripts:' "$d/orca.yaml"
    [ "$output" = "0" ]
    run grep -c 'setup:' "$d/orca.yaml"
    [ "$output" = "0" ]
}

@test "NEVER-CLOBBER, harder: previously-seeded content plus one extra line is left byte-identical" {
    local d before after
    d="$(fresh_project)"
    printf '%s' "$PREVIOUSLY_SEEDED_ORCA_YAML" > "$d/orca.yaml"
    printf '  extra: true\n' >> "$d/orca.yaml"
    before="$(cat "$d/orca.yaml")"
    run seed "$d"
    [ "$status" -eq 0 ]
    after="$(cat "$d/orca.yaml")"
    [ "$before" = "$after" ]
    case "$output" in
        *"left alone"*) ;;
        *) echo "expected it to log that the file was left alone: $output"; return 1 ;;
    esac
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
    seed "$d" >/dev/null
    grep -qF 'make bootstrap' "$d/orca.yaml"
    run grep -c 'seed-project.sh' "$d/orca.yaml"
    [ "$output" = "0" ]
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
    [ -f "$d/orca.yaml" ]
}

# Re-registered by claude-orca-88v (supersedes the seed-project contract
# for this one case) when S4, claude-orca-dbu.4, moved the call site: the
# intent is verbatim -- the entrypoint calls it, and it can never take PID
# 1 down -- and only the structure it asserts has changed. seed-project.sh
# is provision.d/50-seed-project now, reached through provision-run.sh
# after Orca is serving, and "never dies when it fails" is a stronger
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
