# Claude Code Development Environment
# Based on official Docker Claude Code sandbox
# Pin base image digest for reproducible builds (update periodically)
FROM docker/sandbox-templates:claude-code@sha256:be00c5a012768c207e1b445e30c1d1a2b58d408ed65c6b39620d615c7e7e56ba

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV SHELL=/bin/zsh
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Switch to root for installations
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

# Install Oh-My-Zsh for agent user (switching to agent first)
USER agent
WORKDIR /home/agent
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v1.2.1/zsh-in-docker.sh)" -- \
    -t https://github.com/sindresorhus/pure \
    -p git \
    -p https://github.com/zsh-users/zsh-syntax-highlighting \
    -a 'fpath+=("$HOME/.zsh/pure")' \
    -a 'autoload -U promptinit; promptinit' \
    -a 'prompt pure'

# Switch back to root for remaining installations
USER root

# Install Helix editor from specific release (detect architecture)
RUN HELIX_VERSION=25.07.1 && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then HELIX_ARCH="aarch64"; else HELIX_ARCH="x86_64"; fi && \
    wget -qO helix.tar.xz https://github.com/helix-editor/helix/releases/download/${HELIX_VERSION}/helix-${HELIX_VERSION}-${HELIX_ARCH}-linux.tar.xz && \
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
    selenium \
    urllib3

# Install common package managers so dependency detection can actually install
RUN pip3 install --no-cache-dir --break-system-packages poetry uv \
    && npm install -g pnpm yarn \
    && gem install bundler 2>/dev/null || true

# Switch back to agent user (default user in Claude sandbox)
USER agent

# Install IntelliShell for the agent user (pinned to v3.4.0)
RUN curl -sSf https://raw.githubusercontent.com/lasantosr/intelli-shell/v3.4.0/install.sh | sh

# Install frankbria/ralph-claude-code (pinned to known-good commit)
RUN git clone https://github.com/frankbria/ralph-claude-code.git /tmp/ralph-claude-code \
    && cd /tmp/ralph-claude-code \
    && git checkout abcfa8b695ec388a33c03c1bcba9af7c89b25ff6 \
    && chmod +x install.sh \
    && ./install.sh \
    && rm -rf /tmp/ralph-claude-code

# Create config directories
RUN mkdir -p /home/agent/.config/helix /home/agent/.config/intelli-shell

# Copy configuration files
COPY --chown=agent:agent config/.zshrc /home/agent/.zshrc
COPY --chown=agent:agent config/helix-config.toml /home/agent/.config/helix/config.toml
COPY --chown=agent:agent config/intellishell-config.toml /home/agent/.config/intelli-shell/config.toml
COPY --chown=agent:agent config/intellishell-defaults.txt /home/agent/.config/intelli-shell/defaults.txt
COPY --chown=agent:agent config/claude-settings.json /home/agent/.config/claude-settings-template.json

# Stage configs for version-sync (outside volume mount path)
USER root
RUN mkdir -p /etc/claude-dev/configs
COPY CONFIG_VERSION /etc/claude-dev/CONFIG_VERSION
COPY config/.zshrc /etc/claude-dev/configs/.zshrc
COPY config/helix-config.toml /etc/claude-dev/configs/helix-config.toml
COPY config/intellishell-config.toml /etc/claude-dev/configs/intellishell-config.toml
COPY config/intellishell-defaults.txt /etc/claude-dev/configs/intellishell-defaults.txt
COPY config/claude-settings.json /etc/claude-dev/configs/claude-settings.json
USER agent

COPY --chown=agent:agent scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

# Copy helper scripts
COPY --chown=agent:agent scripts/container-welcome.sh /usr/local/bin/container-welcome
COPY --chown=agent:agent scripts/ralph-wrapper.sh /usr/local/bin/ralph-wrapper.sh
COPY --chown=agent:agent scripts/view-logs.sh /usr/local/bin/view-logs
COPY --chown=agent:agent scripts/detect-dependencies.sh /usr/local/bin/detect-dependencies.sh
COPY --chown=agent:agent scripts/guided-setup.sh /usr/local/bin/guided-setup.sh
COPY --chown=agent:agent scripts/ralph-watchdog.sh /usr/local/bin/ralph-watchdog
COPY --chown=agent:agent scripts/ralph-tmux.sh /usr/local/bin/ralph-tmux

# Make scripts executable
USER root
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/container-welcome \
             /usr/local/bin/ralph-wrapper.sh \
             /usr/local/bin/view-logs \
             /usr/local/bin/detect-dependencies.sh \
             /usr/local/bin/guided-setup.sh \
             /usr/local/bin/ralph-watchdog \
             /usr/local/bin/ralph-tmux
USER agent

# Set default shell to zsh
ENV SHELL=/bin/zsh

# Set working directory
WORKDIR /workspace

# Use custom entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/zsh"]
