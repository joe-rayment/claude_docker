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
#   claude_orca_root    -- $CLAUDE_ORCA_ROOT if set, else the claude-orca-root
#                          binary's detection from $PWD. Exit 1, no output,
#                          if neither resolves (not inside a bootstrapped
#                          project and no override given).
#   tier_state_file     -- "$(claude_orca_root)/.claude-dev/state/tier.json".
#                          Exit 1, no output, if claude_orca_root fails.
#   template_dir        -- this file's own directory's grandparent (i.e.
#                          scripts/lib/paths.sh -> the repo/template root),
#                          resolved through symlinks -- independent of which
#                          script sourced this file or from where.
#   host_dir            -- $CLAUDE_ORCA_HOST if set, else template_dir's
#                          parent (<project>/.claude-dev when template_dir
#                          is <project>/.claude-dev/template -- the v2
#                          per-folder layout; see plans/orca-port.md S9.2).

claude_config_dir() {
    printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

claude_orca_root() {
    if [ -n "${CLAUDE_ORCA_ROOT:-}" ]; then
        printf '%s\n' "$CLAUDE_ORCA_ROOT"
        return 0
    fi
    command -v claude-orca-root >/dev/null 2>&1 || return 1
    claude-orca-root
}

tier_state_file() {
    local root
    root="$(claude_orca_root)" || return 1
    printf '%s\n' "$root/.claude-dev/state/tier.json"
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
