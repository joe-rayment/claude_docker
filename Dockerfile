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
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# Install Oh-My-Zsh with Pure theme and plugins
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v1.2.1/zsh-in-docker.sh)" -- \
    -t https://github.com/sindresorhus/pure \
    -p git \
    -p https://github.com/zsh-users/zsh-syntax-highlighting \
    -a 'fpath+=("$HOME/.zsh/pure")' \
    -a 'autoload -U promptinit; promptinit' \
    -a 'prompt pure'

# Install Helix editor
RUN wget -qO- https://github.com/helix-editor/helix/releases/latest/download/helix-$(uname -m)-linux.tar.xz | tar -xJ && \
    mv helix-*/hx /usr/local/bin/ && \
    mv helix-*/runtime /usr/local/lib/helix-runtime && \
    rm -rf helix-* && \
    ln -s /usr/local/lib/helix-runtime /usr/local/bin/runtime

# Upgrade pip and install Python packages
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel && \
    pip3 install --no-cache-dir \
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
RUN mkdir -p /home/agent/.config/helix

# Copy configuration files
COPY --chown=agent:agent config/.zshrc /home/agent/.zshrc
COPY --chown=agent:agent config/helix-config.toml /home/agent/.config/helix/config.toml
COPY --chown=agent:agent scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

# Make entrypoint executable
USER root
RUN chmod +x /usr/local/bin/entrypoint.sh
USER agent

# Set default shell to zsh
ENV SHELL=/bin/zsh

# Set working directory
WORKDIR /workspace

# Use custom entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/zsh"]
