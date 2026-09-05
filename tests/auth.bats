#!/usr/bin/env bats
#
# auth.bats -- S5 (claude-orca-3sk.17): the credential story for a
# sandboxed project. With HOME faked and the Keychain unreachable, Claude
# Code, gh and git each need a way to authenticate that keeps secrets out
# of the agent's reach and out of the repo:
#
#   Claude   -- guided first run inside the sandbox writes
#               <config dir>/.credentials.json (0600); the wrapper prints
#               the login path only while that file is absent.
#   gh       -- the HOST side reads `gh auth token` and passes GH_TOKEN
#               into srt, which masks it (credentials.envVars, mode mask,
#               injectHosts github.com + api.github.com). The token is
#               never written under the project.
#   git      -- registration seeds <project>/.claude-dev/home/.gitconfig
#               with user.name/user.email copied from the host, nothing
#               else.
#   billing  -- auth-guard is fatal on ANTHROPIC_API_KEY/_AUTH_TOKEN/
#               _BASE_URL unless CLAUDE_DEV_ALLOW_API_BILLING=1.
#
# FROZEN per claude-orca-3sk.17's acceptance contract: this file must not
# be edited after its RED commit. If a case here turns out to be wrong,
# stop and report -- do not edit it.

load helpers/setup

SHELL_BIN_UNDER_TEST() {
    "$ORCA_HOST/bin/claude-orca-shell" "$@"
}

AUTH_GUARD() {
    "$ORCA_HOST/template/bin/auth-guard" "$@"
}

# --- 1. srt settings: the masked GH_TOKEN credential ----------------------

@test "srt settings carry credentials.envVars GH_TOKEN with mode mask and injectHosts github.com and api.github.com" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"

    run SHELL_BIN_UNDER_TEST --print-settings --root "$primary" --cwd "$primary"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/settings.json"

    run jq -r '.credentials.envVars | length' "$BATS_TEST_TMPDIR/settings.json"
    [ "$output" = "1" ]

    run jq -r '.credentials.envVars[0].name' "$BATS_TEST_TMPDIR/settings.json"
    [ "$output" = "GH_TOKEN" ]

    run jq -r '.credentials.envVars[0].mode' "$BATS_TEST_TMPDIR/settings.json"
    [ "$output" = "mask" ]

    run jq -r '.credentials.envVars[0].injectHosts | join(",")' "$BATS_TEST_TMPDIR/settings.json"
    [ "$output" = "github.com,api.github.com" ]

    # No gh token on the host -> no credentials block at all, so the
    # settings stay schema-valid either way (an entry naming an unset var
    # is not a thing we want to emit).
    export STUB_GH_UNAUTH=1
    run SHELL_BIN_UNDER_TEST --print-settings --root "$primary" --cwd "$primary"
    unset STUB_GH_UNAUTH
    [ "$status" -eq 0 ]
    run jq -r 'has("credentials")' <<<"$output"
    [ "$output" = "false" ]
}

@test "settings carrying the credentials block still validate against the pinned srt schema" {
    real_srt_dir="$(ensure_real_srt)" || skip "no real node/npm available to fetch or run the pinned srt schema"

    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"

    run SHELL_BIN_UNDER_TEST --print-settings --root "$primary" --cwd "$primary"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/settings.json"
    grep -q '"GH_TOKEN"' "$BATS_TEST_TMPDIR/settings.json"

    run env PATH="$ORIGINAL_PATH" node "$REPO_ROOT/tests/helpers/validate-srt-schema.mjs" \
        "$real_srt_dir/dist/index.js" "$BATS_TEST_TMPDIR/settings.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VALID"* ]]
}

# --- 2. where the token comes from, and where it must never land ---------

@test "GH_TOKEN comes from stubbed \`gh auth token\` at wrapper time and is not written anywhere under the project" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"

    export STUB_GH_TOKEN="gho_stubbedtokenSENTINEL0123456789"
    export STUB_SRT_NOEXEC=1
    run SHELL_BIN_UNDER_TEST --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]

    # It reached the srt process environment (srt does the masking).
    grep -qxF "GH_TOKEN=$STUB_GH_TOKEN" "$STUB_ENV"

    # ...and nowhere under the project: not the settings file, not the
    # env/state files, not the seeded sandbox HOME.
    run grep -rlF "$STUB_GH_TOKEN" "$primary"
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    # The wrapper never echoes it either.
    run SHELL_BIN_UNDER_TEST --print-env --root "$primary" --cwd "$primary"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$STUB_GH_TOKEN"* ]]
}

# --- 3. git identity ------------------------------------------------------

@test "gitconfig seeded with user.name and user.email only" {
    git config --global user.name "Host User"
    git config --global user.email "host@example.com"

    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    gc="$primary/.claude-dev/home/.gitconfig"
    [ -f "$gc" ]

    run git config --file "$gc" --get user.name
    [ "$output" = "Host User" ]
    run git config --file "$gc" --get user.email
    [ "$output" = "host@example.com" ]

    # Nothing else -- no credential helper, no signing key, no remotes.
    run git config --file "$gc" --list
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]

    # Never reset a project's own edits.
    git config --file "$gc" user.name "Edited By Hand"
    run "$ORCA_HOST/bin/claude-dev" register "$primary"
    [ "$status" -eq 0 ]
    run git config --file "$gc" --get user.name
    [ "$output" = "Edited By Hand" ]
}

# --- 4. billing hard-guard (ported from claude_docker's auth-guard) ------

@test "auth-guard is fatal on ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL and a warning with CLAUDE_DEV_ALLOW_API_BILLING=1" {
    guard="$REPO_ROOT/bin/auth-guard"
    [ -x "$guard" ]

    for var in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL; do
        run env HOME="$HOME" "$var=leaked-value" "$guard"
        [ "$status" -ne 0 ]
        [[ "$output" == *"FATAL"* ]]
        [[ "$output" == *"$var"* ]]
        [[ "$output" == *"process environment"* ]]

        run env HOME="$HOME" "$var=leaked-value" CLAUDE_DEV_ALLOW_API_BILLING=1 "$guard"
        [ "$status" -eq 0 ]
        [[ "$output" == *"WARNING"* ]]
        [[ "$output" == *"$var"* ]]
        [[ "$output" != *"FATAL"* ]]
    done
}

@test "auth-guard: silent exit 0 when nothing is set and the config dir does not exist" {
    run env HOME="$HOME" "$REPO_ROOT/bin/auth-guard"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "auth-guard: unrelated env vars and unrelated .env keys are never a hit" {
    mkdir -p "$HOME/.claude"
    printf '%s' '{"env":{"KEEP":"1","ANTHROPIC_MODEL":"claude-opus-5"}}' > "$HOME/.claude/settings.json"
    run env HOME="$HOME" UNRELATED_VAR=1 "$REPO_ROOT/bin/auth-guard"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "auth-guard: fatal on an offending key in the .env block of settings.json or settings.local.json" {
    mkdir -p "$HOME/.claude"
    printf '%s' '{"env":{"ANTHROPIC_API_KEY":"sk-ant-leaked"}}' > "$HOME/.claude/settings.json"
    run env HOME="$HOME" "$REPO_ROOT/bin/auth-guard"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
    [[ "$output" == *"settings.json"* ]]

    rm -f "$HOME/.claude/settings.json"
    printf '%s' '{"env":{"ANTHROPIC_BASE_URL":"https://evil.example.com"}}' \
        > "$HOME/.claude/settings.local.json"
    run env HOME="$HOME" "$REPO_ROOT/bin/auth-guard"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"settings.local.json"* ]]
}

@test "the wrapper runs auth-guard before exec and refuses to launch on a fatal hit" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"

    export STUB_SRT_NOEXEC=1
    : > "$STUB_LOG"
    run env ANTHROPIC_API_KEY=sk-ant-leaked \
        "$ORCA_HOST/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    # never reached srt
    run grep -c "=== srt invocation ===" "$STUB_LOG"
    [ "$output" = "0" ]

    run env ANTHROPIC_API_KEY=sk-ant-leaked CLAUDE_DEV_ALLOW_API_BILLING=1 \
        "$ORCA_HOST/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"* ]]
    grep -q "=== srt invocation ===" "$STUB_LOG"
}

# --- 5. guided Claude first run ------------------------------------------

@test "guided first-run prints the login path when .credentials.json is absent and skips it when present" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    creds="$primary/.claude-dev/home/.claude/.credentials.json"
    export STUB_SRT_NOEXEC=1

    [ ! -f "$creds" ]
    run SHELL_BIN_UNDER_TEST --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]
    [[ "$output" == *"no Claude credentials yet"* ]]
    [[ "$output" == *"$creds"* ]]

    run SHELL_BIN_UNDER_TEST --check --root "$primary" --cwd "$primary"
    [ "$status" -eq 0 ]
    [[ "$output" == *"auth: credentials absent"* ]]

    mkdir -p "$(dirname "$creds")"
    printf '%s' '{"claudeAiOauth":{"accessToken":"fake"}}' > "$creds"
    chmod 600 "$creds"

    run SHELL_BIN_UNDER_TEST --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]
    [[ "$output" != *"no Claude credentials yet"* ]]

    run SHELL_BIN_UNDER_TEST --check --root "$primary" --cwd "$primary"
    [ "$status" -eq 0 ]
    [[ "$output" == *"auth: credentials present"* ]]
}
