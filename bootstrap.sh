#!/usr/bin/env bash
#
# claude_orca bootstrap -- thin installer, run once per machine (idempotent).
# Installs the host side under ~/.claude-orca (override: CLAUDE_ORCA_HOME)
# and registers a project directory. Everything it does is safe to re-run.
#
#   cd /path/to/your/project
#   gh api repos/joe-rayment/claude_orca/contents/bootstrap.sh \
#       -H "Accept: application/vnd.github.raw" | bash
#
# Or register a different directory:
#   ... | bash -s -- /path/to/project

set -euo pipefail

require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: '$1' is required but was not found on PATH." >&2
        exit 1
    }
}

require git
require gh
require brew

if ! gh auth status >/dev/null 2>&1; then
    echo "Error: gh is not authenticated -- run 'gh auth login' first." >&2
    exit 1
fi

HOST="${CLAUDE_ORCA_HOME:-$HOME/.claude-orca}"
TEMPLATE_URL="${CLAUDE_ORCA_TEMPLATE_URL:-https://github.com/joe-rayment/claude_orca.git}"

mkdir -p "$HOST"

echo "==> Installing claude_orca template under $HOST"
if [ -d "$HOST/template/.git" ]; then
    git -C "$HOST/template" pull --ff-only
else
    rm -rf "$HOST/template"
    git clone --quiet "$TEMPLATE_URL" "$HOST/template"
fi

if [ "${CLAUDE_ORCA_SKIP_BREW:-0}" != "1" ]; then
    echo "==> brew bundle (git, gh, jq, ripgrep, node, bats-core, beads)"
    brew bundle --file "$HOST/template/Brewfile"
fi

echo "==> Installing sandbox-runtime (srt)"
"$HOST/template/scripts/install-srt.sh"

echo "==> Verifying tools"
"$HOST/template/scripts/install-tools.sh"

mkdir -p "$HOST/bin"
ln -sf "$HOST/template/scripts/launcher.sh" "$HOST/bin/claude-dev"

exec "$HOST/bin/claude-dev" register "${1:-$PWD}"
