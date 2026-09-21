#!/usr/bin/env bash
#
# volume-dirs.sh -- the launcher's scratch volumes, for everything that
# writes files for a living (claude-orca-1eh). The launcher (separate bead,
# claude-orca-7uy) mounts docker volumes under the agent home and names
# them in CLAUDE_ORCA_VOLUME_DIRS, colon-separated guest paths; measured in
# claude-orca-19o, file-creating work on the macOS share costs 15x the wall
# time and 185x the VM interrupts of a docker volume. Consumers source this
# file and ask volume_dirs which of those names are real here:
#
#   . "$(dirname "$0")/volume-dirs.sh"
#   volume_dirs "$AGENT_HOME" | while read -r d; do ...
#
# An entry qualifies only when it (a) sits under the agent home, (b) walks
# nowhere with a '..' segment, and (c) `mountpoint -q` confirms is a mount
# point -- everything else is dropped with one 'ignored' line on stderr,
# because a silent filter would leave a mistyped volume looking exactly
# like a missing one. Unset or empty variable: nothing, exit 0. It never
# creates a directory: what is not mounted is the launcher's problem, and
# creating it would paper over exactly the failure this list exists to
# catch.
#
# Sourcing is safe more than once (the function is redefined, nothing
# runs), and bash 3.2 clean (scripts/lint-bash32.sh scans all of scripts/).

volume_dirs() {
    local agent_home="${1:-}" d
    [ -n "$agent_home" ] || return 0
    [ -n "${CLAUDE_ORCA_VOLUME_DIRS:-}" ] || return 0

    local oldIFS="$IFS"
    IFS=':'
    set -f
    for d in $CLAUDE_ORCA_VOLUME_DIRS; do
        # An empty segment (a stray leading/trailing colon) is not a path;
        # say nothing about it.
        [ -n "$d" ] || continue
        case "$d" in
            "$agent_home"/*) ;;
            *)
                printf 'volume-dirs: ignored (not under %s): %s\n' \
                    "$agent_home" "$d" >&2
                continue
                ;;
        esac
        # A '..' SEGMENT: /.. at the end, or /.. in the middle. '..foo'
        # and 'foo..' are ordinary names, not traversals.
        case "$d" in
            */..|*/../*)
                printf 'volume-dirs: ignored (contains ".."): %s\n' "$d" >&2
                continue
                ;;
        esac
        if mountpoint -q "$d" 2>/dev/null; then
            printf '%s\n' "$d"
        else
            printf 'volume-dirs: ignored (not a mount point): %s\n' "$d" >&2
        fi
    done
    set +f
    IFS="$oldIFS"
    return 0
}
