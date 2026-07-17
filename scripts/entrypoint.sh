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

# One-time cleanup: remove stale native-install artifacts from old volumes.
# Older images let Claude's autoupdater write its own copy under ~/.local; that
# stale copy must be cleared so it doesn't shadow /opt/claude/claude. The
# ~/.local/bin/claude symlink itself is (re)created idempotently below.
NATIVE_CLEANUP_MARKER="/home/agent/.config/.claude-native-cleanup-v2"
if [ ! -f "$NATIVE_CLEANUP_MARKER" ]; then
    {
        # Only remove if it's a real file (the stale autoupdated binary).
        # Leave symlinks alone — they're reconciled below.
        [ -f /home/agent/.local/bin/claude ] && [ ! -L /home/agent/.local/bin/claude ] && \
            rm -f /home/agent/.local/bin/claude
        rm -rf /home/agent/.local/share/claude /home/agent/.claude/downloads
        mkdir -p "$(dirname "$NATIVE_CLEANUP_MARKER")"
        touch "$NATIVE_CLEANUP_MARKER"
    } 2>/dev/null || true
fi

# Idempotent: Claude's native binary self-check expects ~/.local/bin/claude to
# resolve to a valid Claude executable (installMethod="native" in ~/.claude.json).
# Point it at the image's /opt/claude/claude so the single source of truth wins.
# Runs every start so fresh volumes and recovered volumes both get the symlink.
if [ -x /opt/claude/claude ]; then
    mkdir -p /home/agent/.local/bin
    if [ ! -L /home/agent/.local/bin/claude ] || \
       [ "$(readlink /home/agent/.local/bin/claude)" != "/opt/claude/claude" ]; then
        ln -sfn /opt/claude/claude /home/agent/.local/bin/claude
    fi
fi

# Merge user's local overrides into settings.json (deep merge, local wins).
# permissions.allow/deny/ask arrays are unioned rather than replaced so a
# local allowlist extends the base one instead of wiping it.
merge_claude_settings_local() {
    local settings=${1:-/home/agent/.claude/settings.json}
    local local_settings=${2:-/home/agent/.claude/settings.local.json}
    [ -f "$local_settings" ] || return 0
    if ! jq empty "$local_settings" 2>/dev/null; then
        echo -e "\033[33m⚠  WARNING: $local_settings contains invalid JSON — local overrides NOT applied.\033[0m"
        echo "   Fix the file and restart the container (or re-run the entrypoint) to apply them."
        echo ""
        return 0
    fi
    local merged
    merged=$(jq -s '
        .[0] as $base | .[1] as $local | ($base * $local)
        | if ($base.permissions.allow or $local.permissions.allow)
          then .permissions.allow = ((($base.permissions.allow // []) + ($local.permissions.allow // [])) | unique) else . end
        | if ($base.permissions.deny or $local.permissions.deny)
          then .permissions.deny = ((($base.permissions.deny // []) + ($local.permissions.deny // [])) | unique) else . end
        | if ($base.permissions.ask or $local.permissions.ask)
          then .permissions.ask = ((($base.permissions.ask // []) + ($local.permissions.ask // [])) | unique) else . end
    ' "$settings" "$local_settings" 2>/dev/null) \
        && [ -n "$merged" ] && echo "$merged" > "$settings"
}

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
    cp /etc/claude-dev/configs/tmux.conf /home/agent/.tmux.conf 2>/dev/null || true
    # Update Claude settings and statusline script
    mkdir -p /home/agent/.claude
    cp /etc/claude-dev/configs/claude-settings.json /home/agent/.claude/settings.json 2>/dev/null || true
    merge_claude_settings_local
    cp /etc/claude-dev/configs/statusline.sh /home/agent/.claude/statusline.sh 2>/dev/null || true
    chmod +x /home/agent/.claude/statusline.sh 2>/dev/null || true
    # Deploy custom agents
    mkdir -p /home/agent/.claude/agents
    cp /etc/claude-dev/configs/agents/*.md /home/agent/.claude/agents/ 2>/dev/null || true
    # Deploy custom skills (directory-based: ~/.claude/skills/<name>/SKILL.md)
    mkdir -p /home/agent/.claude/skills
    cp -r /etc/claude-dev/configs/skills/. /home/agent/.claude/skills/ 2>/dev/null || true
    # Deploy custom slash commands (~/.claude/commands/<name>.md)
    mkdir -p /home/agent/.claude/commands
    cp /etc/claude-dev/configs/commands/*.md /home/agent/.claude/commands/ 2>/dev/null || true
    # Validate settings JSON — warn but don't block (corruption is the concern, not absence)
    if [ -f /home/agent/.claude/settings.json ] && ! jq empty /home/agent/.claude/settings.json 2>/dev/null; then
        echo -e "\033[33m⚠  WARNING: /home/agent/.claude/settings.json contains invalid JSON.\033[0m"
        echo "   Claude Code may not start correctly. Check the file for syntax errors."
        echo ""
    fi
    echo "${IMAGE_HASH}" > /home/agent/.config-hash
fi

# Start virtual framebuffer for screenshot tools (Playwright, import, etc.)
# A container restart can leave a stale /tmp/.X99-lock from the killed Xvfb;
# clear it (only when no Xvfb is running) so the restart gets a live display.
if command -v Xvfb &>/dev/null; then
    if ! pgrep -x Xvfb >/dev/null 2>&1; then
        rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
        Xvfb :99 -screen 0 1280x720x24 &>/dev/null &
    fi
    export DISPLAY=:99
fi

# Bound the container's disk footprint on every (re)start: sweep stray test
# temp dirs, aged screenshots, and oversized append-only logs. Best-effort and
# backgrounded so it never delays startup; the `command -v` guard makes it a
# no-op on images built before disk-cleanup was baked in. Also runs per Claude
# session via the SessionStart hook in claude-settings.json.
if command -v disk-cleanup >/dev/null 2>&1; then
    disk-cleanup >/dev/null 2>&1 &
fi

# Generate the Playwright MCP server config for interactive browser automation
# (click/fill/multi-step, beyond the static take-screenshot CLI). /workspace/.mcp.json
# is gitignored; its servers auto-enable via enableAllProjectMcpServers. We only
# (re)write the 'playwright' key, preserving any other servers the user defined.
# No-op on images built before the pinned binary was baked.
if command -v playwright-mcp >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    MCP_JSON=/workspace/.mcp.json
    mcp_base='{}'
    [ -f "$MCP_JSON" ] && jq -e . "$MCP_JSON" >/dev/null 2>&1 && mcp_base=$(cat "$MCP_JSON")
    if printf '%s' "$mcp_base" | jq '
            .mcpServers = ((.mcpServers // {}) | .playwright = {
                command: "playwright-mcp",
                args: ["--headless", "--browser", "chromium"],
                env: { PLAYWRIGHT_BROWSERS_PATH: "/home/agent/.cache/ms-playwright" }
            })' > "$MCP_JSON.tmp" 2>/dev/null; then
        mv "$MCP_JSON.tmp" "$MCP_JSON"
    else
        rm -f "$MCP_JSON.tmp"
    fi
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

# Ensure project .gitignore covers template files — but only when /workspace
# is itself a git toplevel. Skips if no git is in use, or if /workspace is a
# bind-mounted subdir of a host repo (parent .git lives outside the mount and
# isn't visible here, so git rev-parse returns nothing). Idempotent.
ensure_workspace_gitignore() {
    local top
    top=$(git -C /workspace rev-parse --show-toplevel 2>/dev/null || true)
    [ "$top" = "/workspace" ] || return 0
    local gitignore=/workspace/.gitignore
    touch "$gitignore" 2>/dev/null || return 0
    local pattern
    for pattern in '.claude-dev/' '/claude-dev' '.mcp.json' '.claude/logs/' 'attachments/'; do
        grep -qxF "$pattern" "$gitignore" 2>/dev/null || echo "$pattern" >> "$gitignore"
    done
}
ensure_workspace_gitignore

# Copy Claude settings and statusline only if not already present (preserve user customizations)
mkdir -p /home/agent/.claude
if [ ! -f /home/agent/.claude/settings.json ]; then
    cp /etc/claude-dev/configs/claude-settings.json /home/agent/.claude/settings.json 2>/dev/null || true
    merge_claude_settings_local
fi
if [ ! -f /home/agent/.claude/statusline.sh ]; then
    cp /etc/claude-dev/configs/statusline.sh /home/agent/.claude/statusline.sh 2>/dev/null || true
    chmod +x /home/agent/.claude/statusline.sh 2>/dev/null || true
fi

# Wire git credential helper to gh if GitHub is authenticated
if [ -f "/home/agent/.config/gh/hosts.yml" ]; then
    gh auth setup-git 2>/dev/null \
        || dev-log error "gh auth setup-git failed during entrypoint" "git credential helper not wired; run 'gh auth setup-git' manually" 2>/dev/null || true
fi

# Beads runs in embedded Dolt mode — there is no SQL server to start. bd
# operates directly on /workspace/.beads/embeddeddolt, rebuilt from the
# git-tracked issues.jsonl as needed.
#
# Beads agent memory — single entry point covering three scenarios:
#   (A) fresh project, no .beads/  → bd init + bd hooks install
#   (B) cloned project, .beads/ JSONL present but Dolt DB missing in this volume
#       → bd doctor --fix --yes
#   (C) healthy (.beads/ + populated Dolt DB) → no-op, silent
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

# Seed starter agent memories on a freshly-initialized beads DB. Called only
# from the fresh-init path (A), so it runs once per project.
seed_beads_memories() {
    (cd /workspace && bd remember "NEVER assign beads to a user -- they are for Claude Code only. Anything that requires a user input should be handled in a question in chat.") 2>/dev/null \
        || dev-log error "bd remember seed failed during entrypoint" "starter memory not stored" 2>/dev/null || true
    (cd /workspace && bd remember "Code changes must be tested in realistic settings, including running the actual program and taking screenshots.") 2>/dev/null \
        || dev-log error "bd remember seed failed during entrypoint" "starter memory not stored" 2>/dev/null || true
}

ensure_beads() {
    command -v bd &>/dev/null || return 0
    command -v dolt &>/dev/null || return 0
    [ -d "/workspace/.git" ] || return 0

    if [ ! -d "/workspace/.beads" ]; then
        # (A) fresh — initialize
        local prefix
        prefix=$(detect_beads_prefix)
        if ! (cd /workspace && bd init --prefix "$prefix" --quiet) 2>/dev/null; then
            dev-log error "bd init failed during entrypoint" "prefix=$prefix; beads unavailable in this project" 2>/dev/null || true
        fi
        if [ -d "/workspace/.beads" ]; then
            (cd /workspace && bd hooks install) 2>/dev/null \
                || dev-log error "bd hooks install failed during entrypoint" "git hooks not wired; run 'bd hooks install' manually" 2>/dev/null || true
            seed_beads_memories
        fi
        return 0
    fi

    # (B) or (C): .beads/ exists — heal only if bd status is broken. Without
    # metadata.json we can't know what to heal, so skip. Embedded mode needs no
    # server, so we probe bd directly rather than a Dolt port.
    [ -f "/workspace/.beads/metadata.json" ] || return 0
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
