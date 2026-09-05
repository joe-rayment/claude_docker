#!/bin/bash
unset CLAUDECODE

# Resolve through a symlink chain (e.g. bin/start-professor -> ../scripts/
# start-professor.sh) to this script's real directory, so lib/paths.sh
# resolves whether this is invoked via the repo copy or the
# ~/.claude-orca/template/bin/ symlink.
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

root="$(claude_orca_root 2>/dev/null)" && cd "$root" 2>/dev/null || true
exec claude --agent professor --dangerously-skip-permissions
