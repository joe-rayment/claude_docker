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
    && locale-gen en_US.UTF-8 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── Agent: user-level shell setup ─────────────────────────────────────
USER agent
WORKDIR /home/agent

# Install Oh-My-Zsh (pinned to v1.2.1 via URL)
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v1.2.1/zsh-in-docker.sh)" -- \
    -t https://github.com/sindresorhus/pure \
    -p git \
    -p https://github.com/zsh-users/zsh-syntax-highlighting \
    -a 'fpath+=("$HOME/.zsh/pure")' \
    -a 'autoload -U promptinit; promptinit' \
    -a 'prompt pure'

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

# Install Python and JS package managers (Ruby isn't in the base image, so the
# former `gem install bundler ... || true` silently failed on every build —
# dropped. Add ruby-full + a real gem install here if Bundler is ever needed.)
RUN pip3 install --no-cache-dir --break-system-packages poetry uv \
    && npm install -g pnpm@9 yarn@1.22

# Claude Code: install the native binary to a SYSTEM path (/opt/claude) and symlink
# into /usr/local/bin. This avoids the /home/agent volume mount masking the binary
# at container start. Base image ships an npm-installed Claude — remove it so there's
# only one install path. DISABLE_AUTOUPDATER + DISABLE_AUTO_MIGRATE_TO_NATIVE keep
# Claude from writing a second copy into ~/.local at runtime.
#
# CLAUDE_CACHEBUST busts the layer whenever the launcher passes a fresh value (it
# passes BUILD_SHA, which changes on every upstream commit). Run ./claude-dev --rebuild
# to force a fresh Claude download outside of a repo update.
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

# Install Beads issue tracker for project-scoped AI agent memory
RUN curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash

# Install Dolt SQL server (required by Beads v0.56+ for database operations)
RUN curl -fsSL https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash

# Copy scripts first (change less often than config — better layer caching)
COPY --chown=agent:agent scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=agent:agent scripts/container-welcome.sh /usr/local/bin/container-welcome
COPY --chown=agent:agent scripts/view-logs.sh /usr/local/bin/view-logs
COPY --chown=agent:agent scripts/detect-dependencies.sh /usr/local/bin/detect-dependencies.sh
COPY --chown=agent:agent scripts/guided-setup.sh /usr/local/bin/guided-setup.sh
COPY --chown=agent:agent scripts/dev-log.sh /usr/local/bin/dev-log
COPY --chown=agent:agent scripts/start-professor.sh /usr/local/bin/start-professor.sh
COPY --chown=agent:agent scripts/start-dolt.sh /usr/local/bin/start-dolt
COPY --chown=agent:agent scripts/take-screenshot.sh /usr/local/bin/take-screenshot
COPY --chown=agent:agent run-tests.sh /usr/local/bin/run-tests.sh
COPY --chown=agent:agent tests/ /opt/claude-dev/tests/
COPY --chown=agent:agent knowledge-base/ /opt/claude-dev/knowledge-base/

# Stage configs for checksum-based sync (outside volume mount path)
RUN mkdir -p /etc/claude-dev/configs/agents
COPY config/.zshrc config/helix-config.toml config/intellishell-config.toml \
     config/intellishell-defaults.txt config/claude-settings.json \
     config/statusline.sh \
     /etc/claude-dev/configs/
COPY config/agents/professor.md /etc/claude-dev/configs/agents/professor.md

# Copy configuration files to agent home
COPY --chown=agent:agent config/.zshrc /home/agent/.zshrc
COPY --chown=agent:agent config/helix-config.toml /home/agent/.config/helix/config.toml
COPY --chown=agent:agent config/intellishell-config.toml /home/agent/.config/intelli-shell/config.toml
COPY --chown=agent:agent config/intellishell-defaults.txt /home/agent/.config/intelli-shell/defaults.txt
COPY --chown=agent:agent config/claude-settings.json /home/agent/.config/claude-settings-template.json
# Make scripts executable
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/container-welcome \
             /usr/local/bin/view-logs \
             /usr/local/bin/detect-dependencies.sh \
             /usr/local/bin/guided-setup.sh \
             /usr/local/bin/dev-log \
             /usr/local/bin/start-professor.sh \
             /usr/local/bin/start-dolt \
             /usr/local/bin/take-screenshot \
             /usr/local/bin/run-tests.sh

# ── Agent: user-level tool install and final state ────────────────────
USER agent

# Install IntelliShell for the agent user (pinned to v3.4.0 via URL)
RUN curl -sSf https://raw.githubusercontent.com/lasantosr/intelli-shell/v3.4.0/install.sh | sh

# Install Playwright with Chromium (as agent user so browsers cache to ~/.cache/ms-playwright/)
RUN npx playwright install --with-deps chromium

# Install termshot for terminal screenshots
RUN go install github.com/homeport/termshot/cmd/termshot@latest

# Create config directories (safety net if COPY didn't create them)
RUN mkdir -p /home/agent/.config/helix /home/agent/.config/intelli-shell

# Set working directory
WORKDIR /workspace

# Use custom entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/zsh"]
