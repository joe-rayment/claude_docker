#!/usr/bin/env bash
#
# auth-guard.sh -- billing hard-guard, ported unchanged in behaviour from
# claude_docker's scripts/auth-guard.sh (beads_claude_docker-q34) for S5
# (claude-orca-3sk.17). A sandboxed project must run Claude Code on
# subscription auth only. The presence of ANTHROPIC_BASE_URL,
# ANTHROPIC_AUTH_TOKEN, or ANTHROPIC_API_KEY -- in the process
# environment, or under the `.env` object of either
# <config dir>/settings.json or <config dir>/settings.local.json --
# silently flips Claude Code's billing from subscription to API. That is a
# hazard, not a config choice: FATAL + exit 1 by default.
# CLAUDE_DEV_ALLOW_API_BILLING=1 downgrades every hit to a WARNING and
# lets the caller continue (exit 0). No hits -> silent exit 0.
#
# Run by the container entrypoint before any agent starts, and callable
# directly as bin/auth-guard.
#
# Fails OPEN per var-source, never crashes the caller: a missing jq skips
# the settings-file checks (process-env checks need no jq and always run);
# a missing settings file is simply not a hit, not an error.
#
# bash 3.2 clean: no `${#arr[@]}` on a possibly-empty array under `set -u`
# (macOS /bin/bash treats that as an unbound variable), hence the explicit
# hit_count.

set -euo pipefail

_resolve_script_path() {
    local src="${BASH_SOURCE[0]}" link dir
    while [ -L "$src" ]; do
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(case "$src" in (*/*) cd "${src%/*}/" ;; esac && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}
SCRIPT_DIR="$(_s="$(_resolve_script_path)"; case "$_s" in (*/*) cd "${_s%/*}/" ;; esac && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"

case "${1:-}" in
    --help|-h)
        cat <<'USAGE'
Usage: auth-guard [--help]

Refuses (exit 1, FATAL on stderr) when ANTHROPIC_BASE_URL,
ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY is set in the process
environment or in the .env block of the Claude config dir's
settings.json / settings.local.json -- each silently switches Claude Code
billing from subscription to API. CLAUDE_DEV_ALLOW_API_BILLING=1
downgrades every hit to a WARNING (exit 0).
USAGE
        exit 0
        ;;
esac

VARS="ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY"
CONFIG_DIR="$(claude_config_dir)"
SETTINGS="$CONFIG_DIR/settings.json"
SETTINGS_LOCAL="$CONFIG_DIR/settings.local.json"

NL="$(printf '\nx')"; NL="${NL%x}"
TAB="$(printf '\tx')"; TAB="${TAB%x}"

hits=""
hit_count=0

# One newline-delimited list of "<var><tab><location>" rather than arrays:
# nothing in a var name or a settings path can contain a tab or a newline,
# and this stays clear of bash 3.2's empty-array-under-set -u trap
# entirely. Walked below with parameter expansion only -- no sed/awk --
# because tests/auth-guard.bats runs this script with everything bar
# dirname/readlink off PATH (the "missing jq" cases) and still expects the
# FATAL lines.
record_hit() {
    hits="$hits$1$TAB$2$NL"
    hit_count=$((hit_count + 1))
}

for v in $VARS; do
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
    for v in $VARS; do
        val=$(jq -r --arg k "$v" '(.env // {})[$k] // empty' "$file" 2>/dev/null) || val=""
        if [ -n "$val" ]; then
            record_hit "$v" "the .env block of $file"
        fi
    done
}

check_settings_file "$SETTINGS"
check_settings_file "$SETTINGS_LOCAL"

if [ "$hit_count" -eq 0 ]; then
    exit 0
fi

level=FATAL
if [ "${CLAUDE_DEV_ALLOW_API_BILLING:-0}" = "1" ]; then
    level=WARNING
fi

rest="$hits"
while [ -n "$rest" ]; do
    line="${rest%%$NL*}"
    rest="${rest#*$NL}"
    [ -n "$line" ] || continue
    var="${line%%$TAB*}"
    loc="${line#*$TAB}"
    echo "$level: $var is set in $loc -- this silently switches Claude Code billing from subscription to API." >&2
done

if [ "$level" = "WARNING" ]; then
    echo "WARNING: CLAUDE_DEV_ALLOW_API_BILLING=1 is set -- continuing with API billing allowed." >&2
    exit 0
fi

echo "FATAL: refusing to start -- this project runs Claude Code on subscription auth only." >&2
echo "FATAL: unset the var(s) named above, or set CLAUDE_DEV_ALLOW_API_BILLING=1 to downgrade this to a warning." >&2
exit 1
