# Claude Code Development Environment
# Based on official Docker Claude Code sandbox
# Pin base image digest for reproducible builds (update periodically)
FROM docker/sandbox-templates:claude-code@sha256:be00c5a012768c207e1b445e30c1d1a2b58d408ed65c6b39620d615c7e7e56ba

# Build traceability
ARG BUILD_SHA=unknown
LABEL build.sha=${BUILD_SHA}

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV SHELL=/bin/zsh
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# ── Root: system packages ─────────────────────────────────────────────
USER root

# Install additional dependencies
RUN apt-get update && apt-get install -y \
    zsh \
    curl \
    wget \
    locales \
    build-essential \
    python3-pip \
    python3-dev \
    jq \
    figlet \
    tmux \
    && locale-gen en_US.UTF-8 \
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

# Install Python packages (using --break-system-packages for container environment)
RUN pip3 install --no-cache-dir --break-system-packages \
    numpy \
    pandas \
    requests \
    matplotlib \
    scikit-learn \
    jupyter \
    ipython \
    scipy \
    seaborn \
    psutil \
    attrs \
    certifi \
    urllib3

# Install common package managers so dependency detection can actually install
RUN pip3 install --no-cache-dir --break-system-packages poetry uv \
    && npm install -g pnpm@9 yarn@1.22 \
    && gem install bundler -v 2.5.6 2>/dev/null || true

# Install bats-core for experience testing
RUN git clone --depth 1 --branch v1.11.1 https://github.com/bats-core/bats-core.git /tmp/bats-core \
    && /tmp/bats-core/install.sh /usr/local \
    && rm -rf /tmp/bats-core

# Copy scripts first (change less often than config — better layer caching)
COPY --chown=agent:agent scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=agent:agent scripts/container-welcome.sh /usr/local/bin/container-welcome
COPY --chown=agent:agent scripts/view-logs.sh /usr/local/bin/view-logs
COPY --chown=agent:agent scripts/detect-dependencies.sh /usr/local/bin/detect-dependencies.sh
COPY --chown=agent:agent scripts/guided-setup.sh /usr/local/bin/guided-setup.sh
COPY --chown=agent:agent scripts/dev-log.sh /usr/local/bin/dev-log
COPY --chown=agent:agent config/claude-usage.sh /usr/local/bin/claude-usage
COPY --chown=agent:agent run-tests.sh /usr/local/bin/run-tests.sh
COPY --chown=agent:agent tests/ /opt/claude-dev/tests/

# Stage configs for version-sync (outside volume mount path)
RUN mkdir -p /etc/claude-dev/configs
COPY CONFIG_VERSION /etc/claude-dev/CONFIG_VERSION
COPY config/.zshrc /etc/claude-dev/configs/.zshrc
COPY config/helix-config.toml /etc/claude-dev/configs/helix-config.toml
COPY config/intellishell-config.toml /etc/claude-dev/configs/intellishell-config.toml
COPY config/intellishell-defaults.txt /etc/claude-dev/configs/intellishell-defaults.txt
COPY config/claude-settings.json /etc/claude-dev/configs/claude-settings.json
COPY config/statusline.sh /etc/claude-dev/configs/statusline.sh
COPY config/claude-usage.sh /etc/claude-dev/configs/claude-usage.sh

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
             /usr/local/bin/claude-usage \
             /usr/local/bin/run-tests.sh

# ── Agent: user-level tool install and final state ────────────────────
USER agent

# Install IntelliShell for the agent user (pinned to v3.4.0 via URL)
RUN curl -sSf https://raw.githubusercontent.com/lasantosr/intelli-shell/v3.4.0/install.sh | sh

# Create config directories (safety net if COPY didn't create them)
RUN mkdir -p /home/agent/.config/helix /home/agent/.config/intelli-shell

# Set working directory
WORKDIR /workspace

# Use custom entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/zsh"]
