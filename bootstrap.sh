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
# mkdir/clone -- so a failed dependency costs nothing and leaves nothing
# behind. What the preflight finds missing it INSTALLS, then carries on in
# the same run: the Xcode Command Line Tools (git), the GitHub CLI, and
# Apple's signed `container` .pkg. Only the unfixable checks stop it -- not
# a Mac, not Apple silicon, or macOS older than 26.
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

# Everything past here is fixable, and the preflight fixes it. One scratch
# directory carries every download; it is removed when the preflight ends
# (and by the error trap if one of them fails).
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-orca-bootstrap.XXXXXX")"

# git ships inside the Xcode Command Line Tools. `softwareupdate` installs
# them headlessly when the on-demand trigger file exists; the GUI installer
# is the fallback, and the only one that needs a click.
if ! have git; then
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
    PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
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

# Apple ships `container` as a signed .pkg on its releases page; gh (now
# authenticated) fetches it and `installer` puts it in /usr/local/bin. The
# admin password is the only thing this asks of you.
if ! have container; then
    step "Installing Apple's container CLI (signed .pkg from github.com/apple/container/releases)"
    gh release download --repo apple/container \
        --pattern '*-installer-signed.pkg' --dir "$TMP_DIR" --clobber </dev/null || true
    CONTAINER_PKG="$(ls "$TMP_DIR"/*-installer-signed.pkg 2>/dev/null | head -1 || true)"

    if [ -z "$CONTAINER_PKG" ]; then
        {
            echo "Error: could not download Apple's 'container' installer."
            echo "  Get the signed installer (container-*-installer-signed.pkg) by hand from:"
            echo "    https://github.com/apple/container/releases"
            echo "  Then install it (it will ask for your password):"
            echo "    sudo installer -pkg ~/Downloads/container-installer-signed.pkg -target /"
            echo "  $RERUN_NOTE"
        } >&2
        exit 1
    fi

    echo "    macOS will ask for your password to run the installer."
    sudo installer -pkg "$CONTAINER_PKG" -target / </dev/null || true
    PATH="/usr/local/bin:$PATH"
    hash -r

    if ! have container; then
        {
            echo "Error: Apple's 'container' CLI is still not on PATH after installing it."
            echo "  Install the signed .pkg by hand from:"
            echo "    https://github.com/apple/container/releases"
            echo "    sudo installer -pkg ~/Downloads/container-installer-signed.pkg -target /"
            echo "  $RERUN_NOTE"
        } >&2
        exit 1
    fi
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

# The container service (one per Mac, not per project). Idempotent: a
# second call reports that it is already running, which is not an error.
# --enable-kernel-install answers, up front, the one question the CLI asks
# on stdin (whether to download the default Linux kernel) -- and stdin here
# is the rest of this script. An older CLI without the flag retries plain.
step "Starting the container service (container system start)"
service_rc=0
service_out="$(container system start --enable-kernel-install 2>&1 </dev/null)" || service_rc=$?
if [ "$service_rc" -ne 0 ]; then
    case "$service_out" in
        *"Unknown option"*|*"unexpected argument"*)
            service_rc=0
            service_out="$(container system start 2>&1 </dev/null)" || service_rc=$?
            ;;
    esac
fi
if [ "$service_rc" -ne 0 ]; then
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
