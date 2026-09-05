#!/usr/bin/env bash
#
# tier-prime -- SessionStart hook. Prints the tier trio from
# .claude-dev/state/tier.json (S4, claude-orca-3sk.4, replaces the old
# frontmatter-reading version -- see .claude/plans/orca-port.md S3.6 and
# scripts/tier-set.sh's header). MUST fail open: never non-zero, never
# blocking; a missing tier.json (or missing jq) prints an <unbound>
# fallback line instead of erroring.
#
# TIER_PRIME_STATE_FILE overrides the tier.json path (test suite).

set -u

# Resolve through a symlink chain (e.g. bin/tier-prime -> ../scripts/tier-prime.sh)
# to this script's real directory, so lib/paths.sh resolves whether this is
# invoked via the repo copy or the ~/.claude-orca/template/bin/ symlink.
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

STATE_FILE="${TIER_PRIME_STATE_FILE:-}"
[ -n "$STATE_FILE" ] || STATE_FILE="$(tier_state_file 2>/dev/null)" || STATE_FILE=""

top=""; worker=""; recon=""; pinned="false"; overdrive="false"
if [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
    top=$(jq -r '.top // empty' "$STATE_FILE" 2>/dev/null)
    worker=$(jq -r '.worker // empty' "$STATE_FILE" 2>/dev/null)
    recon=$(jq -r '.recon // empty' "$STATE_FILE" 2>/dev/null)
    pinned=$(jq -r '.pinned // false' "$STATE_FILE" 2>/dev/null)
    overdrive=$(jq -r '.overdrive // false' "$STATE_FILE" 2>/dev/null)
fi

flags=""
[ "$overdrive" = "true" ] && flags="$flags OVERDRIVE"
[ "$pinned" = "true" ] && flags="$flags PIN"

line="[tier] orchestrator=${top:-<unbound>} worker=${worker:-<unbound>} recon=${recon:-<unbound>}"
if [ -n "$flags" ]; then
    line="$line (${flags# })"
fi
echo "$line"
echo "protocol: $(claude_config_dir)/CLAUDE.md § Delegation · § Lanes"
exit 0
