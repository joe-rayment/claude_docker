#!/usr/bin/env bash
#
# tier-reconcile -- SessionStart/PostModelSwitch/ConfigChange hook. Keeps
# .claude-dev/state/tier.json's top/worker/recon in sync with the bound
# model, and purges legacy picker-corrupting env vars from
# <config dir>/settings.local.json's .env block. S4 (claude-orca-3sk.4)
# replaces the old frontmatter-rewriting version -- see scripts/tier-set.sh's
# header -- this hook now writes tier.json, never agents/*.md.
#
# Contract (runs on every SessionStart/model-switch, so all three matter):
#   - Idempotent: no write when already in sync.
#   - Silent: prints NOTHING on stdout (a hook's stdout can be surfaced to
#     the transcript/prompt; diagnostics, if any, go to stderr).
#   - Never clobbers a pinned or off-ladder binding, and never touches
#     .model itself -- that is the user's lever, via /model or /tier.
#
# PostModelSwitch/ConfigChange pipe a JSON payload on stdin; PostModelSwitch's
# carries `to_model`, preferred over the live settings .model because the
# switch may not be persisted to disk yet. Stdin is read only when not a tty,
# so a manual/interactive run never blocks waiting on input.
#
# TIER_STATE_FILE / TIER_SETTINGS_LOCAL / TIER_SETTINGS / TIER_DERIVE
# override the paths (test suite).

set -u

# Resolve through a symlink chain (e.g. bin/tier-reconcile ->
# ../scripts/tier-reconcile.sh) to this script's real directory, so
# lib/paths.sh resolves whether this is invoked via the repo copy or the
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
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"

to_model=""
if [ ! -t 0 ]; then
    payload=$(cat 2>/dev/null)
    if [ -n "$payload" ]; then
        to_model=$(printf '%s' "$payload" | jq -r 'if type == "object" then (.to_model // empty) else empty end' 2>/dev/null)
    fi
fi

command -v jq >/dev/null 2>&1 || exit 0

STATE_FILE="${TIER_STATE_FILE:-}"
[ -n "$STATE_FILE" ] || STATE_FILE="$(tier_state_file 2>/dev/null)" || exit 0

LOCAL_SETTINGS="${TIER_SETTINGS_LOCAL:-}"
[ -n "$LOCAL_SETTINGS" ] || LOCAL_SETTINGS="$(claude_config_dir)/settings.local.json"
BASE_SETTINGS="${TIER_SETTINGS:-}"
[ -n "$BASE_SETTINGS" ] || BASE_SETTINGS="$(claude_config_dir)/settings.json"

DERIVE="${TIER_DERIVE:-}"
if [ -z "$DERIVE" ]; then
    DERIVE=$(command -v tier-derive 2>/dev/null) || DERIVE="$SCRIPT_DIR/tier-derive.sh"
fi
[ -x "$DERIVE" ] || exit 0

# 1) Purge legacy picker-corrupting env vars from settings.local.json's .env
#    block, if any are present. Always runs, even when a pin or an
#    off-ladder .model skips the derivation below.
if [ -f "$LOCAL_SETTINGS" ] && jq -e '(.env // {}) | keys | map(select(test("^ANTHROPIC_DEFAULT_(OPUS|SONNET|HAIKU)_MODEL(_NAME)?$") or . == "CLAUDE_CODE_SUBAGENT_MODEL")) | length > 0' "$LOCAL_SETTINGS" >/dev/null 2>&1; then
    tmp=$(mktemp "$LOCAL_SETTINGS.XXXXXX") || exit 0
    if jq '.env = ((.env // {})
                   | del(.ANTHROPIC_DEFAULT_OPUS_MODEL, .ANTHROPIC_DEFAULT_SONNET_MODEL, .ANTHROPIC_DEFAULT_HAIKU_MODEL,
                         .ANTHROPIC_DEFAULT_OPUS_MODEL_NAME, .ANTHROPIC_DEFAULT_SONNET_MODEL_NAME, .ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME,
                         .CLAUDE_CODE_SUBAGENT_MODEL))
       ' "$LOCAL_SETTINGS" > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$LOCAL_SETTINGS"
    else
        rm -f "$tmp"
    fi
fi

# 2) Re-derive worker/recon (and refresh the recorded top) in tier.json from
#    the live .model -- unless pinned, .model is unset, or .model is
#    off-ladder (never clobber a binding we can't place on the ladder).
pinned="false"
[ -f "$STATE_FILE" ] && pinned=$(jq -r '.pinned // false' "$STATE_FILE" 2>/dev/null)
[ "$pinned" = "true" ] && exit 0

model="$to_model"
if [ -z "$model" ] && [ -f "$LOCAL_SETTINGS" ]; then
    model=$(jq -r '.model // empty' "$LOCAL_SETTINGS" 2>/dev/null)
fi
if [ -z "$model" ] && [ -f "$BASE_SETTINGS" ]; then
    model=$(jq -r '.model // empty' "$BASE_SETTINGS" 2>/dev/null)
fi
[ -n "$model" ] || exit 0

overdriven="false"
[ -f "$STATE_FILE" ] && overdriven=$(jq -r '.overdrive // false' "$STATE_FILE" 2>/dev/null)

# An off-ladder .model exits non-zero and leaves tier.json untouched; so does
# a tier-derive too old to know --overdrive (it reads the flag as the model
# id and exits 3). Never retry without the flag -- falling back to the
# capped derivation would silently revert an active lift.
if [ "$overdriven" = "true" ]; then
    trio=$("$DERIVE" --overdrive "$model" 2>/dev/null) || exit 0
else
    trio=$("$DERIVE" "$model" 2>/dev/null) || exit 0
fi
set -f; set -- $trio; set +f
[ $# -eq 3 ] || exit 0
want_top=$1 want_w=$2 want_c=$3

cur_top=""; cur_w=""; cur_c=""
if [ -f "$STATE_FILE" ]; then
    cur_top=$(jq -r '.top // empty' "$STATE_FILE" 2>/dev/null)
    cur_w=$(jq -r '.worker // empty' "$STATE_FILE" 2>/dev/null)
    cur_c=$(jq -r '.recon // empty' "$STATE_FILE" 2>/dev/null)
fi
[ "$cur_top" = "$want_top" ] && [ "$cur_w" = "$want_w" ] && [ "$cur_c" = "$want_c" ] && exit 0

base_json='{}'
if [ -f "$STATE_FILE" ]; then
    existing="$(cat "$STATE_FILE" 2>/dev/null)"
    printf '%s' "$existing" | jq -e . >/dev/null 2>&1 && base_json="$existing"
fi

mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
tmp=$(mktemp "$STATE_FILE.XXXXXX") || exit 0
if printf '%s' "$base_json" | jq --arg t "$want_top" --arg w "$want_w" --arg c "$want_c" \
      --arg u "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.top = $t | .worker = $w | .recon = $c | .updated = $u
       | .pinned = (.pinned // false) | .overdrive = (.overdrive // false)' \
      > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$STATE_FILE"
else
    rm -f "$tmp"
fi
exit 0
