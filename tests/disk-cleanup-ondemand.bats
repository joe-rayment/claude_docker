#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# disk-cleanup-ondemand.bats — bead claude-orca-p91's acceptance contract
# (FROZEN from its RED commit onward: never edit to make an implementation
# pass).
#
# On-demand instruments: idle browser caches (ms-playwright, the playwright
# package home), stale npx residue and stale Claude Code versions are swept
# because they are re-fetched on demand; the version the symlink points at
# is kept, and nothing outside $HOME (a fake /opt among it) is touched.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CLEANUP="$REPO_ROOT/scripts/disk-cleanup.sh"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export HOME="$BATS_TEST_TMPDIR/home"
    export TMP_SCAN_DIR="$BATS_TEST_TMPDIR/scan"
    export WORKSPACE="$BATS_TEST_TMPDIR/ws"
    mkdir -p "$HOME" "$TMP_SCAN_DIR" "$WORKSPACE"
}

# age every file AND directory in a tree (an install adds directories, so
# a directory's own mtime is part of "when was this last used")
aged_tree() { find "$1" -exec touch -d "$2" {} + ; }

@test "sweep: a 15-day-idle ms-playwright goes and a 1-day one stays" {
    old_home="$BATS_TEST_TMPDIR/old-home"
    new_home="$BATS_TEST_TMPDIR/new-home"
    mkdir -p "$old_home/.cache/ms-playwright/chromium-1190" \
             "$new_home/.cache/ms-playwright/chromium-1191"
    printf 'browser' > "$old_home/.cache/ms-playwright/chromium-1190/chrome"
    printf 'browser' > "$new_home/.cache/ms-playwright/chromium-1191/chrome"
    aged_tree "$old_home/.cache/ms-playwright" '15 days ago'
    aged_tree "$new_home/.cache/ms-playwright" '1 day ago'

    HOME="$old_home" run bash "$CLEANUP"
    [ "$status" -eq 0 ]
    [ ! -d "$old_home/.cache/ms-playwright" ]

    HOME="$new_home" run bash "$CLEANUP"
    [ "$status" -eq 0 ]
    [ -f "$new_home/.cache/ms-playwright/chromium-1191/chrome" ]
}

@test "sweep: an idle claude-orca-playwright package home goes, a fresh one stays" {
    idle="$HOME/.cache/claude-orca-playwright/node_modules/playwright"
    mkdir -p "$idle"
    printf '{"name":"playwright"}' > "$idle/package.json"
    aged_tree "$HOME/.cache/claude-orca-playwright" '15 days ago'

    run bash "$CLEANUP"
    [ "$status" -eq 0 ]
    [ ! -d "$HOME/.cache/claude-orca-playwright" ]

    fresh="$BATS_TEST_TMPDIR/fresh-home/.cache/claude-orca-playwright/node_modules/playwright"
    mkdir -p "$fresh"
    printf '{"name":"playwright"}' > "$fresh/package.json"

    HOME="$BATS_TEST_TMPDIR/fresh-home" run bash "$CLEANUP"
    [ "$status" -eq 0 ]
    [ -f "$fresh/package.json" ]
}

@test "sweep: a stale claude version dir goes while the symlink target stays" {
    vdir="$HOME/.local/share/claude/versions"
    mkdir -p "$vdir/2.0.0/bin" "$vdir/2.1.271/bin" "$HOME/.local/bin"
    printf 'x' > "$vdir/2.0.0/bin/claude"
    printf 'x' > "$vdir/2.1.271/bin/claude"
    ln -s "$vdir/2.1.271/bin/claude" "$HOME/.local/bin/claude"

    run bash "$CLEANUP"
    [ "$status" -eq 0 ]
    [ ! -d "$vdir/2.0.0" ]
    [ -f "$vdir/2.1.271/bin/claude" ]
    [ -L "$HOME/.local/bin/claude" ]
}

@test "sweep: _npx entries older than CLAUDE_ORCA_CLEANUP_NPM_DAYS go, fresh ones stay" {
    npx_dir="$HOME/.npm/_npx"
    mkdir -p "$npx_dir/aaa-old" "$npx_dir/bbb-new"
    printf 'x' > "$npx_dir/aaa-old/pkg"
    printf 'x' > "$npx_dir/bbb-new/pkg"
    aged_tree "$npx_dir/aaa-old" '20 days ago'
    aged_tree "$npx_dir/bbb-new" '1 day ago'

    run bash "$CLEANUP"
    [ "$status" -eq 0 ]
    [ ! -d "$npx_dir/aaa-old" ]
    [ -d "$npx_dir/bbb-new" ]
}

@test "sweep: nothing under a fake /opt is touched" {
    fake_opt="$BATS_TEST_TMPDIR/opt"
    mkdir -p "$fake_opt/claude/bin"
    printf 'live' > "$fake_opt/claude/bin/claude"
    printf '9.9.9' > "$fake_opt/claude/VERSION"

    # claude runs from /opt here, so every versions/ copy is not the target
    vdir="$HOME/.local/share/claude/versions"
    mkdir -p "$vdir/2.0.0" "$vdir/2.1.271" "$HOME/.local/bin"
    ln -s "$fake_opt/claude/bin/claude" "$HOME/.local/bin/claude"

    run bash "$CLEANUP"
    [ "$status" -eq 0 ]
    [ ! -d "$vdir/2.0.0" ]
    [ ! -d "$vdir/2.1.271" ]
    [ -f "$fake_opt/claude/bin/claude" ]
    [ "$(cat "$fake_opt/claude/VERSION")" = "9.9.9" ]
    [ -L "$HOME/.local/bin/claude" ]
}

@test "--report names the on-demand items with their idle-day policies" {
    mkdir -p "$HOME/.cache/ms-playwright" "$HOME/.cache/claude-orca-playwright" \
        "$HOME/.npm/_npx" "$HOME/.local/share/claude/versions"

    run bash "$CLEANUP" --report
    [ "$status" -eq 0 ]
    [[ "$output" == *"ms-playwright"* ]]
    [[ "$output" == *"claude-orca-playwright"* ]]
    [[ "$output" == *"_npx"* ]]
    [[ "$output" == *"claude/versions"* ]]
    [[ "$output" == *"on-demand, swept after 14 idle days"* ]]
    [[ "$output" == *"current kept"* ]]
}
