#!/bin/bash
set -e

# Create workspace directory if it doesn't exist
mkdir -p /workspace

# Change to workspace directory
cd /workspace

# Execute the provided command or start zsh
exec "$@"
