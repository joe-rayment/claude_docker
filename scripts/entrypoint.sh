#!/bin/bash
set -e

# FIX (beads_claude_docker-kk2): `kill -- -$$` sends SIGTERM to this
# process's own group, which includes the shell itself -- and with the trap
# below still armed, that self-inflicted signal re-enters cleanup() instead
# of terminating the shell, which sends the group signal again, recursing
# without bound. Driven for real via setsid + a real sleeping child + real
# SIGTERM (both delivered to this single PID -- confirmed docker-init/tini's
# production-faithful mode -- and delivered to the whole group): baseline
# reproduced ~2146-2392 nested re-entries every time, 0 of which ever
# completed past the `kill` line (a canary placed immediately after it never
# printed once), ending in a SIGSEGV stack-overflow crash (rc=139) after
# 0.6-2.8s of CPU-spinning. Appending an explicit `exit` after the kill was
# considered and driven too: dead on arrival, for the same reason the canary
# never printed -- that line is never reached, since re-entry happens AT the
# kill, before this function's own body can proceed any further. Resetting
# the trap FIRST, so the self-inflicted signal falls through to the default
# terminate action instead of re-entering this handler, is what actually
# works: driven the same way, 6/6 clean runs, both delivery modes -- exactly
# one trap invocation, a conventional exit status (143 = 128+SIGTERM, not
# 139), and the real sleeping child still reaped by the group kill before
# the shell itself terminates, so the trap's original purpose (take child
# processes down with the shell) is preserved, not traded away for the fix.
cleanup() { trap - SIGTERM SIGINT; kill -- -$$ 2>/dev/null; }
trap cleanup SIGTERM SIGINT

# Billing hard-guard (beads_claude_docker-q34): this container must run
# Claude Code on subscription auth only -- ANTHROPIC_BASE_URL/AUTH_TOKEN/
# API_KEY (process env, or the `.env` block of either settings file)
# silently flip billing to API, a hazard rather than a config choice. A
# FATAL refusal by default; CLAUDE_DEV_ALLOW_API_BILLING=1 downgrades to a
# warning and lets the container start anyway. Unlike the firewall block
# below, a failure here is NOT survivable: it stops the session before it
# starts, same diagnostic-then-hang shape as the /workspace check further
# down this file.
if [ -x /usr/local/bin/auth-guard.sh ]; then
    if ! /usr/local/bin/auth-guard.sh; then
        echo "   Container will stay alive for debugging. Run: docker exec -it <name> /bin/bash" >&2
        exec sleep infinity
    fi
fi

# Opt-in egress firewall (beads_claude_docker-0am): default-deny OUTPUT with
# an allowlist for the services this container talks to. OFF by default
# everywhere -- CLAUDE_DEV_FIREWALL=1 is the only thing that invokes it, and
# even then a refusal (no CAP_NET_ADMIN) only warns and lets the container
# keep starting -- a wrong or unapplied allowlist must never brick it. See
# knowledge-base/EGRESS_FIREWALL.md.
if [ "${CLAUDE_DEV_FIREWALL:-0}" = "1" ] && [ -x /usr/local/bin/egress-firewall.sh ]; then
    /usr/local/bin/egress-firewall.sh \
        || dev-log error "egress-firewall.sh failed to apply (CLAUDE_DEV_FIREWALL=1)" "container continuing with the firewall NOT applied -- run 'egress-firewall.sh --dry-run' to inspect the intended policy" 2>/dev/null || true
fi

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
#
# HARDENING (beads_claude_docker-9rk): a jq that exits 0 with EMPTY output
# (e.g. bd itself exits 0 printing nothing, or a broken jq silently no-ops)
# used to read back as "" -- the same value as a confirmed-empty prefix --
# forging the all-clear for the destructive rm -rf below. Guard against it
# structurally rather than by sniffing content: every successful extraction
# is prefixed with a "v:" sentinel marker that only a real, complete jq run
# over a "value"-bearing object can produce, so empty-but-"successful"
# output (no marker at all) is indistinguishable from any other failure and
# falls through to __unknown__. `has("value")` additionally requires the
# key to actually exist (not just be null) -- a future bd renaming/dropping
# that key hits the jq `error` branch (non-zero exit) rather than silently
# matching `// ""`.
_beads_issue_prefix() {
    local dir="$1"
    local raw="" bd_rc=0
    raw=$( (cd "$dir" && bd config get issue_prefix --json) 2>/dev/null ) || bd_rc=$?
    if [ "$bd_rc" != "0" ]; then
        printf '__unknown__'
        return 0
    fi
    local value="" jq_rc=0
    value=$(printf '%s' "$raw" | jq -r 'if has("value") then "v:" + (.value // "") else error end' 2>/dev/null) || jq_rc=$?
    if [ "$jq_rc" != "0" ] || [ "${value#v:}" = "$value" ]; then
        # Second half of the condition is the marker check: if stripping a
        # leading "v:" changes nothing, no marker was ever emitted (jq
        # failed silently, or produced no output at all) -- never conflate
        # that with a confirmed-empty prefix (which reads back as exactly
        # "v:" -> stripped to "").
        printf '__unknown__'
        return 0
    fi
    printf '%s' "${value#v:}"
}

# $1 (optional): project directory, defaults to /workspace. Parameterized so
# tests can exercise the real function body against a throwaway directory
# instead of /workspace (whose Dolt DB is the live, non-disposable one).
ensure_beads() {
    local dir="${1:-/workspace}"
    command -v bd &>/dev/null || return 0
    # This only ever detects dolt's ABSENCE, not a broken dolt -- driven
    # (beads_claude_docker-8zo): a `dolt` on PATH that exists but exits
    # nonzero on every invocation was shadowed in front of the real one for
    # both a fresh init (case A) and a full destructive rebuild (case B
    # escalation below), logging every invocation. Zero invocations were
    # observed in either run, and both completed exactly as they do with a
    # healthy dolt (database initialized, memories seeded / issues and
    # memories fully recovered) -- confirmed non-vacuous by removing dolt
    # from PATH entirely instead of shadowing it, which DOES trip this gate
    # and correctly leaves a corrupted fixture untouched. bd 1.0.4 embeds
    # Dolt directly and never execs the external binary for any command
    # ensure_beads uses, so a present-but-failing dolt is a no-op shape, not
    # a live risk.
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

    # SYMLINK GUARD (beads_claude_docker-8zo): driven, not theorized. A
    # `.beads/embeddeddolt` that is a symlink-to-directory is NOT a safe
    # no-op, even for read-only commands -- empirically, `bd status --json`
    # run with cwd correctly at $dir, against a project whose embeddeddolt is
    # a symlink to a healthy DB elsewhere, printed "no beads configuration
    # found" + a stray-permissions warning naming the SYMLINK TARGET's
    # parent directory (confirmed by re-running with the target placed
    # somewhere structurally unrelated to $dir -- the warning and the stray
    # database both followed the target, not $dir; the original repro
    # happened to place the target as a sibling of $dir, which coincidentally
    # made the two indistinguishable), reported total_issues=0 (the real
    # count was 1), and silently created a brand new, wrong, empty database
    # at "<parent-of-the-symlink-TARGET>/embeddeddolt/beads/" -- bd's own
    # project-root resolution gets lost chasing the symlink target, before
    # any of ensure_beads's own logic runs. So this can't be
    # guarded only at the destructive `rm -rf` site: it must fire before the
    # FIRST bd command below. Separately (and this is the reachable-in-
    # practice half): if repair ever proceeds past this point, the escalation
    # below does `rm -rf "$dir/.beads/embeddeddolt"` -- on a symlink that
    # removes only the link (confirmed: target and its contents survive,
    # untouched, orphaned) -- and the immediately following `bd init` then
    # builds a brand new database at the same path, beside the
    # preserved-but-now-unreferenced old one, with no error. Same
    # "unrepaired beats unprotected" choice as the safety_copy bail-out
    # below: bail out loud rather than silently resolve-and-adopt the
    # symlink's target (which could itself point somewhere unexpected).
    # Placed before the issues.jsonl gate so it fires even on an
    # empty-export project, and scoped to embeddeddolt specifically, as
    # named in the bead -- `.beads` itself being a symlink is a distinct,
    # undriven shape.
    if [ -L "$dir/.beads/embeddeddolt" ]; then
        dev-log error "ensure_beads: $dir/.beads/embeddeddolt is a symlink, not a real directory; skipping repair to avoid bd silently misreading the project root or a destructive rebuild orphaning the symlink's target -- replace it with a real directory (or restore from the target's data) and retry" 2>/dev/null || true
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

    # CONCURRENCY GUARD (beads_claude_docker-8zo): driven, not theorized --
    # 20x2-way runs of the repair logic below, launched concurrently against
    # byte-identical copies of the same corrupted fixture, came back clean
    # every time, but 5-way concurrency (15-20 iterations) reproducibly lost
    # both `bd remember` memories in ~13% of runs, with a follow-up batch
    # (per-contender dev-log capture) showing the exact mechanism: multiple
    # racing invocations each reach the escalation below independently, and
    # whichever one's own `rm -rf .../embeddeddolt` + reinit finishes LAST
    # wins the final on-disk state -- if that last writer's own
    # `bd export --include-memories` happened to run against a DB that a
    # DIFFERENT racing writer had *just* wiped mid-race, it captures a
    # transient, legitimately-empty snapshot (0 issues, 0 memories), which
    # the capture gate below correctly treats as "nothing to adopt" (not a
    # failure) rather than a fresh_ok=0 abort -- so it proceeds, importing
    # issues from the still-correct on-disk issues.jsonl (issues always
    # survived in every trial) but skipping memory-restore entirely, since
    # its own capture had none to restore. Concurrent invocations of this
    # whole repair path are consequently not safe against each other, so
    # only one may run at a time; the rest exit 0 having touched nothing,
    # exactly as they would after seeing the same result the winner reaches
    # anyway. flock's fd-scoped lock releases automatically on the holder's
    # exit for ANY reason, including a killed/crashed process, so there is
    # no stale-lock case to additionally guard against. Scoped to a subshell
    # (not `exec 9>` in this function's own shell) so the fd -- and the lock
    # with it -- closes when the subshell exits, rather than leaking through
    # the rest of entrypoint.sh and into the final `exec "$@"` that replaces
    # this process with the long-lived shell, which would hold the lock open
    # forever and silently disable repair for the rest of the container's
    # life. `flock -n 9 || ...` sits left of `||` per this file's own set -e
    # rule, so lock contention resolves to a normal, successful skip rather
    # than aborting entrypoint.sh's unconditional bare `ensure_beads` call at
    # the bottom of this file.
    if ! command -v flock &>/dev/null; then
        dev-log error "ensure_beads: flock unavailable; running beads repair WITHOUT concurrency protection (see beads_claude_docker-8zo for the race this normally guards against)" 2>/dev/null || true
    fi
    # A discardable `9>` probe (not touch) is what's guarded against
    # failing: proving the lockfile is OPENABLE FOR WRITE HERE, on its own
    # line with its own `||` per this file's rule for expected failures,
    # means the subshell below can be a plain, un-suffixed compound command
    # -- its exit status still propagates as ensure_beads's own return value
    # exactly as the unwrapped body's did before this change, so a genuine
    # bare unguarded failure inside it can still abort loudly under set -e
    # (the bats-can't-catch-this safety net this bead's own harness re-run
    # exists to check). A trailing `|| true` on the subshell itself was
    # tried and rejected: it also swallows that same abort signal for ANY
    # future bug inside the whole repair body, not just a lock-file-open
    # failure -- confirmed empirically, the positive-control harness run
    # (a bare `false` inserted just inside) kept reporting a clean exit
    # with that version.
    #
    # REGRESSION (beads_claude_docker-xgm), found by the final closure
    # audit: the first version of this probe used `touch`, which tests
    # CREATABILITY, not the OPENABILITY the subshell's own `9>` redirection
    # actually needs -- and those differ. A pre-existing SAME-USER lockfile
    # at mode 000 lets `touch` SUCCEED (an owner may set a file's timestamps
    # without holding write permission on it), so `lockfile` stayed pointed
    # at that unwritable tier-1 path, neither the TMPDIR tier nor the
    # `/dev/null` last resort was ever reached, and the subshell's bare
    # `9>"$lockfile"` then failed with "Permission denied" -- aborting
    # entrypoint.sh under set -e BEFORE the final `exec "$@"`. Confirmed
    # directly: an echo placed after the bare `ensure_beads` call at the
    # bottom of this file never printed. Probing with the SAME kind of
    # redirection the real acquisition uses (`: 9>"$lockfile"` in a
    # throwaway, discardable subshell) closes the gap -- open-for-write
    # success is a strict subset of touch's success (opening needs actual
    # write permission; touch's timestamp update accepts ownership alone),
    # so this probe can only degrade to the next tier in MORE cases than
    # before, never fewer, and every ordinary shape (writable file,
    # nonexistent-but-creatable path, read-only directory, another user's
    # file) still resolves exactly as it did. The identical exposure applies
    # to the TMPDIR tier below, so it gets the same probe.
    #
    # REGRESSION CAUGHT IN VERIFICATION (beads_claude_docker-8zo): an
    # unconditional bail-out here was a real loss of function, not a
    # harmless fast-path. Driven: chmod .beads a-w while embeddeddolt's own
    # contents and issues.jsonl stayed writable (a real, reachable shape --
    # `rm -rf` can empty a directory's contents without needing write on the
    # PARENT to unlink the directory entry itself, so at HEAD, before this
    # bead, that fixture's repair completed: `rm -rf .../embeddeddolt`
    # empties it in place and `bd init` rebuilds inside the same,
    # never-actually-removed directory entry). Bailing out here on a bare
    # `touch` failure regressed exactly that case. Fixed the same way the
    # missing-flock case above already is: fail open, log it -- an unlocked
    # repair is strictly better than no repair. Two-tier, same shape as the
    # safety_copy fallback below: tier 1 inside .beads/ (already
    # project-scoped by location, no extra uniqueness needed); tier 2 under
    # a now-SHARED ${TMPDIR:-/tmp} namespace if tier 1 fails, which is
    # exactly why tier 2 -- unlike safety_copy's own TMPDIR tier -- cannot
    # use mktemp: a mktemp'd path is unique PER INVOCATION, so two
    # concurrent runs against the same project would each lock a DIFFERENT
    # file and mutual exclusion would silently become a no-op while still
    # looking protected. Tier 2 is instead a deterministic name derived from
    # a checksum of the project's own absolute path, so concurrent runs
    # against the SAME project always compute the SAME tier-2 path and
    # genuinely collide (verified: the 5-way concurrency batch below was
    # re-run with tier 1 forced to fail, and serialization still held,
    # 0/30 memory loss). If neither tier is creatable (or hashing itself
    # fails), the last resort is /dev/null: not a real lock file, so the
    # inner flock attempt is skipped entirely rather than "locking" a
    # descriptor no other invocation shares -- the repair body still runs,
    # unprotected but not silently no-op-disguised-as-protected.
    #
    # HANG, NOT ABORT (beads_claude_docker-pef): an openability probe is only
    # as good as its ability to RETURN. A write-only open of a FIFO with no
    # reader attached does not fail fast -- it BLOCKS in open(2) until a reader
    # shows up, which for a lock path nobody reads is forever. So a FIFO
    # pre-placed at either lock path (by a buggy or hostile actor with this
    # UID; nothing in this repo creates one) parks the probe below, or -- with
    # the older creatability probe, which never opened the file -- the repair
    # subshell's own bare `9>"$lockfile"` one screenful down. Either way
    # ensure_beads never returns, entrypoint.sh never reaches its final
    # `exec "$@"`, and the container start looks like nothing happened at all:
    # strictly worse than the loud set -e abort above, which at least names
    # itself. The `[ -p ... ]` guard is what makes the probe bounded: it is a
    # pure stat(2), it short-circuits BEFORE the blocking open, and treating a
    # FIFO as unusable degrades it to the next tier exactly the way a
    # permission failure already does. Guarding tier selection also covers the
    # real acquisition below, which is the more dangerous of the two sites and
    # cannot itself be wrapped in a bounded-time open: fd 9 has to stay open
    # across the whole repair subshell, so a `timeout` around it would have to
    # outlive the repair it guards. The remaining TOCTOU (a FIFO swapped in
    # between this probe and that redirection) is deliberately out of scope --
    # it needs a same-UID actor racing a container start, and closing it
    # honestly means an O_NONBLOCK open the shell can't express.
    local lockfile="$dir/.beads/.ensure_beads.lock"
    if [ -p "$lockfile" ] || ! ( : 9>"$lockfile" ) 2>/dev/null; then
        local dir_abs="" dir_hash="" tmp_lockfile=""
        dir_abs=$( (cd "$dir" 2>/dev/null && pwd -P) 2>/dev/null ) || dir_abs="$dir"
        dir_hash=$(printf '%s' "$dir_abs" | cksum 2>/dev/null | cut -d' ' -f1)
        lockfile=""
        if [ -n "$dir_hash" ]; then
            tmp_lockfile="${TMPDIR:-/tmp}/beads-ensure-lock.$dir_hash"
            # Same `-p` guard as tier 1, and for the same reason: the shared
            # ${TMPDIR:-/tmp} namespace is if anything the easier of the two
            # paths to pre-place a FIFO at. Left of `&&`, so a FIFO here is an
            # expected failure that falls through to the /dev/null last resort
            # rather than aborting under set -e.
            [ ! -p "$tmp_lockfile" ] && ( : 9>"$tmp_lockfile" ) 2>/dev/null && lockfile="$tmp_lockfile"
        fi
        if [ -z "$lockfile" ]; then
            dev-log error "ensure_beads: cannot create a lock file in $dir/.beads or \${TMPDIR:-/tmp}; running repair WITHOUT concurrency protection" 2>/dev/null || true
            lockfile="/dev/null"
        fi
    fi
    (
    if [ "$lockfile" != "/dev/null" ] && command -v flock &>/dev/null; then
        flock -n 9 || { dev-log error "ensure_beads: another instance is already repairing this project's beads database (lock held); skipping this run" 2>/dev/null || true; exit 0; }
    fi

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
    local safety_copy="" safety_tmp=""
    safety_tmp=$(mktemp "${TMPDIR:-/tmp}/beads-issues-safety.XXXXXX" 2>/dev/null) || safety_tmp=""
    if [ -n "$safety_tmp" ]; then
        if cp "$dir/.beads/issues.jsonl" "$safety_tmp" 2>/dev/null; then
            safety_copy="$safety_tmp"
        else
            rm -f "$safety_tmp" 2>/dev/null || true
        fi
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
        # Only discard the safety net once the live file is confirmed
        # present -- if some earlier restore attempt silently failed and
        # left issues.jsonl missing/empty, this is the last copy.
        if [ -s "$dir/.beads/issues.jsonl" ]; then
            rm -f "$safety_copy" 2>/dev/null || true
        fi
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
    local init_rc=0 import_rc=0 did_destructive_rebuild=0
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
            # A live DB can legitimately be AHEAD of a stale on-disk
            # issues.jsonl (bd's own auto-export is throttled, so a recent
            # `bd create` can be missing from the last export), and it is
            # the ONLY place `bd remember` memories exist -- neither
            # issues.jsonl nor bd's own default export ever carries them
            # (confirmed via export-state.json's "memories":0 even with
            # memories present; `bd export` excludes them by design since
            # they may hold sensitive agent context). The `rm -rf` below
            # is the single point that can destroy both forever, so —
            # same "unrepaired beats unprotected" invariant as the
            # safety_copy bail-out above, applied to this destructive step
            # — it may only run once the capture has demonstrably
            # succeeded. A failed capture skips the destruction entirely
            # and leaves the DB broken-but-intact rather than rebuilding
            # from stale/absent data.
            #
            # Two-tier fallback identical in shape to safety_copy: mktemp
            # first (outside .beads/), then a fixed name inside .beads/ if
            # mktemp is unusable (full/read-only TMPDIR) -- the SAME
            # fallback also triggers if mktemp succeeds but `bd export`
            # itself fails or yields nothing, not only if mktemp fails.
            # `bd export` is read-only and works even in this
            # write-broken state (verified against a fixture with
            # issue_prefix missing). --include-memories pulls issues and
            # memories into one atomic snapshot; jq then splits them so
            # memories are NEVER written into issues.jsonl/safety_copy —
            # that file is git-tracked, so adopting the combined export
            # wholesale would leak memory content into git history.
            local fresh_export="" fresh_ok=0
            fresh_export=$(mktemp "${TMPDIR:-/tmp}/beads-issues-fresh.XXXXXX" 2>/dev/null) || fresh_export=""
            if [ -n "$fresh_export" ]; then
                if (cd "$dir" && bd export --include-memories -o "$fresh_export" --quiet) >/dev/null 2>&1 && [ -s "$fresh_export" ]; then
                    fresh_ok=1
                else
                    rm -f "$fresh_export" 2>/dev/null || true
                    fresh_export=""
                fi
            fi
            if [ "$fresh_ok" != "1" ]; then
                local fallback_fresh="$dir/.beads/issues.jsonl.fresh"
                if (cd "$dir" && bd export --include-memories -o "$fallback_fresh" --quiet) >/dev/null 2>&1 && [ -s "$fallback_fresh" ]; then
                    fresh_export="$fallback_fresh"
                    fresh_ok=1
                else
                    rm -f "$fallback_fresh" 2>/dev/null || true
                    fresh_export=""
                fi
            fi

            if [ "$fresh_ok" != "1" ]; then
                dev-log error "ensure_beads: cannot capture live DB state before embeddeddolt removal (mktemp and .beads/ fallback both failed, or bd export produced no data); skipping embeddeddolt rebuild -- any bd remember memories and any issues ahead of the last export stay at risk in the broken-but-intact DB rather than being rolled back to a stale one" 2>/dev/null || true
            else
                # Split the atomic capture: issues (candidate for
                # issues.jsonl/safety_copy adoption) vs memories (restored
                # straight into the rebuilt DB after import, never written
                # to a tracked file). Treat a jq failure as a capture
                # failure too -- a partial/unusable split must not
                # masquerade as success.
                local fresh_issues="${fresh_export}.issues" fresh_memories="${fresh_export}.memories"
                local split_ok=0
                if jq -c 'select(._type != "memory")' "$fresh_export" > "$fresh_issues" 2>/dev/null \
                    && jq -c 'select(._type == "memory")' "$fresh_export" > "$fresh_memories" 2>/dev/null; then
                    split_ok=1
                fi

                # Adopt the issues split only if the split is trustworthy
                # AND (when there's anything to adopt) both copies land
                # safely. A split that succeeded but yielded zero issue
                # lines is a legitimate "nothing to adopt" result (matches
                # the original -s guard: never let a genuinely-empty
                # result stomp a preserved-corrupt file); an adoption cp
                # failing partway is NOT that case and must block
                # destruction like any other capture failure.
                local adopt_ok=1
                if [ "$split_ok" != "1" ]; then
                    adopt_ok=0
                elif [ -s "$fresh_issues" ]; then
                    cp "$fresh_issues" "$dir/.beads/issues.jsonl" 2>/dev/null \
                        && cp "$fresh_issues" "$safety_copy" 2>/dev/null \
                        || adopt_ok=0
                fi

                if [ "$adopt_ok" != "1" ]; then
                    dev-log error "ensure_beads: captured live DB state but could not adopt it (jq split or copy failed); skipping embeddeddolt rebuild to avoid rolling back to a stale export" 2>/dev/null || true
                    rm -f "$fresh_export" "$fresh_issues" "$fresh_memories" 2>/dev/null || true
                else
                    # This is the ONE place that really performs the
                    # destructive rm -rf + reinit + import (beads_claude_docker-9rk):
                    # the flag below gates the "Rebuilt" success log at the
                    # bottom of this function so a run that skipped this
                    # branch (capture failed, adopt failed, or prefix_after
                    # turned out non-empty) can never claim credit for a
                    # rebuild that never happened -- whatever $total reports
                    # in that case is just the untouched original database.
                    did_destructive_rebuild=1
                    # HARDENING (beads_claude_docker-8zo): a real SIGTERM
                    # driven into the window right after this line was
                    # confirmed, empirically, to freeze the whole process
                    # (see the CONCURRENCY GUARD comment above this branch's
                    # entry point in the diff for the unrelated trap/cleanup
                    # defect this exposed, filed separately). When that
                    # happens, this is the LAST line proven to reach
                    # errors.log before things go dark -- confirmed by
                    # driving the signal for real: rm -rf ran, but the
                    # reinit below never started. Naming the capture paths
                    # here (rather than only in the memory-restore failure
                    # message further down, which never gets a chance to run
                    # in that exact scenario) turns "memories are gone,
                    # recoverable only by spelunking /tmp" into an actionable
                    # breadcrumb even when the process dies moments later:
                    # issues.jsonl/DB self-heal on the next run either way,
                    # but memories only come back via a manual
                    # `bd import $fresh_memories`.
                    dev-log error "ensure_beads: embeddeddolt present but issue_prefix missing after init+import; removing embeddeddolt and rebuilding (live capture at $fresh_export, issues at $fresh_issues, memories at $fresh_memories -- if this run is interrupted before completing, the next run recovers issues automatically but memories need a manual 'bd import $fresh_memories')" 2>/dev/null || true

                    rm -rf "$dir/.beads/embeddeddolt" 2>/dev/null || true
                    _beads_restore_export_if_missing "$dir" "$safety_copy"
                    (cd "$dir" && bd init --prefix "$prefix" --quiet --non-interactive) 2>/dev/null || true
                    _beads_restore_export_if_missing "$dir" "$safety_copy"
                    (cd "$dir" && bd import) 2>/dev/null || true
                    _beads_restore_export_if_missing "$dir" "$safety_copy"

                    # Restore memories directly into the rebuilt DB (never
                    # via issues.jsonl). On failure, preserve the capture
                    # instead of deleting it -- at that point it is the
                    # only remaining copy.
                    if [ -s "$fresh_memories" ]; then
                        if (cd "$dir" && bd import "$fresh_memories") 2>/dev/null; then
                            rm -f "$fresh_memories" 2>/dev/null || true
                        else
                            dev-log error "ensure_beads: memory restore failed after embeddeddolt rebuild; captured memories preserved at $fresh_memories -- import manually with 'bd import $fresh_memories'" 2>/dev/null || true
                        fi
                    else
                        rm -f "$fresh_memories" 2>/dev/null || true
                    fi
                    rm -f "$fresh_export" "$fresh_issues" 2>/dev/null || true
                fi
            fi
        fi
    fi

    total=$( (cd "$dir" && bd status --json) 2>/dev/null | jq -r '.summary.total_issues // 0' 2>/dev/null || echo 0)
    [ -z "$total" ] && total=0
    _beads_restore_export_if_missing "$dir" "$safety_copy"
    if [ -s "$dir/.beads/issues.jsonl" ]; then
        rm -f "$safety_copy" 2>/dev/null || true
    fi

    if [ "$init_rc" != "0" ] && [ "$import_rc" != "0" ] && [ "$did_destructive_rebuild" != "1" ]; then
        # (beads_claude_docker-9rk) The ordinary init+import pair both
        # failed AND the destructive escalation never actually ran (skipped
        # by one of its own guards: prefix_after wasn't confirmed-empty, or
        # the pre-destruction capture/adopt failed). $total here is just
        # whatever the untouched, still-broken database already reported --
        # never word that as a rebuild that happened.
        if [ "$total" != "0" ]; then
            # This run (bd init + bd import) genuinely failed and nothing
            # was repaired -- the reason text says so; the result field
            # must say so too, or runs.log misreports this exactly the way
            # the old wording misreported a rebuild.
            dev-log run "bd init + bd import" fail "Beads database left untouched with its pre-existing $total issue(s); destructive rebuild was skipped (see prior error for why)" 2>/dev/null || true
        else
            dev-log error "Beads auto-rebuild from issues.jsonl failed on startup" 2>/dev/null || true
        fi
    elif [ "$total" != "0" ]; then
        dev-log run "bd init + bd import" pass "Rebuilt Beads database from issues.jsonl on startup ($total issues)" 2>/dev/null || true
    else
        dev-log error "Beads auto-rebuild from issues.jsonl failed on startup" 2>/dev/null || true
    fi
    ) 9>"$lockfile"
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
