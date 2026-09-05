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
    "$CLAUDE_ORCA_HOME/template/scripts/sandbox/gen-settings.sh" "$@"
}

@test "primary checkout scope: allowWrite is exactly project, .claude-dev/home, .claude-dev/tmp" {
    make_project "$PROJECT_DIR"
    real_home="$(make_real_home)"
    primary="$(abspath "$PROJECT_DIR")"

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
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
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
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
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    expected="$(jq -nc --arg w "$worktree" --arg p "$primary" \
        '[$w, ($p+"/.git"), ($p+"/.beads"), ($p+"/.claude-dev/home"), ($p+"/.claude-dev/tmp")]')"
    actual="$(jq -c '.filesystem.allowWrite' <<<"$output")"
    [ "$actual" = "$expected" ]
}

@test "denyRead contains the real HOME and allowRead re-opens only project, worktree, ~/.claude-orca, ~/.local/bin, ~/.local/share/claude, ~/.orca/agent-hooks" {
    make_project "$PROJECT_DIR"
    wt="$(make_worktree "$PROJECT_DIR" feature)"
    real_home="$(make_real_home)"
    host="$(abspath "$CLAUDE_ORCA_HOME")"
    primary="$(abspath "$PROJECT_DIR")"
    worktree="$(abspath "$wt")"

    # Primary session: worktree == primary, so allowRead dedupes to one entry.
    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
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
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    allow_read="$(jq -c '.filesystem.allowRead' <<<"$output")"
    expected_worktree="$(jq -nc --arg p "$primary" --arg w "$worktree" --arg h "$host" --arg rh "$real_home" \
        '[$p, $w, $h, ($rh+"/.local/bin"), ($rh+"/.local/share/claude"), ($rh+"/.orca/agent-hooks")]')"
    [ "$allow_read" = "$expected_worktree" ]
}

@test "host-executed files are denyWrite: orca.yaml, .worktreeinclude, .envrc, .beads/hooks" {
    make_project "$PROJECT_DIR"
    wt="$(make_worktree "$PROJECT_DIR" feature)"
    real_home="$(make_real_home)"
    primary="$(abspath "$PROJECT_DIR")"
    worktree="$(abspath "$wt")"

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    deny_write="$(jq -c '.filesystem.denyWrite' <<<"$output")"
    expected="$(jq -nc --arg p "$primary" \
        '[($p+"/orca.yaml"), ($p+"/.worktreeinclude"), ($p+"/.envrc"), ($p+"/.beads/hooks")]')"
    [ "$deny_write" = "$expected" ]

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$worktree" \
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    deny_write="$(jq -c '.filesystem.denyWrite' <<<"$output")"
    expected="$(jq -nc --arg p "$primary" --arg w "$worktree" \
        '[($p+"/orca.yaml"), ($p+"/.worktreeinclude"), ($p+"/.envrc"), ($p+"/.beads/hooks"),
          ($w+"/orca.yaml"), ($w+"/.worktreeinclude"), ($w+"/.envrc")]')"
    [ "$deny_write" = "$expected" ]
}

@test "network: defaults plus sandbox.json extras, strictAllowlist/allowLocalBinding/allowPty/enableWeakerNetworkIsolation true, allowAppleEvents false, allowUnixSockets empty" {
    make_project "$PROJECT_DIR"
    real_home="$(make_real_home)"
    primary="$(abspath "$PROJECT_DIR")"

    jq '.network.extraAllowedDomains = ["example.com", "*.internal.example.org"]' \
        "$PROJECT_DIR/.claude-dev/sandbox.json" > "$BATS_TEST_TMPDIR/sandbox.json.tmp"
    mv "$BATS_TEST_TMPDIR/sandbox.json.tmp" "$PROJECT_DIR/.claude-dev/sandbox.json"

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    allowed="$(jq -c '.network.allowedDomains' <<<"$output")"
    expected='["api.anthropic.com","claude.ai","console.anthropic.com","platform.claude.com","statsig.anthropic.com","*.sentry.io","github.com","api.github.com","*.githubusercontent.com","registry.npmjs.org","pypi.org","files.pythonhosted.org","example.com","*.internal.example.org"]'
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
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
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
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
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
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
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
    host="$(abspath "$CLAUDE_ORCA_HOME")"

    export CLAUDE_ORCA_REAL_HOME="$real_home"
    run "$CLAUDE_ORCA_HOME/bin/claude-orca-shell" --print-env --root "$primary" --cwd "$primary"
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
        "PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$real_home/.local/bin:$host/template/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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

    run "$CLAUDE_ORCA_HOME/bin/claude-dev" rc-install
    [ "$status" -eq 0 ]
    [ "$(grep -c '# >>> claude_orca >>>' "$HOME/.zshrc")" -eq 1 ]
    [ "$(grep -c '# >>> claude_orca >>>' "$HOME/.bash_profile")" -eq 1 ]
    grep -qxF "# pre-existing user content" "$HOME/.zshrc"
    grep -qxF "# pre-existing user content" "$HOME/.bash_profile"

    zshrc_sum1="$(sha256sum "$HOME/.zshrc" | cut -d' ' -f1)"
    bp_sum1="$(sha256sum "$HOME/.bash_profile" | cut -d' ' -f1)"

    run "$CLAUDE_ORCA_HOME/bin/claude-dev" rc-install
    [ "$status" -eq 0 ]
    [ "$(grep -c '# >>> claude_orca >>>' "$HOME/.zshrc")" -eq 1 ]
    [ "$(grep -c '# >>> claude_orca >>>' "$HOME/.bash_profile")" -eq 1 ]
    [ "$(sha256sum "$HOME/.zshrc" | cut -d' ' -f1)" = "$zshrc_sum1" ]
    [ "$(sha256sum "$HOME/.bash_profile" | cut -d' ' -f1)" = "$bp_sum1" ]

    run "$CLAUDE_ORCA_HOME/bin/claude-dev" rc-uninstall
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

        run "$shell" -c "cd '$outside' && unset CLAUDE_ORCA_SANDBOXED && . '$CLAUDE_ORCA_HOME/$rc_name' && echo REACHED_END"
        [ "$status" -eq 0 ]
        [[ "$output" == *"REACHED_END"* ]]
        [[ "$output" != *"REFUSING"* ]]

        run "$shell" -c "cd '$primary' && export CLAUDE_ORCA_SANDBOXED=1 && . '$CLAUDE_ORCA_HOME/$rc_name' && echo REACHED_END"
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
    run "$CLAUDE_ORCA_HOME/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    unset STUB_SRT_NOEXEC CLAUDE_ORCA_REAL_HOME
    [ "$status" -eq 0 ]

    settings_hash="$(printf '%s' "$primary" | sha1sum | cut -d' ' -f1)"
    settings_file="$primary/.claude-dev/state/srt-$settings_hash.json"
    [ -f "$settings_file" ]
    [ "$(file_mode "$settings_file")" = "600" ]

    grep -A1 -Fx -- '--settings' "$STUB_LOG" | grep -qF "$settings_file"
    grep -A1 -Fx -- '-c' "$STUB_LOG" | grep -qxF 'exec zsh -l'
}

@test "missing srt shadows claude/codex/gemini/opencode with refusing functions" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    rm -f "$CLAUDE_ORCA_HOME/srt/node_modules/.bin/srt"

    for shell in zsh bash; do
        command -v "$shell" >/dev/null 2>&1 || continue
        if [ "$shell" = zsh ]; then rc_name=shellrc.zsh; else rc_name=shellrc.bash; fi

        for agent in claude codex gemini opencode; do
            run "$shell" -c "cd '$primary' && unset CLAUDE_ORCA_SANDBOXED && . '$CLAUDE_ORCA_HOME/$rc_name' && $agent; ec=\$?; echo \"EXIT:\$ec\""
            [ "$status" -eq 0 ]
            [[ "$output" == *"REFUSING"* ]]
            [[ "$output" == *"EXIT:1"* ]]
        done
    done
}
