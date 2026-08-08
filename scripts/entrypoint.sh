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
    cp /etc/claude-dev/configs/claude-user-memory.md /home/agent/.claude/CLAUDE.md 2>/dev/null || true
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
#   (A) fresh project, no .beads/ at all        → bd init + bd hooks install
#   (B) .beads/issues.jsonl carries issues but the live Dolt DB reports zero,
#       OR the DB reports issues but its write path is broken (issue_prefix
#       config missing — bd status's count doesn't read that config, so a
#       count-only health check can call this "healthy" while bd create/bd
#       import stay silently broken forever: beads_claude_docker-a2s)
#       (a teardown/resume snapshot restore may drop in only issues.jsonl —
#       no config.yaml/embeddeddolt/metadata.json come with it)
#       → bd init --prefix (idempotent: refuses safely with a non-zero exit
#         if a Dolt DB already exists here, never reinitializes or touches
#         issues.jsonl — see `bd help init-safety`), then bd import (upsert
#         from issues.jsonl). NOT bd doctor --fix --yes: that subcommand is
#         unsupported in embedded Dolt mode and is a confirmed silent no-op.
#       If BOTH calls fail with embeddeddolt/ present and issue_prefix still
#       missing afterward, that's a reachable double-failure
#       (beads_claude_docker-cx8): remove embeddeddolt/ and retry the same
#       pair once, exporting the live DB first so a database that's ahead of
#       a stale on-disk export is never silently rolled back.
#   (C) healthy (DB already reports issues AND issue_prefix is configured,
#       or is a legitimately empty already-initialized project) → no-op,
#       silent
#
# Throughout (B), issues.jsonl is copied aside before any bd command touches
# this dir and restored immediately if a call wipes it out from under us:
# `bd status --json` — the very first bd call in (B) — silently DELETES a
# non-empty issues.jsonl when the issues table is empty and the export
# yields zero importable issue records, whether from a memory-only export,
# a missing required field (e.g. "title"), or a hard parse error/truncated
# mid-record line (beads_claude_docker-2fd). Empirically, the delete is
# gated behind bd's own throttled auto-export (default 60s since the last
# recorded export in .beads/export-state.json): well within the window bd
# just logs a warning and leaves the file alone, but once the throttle has
# elapsed the next such call deletes it regardless of which of the above
# shapes caused the zero-record result — so this safeguard is unconditional
# rather than pattern-matched to one shape.
detect_beads_prefix() {
    local dir="${1:-/workspace}"
    local prefix remote
    remote=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
    if [ -n "$remote" ]; then
        prefix=$(basename "$remote" .git 2>/dev/null || true)
    fi
    [ -z "${prefix:-}" ] && prefix="${CLAUDE_PROJECT_NAME:-}"
    [ -z "${prefix:-}" ] && prefix=$(basename "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")")
    echo "$prefix"
}

# Seed starter agent memories on a freshly-initialized beads DB. Called only
# from the fresh-init path (A), so it runs once per project.
seed_beads_memories() {
    local dir="${1:-/workspace}"
    (cd "$dir" && bd remember "NEVER assign beads to a user -- they are for Claude Code only. Anything that requires a user input should be handled in a question in chat.") 2>/dev/null \
        || dev-log error "bd remember seed failed during entrypoint" "starter memory not stored" 2>/dev/null || true
    (cd "$dir" && bd remember "Code changes must be tested in realistic settings, including running the actual program and taking screenshots.") 2>/dev/null \
        || dev-log error "bd remember seed failed during entrypoint" "starter memory not stored" 2>/dev/null || true
}

# Restore issues.jsonl from its pre-repair safety copy if a bd command wiped
# it out from under us (beads_claude_docker-2fd). No-op when there's no
# usable copy to restore from, or the live file is already present.
_beads_restore_export_if_missing() {
    local dir="$1" safety_copy="$2"
    [ -n "$safety_copy" ] && [ -s "$safety_copy" ] || return 0
    [ -s "$dir/.beads/issues.jsonl" ] && return 0
    cp "$safety_copy" "$dir/.beads/issues.jsonl" 2>/dev/null || true
}

# Read-only probe for the write path's actual dependency
# (beads_claude_docker-a2s): `bd status --json`'s issue count does not
# require issue_prefix to be configured, so a database can report a healthy
# non-zero count while bd create/bd import are broken ("issue_prefix config
# is missing"). NOTE: despite the name, `bd config get` is NOT actually
# side-effect-free -- like any other bd read, it can trigger the same
# throttled auto-export that deletes issues.jsonl on a zero-importable
# export (2fd). It's only safe to call here because every call site below
# follows it with _beads_restore_export_if_missing.
#
# Distinguishes FAILURE from EMPTY: a broken/missing jq must never be read
# as "no prefix configured", or a jq failure on a HEALTHY project forges
# the exact signature the embeddeddolt-removal escalation looks for. Echoes
# the configured prefix; "" only when bd and jq both ran and confirmed no
# prefix is set; the sentinel __unknown__ when `bd config get` exits
# non-zero or jq fails to parse its output (missing/broken jq, or bd
# emitting something jq can't read) -- never conflated with a
# confirmed-empty result.
_beads_issue_prefix() {
    local dir="$1"
    local raw="" bd_rc=0
    raw=$( (cd "$dir" && bd config get issue_prefix --json) 2>/dev/null ) || bd_rc=$?
    if [ "$bd_rc" != "0" ]; then
        printf '__unknown__'
        return 0
    fi
    local value="" jq_rc=0
    value=$(printf '%s' "$raw" | jq -r '.value // ""' 2>/dev/null) || jq_rc=$?
    if [ "$jq_rc" != "0" ]; then
        printf '__unknown__'
        return 0
    fi
    printf '%s' "$value"
}

# $1 (optional): project directory, defaults to /workspace. Parameterized so
# tests can exercise the real function body against a throwaway directory
# instead of /workspace (whose Dolt DB is the live, non-disposable one).
ensure_beads() {
    local dir="${1:-/workspace}"
    command -v bd &>/dev/null || return 0
    command -v dolt &>/dev/null || return 0
    command -v jq &>/dev/null || return 0
    [ -d "$dir/.git" ] || return 0

    if [ ! -d "$dir/.beads" ]; then
        # (A) fresh — initialize
        local prefix
        prefix=$(detect_beads_prefix "$dir")
        if ! (cd "$dir" && bd init --prefix "$prefix" --quiet) 2>/dev/null; then
            dev-log error "bd init failed during entrypoint" "prefix=$prefix; beads unavailable in this project" 2>/dev/null || true
        fi
        if [ -d "$dir/.beads" ]; then
            (cd "$dir" && bd hooks install) 2>/dev/null \
                || dev-log error "bd hooks install failed during entrypoint" "git hooks not wired; run 'bd hooks install' manually" 2>/dev/null || true
            seed_beads_memories "$dir"
        fi
        return 0
    fi

    # (B) or (C): .beads/ exists. Trigger repair on the thing that actually
    # matters — issues.jsonl carries data but the live DB reports none, or
    # the write path is broken even though the count looks fine — NOT on
    # metadata.json presence (that file is unrelated project-identity
    # metadata — dolt backend/project_id — not an issue count or health
    # signal, and a snapshot restore may legitimately omit it). An empty or
    # missing issues.jsonl alongside an empty DB is just a fresh,
    # legitimately-empty project: no-op.
    [ -s "$dir/.beads/issues.jsonl" ] || return 0

    # SAFEGUARD (beads_claude_docker-2fd): snapshot issues.jsonl before any
    # bd command below runs -- preferably outside .beads/ (mktemp), falling
    # back to a name inside .beads/ if mktemp is unusable (e.g. a full or
    # read-only TMPDIR). See the comment above detect_beads_prefix for
    # exactly what this protects against. Every step past this point
    # restores from the copy immediately if the live file goes missing, so
    # the export can never end up permanently lost — even in the "nothing
    # left to rebuild from" case. If NEITHER copy can be made, every
    # _beads_restore_export_if_missing call below would silently no-op, so
    # bail out here, unrepaired, rather than run bd commands that can
    # delete the only copy of the history with nothing left to restore it
    # from.
    local safety_copy=""
    safety_copy=$(mktemp "${TMPDIR:-/tmp}/beads-issues-safety.XXXXXX" 2>/dev/null) || safety_copy=""
    if [ -n "$safety_copy" ]; then
        cp "$dir/.beads/issues.jsonl" "$safety_copy" 2>/dev/null || safety_copy=""
    fi
    if [ -z "$safety_copy" ]; then
        local fallback_copy="$dir/.beads/issues.jsonl.bak"
        if cp "$dir/.beads/issues.jsonl" "$fallback_copy" 2>/dev/null; then
            safety_copy="$fallback_copy"
        else
            dev-log error "ensure_beads: cannot create a safety copy of issues.jsonl (mktemp and .beads/ fallback both failed); skipping repair to avoid unprotected data loss" 2>/dev/null || true
            return 0
        fi
    fi

    # HEALTH (beads_claude_docker-a2s): a non-zero issue count alone is not
    # "healthy" — require both the count AND the write path's config.
    local total
    total=$( (cd "$dir" && bd status --json) 2>/dev/null | jq -r '.summary.total_issues // 0' 2>/dev/null || echo 0)
    [ -z "$total" ] && total=0
    _beads_restore_export_if_missing "$dir" "$safety_copy"

    local prefix_val
    prefix_val=$(_beads_issue_prefix "$dir")
    _beads_restore_export_if_missing "$dir" "$safety_copy"

    if [ "$total" != "0" ] && [ -n "$prefix_val" ]; then
        rm -f "$safety_copy" 2>/dev/null || true
        return 0   # (C) healthy — DB has issues AND the write path works
    fi

    # (B) repair: (re)establish the Dolt workspace, then pull issues.jsonl
    # in. Both calls are safe to run unconditionally, even against a DB that
    # turns out to already be healthy:
    #   - plain `bd init` (never --reinit-local/--force) refuses with a
    #     non-zero exit if a Dolt DB already exists here; it never silently
    #     reinitializes or touches issues.jsonl.
    #   - `bd import` upserts; if the DB already matches the JSONL it exits
    #     non-zero ("nothing to commit"), a harmless, expected no-op.
    local prefix
    prefix=$(detect_beads_prefix "$dir")
    # init_rc/import_rc capture the real exit codes for the escalation guard
    # below WITHOUT tripping `set -e` (entrypoint.sh runs under it): `bd
    # init` failing with "already initialized" is the ordinary, expected
    # case whenever embeddeddolt/ already exists, not an error to abort on,
    # so the failing command must stay on the LEFT of `||` — never bare on
    # its own line — or the whole script would exit right here.
    local init_rc=0 import_rc=0
    (cd "$dir" && bd init --prefix "$prefix" --quiet --non-interactive) 2>/dev/null || init_rc=$?
    _beads_restore_export_if_missing "$dir" "$safety_copy"
    (cd "$dir" && bd import) 2>/dev/null || import_rc=$?
    _beads_restore_export_if_missing "$dir" "$safety_copy"

    # ESCALATION (beads_claude_docker-cx8): the reachable double-failure.
    # When embeddeddolt/ already exists but its issue_prefix config row is
    # gone, `bd init` refuses ("already initialized") and `bd import` also
    # fails ("issue_prefix config is missing") — both halves above fail.
    # Recovery needs one more step: remove embeddeddolt/ and retry the same
    # init+import pair. Guarded narrowly on the exact proven signature so
    # this can never fire against a DB that is merely healthy (already
    # returned above) or merely empty-but-correctly-initialized
    # (prefix_after would be non-empty there, and a legitimately-empty
    # project's issues.jsonl typically wouldn't even exist to pass the -s
    # gate above): both calls above must have failed, AND the read-only
    # probe must confirm issue_prefix is STILL missing after them, AND
    # embeddeddolt must actually exist to remove.
    if [ "$init_rc" != "0" ] && [ "$import_rc" != "0" ] && [ -d "$dir/.beads/embeddeddolt" ]; then
        local prefix_after
        prefix_after=$(_beads_issue_prefix "$dir")
        # "" here means KNOWN-empty (bd and jq both ran and confirmed no
        # prefix); the __unknown__ sentinel (non-empty) deliberately fails
        # this check too, so a broken/missing jq can never forge the
        # all-clear for this destructive step.
        if [ -z "$prefix_after" ]; then
            dev-log error "ensure_beads: embeddeddolt present but issue_prefix missing after init+import; removing embeddeddolt and rebuilding" 2>/dev/null || true

            # A live DB can legitimately be AHEAD of a stale on-disk
            # issues.jsonl (bd's own auto-export is throttled, so a recent
            # `bd create` can be missing from the last export). `bd export`
            # is read-only and works even in this write-broken state, so
            # capture the freshest truth before the destructive step below
            # — and only adopt it if it actually produced data, so a
            # genuinely-empty DB's 0-issue export can never stomp a
            # preserved-but-corrupt export (2fd's last-resort copy).
            local fresh_export
            fresh_export=$(mktemp "${TMPDIR:-/tmp}/beads-issues-fresh.XXXXXX" 2>/dev/null) || fresh_export=""
            if [ -n "$fresh_export" ]; then
                if (cd "$dir" && bd export -o "$fresh_export" --quiet) >/dev/null 2>&1 && [ -s "$fresh_export" ]; then
                    cp "$fresh_export" "$dir/.beads/issues.jsonl" 2>/dev/null || true
                    cp "$fresh_export" "$safety_copy" 2>/dev/null || true
                fi
                rm -f "$fresh_export" 2>/dev/null || true
            fi

            rm -rf "$dir/.beads/embeddeddolt" 2>/dev/null || true
            _beads_restore_export_if_missing "$dir" "$safety_copy"
            (cd "$dir" && bd init --prefix "$prefix" --quiet --non-interactive) 2>/dev/null || true
            _beads_restore_export_if_missing "$dir" "$safety_copy"
            (cd "$dir" && bd import) 2>/dev/null || true
            _beads_restore_export_if_missing "$dir" "$safety_copy"
        fi
    fi

    total=$( (cd "$dir" && bd status --json) 2>/dev/null | jq -r '.summary.total_issues // 0' 2>/dev/null || echo 0)
    [ -z "$total" ] && total=0
    _beads_restore_export_if_missing "$dir" "$safety_copy"
    rm -f "$safety_copy" 2>/dev/null || true

    if [ "$total" != "0" ]; then
        dev-log run "bd init + bd import" pass "Rebuilt Beads database from issues.jsonl on startup ($total issues)" 2>/dev/null || true
    else
        dev-log error "Beads auto-rebuild from issues.jsonl failed on startup" 2>/dev/null || true
    fi
}

ensure_beads

# Beads hygiene: silence the two warnings `bd` prints on every invocation.
#   - "permissions 0755 (recommended: 0700)" — the Dolt DB shouldn't be
#     group/world-readable.
#   - "beads.role not configured (GH#2950)" — bd falls back to a URL
#     heuristic without it, and nags until it's set explicitly.
# Idempotent and safe to run on every start regardless of which ensure_beads()
# branch ran (fresh init, repaired, or already-healthy): only touches the
# .beads/ directory's mode bits and a local (non-git-tracked) git config key,
# never issues.jsonl or the Dolt DB itself.
#
# Role choice: "maintainer" vs "contributor" are not interchangeable — bd
# init's own non-interactive default is "maintainer" (direct push access to
# origin); "contributor" is an opt-in OSS fork workflow (`bd init
# --contributor`, auto-sets sync.remote=upstream) for someone syncing a fork
# against an upstream they can't push to. Template projects are worked on
# directly against their own git remote's refs/dolt/data, so "maintainer" is
# the correct default here — matches what fresh (case A) `bd init` already
# picks on its own; this just makes it hold for case B/C repos too (cloned or
# already-initialized projects, where bd init never runs). Never overwrites
# an explicit role a user already configured.
ensure_beads_hygiene() {
    [ -d "/workspace/.beads" ] || return 0
    chmod 700 /workspace/.beads 2>/dev/null || true
    command -v bd &>/dev/null || return 0
    # -e (not -d): a worktree checkout or submodule has .git as a *file*
    # (gitdir: pointer), not a directory. -e accepts both shapes.
    [ -e "/workspace/.git" ] || return 0
    if [ -z "$(git -C /workspace config --get beads.role 2>/dev/null)" ]; then
        git -C /workspace config beads.role maintainer 2>/dev/null || true
    fi
}
ensure_beads_hygiene

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
