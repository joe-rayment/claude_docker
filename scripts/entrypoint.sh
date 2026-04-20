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

# Clean up orphaned file from old CONFIG_VERSION-based sync
rm -f /home/agent/.config-version

# One-time cleanup: remove the old auto-migrated native Claude install from
# /home/agent/.local (created by Claude's autoupdater on older images). With the
# system install at /opt/claude, ~/.local/bin/claude would shadow it via PATH.
# Credentials at /home/agent/.claude are preserved.
NATIVE_CLEANUP_MARKER="/home/agent/.config/.claude-native-cleanup-v1"
if [ ! -f "$NATIVE_CLEANUP_MARKER" ]; then
    {
        rm -f /home/agent/.local/bin/claude
        rm -rf /home/agent/.local/share/claude /home/agent/.claude/downloads
        mkdir -p "$(dirname "$NATIVE_CLEANUP_MARKER")"
        touch "$NATIVE_CLEANUP_MARKER"
    } 2>/dev/null || true
fi

# Config sync: update volume configs when image configs have changed
# Uses checksums of staged config files instead of a manual version string
IMAGE_HASH=$(find /etc/claude-dev/configs -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum | cut -d' ' -f1)
VOLUME_HASH=$(cat /home/agent/.config-hash 2>/dev/null || echo "none")
if [ "$IMAGE_HASH" != "$VOLUME_HASH" ]; then
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
    # Merge user's local overrides into settings (deep merge, local wins)
    if [ -f /home/agent/.claude/settings.local.json ]; then
        MERGED=$(jq -s '.[0] * .[1]' /home/agent/.claude/settings.json /home/agent/.claude/settings.local.json 2>/dev/null) && \
            echo "$MERGED" > /home/agent/.claude/settings.json
    fi
    cp /etc/claude-dev/configs/statusline.sh /home/agent/.claude/statusline.sh 2>/dev/null || true
    chmod +x /home/agent/.claude/statusline.sh 2>/dev/null || true
    # Deploy custom agents
    mkdir -p /home/agent/.claude/agents
    cp /etc/claude-dev/configs/agents/*.md /home/agent/.claude/agents/ 2>/dev/null || true
    # Validate settings JSON — warn but don't block (corruption is the concern, not absence)
    if [ -f /home/agent/.claude/settings.json ] && ! jq empty /home/agent/.claude/settings.json 2>/dev/null; then
        echo -e "\033[33m⚠  WARNING: /home/agent/.claude/settings.json contains invalid JSON.\033[0m"
        echo "   Claude Code may not start correctly. Check the file for syntax errors."
        echo ""
    fi
    echo "${IMAGE_HASH}" > /home/agent/.config-hash
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

# Ensure /drops directory exists (even if host dir not mounted)
mkdir -p /drops 2>/dev/null || true

# Ensure attachments directory exists for file sharing
mkdir -p /workspace/attachments 2>/dev/null || true

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

# Beads agent memory — single entry point covering three scenarios:
#   (A) fresh project, no .beads/  → bd init + bd hooks install
#   (B) cloned project, .beads/ JSONL present but Dolt DB missing in this volume
#       → bd doctor --fix --yes
#   (C) healthy (.beads/ + populated Dolt DB) → no-op, silent
# Also cleans up the empty .beads/dolt leftover from a failed init.
detect_beads_prefix() {
    local prefix remote
    remote=$(git -C /workspace remote get-url origin 2>/dev/null || true)
    if [ -n "$remote" ]; then
        prefix=$(basename "$remote" .git 2>/dev/null || true)
    fi
    [ -z "${prefix:-}" ] && prefix="${CLAUDE_PROJECT_NAME:-}"
    [ -z "${prefix:-}" ] && prefix=$(basename "$(git -C /workspace rev-parse --show-toplevel 2>/dev/null || echo /workspace)")
    echo "$prefix"
}

ensure_beads() {
    command -v bd &>/dev/null || return 0
    command -v dolt &>/dev/null || return 0
    [ -d "/workspace/.git" ] || return 0

    # Clear empty .beads/dolt leftover from a failed prior init
    if [ -d "/workspace/.beads/dolt" ] && [ ! -d "/workspace/.beads/dolt/.dolt" ]; then
        rm -rf "/workspace/.beads/dolt"
    fi

    if [ ! -d "/workspace/.beads" ]; then
        # (A) fresh — initialize
        local prefix
        prefix=$(detect_beads_prefix)
        (cd /workspace && bd init --prefix "$prefix" --quiet) 2>/dev/null || true
        if [ -d "/workspace/.beads" ]; then
            (cd /workspace && bd hooks install) 2>/dev/null || true
        fi
        return 0
    fi

    # (B) or (C): .beads/ exists — heal only if Dolt is up and bd status is broken.
    # Without metadata.json we can't know what to heal, so skip.
    [ -f "/workspace/.beads/metadata.json" ] || return 0
    timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/3307" 2>/dev/null || return 0
    (cd /workspace && bd status) &>/dev/null && return 0  # (C) healthy

    # (B) repair
    (cd /workspace && bd doctor --fix --yes) &>/dev/null || true
    if (cd /workspace && bd status) &>/dev/null; then
        dev-log run "bd doctor --fix --yes" pass "Auto-repaired Beads database on startup" 2>/dev/null || true
    else
        dev-log error "Beads auto-repair failed on startup" 2>/dev/null || true
    fi
}

ensure_beads

# Register Claude Code hooks for beads awareness (SessionStart, PreCompact).
# Idempotent — merges into existing settings.json without overwriting other entries.
# Runs after config version sync since that may reset settings.json to the template.
if command -v bd &>/dev/null; then
    if ! bd setup claude 2>/dev/null; then
        dev-log error "bd setup claude failed during entrypoint" 2>/dev/null || true
    fi
fi

# Change to workspace directory (with diagnostic on failure to prevent silent restart loop)
cd /workspace || {
    echo -e "\033[31mFATAL: /workspace is not accessible. Check your volume mount.\033[0m" >&2
    echo "   Container will stay alive for debugging. Run: docker exec -it <name> /bin/bash" >&2
    exec sleep infinity
}

# Launch the shell directly. Signal chain on docker stop:
# SIGTERM → tini → shell exits cleanly.
exec "$@"
