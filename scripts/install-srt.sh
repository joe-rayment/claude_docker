#!/usr/bin/env bash
#
# Installs Anthropic's sandbox-runtime (srt), pinned, under
# <project>/.claude-dev/srt via `npm --prefix` (V1, claude-orca-qt9.1).
# Only actually installs when the pinned version isn't already there, so a
# second run is a no-op.
#
# Usage: install-srt.sh [<host dir>]   (default: this template's parent)

set -euo pipefail

SRT_VERSION="0.0.75"

_resolve_script_path() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        local link dir
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(cd "$(dirname "$src")" && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}
SCRIPT_DIR="$(cd "$(dirname "$(_resolve_script_path)")" && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"

HOST="${1:-$(host_dir)}"
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
