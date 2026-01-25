# Claude Code Development Environment
# Based on official Docker Claude Code sandbox
FROM docker/sandbox-templates:claude-code

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
    rm -rf helix-* helix.tar.xz && \
    ln -s /usr/local/lib/helix/runtime /usr/local/bin/runtime

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

# Switch back to agent user (default user in Claude sandbox)
USER agent

# Install IntelliShell for the agent user
RUN curl -sSf https://raw.githubusercontent.com/lasantosr/intelli-shell/main/install.sh | sh

# Create config directories
RUN mkdir -p /home/agent/.config/helix /home/agent/.config/intelli-shell

# Copy configuration files
COPY --chown=agent:agent config/.zshrc /home/agent/.zshrc
COPY --chown=agent:agent config/helix-config.toml /home/agent/.config/helix/config.toml
COPY --chown=agent:agent config/intellishell-config.toml /home/agent/.config/intelli-shell/config.toml
COPY --chown=agent:agent config/intellishell-defaults.txt /home/agent/.config/intelli-shell/defaults.txt
COPY --chown=agent:agent config/claude-settings.json /home/agent/.config/claude-settings-template.json
COPY --chown=agent:agent config/SPEC.md.template /home/agent/.config/
COPY --chown=agent:agent config/PLAN.md.template /home/agent/.config/
COPY --chown=agent:agent scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

# Copy helper scripts
COPY --chown=agent:agent scripts/container-welcome.sh /usr/local/bin/container-welcome
COPY --chown=agent:agent scripts/setup-ralph.sh /usr/local/bin/setup-ralph
COPY --chown=agent:agent scripts/ralph.sh /usr/local/bin/ralph.sh
COPY --chown=agent:agent scripts/view-logs.sh /usr/local/bin/view-logs

# Make scripts executable
USER root
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/container-welcome \
             /usr/local/bin/setup-ralph \
             /usr/local/bin/ralph.sh \
             /usr/local/bin/view-logs
USER agent

# Set default shell to zsh
ENV SHELL=/bin/zsh

# Set working directory
WORKDIR /workspace

# Use custom entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/zsh"]
