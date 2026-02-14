#!/bin/bash
set -e

cleanup() { kill -- -$$ 2>/dev/null; }
trap cleanup SIGTERM SIGINT

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
    # User customizations should go in ~/.zshrc.local (sourced at end of .zshrc)
    cp /etc/claude-dev/configs/.zshrc /home/agent/.zshrc 2>/dev/null || true
    mkdir -p /home/agent/.config/helix
    cp /etc/claude-dev/configs/helix-config.toml /home/agent/.config/helix/config.toml 2>/dev/null || true
    mkdir -p /home/agent/.config/intelli-shell
    cp /etc/claude-dev/configs/intellishell-config.toml /home/agent/.config/intelli-shell/config.toml 2>/dev/null || true
    cp /etc/claude-dev/configs/intellishell-defaults.txt /home/agent/.config/intelli-shell/defaults.txt 2>/dev/null || true
    rm -f /home/agent/.config/intelli-shell/.defaults_imported
    # Update Claude settings and statusline script
    mkdir -p /home/agent/.claude
    cp /etc/claude-dev/configs/claude-settings.json /home/agent/.claude/settings.json 2>/dev/null || true
    cp /etc/claude-dev/configs/statusline.sh /home/agent/.claude/statusline.sh 2>/dev/null || true
    chmod +x /home/agent/.claude/statusline.sh 2>/dev/null || true
    # Update tmux config
    cp /etc/claude-dev/configs/tmux.conf /home/agent/.tmux.conf 2>/dev/null || true
    # Validate settings JSON — warn but don't block (corruption is the concern, not absence)
    if [ -f /home/agent/.claude/settings.json ] && ! jq empty /home/agent/.claude/settings.json 2>/dev/null; then
        echo -e "\033[33m⚠  WARNING: /home/agent/.claude/settings.json contains invalid JSON.\033[0m"
        echo "   Claude Code may not start correctly. Check the file for syntax errors."
        echo ""
    fi
    echo "${IMAGE_VERSION}" > /home/agent/.config-version
fi

# Workspace validation
if [ -z "$(ls -A /workspace 2>/dev/null)" ]; then
    echo -e "\033[33m⚠  WARNING: /workspace is empty — project may not be mounted.\033[0m"
    echo "   Check .claude-dev/docker-compose.yml or your volume mount path."
    echo ""
fi

# Copy Claude settings and statusline only if not already present (preserve user customizations)
mkdir -p /home/agent/.claude
if [ ! -f /home/agent/.claude/settings.json ]; then
    cp /home/agent/.config/claude-settings-template.json /home/agent/.claude/settings.json 2>/dev/null || true
fi
if [ ! -f /home/agent/.claude/statusline.sh ]; then
    cp /etc/claude-dev/configs/statusline.sh /home/agent/.claude/statusline.sh 2>/dev/null || true
    chmod +x /home/agent/.claude/statusline.sh 2>/dev/null || true
fi

# Wire git credential helper to gh if GitHub is authenticated
if [ -f "/home/agent/.config/gh/hosts.yml" ]; then
    gh auth setup-git 2>/dev/null || true
fi

# Beads auto-initialization: ensure project has agent memory
if command -v bd &>/dev/null && [ -d "/workspace/.git" ]; then
    if [ ! -d "/workspace/.beads" ]; then
        # Fresh project — initialize beads
        (cd /workspace && bd init --quiet 2>/dev/null) || true
        if [ -d "/workspace/.beads" ]; then
            (cd /workspace && bd hooks install 2>/dev/null) || true
        fi
    elif [ ! -f "/workspace/.beads/beads.db" ]; then
        # Cloned from GitHub — rebuild SQLite from JSONL
        (cd /workspace && bd import 2>/dev/null) || true
    fi
fi

# Change to workspace directory
cd /workspace

# Auto-start tmux for agent teams support.
# teammateMode: "tmux" requires a tmux session for teammate panes to appear.
# Skip if: already in tmux, non-interactive, or command is tmux itself.
if [ -z "${TMUX:-}" ] && [ -t 0 ] && [ "${1:-}" != "tmux" ]; then
    # Kill stale tmux server from previous container lifecycle (if any)
    tmux kill-server 2>/dev/null || true
    # exec replaces entrypoint as PID 1 so tmux receives signals directly.
    # -A: attach if session "main" exists, create if not (idempotent).
    # -u: force UTF-8 support.
    exec tmux -u new-session -A -s main "$@"
fi

# Fallback: already in tmux, non-interactive, or explicit tmux command
exec "$@"
