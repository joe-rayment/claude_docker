#!/usr/bin/env bats
#
# S2 acceptance contract (claude-orca-3sk.14) -- FROZEN from RED-AT onward.
# Exercises scripts/sandbox/{gen-settings.sh,claude-orca-root,
# claude-orca-shell,shellrc.zsh,shellrc.bash} and the launcher's
# rc-install/rc-uninstall, with srt/brew/npm/gh/node stubbed on PATH (see
# helpers/setup.bash) -- no Docker, no network, no real macOS tooling
# required. One case (schema validation) needs a real node + a real,
# installed copy of @anthropic-ai/sandbox-runtime and is skipped, not
# faked, when neither is available.

load helpers/setup

GEN_SETTINGS() {
    "$ORCA_HOST/template/scripts/sandbox/gen-settings.sh" "$@"
}

# V6 (claude-orca-riu.3): `claude-dev register` now seeds orca.cli true,
# which widens allowRead and allowUnixSockets by the Orca runtime dir. The
# S2 scope cases below pin the BASE scope, so they switch the mode off
# first; the seeded default is pinned by tests/orca-cli-mode.bats.
disable_orca_cli() {
    local dir="$1" tmp="$BATS_TEST_TMPDIR/sandbox.json.tmp"
    jq '.orca.cli = false' "$dir/.claude-dev/sandbox.json" > "$tmp"
    mv "$tmp" "$dir/.claude-dev/sandbox.json"
}

@test "primary checkout scope: allowWrite is exactly project, .claude-dev/home, .claude-dev/tmp" {
    make_project "$PROJECT_DIR"
    real_home="$(make_real_home)"
    primary="$(abspath "$PROJECT_DIR")"

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    expected="$(jq -nc --arg p "$primary" '[$p, ($p+"/.claude-dev/home"), ($p+"/.claude-dev/tmp")]')"
    actual="$(jq -c '.filesystem.allowWrite' <<<"$output")"
    [ "$actual" = "$expected" ]

    # A validated filesystem.extraAllowWrite entry is appended -- and only
    # appended: the base three stay first, in place, unmodified.
    mkdir -p "$PROJECT_DIR/build"
    jq --arg d "$PROJECT_DIR/build" '.filesystem.extraAllowWrite = [$d]' \
        "$PROJECT_DIR/.claude-dev/sandbox.json" > "$BATS_TEST_TMPDIR/sandbox.json.tmp"
    mv "$BATS_TEST_TMPDIR/sandbox.json.tmp" "$PROJECT_DIR/.claude-dev/sandbox.json"

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    expected_with_extra="$(jq -nc --arg p "$primary" \
        '[$p, ($p+"/.claude-dev/home"), ($p+"/.claude-dev/tmp"), ($p+"/build")]')"
    actual="$(jq -c '.filesystem.allowWrite' <<<"$output")"
    [ "$actual" = "$expected_with_extra" ]
}

@test "linked worktree scope: allowWrite is exactly worktree, primary/.git, primary/.beads, primary/.claude-dev/home, primary/.claude-dev/tmp" {
    make_project "$PROJECT_DIR"
    wt="$(make_worktree "$PROJECT_DIR" feature)"
    real_home="$(make_real_home)"
    primary="$(abspath "$PROJECT_DIR")"
    worktree="$(abspath "$wt")"

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$worktree" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    # V2d (claude-orca-qt9.9): .claude-dev/run is on the list too -- what a
    # sandbox writes goes there, and a linked worktree names every shared
    # path outright instead of inheriting them from "$primary".
    expected="$(jq -nc --arg w "$worktree" --arg p "$primary" \
        '[$w, ($p+"/.git"), ($p+"/.beads"), ($p+"/.claude-dev/home"), ($p+"/.claude-dev/tmp"), ($p+"/.claude-dev/run")]')"
    actual="$(jq -c '.filesystem.allowWrite' <<<"$output")"
    [ "$actual" = "$expected" ]
}

@test "denyRead contains the real HOME and allowRead re-opens only project, worktree, ~/.claude-orca, ~/.local/bin, ~/.local/share/claude, ~/.orca/agent-hooks" {
    make_project "$PROJECT_DIR"
    disable_orca_cli "$PROJECT_DIR"
    wt="$(make_worktree "$PROJECT_DIR" feature)"
    real_home="$(make_real_home)"
    host="$(abspath "$ORCA_HOST")"
    primary="$(abspath "$PROJECT_DIR")"
    worktree="$(abspath "$wt")"

    # Primary session: worktree == primary, so allowRead dedupes to one entry.
    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    deny_read="$(jq -c '.filesystem.denyRead' <<<"$output")"
    [ "$deny_read" = "$(jq -nc --arg h "$real_home" '[$h]')" ]

    allow_read="$(jq -c '.filesystem.allowRead' <<<"$output")"
    expected_primary="$(jq -nc --arg p "$primary" --arg h "$host" --arg rh "$real_home" \
        '[$p, $h, ($rh+"/.local/bin"), ($rh+"/.local/share/claude"), ($rh+"/.orca/agent-hooks")]')"
    [ "$allow_read" = "$expected_primary" ]

    # Linked worktree: both primary and worktree are re-opened.
    run GEN_SETTINGS \
        --primary "$primary" --worktree "$worktree" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    allow_read="$(jq -c '.filesystem.allowRead' <<<"$output")"
    expected_worktree="$(jq -nc --arg p "$primary" --arg w "$worktree" --arg h "$host" --arg rh "$real_home" \
        '[$p, $w, $h, ($rh+"/.local/bin"), ($rh+"/.local/share/claude"), ($rh+"/.orca/agent-hooks")]')"
    [ "$allow_read" = "$expected_worktree" ]
}

@test "host-executed files are denyWrite: every entry of the shared host-owned list, for the primary and any linked worktree" {
    make_project "$PROJECT_DIR"
    wt="$(make_worktree "$PROJECT_DIR" feature)"
    real_home="$(make_real_home)"
    primary="$(abspath "$PROJECT_DIR")"
    worktree="$(abspath "$wt")"
    # V2 (claude-orca-qt9.2): one list, shared with the Orca-layer profile.
    . "$REPO_ROOT/scripts/sandbox/host-owned-paths.sh"

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    deny_write="$(jq -c '.filesystem.denyWrite' <<<"$output")"
    expected="$(host_owned_paths "$primary" | jq -R . | jq -s -c .)"
    [ "$deny_write" = "$expected" ]

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$worktree" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    deny_write="$(jq -c '.filesystem.denyWrite' <<<"$output")"
    expected="$({ host_owned_paths "$primary"; host_owned_paths "$worktree"; } \
        | jq -R . | jq -s -c .)"
    [ "$deny_write" = "$expected" ]
}

@test "network: defaults plus sandbox.json extras, strictAllowlist/allowLocalBinding/allowPty/enableWeakerNetworkIsolation true, allowAppleEvents false, allowUnixSockets empty" {
    make_project "$PROJECT_DIR"
    disable_orca_cli "$PROJECT_DIR"
    real_home="$(make_real_home)"
    primary="$(abspath "$PROJECT_DIR")"

    jq '.network.extraAllowedDomains = ["example.com", "*.internal.example.org"]' \
        "$PROJECT_DIR/.claude-dev/sandbox.json" > "$BATS_TEST_TMPDIR/sandbox.json.tmp"
    mv "$BATS_TEST_TMPDIR/sandbox.json.tmp" "$PROJECT_DIR/.claude-dev/sandbox.json"

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    allowed="$(jq -c '.network.allowedDomains' <<<"$output")"
    expected='["api.anthropic.com","claude.ai","console.anthropic.com","platform.claude.com","statsig.anthropic.com","*.sentry.io","github.com","api.github.com","*.githubusercontent.com","registry.npmjs.org","pypi.org","files.pythonhosted.org","cdn.playwright.dev","playwright.download.prss.microsoft.com","example.com","*.internal.example.org"]'
    [ "$allowed" = "$expected" ]

    run jq -e '.network.strictAllowlist == true
        and .network.allowLocalBinding == true
        and .network.allowUnixSockets == []
        and .network.deniedDomains == []
        and .allowPty == true
        and .enableWeakerNetworkIsolation == true
        and .allowAppleEvents == false' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "invalid sandbox.json extras (domain pattern, write path outside the folder) are rejected" {
    make_project "$PROJECT_DIR"
    real_home="$(make_real_home)"
    primary="$(abspath "$PROJECT_DIR")"

    jq '.network.extraAllowedDomains = ["*.com"]' \
        "$PROJECT_DIR/.claude-dev/sandbox.json" > "$BATS_TEST_TMPDIR/sandbox.json.tmp"
    mv "$BATS_TEST_TMPDIR/sandbox.json.tmp" "$PROJECT_DIR/.claude-dev/sandbox.json"

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 2 ]
    [[ "$output" == *"domain"* ]]

    outside="$BATS_TEST_TMPDIR/outside-dir"
    mkdir -p "$outside"
    jq --arg d "$outside" '.network.extraAllowedDomains = [] | .filesystem.extraAllowWrite = [$d]' \
        "$PROJECT_DIR/.claude-dev/sandbox.json" > "$BATS_TEST_TMPDIR/sandbox.json.tmp"
    mv "$BATS_TEST_TMPDIR/sandbox.json.tmp" "$PROJECT_DIR/.claude-dev/sandbox.json"

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 2 ]
    [[ "$output" == *"outside"* || "$output" == *"extraAllowWrite"* ]]
}

@test "generated settings validate against the pinned srt schema (node against ~/.claude-orca/srt)" {
    real_srt_dir="$(ensure_real_srt)" || skip "no real node/npm available to fetch or run the pinned srt schema (set CLAUDE_ORCA_SRT_REAL, or ensure node+npm are on PATH outside the test stub)"

    make_project "$PROJECT_DIR"
    real_home="$(make_real_home)"
    primary="$(abspath "$PROJECT_DIR")"

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/settings.json"

    run env PATH="$ORIGINAL_PATH" node "$REPO_ROOT/tests/helpers/validate-srt-schema.mjs" \
        "$real_srt_dir/dist/index.js" "$BATS_TEST_TMPDIR/settings.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VALID"* ]]
}

@test "env block matches the specified variables" {
    make_project "$PROJECT_DIR"
    real_home="$(abspath "$(make_real_home)")"
    primary="$(abspath "$PROJECT_DIR")"
    host="$(abspath "$ORCA_HOST")"

    export CLAUDE_ORCA_REAL_HOME="$real_home"
    run "$ORCA_HOST/bin/claude-orca-shell" --print-env --root "$primary" --cwd "$primary"
    unset CLAUDE_ORCA_REAL_HOME
    [ "$status" -eq 0 ]

    expected_lines=(
        "HOME=$primary/.claude-dev/home"
        "CLAUDE_CONFIG_DIR=$primary/.claude-dev/home/.claude"
        "TMPDIR=$primary/.claude-dev/tmp"
        "GIT_CONFIG_GLOBAL=$primary/.claude-dev/home/.gitconfig"
        "GH_CONFIG_DIR=$primary/.claude-dev/home/.config/gh"
        "BEADS_DIR=$primary/.beads"
        "ORCA_USER_DATA_PATH=$real_home/Library/Application Support/orca"
        "DISABLE_AUTOUPDATER=1"
        "CLAUDE_ORCA_SANDBOXED=1"
        "CLAUDE_ORCA_REAL_HOME=$real_home"
        "CLAUDE_ORCA_ROOT=$primary"
        "PATH=$host/bin:$host/template/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$real_home/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    )

    for line in "${expected_lines[@]}"; do
        grep -qxF "$line" <<<"$output"
    done

    [ "$(wc -l <<<"$output")" -eq "${#expected_lines[@]}" ]
}

@test "rc snippet install is idempotent and --uninstall removes it (zsh and bash)" {
    make_project "$PROJECT_DIR"

    echo "# pre-existing user content" > "$HOME/.zshrc"
    echo "# pre-existing user content" > "$HOME/.bash_profile"

    run "$ORCA_HOST/bin/claude-dev" rc-install
    [ "$status" -eq 0 ]
    [ "$(grep -c '# >>> claude_orca >>>' "$HOME/.zshrc")" -eq 1 ]
    [ "$(grep -c '# >>> claude_orca >>>' "$HOME/.bash_profile")" -eq 1 ]
    grep -qxF "# pre-existing user content" "$HOME/.zshrc"
    grep -qxF "# pre-existing user content" "$HOME/.bash_profile"

    zshrc_sum1="$(sha256sum "$HOME/.zshrc" | cut -d' ' -f1)"
    bp_sum1="$(sha256sum "$HOME/.bash_profile" | cut -d' ' -f1)"

    run "$ORCA_HOST/bin/claude-dev" rc-install
    [ "$status" -eq 0 ]
    [ "$(grep -c '# >>> claude_orca >>>' "$HOME/.zshrc")" -eq 1 ]
    [ "$(grep -c '# >>> claude_orca >>>' "$HOME/.bash_profile")" -eq 1 ]
    [ "$(sha256sum "$HOME/.zshrc" | cut -d' ' -f1)" = "$zshrc_sum1" ]
    [ "$(sha256sum "$HOME/.bash_profile" | cut -d' ' -f1)" = "$bp_sum1" ]

    run "$ORCA_HOST/bin/claude-dev" rc-uninstall
    [ "$status" -eq 0 ]
    ! grep -q '# >>> claude_orca >>>' "$HOME/.zshrc"
    ! grep -q '# >>> claude_orca >>>' "$HOME/.bash_profile"
    grep -qxF "# pre-existing user content" "$HOME/.zshrc"
    grep -qxF "# pre-existing user content" "$HOME/.bash_profile"
}

@test "shellrc is a no-op outside a bootstrapped folder and when CLAUDE_ORCA_SANDBOXED=1" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    outside="$BATS_TEST_TMPDIR/not-a-project"
    mkdir -p "$outside"

    for shell in zsh bash; do
        command -v "$shell" >/dev/null 2>&1 || continue
        if [ "$shell" = zsh ]; then rc_name=shellrc.zsh; else rc_name=shellrc.bash; fi

        run "$shell" -c "cd '$outside' && unset CLAUDE_ORCA_SANDBOXED && . '$ORCA_HOST/template/scripts/sandbox/$rc_name' && echo REACHED_END"
        [ "$status" -eq 0 ]
        [[ "$output" == *"REACHED_END"* ]]
        [[ "$output" != *"REFUSING"* ]]

        run "$shell" -c "cd '$primary' && export CLAUDE_ORCA_SANDBOXED=1 && . '$ORCA_HOST/template/scripts/sandbox/$rc_name' && echo REACHED_END"
        [ "$status" -eq 0 ]
        [[ "$output" == *"REACHED_END"* ]]
        [[ "$output" != *"REFUSING"* ]]
    done
}

@test "wrapper execs stubbed srt with --settings <generated> -c 'exec zsh -l'" {
    make_project "$PROJECT_DIR"
    real_home="$(make_real_home)"
    primary="$(abspath "$PROJECT_DIR")"

    export CLAUDE_ORCA_REAL_HOME="$real_home"
    export STUB_SRT_NOEXEC=1
    run "$ORCA_HOST/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    unset STUB_SRT_NOEXEC CLAUDE_ORCA_REAL_HOME
    [ "$status" -eq 0 ]

    # V2d (claude-orca-qt9.9): the settings file is written to a private
    # per-launch directory outside the folder (the wrapper runs inside
    # layer 1, which write-denies the host-owned tree, and the file
    # defines layer 2, so nowhere layer 2 can write either) -- name it
    # from what srt was handed, and keep the file-name hash pinned.
    settings_hash="$(printf '%s' "$primary" | sha1sum | cut -d' ' -f1)"
    settings_file="$(grep -A1 -Fx -- '--settings' "$STUB_LOG" | sed -n 2p)"
    [ "$(basename "$settings_file")" = "srt-$settings_hash.json" ]
    [ "${settings_file#$primary/}" = "$settings_file" ]
    [ -f "$settings_file" ]
    [ "$(file_mode "$settings_file")" = "600" ]

    grep -A1 -Fx -- '-c' "$STUB_LOG" | grep -qxF 'exec zsh -l'
}

@test "missing srt shadows claude/codex/gemini/opencode with refusing functions" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    rm -f "$ORCA_HOST/srt/node_modules/.bin/srt"

    for shell in zsh bash; do
        command -v "$shell" >/dev/null 2>&1 || continue
        if [ "$shell" = zsh ]; then rc_name=shellrc.zsh; else rc_name=shellrc.bash; fi

        for agent in claude codex gemini opencode; do
            run "$shell" -c "cd '$primary' && unset CLAUDE_ORCA_SANDBOXED && . '$ORCA_HOST/template/scripts/sandbox/$rc_name' && $agent; ec=\$?; echo \"EXIT:\$ec\""
            [ "$status" -eq 0 ]
            [[ "$output" == *"REFUSING"* ]]
            [[ "$output" == *"EXIT:1"* ]]
        done
    done
}
