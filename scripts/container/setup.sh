#!/usr/bin/env bash
#
# setup.sh -- everything the image installs, as a script that can actually
# be RUN and checked outside a Docker build.
#
# The Dockerfile used to carry all of this as RUN steps, which meant none
# of it could be exercised on a box that cannot build containers: the only
# way to learn a step was wrong was to push and watch CI. Here the same
# logic is one bash script with idempotent phases, so
# scripts/container/verify-rootfs.sh can run it for real inside an Ubuntu
# 24.04 chroot and then re-run it to prove it settles.
#
# Usage:
#   setup.sh                 install everything that is not already there
#   setup.sh --check         verify the result; installs nothing, needs no root
#   setup.sh --phase <name>  run one phase
#   setup.sh --list          print the phase names in order
#
# Every version is pinned and overridable by env, which is how the
# Dockerfile passes its ARGs through: node's below, each toolchain phase's
# at the top of its own file under phases/ (loaded at the end of this one).

set -Eeuo pipefail

NODE_MAJOR="${NODE_MAJOR:-22}"

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

# Where global npm packages go. `npm root -g` says /usr/lib/node_modules,
# which the node .deb owns and the container layer holds -- so opencode's
# 352 MB would be re-downloaded on every recreate. /usr/local is the
# toolchain cache, so it is installed once per folder. Passed as --prefix
# on the one install that needs it rather than written into an npmrc: the
# npmrc for a /usr/local prefix would itself live in the cache.
NPM_PREFIX="${NPM_PREFIX:-/usr/local}"
npm_global_root() { printf '%s/lib/node_modules\n' "$NPM_PREFIX"; }

PHASES="base node gh orcadeps bats bd dolt helix opencode orca user template"

# WHERE EACH PHASE RUNS, and why the line falls here.
#
# A folder's toolchain cache is a bind mount (<project>/.claude-dev/
# toolchain, mounted over /usr/local and /opt/Orca), so it can
# hold FILES and nothing else. apt state is not files: it is /var/lib/dpkg,
# /etc, ld.so caches and a hundred paths across the filesystem, and a bind
# mount cannot carry any of it. So the line is drawn at apt:
#
#   IMAGE_PHASES      everything apt-managed -- the base packages, node,
#                     gh, and the GTK/at-spi/xvfb libraries Orca links
#                     against. Slow (~340 s) and almost never changes.
#   TOOLCHAIN_PHASES  the payload: six pinned tools that land under
#                     /usr/local and /opt/Orca and nowhere
#                     else. ~1.2 GB, ~340 s, and the half that actually
#                     churns -- a version bump here is a template pull,
#                     not an image rebuild. Claude Code is the exception:
#                     it is installed per folder by
#                     provision.d/15-claude-on-path, not here.
#
# A plain `setup.sh` still runs every phase in order, which is exactly what
# a folder with no prebuilt image does on its first start.
# `template` is in neither set on purpose: it only links a template that
# has to be COPYed in first, so the Dockerfile runs it by name after the
# copy, and a folder running the base image has nothing to link.
IMAGE_PHASES="base node gh orcadeps user"
TOOLCHAIN_PHASES="bats bd dolt helix opencode orca"

# The base apt set: only what Orca's own package does NOT already depend
# on. The .deb pulls libgtk-3-0, libnss3, libnotify4, libxss1, libxtst6,
# libsecret-1-0, libatspi2.0-0, libuuid1, xdg-utils, python3-gi,
# at-spi2-core, xdotool, xclip and xvfb, so hand-listing them here only
# invites drift.
#
# xvfb matters and arrives that way: `orca-ide --serve` refuses to start
# with no usable display server and spawns its OWN (Xvfb :99 -screen 0
# 1280x1024x24 -nolisten tcp -terminate) when the binary is present -- the
# image supplies it, never runs it. An image without it is what failed
# CI's first smoke stage.
#
# util-linux carries setpriv, which the entrypoint uses to drop root;
# libasound2t64 is 24.04's spelling of libasound2.
BASE_PACKAGES="ca-certificates curl wget gnupg git jq ripgrep zsh less
python3 python3-pip locales tini util-linux procps psmisc
build-essential unzip xz-utils sudo
libasound2t64 libgbm1 xauth fonts-liberation"

# Elapsed seconds, not a clock: this log is read to find out which phase
# cost the minutes, and $SECONDS answers that without the reader having to
# subtract anything (recovery plan step 0.2).
say()  { printf '[setup +%ss] %s\n' "$SECONDS" "$*"; }
warn() { printf '[setup +%ss] %s\n' "$SECONDS" "$*" >&2; }
die()  { printf '[setup +%ss] error: %s\n' "$SECONDS" "$*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "must run as root (phase: ${1:-all})"
}

# arm64/amd64, the way dpkg and most release assets spell it.
deb_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo amd64 ;;
        arm64|aarch64) echo arm64 ;;
        *) die "unsupported arch: $(uname -m)" ;;
    esac
}

# The way downloads.claude.ai spells it.
claude_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo x64 ;;
        arm64|aarch64) echo arm64 ;;
        *) die "unsupported arch: $(uname -m)" ;;
    esac
}

apt_cleanup() {
    apt-get clean
    rm -rf /var/lib/apt/lists/*
}

# `apt-get update` on a VM with no working DNS exits 0 after printing
# "Temporary failure resolving" for every source, and the failure then
# surfaces one step later as "Unable to locate package <first package>" --
# a real Mac run on 2026-09-06 read that as a packaging bug. So the update
# is checked here, output and exit status both, and dies naming the real
# cause and the fix.
apt_update_or_die() {
    local out="" rc=0
    out="$(apt-get update 2>&1)" || rc=$?
    [ -n "$out" ] && printf '%s\n' "$out"
    if [ "$rc" -ne 0 ] || printf '%s\n' "$out" | grep -q 'Temporary failure resolving'; then
        die "the VM has no working DNS: apt cannot reach the Ubuntu archive (apt-get update exit $rc). Set \"dns\" in <project>/.claude-dev/claude-orca.json (e.g. \"1.1.1.1\") and restart the folder with ./claude-dev"
    fi
}

node_major() {
    command -v node >/dev/null 2>&1 || return 1
    node --version 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\)\..*/\1/p'
}

stamp() {
    # stamp <file> -- the pinned version a previous run wrote, if any.
    [ -f "$1" ] || return 1
    tr -d '[:space:]' < "$1"
}

# --- base tooling + the Electron runtime libraries Orca needs -----------
#
# GNU coreutils' stty must be the one on PATH: Claude Code saves and
# restores terminal state with `stty -g`, and uutils' stty can save but
# not restore. 24.04 ships GNU already -- the repair below only fixes a
# base that does not.
phase_base() {
    need_root base
    local missing=0 p
    for p in $BASE_PACKAGES; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null \
            | grep -q '^install ok installed$' || { missing=1; break; }
    done
    if [ "$missing" -eq 0 ] && locale -a 2>/dev/null | grep -qix 'en_US\.utf-\?8'; then
        say "base: packages and en_US.UTF-8 already present"
    else
        say "base: installing apt packages and generating en_US.UTF-8"
        apt_update_or_die
        # shellcheck disable=SC2086
        apt-get install -y --no-install-recommends $BASE_PACKAGES
        locale-gen en_US.UTF-8
        apt_cleanup
    fi

    if ! stty --version 2>/dev/null | grep -q 'GNU coreutils'; then
        say "base: repairing stty -> /usr/bin/gnustty"
        test -x /usr/bin/gnustty && ln -sf /usr/bin/gnustty /usr/bin/stty
    fi
    stty --version | grep -q 'GNU coreutils'
}

# --- Node (nodesource) --------------------------------------------------
phase_node() {
    need_root node
    if [ "$(node_major || true)" = "$NODE_MAJOR" ]; then
        say "node: $(node --version) already present"
        return 0
    fi
    say "node: installing ${NODE_MAJOR}.x from nodesource"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y --no-install-recommends nodejs
    apt_cleanup
    node --version
}

# --- GitHub CLI ---------------------------------------------------------
phase_gh() {
    need_root gh
    if command -v gh >/dev/null 2>&1; then
        say "gh: $(gh --version | head -1) already present"
        return 0
    fi
    say "gh: installing from the GitHub CLI apt repo"
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
    apt_update_or_die
    apt-get install -y --no-install-recommends gh
    apt_cleanup
    gh --version
}

# --- Orca's apt dependencies (image phase) ------------------------------
#
# These used to arrive for free: the .deb was installed with apt at build
# time and apt pulled its Depends. The payload now installs at first start
# into the folder's toolchain cache, which is a bind mount and cannot hold
# apt state -- so the libraries Orca links against have to be here, in the
# image, hand-listed.
#
# Hand-listing invites drift, so phase_orca CHECKS it: it reads Depends
# straight out of the .deb it just downloaded and dies naming any package
# that is missing. The list is 24.04's real package names (the .deb asks
# for libgtk-3-0 and libatspi2.0-0, which 24.04 ships as the t64 variants).
#
# xvfb matters and is why it is here: `orca-ide --serve` refuses to start
# with no usable display server and spawns its own Xvfb when the binary is
# present. An image without it is what failed CI's first smoke stage.
ORCA_PACKAGES="libgtk-3-0t64 libnotify4 libnss3 libxss1 libxtst6 xdg-utils
libatspi2.0-0t64 libuuid1 libsecret-1-0 python3 python3-gi
gir1.2-atspi-2.0 at-spi2-core xdotool xclip xvfb"

phase_orcadeps() {
    need_root orcadeps
    local missing=0 p
    for p in $ORCA_PACKAGES; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null \
            | grep -q '^install ok installed$' || { missing=1; break; }
    done
    if [ "$missing" -eq 0 ]; then
        say "orca deps: already present"
        return 0
    fi
    say "orca deps: installing the libraries Orca links against"
    apt_update_or_die
    # shellcheck disable=SC2086
    apt-get install -y --no-install-recommends $ORCA_PACKAGES
    apt_cleanup
}

# --- the agent user -----------------------------------------------------
#
# 24.04 ships a stock `ubuntu` user at uid 1000; take that uid for
# `agent`, which the entrypoint may later re-map to the Mac's own uid
# (HOST_UID).
phase_user() {
    need_root user
    if id -u agent >/dev/null 2>&1; then
        say "agent user: uid $(id -u agent) already present"
    else
        say "agent user: creating agent at uid/gid 1000"
        if [ "$(id -un 1000 2>/dev/null || true)" = "ubuntu" ]; then
            userdel -r ubuntu 2>/dev/null || true
        fi
        getent group 1000 >/dev/null 2>&1 || groupadd -g 1000 agent
        useradd -u 1000 -g 1000 -m -d /home/agent -s /usr/bin/zsh agent
    fi
    mkdir -p /home/agent/.claude /home/agent/.config/orca /home/agent/.local/bin
    # Not `chown -R`: /home/agent is the bind-mounted folder home, and
    # chown on a unix socket over that mount returns EINVAL. Orca leaves
    # its sockets in .config/orca, so on the next boot `chown -R` died on
    # one -- `.config/orca/o-7563-9c89.sock: Invalid argument` on a real
    # Mac run -- and under `set -Eeuo pipefail` that took setup.sh, the
    # entrypoint and the container with it, every restart from then on.
    # Chown everything that is not a socket instead. The sockets stay:
    # they may belong to something running, and deleting a file in the
    # user's home to make a chown succeed is the wrong trade. A real
    # failure on a real file still fails the phase (xargs exits 123,
    # pipefail propagates it); an empty result does not (`xargs -r`).
    # ... and -h, so a DANGLING symlink is chowned rather than followed.
    # Orca leaves SingletonCookie, SingletonLock and SingletonSocket in
    # .config/orca pointing at a pid, a cookie and a /tmp path that a new
    # container does not have, and plain chown answers "cannot
    # dereference" -> xargs 123 -> pipefail -> the container dies on every
    # recreate. CI run 34154457951 caught it; the Mac hid it, because
    # .config/orca is a docker volume and `-xdev` stops find at a device
    # boundary that exists on macOS (virtiofs vs the VM's disk) and does
    # not on Linux (both on the same filesystem). -h needs neither to be
    # true: owning the link is what was meant either way.
    # Only what is not already agent:agent reaches chown: find looks at
    # every file anyway, and on a restart that is usually nothing, so the
    # boot no longer rewrites the owner of the whole home over the share.
    find /home/agent -xdev ! -type s \( ! -user agent -o ! -group agent \) -print0 \
        | xargs -0 -r chown -h agent:agent
}

# --- this template ------------------------------------------------------
#
# /opt/claude-orca-host/template -> /opt/claude-orca gives config-sync.sh
# the <host>/template/config layout it expects without a --template flag
# and without touching its contract (tests/config-sync.bats).
# Orca Web keeps its theme in the browser (localStorage), not in the
# orca-data.json seed-orca-state.sh writes, so the served web-index.html
# inside app.asar carries a one-time seed (claude-orca-qa2.18). Runs at
# image build (dark) and again at every boot, where the folder's
# claude-orca.json theme arrives as CLAUDE_ORCA_THEME; a no-op once the
# archive already seeds that theme.
web_theme_patcher() {
    local here
    here="$(cd "$(dirname "$0")" && pwd)"
    if [ -f "$here/patch-orca-web-theme.py" ]; then
        printf '%s\n' "$here/patch-orca-web-theme.py"
    elif [ -f /opt/claude-orca/scripts/container/patch-orca-web-theme.py ]; then
        printf '%s\n' /opt/claude-orca/scripts/container/patch-orca-web-theme.py
    fi
}

patch_orca_web_theme() {
    local patcher
    patcher="$(web_theme_patcher)"
    if [ -z "$patcher" ]; then
        say "orca web theme: patcher is not here yet, nothing to seed"
        return 0
    fi
    if [ ! -f /opt/Orca/resources/app.asar ]; then
        say "orca web theme: no /opt/Orca/resources/app.asar, nothing to seed"
        return 0
    fi
    # Never fatal. This is a colour preference reaching into Orca's own
    # archive: a future Orca whose web-index.html has a different shape
    # must leave the folder booting in light mode, not refuse to start.
    if ! python3 "$patcher" --asar /opt/Orca/resources/app.asar \
        --theme "${CLAUDE_ORCA_THEME:-dark}" \
        --terminal-theme "${CLAUDE_ORCA_TERMINAL_THEME:-Homebrew}"; then
        warn "orca web theme: could not seed ${CLAUDE_ORCA_THEME:-dark}/${CLAUDE_ORCA_TERMINAL_THEME:-Homebrew} (Orca starts in its own default)"
    fi
    return 0
}

phase_template() {
    need_root template
    patch_orca_web_theme
    if [ ! -d /opt/claude-orca ]; then
        say "template: /opt/claude-orca is not here yet, nothing to link"
        return 0
    fi
    if [ "$(readlink /opt/claude-orca-host/template 2>/dev/null || true)" = "/opt/claude-orca" ] \
        && [ -x /opt/claude-orca/scripts/container/entrypoint.sh ] \
        && [ -x /opt/claude-orca/scripts/container/smoke.sh ]; then
        say "template: /opt/claude-orca-host/template already present"
        return 0
    fi
    say "template: linking /opt/claude-orca-host/template -> /opt/claude-orca"
    chmod +x /opt/claude-orca/scripts/container/entrypoint.sh \
             /opt/claude-orca/scripts/container/smoke.sh
    mkdir -p /opt/claude-orca-host
    ln -sfn /opt/claude-orca /opt/claude-orca-host/template
    # Only when it is not already right. `chown -R` over a directory an
    # image layer just added rewrites every inode, and overlayfs copies
    # the lot up into a NEW layer -- 1.51 GB of second copy in the first
    # real toolchain build. The Dockerfile COPYs with --chown so this is a
    # no-op there, and it still does the work anywhere else.
    if id -u agent >/dev/null 2>&1 \
        && [ "$(stat -c '%u' /opt/claude-orca 2>/dev/null || echo x)" != "$(id -u agent)" ]; then
        chown -R agent:agent /opt/claude-orca
    fi
}

# --- --check: what every phase was supposed to leave behind -------------
#
# Reads only. No root, no network, no installing -- so it is equally
# usable inside a fresh chroot, in CI against the built image, and on a
# dev box (where it will honestly FAIL the rows that box does not have).
CHECK_STATUS=0
ck_ok()   { printf '[check] ok    %s\n' "$*"; }
ck_fail() { printf '[check] FAIL  %s\n' "$*"; CHECK_STATUS=1; }

run_checks() {
    local v

    v="$(node_major 2>/dev/null || true)"
    if [ -n "$v" ] && [ "$v" -ge "$NODE_MAJOR" ] 2>/dev/null; then
        ck_ok "node $(node --version) (>= ${NODE_MAJOR}.x)"
    else
        ck_fail "node: want v${NODE_MAJOR}.x or newer, got ${v:-none}"
    fi

    if command -v gh >/dev/null 2>&1; then
        ck_ok "gh $(gh --version 2>/dev/null | head -1)"
    else
        ck_fail "gh: not on PATH"
    fi

    v="$(installed_bats 2>/dev/null || true)"
    if [ "$v" = "$BATS_VERSION" ]; then
        ck_ok "bats ${v}"
    else
        ck_fail "bats: want ${BATS_VERSION}, got ${v:-none}"
    fi

    v="$(installed_bd 2>/dev/null || true)"
    if [ "$v" = "$BD_VERSION" ]; then
        ck_ok "bd ${v}"
    else
        ck_fail "bd: want ${BD_VERSION}, got ${v:-none}"
    fi

    v="$(installed_dolt 2>/dev/null || true)"
    if [ "$v" = "$DOLT_VERSION" ]; then
        ck_ok "dolt ${v}"
    else
        ck_fail "dolt: want ${DOLT_VERSION}, got ${v:-none}"
    fi

    v="$(installed_helix 2>/dev/null || true)"
    if [ "$v" = "$HELIX_VERSION" ] && [ -d /usr/local/lib/helix/runtime ]; then
        ck_ok "helix ${v}"
    else
        ck_fail "helix: want ${HELIX_VERSION} with /usr/local/lib/helix/runtime, got ${v:-none}"
    fi

    v="$(installed_opencode 2>/dev/null || true)"
    if [ "$v" = "$OPENCODE_VERSION" ]; then
        ck_ok "opencode ${v}"
    else
        ck_fail "opencode: want ${OPENCODE_VERSION}, got ${v:-none}"
    fi

    v="$(stamp /opt/orca/VERSION 2>/dev/null || true)"
    if [ "$v" = "$ORCA_VERSION" ] && [ -x /opt/orca/orca-ide ] \
        && [ -x /opt/orca/resources/bin/orca-ide ]; then
        ck_ok "orca ${v} (/opt/orca/orca-ide executable, not run)"
    else
        ck_fail "orca: want ${ORCA_VERSION} in /opt/orca/VERSION with an executable orca-ide, got ${v:-none}"
    fi

    v="$(web_theme_patcher)"
    if [ -n "$v" ] && [ -f /opt/Orca/resources/app.asar ] \
        && python3 "$v" --check --asar /opt/Orca/resources/app.asar \
            --theme "${CLAUDE_ORCA_THEME:-dark}" \
        --terminal-theme "${CLAUDE_ORCA_TERMINAL_THEME:-Homebrew}" \
        >/dev/null 2>&1; then
        ck_ok "orca web theme seeded ${CLAUDE_ORCA_THEME:-dark} + terminal ${CLAUDE_ORCA_TERMINAL_THEME:-Homebrew} in app.asar"
    else
        ck_fail "orca web theme: app.asar does not seed ${CLAUDE_ORCA_THEME:-dark} + terminal ${CLAUDE_ORCA_TERMINAL_THEME:-Homebrew} (patch-orca-web-theme.py)"
    fi

    # The image creates agent at 1000; on a Mac the entrypoint re-maps it to
    # HOST_UID so the bind mounts stay the owner's, and that is the uid a
    # running container has to show.
    local want_uid="${HOST_UID:-1000}"
    v="$(id -u agent 2>/dev/null || true)"
    if [ "$v" = "$want_uid" ]; then
        ck_ok "agent user at uid ${want_uid}"
    else
        ck_fail "agent user: want uid ${want_uid}, got ${v:-none}"
    fi

    if [ -x /usr/bin/tini ]; then
        ck_ok "tini at /usr/bin/tini (the image's ENTRYPOINT pid 1)"
    else
        ck_fail "tini: /usr/bin/tini is missing"
    fi

    if stty --version 2>/dev/null | grep -q 'GNU coreutils'; then
        ck_ok "stty is GNU coreutils"
    else
        ck_fail "stty: not GNU coreutils (Claude Code cannot restore terminal state)"
    fi

    if locale -a 2>/dev/null | grep -qix 'en_US\.utf-\?8'; then
        ck_ok "locale en_US.UTF-8 generated"
    else
        ck_fail "locale: en_US.UTF-8 is not in \`locale -a\`"
    fi

    return "$CHECK_STATUS"
}

run_phase() {
    case "$1" in
        base|node|gh|orcadeps|bats|bd|dolt|helix|opencode|orca|user|template)
            # A phase whose file under phases/ was not copied next to
            # this script (the Dockerfile copies each one before its RUN).
            command -v "phase_$1" >/dev/null 2>&1 \
                || die "phase $1: phases/$1.sh is not next to $0"
            "phase_$1" ;;
        *) die "unknown phase: $1 (have: ${PHASES})" ;;
    esac
}

main() {
    case "${1:-}" in
        --check)
            run_checks
            ;;
        --list)
            case "${2:-}" in
                image)     printf '%s\n' $IMAGE_PHASES ;;
                toolchain) printf '%s\n' $TOOLCHAIN_PHASES ;;
                *)         printf '%s\n' $PHASES ;;
            esac
            ;;
        --phase)
            [ -n "${2:-}" ] || die "--phase needs a name (have: ${PHASES})"
            run_phase "$2"
            ;;
        # The two halves of the line drawn at IMAGE_PHASES above: the
        # Dockerfile bakes one, the entrypoint installs the other into the
        # folder's toolchain cache on first start. Running both, in this
        # order, is the same filesystem as running --all.
        --image)
            local ip
            for ip in $IMAGE_PHASES; do run_phase "$ip"; done
            say "image phases done"
            ;;
        --toolchain)
            local tp
            for tp in $TOOLCHAIN_PHASES; do run_phase "$tp"; done
            say "toolchain phases done"
            ;;
        ""|--all)
            local p
            for p in $PHASES; do run_phase "$p"; done
            say "all phases done"
            ;;
        -h|--help)
            sed -n '3,22p' "$0"
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
}

# The toolchain phases (bats bd dolt helix opencode orca) live one per file:
# phases/ next to this script in a checkout, /opt/claude-orca-phases/ next
# to the copy the Dockerfile runs. A phase whose file is not here yet (an
# earlier image layer) simply is not defined.
_setup_here="$(cd "$(dirname "$0")" && pwd)"
for _setup_phase in "$_setup_here"/phases/*.sh "$_setup_here"/claude-orca-phases/*.sh; do
    [ -f "$_setup_phase" ] && . "$_setup_phase"
done
unset _setup_here _setup_phase

main "$@"
