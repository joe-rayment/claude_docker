#!/usr/bin/env bats

# Smoke tests — verify the container environment is correctly set up
# These run without tmux and check static properties

@test "scripts are present and executable" {
    [ -x /usr/local/bin/entrypoint.sh ]
    [ -x /usr/local/bin/container-welcome ]
    [ -x /usr/local/bin/guided-setup.sh ]
    [ -x /usr/local/bin/detect-dependencies.sh ]
    [ -x /usr/local/bin/view-logs ]
    [ -x /usr/local/bin/dev-log ]
    [ -x /usr/local/bin/agent-panels ]
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
    command -v tmux
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
    [ -f /etc/claude-dev/configs/tmux.conf ]
}

@test "claude-settings.json is valid JSON with agent teams config" {
    local settings="/etc/claude-dev/configs/claude-settings.json"
    jq empty "$settings"
    jq -e '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS == "1"' "$settings"
    jq -e '.teammateMode == "tmux"' "$settings"
}

@test "zshrc aliases are defined" {
    grep -q 'alias cs=' /etc/claude-dev/configs/.zshrc
    grep -q 'alias menu=' /etc/claude-dev/configs/.zshrc
    grep -q 'alias dlog=' /etc/claude-dev/configs/.zshrc
    grep -q 'alias ap=' /etc/claude-dev/configs/.zshrc
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
    run bash -c "run-tests.sh smoke 2>&1 | head -1"
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    # Should not show "Unknown test suite" error
    [[ "$output" != *"Unknown"* ]]
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

@test "tmux.conf is installed in agent home" {
    [ -f /home/agent/.tmux.conf ]
}

@test "agent-panels shows help with no arguments" {
    run env -u TMUX agent-panels
    [ "$status" -eq 0 ]
    [[ "$output" == *"toggle"* ]]
    [[ "$output" == *"CapsLk+a"* ]]
}

@test "screenshot tools are installed" {
    command -v Xvfb
    command -v import
    command -v termshot
}

@test "playwright is installed" {
    run npx playwright --version
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
    run npx playwright install --dry-run chromium
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
