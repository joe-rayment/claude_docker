#!/usr/bin/env bats
#
# S12 acceptance contract (claude-orca-3sk.23), rebased onto v3 by
# claude-orca-qa2.3. The install IS the folder, so teardown deletes it
# whole (launcher included) and the snapshots live beside it, in
# <project>/.claude-dev-snapshots/. What survives from v2 here is exactly
# the part that is not about Seatbelt: beads state is the one thing in a
# project that is expensive to lose and lives nowhere else, so the
# snapshot/restore round trip is checked end to end. The container
# lifecycle itself (stop, rm, recreate on --update) is tests/launcher-v3.bats.
#
# Everything runs against the local git fixture template and a fixture
# $HOME built by helpers/setup.bash -- never the real shell rc files.

load helpers/setup

@test "--teardown snapshots beads to the documented location then removes .claude-dev, ./claude-dev and only the seeded gitignore lines" {
    mkdir -p "$PROJECT_DIR"
    printf 'node_modules/\n*.log\n' > "$PROJECT_DIR/.gitignore"
    make_project "$PROJECT_DIR"

    mkdir -p "$PROJECT_DIR/.beads"
    printf '{"id":"x-1"}\n' > "$PROJECT_DIR/.beads/issues.jsonl"
    printf '{"prefix":"x"}\n' > "$PROJECT_DIR/.beads/metadata.json"
    printf 'mine\n' > "$PROJECT_DIR/keep.txt"

    # A folder upgraded from v2 still carries the shell hook v3 never wants.
    printf '%s\n' 'eval "$(/opt/homebrew/bin/brew shellenv)"' > "$HOME/.zprofile"
    {
        echo "# >>> claude_orca >>>"
        echo "stale v2 hook"
        echo "# <<< claude_orca <<<"
    } >> "$HOME/.zprofile"

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --teardown
    [ "$status" -eq 0 ]

    # The snapshot goes exactly where TEARDOWN_RECOVERY.md says it goes --
    # beside the folder, never in a central location.
    grep -qF '<project>/.claude-dev-snapshots/<timestamp>/' \
        "$REPO_ROOT/knowledge-base/TEARDOWN_RECOVERY.md"

    local root snap
    root="$PROJECT_DIR/.claude-dev-snapshots"
    [ "$(ls -1 "$root" | wc -l | tr -d ' ')" = "1" ]
    snap="$root/$(ls -1 "$root")"
    [[ "$(basename "$snap")" =~ ^[0-9]{8}-[0-9]{6}$ ]]
    [ "$(cat "$snap/issues.jsonl")" = '{"id":"x-1"}' ]
    [ "$(cat "$snap/metadata.json")" = '{"prefix":"x"}' ]
    [[ "$output" == *"$snap"* ]]

    # Gone: the install, the stub, the stale rc block. Kept: everything
    # else, including the user's own gitignore and rc lines, byte for byte.
    [ ! -d "$PROJECT_DIR/.claude-dev" ]
    [ ! -e "$PROJECT_DIR/claude-dev" ]
    [ "$(cat "$PROJECT_DIR/.gitignore")" = "$(printf 'node_modules/\n*.log')" ]
    [ "$(cat "$HOME/.zprofile")" = 'eval "$(/opt/homebrew/bin/brew shellenv)"' ]
    [ "$(cat "$PROJECT_DIR/keep.txt")" = "mine" ]
    [ -f "$PROJECT_DIR/.beads/issues.jsonl" ]
}

# The other half of the round trip -- restoring the newest snapshot on the
# next registration -- moved into the container with the rest of the
# seeding (startup v4, claude-orca-qa2.9): the entrypoint restores it
# before `bd init`, and tests/container-entrypoint.bats runs that natively.
# Snapshotting stays here, because teardown is the Mac's own command.
