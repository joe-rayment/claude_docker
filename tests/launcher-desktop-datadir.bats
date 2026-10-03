#!/usr/bin/env bats
#
# Follow-up hardening for claude-orca-tgr (verifier review): a way the
# desktop hand-off could guess wrong that the first pass did not cover.
# (Its sibling case, orca_quit_app()'s watchdog, went with the quit
# itself on 2026-09-13 -- the launcher never quits Orca now.)
#
#   * orca_user_data_dir() silently guessed between two Library paths.
#     It now discovers the real one from the running app's own open files
#     (`lsof -p <pid> -Fn`, `.result.app.pid` from `status --json`) and
#     caches it under .claude-dev/state/, ahead of the two guesses.
#
# These are exercised directly against the real function bodies -- none of
# them needs the CLI dispatch at the bottom of scripts/launcher.sh running, so
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
        sed -n '/^orca_data_json_file()/,/^}/p' "$LAUNCHER_SH"
        sed -n '/^orca_user_data_dir()/,/^}/p' "$LAUNCHER_SH"
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

# --- what the strip removes, and how it knows it landed ------------------
#
# Three facts the hand-off's whole control flow now rests on, each read
# straight off the function that produces it:
#
#   * the Mac's own paths can be symlinks (/Users/joe/code -> /Volumes/...),
#     so string equality alone answers "is this my folder?" wrong;
#   * a repo attached to a REMOTE host lives in the same .repos array as a
#     local one, told apart only by executionHostId -- and the container's
#     own workspace is one of those, so counting it as a local leak is
#     reporting this folder's own sandbox as the thing to remove;
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

# --- the store is the profile's, and SQLite-era profiles are untouchable --
#
# Since Orca grew profiles (verified 1.4.197, still so on 1.4.218), its
# local project list lives at <udd>/profiles/<activeProfileId>/orca-data.json;
# the root <udd>/orca-data.json is only the pre-profiles legacy copy Orca
# copies forward once and never reads again -- so a reader (or worse, a
# rewriter) aimed at the root edits a file the app has abandoned: the strip
# "succeeds", the app still lists the folder. And since 1.4.219 the profile
# keeps its state in profiles/<id>/profile-state.db and treats its
# orca-data.json as an export, where ANY byte change makes the next start
# refuse ("cannot safely choose a profile-state authority") -- a rewrite
# there would brick the user's desktop Orca.

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# Guards: orca_data_json_file() reads the ACTIVE profile's orca-data.json
# (activeProfileId from orca-profile-index.json) and only falls back to the
# root file when the profile has none -- the one resolution every reader of
# the local project list shares, so a pre-profiles Orca and a profiled one
# both get the store the app actually holds.
# Fails if: the helper ever answers the root file while the profile's own
# orca-data.json exists, or names a profile the index does not point at.
# Run: bats -f 'orca_data_json_file reads the active profile' tests/launcher-desktop-datadir.bats
@test "orca_data_json_file reads the active profile's orca-data.json, root only as a fallback" {
    local probe data f
    probe="$BATS_TEST_TMPDIR/probe.sh"
    write_probe "$probe"

    data="$BATS_TEST_TMPDIR/mac-orca-data"
    mkdir -p "$data/profiles/p2"

    # Pre-profiles Orca: no index, no profiles/ -- the root file is the
    # store, and the helper must say so rather than invent a profile path.
    run bash "$probe" orca_data_json_file "$data"
    [ "$status" -eq 0 ]
    [ "$output" = "$data/orca-data.json" ]

    # A profiled Orca: the index names the active profile.
    printf '{"activeProfileId":"p2"}\n' > "$data/orca-profile-index.json"
    f="$data/profiles/p2/orca-data.json"
    printf '{"repos":[]}\n' > "$f"
    run bash "$probe" orca_data_json_file "$data"
    [ "$status" -eq 0 ]
    [ "$output" = "$f" ]

    # The default profile id, when the index itself has no activeProfileId
    # at all (or is unreadable).
    printf '{"other":true}\n' > "$data/orca-profile-index.json"
    mkdir -p "$data/profiles/local-default"
    printf '{"repos":[]}\n' > "$data/profiles/local-default/orca-data.json"
    run bash "$probe" orca_data_json_file "$data"
    [ "$status" -eq 0 ]
    [ "$output" = "$data/profiles/local-default/orca-data.json" ]

    # No profile file after all (index names one that was never created --
    # or a pre-profiles Orca again): the root legacy file is the store.
    rm -rf "$data/profiles/local-default" "$data/profiles/p2"
    printf '{"repos":[]}\n' > "$data/orca-data.json"
    run bash "$probe" orca_data_json_file "$data"
    [ "$status" -eq 0 ]
    [ "$output" = "$data/orca-data.json" ]
}

# Guards: the case a SQLite-era Orca (1.4.219+) actually hits -- the strip
# must return non-zero, print the SQLite line, and leave BOTH files
# byte-identical: the profile's orca-data.json is only its export, and
# editing it makes the user's next Orca start refuse outright.
# Fails if: the strip rewrites the profile file (or the stale root legacy
# file sitting beside it), or goes quiet about refusing.
# Run: bats -f 'refuses to edit a SQLite-era profile' tests/launcher-desktop-datadir.bats
@test "orca_strip_local_repo refuses to edit a SQLite-era profile and says so" {
    local probe dir data f root sha_f sha_root
    probe="$BATS_TEST_TMPDIR/probe.sh"
    write_probe "$probe"

    dir="$(abspath "$PROJECT_DIR")"
    data="$BATS_TEST_TMPDIR/mac-orca-profile"
    mkdir -p "$data/profiles/p2"
    printf '{"activeProfileId":"p2"}\n' > "$data/orca-profile-index.json"
    f="$data/profiles/p2/orca-data.json"
    root="$data/orca-data.json"
    printf '{"repos":[{"id":"r1","path":"%s"},{"id":"r9","path":"/Users/joe/profile-only"}]}\n' \
        "$dir" > "$f"
    printf '{"repos":[{"id":"r2","path":"%s"},{"id":"r8","path":"/Users/joe/root-only"}]}\n' \
        "$dir" > "$root"
    : > "$data/profiles/p2/profile-state.db"
    sha_f="$(sha_of "$f")"
    sha_root="$(sha_of "$root")"

    run env ORCA_USER_DATA_PATH="$data" bash "$probe" orca_strip_local_repo "$dir"
    [ "$status" -eq 1 ]
    grep -qF "Orca keeps this profile in SQLite; the launcher will not edit it" <<< "$output"

    # Not one byte moved, in either file: the profile export is frozen and
    # the stale root copy is not the store this Mac's Orca reads.
    [ "$(sha_of "$f")" = "$sha_f" ]
    [ "$(sha_of "$root")" = "$sha_root" ]
}

# Guards: without the SQLite db the profile's orca-data.json is a plain
# store the launcher may rewrite -- this folder's entry goes, removed repo
# ids come out of .projects[].sourceRepoIds, a project left referencing
# nothing goes with them, and the stale root legacy file stays untouched.
# Fails if: the strip edits the root file instead of the profile's, leaves
# a dangling sourceRepoId behind, drops a project that still references
# kept repos, or clobbers unrelated top-level keys.
# Run: bats -f 'strips the active profile' tests/launcher-desktop-datadir.bats
@test "orca_strip_local_repo strips the active profile's orca-data.json when no SQLite db exists" {
    local probe dir data f root sha_root
    probe="$BATS_TEST_TMPDIR/probe.sh"
    write_probe "$probe"

    dir="$(abspath "$PROJECT_DIR")"
    data="$BATS_TEST_TMPDIR/mac-orca-profile"
    mkdir -p "$data/profiles/p2"
    printf '{"activeProfileId":"p2"}\n' > "$data/orca-profile-index.json"
    f="$data/profiles/p2/orca-data.json"
    root="$data/orca-data.json"
    printf '{
        "repos":[{"id":"r1","path":"%s"},{"id":"r2","path":"/Users/joe/some-other-project"}],
        "projects":[{"id":"proj1","name":"Mine","sourceRepoIds":["r1"]},
                    {"id":"proj2","name":"Kept","sourceRepoIds":["r1","r2"]}],
        "windowState":{"x":100}
    }\n' "$dir" > "$f"
    printf '{"repos":[{"id":"r5","path":"%s"},{"id":"r6","path":"/Users/joe/legacy-only"}]}\n' \
        "$dir" > "$root"
    sha_root="$(sha_of "$root")"

    run env ORCA_USER_DATA_PATH="$data" bash "$probe" orca_strip_local_repo "$dir"
    [ "$status" -eq 0 ]

    # The profile file: this folder's repo is gone, everything else stays.
    [ "$(jq -c '[.repos[].id]' "$f")" = '["r2"]' ]
    # The removed repo's id is out of every project's sourceRepoIds, and a
    # project left referencing nothing is gone with it.
    [ "$(jq -c '[.projects[].id]' "$f")" = '["proj2"]' ]
    [ "$(jq -c '[.projects[].sourceRepoIds[]]' "$f")" = '["r2"]' ]
    [ "$(jq '.windowState.x' "$f")" = "100" ]

    # The stale root copy beside it: byte-identical.
    [ "$(sha_of "$root")" = "$sha_root" ]
}

# Guards: a Mac whose Orca predates profiles has only the root
# orca-data.json -- the strip must still land there, removing only this
# folder and leaving the user's other repos and keys intact.
# Fails if: the profile fallback ever misses the root store, or the
# rewrite stops preserving unrelated repos and keys.
# Run: bats -f 'strips a pre-profiles root' tests/launcher-desktop-datadir.bats
@test "orca_strip_local_repo strips a pre-profiles root orca-data.json" {
    local probe dir data f
    probe="$BATS_TEST_TMPDIR/probe.sh"
    write_probe "$probe"

    dir="$(abspath "$PROJECT_DIR")"
    data="$BATS_TEST_TMPDIR/mac-orca-legacy"
    mkdir -p "$data"
    f="$data/orca-data.json"
    printf '{"repos":[{"path":"%s"},{"path":"/Users/joe/some-other-project"}],"windowState":{"x":100}}\n' \
        "$dir" > "$f"

    run env ORCA_USER_DATA_PATH="$data" bash "$probe" orca_strip_local_repo "$dir"
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.repos[].path]' "$f")" = '["/Users/joe/some-other-project"]' ]
    [ "$(jq '.windowState.x' "$f")" = "100" ]
}

# Guards: a repo attached to a remote host lives in the same .repos array,
# and the project that references it must survive a strip of a local repo
# -- neither the repo nor its sourceRepoId is the launcher's to remove.
# Fails if: the rewrite ever removes a remote-host entry, its id out of
# .projects[].sourceRepoIds, or the project referencing it.
# Run: bats -f 'leaves a remote-host repo' tests/launcher-desktop-datadir.bats
@test "orca_strip_local_repo leaves a remote-host repo and its project references alone" {
    local probe dir data f
    probe="$BATS_TEST_TMPDIR/probe.sh"
    write_probe "$probe"

    dir="$(abspath "$PROJECT_DIR")"
    data="$BATS_TEST_TMPDIR/mac-orca-remote"
    mkdir -p "$data/profiles/p2"
    printf '{"activeProfileId":"p2"}\n' > "$data/orca-profile-index.json"
    f="$data/profiles/p2/orca-data.json"
    printf '{
        "repos":[{"id":"r1","path":"%s"},
                 {"id":"r2","path":"/Users/joe/some-other-project"},
                 {"id":"r3","path":"/Volumes/x/remote-project","executionHostId":"runtime:remote-1"}],
        "projects":[{"id":"projA","name":"Mixed","sourceRepoIds":["r1","r3"]},
                    {"id":"projB","name":"Remote only","sourceRepoIds":["r3"]}]
    }\n' "$dir" > "$f"

    run env ORCA_USER_DATA_PATH="$data" bash "$probe" orca_strip_local_repo "$dir"
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.repos[].id]' "$f")" = '["r2","r3"]' ]
    [ "$(jq -r '.repos[] | select(.id == "r3") | .executionHostId' "$f")" = "runtime:remote-1" ]
    [ "$(jq -c '[.projects[] | select(.id == "projA") | .sourceRepoIds[]]' "$f")" = '["r3"]' ]
    [ "$(jq -c '[.projects[] | select(.id == "projB") | .sourceRepoIds[]]' "$f")" = '["r3"]' ]
}

# Guards: orca_user_data_dir()'s lsof discovery -- the open file it sees
# can be the active profile's orca-data.json, whose dirname is
# profiles/<id>; the user data dir it must answer and cache is that
# directory's grandparent.
# Fails if: discovery answers (or caches) the profiles/<id> directory
# itself, pointing every later reader one level too deep.
# Run: bats -f 'lsof hit inside profiles' tests/launcher-desktop-datadir.bats
@test "orca_user_data_dir maps an lsof hit inside profiles/ back to the user data dir" {
    local dir cli probe lsofdir data
    dir="$(abspath "$PROJECT_DIR")"
    cli="$CLAUDE_ORCA_APP/Contents/Resources/bin/orca"
    write_stub_orca "$cli"
    export ORCA_STUB_APP_RUNNING=true
    data="$BATS_TEST_TMPDIR/mac-orca-data"
    mkdir -p "$data/profiles/p2"
    # The stub names <dir>/orca-environments.json under ORCA_STUB_LSOF_DIR;
    # pointing that directory at the profile is exactly what a real 1.4.x
    # app's open orca-data.json looks like to the reader.
    lsofdir="$data/profiles/p2"
    export ORCA_STUB_LSOF_DIR="$lsofdir"

    probe="$BATS_TEST_TMPDIR/probe.sh"
    write_probe "$probe"

    run bash "$probe" orca_user_data_dir "$dir" "$cli"
    [ "$status" -eq 0 ]
    [ "$output" = "$data" ]

    # ... and the cache under state/ holds the grandparent too, since it
    # is the answer every later no-pid run will read.
    [ "$(cat "$dir/.claude-dev/state/orca-data-dir")" = "$data" ]
}
