#!/bin/bash
# Install the Wozcode Claude Code plugin once Claude is authenticated.
#
# Self-healing: checks `claude plugin list` for actual install state, so a stale
# or missing marker doesn't block recovery, and a previously-failed install gets
# retried automatically. Marker file is a fast-path to skip the plugin-list check
# once we've confirmed install at least once.
#
# Bails silently if Claude isn't installed, the `plugin` subcommand isn't
# available in this build, or the user hasn't authenticated yet — the caller
# re-invokes (entrypoint, Stop hook, shell launcher) so install lands as soon
# as prerequisites are met.
#
# Flags:
#   --verbose   Print diagnostic output to stderr (default: silent)
#
# Opt out: set CLAUDE_DEV_NO_WOZCODE=1.

[ "${CLAUDE_DEV_NO_WOZCODE:-}" = "1" ] && exit 0

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1
log() { [ "$VERBOSE" = "1" ] && echo "install-wozcode: $*" >&2 || true; }

MARKER="/home/agent/.config/.wozcode-installed"
PLUGIN_NAME="woz@wozcode-marketplace"

# Auth + capability checks (silent bail — prerequisites not yet met)
if [ ! -f "/home/agent/.claude/.credentials.json" ]; then
    log "no credentials.json yet — skipping (will retry after auth)"
    exit 0
fi
if ! command -v claude >/dev/null 2>&1; then
    log "claude CLI not on PATH — skipping"
    exit 0
fi
if ! claude plugin --help >/dev/null 2>&1; then
    log "claude plugin subcommand unavailable — skipping"
    exit 0
fi

# Fast path: marker says we installed, and plugin list confirms it.
if [ -f "$MARKER" ] && claude plugin list 2>/dev/null | grep -qF "$PLUGIN_NAME"; then
    log "already installed (marker + plugin list)"
    exit 0
fi

# Slow path: verify against plugin list. If installed, write the marker and exit.
if claude plugin list 2>/dev/null | grep -qF "$PLUGIN_NAME"; then
    mkdir -p "$(dirname "$MARKER")"
    touch "$MARKER"
    log "plugin already present — marker refreshed"
    exit 0
fi

# Not installed — attempt install. Feed /dev/null so any unexpected interactive
# prompt errors out instead of hanging.
log "installing $PLUGIN_NAME…"
if claude plugin marketplace add WithWoz/wozcode-plugin </dev/null >/dev/null 2>&1 \
   && claude plugin install "$PLUGIN_NAME" </dev/null >/dev/null 2>&1; then
    mkdir -p "$(dirname "$MARKER")"
    touch "$MARKER"
    log "installed successfully"
    command -v dev-log >/dev/null 2>&1 \
        && dev-log run "claude plugin install $PLUGIN_NAME" pass "Wozcode plugin installed" >/dev/null 2>&1
else
    log "install failed — will retry on next invocation"
    command -v dev-log >/dev/null 2>&1 \
        && dev-log error "Wozcode plugin install failed" "will retry on next container start / Claude session end; run 'install-wozcode --verbose' to diagnose, or set CLAUDE_DEV_NO_WOZCODE=1 to skip" >/dev/null 2>&1
fi
