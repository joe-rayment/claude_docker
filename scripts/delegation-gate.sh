#!/usr/bin/env bash
# delegation-gate.sh -- thin exec shim into python/delegation-gate.py. The real logic
# lives outside scripts/ on purpose: tests/shell-entry.bats (FROZEN, S2b,
# claude-orca-3sk.24) runs `bash -n` over every file `find`s under
# scripts/, and a real Python file there fails that parse -- see
# scripts/lib/paths.sh's header and .claude/plans/orca-port.md S7 notes.
# This shim IS a real, bash-3.2-clean file under scripts/, so it satisfies
# that contract; python/delegation-gate.py carries the actual behaviour and its
# own tests/delegation-gate.bats invokes it directly by path too.
set -u

# Resolve through a symlink chain (e.g. bin/delegation-gate -> ../scripts/
# delegation-gate.sh) to this script's real directory, so the sibling python/ dir
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
exec python3 "$SCRIPT_DIR/../python/delegation-gate.py" "$@"
