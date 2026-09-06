#!/usr/bin/env bats
#
# S4 acceptance contract (claude-orca-3sk.4) -- FROZEN from RED-AT onward.
# Exercises scripts/config-sync.sh against a project bootstrapped by
# helpers/setup.bash's make_project() (which now also clones this repo's
# config/ and bin/ into $ORCA_HOST/template -- see setup.bash) --
# no Docker, no network, no real macOS tooling required.

load helpers/setup

CONFIG_SYNC() {
    "$ORCA_HOST/template/scripts/config-sync.sh" "$@"
}

@test "sync populates settings.json, CLAUDE.md, agents, commands, skills, statusline.sh, .zshrc from config/" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"

    # V6 (claude-orca-riu.3): register seeds orca.cli true, so the selftest
    # launch inside make_project appends claude-orca-shell's orca-cli
    # addendum to CLAUDE.md. This case is about the sync itself producing
    # the config/ sources, so drop the checksum gate and make it really
    # run -- a real sync rewrites CLAUDE.md from the template. (The
    # addendum's own lifecycle is pinned by tests/orca-cli-mode.bats.)
    rm -f "$PROJECT_DIR/.claude-dev/run/config-hash"

    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]

    dest="$primary/.claude-dev/home/.claude"
    src="$ORCA_HOST/template/config"

    [ -f "$dest/settings.json" ]
    run jq -e . "$dest/settings.json"
    [ "$status" -eq 0 ]
    [ -f "$dest/CLAUDE.md" ]
    diff "$src/claude-user-memory.md" "$dest/CLAUDE.md"
    [ -x "$dest/statusline.sh" ]
    diff "$src/statusline.sh" "$dest/statusline.sh"
    [ -f "$primary/.claude-dev/home/.zshrc" ]
    diff "$src/.zshrc" "$primary/.claude-dev/home/.zshrc"

    for f in "$src"/agents/*.md; do
        [ -f "$dest/agents/$(basename "$f")" ]
    done
    for f in "$src"/claude-commands/*.md; do
        [ -f "$dest/commands/$(basename "$f")" ]
    done
    [ -f "$dest/skills/snowpark-deploy/SKILL.md" ]
}

@test "hook commands resolve to <host>/template/bin/<name> and no command mentions /usr/local/bin, /home/agent or /workspace" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"

    # A host dir somewhere else entirely -- config-sync takes --host
    # explicitly and the caller resolves it (V1: <project>/.claude-dev,
    # see scripts/sandbox/claude-orca-shell), so this proves the SHAPE of
    # what config-sync writes once that resolution happens, independent of
    # where the folder actually is.
    fakeproject="$BATS_TEST_TMPDIR/fakeproject"
    host="$fakeproject/.claude-dev"
    mkdir -p "$host/template"
    cp -R "$ORCA_HOST/template/config" "$host/template/config"

    run CONFIG_SYNC --project "$primary" --host "$host"
    [ "$status" -eq 0 ]

    settings="$primary/.claude-dev/home/.claude/settings.json"
    for name in tier-gate tier-reconcile tier-prime statusline; do
        grep -qF "\"$host/template/bin/$name\"" "$settings"
    done

    run cat "$settings"
    [[ "$output" != *"/usr/local/bin"* ]]
    [[ "$output" != *"/home/agent"* ]]
    [[ "$output" != *"/workspace"* ]]
}

@test "settings.local.json overlay is preserved and wins" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    dest="$primary/.claude-dev/home/.claude"
    mkdir -p "$dest"
    cat > "$dest/settings.local.json" <<'JSON'
{"model":"local-test-model","permissions":{"allow":["Bash(local-thing)"]}}
JSON
    local_before="$(cat "$dest/settings.local.json")"

    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]

    run jq -r '.model' "$dest/settings.json"
    [ "$output" = "local-test-model" ]
    run jq -e '.permissions.allow | index("Bash(local-thing)") != null' "$dest/settings.json"
    [ "$status" -eq 0 ]
    # base allowlist entries survive -- unioned, not replaced by the local one
    run jq -e '.permissions.allow | index("Bash(*)") != null' "$dest/settings.json"
    [ "$status" -eq 0 ]

    # the overlay FILE itself is preserved, byte-identical -- config-sync
    # only ever reads it, never rewrites or moves it
    [ "$(cat "$dest/settings.local.json")" = "$local_before" ]
}

@test "unchanged checksum → no rewrite; changed → rewrite" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    dest="$primary/.claude-dev/home/.claude"

    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    sum1="$(tree_checksum "$dest")"
    hash1="$(cat "$primary/.claude-dev/run/config-hash")"

    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    [ "$sum1" = "$(tree_checksum "$dest")" ]

    # prove it's a genuine skip, not a coincidental re-write of the same
    # bytes: plant a canary the sync would remove if it actually re-ran.
    echo canary > "$dest/agents/CANARY.md"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    [ -f "$dest/agents/CANARY.md" ]

    # now change the template config -> checksum changes -> a real rewrite
    echo "# changed" >> "$ORCA_HOST/template/config/claude-user-memory.md"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    [ ! -f "$dest/agents/CANARY.md" ]
    hash2="$(cat "$primary/.claude-dev/run/config-hash")"
    [ "$hash1" != "$hash2" ]
    diff "$ORCA_HOST/template/config/claude-user-memory.md" "$dest/CLAUDE.md"
}

# claude-orca-qa2.11: an OpenRouter worker inside the VM is an `opencode`
# terminal, and opencode reads its provider config from a file
# (OPENCODE_CONFIG, pointed at this path by seed-orca-state.sh). That file
# is template-owned like the rest of the agent home, so it is config-sync's
# to write -- under the same checksum gate, from config/opencode/.
@test "the home opencode config carries the OpenRouter provider and is synced from config/opencode" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    src="$ORCA_HOST/template/config/opencode/opencode.json"
    dest="$primary/.claude-dev/home/.config/opencode/opencode.json"

    # The source: real JSON, the OpenRouter provider, and the key read from
    # the env the VM already carries (claude-orca-qa2.7) -- never a literal
    # key. No `model`: the model is per worker, chosen on argv.
    [ -f "$src" ]
    run jq -e . "$src"
    [ "$status" -eq 0 ]
    [ "$(jq -r '."$schema"' "$src")" = "https://opencode.ai/config.json" ]
    [ "$(jq -r '.provider.openrouter.options.apiKey' "$src")" = "{env:OPENROUTER_API_KEY}" ]
    run jq -e 'has("model")' "$src"
    [ "$status" -ne 0 ]
    run grep -qE 'sk-[A-Za-z0-9]|or-v1-' "$src"
    [ "$status" -ne 0 ]

    rm -f "$PROJECT_DIR/.claude-dev/run/config-hash"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    [ -f "$dest" ]
    diff "$src" "$dest"

    # Gated like everything else: an unchanged template rewrites nothing...
    echo '// canary' >> "$dest"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    run grep -qF canary "$dest"
    [ "$status" -eq 0 ]

    # ...and a changed one is picked up, canary and all.
    jq '.provider.openrouter.options.baseURL = "https://example.invalid/api"' \
        "$src" > "$BATS_TEST_TMPDIR/opencode.json"
    mv "$BATS_TEST_TMPDIR/opencode.json" "$src"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    diff "$src" "$dest"
}

@test "grep gate: no script under scripts/ references ~/.claude literally" {
    # lib/paths.sh is the ONE designated exception -- every other script
    # goes through claude_config_dir() instead (see its own header).
    run grep -rnE '~/\.claude([^-]|$)|\$HOME/\.claude([^-]|$)' \
        --exclude=paths.sh "$REPO_ROOT/scripts"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "config-sync runs cleanly under bash 3.2 and still populates the config dir" {
    require_bash32() {
        [ -n "${BASH32:-}" ] && return 0
        . "$BATS_TEST_DIRNAME/helpers/ensure_bash32"
    }
    require_bash32

    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"

    run "$BASH32" "$ORCA_HOST/template/scripts/config-sync.sh" \
        --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    [ -f "$primary/.claude-dev/home/.claude/settings.json" ]
}
