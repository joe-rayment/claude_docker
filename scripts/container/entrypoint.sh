#!/usr/bin/env bash
#
# entrypoint.sh -- PID 1's payload inside the claude_orca Linux VM (v3 S1,
# claude-orca-qa2.1; see .claude/plans/container-v3.md S3-S4). Runs under
# tini as root, brings Orca up headless in serve mode as the `agent` user,
# and publishes the pairing URL the Mac side opens in a browser.
#
# Sequence: resolve the project -> re-map and drop to `agent` -> sync this
# template's config/ into the agent's Claude config dir -> start the
# OpenRouter guard, which takes sole custody of the real key -> seed Orca's own
# state (worktree base path, theme, agent env) and `bd init` the project
# folder, both once -> start `--serve`
# with its output in <project>/.claude-dev/run/orca-serve.log -> wait for
# the "Web client URL:" line -> write run/orca-web-url.txt (0600, it
# carries the pairing code) and run/port -> register the project with
# `orca repo add` once -> wait on the serve process, which is what keeps
# the container alive.
#
# Environment:
#   PROJECT_DIR   required; the bind-mounted project, same absolute path
#                 as on the Mac.
#   ORCA_PORT     serve port (default 6768); mirrored to run/port.
#   ORCA_BIN      the Orca Linux binary (default /opt/orca/orca-ide).
#   ORCA_CLI      the Orca CLI (default: the one bundled next to ORCA_BIN,
#                 else the one serve installs into the agent's
#                 ~/.local/bin, else `orca`/`orca-ide` on PATH).
#   HOST_UID      the Mac uid owning the bind mount; `agent` is re-mapped
#                 to it so files written inside look right outside.
#   GH_TOKEN      passed through to the agent environment untouched.
#   CLAUDE_ORCA_THEME         dark|light|system for the seeded Orca
#                 settings (default dark); the Mac side passes
#                 claude-orca.json's `theme` through.
#   CLAUDE_ORCA_PROJECT_NAME  the beads prefix for `bd init` (default:
#                 the project folder's basename).
#   CLAUDE_ORCA_SKIP_BEADS=1  do not `bd init` the project folder.
#   CLAUDE_ORCA_GIT_NAME / CLAUDE_ORCA_GIT_EMAIL   the Mac's global git
#                 identity, copied into the agent's ~/.gitconfig on a
#                 folder that has none. Optional; may be empty.
#   CLAUDE_ORCA_SETUP         the install script (default:
#                 <template root>/scripts/container/setup.sh).
#   CLAUDE_ORCA_SKIP_SETUP=1  do not run it.
#   CLAUDE_ORCA_DNS_FALLBACK  resolver to prepend to resolv.conf when the
#                 VM cannot resolve names (default 1.1.1.1); an empty
#                 string disables the repair.
#   CLAUDE_ORCA_RESOLV_CONF   the file that repair edits (default
#                 /etc/resolv.conf; tests point it elsewhere).
#   CLAUDE_ORCA_DNS_PROBE_HOST  the name whose resolution decides whether
#                 DNS works (default ports.ubuntu.com).
#   OPENROUTER_API_KEY        the REAL OpenRouter key, if the folder has
#                 one. It goes to the in-VM guard and nowhere else: Orca
#                 (and so every terminal) gets the guard's token in this
#                 variable instead, plus OPENROUTER_BASE_URL.
#   CLAUDE_ORCA_GUARD_PORT    loopback port for the guard (4141).
#   CLAUDE_ORCA_GUARD_SCRIPT  the guard (default: the one next to this
#                 script).
#   CLAUDE_ORCA_GUARD_TIMEOUT seconds to wait for it to listen (30).
#   CLAUDE_ORCA_WEBURL_TIMEOUT        seconds to wait for serve (120).
#   CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1   skip usermod/setpriv (tests,
#                 and any run that is already unprivileged).
#
# bash 3.2 clean (scripts/lint-bash32.sh scans all of scripts/), even
# though the image ships bash 5.

set -uo pipefail

log()  { printf '[entrypoint] %s\n' "$*"; }
warn() { printf '[entrypoint] %s\n' "$*" >&2; }
die()  { printf '[entrypoint] %s\n' "$*" >&2; exit 1; }

# Recursive chown for the agent, minus the unix sockets. `chown -R` over
# the bind-mounted folder home returns EINVAL on a socket -- Orca leaves
# its own in .config/orca between boots -- and once it hits one the rest
# of the tree keeps the wrong owner while the error goes to /dev/null.
# Skipping sockets is what makes the chown actually complete. Best
# effort, like every chown on this side: never fatal, and the sockets
# themselves are left alone because something may still be using them.
chown_agent_tree() {
    find "$1" -xdev ! -type s -print0 2>/dev/null \
        | xargs -0 -r chown "$AGENT_UID:$AGENT_GID" 2>/dev/null || true
}

_resolve_script_path() {
    src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  src="$(cd "$(dirname "$src")" && pwd)/$link" ;;
        esac
    done
    printf '%s\n' "$src"
}
SCRIPT_DIR="$(cd "$(dirname "$(_resolve_script_path)")" && pwd -P)"
TEMPLATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

# A command given to the container runtime (after tini's `--`) wins over
# starting Orca: that is how CI runs smoke.sh in the built image, and how
# a person gets a shell in it without a running server.
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

# --- inputs -------------------------------------------------------------

PROJECT_DIR="${PROJECT_DIR:-}"
[ -n "$PROJECT_DIR" ] || die "PROJECT_DIR is required"
[ -d "$PROJECT_DIR" ] || die "PROJECT_DIR is not a directory: $PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"

ORCA_PORT="${ORCA_PORT:-6768}"
ORCA_BIN="${ORCA_BIN:-/opt/orca/orca-ide}"
WEBURL_TIMEOUT="${CLAUDE_ORCA_WEBURL_TIMEOUT:-120}"
AGENT_USER="${CLAUDE_ORCA_AGENT_USER:-agent}"
HOST_DIR="${CLAUDE_ORCA_HOST_DIR:-/opt/claude-orca-host}"

RUN_DIR="$PROJECT_DIR/.claude-dev/run"
SERVE_LOG="$RUN_DIR/orca-serve.log"
URL_FILE="$RUN_DIR/orca-web-url.txt"
PORT_FILE="$RUN_DIR/port"
SETUP_LOG="$RUN_DIR/setup.log"
mkdir -p "$RUN_DIR" "$PROJECT_DIR/.claude-dev/home"

# --- where the template is (startup v4, claude-orca-qa2.9) --------------
#
# The prebuilt image carries this repo at /opt/claude-orca. On a plain base
# image there is nothing there and the only copy is the folder's own clone,
# bind-mounted with the project -- which is also the copy this very script
# was read from. Everything template-shaped (setup.sh, config/) comes from
# the same root, so the two paths never mix.

if [ -d /opt/claude-orca ]; then
    TEMPLATE_ROOT="/opt/claude-orca"
else
    TEMPLATE_ROOT="$PROJECT_DIR/.claude-dev/template"
fi
log "template root: $TEMPLATE_ROOT"

# --- make sure the VM can resolve names --------------------------------
#
# A real Mac run on 2026-09-06 booted the base image into a VM whose
# resolv.conf pointed at nothing that answered: apt printed "Temporary
# failure resolving 'ports.ubuntu.com'" for every line and setup.sh died on
# a package name instead. Nothing here needs DNS more than that install
# does, so the check runs first, and a VM that cannot resolve gets a public
# resolver prepended. Never fatal: the worst case is the install failing
# the way it would have anyway, now with a warning that says why.

DNS_FALLBACK="${CLAUDE_ORCA_DNS_FALLBACK-1.1.1.1}"
RESOLV_CONF="${CLAUDE_ORCA_RESOLV_CONF:-/etc/resolv.conf}"
DNS_PROBE_HOST="${CLAUDE_ORCA_DNS_PROBE_HOST:-ports.ubuntu.com}"

dns_resolves() {
    getent hosts "$1" >/dev/null 2>&1
}

ensure_dns() {
    if dns_resolves "$DNS_PROBE_HOST"; then
        return 0
    fi
    if [ -z "$DNS_FALLBACK" ]; then
        warn "cannot resolve $DNS_PROBE_HOST and CLAUDE_ORCA_DNS_FALLBACK is empty; not touching $RESOLV_CONF"
        return 1
    fi
    if [ "$(id -u)" != "0" ]; then
        warn "cannot resolve $DNS_PROBE_HOST, and only root may repair $RESOLV_CONF; leaving it alone"
        return 1
    fi
    if grep -qx "nameserver $DNS_FALLBACK" "$RESOLV_CONF" 2>/dev/null; then
        warn "cannot resolve $DNS_PROBE_HOST even with nameserver $DNS_FALLBACK in $RESOLV_CONF; the toolchain install is going to fail"
        return 1
    fi
    log "cannot resolve $DNS_PROBE_HOST; prepending nameserver $DNS_FALLBACK to $RESOLV_CONF"
    # Written in place with cat, never mv: the runtime bind-mounts
    # resolv.conf, and a rename over a mount point fails with EBUSY.
    resolv_tmp="$RESOLV_CONF.claude-orca.tmp"
    {
        printf 'nameserver %s\n' "$DNS_FALLBACK"
        cat "$RESOLV_CONF" 2>/dev/null
    } > "$resolv_tmp" || { rm -f "$resolv_tmp"; warn "could not write $resolv_tmp"; return 1; }
    if ! cat "$resolv_tmp" > "$RESOLV_CONF"; then
        rm -f "$resolv_tmp"
        warn "could not write $RESOLV_CONF; the toolchain install is going to fail"
        return 1
    fi
    rm -f "$resolv_tmp"
    if dns_resolves "$DNS_PROBE_HOST"; then
        log "DNS repaired: $DNS_PROBE_HOST resolves via $DNS_FALLBACK"
        return 0
    fi
    warn "still cannot resolve $DNS_PROBE_HOST after adding nameserver $DNS_FALLBACK; the toolchain install is going to fail"
    return 1
}

ensure_dns || true

# --- install the toolchain (startup v4, claude-orca-qa2.9) --------------
#
# setup.sh is what the Dockerfile used to RUN at build time. Running it at
# every start instead is what makes a plain ubuntu:24.04 a usable VM: on
# the prebuilt image every phase is already satisfied and this costs
# seconds, on a base image the first start installs everything. It runs
# before the privilege drop because the phases need root (setup.sh checks
# per phase itself, so an unprivileged run -- the native test run -- is
# still safe).

SETUP="${CLAUDE_ORCA_SETUP:-$TEMPLATE_ROOT/scripts/container/setup.sh}"
log "setup: $SETUP"

if [ "${CLAUDE_ORCA_SKIP_SETUP:-0}" = "1" ]; then
    log "CLAUDE_ORCA_SKIP_SETUP=1; skipping setup"
elif [ ! -x "$SETUP" ]; then
    log "no setup script at $SETUP; skipping setup"
else
    # --check installs nothing and needs no root: it is only here to decide
    # whether to warn that this start is going to take minutes.
    if ! "$SETUP" --check >/dev/null 2>&1; then
        log "First start: installing the toolchain inside the VM (several minutes; progress in .claude-dev/run/setup.log)"
    fi
    if "$SETUP" 2>&1 | tee -a "$SETUP_LOG"; then
        log "setup done (log: $SETUP_LOG)"
    else
        die "setup.sh failed -- see $SETUP_LOG"
    fi
fi

# --- who we run Orca as -------------------------------------------------
#
# Under tini we start as root: re-map `agent` to the Mac uid that owns the
# bind mount (so writes from inside look right from outside), then drop.
# Anywhere unprivileged -- the native test run, a run with `--user` --
# we stay put and keep the caller's own HOME.

PRIVDROP=0
AGENT_HOME="${HOME:-/root}"
AGENT_UID=""
AGENT_GID=""

if [ "${CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP:-0}" != "1" ] && [ "$(id -u)" = "0" ]; then
    if id "$AGENT_USER" >/dev/null 2>&1; then
        if [ -n "${HOST_UID:-}" ] && [ "$HOST_UID" != "$(id -u "$AGENT_USER")" ]; then
            log "re-mapping $AGENT_USER to host uid $HOST_UID"
            usermod -u "$HOST_UID" "$AGENT_USER" \
                || warn "usermod to $HOST_UID failed (continuing)"
        fi
        AGENT_UID="$(id -u "$AGENT_USER")"
        AGENT_GID="$(id -g "$AGENT_USER")"
        AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
        [ -n "$AGENT_HOME" ] || AGENT_HOME="/home/$AGENT_USER"
        mkdir -p "$AGENT_HOME"
        chown "$AGENT_UID:$AGENT_GID" "$AGENT_HOME" 2>/dev/null || true
        chown_agent_tree "$RUN_DIR"
        PRIVDROP=1
    else
        warn "user $AGENT_USER not found; staying root"
    fi
fi

# Every child Orca process goes through one of these: the only place that
# knows whether to drop privileges, and the only place HOME is pinned.
run_as_agent() {
    if [ "$PRIVDROP" = "1" ]; then
        setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --init-groups -- \
            env HOME="$AGENT_HOME" "$@"
    else
        env HOME="$AGENT_HOME" "$@"
    fi
}

# The backgrounded variant. `&` on a function call forks a subshell, so
# without an explicit exec $! would be that subshell rather than Orca --
# and the TERM trap would signal a shell instead of the server. setpriv
# and env both exec too, so the pid survives the whole chain.
agent_exec() {
    if [ "$PRIVDROP" = "1" ]; then
        exec setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --init-groups -- \
            env HOME="$AGENT_HOME" "$@"
    else
        exec env HOME="$AGENT_HOME" "$@"
    fi
}

export GH_TOKEN="${GH_TOKEN:-}"
USER_DATA_DIR="${ORCA_USER_DATA_DIR:-$AGENT_HOME/.config/orca}"
mkdir -p "$USER_DATA_DIR"
[ "$PRIVDROP" = "1" ] && chown_agent_tree "$USER_DATA_DIR"

# --- config-sync (best effort, never fatal) -----------------------------
#
# The project's own .claude-dev/template wins when a folder carries one;
# otherwise the copy baked into the image. config-sync writes into
# <project>/.claude-dev/home/.claude, which IS the agent's own config dir
# (the same directory, bind-mounted).

# config-sync takes the dir ABOVE the template ($HOST/template/config), so
# the mounted clone is passed as its own parent and the image's copy through
# /opt/claude-orca-host/template, the symlink setup.sh's template phase made.
sync_host=""
if [ "$(basename "$TEMPLATE_ROOT")" = "template" ] && [ -d "$TEMPLATE_ROOT/config" ]; then
    sync_host="$(dirname "$TEMPLATE_ROOT")"
elif [ -d "$HOST_DIR/template/config" ]; then
    sync_host="$HOST_DIR"
fi
if [ -n "$sync_host" ]; then
    if run_as_agent "$TEMPLATE_DIR/scripts/config-sync.sh" \
            --project "$PROJECT_DIR" --host "$sync_host"; then
        log "config synced from $sync_host/template/config"
    else
        warn "config-sync failed (continuing without it)"
    fi
else
    log "no template config found (looked in $TEMPLATE_ROOT and $HOST_DIR/template); skipping config-sync"
fi

# --- seed the project folder (startup v4, claude-orca-qa2.9) ------------
#
# The four things `claude-dev register` used to seed on the Mac. They are
# all writes into the bind mount or the agent's HOME, so they belong to the
# side that can actually see the result, and they run before `bd init`
# because the snapshot restore is what that init must not clobber.
# Everything here is idempotent: a folder is started many times.

# Same entries and marker as launcher.sh's seed_gitignore: only the missing
# lines are appended, under one marker, and nothing existing is touched.
seed_gitignore() {
    gitignore="$PROJECT_DIR/.gitignore"
    touch "$gitignore" 2>/dev/null || return 0
    if ! grep -qF "# claude_orca" "$gitignore"; then
        {
            echo ""
            echo "# claude_orca"
        } >> "$gitignore"
    fi
    for pattern in '.claude-dev/' '.claude-dev-snapshots/' '/claude-dev' \
                   'Orca.app/' '.mcp.json' 'attachments/' '.claude/logs/'; do
        grep -qxF "$pattern" "$gitignore" || echo "$pattern" >> "$gitignore"
    done
}

# The other half of the launcher's beads round trip, and the reason it is
# safe to run unprompted: only ever when the project has no issues.jsonl of
# its own, so there is nothing here to lose. The Dolt DB rebuilds from the
# JSONL, which is why only these two files travel.
restore_beads_snapshot() {
    snap_root="$PROJECT_DIR/.claude-dev-snapshots"
    [ -d "$snap_root" ] || return 0
    [ -f "$PROJECT_DIR/.beads/issues.jsonl" ] && return 0
    latest="$(ls -1 "$snap_root" 2>/dev/null | sort -r | head -1)"
    [ -n "$latest" ] || return 0
    [ -f "$snap_root/$latest/issues.jsonl" ] || return 0

    mkdir -p "$PROJECT_DIR/.beads"
    cp "$snap_root/$latest/issues.jsonl" "$PROJECT_DIR/.beads/issues.jsonl"
    if [ -f "$snap_root/$latest/metadata.json" ]; then
        cp "$snap_root/$latest/metadata.json" "$PROJECT_DIR/.beads/metadata.json"
    fi
    log "restored beads snapshot $latest from $snap_root/$latest (the Dolt DB rebuilds from the JSONL)"
}

# A fresh .claude-dev/home has no git identity, so every commit inside the
# VM fails. The Mac passes exactly its user.name and user.email; nothing
# else follows the identity in, and an existing file always wins.
seed_git_identity() {
    gc="$AGENT_HOME/.gitconfig"
    [ -f "$gc" ] && return 0
    [ -n "${CLAUDE_ORCA_GIT_NAME:-}" ] || return 0
    [ -n "${CLAUDE_ORCA_GIT_EMAIL:-}" ] || return 0
    {
        printf '[user]\n'
        printf '\tname = %s\n' "$CLAUDE_ORCA_GIT_NAME"
        printf '\temail = %s\n' "$CLAUDE_ORCA_GIT_EMAIL"
    } > "$gc" || return 0
    log "seeded git identity in $gc"
}

# A Claude Code worker started in a fresh .claude-dev/home stops dead at
# two dialogs nobody is there to answer: the folder-trust prompt, then the
# bypass-permissions disclaimer that --dangerously-skip-permissions raises
# once per install. Both are ordinary config, so the entrypoint seeds them
# before Orca starts (claude-orca-qa2.17). Keys read off the shipped Claude
# Code binary: projects[<path>].hasTrustDialogAccepted and
# hasCompletedOnboarding in the home's .claude.json, and, in the config
# dir's settings.json, skipDangerousModePermissionPrompt -- what the dialog
# itself writes on accept (the older .claude.json
# bypassPermissionsModeAccepted migrates into it).
#
# Absent keys only: a value the user or the agent already set always wins,
# and a file that is not valid JSON is left untouched rather than replaced.
# This runs AFTER config-sync, which regenerates settings.json wholesale.
seed_json_key_absent() {
    seed_path="$1"
    seed_filter="$2"
    shift 2
    [ -f "$seed_path" ] || printf '{}\n' > "$seed_path" 2>/dev/null || return 1
    jq -e . "$seed_path" >/dev/null 2>&1 || {
        warn "$seed_path is not valid JSON; leaving it alone"
        return 1
    }
    seed_tmp="$seed_path.claude-orca.tmp"
    if jq "$@" "$seed_filter" "$seed_path" > "$seed_tmp" 2>/dev/null \
            && [ -s "$seed_tmp" ]; then
        mv -f "$seed_tmp" "$seed_path" || { rm -f "$seed_tmp"; return 1; }
        return 0
    fi
    rm -f "$seed_tmp"
    return 1
}

seed_claude_first_run() {
    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not found; skipping the Claude Code first-run seed"
        return 0
    fi

    if seed_json_key_absent "$AGENT_HOME/.claude.json" '
        (if has("hasCompletedOnboarding") then .
         else . + {hasCompletedOnboarding: true} end)
        | .projects = ((.projects // {}) as $pr
            | $pr + {($p): (($pr[$p] // {})
                | if has("hasTrustDialogAccepted") then .
                  else . + {hasTrustDialogAccepted: true} end)})
    ' --arg p "$PROJECT_DIR"; then
        log "seeded Claude Code trust for $PROJECT_DIR in $AGENT_HOME/.claude.json"
    else
        warn "could not seed $AGENT_HOME/.claude.json (continuing)"
    fi

    mkdir -p "$AGENT_HOME/.claude" 2>/dev/null
    if seed_json_key_absent "$AGENT_HOME/.claude/settings.json" '
        if has("skipDangerousModePermissionPrompt") then .
        else . + {skipDangerousModePermissionPrompt: true} end
    '; then
        log "seeded skipDangerousModePermissionPrompt in $AGENT_HOME/.claude/settings.json"
    else
        warn "could not seed $AGENT_HOME/.claude/settings.json (continuing)"
    fi
}

seed_gitignore
mkdir -p "$PROJECT_DIR/attachments"
restore_beads_snapshot
seed_git_identity
seed_claude_first_run

# Written as root when we are root: hand them to the agent, who is the one
# that edits them from here on.
if [ "$PRIVDROP" = "1" ]; then
    chown "$AGENT_UID:$AGENT_GID" "$PROJECT_DIR/.gitignore" \
        "$PROJECT_DIR/attachments" "$AGENT_HOME/.gitconfig" \
        "$AGENT_HOME/.claude.json" "$AGENT_HOME/.claude" \
        "$AGENT_HOME/.claude/settings.json" 2>/dev/null
    chown_agent_tree "$PROJECT_DIR/.beads"
fi

# --- the OpenRouter guard (claude-orca-qa2.21) --------------------------
#
# The user's rule is that their data never routes to China, and the only
# thing that can enforce it is a chokepoint no client can edit: the guard
# (scripts/container/openrouter-guard.py + config/provider-policy.json,
# claude-orca-qa2.20) holds the real OPENROUTER_API_KEY alone and forces
# provider.only/allow_fallbacks=false/data_collection=deny onto every
# completion request. It therefore starts HERE, before Orca and before the
# state seed that publishes its token, and what Orca -- and so every
# terminal Orca spawns -- inherits is the token and the guard's loopback
# base URL, never the key.
#
# Fail closed on the KEY, not on the boot: a guard that will not start
# leaves the VM without OpenRouter rather than with an unpoliced key in
# every terminal.

GUARD_PORT="${CLAUDE_ORCA_GUARD_PORT:-4141}"
GUARD_SCRIPT="${CLAUDE_ORCA_GUARD_SCRIPT:-$SCRIPT_DIR/openrouter-guard.py}"
GUARD_TIMEOUT="${CLAUDE_ORCA_GUARD_TIMEOUT:-30}"
GUARD_LOG="$RUN_DIR/openrouter-guard.log"
GUARD_PID_FILE="$RUN_DIR/openrouter-guard.pid"
GUARD_TOKEN_FILE="$RUN_DIR/openrouter-guard.token"
GUARD_BASE_URL="http://127.0.0.1:$GUARD_PORT/api/v1"
GUARD_PID=""
GUARD_TOKEN=""

guard_port_open() {
    python3 -c "import socket,sys
s = socket.socket()
s.settimeout(0.3)
sys.exit(0 if s.connect_ex(('127.0.0.1', $GUARD_PORT)) == 0 else 1)" \
        >/dev/null 2>&1
}

# Stable across restarts: the token is seeded into Orca's per-agent env,
# which is written once, so a fresh random token on every start would leave
# that seed pointing at a credential the guard no longer accepts.
guard_token() {
    if [ -s "$GUARD_TOKEN_FILE" ]; then
        head -1 "$GUARD_TOKEN_FILE" | tr -d '\r\n'
        return 0
    fi
    od -An -tx1 -N24 /dev/urandom 2>/dev/null | tr -d ' \n'
}

start_openrouter_guard() {
    if [ ! -f "$GUARD_SCRIPT" ]; then
        warn "no OpenRouter guard script at $GUARD_SCRIPT"
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        warn "python3 not found; cannot run the OpenRouter guard"
        return 1
    fi
    rm -f "$GUARD_PID_FILE"
    : > "$GUARD_LOG"
    [ "$PRIVDROP" = "1" ] && chown "$AGENT_UID:$AGENT_GID" "$GUARD_LOG" 2>/dev/null

    # agent_exec, not run_as_agent: the exec chain keeps $! the guard's own
    # pid rather than a wrapper subshell's. The real key is handed over
    # here and nowhere else.
    agent_exec env \
        OPENROUTER_API_KEY="$OPENROUTER_REAL_KEY" \
        OPENROUTER_GUARD_TOKEN="$GUARD_TOKEN" \
        CLAUDE_ORCA_RUN_DIR="$RUN_DIR" \
        python3 "$GUARD_SCRIPT" --port "$GUARD_PORT" --run-dir "$RUN_DIR" \
        >>"$GUARD_LOG" 2>&1 &
    GUARD_PID=$!

    guard_waited=0
    while [ "$guard_waited" -lt "$GUARD_TIMEOUT" ]; do
        if guard_port_open; then
            printf '%s\n' "$GUARD_PID" > "$GUARD_PID_FILE"
            if [ "$PRIVDROP" = "1" ]; then
                chown "$AGENT_UID:$AGENT_GID" "$GUARD_PID_FILE" \
                    "$GUARD_TOKEN_FILE" 2>/dev/null
            fi
            return 0
        fi
        kill -0 "$GUARD_PID" 2>/dev/null || break
        sleep 1
        guard_waited=$((guard_waited + 1))
    done
    kill -TERM "$GUARD_PID" 2>/dev/null
    GUARD_PID=""
    return 1
}

OPENROUTER_REAL_KEY="${OPENROUTER_API_KEY:-}"
if [ -n "$OPENROUTER_REAL_KEY" ]; then
    GUARD_TOKEN="$(guard_token)"
    # From this line on the real key exists only in the guard's own
    # environment: nothing downstream inherits it.
    unset OPENROUTER_API_KEY
    unset OPENROUTER_BASE_URL
    if [ -n "$GUARD_TOKEN" ] && start_openrouter_guard; then
        export OPENROUTER_API_KEY="$GUARD_TOKEN"
        export OPENROUTER_BASE_URL="$GUARD_BASE_URL"
        log "OpenRouter guard listening on $GUARD_BASE_URL (pid $GUARD_PID, log: $GUARD_LOG); agents get its token, never the key"
    else
        warn "the OpenRouter guard did not start -- the real OPENROUTER_API_KEY is NOT being passed to Orca (see $GUARD_LOG). Agents have no OpenRouter access this run; that is deliberate, because an unpoliced key in a terminal is exactly what the guard exists to prevent."
    fi
else
    log "no OPENROUTER_API_KEY; not starting the OpenRouter guard"
fi

# --- seed Orca's own state, once (claude-orca-qa2.5) --------------------
#
# Before serve starts, so Orca reads it rather than racing it: the
# project's worktree base path inside the folder, the theme, and the
# agent env. Never fatal -- an unseeded Orca still works, it just needs
# the settings pane.

if run_as_agent bash "$SCRIPT_DIR/seed-orca-state.sh" \
        --user-data-dir "$USER_DATA_DIR" \
        --project "$PROJECT_DIR" \
        --theme "${CLAUDE_ORCA_THEME:-}" \
        --openrouter-token "${OPENROUTER_API_KEY:-}" \
        --openrouter-base-url "${OPENROUTER_BASE_URL:-}"; then
    :
else
    warn "seeding Orca state failed (continuing)"
fi
if [ "$PRIVDROP" = "1" ]; then
    chown_agent_tree "$USER_DATA_DIR"
fi

# --- beads, once (claude-orca-qa2.5) ------------------------------------
#
# v3 does the tracker init in here rather than in `claude-dev register` on
# the Mac: bd lives in the image, not on the host, so this is the first
# place that can run it. Opt out with CLAUDE_ORCA_SKIP_BEADS=1.

if [ "${CLAUDE_ORCA_SKIP_BEADS:-0}" = "1" ]; then
    log "CLAUDE_ORCA_SKIP_BEADS=1; skipping bd init"
elif ! command -v bd >/dev/null 2>&1; then
    log "bd not on PATH; skipping bd init"
elif [ -e "$PROJECT_DIR/.beads" ]; then
    log "beads already initialized in $PROJECT_DIR; leaving it alone"
else
    bd_prefix="${CLAUDE_ORCA_PROJECT_NAME:-}"
    [ -n "$bd_prefix" ] || bd_prefix="$(basename "$PROJECT_DIR")"
    if ( cd "$PROJECT_DIR" && run_as_agent bd init --prefix "$bd_prefix" ) \
            >/dev/null 2>&1; then
        log "beads initialized in $PROJECT_DIR (prefix $bd_prefix)"
    else
        warn "bd init failed in $PROJECT_DIR (continuing)"
    fi
fi

# --- start Orca serve ---------------------------------------------------

[ -x "$ORCA_BIN" ] || die "ORCA_BIN is not executable: $ORCA_BIN"

: > "$SERVE_LOG"
[ "$PRIVDROP" = "1" ] && chown "$AGENT_UID:$AGENT_GID" "$SERVE_LOG" 2>/dev/null

log "starting Orca serve on port $ORCA_PORT (log: $SERVE_LOG)"
agent_exec "$ORCA_BIN" \
    --no-sandbox \
    --disable-gpu \
    --user-data-dir="$USER_DATA_DIR" \
    --serve \
    --port "$ORCA_PORT" \
    --project-root "$PROJECT_DIR" \
    >>"$SERVE_LOG" 2>&1 &
SERVE_PID=$!

stop_serve() {
    kill -TERM "$SERVE_PID" 2>/dev/null
    [ -n "${GUARD_PID:-}" ] && kill -TERM "$GUARD_PID" 2>/dev/null
}
trap 'stop_serve; exit 143' TERM INT

# --- wait for the Web client URL ----------------------------------------

web_url=""
waited=0
while [ "$waited" -lt "$WEBURL_TIMEOUT" ]; do
    web_url="$(sed -n 's/^.*Web client URL:[[:space:]]*\(http[^[:space:]]*\).*$/\1/p' \
        "$SERVE_LOG" 2>/dev/null | tail -1)"
    [ -n "$web_url" ] && break
    if ! kill -0 "$SERVE_PID" 2>/dev/null; then
        warn "orca serve exited before announcing a Web client URL -- see $SERVE_LOG"
        wait "$SERVE_PID"
        exit 1
    fi
    sleep 1
    waited=$((waited + 1))
done

if [ -z "$web_url" ]; then
    stop_serve
    warn "orca serve did not become ready within ${WEBURL_TIMEOUT} s -- see $SERVE_LOG"
    exit 1
fi

# The pairing code in that fragment is a credential: owner-only, and the
# mode is set before the URL lands in it.
: > "$URL_FILE"
chmod 600 "$URL_FILE"
printf '%s\n' "$web_url" > "$URL_FILE"
printf '%s\n' "$ORCA_PORT" > "$PORT_FILE"
if [ "$PRIVDROP" = "1" ]; then
    chown "$AGENT_UID:$AGENT_GID" "$URL_FILE" "$PORT_FILE" 2>/dev/null
fi
log "Orca web URL written to $URL_FILE"

# --- register the project with Orca, exactly once -----------------------

resolve_cli() {
    if [ -n "${ORCA_CLI:-}" ]; then
        printf '%s\n' "$ORCA_CLI"
        return 0
    fi
    for candidate in \
        "$(dirname "$ORCA_BIN")/resources/bin/orca-ide" \
        "$AGENT_HOME/.local/bin/orca-ide" \
        "$AGENT_HOME/.local/bin/orca"
    do
        [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    for name in orca orca-ide; do
        found="$(command -v "$name" 2>/dev/null)"
        [ -n "$found" ] && { printf '%s\n' "$found"; return 0; }
    done
    return 1
}

cli="$(resolve_cli)"
if [ -n "$cli" ]; then
    # The CLI finds the running server through its user-data dir, and it
    # defaults to Orca's own rather than the one serve was started with.
    # Without this the registration talks to a runtime that is not there
    # and fails silently (claude-orca-qa2.17).
    log "registering project with Orca: $cli repo add --path $PROJECT_DIR (ORCA_USER_DATA_PATH=$USER_DATA_DIR)"
    if command -v timeout >/dev/null 2>&1; then
        run_as_agent env ORCA_USER_DATA_PATH="$USER_DATA_DIR" \
            timeout 60 "$cli" repo add --path "$PROJECT_DIR" --json \
            >>"$SERVE_LOG" 2>&1 || warn "orca repo add failed (continuing)"
    else
        run_as_agent env ORCA_USER_DATA_PATH="$USER_DATA_DIR" \
            "$cli" repo add --path "$PROJECT_DIR" --json \
            >>"$SERVE_LOG" 2>&1 || warn "orca repo add failed (continuing)"
    fi
else
    warn "no Orca CLI found; skipping repo add"
fi

# --- the container lives as long as Orca serves -------------------------

log "Orca is serving; waiting on pid $SERVE_PID"
wait "$SERVE_PID"
status=$?
log "orca serve exited with status $status"
exit "$status"
