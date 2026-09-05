#!/usr/bin/env bash
#
# install-claude.sh -- installs Claude Code, pinned, under
# <project>/.claude-dev/claude via `npm --prefix`, and links
# <project>/.claude-dev/bin/claude at it (V1, claude-orca-qt9.1; see
# .claude/plans/orca-port.md S9.2). That bin dir leads the sandbox PATH,
# so the only `claude` an agent in this folder can reach is this one --
# never a central install the user may also have.
#
# Usage: install-claude.sh [<host dir>]      (default: this template's parent)
#        install-claude.sh --print-version   (installed version, or exit 1)
#
# CLAUDE_ORCA_SKIP_CLAUDE=1 skips the install entirely (CI/Linux hosts):
# claude-dev --doctor then reports the row as missing rather than pretending.
# Only actually installs when the pinned version isn't already there, so a
# second run is a no-op.

set -euo pipefail

# The single pin. `npm view @anthropic-ai/claude-code version` moves this;
# nothing else in the template names a Claude Code version.
CLAUDE_CODE_VERSION="2.1.261"

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

MODE="install"
if [ "${1:-}" = "--print-version" ]; then
    MODE="print-version"
    shift
fi

HOST="${1:-$(host_dir)}"
CLAUDE_DIR="$HOST/claude"
PKG_JSON="$CLAUDE_DIR/node_modules/@anthropic-ai/claude-code/package.json"

# Read the installed version straight out of package.json -- no jq, no
# `node -e` (both stubbable, and node is the thing being installed for).
installed_version() {
    [ -f "$PKG_JSON" ] || return 1
    local v
    v="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PKG_JSON" \
        | head -1 | sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/')"
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}

if [ "$MODE" = "print-version" ]; then
    installed_version
    exit $?
fi

if [ "${CLAUDE_ORCA_SKIP_CLAUDE:-0}" = "1" ]; then
    echo "  skipped: Claude Code (CLAUDE_ORCA_SKIP_CLAUDE=1)"
    exit 0
fi

if ! command -v node >/dev/null 2>&1; then
    echo "Error: node is required but was not found on PATH." >&2
    exit 1
fi

mkdir -p "$CLAUDE_DIR"
if [ "$(installed_version || true)" != "$CLAUDE_CODE_VERSION" ]; then
    npm --prefix "$CLAUDE_DIR" install --no-audit --no-fund \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
fi

# Relative link, like every other entry in bin/: the whole folder stays
# movable, and nothing outside it is named.
mkdir -p "$HOST/bin"
ln -sfn "../claude/node_modules/.bin/claude" "$HOST/bin/claude"
