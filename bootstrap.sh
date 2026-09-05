#!/usr/bin/env bash
#
# claude_orca bootstrap -- run once per project folder (idempotent).
# Everything it installs lands under <project>/.claude-dev: the template
# clone, sandbox-runtime, Claude Code, Orca.app, and the bin/ symlinks the
# sandbox PATH leads with. There is no central install and no central Orca
# -- the only Orca for this project is the sandboxed one in the folder
# (V1, claude-orca-qt9.1; see .claude/plans/orca-port.md S9).
#
#   cd /path/to/your/project
#   gh api repos/joe-rayment/claude_orca/contents/bootstrap.sh \
#       -H "Accept: application/vnd.github.raw" | bash
#
# Or bootstrap a different directory:
#   ... | bash -s -- /path/to/project
#
# CI/Linux escape hatches: CLAUDE_ORCA_SKIP_BREW, CLAUDE_ORCA_SKIP_CLAUDE,
# CLAUDE_ORCA_SKIP_ORCA_DMG, CLAUDE_ORCA_SKIP_SELFTEST -- each skips only
# its own step, and claude-dev --doctor reports what was skipped.

set -euo pipefail

require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: '$1' is required but was not found on PATH." >&2
        exit 1
    }
}

require git
require gh

# CLAUDE_ORCA_SKIP_BREW=1 (Linux/CI hosts with no Homebrew) skips this
# requirement too, not just the `brew bundle` call below -- otherwise the
# skip flag was useless: bootstrap.sh died here before ever reaching it.
if [ "${CLAUDE_ORCA_SKIP_BREW:-0}" != "1" ]; then
    require brew
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "Error: gh is not authenticated -- run 'gh auth login' first." >&2
    exit 1
fi

PROJECT="${1:-$PWD}"
[ -d "$PROJECT" ] || { echo "Error: directory does not exist: $PROJECT" >&2; exit 1; }
PROJECT="$(cd "$PROJECT" && pwd -P)"
HOST="$PROJECT/.claude-dev"
TEMPLATE_URL="${CLAUDE_ORCA_TEMPLATE_URL:-https://github.com/joe-rayment/claude_orca.git}"

mkdir -p "$HOST"

echo "==> Installing the claude_orca template under $HOST/template"
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
"$HOST/template/scripts/install-srt.sh" "$HOST"

echo "==> Installing Claude Code"
"$HOST/template/scripts/install-claude.sh" "$HOST"

echo "==> Installing Orca"
"$HOST/template/scripts/install-orca.sh" "$HOST"

echo "==> Verifying tools"
"$HOST/template/scripts/install-tools.sh"

# The wrappers, as relative symlinks into the template clone: a `--update`
# pull picks up fixes with no re-bootstrap, and the whole folder stays
# movable. orca-launch lands V2 and may dangle until then -- the link is
# created anyway so the PATH entry never changes shape.
mkdir -p "$HOST/bin"
ln -sfn "../template/scripts/launcher.sh"              "$HOST/bin/claude-dev"
ln -sfn "../template/scripts/sandbox/claude-orca-root"  "$HOST/bin/claude-orca-root"
ln -sfn "../template/scripts/sandbox/claude-orca-shell" "$HOST/bin/claude-orca-shell"
ln -sfn "../template/scripts/sandbox/orca-launch"       "$HOST/bin/orca-launch"

exec "$HOST/bin/claude-dev" register "$PROJECT"
