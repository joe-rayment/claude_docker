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
    # Deploy custom agents
    mkdir -p /home/agent/.claude/agents
    cp /etc/claude-dev/configs/agents/*.md /home/agent/.claude/agents/ 2>/dev/null || true
    # Validate settings JSON — warn but don't block (corruption is the concern, not absence)
    if [ -f /home/agent/.claude/settings.json ] && ! jq empty /home/agent/.claude/settings.json 2>/dev/null; then
        echo -e "\033[33m⚠  WARNING: /home/agent/.claude/settings.json contains invalid JSON.\033[0m"
        echo "   Claude Code may not start correctly. Check the file for syntax errors."
        echo ""
    fi
    echo "${IMAGE_VERSION}" > /home/agent/.config-version
fi

# Start virtual framebuffer for screenshot tools (Playwright, import, etc.)
if command -v Xvfb &>/dev/null; then
    Xvfb :99 -screen 0 1280x720x24 &>/dev/null &
    export DISPLAY=:99
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

# Start Dolt server (required by Beads for database operations)
# Errors logged to /tmp/.dolt-server.log for debugging
/usr/local/bin/start-dolt || true

# Beads auto-initialization: ensure project has agent memory
if command -v bd &>/dev/null && command -v dolt &>/dev/null && [ -d "/workspace/.git" ]; then
    # Clean up stale .beads/dolt directory (empty leftover from failed init)
    if [ -d "/workspace/.beads/dolt" ] && [ ! -d "/workspace/.beads/dolt/.dolt" ]; then
        rm -rf "/workspace/.beads/dolt"
    fi
    if [ ! -d "/workspace/.beads" ]; then
        # Fresh project — determine prefix and initialize
        BEADS_PREFIX=""
        REMOTE_URL=$(git -C /workspace remote get-url origin 2>/dev/null || true)
        if [ -n "$REMOTE_URL" ]; then
            BEADS_PREFIX=$(basename "$REMOTE_URL" .git 2>/dev/null || true)
        fi
        [ -z "$BEADS_PREFIX" ] && BEADS_PREFIX="${CLAUDE_PROJECT_NAME:-}"
        [ -z "$BEADS_PREFIX" ] && BEADS_PREFIX=$(basename "$(git -C /workspace rev-parse --show-toplevel 2>/dev/null || echo /workspace)")
        (cd /workspace && bd init --prefix "$BEADS_PREFIX" --quiet 2>/dev/null) || true
        if [ -d "/workspace/.beads" ]; then
            (cd /workspace && bd hooks install 2>/dev/null) || true
        fi
        unset BEADS_PREFIX REMOTE_URL
    fi
fi

# Change to workspace directory (with diagnostic on failure to prevent silent restart loop)
cd /workspace || {
    echo -e "\033[31mFATAL: /workspace is not accessible. Check your volume mount.\033[0m" >&2
    echo "   Container will stay alive for debugging. Run: docker exec -it <name> /bin/bash" >&2
    exec sleep infinity
}

# Auto-start tmux for agent teams support.
# teammateMode: "tmux" requires a tmux session for teammate panes to appear.
# Skip if: already in tmux, non-interactive, command is tmux itself, or opt-out.
# Set CLAUDE_DEV_NO_TMUX=1 to bypass tmux (useful for debugging or alternate runtimes).
if [ -z "${TMUX:-}" ] && [ -t 0 ] && [ "${1:-}" != "tmux" ] && [ -z "${CLAUDE_DEV_NO_TMUX:-}" ]; then
    # Kill stale "main" session from a previous container lifecycle (if any).
    # Only targets our session — leaves other tmux sessions intact.
    if tmux has-session -t main 2>/dev/null; then
        tmux kill-session -t main 2>/dev/null || true
    fi
    # Verify tmux can start before committing to it. If the config is broken
    # or tmux is unavailable, fall through to raw shell instead of crash-looping.
    if tmux -u new-session -d -s _probe 2>/dev/null; then
        tmux kill-session -t _probe 2>/dev/null || true

        # Create session detached so we can configure panes before attaching
        tmux -u new-session -d -s main -c /workspace

        # Attach via exec — replaces the entrypoint with the tmux client.
        # Signal chain on docker stop: SIGTERM → tini → tmux client exits →
        # server detects lost client → client-detached hook fires kill-server →
        # all child processes (shells, agents) terminate cleanly.
        # See tmux.conf client-detached hook for the server-side cleanup.
        exec tmux -u attach-session -t main
    fi
    echo -e "\033[33m⚠  tmux failed to start — falling back to shell.\033[0m" >&2
    echo "   Check ~/.tmux.conf for errors or set CLAUDE_DEV_NO_TMUX=1." >&2
fi

# Fallback: already in tmux, non-interactive, tmux failed, or opt-out
exec "$@"
