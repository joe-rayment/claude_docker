#!/usr/bin/env bats
# Guards: Ghostty's per-pane router sends a pane opened inside a sandboxed folder to that folder's `claude-dev pane`, and every other pane (outside any folder, route:false, no launcher, deleted cwd, router gone) to the user's normal Mac shell -- never an error.
# Fails if: the walk-up stops finding a folder 3 levels down, "route": false stops opting a folder out, a missing/non-executable claude-dev crashes instead of falling to the shell, or the include's `command` line stops falling back when the router file is missing.
# Run: bats tests/ghostty-router.bats
#
# The router is scripts/mac/ghostty-pane run under the real /bin/sh. The
# "claude-dev" it execs is a stub that prints its argv; the "Mac shell" is
# a stub too (SHELL), so nothing here starts Docker, ssh or a login shell.
# Every path lives under $BATS_TEST_TMPDIR; HOME is a fixture.

load helpers/user

ROUTER="$BATS_TEST_DIRNAME/../scripts/mac/ghostty-pane"
INCLUDE="$BATS_TEST_DIRNAME/../config/ghostty/claude-dev.ghostty"

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    # The stub shell: says it ran and with what.
    FAKE_SHELL="$BATS_TEST_TMPDIR/fakeshell"
    printf '#!/bin/sh\necho "FAKE-SHELL $*"\n' > "$FAKE_SHELL"
    chmod +x "$FAKE_SHELL"
    export SHELL="$FAKE_SHELL"
    unset CLAUDE_DEV_ROUTER_TRACE
}

# A fake sandboxed folder at $1: .claude-dev/claude-orca.json (content $2,
# default "{}") and a ./claude-dev stub printing its argv, one [arg] each.
make_folder() {
    mkdir -p "$1/.claude-dev"
    printf '%s\n' "${2:-{\}}" > "$1/.claude-dev/claude-orca.json"
    printf '#!/bin/sh\nprintf "CLAUDE-DEV-STUB"\nfor a in "$@"; do printf " [%%s]" "$a"; done\necho\n' > "$1/claude-dev"
    chmod +x "$1/claude-dev"
}

# Run the router with $1 as the pane's working directory.
run_router_in() {
    run bash -c 'cd "$1" && exec /bin/sh "$2"' _ "$1" "$ROUTER"
}

@test "a pane in the sandboxed folder itself runs claude-dev pane <folder>" {
    make_folder "$BATS_TEST_TMPDIR/proj"
    run_router_in "$BATS_TEST_TMPDIR/proj"
    [ "$status" -eq 0 ]
    [ "$output" = "CLAUDE-DEV-STUB [pane] [$BATS_TEST_TMPDIR/proj]" ]
}

@test "a pane nested three folders deep still finds its folder" {
    make_folder "$BATS_TEST_TMPDIR/proj"
    mkdir -p "$BATS_TEST_TMPDIR/proj/a/b/c"
    run_router_in "$BATS_TEST_TMPDIR/proj/a/b/c"
    [ "$status" -eq 0 ]
    [ "$output" = "CLAUDE-DEV-STUB [pane] [$BATS_TEST_TMPDIR/proj]" ]
}

@test "a folder name with spaces reaches claude-dev as one argument" {
    make_folder "$BATS_TEST_TMPDIR/my proj"
    mkdir -p "$BATS_TEST_TMPDIR/my proj/sub"
    run_router_in "$BATS_TEST_TMPDIR/my proj/sub"
    [ "$status" -eq 0 ]
    [ "$output" = "CLAUDE-DEV-STUB [pane] [$BATS_TEST_TMPDIR/my proj]" ]
}

@test "a pane outside every sandboxed folder gets the Mac login shell" {
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere/deep"
    run_router_in "$BATS_TEST_TMPDIR/elsewhere/deep"
    [ "$status" -eq 0 ]
    [ "$output" = "FAKE-SHELL -l" ]
}

@test "route:false opts the folder out, with or without spaces around the colon" {
    make_folder "$BATS_TEST_TMPDIR/proj" '{"name": "p", "route": false}'
    run_router_in "$BATS_TEST_TMPDIR/proj"
    [ "$output" = "FAKE-SHELL -l" ]
    make_folder "$BATS_TEST_TMPDIR/proj2" '{"route":false}'
    run_router_in "$BATS_TEST_TMPDIR/proj2"
    [ "$output" = "FAKE-SHELL -l" ]
}

@test "route:true (or no route key) still routes" {
    make_folder "$BATS_TEST_TMPDIR/proj" '{"route": true}'
    run_router_in "$BATS_TEST_TMPDIR/proj"
    [ "$output" = "CLAUDE-DEV-STUB [pane] [$BATS_TEST_TMPDIR/proj]" ]
}

@test "a folder whose claude-dev is missing or not executable gets the Mac shell" {
    make_folder "$BATS_TEST_TMPDIR/proj"
    chmod -x "$BATS_TEST_TMPDIR/proj/claude-dev"
    run_router_in "$BATS_TEST_TMPDIR/proj"
    [ "$output" = "FAKE-SHELL -l" ]
    rm "$BATS_TEST_TMPDIR/proj/claude-dev"
    run_router_in "$BATS_TEST_TMPDIR/proj"
    [ "$output" = "FAKE-SHELL -l" ]
}

@test "a deleted working directory gets the Mac shell, not an error" {
    make_folder "$BATS_TEST_TMPDIR/proj"
    mkdir -p "$BATS_TEST_TMPDIR/proj/gone"
    run bash -c 'cd "$1" && rmdir "$1" && exec /bin/sh "$2"' _ "$BATS_TEST_TMPDIR/proj/gone" "$ROUTER"
    [ "$status" -eq 0 ]
    # (dash itself may complain "getcwd() failed" first; the shell still starts)
    [[ "$output" == *"FAKE-SHELL -l" ]]
}

@test "an unreadable working directory gets the Mac shell" {
    need_nonroot
    make_folder "$BATS_TEST_TMPDIR/proj"
    mkdir -p "$BATS_TEST_TMPDIR/proj/locked"
    run bash -c 'cd "$1" && chmod 000 "$1" && exec /bin/sh "$2"' _ "$BATS_TEST_TMPDIR/proj/locked" "$ROUTER"
    chmod 755 "$BATS_TEST_TMPDIR/proj/locked"
    [ "$status" -eq 0 ]
    [ "$output" = "FAKE-SHELL -l" ]
}

@test "the walk gives up after 40 levels" {
    make_folder "$BATS_TEST_TMPDIR/proj"
    deep="$BATS_TEST_TMPDIR/proj"
    for i in $(seq 1 45); do deep="$deep/d$i"; done
    mkdir -p "$deep"
    run_router_in "$deep"
    [ "$output" = "FAKE-SHELL -l" ]
}

@test "a bad SHELL falls back to a shell that exists" {
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
    SHELL="$BATS_TEST_TMPDIR/no-such-shell" run_router_in "$BATS_TEST_TMPDIR/elsewhere" < /dev/null
    # /bin/zsh (macOS) or /bin/sh was started instead; the pane did not die.
    [ "$status" -eq 0 ]
    [[ "$output" != *"not found"* ]]
    [[ "$output" != *"No such file"* ]]
}

@test "CLAUDE_DEV_ROUTER_TRACE=1 names the decision on stderr" {
    make_folder "$BATS_TEST_TMPDIR/proj"
    CLAUDE_DEV_ROUTER_TRACE=1 run_router_in "$BATS_TEST_TMPDIR/proj"
    [[ "$output" == *"ghostty-pane: route $BATS_TEST_TMPDIR/proj"* ]]
    CLAUDE_DEV_ROUTER_TRACE=1 run_router_in "$BATS_TEST_TMPDIR"
    [[ "$output" == *"ghostty-pane: shell (no sandboxed folder above"* ]]
}

# --- the include's own `command` line, as Ghostty would run it ------------

# The value of `command =` in the include, run the way Ghostty runs a command
# with shell metacharacters: handed to /bin/sh -c.
run_include_command() {
    local cmd
    cmd="$(sed -n 's/^command = //p' "$INCLUDE")"
    [ -n "$cmd" ]
    run bash -c 'cd "$1" && exec /bin/sh -c "$2"' _ "$1" "$cmd"
}

@test "the include's command line falls to the Mac shell when the router file is missing" {
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
    [ ! -e "$HOME/.local/share/claude-dev/ghostty-pane" ]
    run_include_command "$BATS_TEST_TMPDIR/elsewhere"
    [ "$status" -eq 0 ]
    [ "$output" = "FAKE-SHELL -l" ]
}

@test "the include's command line runs the installed router when it is there" {
    make_folder "$BATS_TEST_TMPDIR/proj"
    mkdir -p "$HOME/.local/share/claude-dev"
    cp "$ROUTER" "$HOME/.local/share/claude-dev/ghostty-pane"
    chmod 755 "$HOME/.local/share/claude-dev/ghostty-pane"
    run_include_command "$BATS_TEST_TMPDIR/proj"
    [ "$status" -eq 0 ]
    [ "$output" = "CLAUDE-DEV-STUB [pane] [$BATS_TEST_TMPDIR/proj]" ]
}

@test "the include and the router carry the same version stamp" {
    [ "$(head -1 "$INCLUDE")" = "# claude-dev ghostty v1" ]
    [ "$(sed -n 2p "$ROUTER")" = "$(head -1 "$INCLUDE")" ]
    grep -q '^shell-integration = @SHELL_INTEGRATION@$' "$INCLUDE"
}
