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
#
# Every dependency and precondition is checked in the preflight below,
# BEFORE the first mkdir/clone/install -- so a missing tool or an
# unwritable rc file costs nothing and leaves nothing behind. What can be
# fixed safely is fixed here (brew install gh, the Xcode CLT dialog);
# anything that needs you prints the exact command to paste and exits 1.
# This script is piped into bash, so stdin is the script itself: it never
# prompts, it only instructs.

set -Eeuo pipefail

CURRENT_STEP=""

# Every install step announces itself through step(), so the ERR trap can
# name the one that died instead of leaving a bare non-zero exit.
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

# CLAUDE_ORCA_SKIP_BREW=1 (Linux/CI hosts with no Homebrew) skips this
# requirement too, not just the `brew bundle` call below -- otherwise the
# skip flag was useless: bootstrap.sh died here before ever reaching it.
if [ "${CLAUDE_ORCA_SKIP_BREW:-0}" != "1" ] && ! have brew; then
    {
        echo "Error: brew (Homebrew) is required but was not found on PATH."
        if [ "$UNAME_S" = "Darwin" ]; then
            echo "  Install it (it will ask for your password):"
            echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        else
            echo "  This host is not macOS. Install Homebrew, or set CLAUDE_ORCA_SKIP_BREW=1"
            echo "  to skip every brew step."
        fi
        echo "  $RERUN_NOTE"
    } >&2
    exit 1
fi

# gh is the one dependency bootstrap can safely install for you: Homebrew
# is already present by this point on any host that has it.
if ! have gh && have brew; then
    step "Installing the GitHub CLI (brew install gh)"
    brew install gh || true
fi

if ! have gh; then
    {
        echo "Error: gh is required but was not found on PATH."
        if [ "$UNAME_S" = "Darwin" ]; then
            echo "  Install it:  brew install gh"
        else
            echo "  Install it from https://github.com/cli/cli#installation"
        fi
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

# A no-sudo reclaim of an rc file that exists but is not writable -- see
# rc_reclaim in scripts/launcher.sh, which this deliberately duplicates:
# the template that carries that copy has not been cloned yet at preflight
# time. Deleting a file needs write permission on its DIRECTORY, not on the
# file, so a root-owned-but-readable rc file can be rebuilt in place with
# identical contents and our own ownership. Returns 1 silently when that
# cannot apply, and the instructions below take over.
rc_reclaim() {
    local file="$1" dir tmp
    [ -e "$file" ] || return 1
    [ ! -w "$file" ] || return 1
    [ -r "$file" ] || return 1

    dir="$(dirname "$file")"
    [ -w "$dir" ] || return 1

    tmp="$(mktemp "$dir/.claude-orca-reclaim.XXXXXX")" || return 1
    if ! cat "$file" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if ! rm -f "$file" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$file"
    chmod 644 "$file"

    echo "==> Reclaimed $file: it was not writable (likely left root-owned by an installer); rebuilt with identical contents, now owned by $(id -un)" >&2
}

# Registration appends one marker-delimited block to each of these (see
# rc_install_one in scripts/launcher.sh); a root-owned or read-only rc file
# would fail there, after the clone and every install. Catch it here, while
# there is still nothing on disk to clean up -- reclaiming what can be
# reclaimed, and refusing only for what genuinely needs you. An absent file
# is fine only if $HOME itself can be written.
rc_unwritable=""
if [ -n "${HOME:-}" ]; then
    for rc in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile"; do
        if [ -e "$rc" ]; then
            if [ ! -w "$rc" ]; then
                rc_reclaim "$rc" || rc_unwritable="$rc_unwritable$rc
"
            fi
        elif [ ! -w "$HOME" ]; then
            rc_unwritable="$rc_unwritable$rc
"
        fi
    done
fi

if [ -n "$rc_unwritable" ]; then
    {
        echo "Error: the claude_orca shell hook cannot be installed -- these files are not writable:"
        printf '%s' "$rc_unwritable" | while IFS= read -r rc; do
            [ -n "$rc" ] || continue
            echo "  $rc"
            echo "    Check who owns it:   ls -l $rc"
            echo "    Reclaim it:          sudo chown $(id -un) $rc && chmod u+w $rc"
        done
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

if [ "${CLAUDE_ORCA_SKIP_BREW:-0}" != "1" ]; then
    step "brew bundle (git, gh, jq, ripgrep, node, bats-core, beads)"
    brew bundle --file "$HOST/template/Brewfile"
fi

step "Installing sandbox-runtime (srt)"
"$HOST/template/scripts/install-srt.sh" "$HOST"

step "Installing Claude Code"
"$HOST/template/scripts/install-claude.sh" "$HOST"

step "Installing Orca"
"$HOST/template/scripts/install-orca.sh" "$HOST"

step "Verifying tools"
"$HOST/template/scripts/install-tools.sh"

# The wrappers, as relative symlinks into the template clone: a `--update`
# pull picks up fixes with no re-bootstrap, and the whole folder stays
# movable. V5 (claude-orca-qt9.5): the list lives in link-bin.sh, which
# `claude-dev --update` re-runs from the pulled template -- so an entry
# point added upstream reaches existing folders too.
"$HOST/template/scripts/link-bin.sh" "$HOST"

exec "$HOST/bin/claude-dev" register "$PROJECT"
