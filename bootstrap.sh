#!/usr/bin/env bash
#
# claude_orca bootstrap -- run once per project folder (idempotent).
#
# v3 (claude-orca-qa2.2; see .claude/plans/container-v3.md S5): the Mac
# installs almost nothing. Everything an agent runs lives inside one Linux
# VM per project, started from the pinned image by Apple's `container`, so
# all this script leaves on the Mac is <project>/.claude-dev/{template,
# bin,home,run,state} -- no Homebrew bundle, no sandbox-runtime, no Orca
# DMG, and no shell-rc hook.
#
#   cd /path/to/your/project
#   gh api repos/joe-rayment/claude_orca/contents/bootstrap.sh \
#       -H "Accept: application/vnd.github.raw" | bash
#
# Or bootstrap a different directory:
#   ... | bash -s -- /path/to/project
#
# Every precondition is checked in the preflight below, BEFORE the first
# mkdir/clone -- so a missing tool costs nothing and leaves nothing behind.
# This script is piped into bash, so stdin is the script itself: it never
# prompts, it only instructs.

set -Eeuo pipefail

CURRENT_STEP=""

step() {
    CURRENT_STEP="$*"
    echo "==> $*"
}

RERUN_NOTE="Then re-run this same command -- bootstrap is idempotent and picks up where it left off."

on_err() {
    {
        echo "Bootstrap failed during: ${CURRENT_STEP:-preflight}"
        echo "Fix the issue above, then re-run this same command -- bootstrap is idempotent and picks up where it left off."
    } >&2
}
trap on_err ERR

have() { command -v "$1" >/dev/null 2>&1; }

# --- preflight -------------------------------------------------------------

UNAME_S="$(uname -s)"

if ! have git; then
    {
        echo "Error: git is required but was not found on PATH."
        if [ "$UNAME_S" = "Darwin" ]; then
            xcode-select --install >/dev/null 2>&1 || true
            echo "  Opened the Xcode Command Line Tools installer -- click Install and wait"
            echo "  for it to finish (that is where macOS keeps git)."
        else
            echo "  Install git with your package manager, e.g. 'sudo apt-get install git'."
        fi
        echo "  $RERUN_NOTE"
    } >&2
    exit 1
fi

# Apple's `container` runs one lightweight Linux VM per container and needs
# macOS 26 on Apple silicon. There is no fallback: Docker Desktop is not
# what this template drives, and an Intel Mac cannot run it at all.
if [ "$UNAME_S" != "Darwin" ]; then
    {
        echo "Error: claude_orca needs macOS 26 or newer on Apple silicon -- this host reports $UNAME_S."
        echo "  Everything an agent runs lives in a Linux VM started by Apple's 'container'"
        echo "  CLI, which exists only on macOS."
    } >&2
    exit 1
fi

UNAME_M="$(uname -m)"
if [ "$UNAME_M" != "arm64" ] && [ "$UNAME_M" != "aarch64" ]; then
    {
        echo "Error: claude_orca needs Apple silicon -- this Mac reports $UNAME_M."
        echo "  Apple's 'container' CLI does not support Intel Macs."
    } >&2
    exit 1
fi

MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo 0)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
case "$MACOS_MAJOR" in
    ''|*[!0-9]*) MACOS_MAJOR=0 ;;
esac
if [ "$MACOS_MAJOR" -lt 26 ]; then
    {
        echo "Error: claude_orca needs macOS 26 or newer -- this Mac reports $MACOS_VERSION."
        echo "  Apple's 'container' CLI requires macOS 26."
    } >&2
    exit 1
fi

# A .pkg install needs an admin password, so it is instructed, never run.
if ! have container; then
    {
        echo "Error: Apple's 'container' CLI is required but was not found on PATH."
        echo "  Download the signed installer (container-*-installer-signed.pkg) from:"
        echo "    https://github.com/apple/container/releases"
        echo "  Then install it (it will ask for your password):"
        echo "    sudo installer -pkg ~/Downloads/container-installer-signed.pkg -target /"
        echo "  $RERUN_NOTE"
    } >&2
    exit 1
fi

if ! have gh; then
    {
        echo "Error: gh is required but was not found on PATH."
        echo "  Install it:  brew install gh"
        echo "  Or from https://github.com/cli/cli#installation"
        echo "  $RERUN_NOTE"
    } >&2
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    {
        echo "Error: gh is not authenticated -- run 'gh auth login' first."
        echo "  Authenticate:  gh auth login --web"
        echo "  $RERUN_NOTE"
    } >&2
    exit 1
fi

PROJECT="${1:-$PWD}"
[ -d "$PROJECT" ] || { echo "Error: directory does not exist: $PROJECT" >&2; exit 1; }
PROJECT="$(cd "$PROJECT" && pwd -P)"

if [ ! -w "$PROJECT" ]; then
    {
        echo "Error: cannot write to the project folder: $PROJECT"
        echo "  Everything claude_orca installs lands in $PROJECT/.claude-dev."
        echo "  Check who owns it:   ls -ld $PROJECT"
        echo "  Reclaim it:          sudo chown -R $(id -un) $PROJECT"
        echo "  $RERUN_NOTE"
    } >&2
    exit 1
fi

# The container service (one per Mac, not per project). Idempotent: a
# second call reports that it is already running, which is not an error.
step "Starting the container service (container system start)"
if ! service_out="$(container system start 2>&1)"; then
    case "$service_out" in
        *"already running"*|*"already started"*) ;;
        *)
            {
                printf '%s\n' "$service_out"
                echo "Error: 'container system start' failed."
                echo "  Check it by hand:  container system status"
                echo "  $RERUN_NOTE"
            } >&2
            exit 1
            ;;
    esac
fi

# --- install ---------------------------------------------------------------

HOST="$PROJECT/.claude-dev"
TEMPLATE_URL="${CLAUDE_ORCA_TEMPLATE_URL:-https://github.com/joe-rayment/claude_orca.git}"

mkdir -p "$HOST"

step "Installing the claude_orca template under $HOST/template"
if [ -d "$HOST/template/.git" ]; then
    git -C "$HOST/template" pull --ff-only
else
    rm -rf "$HOST/template"
    git clone --quiet "$TEMPLATE_URL" "$HOST/template"
fi

# The wrappers, as relative symlinks into the template clone: a `--update`
# pull picks up fixes with no re-bootstrap, and the whole folder stays
# movable. The list lives in link-bin.sh, which `claude-dev --update`
# re-runs from the pulled template.
"$HOST/template/scripts/link-bin.sh" "$HOST"

exec "$HOST/bin/claude-dev" register "$PROJECT"
