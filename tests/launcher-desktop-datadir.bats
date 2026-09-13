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
        sed -n '/^orca_data_json_repo_paths()/,/^}/p' "$LAUNCHER_SH"
        sed -n '/^same_dir_path()/,/^}/p' "$LAUNCHER_SH"
        sed -n '/^orca_paths_include_dir()/,/^}/p' "$LAUNCHER_SH"
        sed -n '/^orca_path_is_this_folder()/,/^}/p' "$LAUNCHER_SH"
        sed -n '/^orca_data_json_lists_dir()/,/^}/p' "$LAUNCHER_SH"
        sed -n '/^orca_strip_local_repo()/,/^}/p' "$LAUNCHER_SH"
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

# --- what the strip removes, and how it knows it landed ------------------
#
# Three facts the hand-off's whole control flow now rests on, each read
# straight off the function that produces it:
#
#   * the Mac's own paths can be symlinks (/Users/joe/code -> /Volumes/...),
#     so string equality alone answers "is this my folder?" wrong;
#   * a repo attached to a REMOTE host lives in the same .repos array as a
#     local one, told apart only by executionHostId -- and the container's
#     own workspace is one of those, so counting it as a local leak means
#     quitting the app over this folder's own sandbox;
#   * a rewrite that did not change the file has to be an error, because
#     the caller's next move is to hand the folder to the app.

@test "same_dir_path matches two paths that resolve to the same directory through a symlink" {
    local probe real link
    probe="$BATS_TEST_TMPDIR/probe.sh"
    write_probe "$probe"

    real="$BATS_TEST_TMPDIR/real-project"
    link="$BATS_TEST_TMPDIR/linked-project"
    mkdir -p "$real"
    ln -s "$real" "$link"

    run bash "$probe" same_dir_path "$link" "$real"
    [ "$status" -eq 0 ]

    # ... and does not match two directories that merely look alike.
    mkdir -p "$BATS_TEST_TMPDIR/other-project"
    run bash "$probe" same_dir_path "$BATS_TEST_TMPDIR/other-project" "$real"
    [ "$status" -ne 0 ]
}

@test "orca_data_json_lists_dir ignores a repo attached to a remote host at this very path" {
    local probe dir f
    probe="$BATS_TEST_TMPDIR/probe.sh"
    write_probe "$probe"

    dir="$(abspath "$PROJECT_DIR")"
    f="$BATS_TEST_TMPDIR/orca-data.json"

    # The container's own workspace, as the app stores it: same path,
    # executionHostId naming the environment this launcher registered.
    printf '{"repos":[{"id":"r1","path":"%s","executionHostId":"env-1"}]}\n' "$dir" > "$f"
    run bash "$probe" orca_data_json_lists_dir "$f" "$dir"
    [ "$status" -ne 0 ]

    # The same path with no executionHostId is the local project this is
    # all about, and that one IS listed.
    printf '{"repos":[{"id":"r1","path":"%s","executionHostId":"env-1"},{"id":"r2","path":"%s"}]}\n' \
        "$dir" "$dir" > "$f"
    run bash "$probe" orca_data_json_lists_dir "$f" "$dir"
    [ "$status" -eq 0 ]
}

@test "orca_strip_local_repo returns non-zero and says so when the rewrite leaves the folder listed" {
    local probe dir data fake real_jq
    probe="$BATS_TEST_TMPDIR/probe.sh"
    write_probe "$probe"

    dir="$(abspath "$PROJECT_DIR")"
    data="$BATS_TEST_TMPDIR/mac-orca-data"
    mkdir -p "$data"
    printf '{"repos":[{"path":"%s"}]}\n' "$dir" > "$data/orca-data.json"

    # A jq that reads fine but writes the file back unchanged -- standing
    # in for every way the rewrite can quietly not happen (a filter that
    # matched nothing, a failed rename, the app's own flush landing on top
    # of it). The strip must not report success for that.
    fake="$BATS_TEST_TMPDIR/fake-bin"
    mkdir -p "$fake"
    real_jq="$(command -v jq)"
    {
        echo '#!/usr/bin/env bash'
        echo 'for a in "$@"; do'
        echo '    case "$a" in'
        echo '        *".repos ="*)'
        echo '            for last in "$@"; do :; done'
        echo '            exec cat "$last" ;;'
        echo '    esac'
        echo 'done'
        printf 'exec %s "$@"\n' "$real_jq"
    } > "$fake/jq"
    chmod +x "$fake/jq"

    run env ORCA_USER_DATA_PATH="$data" PATH="$fake:$PATH" \
        bash "$probe" orca_strip_local_repo "$dir"
    [ "$status" -eq 1 ]
    grep -qF "still lists" <<< "$output"
    grep -qF "$data/orca-data.json" <<< "$output"

    # The real jq, same fixture: it lands, and says so with a 0.
    run env ORCA_USER_DATA_PATH="$data" bash "$probe" orca_strip_local_repo "$dir"
    [ "$status" -eq 0 ]
    [ "$(jq '.repos | length' "$data/orca-data.json")" = "0" ]
}
