#!/usr/bin/env bash
#
# Verifies each tool the Brewfile installs is on PATH. Informational (S1):
# always exits 0. S3's --doctor gate is the version of this that fails a
# session, and it is also what reports the in-folder pieces (Claude Code,
# Orca.app) -- V1 dropped the Orca cask row from here, because in v2 a
# central Orca install is precisely what must NOT be used.
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

exit 0
