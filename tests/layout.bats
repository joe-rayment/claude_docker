#!/usr/bin/env bats
#
# V1 acceptance contract (claude-orca-qt9.1) -- FROZEN from RED-AT onward.
# The v2 per-folder layout: everything the bootstrap installs lives under
# <project>/.claude-dev (template, srt, Claude Code, Orca.app, bin/), the
# project root gets the ./claude-dev stub, the shell rc block is generic,
# and ~/.claude-orca is gone from both the filesystem and the source.
# Runs on Linux: brew/npm/gh/node/curl/hdiutil are all stubbed by
# helpers/setup.bash, so no network and no macOS tooling is required.
#
# See .claude/plans/orca-port.md S9.

load helpers/setup

ORCA_PIN="1.4.197"

# The single Claude Code pin, read from the installer rather than copied
# here: the contract is that ONE variable drives the npm install, the
# fabricated package.json and the in-folder binary.
claude_code_pin() {
    sed -n 's/^CLAUDE_CODE_VERSION="\([^"]*\)".*/\1/p' \
        "$REPO_ROOT/scripts/install-claude.sh" | head -1
}

# bin/<name> must point into the template clone -- absolute or relative.
assert_links_into_template() {
    local host="$1" name="$2" target
    [ -L "$host/bin/$name" ]
    target="$(readlink "$host/bin/$name")"
    case "$target" in
        "$host/template/"*|../template/*) return 0 ;;
        *) printf 'bin/%s does not point into the template: %s\n' "$name" "$target"
           return 1 ;;
    esac
}

@test "bootstrap installs template, srt, Claude Code and the Orca app under <project>/.claude-dev with the pinned versions (stubbed npm/curl/hdiutil)" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    local host pin
    host="$(abspath "$PROJECT_DIR")/.claude-dev"

    # The template clone, and the wrappers symlinked out of it.
    [ -d "$host/template/.git" ]
    [ -f "$host/template/bootstrap.sh" ]
    assert_links_into_template "$host" claude-dev
    assert_links_into_template "$host" claude-orca-shell
    assert_links_into_template "$host" claude-orca-root
    assert_links_into_template "$host" orca-launch
    [ -x "$host/bin/claude-dev" ]
    [ -x "$host/bin/claude-orca-shell" ]

    # srt, pinned, installed by prefix into the folder.
    run cat "$host/srt/node_modules/@anthropic-ai/sandbox-runtime/package.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"version":"0.0.75"'* ]]
    grep -qF -- "--prefix $host/srt install" "$STUB_LOG"
    grep -qF "sandbox-runtime@0.0.75" "$STUB_LOG"

    # Claude Code, pinned by a single CLAUDE_CODE_VERSION, in the folder.
    pin="$(claude_code_pin)"
    [ -n "$pin" ]
    [[ "$pin" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
    grep -qF -- "--prefix $host/claude install" "$STUB_LOG"
    grep -qF "@anthropic-ai/claude-code@$pin" "$STUB_LOG"
    grep -qF "\"version\":\"$pin\"" \
        "$host/claude/node_modules/@anthropic-ai/claude-code/package.json"
    [ -x "$host/bin/claude" ]

    # Orca, from the pinned GitHub release DMG for this arch.
    grep -qF "releases/download/v$ORCA_PIN/orca-macos-" "$STUB_LOG"
    grep -q '^hdiutil attach' "$STUB_LOG"
    grep -q '^hdiutil detach' "$STUB_LOG"
    [ -f "$host/app/Orca.app/Contents/Info.plist" ]
    grep -qF "$ORCA_PIN" "$host/app/Orca.app/Contents/Info.plist"
    [ -s "$host/state/orca.sha256" ]
}

@test "nothing is written under ~/.claude-orca and no script or config references it (grep gate)" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [ ! -e "$HOME/.claude-orca" ]

    # One file may still name the v1 host root: the leftover check that
    # offers to remove it.
    local leftovers hits
    leftovers="$REPO_ROOT/scripts/v1-leftovers.sh"
    [ -f "$leftovers" ]
    grep -qF '.claude-orca' "$leftovers"

    run grep -rnE '(\$HOME|~)/\.claude-orca|CLAUDE_ORCA_HOME' \
        "$REPO_ROOT/bootstrap.sh" "$REPO_ROOT/scripts" "$REPO_ROOT/config"
    hits="$(printf '%s\n' "$output" | grep -v "^$leftovers:" || true)"
    [ -z "$hits" ]
}

@test "the project root gets an executable ./claude-dev stub that execs .claude-dev/bin/claude-dev" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    local stub="$PROJECT_DIR/claude-dev"
    [ -f "$stub" ]
    [ ! -L "$stub" ]
    [ -x "$stub" ]
    grep -qF '.claude-dev/bin/claude-dev' "$stub"
    grep -q '^exec ' "$stub"

    run "$stub" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-dev"* ]]
    [[ "$output" == *"--teardown"* ]]

    # ... and it is generated, never committed.
    grep -qxF '/claude-dev' "$PROJECT_DIR/.gitignore"
    grep -qxF 'Orca.app/' "$PROJECT_DIR/.gitignore"
}

@test "the rc marker block is generic: it finds .claude-dev/bin/claude-orca-shell by walking up from a subdirectory and execs it, and is a no-op outside a bootstrapped folder" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    local primary sub outside block
    primary="$(abspath "$PROJECT_DIR")"
    sub="$primary/deep/nested"
    mkdir -p "$sub"
    outside="$BATS_TEST_TMPDIR/not-a-project"
    mkdir -p "$outside"

    # The block as actually installed in the user's rc file.
    block="$BATS_TEST_TMPDIR/block.bash"
    sed -n '/# >>> claude_orca >>>/,/# <<< claude_orca <<</p' \
        "$HOME/.bash_profile" > "$block"
    [ -s "$block" ]

    # Generic: the walk-up target is in the block, and no install path
    # from this machine -- central or per-folder -- is baked into it.
    grep -qF '.claude-dev/bin/claude-orca-shell' "$block"
    ! grep -qF "$primary" "$block"
    ! grep -qE '/(claude-orca-home|\.claude-orca)/' "$block"

    # Inside a subdirectory: walks up, finds the in-folder wrapper, execs
    # it (so the trailing echo never runs) and lands in srt.
    export STUB_SRT_NOEXEC=1
    : > "$STUB_LOG"
    run bash -c "cd '$sub' && unset CLAUDE_ORCA_SANDBOXED && . '$block' && echo NOT_REACHED"
    [ "$status" -eq 0 ]
    [[ "$output" != *"NOT_REACHED"* ]]
    [[ "$output" != *"REFUSING"* ]]
    grep -qF '=== srt invocation ===' "$STUB_LOG"
    # V2d (claude-orca-qt9.9): the settings file srt is handed lives in a
    # private per-launch directory outside the folder, never under the
    # folder's own host-owned tree.
    layout_settings="$(grep -A1 -Fx -- '--settings' "$STUB_LOG" | sed -n 2p)"
    [ -f "$layout_settings" ]
    [ "${layout_settings#$primary/}" = "$layout_settings" ]

    # Outside a bootstrapped folder: a no-op, nothing exec'd.
    : > "$STUB_LOG"
    run bash -c "cd '$outside' && unset CLAUDE_ORCA_SANDBOXED && . '$block' && echo REACHED_END"
    unset STUB_SRT_NOEXEC
    [ "$status" -eq 0 ]
    [[ "$output" == *"REACHED_END"* ]]
    [[ "$output" != *"REFUSING"* ]]
    ! grep -qF '=== srt invocation ===' "$STUB_LOG"
}

@test "the in-folder claude binary precedes any other claude on the sandbox PATH printed by claude-orca-shell --print-env" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    local primary real_home path_value first d
    primary="$(abspath "$PROJECT_DIR")"

    # A decoy `claude` in a directory the sandbox PATH also carries.
    real_home="$(abspath "$(make_real_home)")"
    printf '#!/bin/sh\necho decoy\n' > "$real_home/.local/bin/claude"
    chmod +x "$real_home/.local/bin/claude"

    export CLAUDE_ORCA_REAL_HOME="$real_home"
    run "$primary/.claude-dev/bin/claude-orca-shell" \
        --print-env --root "$primary" --cwd "$primary"
    unset CLAUDE_ORCA_REAL_HOME
    [ "$status" -eq 0 ]

    path_value="$(grep '^PATH=' <<<"$output" | head -1)"
    path_value="${path_value#PATH=}"
    [ -n "$path_value" ]
    [ -x "$real_home/.local/bin/claude" ]

    first=""
    while IFS= read -r d; do
        if [ -n "$d" ] && [ -x "$d/claude" ]; then
            first="$d"
            break
        fi
    done < <(printf '%s\n' "$path_value" | tr ':' '\n')

    [ "$first" = "$primary/.claude-dev/bin" ]
}

@test "CLAUDE_ORCA_SKIP_ORCA_DMG and CLAUDE_ORCA_SKIP_CLAUDE skip only their step and doctor reports those rows as missing" {
    local host host2 project2

    # (a) skip the DMG: Claude Code still lands in the folder.
    export CLAUDE_ORCA_SKIP_ORCA_DMG=1
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    host="$(abspath "$PROJECT_DIR")/.claude-dev"
    [ ! -e "$host/app/Orca.app" ]
    ! grep -q 'releases/download' "$STUB_LOG"
    [ -x "$host/bin/claude" ]

    run "$host/bin/claude-dev" --doctor
    [[ "$output" =~ \[ok\][[:space:]]+claude\ \(in-folder\) ]]
    [[ "$output" =~ \[missing\][[:space:]]+orca\ app ]]
    unset CLAUDE_ORCA_SKIP_ORCA_DMG

    # (b) skip Claude Code: the Orca app still installs.
    export CLAUDE_ORCA_SKIP_CLAUDE=1
    project2="$BATS_TEST_TMPDIR/project2"
    mkdir -p "$project2"
    : > "$STUB_LOG"
    run bash "$REPO_ROOT/bootstrap.sh" "$project2"
    [ "$status" -eq 0 ]
    host2="$(abspath "$project2")/.claude-dev"
    [ ! -e "$host2/bin/claude" ]
    ! grep -q 'claude-code@' "$STUB_LOG"
    [ -f "$host2/app/Orca.app/Contents/Info.plist" ]

    run "$host2/bin/claude-dev" --doctor
    [[ "$output" =~ \[missing\][[:space:]]+claude\ \(in-folder\) ]]
    [[ "$output" =~ \[ok\][[:space:]]+orca\ app ]]
    unset CLAUDE_ORCA_SKIP_CLAUDE
}

@test "second bootstrap run is a no-op (tree checksum unchanged)" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    local sum1 sum2
    [ -d "$PROJECT_DIR/.claude-dev/template/.git" ]
    [ -f "$PROJECT_DIR/claude-dev" ]
    sum1="$(tree_checksum "$PROJECT_DIR")"

    : > "$STUB_LOG"
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    sum2="$(tree_checksum "$PROJECT_DIR")"
    [ "$sum1" = "$sum2" ]

    # Nothing re-downloaded or re-installed on the second pass.
    ! grep -q 'releases/download' "$STUB_LOG"
    ! grep -q 'claude-code@' "$STUB_LOG"
    ! grep -q 'sandbox-runtime@' "$STUB_LOG"
}
