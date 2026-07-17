#!/bin/sh
# tier-reconcile — keep the tier slots linked to the default model.
#
# Reads .model from settings.json, derives the trio (via tier-derive), and
# rewrites the ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL(+_NAME) slots ONLY
# IF they differ from the derived values. This is the mechanism that links
# /model → the worker/recon tiers: /model persists the new default to
# settings.json, and the next UserPromptSubmit fires this — before any
# subagent spawns that turn — so executor/scout always run models consecutive
# to the current default.
#
# The _NAME writes exist because Claude Code's own /model picker reads the
# SAME ANTHROPIC_DEFAULT_*_MODEL vars to build its "Opus"/"Sonnet"/"Haiku"
# menu rows, defaulting each row's label to the companion *_NAME var (falling
# back to the raw id, never to the hardcoded "Opus"/"Sonnet"/"Haiku" text) —
# see tier-set.sh's header for how this was confirmed.
#
# IMPORTANT: the _NAME sync is a SEPARATE concern from the VALUE derivation,
# and runs unconditionally off whatever the slots ALREADY hold — not gated on
# .model being on-ladder or on an explicit pin being absent. A pin (or an
# off-ladder .model) only opts out of re-deriving the slot VALUES from
# .model; it says nothing about whether the NAME already sitting next to a
# perfectly nameable value is honest. Without this split, a session whose
# .model has drifted off-ladder (e.g. a custom "opus[1m]" typed straight into
# the picker) while ANTHROPIC_DEFAULT_OPUS_MODEL still holds a real, on-ladder
# id from an earlier /tier run would NEVER get its _NAME written — the picker
# would stay mislabeled for the rest of the session even though the fix was
# "installed". So: VALUE re-derivation is gated (pin / on-ladder .model);
# NAME sync is not — it always reflects whatever value ends up in each slot.
#
# An explicit (2/3-arg) `tier-set` pin sets .env.TIER_EXPLICIT_PIN="1" to opt
# the session OUT of VALUE auto-derivation — this hook then leaves the
# pinned worker/recon VALUES alone (but still keeps their NAMEs honest).
# Running a plain 1-arg `/tier <top>` clears the pin and resumes tracking
# .model automatically.
#
# Contract (it runs on every prompt, so all three matter):
#   - Idempotent: no write when already in sync.
#   - Silent: prints NOTHING on stdout (a UserPromptSubmit hook's stdout would
#     be injected into the prompt). Diagnostics, if any, go to stderr.
#   - Fast: a couple of jq reads + at most one atomic write.
#   - Never clobbers a slot VALUE: an off-ladder/custom .model (tier-derive
#     exits non-zero) or an active explicit pin leaves VALUES exactly as they
#     are — only NAMEs may still be touched, to match those unchanged values.
#
# TIER_SETTINGS overrides the settings path (used by the test suite).

set -u
SETTINGS="${TIER_SETTINGS:-$HOME/.claude/settings.json}"

[ -f "$SETTINGS" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Locate tier-derive whether installed (/usr/local/bin) or run from the repo.
DERIVE=$(command -v tier-derive 2>/dev/null) || DERIVE="$(dirname "$0")/tier-derive.sh"
[ -x "$DERIVE" ] || exit 0

name_for() { [ -n "$1" ] || return 0; "$DERIVE" --name "$1" 2>/dev/null || true; }

cur_o=$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL   // empty' "$SETTINGS" 2>/dev/null)
cur_s=$(jq -r '.env.ANTHROPIC_DEFAULT_SONNET_MODEL // empty' "$SETTINGS" 2>/dev/null)
cur_h=$(jq -r '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL  // empty' "$SETTINGS" 2>/dev/null)
cur_on=$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME   // empty' "$SETTINGS" 2>/dev/null)
cur_sn=$(jq -r '.env.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME // empty' "$SETTINGS" 2>/dev/null)
cur_hn=$(jq -r '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME  // empty' "$SETTINGS" 2>/dev/null)

# VALUE re-derivation: skipped (new_* stay == cur_*) while pinned, while
# .model is unset/off-ladder, or once a pin/off-ladder check below bails.
new_o=$cur_o; new_s=$cur_s; new_h=$cur_h

pinned=$(jq -r '.env.TIER_EXPLICIT_PIN // empty' "$SETTINGS" 2>/dev/null)
if [ "$pinned" != "1" ]; then
    model=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
    if [ -n "$model" ] && trio=$("$DERIVE" "$model" 2>/dev/null); then
        # shellcheck disable=SC2086 # trio is three shell-safe ids, intentional split
        set -- $trio
        [ $# -eq 3 ] && { new_o=$1; new_s=$2; new_h=$3; }
    fi
fi

# NAME sync: always reflects whichever value each slot ends up holding.
new_on=$(name_for "$new_o"); new_sn=$(name_for "$new_s"); new_hn=$(name_for "$new_h")

[ "$cur_o" = "$new_o" ] && [ "$cur_s" = "$new_s" ] && [ "$cur_h" = "$new_h" ] \
    && [ "$cur_on" = "$new_on" ] && [ "$cur_sn" = "$new_sn" ] && [ "$cur_hn" = "$new_hn" ] \
    && exit 0  # in sync

tmp=$(mktemp "$SETTINGS.XXXXXX") || exit 0
if jq --arg o "$new_o" --arg s "$new_s" --arg h "$new_h" \
      --arg no "$new_on" --arg ns "$new_sn" --arg nh "$new_hn" '
        .env = ((.env // {})
                | (if $o != "" then .ANTHROPIC_DEFAULT_OPUS_MODEL   = $o else . end)
                | (if $s != "" then .ANTHROPIC_DEFAULT_SONNET_MODEL = $s else . end)
                | (if $h != "" then .ANTHROPIC_DEFAULT_HAIKU_MODEL  = $h else . end)
                | (if $no != "" then .ANTHROPIC_DEFAULT_OPUS_MODEL_NAME   = $no else del(.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME)   end)
                | (if $ns != "" then .ANTHROPIC_DEFAULT_SONNET_MODEL_NAME = $ns else del(.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME) end)
                | (if $nh != "" then .ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME  = $nh else del(.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME)  end))
    ' "$SETTINGS" > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
    mode=$(stat -c %a "$SETTINGS" 2>/dev/null) || mode=644
    chmod "$mode" "$tmp" 2>/dev/null
    mv "$tmp" "$SETTINGS"
else
    rm -f "$tmp"
fi
exit 0
