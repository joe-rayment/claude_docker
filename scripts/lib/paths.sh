#!/usr/bin/env bash
#
# paths.sh -- shared path helpers, sourced (never executed) by every S4
# script (claude-orca-3sk.4; see .claude/plans/orca-port.md S3.6). This is
# the ONLY place that may reference ~/.claude or $HOME/.claude literally --
# every other script under scripts/ goes through claude_config_dir()
# instead (tests/config-sync.bats grep-gates this).
#
# Functions (each prints its result on stdout; non-zero/no-output = failed):
#   claude_config_dir  -- ${CLAUDE_CONFIG_DIR:-$HOME/.claude}. Always
#                          succeeds (falls back to $HOME even if unset/empty).
#   claude_orca_root    -- $CLAUDE_ORCA_ROOT if set, else the bootstrapped
#                          project containing $PWD. Exit 1, no output, if
#                          neither resolves (not inside a bootstrapped
#                          project and no override given).
#   run_dir             -- "$(claude_orca_root)/.claude-dev/run" -- what the
#                          agent side writes (tier.json, the config-sync
#                          hash). state/ next to it is written by the Mac
#                          and read as authority, so anything produced
#                          inside the container belongs here.
#                          Exit 1, no output, if claude_orca_root fails.
#   tier_state_file     -- "$(run_dir)/tier.json". Exit 1, no output, if
#                          run_dir fails.
#   template_dir        -- this file's own directory's grandparent (i.e.
#                          scripts/lib/paths.sh -> the repo/template root),
#                          resolved through symlinks -- independent of which
#                          script sourced this file or from where.
#   host_dir            -- $CLAUDE_ORCA_HOST if set, else template_dir's
#                          parent (<project>/.claude-dev when template_dir
#                          is <project>/.claude-dev/template -- the
#                          per-folder layout).
#   project_dir         -- $CLAUDE_ORCA_ROOT if set, else host_dir's parent
#                          (the project folder itself). Exit 1, no output,
#                          if neither resolves.

claude_config_dir() {
    printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# v3 (claude-orca-qa2.3): the detection the deleted claude-orca-root binary
# did, inlined -- there is no host-side wrapper left to carry it. A folder
# is "bootstrapped" when it has .claude-dev/claude-orca.json. From inside a
# linked worktree the primary checkout is the git common dir's parent;
# outside git, walk up. Read-only: nothing here writes, execs or sources
# anything under the project it inspects.
_paths_sh_primary() {
    local dir="$1" common
    common="$(cd "$dir" && git rev-parse --git-common-dir 2>/dev/null)" || common=""
    if [ -n "$common" ]; then
        case "$common" in
            /*) ;;
            *)  common="$dir/$common" ;;
        esac
        (cd "$common/.." && pwd -P) && return 0
        return 1
    fi
    while :; do
        if [ -f "$dir/.claude-dev/claude-orca.json" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
        [ "$dir" = "/" ] && return 1
        dir="$(cd "$dir/.." && pwd -P)" || return 1
    done
}

claude_orca_root() {
    if [ -n "${CLAUDE_ORCA_ROOT:-}" ]; then
        printf '%s\n' "$CLAUDE_ORCA_ROOT"
        return 0
    fi
    local primary
    primary="$(_paths_sh_primary "$PWD")" || return 1
    [ -f "$primary/.claude-dev/claude-orca.json" ] || return 1
    printf '%s\n' "$primary"
}

run_dir() {
    local root
    root="$(claude_orca_root)" || return 1
    printf '%s\n' "$root/.claude-dev/run"
}

tier_state_file() {
    local run
    run="$(run_dir)" || return 1
    printf '%s\n' "$run/tier.json"
}

# Resolves $1, following symlinks -- shared by template_dir/host_dir so both
# agree on THIS FILE's own real location regardless of how many symlink hops
# (bin/<name> -> ../scripts/<name>.sh, or the .claude-dev/bin/claude-dev
# chain) sit between the caller and here.
_paths_sh_resolve() {
    local src="$1" link dir
    while [ -L "$src" ]; do
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(cd "$(dirname "$src")" && pwd)"; src="$dir/$link" ;;
        esac
    done
    printf '%s\n' "$src"
}

template_dir() {
    local self resolved
    self="${BASH_SOURCE[0]}"
    resolved="$(_paths_sh_resolve "$self")"
    (cd "$(dirname "$resolved")/../.." && pwd)
}

host_dir() {
    if [ -n "${CLAUDE_ORCA_HOST:-}" ]; then
        printf '%s\n' "$CLAUDE_ORCA_HOST"
        return 0
    fi
    local t
    t="$(template_dir)" || return 1
    (cd "$t/.." && pwd)
}

# V2 (claude-orca-qt9.2): the project folder itself. There is no central
# install any more -- the template lives at <project>/.claude-dev/
# template, so host_dir() is <project>/.claude-dev and its parent is the
# project. $CLAUDE_ORCA_ROOT wins when set (the sandboxed side always has
# it). Exit 1, no output, when neither resolves.
project_dir() {
    if [ -n "${CLAUDE_ORCA_ROOT:-}" ]; then
        printf '%s\n' "$CLAUDE_ORCA_ROOT"
        return 0
    fi
    local h
    h="$(host_dir)" || return 1
    (cd "$h/.." && pwd)
}
