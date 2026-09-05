#!/usr/bin/env bash
#
# v1-leftovers.sh -- the ONE place in this template allowed to name the v1
# host root, ~/.claude-orca (tests/layout.bats grep-gates every other
# script and config file). v1 installed the template, srt and the launcher
# centrally there; v2 puts all of it inside the project folder, so a
# machine bootstrapped before the switch is left carrying a central
# install that nothing reads any more -- and, worse, a central `claude-dev`
# on PATH that would register projects the old way.
#
# Usage:
#   v1-leftovers.sh --check    exit 0 and print a one-line report when
#                              leftovers exist; exit 1 (silent) when clean
#   v1-leftovers.sh --path     print just the path when it exists; exit 1
#                              (silent) when clean -- so a caller can name
#                              it before deleting it without hard-coding
#                              the one path this template may not name
#   v1-leftovers.sh --remove   remove ~/.claude-orca and report what went
#
# Never interactive: the bootstrap arrives over a pipe, so "offer" here
# means claude-dev --doctor prints the row and the exact command to run.
# The stale rc block needs no separate handling -- claude-dev rc-install
# rewrites the whole marker block in place on every register/update.

set -euo pipefail

V1_HOME="$HOME/.claude-orca"

cmd_check() {
    [ -e "$V1_HOME" ] || return 1
    echo "v1 leftover: $V1_HOME (the pre-v2 central install -- remove with 'claude-dev --remove-v1')"
    return 0
}

cmd_path() {
    [ -e "$V1_HOME" ] || return 1
    printf '%s\n' "$V1_HOME"
}

cmd_remove() {
    if [ ! -e "$V1_HOME" ]; then
        echo "No v1 leftovers: $V1_HOME does not exist"
        return 0
    fi
    echo "Removing the v1 central install at $V1_HOME"
    rm -rf "$V1_HOME"
    echo "Removed the v1 central install at $V1_HOME"
    echo "Run 'claude-dev rc-install' if any shell rc still sources it (register and --update do this for you)."
}

case "${1:---check}" in
    --check)  cmd_check ;;
    --path)   cmd_path ;;
    --remove) cmd_remove ;;
    *)        echo "Usage: v1-leftovers.sh [--check|--path|--remove]" >&2; exit 2 ;;
esac
