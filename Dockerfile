# Claude Code Development Environment
# Based on official Docker Claude Code sandbox
# Pin base image digest for reproducible builds (update periodically)
FROM docker/sandbox-templates:claude-code@sha256:e7ab93ba4a4a10d3cb20d8d1e777ac57604f2f523c3bc2a78fcbcabac0317c81

# Build traceability
ARG BUILD_SHA=unknown
LABEL build.sha=${BUILD_SHA}

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV SHELL=/bin/zsh
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV COLORTERM=truecolor

# ── Root: system packages ─────────────────────────────────────────────
USER root

# Install additional dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    zsh \
    curl \
    wget \
    locales \
    build-essential \
    python3-pip \
    python3-dev \
    jq \
    xvfb \
    imagemagick \
    tmux \
    && locale-gen en_US.UTF-8 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# The base image (Ubuntu "questing") replaces GNU coreutils' /usr/bin/stty with
# uutils coreutils 0.2.2, whose `stty` can SAVE terminal state (stty -g) but not
# RESTORE it — feeding its own saved string back errors "stty: invalid argument".
# The claude binary save/restores the tty via stty at startup, so that error would
# print on every launch. GNU stty survives as /usr/bin/gnustty; point the standard
# names back at it. (Purging the uutils packages isn't possible — apt marks them
# essential in this base.) test -x fails the build loudly if a future base digest
# moves gnustty, rather than silently leaving a dangling stty symlink.
RUN test -x /usr/bin/gnustty \
    && ln -sf /usr/bin/gnustty /usr/bin/stty \
    && ln -sf /usr/bin/gnustty /bin/stty \
    && stty --version | grep -q 'GNU coreutils'

# ── Agent: user-level shell setup ─────────────────────────────────────
USER agent
WORKDIR /home/agent

# Install Oh-My-Zsh (pinned to v1.2.1 via URL). This clones pure into
# ~/.oh-my-zsh/custom/themes/ and the plugins into ~/.oh-my-zsh/custom/plugins/.
# The .zshrc zsh-in-docker generates is replaced by config/.zshrc, which
# sources oh-my-zsh and initializes the pure prompt itself — so no -a args.
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v1.2.1/zsh-in-docker.sh)" -- \
    -t https://github.com/sindresorhus/pure \
    -p git \
    -p https://github.com/zsh-users/zsh-syntax-highlighting \
    -p https://github.com/zsh-users/zsh-history-substring-search

# ── Root: tools, languages, and file staging ──────────────────────────
USER root

# Install Helix editor from specific release with SHA256 verification
RUN HELIX_VERSION=25.07.1 && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then HELIX_ARCH="aarch64"; else HELIX_ARCH="x86_64"; fi && \
    wget -qO helix.tar.xz https://github.com/helix-editor/helix/releases/download/${HELIX_VERSION}/helix-${HELIX_VERSION}-${HELIX_ARCH}-linux.tar.xz && \
    if [ "$HELIX_ARCH" = "aarch64" ]; then \
        EXPECTED_SHA="ce23fa8d395e633e3e54c052012f11965d91d8d5c2bfa659685f50430b4f8175"; \
    else \
        EXPECTED_SHA="3f08e63ecd388fff657ad39722f88bb03dcf326f1f2da2700d99e1dc40ab2e8b"; \
    fi && \
    echo "$EXPECTED_SHA  helix.tar.xz" | sha256sum -c - && \
    tar -xf helix.tar.xz && \
    mv helix-*/hx /usr/local/bin/ && \
    mkdir -p /usr/local/lib/helix && \
    mv helix-*/runtime /usr/local/lib/helix/runtime && \
    rm -rf helix-* helix.tar.xz

# Tell Helix where to find its runtime files
ENV HELIX_RUNTIME=/usr/local/lib/helix/runtime

# Install Node.js 22 LTS — base image ships Node 20.19; some tools require
# node:sqlite, a built-in added in 22.5+. NodeSource replaces the apt nodejs
# package with their build, so this also unblocks anything else needing >=22.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && node --version

# Install Python and JS package managers (Ruby isn't in the base image, so the
# former `gem install bundler ... || true` silently failed on every build —
# dropped. Add ruby-full + a real gem install here if Bundler is ever needed.)
RUN pip3 install --no-cache-dir --break-system-packages poetry uv \
    && npm install -g pnpm@9 yarn@1.22

# Install the code-map graph engine (graphifyy, pinned like every other tool
# here) into a SYSTEM prefix that is deliberately OFF PATH: the only graphify
# on PATH is scripts/code-map-guard.sh, staged as /usr/local/bin/graphify
# below, and it execs this binary. `code-map upgrade` installs a newer engine
# under ~/.local/lib/code-map, which the guard prefers when it exists — so
# this is the floor, not the ceiling. a+rX because uv installs as root here
# and the container runs as agent.
RUN UV_NO_CACHE=1 UV_TOOL_DIR=/opt/code-map/tools UV_TOOL_BIN_DIR=/opt/code-map/bin \
        uv tool install graphifyy==0.9.48 \
    && chmod -R a+rX /opt/code-map \
    && /opt/code-map/bin/graphify version

# Claude Code: install the native binary to a SYSTEM path (/opt/claude) and symlink
# into /usr/local/bin. This avoids the /home/agent volume mount masking the binary
# at container start. Base image ships an npm-installed Claude — remove it so there's
# only one install path. DISABLE_AUTOUPDATER + DISABLE_AUTO_MIGRATE_TO_NATIVE keep
# Claude from writing a second copy into ~/.local at runtime.
#
# CLAUDE_CACHEBUST busts this layer whenever the launcher passes a fresh value.
# The launcher sets it to "<repo-sha>-<latest-claude-version>", so the layer
# re-runs (and re-downloads Claude) on either a template change OR a new upstream
# Claude release — even when the repo SHA is unchanged. Run ./claude-dev --rebuild
# to force a fresh Claude download outside of those.
ARG CLAUDE_VERSION=latest
ARG CLAUDE_CACHEBUST=unknown
RUN set -eu; \
    npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true; \
    arch=$(uname -m); \
    case "$arch" in \
        x86_64|amd64) arch=x64 ;; \
        arm64|aarch64) arch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    if ldd /bin/ls 2>&1 | grep -q musl; then platform="linux-${arch}-musl"; else platform="linux-${arch}"; fi; \
    base="https://downloads.claude.ai/claude-code-releases"; \
    if [ "$CLAUDE_VERSION" = "latest" ] || [ "$CLAUDE_VERSION" = "stable" ]; then \
        resolved=$(curl -fsSL "${base}/${CLAUDE_VERSION}"); \
    else \
        resolved="$CLAUDE_VERSION"; \
    fi; \
    manifest=$(curl -fsSL "${base}/${resolved}/manifest.json"); \
    checksum=$(echo "$manifest" | jq -r ".platforms[\"${platform}\"].checksum // empty"); \
    if ! echo "$checksum" | grep -Eq '^[a-f0-9]{64}$'; then \
        echo "platform ${platform} not found in manifest for ${resolved}" >&2; exit 1; \
    fi; \
    mkdir -p /opt/claude; \
    curl -fsSL -o /opt/claude/claude "${base}/${resolved}/${platform}/claude"; \
    echo "${checksum}  /opt/claude/claude" | sha256sum -c -; \
    chmod +x /opt/claude/claude; \
    ln -sf /opt/claude/claude /usr/local/bin/claude; \
    echo "${resolved}" > /opt/claude/VERSION
ENV DISABLE_AUTOUPDATER=1
ENV DISABLE_AUTO_MIGRATE_TO_NATIVE=1

# Install bats-core for experience testing
RUN git clone --depth 1 --branch v1.11.1 https://github.com/bats-core/bats-core.git /tmp/bats-core \
    && /tmp/bats-core/install.sh /usr/local \
    && rm -rf /tmp/bats-core

# Install Beads issue tracker (pinned) for project-scoped AI agent memory.
# The upstream install.sh resolves 'latest' via the GitHub API, so we bypass it
# and fetch a tagged release asset directly (matching the pin-everything build
# intent — cf. Helix/bats/IntelliShell pins). bd runs in embedded Dolt mode, so
# no SQL server is required. (The upstream repo moved to gastownhall/beads.)
RUN set -eu; \
    BD_VERSION=1.0.4; \
    arch=$(uname -m); \
    case "$arch" in \
        x86_64|amd64) bdarch=amd64 ;; \
        arm64|aarch64) bdarch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/gastownhall/beads/releases/download/v${BD_VERSION}"; \
    archive="beads_${BD_VERSION}_linux_${bdarch}.tar.gz"; \
    tmp=$(mktemp -d); \
    curl -fsSL -o "${tmp}/${archive}" "${base}/${archive}"; \
    curl -fsSL -o "${tmp}/checksums.txt" "${base}/checksums.txt"; \
    (cd "$tmp" && grep " ${archive}\$" checksums.txt | sha256sum -c -); \
    tar -xzf "${tmp}/${archive}" -C "$tmp"; \
    install -m 0755 "${tmp}/bd" /usr/local/bin/bd; \
    rm -rf "$tmp"; \
    bd version

# Install Dolt (pinned). Beads' embedded mode uses Dolt for on-disk storage;
# the tagged install.sh installs that exact version (no moving 'latest').
RUN curl -fsSL https://github.com/dolthub/dolt/releases/download/v2.0.5/install.sh | bash

# Copy scripts first (change less often than config — better layer caching)
COPY --chown=agent:agent scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=agent:agent scripts/container-welcome.sh /usr/local/bin/container-welcome
COPY --chown=agent:agent scripts/view-logs.sh /usr/local/bin/view-logs
COPY --chown=agent:agent scripts/detect-dependencies.sh /usr/local/bin/detect-dependencies.sh
COPY --chown=agent:agent scripts/guided-setup.sh /usr/local/bin/guided-setup.sh
COPY --chown=agent:agent scripts/dev-log.sh /usr/local/bin/dev-log
COPY --chown=agent:agent scripts/start-professor.sh /usr/local/bin/start-professor.sh
COPY --chown=agent:agent scripts/take-screenshot.sh /usr/local/bin/take-screenshot
COPY --chown=agent:agent scripts/csearch.sh /usr/local/bin/csearch
COPY --chown=agent:agent scripts/tier-set.sh /usr/local/bin/tier-set
COPY --chown=agent:agent scripts/tier-derive.sh /usr/local/bin/tier-derive
COPY --chown=agent:agent scripts/tier-reconcile.sh /usr/local/bin/tier-reconcile
COPY --chown=agent:agent scripts/tier-gate.sh /usr/local/bin/tier-gate
COPY --chown=agent:agent scripts/tier-prime.sh /usr/local/bin/tier-prime
COPY --chown=agent:agent scripts/lane.sh /usr/local/bin/lane
COPY --chown=agent:agent scripts/workflow-lint.sh /usr/local/bin/workflow-lint
COPY --chown=agent:agent scripts/cost-mirror.py /usr/local/bin/cost-mirror
COPY --chown=agent:agent scripts/disk-cleanup.sh /usr/local/bin/disk-cleanup
COPY --chown=agent:agent scripts/bd-guard.sh /usr/local/bin/bd-guard
COPY --chown=agent:agent scripts/context-detect.sh /usr/local/bin/context-detect
COPY --chown=agent:agent scripts/delegation-gate.py /usr/local/bin/delegation-gate
COPY --chown=agent:agent scripts/contract-gate.py /usr/local/bin/contract-gate
COPY --chown=agent:agent scripts/image-drift.py /usr/local/bin/image-drift
# the guard IS `graphify` here: the pinned engine at /opt/code-map/bin stays
# off PATH so every invocation goes through the allowlist
COPY --chown=agent:agent scripts/code-map-guard.sh /usr/local/bin/graphify
COPY --chown=agent:agent run-tests.sh /usr/local/bin/run-tests.sh
COPY --chown=agent:agent tests/ /opt/claude-dev/tests/
COPY --chown=agent:agent knowledge-base/ /opt/claude-dev/knowledge-base/

# Stage configs for checksum-based sync (outside volume mount path)
RUN mkdir -p /etc/claude-dev/configs/agents
COPY config/.zshrc config/helix-config.toml config/intellishell-config.toml \
     config/intellishell-defaults.txt config/claude-settings.json \
     config/statusline.sh config/tmux.conf config/claude-user-memory.md \
     /etc/claude-dev/configs/
COPY config/agents/ /etc/claude-dev/configs/agents/
COPY config/skills/ /etc/claude-dev/configs/skills/
COPY config/claude-commands/ /etc/claude-dev/configs/commands/
# Context rule files read by context-detect (SessionStart hook). Staged
# outside configs/ on purpose: they are inputs to a script, not synced into
# the home volume, and shouldn't churn the config checksum semantics.
COPY config/contexts/ /etc/claude-dev/contexts/

# Copy configuration files to agent home
COPY --chown=agent:agent config/.zshrc /home/agent/.zshrc
COPY --chown=agent:agent config/helix-config.toml /home/agent/.config/helix/config.toml
COPY --chown=agent:agent config/intellishell-config.toml /home/agent/.config/intelli-shell/config.toml
COPY --chown=agent:agent config/intellishell-defaults.txt /home/agent/.config/intelli-shell/defaults.txt
COPY --chown=agent:agent config/tmux.conf /home/agent/.tmux.conf
# Make scripts executable
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/container-welcome \
             /usr/local/bin/view-logs \
             /usr/local/bin/detect-dependencies.sh \
             /usr/local/bin/guided-setup.sh \
             /usr/local/bin/dev-log \
             /usr/local/bin/start-professor.sh \
             /usr/local/bin/take-screenshot \
             /usr/local/bin/csearch \
             /usr/local/bin/tier-set \
             /usr/local/bin/tier-derive \
             /usr/local/bin/tier-reconcile \
             /usr/local/bin/disk-cleanup \
             /usr/local/bin/bd-guard \
             /usr/local/bin/delegation-gate \
             /usr/local/bin/contract-gate \
             /usr/local/bin/image-drift \
             /usr/local/bin/run-tests.sh

# Pin the Playwright CLI globally. take-screenshot calls this binary instead
# of `npx --yes playwright`, which re-resolves 'latest' at runtime and can
# drift ahead of the browsers baked below ("Executable doesn't exist").
# Keep this version and the browser install below in lockstep when bumping.
RUN npm install -g playwright@1.61.1

# Playwright MCP server — interactive browser automation (click/fill/multi-step)
# beyond the static take-screenshot CLI. Pinned in lockstep with the browser it
# drives: @playwright/mcp@0.0.76 bundles playwright-core 1.61 (chromium rev 1226).
# The entrypoint generates /workspace/.mcp.json defining a 'playwright' server
# that runs the installed `playwright-mcp` binary against the baked browser.
# Verified in-container: the server launches the baked chromium and answers an
# MCP initialize handshake. Keep this version and its browser install (below) in
# lockstep when bumping.
RUN npm install -g @playwright/mcp@0.0.76

# ── Agent: user-level tool install and final state ────────────────────
USER agent

# Install IntelliShell for the agent user (pinned to v3.4.0 via URL)
RUN curl -sSf https://raw.githubusercontent.com/lasantosr/intelli-shell/v3.4.0/install.sh | sh

# Install Chromium for the pinned Playwright (as agent user so browsers cache
# to ~/.cache/ms-playwright/, preserved by the home volume)
RUN playwright install --with-deps chromium

# Bake the Playwright MCP's matching browser too. @playwright/mcp@0.0.76 needs
# chromium rev 1226, distinct from the 1.61.1 CLI's 1228 above — bake both so
# neither hits "Executable doesn't exist". System deps already came from the
# --with-deps install above, so this only fetches the browser binaries (as the
# agent user, into the same home-volume cache).
RUN node "$(npm root -g)/@playwright/mcp/node_modules/playwright-core/cli.js" install chromium chromium-headless-shell

# Install termshot for terminal screenshots (pinned)
RUN go install github.com/homeport/termshot/cmd/termshot@v0.6.1
# go install drops binaries in ~/go/bin — must be on PATH for take-screenshot term
ENV PATH="/home/agent/go/bin:${PATH}"

# Create config directories (safety net if COPY didn't create them)
RUN mkdir -p /home/agent/.config/helix /home/agent/.config/intelli-shell

# Set working directory
WORKDIR /workspace

# Use custom entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/zsh"]
