#!/bin/bash
set -e

# Initialize Claude Code authentication if needed
if [ ! -f "/home/agent/.claude/credentials" ] && [ -n "$ANTHROPIC_API_KEY" ]; then
    echo "Setting up Claude Code authentication..."
    mkdir -p /home/agent/.claude
    echo "$ANTHROPIC_API_KEY" > /home/agent/.claude/credentials
fi

# Initialize git config if not already set
if [ ! -f "/home/agent/.gitconfig" ]; then
    if [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; then
        echo "Configuring Git..."
        git config --global user.name "$GIT_USER_NAME"
        git config --global user.email "$GIT_USER_EMAIL"
    fi
fi

# Set up GitHub CLI authentication if token is provided
if [ -n "$GITHUB_TOKEN" ]; then
    echo "Configuring GitHub CLI..."
    echo "$GITHUB_TOKEN" | gh auth login --with-token
fi

# Create workspace directory if it doesn't exist
mkdir -p /workspace

# Change to workspace directory
cd /workspace

# Execute the provided command or start zsh
exec "$@"
