#!/usr/bin/env bash
#
# Verifies each tool the Brewfile installs is on PATH, and checks whether
# the Orca cask is installed -- printing the install hint when it isn't.
# Never installs the Orca GUI app itself. Informational (S1): always exits
# 0. S3's --doctor gate is the version of this that fails a session.
#
# beads is a Homebrew *core* formula (see Brewfile), so there is no tarball
# fallback here -- if that ever changes, this is where a tarball install
# (pinned BD_VERSION, matching the old claude_docker Dockerfile) would go.

set -euo pipefail

TOOLS="git gh brew jq rg node bats bd"

for tool in $TOOLS; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf '  [ok]      %s\n' "$tool"
    else
        printf '  [missing] %s\n' "$tool"
    fi
done

if brew list --cask orca >/dev/null 2>&1 || [ -d "/Applications/Orca.app" ]; then
    printf '  [ok]      orca (cask)\n'
else
    printf '  [missing] orca (cask) -- run: brew install --cask stablyai/orca/orca\n'
fi

exit 0
