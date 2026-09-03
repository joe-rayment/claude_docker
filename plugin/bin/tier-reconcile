#!/bin/sh
# tier-reconcile — keep the worker/recon agent bindings linked to the default model.
#
# Reads .model from settings.json, derives the trio (via tier-derive), and
# rewrites the `model:` frontmatter line of executor.md / scout.md ONLY IF they
# differ from the derived values. This is the mechanism that links /model → the
# worker/recon tiers: /model persists the new default to settings.json, and the
# next SessionStart/UserPromptSubmit fires this hook. Because agent definitions
# are SNAPSHOTTED at session start (verified empirically 2026-07-17), the
# rewritten bindings take effect in the NEXT session — the SessionStart run of
# this hook is what guarantees every session's executor/scout are consistent
# with .model from that session's first spawn.
#
# This hook NEVER touches:
#   - .model itself (that is the user's lever, via /model or /tier), and
#   - any ANTHROPIC_DEFAULT_* env var (writing those was the RETIRED v1
#     mechanism — it corrupted the native /model picker, whose Opus/Sonnet/
#     Haiku rows read those same vars and persist bare aliases on selection;
#     see tier-set.sh's header for the full post-mortem).
#
# It DOES actively PURGE the legacy vars wherever it finds them —
# ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL(_NAME) and
# CLAUDE_CODE_SUBAGENT_MODEL — because any of them silently corrupts model
# selection (the picker) or collapses the tiers onto one model. The purge runs
# even when a pin or an off-ladder .model skips derivation.
#
# An explicit (2/3-arg) `tier-set` pin sets .env.TIER_EXPLICIT_PIN="1" to opt
# the worker/recon bindings OUT of auto-derivation — this hook then leaves the
# agent files alone. A plain 1-arg `/tier <top>` clears the pin and resumes
# tracking .model automatically.
#
# `tier-set overdrive` sets .env.TIER_OVERDRIVE="1" instead, and that one is
# derived THROUGH, not around: this hook passes --overdrive to tier-derive, so
# the lifted worker is re-applied every prompt (surviving new sessions) and
# tracks .model wherever /model moves it. Pin beats overdrive: a literal
# binding is not re-derived at all.
#
# Contract (it runs on every prompt, so all three matter):
#   - Idempotent: no write when already in sync.
#   - Silent: prints NOTHING on stdout (a UserPromptSubmit hook's stdout would
#     be injected into the prompt). Diagnostics, if any, go to stderr.
#   - Fast: a couple of jq/grep reads; writes only on diff.
#   - Never clobbers a binding: an off-ladder/custom .model (tier-derive exits
#     non-zero), an empty .model, or an active pin leaves the agent files
#     exactly as they are.
#
# TIER_SETTINGS and TIER_AGENTS_DIR override the paths (used by the test suite).
#
# PostModelSwitch/ConfigChange (Claude Code >= 2.1.251) pipe a JSON payload
# on stdin; PostModelSwitch's carries a `to_model` field naming the switch
# target, read here and preferred over settings .model because the switch
# may not have been persisted to disk yet when the hook fires. Stdin is
# read only when NOT a tty (`[ ! -t 0 ]`), so a manual/interactive run never
# blocks waiting on input; empty, non-JSON, or to_model-less stdin all fall
# through to the settings-.model behavior unchanged.

set -u
SETTINGS="${TIER_SETTINGS:-$HOME/.claude/settings.json}"
AGENTS="${TIER_AGENTS_DIR:-$HOME/.claude/agents}"
EXEC_MD="$AGENTS/executor.md"
SCOUT_MD="$AGENTS/scout.md"

to_model=""
if [ ! -t 0 ]; then
    payload=$(cat 2>/dev/null)
    if [ -n "$payload" ]; then
        to_model=$(printf '%s' "$payload" | jq -r 'if type == "object" then (.to_model // empty) else empty end' 2>/dev/null)
    fi
fi

[ -f "$SETTINGS" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Locate tier-derive whether installed (/usr/local/bin) or run from the repo;
# TIER_DERIVE overrides the lookup (test suite / non-standard layouts).
DERIVE="${TIER_DERIVE:-}"
[ -n "$DERIVE" ] || DERIVE=$(command -v tier-derive 2>/dev/null) || DERIVE="$(dirname "$0")/tier-derive.sh"
[ -x "$DERIVE" ] || exit 0

fm_model() {  # current frontmatter `model:` value of an agent file ('' if none/missing)
    grep -m1 '^model:' "$1" 2>/dev/null | sed 's/^model:[[:space:]]*//'
}

fm_set() {  # fm_set <agent-file> <model-id> — rewrite the frontmatter model: line atomically
    f=$1; id=$2
    case "$id" in (*[!]a-zA-Z0-9._[-]*|'') return 0 ;; esac   # only safe id chars: sed/YAML injection guard
    grep -q '^model:' "$f" 2>/dev/null || return 0   # no file/line -> nothing to bind, stay silent
    mode=$(stat -c %a "$f" 2>/dev/null) || mode=644
    tmp=$(mktemp "$f.XXXXXX") || return 0
    if sed "0,/^model:/s|^model:.*|model: $id|" "$f" > "$tmp"; then
        chmod "$mode" "$tmp" 2>/dev/null
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
    fi
}

fm_effort() {  # current frontmatter `effort:` value of an agent file ('' if none/missing)
    grep -m1 '^effort:' "$1" 2>/dev/null | sed 's/^effort:[[:space:]]*//'
}

fm_effort_set() {  # fm_effort_set <agent-file> <low|medium|...> — add-or-correct the effort: line
    # atomically. Unlike fm_set, a MISSING line is not "nothing to bind": effort
    # is a per-role STATIC default (never derived from the ladder/top), so it is
    # INSERTED right after model: (matching the verifier.md/oracle.md template
    # convention) rather than requiring a pre-existing line to substitute into.
    f=$1; val=$2
    case "$val" in (*[!]a-zA-Z0-9._[-]*|'') return 0 ;; esac   # same injection guard as fm_set
    grep -q '^model:' "$f" 2>/dev/null || return 0   # no stable anchor -> stay silent, never guess placement
    mode=$(stat -c %a "$f" 2>/dev/null) || mode=644
    tmp=$(mktemp "$f.XXXXXX") || return 0
    if grep -q '^effort:' "$f" 2>/dev/null; then
        sed "0,/^effort:/s|^effort:.*|effort: $val|" "$f" > "$tmp"
    else
        sed "/^model:/a effort: $val" "$f" > "$tmp"
    fi
    if [ $? -eq 0 ]; then
        chmod "$mode" "$tmp" 2>/dev/null
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
    fi
}

# 1) Purge legacy picker-corrupting env vars, if any are present (always runs,
#    even when a pin or off-ladder .model skips the derivation below).
if jq -e '(.env // {}) | keys | map(select(test("^ANTHROPIC_DEFAULT_(OPUS|SONNET|HAIKU)_MODEL(_NAME)?$") or . == "CLAUDE_CODE_SUBAGENT_MODEL" or . == "ANTHROPIC_BASE_URL" or . == "ANTHROPIC_AUTH_TOKEN" or . == "ANTHROPIC_API_KEY")) | length > 0' \
        "$SETTINGS" >/dev/null 2>&1; then
    tmp=$(mktemp "$SETTINGS.XXXXXX") || exit 0
    if jq '.env = ((.env // {})
                   | del(.ANTHROPIC_DEFAULT_OPUS_MODEL, .ANTHROPIC_DEFAULT_SONNET_MODEL, .ANTHROPIC_DEFAULT_HAIKU_MODEL,
                         .ANTHROPIC_DEFAULT_OPUS_MODEL_NAME, .ANTHROPIC_DEFAULT_SONNET_MODEL_NAME, .ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME,
                         .CLAUDE_CODE_SUBAGENT_MODEL,
                         .ANTHROPIC_BASE_URL, .ANTHROPIC_AUTH_TOKEN, .ANTHROPIC_API_KEY))
       ' "$SETTINGS" > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
        mode=$(stat -c %a "$SETTINGS" 2>/dev/null) || mode=644
        chmod "$mode" "$tmp" 2>/dev/null
        mv "$tmp" "$SETTINGS"
    else
        rm -f "$tmp"
    fi
fi

# 2) Derive worker/recon from .model and sync the agent bindings — unless
#    pinned, .model is unset, or .model is off-ladder (never clobber).
pinned=$(jq -r '.env.TIER_EXPLICIT_PIN // empty' "$SETTINGS" 2>/dev/null)
[ "$pinned" = "1" ] && exit 0

model=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
[ -n "$to_model" ] && model="$to_model"
[ -n "$model" ] || exit 0

# `tier-set overdrive` parks .env.TIER_OVERDRIVE="1" to lift the worker cap.
# Unlike TIER_EXPLICIT_PIN above — a literal binding, so derivation is skipped
# outright — overdrive is a DERIVATION RULE: re-applied here every prompt, so
# the lift survives new sessions and follows .model wherever /model moves it.
overdriven=$(jq -r '.env.TIER_OVERDRIVE // empty' "$SETTINGS" 2>/dev/null)

# An off-ladder .model exits non-zero and leaves the bindings alone; so does a
# tier-derive too old to know --overdrive (it reads the flag as the model id
# and exits 3). Never retry without the flag: falling back to the capped
# derivation would silently revert the very lift this is honouring.
if [ "$overdriven" = "1" ]; then
    trio=$("$DERIVE" --overdrive "$model" 2>/dev/null) || exit 0
else
    trio=$("$DERIVE" "$model" 2>/dev/null) || exit 0
fi
# shellcheck disable=SC2086 # intentional split; set -f so ids like opus[1m] can't glob-expand
set -f; set -- $trio; set +f
[ $# -eq 3 ] || exit 0
want_w=$2; want_c=$3

[ "$(fm_model "$EXEC_MD")" = "$want_w" ] || fm_set "$EXEC_MD" "$want_w"
[ "$(fm_model "$SCOUT_MD")" = "$want_c" ] || fm_set "$SCOUT_MD" "$want_c"

# Effort is a per-role STATIC default (never derived from the ladder/top),
# maintained here alongside model: for the same reason and gated the same way
# — pinned/off-ladder/unset .model all skip this too, so this hook never
# reaches into the agent files at all under those conditions. Checkers
# (verifier/oracle) are structurally out of reach: this hook only ever opens
# EXEC_MD/SCOUT_MD, never scans the agents directory.
[ "$(fm_effort "$EXEC_MD")" = "medium" ] || fm_effort_set "$EXEC_MD" "medium"
[ "$(fm_effort "$SCOUT_MD")" = "low" ] || fm_effort_set "$SCOUT_MD" "low"
exit 0
