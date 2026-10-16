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

# claude-orca-3tc: the template's settings are the whole default surface a
# new folder starts from, so the top-level keys are pinned exactly -- a key
# may not appear or vanish without this case naming it. Inline prompt
# suggestions are off by default, twice over: promptSuggestionEnabled: false,
# and env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false -- Claude Code 2.1.288
# checks that variable before the setting, and its jJt() gate is what a
# host (the claude.ai remote view) passes through to switch suggestions on
# mid-session (2026-10-03: they came back with the setting alone). A folder
# that wants them back overrides both through settings.local.json, the way
# the skipDangerousModePermissionPrompt case below proves for its own key.
@test "the template's claude-settings.json pins its exact top-level keys, prompt suggestions off" {
    run jq -r 'keys | sort | join(",")' "$REPO_ROOT/config/claude-settings.json"
    [ "$status" -eq 0 ]
    [ "$output" = "enableAllProjectMcpServers,env,hooks,model,permissions,promptSuggestionEnabled,respondToBashCommands,skipDangerousModePermissionPrompt,statusLine,subagentPromptCacheTtl,subagentStatusLine" ]
    run jq -r '.promptSuggestionEnabled' "$REPO_ROOT/config/claude-settings.json"
    [ "$output" = "false" ]
    run jq -r '.env.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION' "$REPO_ROOT/config/claude-settings.json"
    [ "$output" = "false" ]
}

# claude-orca-ngq.2: the main-session off-ramp is wired like context-meter --
# one bin/offramp entry per hook event, each guarded by [ -x ] so the wiring
# stands alone while the sibling slice builds bin/offramp -- plus the compaction
# env vars that make Claude Code compact at 50% of any model's window (without
# CLAUDE_CODE_AUTO_COMPACT_WINDOW it never compacts until the window is full).
# Guards: the template's settings carry both env vars, and exactly one
# offramp hook entry per event with its flag (--post, --pre, --session-start, --stop).
# Fails if: an env var is renamed or retuned, an offramp entry is dropped,
# duplicated, or its flag changed.
# Run: bats -f 'off-ramp wiring' tests/config-sync.bats
@test "off-ramp wiring: compaction env and one offramp entry per hook event" {
    settings="$REPO_ROOT/config/claude-settings.json"
    run jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$settings"
    [ "$output" = "1000000" ]
    run jq -r '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' "$settings"
    [ "$output" = "50" ]

    for spec in "PostToolUse --post" "PreToolUse --pre" "SessionStart --session-start" "Stop --stop"; do
        set -- $spec
        event="$1"; flag="$2"
        run jq -c "[.hooks.$event[].hooks[] | select(.command | contains(\"bin/offramp\"))]" "$settings"
        [ "$status" -eq 0 ]
        [ "$(jq 'length' <<<"$output")" = "1" ]
        run jq -r "[.hooks.$event[].hooks[] | select(.command | contains(\"bin/offramp\"))][0].command" "$settings"
        [[ "$output" == *" $flag"* ]]
    done
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

# claude-orca-qxc: skills/ is no longer mirrored wholesale. The template's
# own skills are; everything else in there -- the home-scope orchestration
# link provision.d/75-orca-skills creates, Claude Code's own 'synced'
# directory -- is not this script's to remove. The previous sync's shipped
# entries are recorded in skills/.claude-orca-shipped (one name per line),
# which is what still lets a template drop remove its own leftovers.
@test "a skill entry config-sync did not ship survives a resync (claude-orca-qxc)" {
    # Guards: the home-scope orchestration install and Claude Code's own
    # 'synced' skills directory survive every later config-sync -- skills/
    # entries that are neither template-shipped nor previously-shipped are
    # preserved, the way Orca's managed hook entries are.
    # Fails if: any resync rm -rf's skills/ wholesale and wipes the
    # ~/.claude/skills link the Orca panel's agent coverage reads.
    # Run: bats -f 'survives a resync' tests/config-sync.bats
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    dest="$primary/.claude-dev/home/.claude"

    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]

    # Foreign entries, the way the container really has them: a symlink
    # into ~/.agents/skills (what `orca skills install` leaves) and the
    # directory Claude Code's skill sync manages.
    ln -s "$primary/.claude-dev/home/.agents/skills/orchestration" \
        "$dest/skills/orchestration"
    mkdir -p "$dest/skills/synced"
    : > "$dest/skills/synced/marker.txt"

    rm -f "$primary/.claude-dev/run/config-hash"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]

    [ -L "$dest/skills/orchestration" ]
    [ -f "$dest/skills/synced/marker.txt" ]
    # the shipped skill is still mirrored alongside them
    [ -f "$dest/skills/snowpark-deploy/SKILL.md" ]
}

@test "a skill the template shipped last sync but no longer ships is removed (claude-orca-qxc)" {
    # Guards: the .claude-orca-shipped manifest -- ownership is what the
    # previous sync shipped, so a skill dropped from the template is still
    # cleaned up even though skills/ is no longer wiped.
    # Fails if: a dropped-from-template skill lingers forever, or the
    # manifest is not rewritten after the copy.
    # Run: bats -f 'no longer ships' tests/config-sync.bats
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    dest="$primary/.claude-dev/home/.claude"

    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    [ -f "$dest/skills/snowpark-deploy/SKILL.md" ]
    grep -qx "snowpark-deploy" "$dest/skills/.claude-orca-shipped"

    # the template drops it, then the folder syncs again
    rm -rf "$ORCA_HOST/template/config/skills/snowpark-deploy"
    rm -f "$primary/.claude-dev/run/config-hash"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]

    [ ! -e "$dest/skills/snowpark-deploy" ]
    # ...and the manifest no longer claims it (a run-grep, never a bare
    # failing command, so the negative assertion is the status check itself)
    run grep -qx "snowpark-deploy" "$dest/skills/.claude-orca-shipped"
    [ "$status" -eq 1 ]
}

@test "a shipped skill's content is replaced by the template's on resync (claude-orca-qxc)" {
    # Guards: preserving foreign entries must not freeze shipped content --
    # an entry the template still ships is removed and re-copied, so
    # template edits land in the folder.
    # Fails if: the preserve change leaves a stale on-disk copy of a
    # shipped skill.
    # Run: bats -f "content is replaced" tests/config-sync.bats
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    dest="$primary/.claude-dev/home/.claude"

    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]

    printf '\n# template update\n' \
        >> "$ORCA_HOST/template/config/skills/snowpark-deploy/SKILL.md"
    rm -f "$primary/.claude-dev/run/config-hash"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]

    diff "$ORCA_HOST/template/config/skills/snowpark-deploy/SKILL.md" \
        "$dest/skills/snowpark-deploy/SKILL.md"
    grep -qx "snowpark-deploy" "$dest/skills/.claude-orca-shipped"
}

# claude-orca-9bh.13: Orca no longer writes into the folder's settings.json,
# and config-sync no longer carries its entries across a rewrite. A folder an
# older Orca already wrote into is cleaned on its next sync.

# Number of commands under /.orca/agent-hooks/ anywhere in settings file $1
# (hook entries and the statusLine alike).
orca_command_count() {
    jq '[.. | .command? // empty | select(type == "string" and contains("/.orca/agent-hooks/"))] | length' "$1"
}

# Put Orca's managed hook entries and its statusLine chain into the rendered
# settings file $1, the way Orca's installer did with HOME inside the folder:
# its entries appended after ours per event, its statusline command first and
# ours second, plus the chain's remembered base file. The bytes come from
# tests/fixtures/orca/ (Orca's own).
plant_orca_entries() {
    local f="$1" fixture="$BATS_TEST_DIRNAME/fixtures/orca/claude-settings-with-orca.json"
    jq -s '
        .[0] as $ours | .[1] as $orca
        | $ours
        | .hooks = (reduce ($orca.hooks | keys[]) as $e ((.hooks // {});
              .[$e] = ((.[$e] // []) + $orca.hooks[$e])))
        | .statusLine.command = ($orca.statusLine.command + "\n" + $ours.statusLine.command)
    ' "$f" "$fixture" > "$f.planted"
    mv "$f.planted" "$f"
    printf '%s' "$(jq -r '.statusLine.command' "$f" | tail -n 1)" \
        > "$(dirname "$f")/.orca-statusline-base"
}

# Guards:   a settings.json holding Orca's hook entries and statusLine chain
#           comes out as exactly our rendered template after a sync that a
#           template change forces: no command under /.orca/agent-hooks/, our
#           statusLine, every hook command we ship still there, the old
#           chain-base file gone.
# Fails if: config-sync goes back to re-attaching Orca's entries (or its
#           statusLine chain) after rendering, or leaves .orca-statusline-base.
# Run:      bats -f 'Orca-laden settings.json is re-rendered clean on a template change' tests/config-sync.bats
@test "an Orca-laden settings.json is re-rendered clean on a template change (claude-orca-9bh.13)" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    dest="$primary/.claude-dev/home/.claude"

    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    cp "$dest/settings.json" "$BATS_TEST_TMPDIR/rendered.json"
    plant_orca_entries "$dest/settings.json"
    [ "$(orca_command_count "$dest/settings.json")" -gt 12 ]
    [ -f "$dest/.orca-statusline-base" ]

    echo "# changed" >> "$ORCA_HOST/template/config/claude-user-memory.md"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]

    [ "$(orca_command_count "$dest/settings.json")" -eq 0 ]
    [ ! -e "$dest/.orca-statusline-base" ]
    [ "$(jq -c '.statusLine' "$dest/settings.json")" = "$(jq -c '.statusLine' "$BATS_TEST_TMPDIR/rendered.json")" ]
    # The folder's file is the rendered template again, byte for byte.
    diff <(jq -S . "$BATS_TEST_TMPDIR/rendered.json") <(jq -S . "$dest/settings.json")
    # ... which in particular still has every hook command the template ships.
    while IFS= read -r cmd; do
        run jq -e --arg c "$cmd" '[.hooks[][].hooks[].command] | index($c) != null' "$dest/settings.json"
        [ "$status" -eq 0 ]
    done < <(jq -r '.hooks[][].hooks[].command' "$BATS_TEST_TMPDIR/rendered.json")
}

# Guards:   the migration for folders whose template did not change: an
#           unchanged config hash must not let Orca's planted entries stay.
# Fails if: the checksum gate exits early on a matching hash without looking
#           at the settings.json that is on disk.
# Run:      bats -f 'Orca entries are stripped even when the template hash is unchanged' tests/config-sync.bats
@test "Orca entries are stripped even when the template hash is unchanged (claude-orca-9bh.13)" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    dest="$primary/.claude-dev/home/.claude"

    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    cp "$dest/settings.json" "$BATS_TEST_TMPDIR/rendered.json"
    hash1="$(cat "$primary/.claude-dev/run/config-hash")"
    plant_orca_entries "$dest/settings.json"
    [ "$(orca_command_count "$dest/settings.json")" -gt 12 ]

    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    [ "$hash1" = "$(cat "$primary/.claude-dev/run/config-hash")" ]
    [ "$(orca_command_count "$dest/settings.json")" -eq 0 ]
    [ ! -e "$dest/.orca-statusline-base" ]
    diff <(jq -S . "$BATS_TEST_TMPDIR/rendered.json") <(jq -S . "$dest/settings.json")

    # Planting again after the clean-up is cleaned again: not a one-shot.
    plant_orca_entries "$dest/settings.json"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    [ "$(orca_command_count "$dest/settings.json")" -eq 0 ]
}

# Guards:   the stripping above costs a clean folder nothing: its second sync
#           is still the fast no-op, settings.json is not rewritten.
# Fails if: the "has Orca entries" check makes every sync re-render (the file's
#           mtime moves) or removes the early exit for clean folders.
# Run:      bats -f "a clean folder's second sync still does not rewrite settings.json" tests/config-sync.bats
@test "a clean folder's second sync still does not rewrite settings.json (claude-orca-9bh.13)" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    dest="$primary/.claude-dev/home/.claude"

    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    [ "$(orca_command_count "$dest/settings.json")" -eq 0 ]

    # A rewrite would stamp the file with now(); push it far into the past
    # and compare against a marker that is newer than that but older than now.
    touch -t 200101010000 "$dest/settings.json"
    touch -t 200201010000 "$BATS_TEST_TMPDIR/marker"
    run CONFIG_SYNC --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    [ -z "$(find "$dest/settings.json" -newer "$BATS_TEST_TMPDIR/marker")" ]
}
