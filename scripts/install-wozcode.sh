#!/bin/bash
# Install the Wozcode Claude Code plugin once Claude is authenticated.
#
# Idempotent: a marker file prevents repeated runs after a successful install.
# Bails silently if Claude isn't installed, the `plugin` subcommand isn't
# available in this build, or the user hasn't authenticated yet — the caller
# re-invokes on each container start / shell entry, so the install happens
# whenever the prerequisites are first met.
#
# Opt out: set CLAUDE_DEV_NO_WOZCODE=1.

[ "${CLAUDE_DEV_NO_WOZCODE:-}" = "1" ] && exit 0

MARKER="/home/agent/.config/.wozcode-installed"
[ -f "$MARKER" ] && exit 0

# Auth + capability checks
[ -f "/home/agent/.claude/.credentials.json" ] || exit 0
command -v claude >/dev/null 2>&1 || exit 0
claude plugin --help >/dev/null 2>&1 || exit 0

# Feed /dev/null to stdin so any unexpected interactive prompt errors out
# instead of hanging the entrypoint.
if claude plugin marketplace add WithWoz/wozcode-plugin </dev/null >/dev/null 2>&1 \
   && claude plugin install woz@wozcode-marketplace </dev/null >/dev/null 2>&1; then
    mkdir -p "$(dirname "$MARKER")"
    touch "$MARKER"
    command -v dev-log >/dev/null 2>&1 \
        && dev-log run "claude plugin install woz@wozcode-marketplace" pass "Wozcode plugin installed" >/dev/null 2>&1
else
    command -v dev-log >/dev/null 2>&1 \
        && dev-log error "Wozcode plugin install failed" "will retry on next container start; run install-wozcode manually to retry, or set CLAUDE_DEV_NO_WOZCODE=1 to skip" >/dev/null 2>&1
fi
