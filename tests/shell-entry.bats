#!/usr/bin/env bats
#
# S2b acceptance contract (claude-orca-3sk.24) -- FROZEN from RED-AT onward.
# Closes three findings from S2's verification: (1) every script under
# scripts/ must run under bash 3.2 (macOS /bin/bash) -- no unguarded
# empty-array expansion, associative arrays, mapfile/readarray, or
# ${var,,}/${var^^}; (2) a non-interactive login shell (`zsh -l -c …`,
# `bash -l -c …`) opened inside a bootstrapped folder must still be
# re-exec'd through claude-orca-shell, with the -c command preserved via
# $ZSH_EXECUTION_STRING/$BASH_EXECUTION_STRING; (3) `claude-dev rc-install`
# must cover ~/.zprofile, ~/.zshrc and ~/.bash_profile (rc-uninstall all
# three), always appended after existing content, idempotently. See
# .claude/plans/orca-port.md S3.2 and tests/sandbox-config.bats (S2, still
# green, unfrozen) for the wrapper's baseline behaviour.
#
# A real GNU bash 3.2 (never the host's bash >= 4, which lacks the bug this
# bead exists to fix) is required for cases 1-3 -- see helpers/ensure_bash32.

load helpers/setup

require_bash32() {
    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/helpers/ensure_bash32"
}

@test "gen-settings.sh emits identical JSON under bash 3.2 and the host bash, with empty and non-empty extras" {
    require_bash32
    make_project "$PROJECT_DIR"
    real_home="$(make_real_home)"
    primary="$(abspath "$PROJECT_DIR")"
    gen_settings="$ORCA_HOST/template/scripts/sandbox/gen-settings.sh"

    # Empty extras -- sandbox.json's freshly-registered default. This is
    # exactly the shape that crashes bash 3.2 under `set -u`.
    run "$BASH32" "$gen_settings" \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]
    bash32_empty="$output"

    run bash "$gen_settings" \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$bash32_empty" ]

    # Non-empty extras.
    mkdir -p "$PROJECT_DIR/build"
    jq --arg d "$PROJECT_DIR/build" \
        '.filesystem.extraAllowWrite = [$d] | .network.extraAllowedDomains = ["example.com"]' \
        "$PROJECT_DIR/.claude-dev/sandbox.json" > "$BATS_TEST_TMPDIR/sandbox.json.tmp"
    mv "$BATS_TEST_TMPDIR/sandbox.json.tmp" "$PROJECT_DIR/.claude-dev/sandbox.json"

    run "$BASH32" "$gen_settings" \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]
    bash32_full="$output"
    [[ "$bash32_full" == *"$PROJECT_DIR/build"* ]]
    [[ "$bash32_full" == *"example.com"* ]]

    run bash "$gen_settings" \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$bash32_full" ]
}

@test "every script under scripts/ passes bash -n and its --help/--check smoke under bash 3.2" {
    require_bash32

    while IFS= read -r f; do
        run "$BASH32" -n "$f"
        [ "$status" -eq 0 ]
    done < <(find "$REPO_ROOT/scripts" -type f)

    # --help/--check smoke: whichever safe, side-effect-free entry point
    # each script exposes, actually run under bash 3.2. install-srt.sh and
    # install-tools.sh only ever touch node/npm/brew/gh, which setup()'s
    # stubs (already on PATH) make hermetic -- no real network/npm/brew call.

    run "$BASH32" "$REPO_ROOT/scripts/launcher.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-dev"* ]]

    run "$BASH32" "$REPO_ROOT/scripts/sandbox/claude-orca-shell" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-orca-shell"* ]]

    run "$BASH32" "$REPO_ROOT/scripts/sandbox/claude-orca-root" --cwd "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    run "$BASH32" "$REPO_ROOT/scripts/install-tools.sh"
    [ "$status" -eq 0 ]

    # V1 (claude-orca-qt9.1): the installers take the folder's host dir as
    # $1 -- a smoke run gets a scratch one, never this repo's parent.
    smoke_host="$BATS_TEST_TMPDIR/smoke-host"
    run "$BASH32" "$REPO_ROOT/scripts/install-srt.sh" "$smoke_host"
    [ "$status" -eq 0 ]

    CLAUDE_ORCA_SKIP_CLAUDE=1 run "$BASH32" "$REPO_ROOT/scripts/install-claude.sh" "$smoke_host"
    [ "$status" -eq 0 ]

    CLAUDE_ORCA_SKIP_ORCA_DMG=1 run "$BASH32" "$REPO_ROOT/scripts/install-orca.sh" "$smoke_host"
    [ "$status" -eq 0 ]

    run "$BASH32" "$REPO_ROOT/scripts/v1-leftovers.sh" --check
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    make_project "$PROJECT_DIR"
    real_home="$(make_real_home)"
    primary="$(abspath "$PROJECT_DIR")"
    run "$BASH32" "$REPO_ROOT/scripts/sandbox/gen-settings.sh" \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    run "$BASH32" -c "unset CLAUDE_ORCA_SANDBOXED; cd '$BATS_TEST_TMPDIR' && . '$REPO_ROOT/scripts/sandbox/shellrc.zsh'; echo REACHED_END"
    [ "$status" -eq 0 ]
    [[ "$output" == *"REACHED_END"* ]]

    run "$BASH32" -c "unset CLAUDE_ORCA_SANDBOXED; cd '$BATS_TEST_TMPDIR' && . '$REPO_ROOT/scripts/sandbox/shellrc.bash'; echo REACHED_END"
    [ "$status" -eq 0 ]
    [[ "$output" == *"REACHED_END"* ]]
}

@test "a bash-3.2 lint finds no unguarded empty-array expansion, associative array, mapfile or \${var,,} in scripts/" {
    run "$REPO_ROOT/scripts/lint-bash32.sh" "$REPO_ROOT/scripts"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "zsh -l -c command inside a bootstrapped folder is re-exec'd through the wrapper with the command preserved" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    cd "$primary"

    unset CLAUDE_ORCA_SANDBOXED
    run zsh -l -c 'echo INNER_RAN'
    [ "$status" -eq 0 ]
    [[ "$output" == *"INNER_RAN"* ]]

    expected="exec zsh -l -c 'echo INNER_RAN'"
    grep -A1 -Fx -- '-c' "$STUB_LOG" | grep -qxF "$expected"
}

@test "bash -l -c command inside a bootstrapped folder is re-exec'd through the wrapper with the command preserved" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    cd "$primary"

    unset CLAUDE_ORCA_SANDBOXED
    run bash -l -c 'echo INNER_RAN'
    [ "$status" -eq 0 ]
    [[ "$output" == *"INNER_RAN"* ]]

    expected="exec bash -l -c 'echo INNER_RAN'"
    grep -A1 -Fx -- '-c' "$STUB_LOG" | grep -qxF "$expected"
}

@test "interactive zsh -il and bash -il still re-exec (no double exec when already sandboxed)" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    cd "$primary"

    unset CLAUDE_ORCA_SANDBOXED
    run zsh -il -c 'echo ZSH_RAN'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ZSH_RAN"* ]]
    expected="exec zsh -l -c 'echo ZSH_RAN'"
    grep -A1 -Fx -- '-c' "$STUB_LOG" | grep -qxF "$expected"

    : > "$STUB_LOG"
    unset CLAUDE_ORCA_SANDBOXED
    run bash -il -c 'echo BASH_RAN'
    [ "$status" -eq 0 ]
    [[ "$output" == *"BASH_RAN"* ]]
    expected="exec bash -l -c 'echo BASH_RAN'"
    grep -A1 -Fx -- '-c' "$STUB_LOG" | grep -qxF "$expected"

    # Already sandboxed: the top-level CLAUDE_ORCA_SANDBOXED guard makes the
    # whole hook a no-op -- no srt invocation at all, command runs directly.
    : > "$STUB_LOG"
    run env CLAUDE_ORCA_SANDBOXED=1 zsh -il -c 'echo ALREADY_SANDBOXED'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ALREADY_SANDBOXED"* ]]
    [ ! -s "$STUB_LOG" ]

    run env CLAUDE_ORCA_SANDBOXED=1 bash -il -c 'echo ALREADY_SANDBOXED_BASH'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ALREADY_SANDBOXED_BASH"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "rc-install writes the block into .zprofile, .zshrc and .bash_profile, appended after existing content, idempotently, and rc-uninstall removes all three" {
    make_project "$PROJECT_DIR"

    pre_existing='eval "$(/opt/homebrew/bin/brew shellenv)"'
    seed_pre_existing_rc_line "$pre_existing"

    orig_zprofile_sum="$(sha256sum "$HOME/.zprofile" | cut -d' ' -f1)"
    orig_zshrc_sum="$(sha256sum "$HOME/.zshrc" | cut -d' ' -f1)"
    orig_bp_sum="$(sha256sum "$HOME/.bash_profile" | cut -d' ' -f1)"

    run "$ORCA_HOST/bin/claude-dev" rc-install
    [ "$status" -eq 0 ]

    for f in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile"; do
        [ "$(grep -c '# >>> claude_orca >>>' "$f")" -eq 1 ]
        grep -qxF "$pre_existing" "$f"
        pre_line="$(grep -nxF "$pre_existing" "$f" | head -1 | cut -d: -f1)"
        marker_line="$(grep -nxF '# >>> claude_orca >>>' "$f" | head -1 | cut -d: -f1)"
        [ "$marker_line" -gt "$pre_line" ]
    done

    zprofile_sum1="$(sha256sum "$HOME/.zprofile" | cut -d' ' -f1)"
    zshrc_sum1="$(sha256sum "$HOME/.zshrc" | cut -d' ' -f1)"
    bp_sum1="$(sha256sum "$HOME/.bash_profile" | cut -d' ' -f1)"

    run "$ORCA_HOST/bin/claude-dev" rc-install
    [ "$status" -eq 0 ]
    [ "$(sha256sum "$HOME/.zprofile" | cut -d' ' -f1)" = "$zprofile_sum1" ]
    [ "$(sha256sum "$HOME/.zshrc" | cut -d' ' -f1)" = "$zshrc_sum1" ]
    [ "$(sha256sum "$HOME/.bash_profile" | cut -d' ' -f1)" = "$bp_sum1" ]
    [ "$(grep -c '# >>> claude_orca >>>' "$HOME/.zprofile")" -eq 1 ]
    [ "$(grep -c '# >>> claude_orca >>>' "$HOME/.zshrc")" -eq 1 ]
    [ "$(grep -c '# >>> claude_orca >>>' "$HOME/.bash_profile")" -eq 1 ]

    run "$ORCA_HOST/bin/claude-dev" rc-uninstall
    [ "$status" -eq 0 ]
    ! grep -q '# >>> claude_orca >>>' "$HOME/.zprofile"
    ! grep -q '# >>> claude_orca >>>' "$HOME/.zshrc"
    ! grep -q '# >>> claude_orca >>>' "$HOME/.bash_profile"

    [ "$(sha256sum "$HOME/.zprofile" | cut -d' ' -f1)" = "$orig_zprofile_sum" ]
    [ "$(sha256sum "$HOME/.zshrc" | cut -d' ' -f1)" = "$orig_zshrc_sum" ]
    [ "$(sha256sum "$HOME/.bash_profile" | cut -d' ' -f1)" = "$orig_bp_sum" ]
}

# V6 addition (rc_reclaim): an rc file left root-owned by a sudo'd
# installer used to stop registration dead with a sudo instruction. Removing
# a file needs write permission on its DIRECTORY, not on the file, so while
# $HOME is ours the file is rebuilt in place with identical contents and no
# sudo at all. Neither case can run as root, for whom -w is always true.
@test "rc-install reclaims an unwritable-but-readable rc file without sudo" {
    if [ "$(id -u)" -eq 0 ]; then
        skip "root can write anything, so -w never reports the problem"
    fi

    make_project "$PROJECT_DIR"

    pre_existing='export CLAUDE_ORCA_RC_RECLAIM_TEST=1'
    printf '%s\n' "$pre_existing" > "$HOME/.bash_profile"
    chmod 444 "$HOME/.bash_profile"

    run "$ORCA_HOST/bin/claude-dev" rc-install
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reclaimed"* ]]
    [[ "$output" == *".bash_profile"* ]]

    [ -w "$HOME/.bash_profile" ]
    grep -qxF "$pre_existing" "$HOME/.bash_profile"
    [ "$(grep -c '# >>> claude_orca >>>' "$HOME/.bash_profile")" -eq 1 ]
}

@test "rc-install still fails closed when the rc file is unreadable" {
    if [ "$(id -u)" -eq 0 ]; then
        skip "root can read anything, so the refusal never fires"
    fi

    make_project "$PROJECT_DIR"

    : > "$HOME/.bash_profile"
    chmod 000 "$HOME/.bash_profile"

    run "$ORCA_HOST/bin/claude-dev" rc-install
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot write"* ]]
    [[ "$output" == *".bash_profile"* ]]
    [[ "$output" == *"chown"* ]]
    [[ "$output" != *"Reclaimed"* ]]
}
