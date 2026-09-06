# claude_orca v3 -- the Linux side of "Orca in a VM the project folder owns".
#
# One image per project runs one Orca in serve mode, headless, with the
# project bind-mounted at the same absolute path it has on the Mac and
# /home/agent bind-mounted from <project>/.claude-dev/home. The VM
# boundary IS the sandbox: there is no Seatbelt profile and no srt here.
# See .claude/plans/container-v3.md S3-S4.
#
# Every version is pinned. The Claude Code pin is the SAME string as
# scripts/install-claude.sh's CLAUDE_CODE_VERSION -- tests/container-
# entrypoint.bats greps this file for it, so the two can never drift.
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    SHELL=/usr/bin/zsh \
    COLORTERM=truecolor \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_AUTO_MIGRATE_TO_NATIVE=1

# --- base tooling + the Electron runtime libraries Orca needs -----------
#
# Only what Orca's own package does NOT already depend on. The .deb below
# pulls libgtk-3-0, libnss3, libnotify4, libxss1, libxtst6, libsecret-1-0,
# libatspi2.0-0, libuuid1, xdg-utils, python3-gi, at-spi2-core, xdotool,
# xclip and xvfb, so hand-listing them here only invites drift.
#
# xvfb matters and arrives that way: `orca-ide --serve` refuses to start
# with no usable display server, and spawns its OWN virtual one (Xvfb :99
# -screen 0 1280x1024x24 -nolisten tcp -terminate) when the binary is
# present -- the image supplies it, never runs it. An image without it is
# what failed CI's first smoke stage ("On a bare server, install xvfb").
#
# util-linux carries setpriv, which the entrypoint uses to drop root;
# libasound2t64 is 24.04's spelling of libasound2.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg git jq ripgrep zsh less \
        python3 python3-pip locales tini util-linux procps psmisc \
        build-essential unzip xz-utils sudo \
        libasound2t64 libgbm1 xauth fonts-liberation \
    && locale-gen en_US.UTF-8 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# GNU coreutils' stty must be the one on PATH: Claude Code saves and
# restores terminal state with `stty -g`, and uutils' stty can save but not
# restore. 24.04 ships GNU already -- this only repairs a base that does
# not (cf. attachments/claude_docker/Dockerfile).
RUN if ! stty --version 2>/dev/null | grep -q 'GNU coreutils'; then \
        test -x /usr/bin/gnustty && ln -sf /usr/bin/gnustty /usr/bin/stty; \
    fi; \
    stty --version | grep -q 'GNU coreutils'

# --- Node 22 (nodesource) ----------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && node --version

# --- GitHub CLI --------------------------------------------------------
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && gh --version

# --- bats-core (pinned) ------------------------------------------------
RUN git clone --depth 1 --branch v1.14.0 \
        https://github.com/bats-core/bats-core.git /tmp/bats-core \
    && /tmp/bats-core/install.sh /usr/local \
    && rm -rf /tmp/bats-core \
    && bats --version

# --- beads (bd) + dolt, the agent task tracker (pinned) ----------------
RUN set -eu; \
    BD_VERSION=1.2.2; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64|amd64) bdarch=amd64 ;; \
        arm64|aarch64) bdarch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/gastownhall/beads/releases/download/v${BD_VERSION}"; \
    archive="beads_${BD_VERSION}_linux_${bdarch}.tar.gz"; \
    tmp="$(mktemp -d)"; \
    curl -fsSL -o "${tmp}/${archive}" "${base}/${archive}"; \
    curl -fsSL -o "${tmp}/checksums.txt" "${base}/checksums.txt"; \
    (cd "$tmp" && grep " ${archive}\$" checksums.txt | sha256sum -c -); \
    tar -xzf "${tmp}/${archive}" -C "$tmp"; \
    install -m 0755 "${tmp}/bd" /usr/local/bin/bd; \
    rm -rf "$tmp"; \
    bd version
RUN curl -fsSL https://github.com/dolthub/dolt/releases/download/v2.3.1/install.sh | bash

# --- Claude Code, pinned native install --------------------------------
#
# Keep in lockstep with scripts/install-claude.sh's CLAUDE_CODE_VERSION.
ARG CLAUDE_CODE_VERSION=2.1.261
RUN set -eu; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64|amd64) arch=x64 ;; \
        arm64|aarch64) arch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    platform="linux-${arch}"; \
    base="https://downloads.claude.ai/claude-code-releases"; \
    manifest="$(curl -fsSL "${base}/${CLAUDE_CODE_VERSION}/manifest.json")"; \
    checksum="$(echo "$manifest" | jq -r ".platforms[\"${platform}\"].checksum // empty")"; \
    echo "$checksum" | grep -Eq '^[a-f0-9]{64}$' || \
        { echo "no ${platform} in manifest for ${CLAUDE_CODE_VERSION}" >&2; exit 1; }; \
    mkdir -p /opt/claude; \
    curl -fsSL -o /opt/claude/claude "${base}/${CLAUDE_CODE_VERSION}/${platform}/claude"; \
    echo "${checksum}  /opt/claude/claude" | sha256sum -c -; \
    chmod +x /opt/claude/claude; \
    ln -sf /opt/claude/claude /usr/local/bin/claude; \
    echo "${CLAUDE_CODE_VERSION}" > /opt/claude/VERSION; \
    claude --version

# --- Orca Linux, pinned, from the release .deb -------------------------
#
# NOT the AppImage (claude-orca-qa2.6). An AppImage's runtime carries the
# "AI\x02" magic in its ELF e_ident padding, which QEMU's binfmt pattern
# does not match, so the self-extractor cannot run under emulation: the
# linux/arm64 leg of the multi-arch build died on `./orca.AppImage: Exec
# format error`. Installing the .deb goes through apt, the same path every
# other layer here already takes under QEMU, and its Depends supply the
# GTK/NSS/at-spi/xdotool/xclip/xvfb set so this file need not list them.
#
# Nothing below EXECUTES the Orca binary. Under emulation a 200 MB
# Electron binary is slow to start and proves nothing about the target
# machine; `test -x` is the only claim a build can honestly make. The
# runtime check that Orca actually serves belongs to
# scripts/container/smoke.sh, which CI runs on the native amd64 image.
ARG ORCA_VERSION=1.4.197
RUN set -eu; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64|amd64) debarch=amd64 ;; \
        arm64|aarch64) debarch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    asset="orca-ide_${ORCA_VERSION}_${debarch}.deb"; \
    url="https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/${asset}"; \
    tmp="$(mktemp -d)"; \
    curl -fsSL -o "${tmp}/orca.deb" "$url"; \
    apt-get update; \
    apt-get install -y --no-install-recommends "${tmp}/orca.deb"; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* "$tmp"; \
    test -x /opt/Orca/orca-ide; \
    test -x /opt/Orca/resources/bin/orca-ide; \
    ln -s /opt/Orca /opt/orca; \
    ln -sf /opt/Orca/resources/bin/orca-ide /usr/local/bin/orca; \
    echo "${ORCA_VERSION}" > /opt/orca/VERSION

# --- the agent user ----------------------------------------------------
#
# 24.04 ships a stock `ubuntu` user at uid 1000; take that uid for `agent`,
# which the entrypoint may later re-map to the Mac's own uid (HOST_UID).
RUN set -eu; \
    userdel -r ubuntu 2>/dev/null || true; \
    groupadd -g 1000 agent; \
    useradd -u 1000 -g 1000 -m -d /home/agent -s /usr/bin/zsh agent; \
    mkdir -p /home/agent/.claude /home/agent/.config/orca /home/agent/.local/bin; \
    chown -R agent:agent /home/agent

# --- this template ------------------------------------------------------
#
# /opt/claude-orca-host/template -> /opt/claude-orca gives config-sync.sh
# the <host>/template/config layout it expects without a --template flag
# and without touching its contract (tests/config-sync.bats).
COPY . /opt/claude-orca
RUN set -eu; \
    chmod +x /opt/claude-orca/scripts/container/entrypoint.sh \
             /opt/claude-orca/scripts/container/smoke.sh; \
    mkdir -p /opt/claude-orca-host; \
    ln -sfn /opt/claude-orca /opt/claude-orca-host/template; \
    chown -R agent:agent /opt/claude-orca

ENV HOME=/home/agent \
    ORCA_BIN=/opt/orca/orca-ide \
    ORCA_CLI=/opt/orca/resources/bin/orca-ide \
    ORCA_PORT=6768 \
    PATH=/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

EXPOSE 6768
WORKDIR /home/agent
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/claude-orca/scripts/container/entrypoint.sh"]
