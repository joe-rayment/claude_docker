#!/usr/bin/env bats
#
# Acceptance contract for claude-orca-0h7 -- FROZEN from RED-AT onward.
#
# What broke on the user's Mac: packaged Orca never calls
# app.setPath('userData'), Electron's appData on macOS comes from
# NSSearchPath (which ignores $HOME), and Orca's own kei() overwrites
# ORCA_USER_DATA_PATH with app.getPath('userData') -- so the app wrote to
# the REAL ~/Library/Application Support/orca, which the Seatbelt profile
# denies, and died on the singleton lock. The fix is the one thing
# Electron honours natively: --user-data-dir, pointed at a SHORT
# per-project root (macOS's sockaddr_un is 104 bytes, and the folder's own
# path plus the socket name overruns it).
#
# sandbox-exec cannot run here (this is Linux), so these cases assert the
# process wiring -- the symlink, the env and the argv -- with sandbox-exec
# and the Orca binary stubbed, and CLAUDE_ORCA_SHORT_ROOT pointed inside
# $BATS_TEST_TMPDIR so nothing here ever touches the real /tmp.

load helpers/setup

# A stand-in for the real Orca.app: Contents/MacOS/Orca (the app binary)
# and the bundled CLI at Contents/Resources/bin/orca, the two paths
# orca-launch reaches into.
make_fake_orca_app() {
    local app="$1"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin"
    cat > "$app/Contents/MacOS/Orca" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >> "$STUB_ARGV"
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

# Stands in for /usr/bin/sandbox-exec: records argv one element per line
# and the whole env, then fakes the app coming up by writing Orca's
# runtime metadata under the user data dir it was handed.
write_stub_sandbox_exec() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >> "$STUB_ARGV"
env > "$STUB_ENV"
mkdir -p "$ORCA_USER_DATA_PATH"
printf '{"authToken":"t","transports":[{"kind":"unix","path":"s.sock"}]}\n' \
    > "$ORCA_USER_DATA_PATH/orca-runtime.json"
exit 0
STUB
    chmod +x "$1"
}

# The per-folder layout the Orca layer needs, without the cost of a full
# bootstrap; the launcher is reached through .claude-dev/bin the way the
# Orca.app bundle reaches it, so paths.sh resolves the project itself.
# $BATS_TEST_TMPDIR/stubs is already first on PATH (helpers/setup), so the
# sandbox-exec stub written there is the one `command -v` finds.
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

@test "orca-launch passes --user-data-dir under a short per-project symlink root and exports ORCA_USER_DATA_PATH to the same path" {
    make_v2_project "$PROJECT_DIR"
    p="$(abspath "$PROJECT_DIR")"
    short="$BATS_TEST_TMPDIR/co-fixture"
    want="$short/Library/Application Support/orca"

    cd "$p"
    run env CLAUDE_ORCA_SHORT_ROOT="$short" "$p/.claude-dev/bin/orca-launch"
    [ "$status" -eq 0 ]

    # The env Orca's CLI reads and the switch Electron reads agree.
    grep -qxF "ORCA_USER_DATA_PATH=$want" "$STUB_ENV"
    [ "$(sed -n 1p "$STUB_ARGV")" = "-f" ]
    [ "$(sed -n 2p "$STUB_ARGV")" = "$p/.claude-dev/state/orca.sb" ]
    [ "$(sed -n 3p "$STUB_ARGV")" = "$p/.claude-dev/app/Orca.app/Contents/MacOS/Orca" ]
    [ "$(sed -n 4p "$STUB_ARGV")" = "--user-data-dir=$want" ]

    # HOME and TMPDIR still point into the folder itself.
    grep -qxF "HOME=$p/.claude-dev/home" "$STUB_ENV"
    grep -qxF "TMPDIR=$p/.claude-dev/tmp" "$STUB_ENV"

    # ... and the short path IS the folder's data dir, through the symlink.
    [ -d "$p/.claude-dev/home/Library/Application Support/orca" ]
    [ "$(cd "$want" && pwd -P)" \
      = "$(cd "$p/.claude-dev/home/Library/Application Support/orca" && pwd -P)" ]

    # Anything Finder or a human passes comes AFTER the switch.
    : > "$STUB_ARGV"
    run env CLAUDE_ORCA_SHORT_ROOT="$short" "$p/.claude-dev/bin/orca-launch" --enable-logging
    [ "$status" -eq 0 ]
    [ "$(sed -n 4p "$STUB_ARGV")" = "--user-data-dir=$want" ]
    [ "$(sed -n 5p "$STUB_ARGV")" = "--enable-logging" ]
}

@test "orca-launch creates the short symlink to .claude-dev/home and refuses when the path exists and is not that symlink" {
    make_v2_project "$PROJECT_DIR"
    p="$(abspath "$PROJECT_DIR")"
    short="$BATS_TEST_TMPDIR/co-fixture"
    cd "$p"

    # (a) created fresh, pointing at this folder's home
    run env CLAUDE_ORCA_SHORT_ROOT="$short" "$p/.claude-dev/bin/orca-launch"
    [ "$status" -eq 0 ]
    [ -L "$short" ]
    [ "$(readlink "$short")" = "$p/.claude-dev/home" ]

    # (b) already ours: kept
    run env CLAUDE_ORCA_SHORT_ROOT="$short" "$p/.claude-dev/bin/orca-launch"
    [ "$status" -eq 0 ]
    [ -L "$short" ]
    [ "$(readlink "$short")" = "$p/.claude-dev/home" ]

    # (c) a symlink pointing somewhere else (another project had the root,
    # or someone re-pointed it): replaced, never followed.
    elsewhere="$BATS_TEST_TMPDIR/elsewhere"
    mkdir -p "$elsewhere"
    rm -f "$short"
    ln -s "$elsewhere" "$short"
    run env CLAUDE_ORCA_SHORT_ROOT="$short" "$p/.claude-dev/bin/orca-launch"
    [ "$status" -eq 0 ]
    [ "$(readlink "$short")" = "$p/.claude-dev/home" ]

    # (d) a real directory in the way: refuse (exit 2), launch nothing.
    # /tmp is sticky and world-writable, so an entry we did not make is
    # never trusted and never removed.
    other="$BATS_TEST_TMPDIR/co-real-dir"
    mkdir -p "$other"
    : > "$STUB_ARGV"
    run env CLAUDE_ORCA_SHORT_ROOT="$other" "$p/.claude-dev/bin/orca-launch"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refusing"* ]]
    [[ "$output" == *"$other"* ]]
    [ ! -s "$STUB_ARGV" ]
    [ -d "$other" ]
    [ ! -L "$other" ]
}

@test "orca-launch --print-command prints the env and sandbox-exec command line without launching, and refuses when the socket path would still exceed 100 bytes" {
    make_v2_project "$PROJECT_DIR"
    p="$(abspath "$PROJECT_DIR")"
    short="$BATS_TEST_TMPDIR/co-fixture"
    want="$short/Library/Application Support/orca"

    # No sandbox-exec on PATH at all: --print-command still prints, and
    # generates no profile, no symlink, no launch.
    rm -f "$BATS_TEST_TMPDIR/stubs/sandbox-exec"
    rm -f "$p/.claude-dev/state/orca.sb"
    : > "$STUB_ARGV"
    cd "$p"
    run env CLAUDE_ORCA_SHORT_ROOT="$short" "$p/.claude-dev/bin/orca-launch" --print-command
    [ "$status" -eq 0 ]
    [ ! -e "$short" ]
    [ ! -e "$p/.claude-dev/state/orca.sb" ]
    [ ! -s "$STUB_ARGV" ]

    grep -qxF "HOME=$p/.claude-dev/home" <<<"$output"
    grep -qxF "TMPDIR=$p/.claude-dev/tmp" <<<"$output"
    grep -qxF "CLAUDE_ORCA_ROOT=$p" <<<"$output"
    grep -qxF "CLAUDE_ORCA_REAL_HOME=$HOME" <<<"$output"
    grep -qxF "CLAUDE_ORCA_LAYER=orca" <<<"$output"
    grep -qxF "ORCA_USER_DATA_PATH=$want" <<<"$output"

    cmd="$(grep '^sandbox-exec ' <<<"$output")"
    [ "$cmd" = "sandbox-exec -f $p/.claude-dev/state/orca.sb $p/.claude-dev/app/Orca.app/Contents/MacOS/Orca '--user-data-dir=$want'" ]

    # --print-env stops at the exports.
    run env CLAUDE_ORCA_SHORT_ROOT="$short" "$p/.claude-dev/bin/orca-launch" --print-env
    [ "$status" -eq 0 ]
    grep -qxF "ORCA_USER_DATA_PATH=$want" <<<"$output"
    ! grep -q 'sandbox-exec' <<<"$output"

    # A root long enough that <user data dir>/o-<n>.sock would overrun
    # macOS's 104-byte sockaddr_un: refuse in every mode, exit 2.
    long="$BATS_TEST_TMPDIR/$(printf '%090d' 0)"
    run env CLAUDE_ORCA_SHORT_ROOT="$long" "$p/.claude-dev/bin/orca-launch" --print-command
    [ "$status" -eq 2 ]
    [[ "$output" == *"104"* ]]
    [[ "$output" == *"$long/Library/Application Support/orca"* ]]
    [ ! -e "$long" ]
}
