#!/usr/bin/env bats
#
# `claude-dev verify` -- the command that reads the seeding back.
#
# --doctor answers "can this folder open at all": the CLI, the daemon, the
# image, the container, the port, the URL. None of that says whether the
# folder is SET UP. The rulebook, the six agent definitions, the hooks
# (with Orca's own entries kept), the git identity, the Claude first-run
# keys, Orca's worktree base and theme, the beads database -- every one is
# written by code that logs a line and moves on, and nothing read any of
# it back. A folder whose seeding half failed looked exactly like one that
# worked, which is how an owner came to conclude on 2026-09-07 that the
# things they had asked for were "fundamentally missing" from the
# template. They were present; nothing could say so.
#
# Assertions are functions, never a bare `[[ ]]` (see run-tests.sh).

load helpers/setup

VERIFY_SH="${BATS_TEST_DIRNAME}/../scripts/container/verify-folder.sh"

contains() {
    case "$1" in
        *"$2"*) return 0 ;;
    esac
    printf 'expected to contain: %s\n           actual: %s\n' "$2" "$1" >&2
    return 1
}

@test "verify refuses a directory that was never registered" {
    mkdir -p "$BATS_TEST_TMPDIR/plain"
    run bash "$REPO_ROOT/scripts/launcher.sh" verify "$BATS_TEST_TMPDIR/plain"
    [ "$status" -ne 0 ]
    contains "$output" "is not registered"
}

@test "verify stops at the container when there is none, and says how to get one" {
    mkdir -p "$PROJECT_DIR"
    local primary name
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null
    name="claude-orca-$(basename "$primary")"
    rm -f "$CONTAINER_STUB_STATE/containers/$name"

    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 2 ]
    contains "$output" "container"
    contains "$output" "run ./claude-dev first"
}

@test "verify prints the Mac rows and the container's own rows, and passes when both are clean" {
    mkdir -p "$PROJECT_DIR"
    local primary
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null

    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 0 ]
    # The Mac's own four.
    contains "$output" "container"
    contains "$output" "image"
    contains "$output" "port"
    contains "$output" "web url"
    # ... and what only the container can answer, passed through.
    contains "$output" "mount point"
    contains "$output" "rulebook"
    contains "$output" "openrouter guard"
    contains "$output" "Everything this folder promises is there."
}

@test "one FAIL row from inside fails the command and names the way out" {
    mkdir -p "$PROJECT_DIR"
    local primary
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null

    export CLAUDE_ORCA_TEST_VERIFY_FAIL=1
    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 2 ]
    contains "$output" "FAIL"
    contains "$output" "rulebook"
    contains "$output" "--update"
}

@test "the in-container checklist prints parseable rows and fails when the folder is wrong" {
    # Run natively, against a directory that is NOT a set-up folder: every
    # row is a FAIL or n/a, which is exactly what the format has to
    # survive. What matters here is the shape the launcher parses.
    run env PROJECT_DIR="$BATS_TEST_TMPDIR/nowhere" HOME="$BATS_TEST_TMPDIR/nohome" \
        bash "$VERIFY_SH"
    [ "$status" -eq 1 ]

    local line first
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        first="${line%%	*}"
        case "$first" in
            ok|FAIL|n/a) ;;
            *) echo "row does not start with ok/FAIL/n/a: $line"; return 1 ;;
        esac
        # name and detail are the other two fields
        case "$line" in
            *"	"*) ;;
            *) echo "row is not tab separated: $line"; return 1 ;;
        esac
    done <<< "$output"

    contains "$output" "mount point"
}

@test "a container whose image predates the checklist fails verify instead of passing it" {
    # The four Mac rows are about the container, not about the folder's
    # setup, so on their own they say nothing -- and an image older than
    # verify-folder.sh makes the exec answer nothing at all. Reporting
    # that as "everything this folder promises is there" would be the
    # exact failure this command was written to end.
    mkdir -p "$PROJECT_DIR"
    local primary
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null

    export CLAUDE_ORCA_TEST_VERIFY_SILENT=1
    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 2 ]
    contains "$output" "answered nothing"
    contains "$output" "--update"
}

# --- desktop Orca, S3 (claude-orca-8uo.4, claude-orca-qhq) ---------------
#
# The one risk the desktop client adds, and its guard (.claude/plans/
# desktop-orca.md S5). Orca's desktop app can open LOCAL workspaces --
# folders on the Mac, whose agents run on the Mac with no container around
# them. The browser tab cannot do that by construction; the app can, and
# there is no knob in 1.4.197 to turn it off. Since claude-orca-qhq the app
# is launched on a profile the launcher owns outright (never the user's own
# Orca profile) and that holds only this folder's environment, so this is a
# detection rather than a prevention: verify reads THAT profile's own local
# repo list back and fails if it lists anything at all -- any repo in a
# profile the launcher controls is a leak, whatever path it names.
#
# `orca repo list --json` with no --environment IS the local list; there is
# no --host flag in 1.4.197 (bead claude-orca-8uo.1, correcting the plan).

@test "verify fails when the folder's Orca profile lists a local repo" {
    mkdir -p "$PROJECT_DIR"
    local primary
    primary="$(abspath "$PROJECT_DIR")"
    export STUB_UNAME_S=Darwin
    export STUB_UNAME_M=arm64
    write_stub_orca "$CLAUDE_ORCA_APP/Contents/Resources/bin/orca"
    make_project_v3 "$primary" >/dev/null

    # The ordinary case first: the folder's own conduit profile holds no
    # local project at all.
    export ORCA_STUB_LOCAL_REPOS=""
    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 0 ]
    contains "$output" "holds no local project"

    # And the finding: ANY repo in this folder's own profile is a leak --
    # nothing but this folder's environment is ever added to it, so a repo
    # showing up at all, whatever path it names, is a workspace whose
    # agents run outside the container. A FAIL row and a failing exit code,
    # not a note.
    export ORCA_STUB_LOCAL_REPOS="$BATS_TEST_TMPDIR/some-other-project"
    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 2 ]
    contains "$output" "FAIL"
    contains "$output" "LOCAL project"
}
