#!/usr/bin/env bats

# plugin-build.bats — scripts/build-plugin.sh regenerates /workspace/plugin/
# (a Claude Code plugin tree) from the existing config/ sources: a
# .claude-plugin/plugin.json manifest, agents/ (config/agents/*.md),
# skills/ (config/skills/snowpark-deploy verbatim, plus tier and code-map
# converted from config/claude-commands/*.md command-passthroughs into
# SKILL.md form), hooks/hooks.json (derived from config/claude-settings.json's
# "hooks" block), and bin/ (the PATH scripts those hooks invoke via
# `command -v <name>`, resolved through the Dockerfile's COPY mapping that
# scripts/image-drift.py's copy_entries() already owns as the single
# source of truth). See beads_claude_docker-fo2.
#
# FROZEN per fo2's acceptance contract from its RED commit until fo2's own
# verification completed — fo2 is CLOSED with VERIFIED: PASS (see its bead
# notes), so that window has elapsed. The bin/ set below was subsequently
# widened by beads_claude_docker-nmnb (cs-new) and beads_claude_docker-f5i6
# (fleet-menu) — standalone CLI tools the plugin ships in bin/ without
# being hook-invoked; see build-plugin.sh's STANDALONE_NAMES for why the
# "hooks invoke via `command -v`" bin/ description below no longer covers
# 100% of bin/'s contents.
#
# The CLI form asserted here (`claude --plugin-dir <path> plugin details
# <name>`) was discovered empirically against the installed CLI (2.1.247):
# `claude plugin details <name>` alone only resolves plugins already
# registered by name (installed, or under ~/.claude/skills/) — a bare path
# argument is rejected with "not found ... pass --plugin-dir <path>". The
# global `--plugin-dir <path>` flag (placed before the `plugin` subcommand)
# loads an arbitrary directory for the session and makes it resolvable by
# its manifest's own "name" field, exiting 0 with a component inventory —
# confirmed working against a path outside ~/.claude/skills too.

REPO_ROOT=/workspace
BUILD_SCRIPT="$REPO_ROOT/scripts/build-plugin.sh"
PLUGIN_DIR="$REPO_ROOT/plugin"
SETTINGS="$REPO_ROOT/config/claude-settings.json"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

# ── manifest ────────────────────────────────────────────────────────────

@test "plugin-build: .claude-plugin/plugin.json exists" {
    [ -f "$PLUGIN_DIR/.claude-plugin/plugin.json" ]
}

@test "plugin-build: manifest name is claude-dev" {
    run jq -r '.name' "$PLUGIN_DIR/.claude-plugin/plugin.json"
    [ "$status" -eq 0 ]
    [ "$output" = "claude-dev" ]
}

@test "plugin-build: manifest version is present and semver-shaped" {
    run jq -r '.version' "$PLUGIN_DIR/.claude-plugin/plugin.json"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# ── agents/ ─────────────────────────────────────────────────────────────

@test "plugin-build: agents/ carries all 6 agent defs" {
    run bash -c "ls '$PLUGIN_DIR/agents' | sort"
    [ "$status" -eq 0 ]
    expected=$'bead-auditor.md\nexecutor.md\noracle.md\nprofessor.md\nscout.md\nverifier.md'
    [ "$output" = "$expected" ]
}

@test "plugin-build: agents/executor.md matches config/agents/executor.md byte-for-byte" {
    diff -q "$PLUGIN_DIR/agents/executor.md" "$REPO_ROOT/config/agents/executor.md"
}

# ── skills/ ─────────────────────────────────────────────────────────────

@test "plugin-build: skills/snowpark-deploy/SKILL.md exists and matches source" {
    diff -q "$PLUGIN_DIR/skills/snowpark-deploy/SKILL.md" "$REPO_ROOT/config/skills/snowpark-deploy/SKILL.md"
}

@test "plugin-build: skills/tier/SKILL.md exists with name+description frontmatter only" {
    [ -f "$PLUGIN_DIR/skills/tier/SKILL.md" ]
    run head -1 "$PLUGIN_DIR/skills/tier/SKILL.md"
    [ "$output" = "---" ]
    run grep -c '^name:' "$PLUGIN_DIR/skills/tier/SKILL.md"
    [ "$output" -eq 1 ]
    ! grep -q '^model:' "$PLUGIN_DIR/skills/tier/SKILL.md"
    ! grep -q '^allowed-tools:' "$PLUGIN_DIR/skills/tier/SKILL.md"
}

@test "plugin-build: skills/code-map/SKILL.md exists with name+description frontmatter only" {
    [ -f "$PLUGIN_DIR/skills/code-map/SKILL.md" ]
    run head -1 "$PLUGIN_DIR/skills/code-map/SKILL.md"
    [ "$output" = "---" ]
    run grep -c '^name:' "$PLUGIN_DIR/skills/code-map/SKILL.md"
    [ "$output" -eq 1 ]
    ! grep -q '^model:' "$PLUGIN_DIR/skills/code-map/SKILL.md"
}

# ── hooks/hooks.json ────────────────────────────────────────────────────

@test "plugin-build: hooks/hooks.json exists and is valid JSON" {
    run jq empty "$PLUGIN_DIR/hooks/hooks.json"
    [ "$status" -eq 0 ]
}

@test "plugin-build: hooks/hooks.json event-name set matches config/claude-settings.json's hooks block" {
    run bash -c "jq -S '.hooks | keys' '$PLUGIN_DIR/hooks/hooks.json'"
    [ "$status" -eq 0 ]
    plugin_keys="$output"
    run bash -c "jq -S '.hooks | keys' '$SETTINGS'"
    [ "$status" -eq 0 ]
    [ "$plugin_keys" = "$output" ]
}

@test "plugin-build: hooks/hooks.json is non-empty (actual hook commands carried over)" {
    run jq '[.hooks[][].hooks[].command] | length' "$PLUGIN_DIR/hooks/hooks.json"
    [ "$status" -eq 0 ]
    [ "$output" -gt 0 ]
}

# ── bin/ ────────────────────────────────────────────────────────────────

@test "plugin-build: bin/ carries exactly the hook-invoked scripts plus the declared standalone set" {
    run bash -c "ls '$PLUGIN_DIR/bin' | sort"
    [ "$status" -eq 0 ]
    expected=$'bd-guard\ncode-map-prime\ncontext-detect\ncontract-gate\ncost-mirror\ncs-new\ndelegation-gate\ndisk-cleanup\nfleet\nfleet-menu\nimage-drift\nlane\noutbound-guard\npeers\nprime-memories\nsession-end-audit\nsession-title\ntier-gate\ntier-prime\ntier-reconcile\nworkflow-lint'
    [ "$output" = "$expected" ]
}

@test "plugin-build: every bin/ script is executable" {
    run bash -c "find '$PLUGIN_DIR/bin' -maxdepth 1 -type f ! -perm -u+x"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "plugin-build: bin/cost-mirror is the python cost-mirror script (extension-less PATH name)" {
    run head -1 "$PLUGIN_DIR/bin/cost-mirror"
    [ "$output" = "#!/usr/bin/env python3" ]
}

# ── CLI verification: claude plugin details against the built tree ────────

@test "plugin-build: claude --plugin-dir <built tree> plugin details claude-dev exits 0" {
    run claude --plugin-dir "$PLUGIN_DIR" plugin details claude-dev
    [ "$status" -eq 0 ]
}

@test "plugin-build: claude plugin details inventory names agents, skills and hooks" {
    run claude --plugin-dir "$PLUGIN_DIR" plugin details claude-dev
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skills ("* ]]
    [[ "$output" == *"Agents ("* ]]
    [[ "$output" == *"Hooks ("* ]]
    [[ "$output" == *"snowpark-deploy"* ]]
    [[ "$output" == *"tier"* ]]
    [[ "$output" == *"code-map"* ]]
}

@test "plugin-build: claude plugin validate accepts the built tree" {
    run claude plugin validate "$PLUGIN_DIR"
    [ "$status" -eq 0 ]
}

# ── idempotence ─────────────────────────────────────────────────────────

@test "plugin-build: running build-plugin.sh a second time produces no diff" {
    run bash -c "find '$PLUGIN_DIR' -type f | sort | xargs sha256sum | sort -k2"
    [ "$status" -eq 0 ]
    before="$output"
    run bash "$BUILD_SCRIPT"
    [ "$status" -eq 0 ]
    run bash -c "find '$PLUGIN_DIR' -type f | sort | xargs sha256sum | sort -k2"
    [ "$status" -eq 0 ]
    [ "$output" = "$before" ]
}
