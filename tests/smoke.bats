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
}

@test "config version file exists and is a number" {
    [ -f /etc/claude-dev/CONFIG_VERSION ]
    local ver
    ver=$(cat /etc/claude-dev/CONFIG_VERSION)
    [[ "$ver" =~ ^[0-9]+$ ]]
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
    jq -e '.teammateMode == "tmux"' "$settings"
}

@test "zshrc aliases are defined" {
    grep -q 'alias cs=' /etc/claude-dev/configs/.zshrc
    grep -q 'alias menu=' /etc/claude-dev/configs/.zshrc
    grep -q 'alias dlog=' /etc/claude-dev/configs/.zshrc
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
    local test_dir="/tmp/test-logs-$$"
    LOG_DIR="$test_dir" dev-log run "echo test" pass "smoke test"
    [ -f "$test_dir/runs.log" ]
    grep -q "smoke test" "$test_dir/runs.log"
    rm -rf "$test_dir"
}
