#!/usr/bin/env bash
#
# entrypoint.sh -- PID 1's payload inside the claude_orca Linux VM (v3 S1,
# claude-orca-qa2.1; see .claude/plans/container-v3.md S3-S4). Runs under
# tini as root, brings Orca up headless in serve mode as the `agent` user,
# and publishes the pairing URL the Mac side opens in a browser.
#
# Sequence: resolve the project -> re-map and drop to `agent` -> sync this
# template's config/ into the agent's Claude config dir -> start `--serve`
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
mkdir -p "$RUN_DIR" "$PROJECT_DIR/.claude-dev/home"

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
        chown -R "$AGENT_UID:$AGENT_GID" "$RUN_DIR" 2>/dev/null || true
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
[ "$PRIVDROP" = "1" ] && chown -R "$AGENT_UID:$AGENT_GID" "$USER_DATA_DIR" 2>/dev/null

# --- config-sync (best effort, never fatal) -----------------------------
#
# The project's own .claude-dev/template wins when a folder carries one;
# otherwise the copy baked into the image. config-sync writes into
# <project>/.claude-dev/home/.claude, which IS the agent's own config dir
# (the same directory, bind-mounted).

sync_host=""
if [ -d "$PROJECT_DIR/.claude-dev/template/config" ]; then
    sync_host="$PROJECT_DIR/.claude-dev"
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
    log "no template config found (looked in $PROJECT_DIR/.claude-dev and $HOST_DIR); skipping config-sync"
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
    log "registering project with Orca: $cli repo add --path $PROJECT_DIR"
    if command -v timeout >/dev/null 2>&1; then
        run_as_agent timeout 60 "$cli" repo add --path "$PROJECT_DIR" --json \
            >>"$SERVE_LOG" 2>&1 || warn "orca repo add failed (continuing)"
    else
        run_as_agent "$cli" repo add --path "$PROJECT_DIR" --json \
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
