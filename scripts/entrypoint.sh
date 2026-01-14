#!/bin/bash
set -e

# Import IntelliShell defaults on first run
MARKER_FILE="/home/agent/.config/intelli-shell/.defaults_imported"
DEFAULTS_FILE="/home/agent/.config/intelli-shell/defaults.txt"

if [ -f "$DEFAULTS_FILE" ] && [ ! -f "$MARKER_FILE" ]; then
    mkdir -p "$(dirname "$MARKER_FILE")"
    /home/agent/.local/bin/intelli-shell import "$DEFAULTS_FILE" 2>/dev/null || true
    touch "$MARKER_FILE"
fi

# Create workspace structure
mkdir -p /workspace/logs
mkdir -p /workspace/specs

# Copy Claude settings if not exists
if [ ! -f "/home/agent/.claude/settings.json" ]; then
    mkdir -p /home/agent/.claude
    cp /home/agent/.config/claude-settings-template.json /home/agent/.claude/settings.json 2>/dev/null || true
fi

# Change to workspace directory
cd /workspace

# Execute the provided command or start zsh
exec "$@"
