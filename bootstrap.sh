#!/usr/bin/env bash
#
# claude_orca bootstrap -- run once per project folder (idempotent).
#
# v3 (claude-orca-qa2.2; see .claude/plans/container-v3.md S5): the Mac
# installs almost nothing. Everything an agent runs lives inside one Linux
# container per project, started from the pinned image by Docker, so all
# this script leaves on the Mac is <project>/.claude-dev/{template,bin,
# home,run,state} -- no Homebrew bundle, no sandbox-runtime, and no
# shell-rc hook.
#
#   cd /path/to/your/project
#   gh api repos/joe-rayment/claude_docker/contents/bootstrap.sh \
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
        # Stock scopes: gh is here for the clone and for the token the
        # container's own gh uses. The image is built on this machine, so
        # nothing in this path needs read:packages any more.
        gh auth login --web --git-protocol https </dev/tty || true
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


# WHAT THE PREFLIGHT DECIDED, in one block, before anything is installed.
#
# Four days of diagnosis in September 2026 turned on questions the output
# could not answer: which gh account, what kind of token, which docker.
# The token no longer decides which image a folder runs -- the image is
# built here from the template clone -- but which account and which docker
# still decide whether the clone and the build work at all, and neither
# was written down, so a pasted log could not say what a folder had.
preflight_facts() {
    local token kind account
    echo "==> Preflight"
    if [ "$UNAME_S" = "Darwin" ]; then
        echo "    os          macOS $(sw_vers -productVersion 2>/dev/null || echo '?') ($(uname -m))"
    else
        echo "    os          $UNAME_S ($(uname -m))"
    fi
    echo "    git         $(git --version 2>/dev/null | head -1)"
    echo "    gh          $(gh --version 2>/dev/null | head -1)"
    account="$(gh api user --jq .login 2>/dev/null || true)"
    token="$(gh auth token 2>/dev/null || true)"
    case "$token" in
        gho_*|ghp_*|ghu_*|ghs_*) kind="classic OAuth token" ;;
        github_pat_*)            kind="fine-grained PAT" ;;
        "")                      kind="none" ;;
        *)                       kind="unrecognised" ;;
    esac
    echo "    account     ${account:-<not signed in>} ($kind)"
    echo "    docker      $(docker --version 2>/dev/null | head -1)"
}

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

preflight_facts

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
        echo "    Starting Docker Desktop; a cold start takes a couple of minutes."
        open -a Docker >/dev/null 2>&1 </dev/null || true
        docker_waited=0
        # 180s, not 60: a Docker Desktop that has not run since a reboot
        # takes longer than a minute to answer, and giving up on it sends
        # the user to a "start Docker" message while Docker is starting.
        while [ "$docker_waited" -lt 180 ]; do
            sleep 5
            docker_waited=$((docker_waited + 5))
            printf '.' >&2
            if docker_up; then printf '\n' >&2; break; fi
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
TEMPLATE_URL="${CLAUDE_ORCA_TEMPLATE_URL:-https://github.com/joe-rayment/claude_docker.git}"

step "Installing the claude_orca template under $HOST/template"

# A .claude-dev THIS template wrote has template/ and claude-orca.json in
# it. One from an older generation has neither, and installing on top of
# it leaves two layouts in one directory: the owner's own repo carried a
# git clone of the previous template (claude_docker, docker-compose era)
# with the current layout written into it as untracked files, and every
# diagnosis after that had to guess which generation a file belonged to.
#
# Bootstrap is piped into bash, so it cannot ask -- and it does not need
# to: moving the old directory aside is safe, because nothing in there is
# needed (beads live in <project>/.beads, not in here). So move it aside
# itself, say where it went, and carry on with the install in this same
# run. The Mac's Trash is preferred over a sibling .claude-dev.old-*: it
# is reversible by the usual means, and it leaves no untracked directory
# in the user's own repo -- the gitignore seed only covers .claude-dev/.
if [ -d "$HOST" ] \
    && [ ! -e "$HOST/claude-orca.json" ] \
    && [ ! -d "$HOST/template" ] \
    && [ -n "$(ls -A "$HOST" 2>/dev/null)" ]; then
    OLD_STAMP="$(date +%Y%m%d-%H%M%S)"
    if [ -d "${HOME:-/nonexistent}/.Trash" ] && [ -w "${HOME:-/nonexistent}/.Trash" ]; then
        OLD_DEST="$HOME/.Trash/claude-dev-$(basename "$PROJECT")-$OLD_STAMP"
    else
        OLD_DEST="$HOST.old-$OLD_STAMP"
    fi
    if mv "$HOST" "$OLD_DEST" 2>/dev/null; then
        echo "    an older claude_orca layout was in $HOST; moved it to $OLD_DEST (nothing in it is needed -- beads live in $PROJECT/.beads)"
    else
        {
            echo "Error: $HOST is from an older claude_orca layout, and could not be moved aside."
            echo "  Installing on top of it would leave two generations in one directory."
            echo "  Move it aside yourself and re-run this same command:"
            echo "    mv \"$HOST\" \"$HOST.old-$OLD_STAMP\""
            echo "  Nothing in it is needed -- this folder's beads live in $PROJECT/.beads."
        } >&2
        exit 1
    fi
fi

mkdir -p "$HOST"


if [ -d "$HOST/template/.git" ]; then
    # The template is a MANAGED clone: bootstrap writes it, --update pulls
    # it, and nothing in it is meant to be edited by hand. But things do
    # edit it -- an agent testing a patch, a half-finished experiment --
    # and `git pull --ff-only` then aborts with "your local changes would
    # be overwritten", which takes the whole bootstrap down with a git
    # error and no way forward that the message actually names. Stash the
    # changes instead: recoverable, named, and out of the pull's way.
    if [ -n "$(git -C "$HOST/template" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        echo "    the template clone has local changes; stashing them:"
        git -C "$HOST/template" status --short --untracked-files=no | sed 's/^/      /'
        if git -C "$HOST/template" stash push --quiet \
                -m "claude-orca bootstrap $(date -u +%Y-%m-%dT%H:%M:%SZ)"; then
            echo "      stashed -- recover with: git -C $HOST/template stash pop"
        else
            echo "      could not stash them; the pull below may fail" >&2
        fi
    fi
    # A clone made before the template moved repos (claude_orca ->
    # claude_docker) still points at the old one; follow TEMPLATE_URL.
    if [ "$(git -C "$HOST/template" remote get-url origin 2>/dev/null)" != "$TEMPLATE_URL" ]; then
        echo "    pointing the template clone at $TEMPLATE_URL"
        git -C "$HOST/template" remote set-url origin "$TEMPLATE_URL"
    fi
    git -C "$HOST/template" pull --ff-only
else
    rm -rf "$HOST/template"
    # Only the latest commit: the clone is a build context and a place to
    # `git pull --ff-only` into, never a history to read. (A local path
    # can't be shallow -- git warns and ignores --depth -- so only a URL
    # gets it.)
    depth=""
    case "$TEMPLATE_URL" in *://*|*@*:*) depth="--depth 1" ;; esac
    git clone --quiet $depth "$TEMPLATE_URL" "$HOST/template"
fi

# The wrappers, as relative symlinks into the template clone: a `--update`
# pull picks up fixes with no re-bootstrap, and the whole folder stays
# movable. The list lives in link-bin.sh, which `claude-dev --update`
# re-runs from the pulled template.
"$HOST/template/scripts/link-bin.sh" "$HOST"

# Ghostty, macOS only (claude-orca-9bh.8): the terminal the per-pane routing
# (`claude-dev ghostty`) lives in. Never fatal -- the container does not need
# it, so a missing terminal is a hint, not a failed bootstrap. Homebrew
# installs the cask when it is there; without Homebrew it is the download
# page. CLAUDE_ORCA_GHOSTTY_APP names the one .app to look for (the test
# seam), even when it points nowhere.
if [ "$UNAME_S" = "Darwin" ]; then
    GHOSTTY_APP=""
    if [ -n "${CLAUDE_ORCA_GHOSTTY_APP:-}" ]; then
        if [ -d "$CLAUDE_ORCA_GHOSTTY_APP" ]; then GHOSTTY_APP="$CLAUDE_ORCA_GHOSTTY_APP"; fi
    else
        for candidate in "/Applications/Ghostty.app" "$HOME/Applications/Ghostty.app"; do
            if [ -d "$candidate" ]; then
                GHOSTTY_APP="$candidate"
                break
            fi
        done
    fi
    if [ -z "$GHOSTTY_APP" ]; then
        if have brew; then
            step "Installing Ghostty (brew install --cask ghostty)"
            brew install --cask ghostty </dev/null || true
        else
            echo "Ghostty is not installed (optional). Download it from:"
            echo "    https://ghostty.org/download"
        fi
    fi
    step "Setting up Ghostty (claude-dev ghostty)"
    "$HOST/bin/claude-dev" ghostty || true
fi

# The terminal that ran the bootstrap line becomes the folder's first pane
# (on a new folder, the startup menu). Under `| bash` stdin is this script, so
# register would see no terminal and only print the pane command; /dev/tty is
# the terminal itself, the one sudo and gh auth login read above.
if [ -t 1 ] && ( : </dev/tty ) 2>/dev/null; then
    exec "$HOST/bin/claude-dev" register "$PROJECT" </dev/tty
fi
exec "$HOST/bin/claude-dev" register "$PROJECT"
