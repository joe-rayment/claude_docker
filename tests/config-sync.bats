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
    # The harness's "user hasn't heard from you" nudge is off in every
    # folder: it only ever produced a filler line while workers ran.
    run jq -r '.env.CLAUDE_CODE_SILENT_TURN_REMINDER' "$dest/settings.json"
    [ "$output" = "false" ]
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

@test "bypass-permissions acceptance survives a full wholesale resync (claude-orca-az5)" {
    # provision.d/30-claude-first-run seeds skipDangerousModePermissionPrompt
    # into settings.json ONCE, right after the first config-sync -- but
    # config-sync itself is also invoked later and independently (the host
    # side's post-URL resync, or a typed /config-resync), and its rewrite
    # (`sed ... "$TEMPLATE_CONFIG/claude-settings.json" >
    # "$CONFIG_DIR/settings.json"`) is a wholesale overwrite from the
    # template, not a merge with what is already on disk. A key seeded only
    # by the provision step and absent from the template itself is wiped
    # out by that second sync, and Claude Code shows the interactive
    # Bypass Permissions dialog again -- which an unattended Orca worker
    # cannot answer, so worker-start sees the process die. The key belongs
    # in the template so every rewrite, not just the first, carries it.
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    dest="$primary/.claude-dev/home/.claude"

    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    run jq -r '.skipDangerousModePermissionPrompt' "$dest/settings.json"
    [ "$output" = "true" ]

    # Force a second, unconditional sync -- the checksum gate would
    # otherwise mask a template-only regression by skipping the rewrite.
    rm -f "$primary/.claude-dev/run/config-hash"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    run jq -r '.skipDangerousModePermissionPrompt' "$dest/settings.json"
    [ "$output" = "true" ]

    # settings.local.json remains the one sanctioned override channel: a
    # folder that wants the dialog back can still ask for it explicitly.
    cat > "$dest/settings.local.json" <<'JSON'
{"skipDangerousModePermissionPrompt": false}
JSON
    rm -f "$primary/.claude-dev/run/config-hash"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    run jq -r '.skipDangerousModePermissionPrompt' "$dest/settings.json"
    [ "$output" = "false" ]
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
@test "the home opencode config pins no provider and is synced from config/opencode" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    src="$ORCA_HOST/template/config/opencode/opencode.json"
    dest="$primary/.claude-dev/home/.config/opencode/opencode.json"

    # The source: real JSON, and NO provider override at all (2c3c003).
    # It used to pin provider.openrouter.options.baseURL at the guard on
    # 127.0.0.1:4141 for every folder, whether or not a guard would ever
    # answer there -- and on a fresh folder none does, so opencode's every
    # call was ECONNREFUSED on loopback and read as a network fault. The
    # guard is not gone; it is no longer assumed. Re-pinning it is
    # claude-orca-bqj's switch, and this case is what fails if the pin
    # creeps back in by default.
    # No `model` either: the model is per worker, chosen on argv.
    [ -f "$src" ]
    run jq -e . "$src"
    [ "$status" -eq 0 ]
    [ "$(jq -r '."$schema"' "$src")" = "https://opencode.ai/config.json" ]
    run jq -e 'has("provider")' "$src"
    [ "$status" -ne 0 ]
    run grep -qF '4141' "$src"
    [ "$status" -ne 0 ]
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

# The rulebook (config/claude-user-memory.md) tells the agent to TYPE
# `lane`, `tier-set`, `orca-dispatch` and friends, and the hook entries in
# config/claude-settings.json run those same files by absolute path out of
# the template's bin/. Nothing else put that directory on PATH, so every
# one of those names resolved to nothing inside a real container and the
# first line of every session ("lane standard …") died with
# "command not found". This pins the shipped .zshrc as the thing that
# closes that gap, and pins the folder's own clone winning over the
# image's baked copy.
@test "the shipped .zshrc puts the template's bin/ on PATH so the rulebook's CLIs are typeable" {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"

    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    rm -f "$PROJECT_DIR/.claude-dev/run/config-hash"

    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]

    zshrc="$primary/.claude-dev/home/.zshrc"
    [ -f "$zshrc" ]

    run env HOME="$primary/.claude-dev/home" CLAUDE_ORCA_HOST_DIR="$ORCA_HOST" \
        zsh -c ". \"\$HOME/.zshrc\" >/dev/null 2>&1; printf '%s\n' \"\$PATH\""
    [ "$status" -eq 0 ]

    # The folder's own clone, not the image's baked /opt/claude-orca/bin.
    case ":$output:" in
        *":$ORCA_HOST/template/bin:"*) ;;
        *) printf 'template bin/ absent from PATH: %s\n' "$output"; return 1 ;;
    esac

    # …and every CLI the rulebook names by bare word is actually there.
    for cli in lane tier-set orca-dispatch orca-wait orca-reply delegate; do
        [ -x "$ORCA_HOST/template/bin/$cli" ] || {
            printf 'missing template bin/%s\n' "$cli"; return 1
        }
    done
}

# 2026-09-08: the image's baked /opt/claude-orca copy of config/ is frozen
# at image build time, so on the prebuilt path the CLIs the rulebook names
# by bare word resolved to whatever the repo said the day the image was
# published -- `/tier auth openrouter` was committed, live in the folder,
# and still "unknown verb" in the session. The folder's clone comes first
# now, on PATH as well as in the sync source.
@test "the shipped .zshrc prefers the folder's template bin/ over the image's baked copy" {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"

    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    rm -f "$PROJECT_DIR/.claude-dev/run/config-hash"

    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]

    # Two candidates, the way a prebuilt image really presents them: the
    # folder's own clone (ORCA_HOST is <project>/.claude-dev here) and a
    # separate host dir standing in for /opt/claude-orca-host.
    folder_bin="$primary/.claude-dev/template/bin"
    image_host="$BATS_TEST_TMPDIR/image-host"
    mkdir -p "$folder_bin" "$image_host/template/bin"

    run env HOME="$primary/.claude-dev/home" PROJECT_DIR="$primary" \
        CLAUDE_ORCA_HOST_DIR="$image_host" \
        zsh -c ". \"\$HOME/.zshrc\" >/dev/null 2>&1; printf '%s\n' \"\$PATH\""
    [ "$status" -eq 0 ]

    # The .zshrc prepends exactly one template bin/, so the head of PATH is
    # the whole assertion: the folder's, never the image's.
    [ "${output%%:*}" = "$folder_bin" ] || {
        printf 'PATH head is %s, want %s\n' "${output%%:*}" "$folder_bin"
        return 1
    }
}
