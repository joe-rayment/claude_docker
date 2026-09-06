#!/usr/bin/env bats
#
# V2 acceptance contract (claude-orca-qt9.2) -- FROZEN from RED-AT onward.
# The Orca layer of the two-layer model (.claude/plans/orca-port.md §9):
# the generated Seatbelt profile (scripts/sandbox/gen-orca-profile.sh),
# the ONE host-owned deny list both profiles read
# (scripts/sandbox/host-owned-paths.sh), the host-side launcher
# (scripts/sandbox/orca-launch) and the double-clickable bundle that
# hangs off it (scripts/sandbox/make-launcher-app.sh).
#
# sandbox-exec cannot run here (this is Linux), so these cases assert the
# generated TEXTS and the process wiring: the profile's rule order, the
# srt settings the same list feeds, and what orca-launch execs -- with
# sandbox-exec, the Orca binary and the bundled `orca` CLI stubbed.

load helpers/setup

GEN_PROFILE() {
    "$REPO_ROOT/scripts/sandbox/gen-orca-profile.sh" "$@"
}

# 1-based line number of the first line containing $2 in file $1 (empty
# when absent -- every rule below is emitted exactly once, so "first" and
# "only" are the same line).
line_of() {
    grep -nF -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}

# Line number of the LAST `(allow ...)` rule: SBPL is last-match-wins, so
# "denied last" means "after this line".
last_allow_line() {
    grep -n '^(allow' "$1" | tail -1 | cut -d: -f1
}

# Polls up to ~15s for $1 to exist (and, with $2, to contain it).
wait_for() {
    local target="$1" needle="${2:-}" i=0
    while [ "$i" -lt 150 ]; do
        if [ -f "$target" ]; then
            if [ -z "$needle" ] || grep -qF -- "$needle" "$target"; then
                return 0
            fi
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

# A stand-in for the real Orca.app: the packaged layout this slice
# depends on -- Contents/MacOS/Orca (the app binary) and the bundled CLI
# at Contents/Resources/bin/orca (Orca's Casks/orca.rb installs exactly
# that path onto PATH; config/electron-builder.config.cjs ships
# resources/darwin/bin/orca to bin/orca).
make_fake_orca_app() {
    local app="$1"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin"
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Orca</string>
	<key>CFBundleIconFile</key>
	<string>icon.icns</string>
	<key>CFBundleIdentifier</key>
	<string>com.stablyai.orca</string>
</dict>
</plist>
PLIST
    printf 'icns-fixture-bytes\n' > "$app/Contents/Resources/icon.icns"
    cat > "$app/Contents/MacOS/Orca" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >> "$STUB_ARGV"
env > "$STUB_ENV"
exit 0
STUB
    chmod +x "$app/Contents/MacOS/Orca"
    cat > "$app/Contents/Resources/bin/orca" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CLAUDE_ORCA_ROOT/.claude-dev/state/orca-cli-stub.log"
printf '{"ok":true}\n'
exit 0
STUB
    chmod +x "$app/Contents/Resources/bin/orca"
}

# Stands in for /usr/bin/sandbox-exec: records argv and the whole env,
# then fakes the app coming up by writing Orca's runtime metadata file
# (orca-runtime.json, src/shared/runtime-bootstrap.ts:45) under the user
# data dir -- unless STUB_ORCA_METADATA=0, i.e. "the app never started".
write_stub_sandbox_exec() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >> "$STUB_ARGV"
env > "$STUB_ENV"
if [ "${STUB_ORCA_METADATA:-1}" = "1" ]; then
    mkdir -p "$ORCA_USER_DATA_PATH"
    printf '{"authToken":"t","transports":[{"kind":"unix","path":"s.sock"}]}\n' \
        > "$ORCA_USER_DATA_PATH/orca-runtime.json"
fi
exit 0
STUB
    chmod +x "$1"
}

# The v2 layout without the cost of a full bootstrap: everything the Orca
# layer touches lives under <project>/.claude-dev, and the template is
# reached the way an installed project reaches it (through .claude-dev),
# so paths.sh's template_dir/host_dir/project_dir resolve to the project.
make_v2_project() {
    local dir="$1"
    mkdir -p "$dir/.claude-dev/state" "$dir/.claude-dev/home" \
             "$dir/.claude-dev/tmp" "$dir/.claude-dev/bin"
    printf '%s\n' \
        '{"version":1,"network":{"extraAllowedDomains":[]},"filesystem":{"extraAllowWrite":[]},"orca":{"cli":false}}' \
        > "$dir/.claude-dev/sandbox.json"
    ln -sfn "$REPO_ROOT" "$dir/.claude-dev/template"
    ln -sfn "../template/scripts/sandbox/orca-launch" "$dir/.claude-dev/bin/orca-launch"
    make_fake_orca_app "$dir/.claude-dev/app/Orca.app"
    export STUB_ARGV="$BATS_TEST_TMPDIR/argv.txt"
    : > "$STUB_ARGV"
    write_stub_sandbox_exec "$BATS_TEST_TMPDIR/stubs/sandbox-exec"
}

@test "the generated profile is allow-default, denies reads and writes under /Users and /Volumes, then allows the project subpath, then denies writes to every host-owned path last" {
    make_v2_project "$PROJECT_DIR"
    p="$(abspath "$PROJECT_DIR")"
    rh="$(make_real_home)"

    run GEN_PROFILE --project "$p" --real-home "$rh"
    [ "$status" -eq 0 ]
    prof="$BATS_TEST_TMPDIR/orca.sb"
    printf '%s\n' "$output" > "$prof"

    [ "$(head -1 "$prof")" = "(version 1)" ]
    allow_default="$(line_of "$prof" '(allow default)')"
    [ -n "$allow_default" ]

    # The user's files are not the app's business -- reads and writes.
    deny_users_read="$(line_of "$prof" '(deny file-read* (subpath "/Users"))')"
    deny_users_write="$(line_of "$prof" '(deny file-write* (subpath "/Users"))')"
    deny_vol_read="$(line_of "$prof" '(deny file-read* (subpath "/Volumes"))')"
    deny_vol_write="$(line_of "$prof" '(deny file-write* (subpath "/Volumes"))')"
    for ln in "$deny_users_read" "$deny_users_write" "$deny_vol_read" "$deny_vol_write"; do
        [ -n "$ln" ]
        [ "$ln" -gt "$allow_default" ]
    done

    # Writes are denied everywhere; the folder and two islands come back.
    deny_all_write="$(line_of "$prof" '(deny file-write* (subpath "/"))')"
    [ -n "$deny_all_write" ]

    allow_read_p="$(line_of "$prof" "(allow file-read* (subpath \"$p\"))")"
    allow_write_p="$(line_of "$prof" "(allow file-write* (subpath \"$p\"))")"
    [ -n "$allow_read_p" ]
    [ -n "$allow_write_p" ]
    [ "$allow_read_p" -gt "$deny_users_read" ]
    [ "$allow_write_p" -gt "$deny_users_write" ]
    [ "$allow_write_p" -gt "$deny_all_write" ]

    # Reads the app needs outside the folder.
    for sub in "$p/.claude-dev/app/Orca.app" /private/var/folders /private/tmp /dev; do
        ln="$(line_of "$prof" "(allow file-read* (subpath \"$sub\"))")"
        [ -n "$ln" ]
    done
    # ... and the only two writable places outside it.
    for sub in /private/var/folders /dev; do
        ln="$(line_of "$prof" "(allow file-write* (subpath \"$sub\"))")"
        [ -n "$ln" ]
        [ "$ln" -gt "$deny_all_write" ]
    done
    # The real home is NOT writable, and not readable either.
    ! grep -qF "(allow file-write* (subpath \"$rh\"))" "$prof"

    # SBPL is last-match-wins: every host-owned path is denied after the
    # last allow, so nothing above can re-open one.
    last_allow="$(last_allow_line "$prof")"
    . "$REPO_ROOT/scripts/sandbox/host-owned-paths.sh"
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        ln="$(line_of "$prof" "(deny file-write* (subpath \"$entry\"))")"
        [ -n "$ln" ]
        [ "$ln" -gt "$last_allow" ]
    done < <(host_owned_paths "$p")
}

@test "the host-owned list is one function and gen-settings.sh denyWrite contains every entry of it" {
    lib="$REPO_ROOT/scripts/sandbox/host-owned-paths.sh"
    [ -f "$lib" ]
    # ONE function: one definition site in the file, and both generators
    # source it rather than keeping a list of their own.
    [ "$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$lib")" -eq 1 ]
    grep -qF 'host-owned-paths.sh' "$REPO_ROOT/scripts/sandbox/gen-settings.sh"
    grep -qF 'host-owned-paths.sh' "$REPO_ROOT/scripts/sandbox/gen-orca-profile.sh"

    make_v2_project "$PROJECT_DIR"
    p="$(abspath "$PROJECT_DIR")"
    rh="$(make_real_home)"

    . "$lib"
    entries="$(host_owned_paths "$p")"
    for want in "$p/claude-dev" "$p/Orca.app" "$p/.claude-dev/bin" \
                "$p/.claude-dev/template" "$p/.claude-dev/app" \
                "$p/.claude-dev/srt" "$p/.claude-dev/claude" \
                "$p/.claude-dev/state" "$p/.claude-dev/sandbox.json" \
                "$p/orca.yaml" "$p/.worktreeinclude" \
                "$p/.envrc" "$p/.beads/hooks"; do
        grep -qxF "$want" <<<"$entries"
    done
    # V2c (claude-orca-qt9.7): sandbox.json is validated data, never
    # executed -- but its orca.profileExceptions and extraAllowWrite
    # widen both layers at the next launch, so it is write-denied too.
    # Only .claude-dev/run stays writable from inside.
    ! grep -qxF "$p/.claude-dev/run" <<<"$entries"

    run "$REPO_ROOT/scripts/sandbox/gen-settings.sh" \
        --primary "$p" --worktree "$p" --real-home "$rh" \
        --host "$p/.claude-dev" --sandbox-json "$p/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]
    deny_write="$(jq -r '.filesystem.denyWrite[]' <<<"$output")"
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        grep -qxF "$entry" <<<"$deny_write"
    done <<<"$entries"
}

@test "profile exceptions from sandbox.json are validated as absolute paths and emitted in a marked block; invalid entries fail closed" {
    make_v2_project "$PROJECT_DIR"
    p="$(abspath "$PROJECT_DIR")"
    rh="$(make_real_home)"
    sj="$p/.claude-dev/sandbox.json"
    prof="$BATS_TEST_TMPDIR/orca.sb"

    # The documented fallback: if Electron's appData does not follow HOME,
    # Orca's real user-data dir is opened by hand -- and only that.
    jq --arg r "$rh/Library/Caches/orca" \
       --arg w "$rh/Library/Application Support/orca" \
       '.orca.profileExceptions = {allowRead: [$r], allowWrite: [$w]}' \
       "$sj" > "$sj.tmp"
    mv "$sj.tmp" "$sj"

    run GEN_PROFILE --project "$p" --real-home "$rh"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$prof"

    begin="$(line_of "$prof" 'BEGIN sandbox.json orca.profileExceptions')"
    end="$(line_of "$prof" 'END sandbox.json orca.profileExceptions')"
    [ -n "$begin" ]
    [ -n "$end" ]
    [ "$end" -gt "$begin" ]

    read_ln="$(line_of "$prof" "(allow file-read* (subpath \"$rh/Library/Caches/orca\"))")"
    write_ln="$(line_of "$prof" "(allow file-read* file-write* (subpath \"$rh/Library/Application Support/orca\"))")"
    for ln in "$read_ln" "$write_ln"; do
        [ -n "$ln" ]
        [ "$ln" -gt "$begin" ]
        [ "$ln" -lt "$end" ]
    done
    # An exception never re-opens a host-owned path: those are denied after.
    host_owned_ln="$(line_of "$prof" "(deny file-write* (subpath \"$p/.claude-dev/bin\"))")"
    [ -n "$host_owned_ln" ]
    [ "$host_owned_ln" -gt "$end" ]

    # Fail closed: relative path, traversal, wrong type -- no profile at all.
    for bad in '["Library/Application Support/orca"]' '["/Users/x/../../etc"]' '[{}]'; do
        jq --argjson b "$bad" '.orca.profileExceptions = {allowWrite: $b}' \
            "$sj" > "$sj.tmp"
        mv "$sj.tmp" "$sj"
        run GEN_PROFILE --project "$p" --real-home "$rh"
        [ "$status" -ne 0 ]
        ! grep -q '(allow' <<<"$output"
    done
}

@test "orca-launch exports HOME, TMPDIR, CLAUDE_ORCA_ROOT and ORCA_USER_DATA_PATH inside the folder and execs stubbed sandbox-exec with -f <profile> and the app binary" {
    make_v2_project "$PROJECT_DIR"
    p="$(abspath "$PROJECT_DIR")"
    # claude-orca-0h7: Orca's user data dir now hangs off a short per-project root (--user-data-dir), pinned inside the test tmpdir here so the real /tmp is never touched.
    export CLAUDE_ORCA_SHORT_ROOT="$BATS_TEST_TMPDIR/co-fixture"

    # Invoked exactly the way the launcher bundle invokes it: through the
    # project's own .claude-dev/bin symlink, no --project, no env override.
    cd "$p"
    run "$p/.claude-dev/bin/orca-launch"
    [ "$status" -eq 0 ]

    [ -f "$p/.claude-dev/state/orca.sb" ]
    grep -qF '(version 1)' "$p/.claude-dev/state/orca.sb"
    grep -qF "(allow file-write* (subpath \"$p\"))" "$p/.claude-dev/state/orca.sb"

    grep -qxF "HOME=$p/.claude-dev/home" "$STUB_ENV"
    grep -qxF "TMPDIR=$p/.claude-dev/tmp" "$STUB_ENV"
    grep -qxF "CLAUDE_ORCA_ROOT=$p" "$STUB_ENV"
    grep -qxF "ORCA_USER_DATA_PATH=$CLAUDE_ORCA_SHORT_ROOT/Library/Application Support/orca" "$STUB_ENV"
    [ -d "$p/.claude-dev/home" ]
    [ -d "$p/.claude-dev/tmp" ]

    [ "$(sed -n 1p "$STUB_ARGV")" = "-f" ]
    [ "$(sed -n 2p "$STUB_ARGV")" = "$p/.claude-dev/state/orca.sb" ]
    [ "$(sed -n 3p "$STUB_ARGV")" = "$p/.claude-dev/app/Orca.app/Contents/MacOS/Orca" ]

    # ... and it says where to look when the app misbehaves.
    [[ "$output" == *"$p/.claude-dev/state/orca-launch.log"* ]]
}

@test "orca-launch adds the project once via the bundled orca CLI after the runtime metadata appears (stubbed)" {
    make_v2_project "$PROJECT_DIR"
    p="$(abspath "$PROJECT_DIR")"
    cli_log="$p/.claude-dev/state/orca-cli-stub.log"
    launch_log="$p/.claude-dev/state/orca-launch.log"
    # claude-orca-0h7: the same short per-project root, pinned inside the test tmpdir.
    export CLAUDE_ORCA_SHORT_ROOT="$BATS_TEST_TMPDIR/co-fixture"

    # The app never comes up: no metadata, so no CLI call -- ever.
    STUB_ORCA_METADATA=0 CLAUDE_ORCA_METADATA_TIMEOUT=1 \
        run "$p/.claude-dev/bin/orca-launch" --project "$p"
    [ "$status" -eq 0 ]
    wait_for "$launch_log" "runtime metadata did not appear"
    [ ! -f "$cli_log" ]

    # The app comes up: the project is added, exactly once.
    : > "$launch_log"
    run "$p/.claude-dev/bin/orca-launch" --project "$p"
    [ "$status" -eq 0 ]
    wait_for "$cli_log" "repo add"
    [ "$(wc -l < "$cli_log")" -eq 1 ]
    grep -qF -- "repo add --path $p --json" "$cli_log"
}

@test "make-launcher-app writes a valid Info.plist (parsed with python3 plistlib), an executable Contents/MacOS/Orca that execs .claude-dev/bin/orca-launch, and copies the icon" {
    command -v python3 >/dev/null 2>&1
    proj="$BATS_TEST_TMPDIR/Demo.Project"
    make_v2_project "$proj"
    p="$(abspath "$proj")"

    run "$REPO_ROOT/scripts/sandbox/make-launcher-app.sh" --project "$p"
    [ "$status" -eq 0 ]

    plist="$p/Orca.app/Contents/Info.plist"
    [ -f "$plist" ]
    run python3 -c 'import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
for k in ("CFBundleName", "CFBundleIdentifier", "CFBundleExecutable", "CFBundleIconFile"):
    print(d[k])' "$plist"
    [ "$status" -eq 0 ]
    [ "$(sed -n 1p <<<"$output")" = "Orca (Demo.Project)" ]
    [ "$(sed -n 2p <<<"$output")" = "dev.onorca.sandboxed.demo-project" ]
    [ "$(sed -n 3p <<<"$output")" = "Orca" ]
    [ "$(sed -n 4p <<<"$output")" = "icon.icns" ]

    icon="$p/Orca.app/Contents/Resources/icon.icns"
    [ -f "$icon" ]
    grep -qF 'icns-fixture-bytes' "$icon"

    exe="$p/Orca.app/Contents/MacOS/Orca"
    [ -x "$exe" ]
    grep -qF '.claude-dev/bin/orca-launch' "$exe"

    # Double-clicked from Finder there is no PATH and no useful cwd: the
    # bundle finds its own project and execs the launcher from there.
    rm -f "$p/.claude-dev/bin/orca-launch"
    cat > "$p/.claude-dev/bin/orca-launch" <<'STUB'
#!/bin/bash
pwd > "$LAUNCH_CWD"
printf '%s\n' "$@" > "$LAUNCH_ARGV"
STUB
    chmod +x "$p/.claude-dev/bin/orca-launch"
    cd /
    run env PATH= LAUNCH_CWD="$BATS_TEST_TMPDIR/launch.cwd" \
        LAUNCH_ARGV="$BATS_TEST_TMPDIR/launch.argv" "$exe" --demo
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/launch.cwd")" = "$p" ]
    grep -qxF -- '--demo' "$BATS_TEST_TMPDIR/launch.argv"
}

@test "registration builds Orca.app and .gitignore ignores it" {
    make_project "$PROJECT_DIR"
    p="$(abspath "$PROJECT_DIR")"

    [ -f "$p/Orca.app/Contents/Info.plist" ]
    [ -x "$p/Orca.app/Contents/MacOS/Orca" ]
    grep -qF '.claude-dev/bin/orca-launch' "$p/Orca.app/Contents/MacOS/Orca"

    run git -C "$p" check-ignore -q Orca.app
    [ "$status" -eq 0 ]
    # ... and the template repo ignores its own launcher bundle too.
    grep -qxF '/Orca.app' "$REPO_ROOT/.gitignore"
}
