#!/usr/bin/env bash
#
# link-bin.sh -- (re)creates <project>/.claude-dev/bin, the folder's
# host-side launcher surface: one RELATIVE symlink per entry point into
# the template clone beside it (V5, claude-orca-qt9.5).
#
# Usage: link-bin.sh [<host dir>]     (default: this template's parent)
#
# Why a script of its own rather than one line in bootstrap.sh: the list
# has changed before and will again, and a folder that only ever runs
# `claude-dev --update` must end up with the same bin/ as one bootstrapped
# today. `--update` runs THIS file from the freshly pulled template, so a
# new entry point arrives with the pull instead of waiting for someone to
# re-run the bootstrap one-liner.
#
# v3 (claude-orca-qa2.3): the Mac side runs one thing now -- the launcher.
# Everything an agent uses lives inside the container image and is reached
# through <project>/.claude-dev/template/bin, never through here.
#
# Relative link targets on purpose: the whole folder stays movable, and a
# pulled fix takes effect with no relinking. Idempotent (ln -sfn).

set -euo pipefail

_resolve_script_path() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        local link dir
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(cd "$(dirname "$src")" && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}
SCRIPT_DIR="$(cd "$(dirname "$(_resolve_script_path)")" && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"

HOST="${1:-$(host_dir)}"

mkdir -p "$HOST/bin"
ln -sfn "../template/scripts/launcher.sh"               "$HOST/bin/claude-dev"
