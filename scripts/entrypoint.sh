#!/bin/bash
set -e

# Import IntelliShell defaults on first run
MARKER_FILE="/home/agent/.config/intelli-shell/.defaults_imported"
DEFAULTS_FILE="/home/agent/.config/intelli-shell/defaults.txt"

if [ -f "$DEFAULTS_FILE" ] && [ ! -f "$MARKER_FILE" ]; then
    mkdir -p "$(dirname "$MARKER_FILE")"
    /home/agent/.local/share/intelli-shell/bin/intelli-shell import "$DEFAULTS_FILE" 2>/dev/null || true
    touch "$MARKER_FILE"
fi

# Config version sync: update configs when image is newer than volume
IMAGE_VERSION=$(cat /etc/claude-dev/CONFIG_VERSION 2>/dev/null || echo "0")
VOLUME_VERSION=$(cat /home/agent/.config-version 2>/dev/null || echo "0")
if [ "$IMAGE_VERSION" != "$VOLUME_VERSION" ]; then
    cp /etc/claude-dev/configs/.zshrc /home/agent/.zshrc 2>/dev/null || true
    mkdir -p /home/agent/.config/helix
    cp /etc/claude-dev/configs/helix-config.toml /home/agent/.config/helix/config.toml 2>/dev/null || true
    mkdir -p /home/agent/.config/intelli-shell
    cp /etc/claude-dev/configs/intellishell-config.toml /home/agent/.config/intelli-shell/config.toml 2>/dev/null || true
    cp /etc/claude-dev/configs/intellishell-defaults.txt /home/agent/.config/intelli-shell/defaults.txt 2>/dev/null || true
    rm -f /home/agent/.config/intelli-shell/.defaults_imported
    # Update Claude settings (fixes breaking changes like hooks format)
    mkdir -p /home/agent/.claude
    cp /etc/claude-dev/configs/claude-settings.json /home/agent/.claude/settings.json 2>/dev/null || true
    echo "$IMAGE_VERSION" > /home/agent/.config-version
fi

# Workspace validation
if [ -z "$(ls -A /workspace 2>/dev/null)" ]; then
    echo -e "\033[33m⚠  WARNING: /workspace is empty — project may not be mounted.\033[0m"
    echo "   Check .claude-dev/docker-compose.yml or your volume mount path."
    echo ""
fi

# Copy Claude settings template only if not already present (preserve user customizations)
mkdir -p /home/agent/.claude
if [ ! -f /home/agent/.claude/settings.json ]; then
    cp /home/agent/.config/claude-settings-template.json /home/agent/.claude/settings.json 2>/dev/null || true
fi

# Patch Ralph for sandboxed Docker execution:
# 1. Add --dangerously-skip-permissions to CLAUDE_CODE_CMD (robust pattern)
# 2. Clear CLAUDE_ALLOWED_TOOLS so --allowedTools flag is not passed
#    (--allowedTools overrides --dangerously-skip-permissions)
RALPH_LOOP="/home/agent/.ralph/ralph_loop.sh"
if [ -f "$RALPH_LOOP" ]; then
    sed -i 's|^CLAUDE_CODE_CMD=.*|CLAUDE_CODE_CMD="env NODE_TLS_REJECT_UNAUTHORIZED=0 claude --dangerously-skip-permissions"|' "$RALPH_LOOP"
    sed -i 's|^CLAUDE_ALLOWED_TOOLS=.*|CLAUDE_ALLOWED_TOOLS=""|' "$RALPH_LOOP"
    if ! grep -q 'dangerously-skip-permissions' "$RALPH_LOOP"; then
        echo -e "\033[33m⚠  WARNING: Failed to patch Ralph permissions — Claude may prompt for tool approval.\033[0m" >&2
    fi
fi

# Change to workspace directory
cd /workspace

# Execute the provided command or start zsh
exec "$@"
