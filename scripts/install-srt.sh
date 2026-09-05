#!/usr/bin/env bash
#
# Installs Anthropic's sandbox-runtime (srt), pinned, under
# ${CLAUDE_ORCA_HOME:-$HOME/.claude-orca}/srt via `npm --prefix`. Only
# actually installs when the pinned version isn't already there, so a
# second run is a no-op.

set -euo pipefail

SRT_VERSION="0.0.75"
HOST="${CLAUDE_ORCA_HOME:-$HOME/.claude-orca}"
SRT_DIR="$HOST/srt"
PKG_JSON="$SRT_DIR/node_modules/@anthropic-ai/sandbox-runtime/package.json"

if ! command -v node >/dev/null 2>&1; then
    echo "Error: node is required (>= 20.11) but was not found on PATH." >&2
    exit 1
fi

node_version="$(node --version)"          # e.g. v24.0.0
node_version="${node_version#v}"
major="${node_version%%.*}"
rest="${node_version#*.}"
minor="${rest%%.*}"
if [ "$major" -lt 20 ] || { [ "$major" -eq 20 ] && [ "$minor" -lt 11 ]; }; then
    echo "Error: node >= 20.11 is required (found $node_version)." >&2
    exit 1
fi

# Read the installed version straight out of package.json without depending
# on jq or the (stubbable) node binary being able to run arbitrary -e code.
installed_version=""
if [ -f "$PKG_JSON" ]; then
    installed_version="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PKG_JSON" \
        | head -1 | sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/')"
fi

mkdir -p "$SRT_DIR"
if [ "$installed_version" != "$SRT_VERSION" ]; then
    npm --prefix "$SRT_DIR" install --no-audit --no-fund \
        "@anthropic-ai/sandbox-runtime@${SRT_VERSION}"
fi
