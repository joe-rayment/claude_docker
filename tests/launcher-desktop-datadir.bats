#!/usr/bin/env bats
#
# Follow-up hardening for claude-orca-tgr (verifier review): two ways the
# desktop hand-off could hang or guess wrong that the first pass did not
# cover.
#
#   * orca_quit_app() ran osascript in the foreground: an "Are you sure?"
#     dialog nobody is there to answer leaves it blocked forever, and
#     macOS has no `timeout`. It now backgrounds osascript and watches it
#     with its own poll loop instead.
#   * orca_user_data_dir() silently guessed between two Library paths.
#     It now discovers the real one from the running app's own open files
#     (`lsof -p <pid> -Fn`, `.result.app.pid` from `status --json`) and
#     caches it under .claude-dev/state/, ahead of the two guesses.
#
# Both are exercised directly against the real function bodies -- neither
# needs the CLI dispatch at the bottom of scripts/launcher.sh running, so
# a small probe script sources just the functions under test (`sed`,
# never copied by hand) and calls whichever one a case names.

load helpers/setup

LAUNCHER_SH="$REPO_ROOT/scripts/launcher.sh"

write_probe() {
    {
        echo '#!/usr/bin/env bash'
        sed -n '/^orca_json_app_running()/,/^}/p' "$LAUNCHER_SH"
        sed -n '/^orca_json_app_pid()/,/^}/p' "$LAUNCHER_SH"
        sed -n '/^orca_no_data_dir_message()/,/^}/p' "$LAUNCHER_SH"
        sed -n '/^orca_user_data_dir()/,/^}/p' "$LAUNCHER_SH"
        sed -n '/^orca_quit_app()/,/^}/p' "$LAUNCHER_SH"
        echo '"$@"'
    } > "$1"
    chmod +x "$1"
}

@test "orca_user_data_dir discovers the data dir from the running app's open files and caches it under state" {
    local dir cli probe lsofdir
    dir="$(abspath "$PROJECT_DIR")"
    cli="$CLAUDE_ORCA_APP/Contents/Resources/bin/orca"
    write_stub_orca "$cli"
    export ORCA_STUB_APP_RUNNING=true
    lsofdir="$BATS_TEST_TMPDIR/mac-orca-data"
    mkdir -p "$lsofdir"
    export ORCA_STUB_LSOF_DIR="$lsofdir"

    probe="$BATS_TEST_TMPDIR/probe.sh"
    write_probe "$probe"

    run bash "$probe" orca_user_data_dir "$dir" "$cli"
    [ "$status" -eq 0 ]
    [ "$output" = "$lsofdir" ]

    # ... and next time does not need the app running (or lsof) at all.
    [ "$(cat "$dir/.claude-dev/state/orca-data-dir")" = "$lsofdir" ]
}

@test "orca_user_data_dir prefers ORCA_USER_DATA_PATH, then the cache, over discovery" {
    local dir cli probe lsofdir cached explicit
    dir="$(abspath "$PROJECT_DIR")"
    cli="$CLAUDE_ORCA_APP/Contents/Resources/bin/orca"
    write_stub_orca "$cli"
    export ORCA_STUB_APP_RUNNING=true
    lsofdir="$BATS_TEST_TMPDIR/mac-orca-data-lsof"
    mkdir -p "$lsofdir"
    export ORCA_STUB_LSOF_DIR="$lsofdir"

    probe="$BATS_TEST_TMPDIR/probe.sh"
    write_probe "$probe"

    # A cache from an earlier discovery, at a DIFFERENT (still-existing)
    # directory than lsof would find now -- if this run reached lsof at
    # all it would answer $lsofdir instead, so the cache winning is a
    # real assertion and not just "the only answer available".
    cached="$BATS_TEST_TMPDIR/cached-data-dir"
    mkdir -p "$cached" "$dir/.claude-dev/state"
    printf '%s\n' "$cached" > "$dir/.claude-dev/state/orca-data-dir"

    run bash "$probe" orca_user_data_dir "$dir" "$cli"
    [ "$status" -eq 0 ]
    [ "$output" = "$cached" ]

    # ... and an explicit override beats even that.
    explicit="$BATS_TEST_TMPDIR/explicit-data-dir"
    run env ORCA_USER_DATA_PATH="$explicit" bash "$probe" orca_user_data_dir "$dir" "$cli"
    [ "$status" -eq 0 ]
    [ "$output" = "$explicit" ]
}

@test "orca_quit_app gives up after its watchdog when osascript hangs" {
    local probe t0 t1 elapsed
    export OSASCRIPT_STUB_HANG=1
    export CLAUDE_ORCA_ORCA_WAIT=1

    probe="$BATS_TEST_TMPDIR/probe.sh"
    write_probe "$probe"

    t0="$(date +%s)"
    run bash "$probe" orca_quit_app "$CLAUDE_ORCA_APP"
    t1="$(date +%s)"
    elapsed=$((t1 - t0))

    [ "$status" -eq 2 ]
    grep -qF "did not quit" <<< "$output"
    grep -qF "dialog may be open" <<< "$output"
    # The whole point: it gave up around CLAUDE_ORCA_ORCA_WAIT (1s), not
    # after the osascript stub's own 30s sleep.
    [ "$elapsed" -lt 10 ]
}
