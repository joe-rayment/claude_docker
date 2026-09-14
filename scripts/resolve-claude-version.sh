#!/usr/bin/env bash
#
# resolve-claude-version.sh -- prints the Claude Code version the image
# build should install: latest, unless overridden. This lives OUTSIDE the
# docker build (called by scripts/launcher.sh, which turns the answer into
# `--build-arg CLAUDE_CODE_VERSION=<resolved>`) rather than inside a RUN
# layer, because a RUN step that resolved "latest" would be cached by
# Docker forever -- the very bug this script exists to fix: `claude-dev
# --update` would keep installing whatever version was current the day the
# layer was first built. Resolving here, before `docker build` even
# starts, means every build gets a fresh answer.
#
# It NEVER fails: this runs under callers' `set -e`, and a network blip
# (a captive portal, a DNS hiccup, downloads.claude.ai being briefly down)
# must not fail a build -- it should fall back to the last-known-good pin
# instead. So this script always exits 0 and always prints exactly one
# non-empty version string.
#
# CLAUDE_ORCA_CLAUDE_VERSION=<x.y.z> is the rollback escape hatch: set it
# and this makes NO network call at all, just echoes it back.
#
# Keep FALLBACK in lockstep with scripts/install-claude.sh's and
# scripts/container/setup.sh's CLAUDE_CODE_VERSION pin -- tests/
# container-image.bats and tests/container-entrypoint.bats assert all
# three match, character for character.

set -Eeuo pipefail

FALLBACK="2.1.271"

semver_ok() {
    printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

if [ -n "${CLAUDE_ORCA_CLAUDE_VERSION:-}" ] && semver_ok "${CLAUDE_ORCA_CLAUDE_VERSION}"; then
    printf '%s\n' "${CLAUDE_ORCA_CLAUDE_VERSION}"
    exit 0
fi

BASE="${CLAUDE_ORCA_CLAUDE_RELEASES_BASE:-https://downloads.claude.ai/claude-code-releases}"

body=""
body="$(curl -fsSL --max-time 10 "${BASE}/latest" 2>/dev/null)" || body=""
# Strip a trailing newline/whitespace; the endpoint may or may not send one.
body="$(printf '%s' "$body" | tr -d '[:space:]')"

if [ -n "$body" ] && semver_ok "$body"; then
    printf '%s\n' "$body"
else
    printf '%s\n' "$FALLBACK"
fi

exit 0
