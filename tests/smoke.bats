#!/usr/bin/env bats

# Smoke tests — verify the container environment is correctly set up
# These run without tmux and check static properties

setup() {
    # Route every mktemp/scratch dir under bats's per-test tmpdir, which bats
    # removes at the end of the run on PASS *or* FAIL. Without this, a test that
    # aborts on a failed assertion before its inline `rm -rf` leaks its temp
    # dir — and some hold a ~2.4M `bd init` Dolt DB, so red iteration runs pile
    # up multi-MB leftovers. See scripts/disk-cleanup.sh for the safety net.
    export TMPDIR="$BATS_TEST_TMPDIR"
}

@test "scripts are present and executable" {
    [ -x /usr/local/bin/entrypoint.sh ]
    [ -x /usr/local/bin/container-welcome ]
    [ -x /usr/local/bin/guided-setup.sh ]
    [ -x /usr/local/bin/detect-dependencies.sh ]
    [ -x /usr/local/bin/view-logs ]
    [ -x /usr/local/bin/dev-log ]
    [ -x /usr/local/bin/run-tests.sh ]
}

@test "key binaries are installed" {
    command -v claude
    command -v git
    command -v gh
    command -v node
    command -v python3
    command -v go
    command -v hx
    command -v jq
    command -v bats
    command -v bd
}

@test "config checksum can be computed from staged configs" {
    [ -d /etc/claude-dev/configs ]
    local hash
    hash=$(find /etc/claude-dev/configs -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum | cut -d' ' -f1)
    [ -n "$hash" ]
}

@test "staged configs exist for version-sync" {
    [ -f /etc/claude-dev/configs/.zshrc ]
    [ -f /etc/claude-dev/configs/helix-config.toml ]
    [ -f /etc/claude-dev/configs/intellishell-config.toml ]
    [ -f /etc/claude-dev/configs/intellishell-defaults.txt ]
    [ -f /etc/claude-dev/configs/claude-settings.json ]
}

@test "claude-settings.json is valid JSON with agent teams config" {
    local settings="/etc/claude-dev/configs/claude-settings.json"
    jq empty "$settings"
    jq -e '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS == "1"' "$settings"
}

@test "zshrc aliases are defined" {
    # cs is a function (tmux wrapper), not an alias
    grep -qE '^(alias cs=|cs\(\))' /etc/claude-dev/configs/.zshrc
    grep -q 'alias menu=' /etc/claude-dev/configs/.zshrc
    grep -q 'alias dlog=' /etc/claude-dev/configs/.zshrc
    grep -q 'alias cse=' /etc/claude-dev/configs/.zshrc
}

@test "csearch is present and works in all modes" {
    [ -x /usr/local/bin/csearch ]
    local dir="$BATS_TEST_TMPDIR/csearch-test"
    mkdir -p "$dir"
    printf 'def foo(x):\n    return x\nclass Bar:\n    pass\n' > "$dir/sample.py"
    # find: literal-path content search
    csearch "return x" "$dir/sample.py" | grep -q 'return x'
    # files-only mode
    [ "$(csearch -l "class Bar" "$dir/sample.py")" = "$dir/sample.py" ]
    # read range
    csearch read "$dir/sample.py" 1-1 | grep -q 'def foo'
    # sig mode
    csearch sig "$dir/sample.py" | grep -q 'def foo'
    # no match exits 0 (not an error)
    csearch "zzz_nomatch_zzz" "$dir/sample.py"
    rm -rf "$dir"
}

@test "no voicetree references in scripts" {
    ! grep -ri 'voicetree' /usr/local/bin/container-welcome
    ! grep -ri 'voicetree' /usr/local/bin/guided-setup.sh
    ! grep -ri 'voicetree' /etc/claude-dev/configs/.zshrc
    ! grep -ri 'voicetree' /etc/claude-dev/configs/intellishell-defaults.txt
}

@test "user is agent with correct home" {
    [ "$(whoami)" = "agent" ]
    [ "$HOME" = "/home/agent" ]
}

@test "dev-log creates log directory and writes entries" {
    local marker="smoketest-run-$$-$RANDOM"
    dev-log run "echo test" pass "$marker"
    [ -f /workspace/.claude/logs/runs.log ]
    grep -q "$marker" /workspace/.claude/logs/runs.log
}

@test "dev-log decision subcommand works" {
    local marker="smoketest-decision-$$-$RANDOM"
    dev-log decision "$marker"
    run dev-log show decisions 5
    [[ "$output" == *"$marker"* ]]
}

@test "dev-log error subcommand works" {
    local marker="smoketest-error-$$-$RANDOM"
    dev-log error "$marker" "test detail"
    run dev-log show errors 5
    [[ "$output" == *"$marker"* ]]
}

@test "dev-log change subcommand works" {
    local marker="smoketest-change-$$-$RANDOM"
    dev-log change "$marker" "test reason"
    run dev-log show changes 5
    [[ "$output" == *"$marker"* ]]
}

@test "detect-dependencies runs without error" {
    run detect-dependencies.sh
    [ "$status" -eq 0 ]
}

@test "detect-dependencies --json produces valid JSON" {
    run detect-dependencies.sh --json
    [ "$status" -eq 0 ]
    echo "$output" | jq . >/dev/null 2>&1
}

@test "detect-dependencies --count returns a number" {
    run detect-dependencies.sh --count
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "run-tests.sh accepts smoke argument" {
    # Point TEST_DIR at a nonexistent path: 'smoke' must be accepted (we reach
    # the dir check, not usage) WITHOUT spawning a real nested suite — the old
    # version ran the full baked suite recursively and stalled the run for minutes.
    # Pre-rebuild images ship a run-tests.sh that IGNORES CLAUDE_DEV_TESTS and
    # would recurse anyway — skip rather than detonate.
    grep -q 'CLAUDE_DEV_TESTS' "$(command -v run-tests.sh)" \
        || skip "installed run-tests.sh predates CLAUDE_DEV_TESTS (stale image)"
    run env CLAUDE_DEV_TESTS=/nonexistent-claude-dev-tests run-tests.sh smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
    [[ "$output" != *"Usage"* ]]
}

@test "run-tests.sh rejects unknown suite with usage" {
    grep -q 'CLAUDE_DEV_TESTS' "$(command -v run-tests.sh)" \
        || skip "installed run-tests.sh predates CLAUDE_DEV_TESTS (stale image)"
    # The dir must exist (validated before the suite arg) but be empty, so no
    # suite can possibly run; the bogus suite name must then hit the Usage path.
    local empty
    empty=$(mktemp -d)
    run env CLAUDE_DEV_TESTS="$empty" run-tests.sh bogus-suite
    rmdir "$empty"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "bd binary is installed" {
    command -v bd
}

@test "no voicetree references in mcp config" {
    if [ -f /workspace/.mcp.json ]; then
        run grep -i voicetree /workspace/.mcp.json
        [ "$status" -ne 0 ]
    fi
}

@test "screenshot tools are installed" {
    command -v Xvfb
    command -v import
    command -v termshot
}

@test "playwright CLI works offline (global install or npx cache)" {
    if command -v playwright >/dev/null 2>&1; then
        run playwright --version
    else
        run npx --no-install playwright --version
    fi
    [ "$status" -eq 0 ]
}

@test "take-screenshot script is present and executable" {
    [ -x /usr/local/bin/take-screenshot ]
}

@test "take-screenshot shows help with no arguments" {
    run take-screenshot
    [ "$status" -eq 0 ]
    [[ "$output" == *"url"* ]]
    [[ "$output" == *"display"* ]]
    [[ "$output" == *"term"* ]]
}

@test "chromium browser is available for playwright" {
    if command -v playwright >/dev/null 2>&1; then
        run playwright install --dry-run chromium
    else
        run npx --no-install playwright install --dry-run chromium
    fi
    [ "$status" -eq 0 ]
}

@test "zshrc has screenshot aliases" {
    grep -q 'alias screenshot=' /etc/claude-dev/configs/.zshrc
    grep -q 'alias ss=' /etc/claude-dev/configs/.zshrc
}

@test "claude-settings.json includes beads SessionStart hook" {
    local settings="/etc/claude-dev/configs/claude-settings.json"
    jq -e '.hooks.SessionStart[0].hooks[0].command == "bd prime"' "$settings"
}

@test "claude-settings.json includes beads PreCompact hook" {
    local settings="/etc/claude-dev/configs/claude-settings.json"
    jq -e '.hooks.PreCompact[0].hooks[0].command == "bd prime"' "$settings"
}

@test ".claude-dev runtime clone has no manual edits to tracked files" {
    # .claude-dev/ updates via git pull; manual edits to tracked files break that flow
    [ -d /workspace/.claude-dev/.git ] || skip "no runtime clone"
    local dirty
    dirty=$(git -C /workspace/.claude-dev status --porcelain | grep -v '^??' || true)
    [ -z "$dirty" ]
}

@test "settings.local.json merge unions permission arrays" {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo '{"model":"opus","permissions":{"allow":["Bash(ls)"],"deny":["Bash(rm -rf /)"]}}' > "$tmpdir/settings.json"
    echo '{"permissions":{"allow":["Bash(npm test)","Bash(ls)"]},"env":{"B":"2"}}' > "$tmpdir/settings.local.json"
    local src=/workspace/scripts/entrypoint.sh
    [ -f "$src" ] || src=/usr/local/bin/entrypoint.sh
    source <(sed -n '/^merge_claude_settings_local()/,/^}/p' "$src")
    type merge_claude_settings_local >/dev/null 2>&1 || skip "entrypoint predates merge function"
    merge_claude_settings_local "$tmpdir/settings.json" "$tmpdir/settings.local.json"
    jq -e '.permissions.allow | length == 2' "$tmpdir/settings.json"
    jq -e '.permissions.allow | index("Bash(npm test)")' "$tmpdir/settings.json"
    jq -e '.permissions.allow | index("Bash(ls)")' "$tmpdir/settings.json"
    jq -e '.permissions.deny == ["Bash(rm -rf /)"]' "$tmpdir/settings.json"
    jq -e '.env.B == "2"' "$tmpdir/settings.json"
    jq -e '.model == "opus"' "$tmpdir/settings.json"
    rm -rf "$tmpdir"
}

@test "settings.local.json merge skips and warns on invalid JSON" {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo '{"model":"opus"}' > "$tmpdir/settings.json"
    echo '{bad json' > "$tmpdir/settings.local.json"
    local src=/workspace/scripts/entrypoint.sh
    [ -f "$src" ] || src=/usr/local/bin/entrypoint.sh
    source <(sed -n '/^merge_claude_settings_local()/,/^}/p' "$src")
    type merge_claude_settings_local >/dev/null 2>&1 || skip "entrypoint predates merge function"
    run merge_claude_settings_local "$tmpdir/settings.json" "$tmpdir/settings.local.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"invalid JSON"* ]]
    jq -e '.model == "opus"' "$tmpdir/settings.json"
    rm -rf "$tmpdir"
}

@test "beads database is healthy (bd doctor)" {
    [ -d /workspace/.beads ] || skip "no beads workspace"
    bd doctor >/dev/null 2>&1 || bd doctor --fix --yes
}

@test "bd init creates a working embedded-dolt workspace" {
    local tmpdir
    tmpdir=$(mktemp -d)
    git -C "$tmpdir" init -q
    (cd "$tmpdir" && timeout 60 bd init --prefix=tst >/dev/null 2>&1)
    [ -d "$tmpdir/.beads/embeddeddolt" ]
    [ -f "$tmpdir/.beads/config.yaml" ]
    rm -rf "$tmpdir"
}

@test "staged agents include model-tiered oracle and scout" {
    [ -f /etc/claude-dev/configs/agents/oracle.md ]
    [ -f /etc/claude-dev/configs/agents/scout.md ]
    grep -q '^model: inherit' /etc/claude-dev/configs/agents/oracle.md
    grep -q '^model: haiku' /etc/claude-dev/configs/agents/scout.md
}

@test "professor agent runs on sonnet" {
    grep -q '^model: sonnet' /etc/claude-dev/configs/agents/professor.md
}

@test "claude-settings.json pins the advisor at or above the top tier" {
    # advisorModel must be >= the session's main model; fable is the ceiling
    jq -e '.advisorModel == "fable"' /etc/claude-dev/configs/claude-settings.json
}

@test "knowledge-base index is staged" {
    [ -f /opt/claude-dev/knowledge-base/README.md ]
    grep -q 'BEADS_TROUBLESHOOTING' /opt/claude-dev/knowledge-base/README.md
}

@test "tier engine and /tier command are staged with inherit checkers" {
    # Fable 5 is an active model: the engine must offer it as a candidate
    # (alias fable -> claude-fable-5) and the checkers must inherit the
    # orchestrator's model so they are never a tier below it.
    [ -x /usr/local/bin/tier-set ]
    grep -q 'claude-fable-5' /usr/local/bin/tier-set
    [ -f /etc/claude-dev/configs/commands/tier.md ]
    grep -q 'tier-set' /etc/claude-dev/configs/.zshrc
    grep -q '^model: inherit' /etc/claude-dev/configs/agents/verifier.md
    grep -q '^model: inherit' /etc/claude-dev/configs/agents/oracle.md
}

@test "tier-set maps aliases, degrades downward, warns on inverted ranks, writes settings" {
    local ts fake
    ts=$(mktemp)
    printf '{"env":{"CLAUDE_CODE_SUBAGENT_MODEL":"bad"},"permissions":{"allow":["WebSearch"]}}\n' > "$ts"

    # alias trio maps to concrete ids and lands in settings (no probe needed)
    run env TIER_SETTINGS="$ts" TIER_NO_PROBE=1 /usr/local/bin/tier-set fable opus haiku
    [ "$status" -eq 0 ]
    jq -e '.model == "claude-fable-5"
           and .env.ANTHROPIC_DEFAULT_OPUS_MODEL == "claude-fable-5"
           and .env.ANTHROPIC_DEFAULT_SONNET_MODEL == "claude-opus-4-8"
           and .env.ANTHROPIC_DEFAULT_HAIKU_MODEL == "claude-haiku-4-5-20251001"
           and (.env | has("CLAUDE_CODE_SUBAGENT_MODEL") | not)
           and .permissions.allow == ["WebSearch"]' "$ts"

    # 2 models: reasoning + worker set positionally, recon keeps its default
    run env TIER_SETTINGS="$ts" TIER_NO_PROBE=1 /usr/local/bin/tier-set opus sonnet
    [ "$status" -eq 0 ]
    jq -e '.model == "claude-opus-4-8"
           and .env.ANTHROPIC_DEFAULT_OPUS_MODEL == "claude-opus-4-8"
           and .env.ANTHROPIC_DEFAULT_SONNET_MODEL == "claude-sonnet-5"
           and .env.ANTHROPIC_DEFAULT_HAIKU_MODEL == "claude-haiku-4-5-20251001"' "$ts"

    # unavailable model degrades downward (probe stubbed, no API calls)
    fake=$(mktemp -d)
    printf '#!/bin/sh\ncase "$*" in *definitely-unavailable*) exit 1;; *) exit 0;; esac\n' > "$fake/claude"
    chmod +x "$fake/claude"
    run env TIER_SETTINGS="$ts" PATH="$fake:$PATH" /usr/local/bin/tier-set definitely-unavailable-model
    [ "$status" -eq 0 ]
    jq -e '.model == "claude-opus-4-8"' "$ts"

    # a lower slot outranking the reasoning slot draws a warning
    run env TIER_SETTINGS="$ts" TIER_NO_PROBE=1 /usr/local/bin/tier-set haiku opus
    [[ "$output" == *"outranks"* ]]

    # corrupt settings are left untouched
    printf 'NOT JSON' > "$ts"
    run env TIER_SETTINGS="$ts" TIER_NO_PROBE=1 /usr/local/bin/tier-set fable
    [ "$status" -ne 0 ]
    [ "$(cat "$ts")" = "NOT JSON" ]

    rm -rf "$ts" "$fake"
}

@test "tests do not leak temp dirs when an assertion fails" {
    # Regression guard for the disk-space leak: a bats test that aborts on a
    # failed assertion must NOT strand its scratch dir. We prove the suite-wide
    # fix (routing scratch under bats's auto-cleaned tmpdir) by running a nested
    # failing test and confirming bats reclaimed its run tree.
    local nested run_tmp
    nested="$BATS_TEST_TMPDIR/nested.bats"
    run_tmp="$BATS_TEST_TMPDIR/nested-run"
    mkdir -p "$run_tmp"
    cat > "$nested" <<'EOF'
setup() { export TMPDIR="$BATS_TEST_TMPDIR"; }
@test "leaks nothing on failure" {
    mktemp -d >/dev/null   # scratch under bats tmpdir
    [ 1 = 2 ]              # abort before any inline cleanup
}
EOF
    TMPDIR="$run_tmp" run bats "$nested"
    [ "$status" -ne 0 ]                                  # the nested test failed, as designed
    [ -z "$(find "$run_tmp" -maxdepth 1 -name 'bats-run-*' 2>/dev/null)" ]  # ...but left no run tree
}

@test "disk-cleanup age-gates temp/attachments and caps append-only logs" {
    local dc ws scan
    dc=/workspace/scripts/disk-cleanup.sh          # repo source: testable pre-rebuild
    [ -x "$dc" ]
    ws="$BATS_TEST_TMPDIR/ws"
    scan="$BATS_TEST_TMPDIR/scan"
    mkdir -p "$ws/attachments" "$ws/.claude/logs" "$scan"

    # aged vs fresh attachment
    : > "$ws/attachments/old.png"; touch -d '10 days ago' "$ws/attachments/old.png"
    : > "$ws/attachments/fresh.png"
    # aged vs fresh stray temp dir
    mkdir -p "$scan/tmp.OLD"; touch -d '2 days ago' "$scan/tmp.OLD"
    mkdir -p "$scan/tmp.NEW"
    # oversized vs small append-only log
    seq 1 8000 > "$ws/.claude/logs/runs.log"
    seq 1 10   > "$ws/.claude/logs/errors.log"

    WORKSPACE="$ws" TMP_SCAN_DIR="$scan" TMP_AGE_MIN=1440 \
        ATTACH_AGE_DAYS=7 LOG_MAX_LINES=5000 "$dc" >/dev/null

    [ -f "$ws/attachments/fresh.png" ]                        # fresh kept
    [ ! -f "$ws/attachments/old.png" ]                        # aged removed
    [ -d "$scan/tmp.NEW" ]                                    # fresh temp kept
    [ ! -d "$scan/tmp.OLD" ]                                  # aged temp removed
    [ "$(wc -l < "$ws/.claude/logs/runs.log")" -eq 5000 ]     # oversized log capped
    [ "$(wc -l < "$ws/.claude/logs/errors.log")" -eq 10 ]     # small log untouched
}
