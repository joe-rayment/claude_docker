#!/bin/bash
set -euo pipefail

# auth-guard.sh — billing hard-guard (beads_claude_docker-q34): this sandbox
# must run Claude Code on subscription auth only. The presence of
# ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, or ANTHROPIC_API_KEY -- in the
# process environment, or under the `.env` object of either the config
# dir's settings.json or settings.local.json (see lib/paths.sh's
# claude_config_dir()) -- silently flips Claude Code's billing from
# subscription to API. That is a hazard, not a config choice: FATAL + exit 1
# by default. CLAUDE_DEV_ALLOW_API_BILLING=1 downgrades every hit to a
# WARNING and lets the sandbox continue (exit 0). No hits -> silent exit 0.
#
# Standalone, callable directly.
#
# Fails OPEN per var-source, never crashes the caller: a missing jq skips
# the settings-file checks (process-env checks need no jq and always run);
# a missing settings file is simply not a hit, not an error.

# Resolve through a symlink chain (e.g. bin/auth-guard -> ../scripts/
# auth-guard.sh) to this script's real directory, so lib/paths.sh resolves
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

VARS=(ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY)
SETTINGS="$(claude_config_dir)/settings.json"
SETTINGS_LOCAL="$(claude_config_dir)/settings.local.json"

hit_vars=()
hit_locs=()

record_hit() {
    hit_vars+=("$1")
    hit_locs+=("$2")
}

for v in "${VARS[@]}"; do
    if [ -n "${!v:-}" ]; then
        record_hit "$v" "the process environment"
    fi
done

# check_settings_file <path> -- records a hit for every offending var found
# under that file's top-level `.env` object. A missing file or a missing jq
# is never fatal here: it is simply not a hit (fail OPEN per var-source).
check_settings_file() {
    local file="$1" v val
    [ -f "$file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    for v in "${VARS[@]}"; do
        val=$(jq -r --arg k "$v" '(.env // {})[$k] // empty' "$file" 2>/dev/null) || val=""
        if [ -n "$val" ]; then
            record_hit "$v" "the .env block of $file"
        fi
    done
}

check_settings_file "$SETTINGS"
check_settings_file "$SETTINGS_LOCAL"

if [ "${#hit_vars[@]}" -eq 0 ]; then
    exit 0
fi

level=FATAL
if [ "${CLAUDE_DEV_ALLOW_API_BILLING:-0}" = "1" ]; then
    level=WARNING
fi

i=0
while [ "$i" -lt "${#hit_vars[@]}" ]; do
    echo "$level: ${hit_vars[$i]} is set in ${hit_locs[$i]} -- this silently switches Claude Code billing from subscription to API." >&2
    i=$((i + 1))
done

if [ "$level" = "WARNING" ]; then
    echo "WARNING: CLAUDE_DEV_ALLOW_API_BILLING=1 is set -- continuing with API billing allowed." >&2
    exit 0
fi

echo "FATAL: refusing to start -- this sandbox runs Claude Code on subscription auth only." >&2
echo "FATAL: unset the var(s) named above, or set CLAUDE_DEV_ALLOW_API_BILLING=1 to downgrade this to a warning." >&2
exit 1
