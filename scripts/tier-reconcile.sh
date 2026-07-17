#!/bin/sh
# tier-reconcile — keep the tier slots linked to the default model.
#
# Reads .model from settings.json, derives the trio (via tier-derive), and
# rewrites the ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL slots ONLY IF they
# differ from the derived values. This is the mechanism that links /model → the
# worker/recon tiers: /model persists the new default to settings.json, and the
# next UserPromptSubmit fires this — before any subagent spawns that turn — so
# executor/scout always run models consecutive to the current default.
#
# Contract (it runs on every prompt, so all three matter):
#   - Idempotent: no write when already in sync.
#   - Silent: prints NOTHING on stdout (a UserPromptSubmit hook's stdout would
#     be injected into the prompt). Diagnostics, if any, go to stderr.
#   - Fast: a couple of jq reads + at most one atomic write.
#   - Never clobbers: an off-ladder/custom .model (tier-derive exits non-zero)
#     leaves the slots exactly as they are.
#
# TIER_SETTINGS overrides the settings path (used by the test suite).

set -u
SETTINGS="${TIER_SETTINGS:-$HOME/.claude/settings.json}"

[ -f "$SETTINGS" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Locate tier-derive whether installed (/usr/local/bin) or run from the repo.
DERIVE=$(command -v tier-derive 2>/dev/null) || DERIVE="$(dirname "$0")/tier-derive.sh"
[ -x "$DERIVE" ] || exit 0

model=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
[ -n "$model" ] || exit 0

trio=$("$DERIVE" "$model" 2>/dev/null) || exit 0   # off-ladder → no-op, don't clobber
# shellcheck disable=SC2086 # trio is three shell-safe ids, intentional split
set -- $trio
[ $# -eq 3 ] || exit 0
top=$1; worker=$2; recon=$3

cur_o=$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL   // empty' "$SETTINGS" 2>/dev/null)
cur_s=$(jq -r '.env.ANTHROPIC_DEFAULT_SONNET_MODEL // empty' "$SETTINGS" 2>/dev/null)
cur_h=$(jq -r '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL  // empty' "$SETTINGS" 2>/dev/null)
[ "$cur_o" = "$top" ] && [ "$cur_s" = "$worker" ] && [ "$cur_h" = "$recon" ] && exit 0  # in sync

tmp=$(mktemp "$SETTINGS.XXXXXX") || exit 0
if jq --arg o "$top" --arg s "$worker" --arg h "$recon" '
        .env = ((.env // {})
                | .ANTHROPIC_DEFAULT_OPUS_MODEL   = $o
                | .ANTHROPIC_DEFAULT_SONNET_MODEL = $s
                | .ANTHROPIC_DEFAULT_HAIKU_MODEL  = $h)
    ' "$SETTINGS" > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
    mode=$(stat -c %a "$SETTINGS" 2>/dev/null) || mode=644
    chmod "$mode" "$tmp" 2>/dev/null
    mv "$tmp" "$SETTINGS"
else
    rm -f "$tmp"
fi
exit 0
