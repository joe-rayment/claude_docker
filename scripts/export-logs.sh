#!/usr/bin/env bash
#
# export-logs -- Stop hook: copies the config dir's latest debug log to
# exported-logs/last-session.log so it survives past the debug/ rotation.
# Silent and fail-open: a missing source, or any error, is never fatal --
# this must never block Stop.
set -u

# Resolve through a symlink chain (e.g. bin/export-logs -> ../scripts/
# export-logs.sh) to this script's real directory, so lib/paths.sh resolves
# whether this is invoked via the repo copy or the ~/.claude-orca/template/
# bin/ symlink.
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
CONFIG_DIR="$(claude_config_dir 2>/dev/null)" || exit 0

[ -f "$CONFIG_DIR/debug/latest" ] || exit 0
mkdir -p "$CONFIG_DIR/exported-logs" 2>/dev/null || exit 0
cp "$CONFIG_DIR/debug/latest" "$CONFIG_DIR/exported-logs/last-session.log" 2>/dev/null || exit 0
exit 0
