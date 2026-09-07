#!/usr/bin/env bash
#
# claude_orca bootstrap -- run once per project folder (idempotent).
#
# v3 (claude-orca-qa2.2; see .claude/plans/container-v3.md S5): the Mac
# installs almost nothing. Everything an agent runs lives inside one Linux
# container per project, started from the pinned image by Docker, so all
# this script leaves on the Mac is <project>/.claude-dev/{template,bin,
# home,run,state} -- no Homebrew bundle, no sandbox-runtime, no Orca DMG,
# and no shell-rc hook.
#
#   cd /path/to/your/project
#   gh api repos/joe-rayment/claude_orca/contents/bootstrap.sh \
#       -H "Accept: application/vnd.github.raw" | bash
#
# Or bootstrap a different directory:
#   ... | bash -s -- /path/to/project
#
# Every precondition is checked in the preflight below, BEFORE the first
# mkdir/clone -- so a failed dependency costs nothing and leaves nothing
# behind. What the preflight finds missing it INSTALLS, then carries on in
# the same run: the Xcode Command Line Tools (git), the GitHub CLI, and
# Docker Desktop. Only the unfixable checks stop it -- an operating system
# that is neither macOS nor Linux, or a Docker that will not install.
#
# This script is piped into bash, so stdin is the script itself: it asks no
# questions of its own, and every child that could read stdin is given
# </dev/null so it can never swallow the rest of the script. The one prompt
# you will see is macOS asking for your admin password, which sudo reads
# from /dev/tty rather than stdin.

set -Eeuo pipefail

CURRENT_STEP=""

step() {
    CURRENT_STEP="$*"
    echo "==> $*"
}

RERUN_NOTE="Then re-run this same command -- bootstrap is idempotent and picks up where it left off."

on_err() {
    rm -rf "${TMP_DIR:-/nonexistent/claude-orca-bootstrap}" 2>/dev/null || true
    {
        echo "Bootstrap failed during: ${CURRENT_STEP:-preflight}"
        echo "Fix the issue above, then re-run this same command -- bootstrap is idempotent and picks up where it left off."
    } >&2
}
trap on_err ERR

have() { command -v "$1" >/dev/null 2>&1; }

# --- preflight -------------------------------------------------------------

UNAME_S="$(uname -s)"

# The runtime is Docker, so the host requirement is only that Docker can
# run on it: macOS (Docker Desktop) or Linux (any engine). Apple's
# `container` used to gate this on macOS 26 and Apple silicon; nothing here
# needs either any more, and dropping the gate is what lets CI exercise the
# same runtime the Mac drives.
case "$UNAME_S" in
    Darwin|Linux) ;;
    *)
        {
            echo "Error: claude_orca needs macOS or Linux -- this host reports $UNAME_S."
            echo "  Everything an agent runs lives in a Linux container started by Docker."
        } >&2
        exit 1
        ;;
esac

# Everything past here is fixable, and the preflight fixes it. One scratch
# directory carries every download; it is removed when the preflight ends
# (and by the error trap if one of them fails).
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-orca-bootstrap.XXXXXX")"

# git ships inside the Xcode Command Line Tools. `softwareupdate` installs
# them headlessly when the on-demand trigger file exists; the GUI installer
# is the fallback, and the only one that needs a click.
if ! have git && [ "$UNAME_S" = "Darwin" ]; then
    step "Installing the Xcode Command Line Tools (git)"
    CLT_TRIGGER="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    touch "$CLT_TRIGGER" 2>/dev/null || true
    CLT_LABEL="$(softwareupdate -l 2>/dev/null </dev/null \
        | grep -o 'Command Line Tools for Xcode-[0-9.]*' | sort | tail -1 || true)"
    if [ -n "$CLT_LABEL" ]; then
        echo "    macOS will ask for your password."
        sudo softwareupdate -i "$CLT_LABEL" --verbose </dev/null || true
    fi
    rm -f "$CLT_TRIGGER" 2>/dev/null || true
    hash -r

    if ! have git; then
        xcode-select --install </dev/null >/dev/null 2>&1 || true
        echo "    Click Install in the dialog that just opened; waiting for it to finish."
        CLT_WAITED=0
        while [ "$CLT_WAITED" -lt 1800 ]; do
            if xcode-select -p >/dev/null 2>&1; then
                hash -r
                # An `if`, not `have git && break`: under set -e a false
                # && at the end of the body would end the whole script.
                if have git; then break; fi
            fi
            sleep 5
            CLT_WAITED=$((CLT_WAITED + 5))
        done
        hash -r
    fi

    if ! have git; then
        {
            echo "Error: git is required but was not found on PATH."
            echo "  The Xcode Command Line Tools install did not finish -- run it by hand:"
            echo "    xcode-select --install"
            echo "  $RERUN_NOTE"
        } >&2
        exit 1
    fi
fi

# On Linux git comes from the distro, not from this script.
if ! have git; then
    {
        echo "Error: git is required but was not found on PATH."
        echo "  Install it with your package manager, e.g.:  sudo apt-get install -y git"
        echo "  $RERUN_NOTE"
    } >&2
    exit 1
fi

# gh: Homebrew when it is there, otherwise cli/cli's own signed macOS pkg.
if ! have gh; then
    step "Installing the GitHub CLI (gh)"
    if have brew; then
        brew install gh </dev/null || true
    else
        curl -fsSL -o "$TMP_DIR/gh-release.json" \
            https://api.github.com/repos/cli/cli/releases/latest </dev/null || true
        GH_PKG_URL="$(grep -o 'https://[^"]*macOS_universal\.pkg' \
            "$TMP_DIR/gh-release.json" 2>/dev/null | head -1 || true)"
        if [ -n "$GH_PKG_URL" ]; then
            curl -fsSL -o "$TMP_DIR/gh.pkg" "$GH_PKG_URL" </dev/null || true
        fi
        if [ -s "$TMP_DIR/gh.pkg" ]; then
            echo "    macOS will ask for your password to run the installer."
            sudo installer -pkg "$TMP_DIR/gh.pkg" -target / </dev/null || true
        fi
    fi
    # APPENDED, never prepended. Prepending puts the machine's own
    # /usr/local/bin ahead of everything the caller chose, which is how
    # tests/bootstrap.bats ended up driving a REAL docker daemon on a Mac:
    # the case hides docker from PATH, bootstrap "installs" it through the
    # brew stub, and this line then reached past the stub to the real
    # /usr/local/bin/docker -- a real container, a real 11-minute toolchain
    # install, and a suite that sat on it for 30 minutes. Appending still
    # finds a freshly installed binary, which is all this line is for.
    PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"
    hash -r

    if ! have gh; then
        {
            echo "Error: gh is required but was not found on PATH."
            echo "  Installing it did not work -- do it by hand:  brew install gh"
            echo "  Or from https://github.com/cli/cli#installation"
            echo "  $RERUN_NOTE"
        } >&2
        exit 1
    fi
fi

# gh auth login is interactive by nature, so it needs a terminal. sudo and
# gh both read /dev/tty, which survives this script arriving on stdin.
if ! gh auth status >/dev/null 2>&1; then
    if ( : </dev/tty ) 2>/dev/null; then
        step "Signing in to GitHub (gh auth login)"
        # read:packages: the prebuilt image is a private GHCR package, and a
        # token without that scope is denied its manifest -- which sends
        # the folder down the slow runtime-install path instead.
        gh auth login --web --git-protocol https --scopes read:packages </dev/tty || true
    fi
fi

if ! gh auth status >/dev/null 2>&1; then
    {
        echo "Error: gh is not authenticated -- run 'gh auth login' first."
        echo "  Authenticate:  gh auth login --web"
        echo "  $RERUN_NOTE"
    } >&2
    exit 1
fi

# The token's OAuth scopes, read the way scripts/launcher.sh's gh_has_scope
# reads them: the X-Oauth-Scopes header of an authenticated API call,
# lowercased, comma-matched. `gh auth status` prints them too, but its
# wording moves between gh versions and the header does not. Same three
# outcomes as the launcher's: 0 the header lists the scope, 1 the header is
# present and does not, 2 no header at all -- a fine-grained PAT or App
# token, whose scopes are unknown rather than missing and which `gh auth
# refresh` cannot change anyway.
gh_token_has_scope() {
    local header="" scopes=""
    header="$(gh api -i user 2>/dev/null \
        | tr -d '\r' \
        | tr '[:upper:]' '[:lower:]' \
        | sed -n 's/^x-oauth-scopes:/&/p' \
        | head -1)" || header=""
    [ -n "$header" ] || return 2
    scopes="$(printf '%s\n' "$header" \
        | sed 's/^x-oauth-scopes:[[:space:]]*//' \
        | tr -d '[:space:]')"
    case ",$scopes," in
        *",$1,"*) return 0 ;;
    esac
    return 1
}

# An existing classic login usually predates this template and carries
# gh's stock scopes only. Ask for read:packages now, while there is a
# terminal to answer in; when the refresh fails or there is no terminal,
# the folder still works -- it just installs its toolchain inside the VM
# instead. Only when the header SAYS the scope is missing: a token with no
# header is left alone, and the launcher simply attempts the pull.
SCOPE_RC=0
gh_token_has_scope read:packages || SCOPE_RC=$?
if [ "$SCOPE_RC" -eq 1 ] && ( : </dev/tty ) 2>/dev/null; then
    step "Adding the read:packages scope to the GitHub token (gh auth refresh)"
    echo "    With it the folder pulls the prebuilt image instead of installing the toolchain inside the VM for several minutes."
    gh auth refresh -h github.com -s read:packages </dev/tty || true
fi

# Docker is the runtime. On a Mac that means Docker Desktop, which
# Homebrew installs as a cask; without Homebrew there is nothing this
# script can safely install for you, so it names the download instead. On
# Linux the engine belongs to the distro.
if ! have docker; then
    if have brew; then
        step "Installing Docker Desktop (brew install --cask docker)"
        brew install --cask docker </dev/null || true
        PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"   # appended: see above
        hash -r
    fi
fi

if ! have docker; then
    {
        echo "Error: docker is required but was not found on PATH."
        if [ "$UNAME_S" = "Darwin" ]; then
            echo "  Install Docker Desktop by hand from:"
            echo "    https://www.docker.com/products/docker-desktop/"
            echo "  Or with Homebrew:"
            echo "    brew install --cask docker"
        else
            echo "  Install Docker Engine by hand from:"
            echo "    https://docs.docker.com/engine/install/"
        fi
        echo "  $RERUN_NOTE"
    } >&2
    exit 1
fi

rm -rf "$TMP_DIR"

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

# The Docker daemon (one per machine, not per project). `docker info`
# succeeding IS the daemon being up -- there is no service verb to call,
# and asking twice is idempotent by construction. On a Mac the daemon is
# Docker Desktop, which `open` starts and which takes a while to answer;
# on Linux the daemon is the host's business and this starts nothing.
step "Checking the Docker daemon (docker info)"
docker_up() { docker info >/dev/null 2>&1 </dev/null; }

if ! docker_up; then
    if [ "$UNAME_S" = "Darwin" ]; then
        echo "    Starting Docker Desktop; this can take a minute."
        open -a Docker >/dev/null 2>&1 </dev/null || true
        docker_waited=0
        while [ "$docker_waited" -lt 60 ]; do
            sleep 1
            docker_waited=$((docker_waited + 1))
            if docker_up; then break; fi
        done
    fi
fi

if ! docker_up; then
    {
        echo "Error: the Docker daemon is not responding -- 'docker info' failed."
        if [ "$UNAME_S" = "Darwin" ]; then
            echo "  Start Docker Desktop and wait for the whale to settle:"
            echo "    open -a Docker"
        else
            echo "  Start the daemon:"
            echo "    sudo systemctl start docker"
        fi
        echo "  $RERUN_NOTE"
    } >&2
    exit 1
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
