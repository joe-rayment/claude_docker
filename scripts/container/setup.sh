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
# Every version is pinned below and overridable by env, which is how the
# Dockerfile passes its ARGs through. CLAUDE_CODE_VERSION is the SAME
# string as scripts/install-claude.sh's -- tests/container-entrypoint.bats
# greps both, so the two can never drift.

set -Eeuo pipefail

ORCA_VERSION="${ORCA_VERSION:-1.4.197}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.261}"
OPENCODE_VERSION="${OPENCODE_VERSION:-1.18.25}"
BD_VERSION="${BD_VERSION:-1.2.2}"
DOLT_VERSION="${DOLT_VERSION:-2.3.1}"
BATS_VERSION="${BATS_VERSION:-1.14.0}"
NODE_MAJOR="${NODE_MAJOR:-22}"

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

PHASES="base node gh bats bd dolt claude opencode orca user template"

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

say()  { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup] %s\n' "$*" >&2; }
die()  { printf '[setup] error: %s\n' "$*" >&2; exit 1; }

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

installed_bats() {
    command -v bats >/dev/null 2>&1 || return 1
    bats --version 2>/dev/null | sed -n 's/^Bats \([0-9][^ ]*\).*/\1/p'
}

installed_bd() {
    command -v bd >/dev/null 2>&1 || return 1
    bd version 2>/dev/null | sed -n 's/^bd version \([0-9][^ ]*\).*/\1/p' | head -1
}

# What npm has on disk, read from the package rather than by running the
# binary: opencode is a Bun executable and Bun reads /proc at startup,
# which the chroot verify-rootfs.sh uses does not have (the same
# constraint phase_claude documents). Reading package.json is also what
# keeps the phase idempotent in there -- a check that had to RUN opencode
# would re-install on every pass.
installed_opencode() {
    local root pkg
    command -v npm >/dev/null 2>&1 || return 1
    command -v opencode >/dev/null 2>&1 || return 1
    root="$(npm root -g 2>/dev/null)" || return 1
    pkg="$root/opencode-ai"
    [ -f "$pkg/package.json" ] || return 1
    [ -x "$pkg/bin/opencode.exe" ] || return 1
    jq -r '.version // empty' "$pkg/package.json" 2>/dev/null
}

installed_dolt() {
    command -v dolt >/dev/null 2>&1 || return 1
    dolt version 2>/dev/null | sed -n 's/^dolt version \([0-9][^ ]*\).*/\1/p' | head -1
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

# --- bats-core (pinned) -------------------------------------------------
phase_bats() {
    need_root bats
    if [ "$(installed_bats || true)" = "$BATS_VERSION" ]; then
        say "bats: ${BATS_VERSION} already present"
        return 0
    fi
    say "bats: installing ${BATS_VERSION}"
    rm -rf /tmp/bats-core
    git clone --depth 1 --branch "v${BATS_VERSION}" \
        https://github.com/bats-core/bats-core.git /tmp/bats-core
    /tmp/bats-core/install.sh /usr/local
    rm -rf /tmp/bats-core
    bats --version
}

# --- beads (bd), the agent task tracker (pinned) ------------------------
phase_bd() {
    need_root bd
    if [ "$(installed_bd || true)" = "$BD_VERSION" ]; then
        say "bd: ${BD_VERSION} already present"
        return 0
    fi
    say "bd: installing ${BD_VERSION}"
    local bdarch base archive tmp
    bdarch="$(deb_arch)"
    base="https://github.com/gastownhall/beads/releases/download/v${BD_VERSION}"
    archive="beads_${BD_VERSION}_linux_${bdarch}.tar.gz"
    tmp="$(mktemp -d)"
    curl -fsSL -o "${tmp}/${archive}" "${base}/${archive}"
    curl -fsSL -o "${tmp}/checksums.txt" "${base}/checksums.txt"
    (cd "$tmp" && grep " ${archive}\$" checksums.txt | sha256sum -c -)
    tar -xzf "${tmp}/${archive}" -C "$tmp"
    install -m 0755 "${tmp}/bd" /usr/local/bin/bd
    rm -rf "$tmp"
    bd version
}

# --- dolt, bd's storage engine (pinned) ---------------------------------
phase_dolt() {
    need_root dolt
    if [ "$(installed_dolt || true)" = "$DOLT_VERSION" ]; then
        say "dolt: ${DOLT_VERSION} already present"
        return 0
    fi
    say "dolt: installing ${DOLT_VERSION}"
    curl -fsSL "https://github.com/dolthub/dolt/releases/download/v${DOLT_VERSION}/install.sh" | bash
    dolt version
}

# --- Claude Code, pinned native install ---------------------------------
#
# Keep in lockstep with scripts/install-claude.sh's CLAUDE_CODE_VERSION.
phase_claude() {
    need_root claude
    if [ "$(stamp /opt/claude/VERSION || true)" = "$CLAUDE_CODE_VERSION" ] \
        && [ -x /opt/claude/claude ]; then
        say "claude: ${CLAUDE_CODE_VERSION} already present"
        return 0
    fi
    say "claude: installing ${CLAUDE_CODE_VERSION}"
    local platform base manifest checksum
    platform="linux-$(claude_arch)"
    base="https://downloads.claude.ai/claude-code-releases"
    manifest="$(curl -fsSL "${base}/${CLAUDE_CODE_VERSION}/manifest.json")"
    checksum="$(echo "$manifest" | jq -r ".platforms[\"${platform}\"].checksum // empty")"
    echo "$checksum" | grep -Eq '^[a-f0-9]{64}$' \
        || die "no ${platform} in manifest for ${CLAUDE_CODE_VERSION}"
    mkdir -p /opt/claude
    curl -fsSL -o /opt/claude/claude "${base}/${CLAUDE_CODE_VERSION}/${platform}/claude"
    echo "${checksum}  /opt/claude/claude" | sha256sum -c -
    chmod +x /opt/claude/claude
    ln -sf /opt/claude/claude /usr/local/bin/claude
    echo "${CLAUDE_CODE_VERSION}" > /opt/claude/VERSION
    # Claude Code is a Bun binary and Bun reads /proc/self at startup, so
    # running it needs a mounted /proc -- which an image build has and the
    # chroot verify-rootfs.sh uses does not (`mount` is not permitted
    # there). The sha256 above is what actually proves the download; this
    # is a smoke puff, and it skips rather than aborting on SIGABRT.
    if [ -r /proc/self/cmdline ]; then
        claude --version
    else
        say "claude: not running \`claude --version\` (no /proc; the sha256 is the proof)"
    fi
}

# --- opencode, the OpenRouter worker's CLI (pinned) ---------------------
#
# An Orca worker terminal running a non-Anthropic model is `opencode
# --model openrouter/<vendor>/<model>` (.claude/plans/orca-orchestration.md).
# It is a plain npm global install -- the package ships the per-platform
# binary in its postinstall, so nothing here maps an arch by hand -- and
# its config comes from the file config-sync writes into the agent home,
# pointed at by OPENCODE_CONFIG in Orca's own settings
# (scripts/container/seed-orca-state.sh). No key is baked in anywhere: the
# config reads OPENROUTER_API_KEY from the environment the VM already
# carries (claude-orca-qa2.7).
phase_opencode() {
    need_root opencode
    if [ "$(installed_opencode || true)" = "$OPENCODE_VERSION" ]; then
        say "opencode: ${OPENCODE_VERSION} already present"
        return 0
    fi
    say "opencode: installing ${OPENCODE_VERSION}"
    # --ignore-scripts, then place the platform binary by hand. The
    # package's postinstall picks that binary by probing the machine and
    # then RUNS it to confirm; under a chroot with no /proc the run fails,
    # postinstall falls through to the musl build, npm rejects it
    # (EBADPLATFORM) and the whole install exits 1. The optional
    # dependency npm already resolved for this platform is the same
    # binary, so copying it is the honest, probe-free version of what the
    # postinstall would have done.
    npm install -g --ignore-scripts --no-fund --no-audit "opencode-ai@${OPENCODE_VERSION}"

    local root pkg binpkg src tmp=""
    root="$(npm root -g)"
    pkg="$root/opencode-ai"
    # opencode spells the arch the way downloads.claude.ai does: x64/arm64.
    # (x64 also has a `-baseline` build for CPUs without AVX2; the image is
    # cross-built under QEMU, whose CPU says nothing about the Mac that
    # will run it, so the normal build is the right default.)
    binpkg="opencode-linux-$(claude_arch)"
    src="$pkg/node_modules/$binpkg/bin/opencode"
    [ -f "$src" ] || src="$root/$binpkg/bin/opencode"
    if [ ! -f "$src" ]; then
        tmp="$(mktemp -d)"
        npm install --prefix "$tmp" --no-save --ignore-scripts --loglevel=error \
            "${binpkg}@${OPENCODE_VERSION}"
        src="$tmp/node_modules/$binpkg/bin/opencode"
    fi
    install -m 0755 "$src" "$pkg/bin/opencode.exe"
    if [ -n "$tmp" ]; then rm -rf "$tmp"; fi

    if [ -r /proc/self/cmdline ]; then
        opencode --version
    else
        say "opencode: not running \`opencode --version\` (no /proc; npm's own integrity check is the proof)"
    fi
}

# --- Orca Linux, pinned, from the release .deb --------------------------
#
# NOT the AppImage (claude-orca-qa2.6). An AppImage's runtime carries the
# "AI\x02" magic in its ELF e_ident padding, which QEMU's binfmt pattern
# does not match, so the self-extractor cannot run under emulation: the
# linux/arm64 leg of the multi-arch build died on `./orca.AppImage: Exec
# format error`. Installing the .deb goes through apt, the same path every
# other phase already takes under QEMU, and its Depends supply the
# GTK/NSS/at-spi/xdotool/xclip/xvfb set so this script need not list them.
#
# Nothing here EXECUTES the Orca binary. Under emulation a 200 MB Electron
# binary is slow to start and proves nothing about the target machine;
# `test -x` is the only claim a build can honestly make. The runtime check
# that Orca actually serves belongs to scripts/container/smoke.sh.
phase_orca() {
    need_root orca
    if [ "$(stamp /opt/orca/VERSION || true)" = "$ORCA_VERSION" ] \
        && [ -x /opt/orca/orca-ide ]; then
        say "orca: ${ORCA_VERSION} already present"
        return 0
    fi
    say "orca: installing ${ORCA_VERSION}"
    local debarch asset url tmp
    debarch="$(deb_arch)"
    asset="orca-ide_${ORCA_VERSION}_${debarch}.deb"
    url="https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/${asset}"
    tmp="$(mktemp -d)"
    curl -fsSL -o "${tmp}/orca.deb" "$url"
    apt_update_or_die
    apt-get install -y --no-install-recommends "${tmp}/orca.deb"
    apt_cleanup
    rm -rf "$tmp"
    test -x /opt/Orca/orca-ide
    test -x /opt/Orca/resources/bin/orca-ide
    ln -sfn /opt/Orca /opt/orca
    ln -sf /opt/Orca/resources/bin/orca-ide /usr/local/bin/orca
    echo "${ORCA_VERSION}" > /opt/orca/VERSION
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
    chown -R agent:agent /home/agent
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
        --theme "${CLAUDE_ORCA_THEME:-dark}"; then
        warn "orca web theme: could not seed ${CLAUDE_ORCA_THEME:-dark} (Orca starts in its own default)"
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
    if id -u agent >/dev/null 2>&1; then
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

    v="$(stamp /opt/claude/VERSION 2>/dev/null || true)"
    if [ "$v" = "$CLAUDE_CODE_VERSION" ] && [ -x /opt/claude/claude ]; then
        ck_ok "claude ${v} (/opt/claude/claude)"
    else
        ck_fail "claude: want ${CLAUDE_CODE_VERSION} in /opt/claude/VERSION, got ${v:-none}"
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
            --theme "${CLAUDE_ORCA_THEME:-dark}" >/dev/null 2>&1; then
        ck_ok "orca web theme seeded ${CLAUDE_ORCA_THEME:-dark} in app.asar"
    else
        ck_fail "orca web theme: app.asar does not seed ${CLAUDE_ORCA_THEME:-dark} (patch-orca-web-theme.py)"
    fi

    v="$(id -u agent 2>/dev/null || true)"
    if [ "$v" = "1000" ]; then
        ck_ok "agent user at uid 1000"
    else
        ck_fail "agent user: want uid 1000, got ${v:-none}"
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
        base|node|gh|bats|bd|dolt|claude|opencode|orca|user|template) "phase_$1" ;;
        *) die "unknown phase: $1 (have: ${PHASES})" ;;
    esac
}

main() {
    case "${1:-}" in
        --check)
            run_checks
            ;;
        --list)
            printf '%s\n' $PHASES
            ;;
        --phase)
            [ -n "${2:-}" ] || die "--phase needs a name (have: ${PHASES})"
            run_phase "$2"
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

main "$@"
