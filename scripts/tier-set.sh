#!/bin/sh
# tier-set — bind the model tier from a single TOP model.
#
# The trio is a pure function of the top model: worker and recon are the next
# two consecutive rungs down the ladder (clamped at haiku), derived by
# tier-derive — the single source of truth. You pick ONE model; the other two
# follow. The worker & recon slots go live in the CURRENT session (next
# subagent spawn); the orchestrator's own model moves only via /model.
#
# This is the engine behind the /tier slash command (and the optional `tier`
# shell wrapper). It writes ~/.claude/settings.json:
#
#   .model                              = <top id>     (plain-launch orchestrator)
#   .env.ANTHROPIC_DEFAULT_OPUS_MODEL   = <top id>     (reasoning / anything on the `opus` alias)
#   .env.ANTHROPIC_DEFAULT_SONNET_MODEL = <worker id>  (executor — one rung down)
#   .env.ANTHROPIC_DEFAULT_HAIKU_MODEL  = <recon id>   (scout — two rungs down)
#
# and removes .env.CLAUDE_CODE_SUBAGENT_MODEL (it would flatten all tiers onto
# one model). Verifier & oracle use `model: inherit`, so they always track the
# orchestrator — they are never bound separately.
#
# The same slots are kept in sync automatically by tier-reconcile (a
# SessionStart + UserPromptSubmit hook) whenever .model changes via /model, so
# /model is the primary in-session lever and /tier is the explicit set.
#
# Usage:
#   tier-set                     # NO ARGS -> print the current binding (same as `show`)
#   tier-set <top>               # bind the tier from one model (alias or full id)
#   tier-set show                # print the current binding
#   TIER_NO_PROBE=1 tier-set ... # skip availability probing (bind blind)
#
# Ladder: fable > opus > sonnet > haiku.  top → (top, top-1, top-2), floored:
#   fable→fable/opus/sonnet · opus→opus/sonnet/haiku · sonnet→sonnet/haiku/haiku · haiku→haiku×3
# Extra positional args are IGNORED with a notice — the trio is auto-derived
# now, so `tier-set opus sonnet` binds the opus tier and tells you so.
#
# Semantics:
#   - Worker (executor) and recon (scout) slots take effect in the CURRENT
#     session, not just new ones: Claude Code re-reads settings.json env when
#     it spawns a subagent, so subagents spawned after this runs use the new
#     slots. (Verified empirically on Claude Code 2.1.206 — the docs imply a
#     launch-time snapshot, but observed behaviour is a per-spawn re-read.)
#   - The orchestrator (settings .model) and model:inherit agents
#     (verifier/oracle) are NOT moved in a running session — a file write
#     can't move a running session's own model; only /model does. All three
#     slots apply to any newly launched session.
#   - Aliases are mapped to concrete ids BEFORE writing — never write an alias
#     into the env var that defines that alias.
#   - The top degrades DOWNWARD to the first available model (probe = one tiny
#     `claude -p` ping per candidate tried); the trio is then derived from the
#     top that actually bound.
#   - A container rebuild resets settings.json from the template — re-run
#     /tier (or tier-set) afterwards.
#
# TIER_SETTINGS overrides the settings path (used by the test suite).

set -u
SETTINGS="${TIER_SETTINGS:-$HOME/.claude/settings.json}"

alias_id() {  # alias -> concrete id; unknown strings pass through (full ids)
    case "$1" in
        fable)  echo claude-fable-5 ;;
        opus)   echo claude-opus-4-8 ;;
        sonnet) echo claude-sonnet-5 ;;
        haiku)  echo claude-haiku-4-5-20251001 ;;
        *)      echo "$1" ;;
    esac
}

probe() {  # 0 if the model looks usable; best-effort
    [ -n "${TIER_NO_PROBE:-}" ] && return 0
    command -v claude >/dev/null 2>&1 || return 0   # can't probe -> trust the bind
    timeout 30 claude --model "$1" -p 'reply: ok' >/dev/null 2>&1
}

pick() {  # pick <slot-label> <candidate>... -> echoes first usable, degrading downward
    local slot want seen m
    slot=$1; shift
    want=$1
    seen=" "
    for m in "$@"; do
        case "$seen" in (*" $m "*) continue ;; esac
        seen="$seen$m "
        if probe "$m"; then
            [ "$m" = "$want" ] || echo "tier[$slot] falling back -> $m" >&2
            echo "$m"
            return 0
        fi
        echo "tier[$slot] $m unavailable, trying next..." >&2
    done
    echo "tier[$slot] no candidate available" >&2
    return 1
}

# Locate tier-derive whether installed (/usr/local/bin) or run from the repo.
DERIVE=$(command -v tier-derive 2>/dev/null) || DERIVE="$(dirname "$0")/tier-derive.sh"

if [ $# -eq 0 ] || [ "${1:-}" = "show" ]; then   # no args or `show` -> just print state
    if [ -f "$SETTINGS" ]; then
        cur_model=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
        jq -r '"orchestrator (settings model)      = " + (.model // "<harness default>"),
               "reasoning slot (opus alias)        = " + (.env.ANTHROPIC_DEFAULT_OPUS_MODEL // "<unset -> opus default>"),
               "worker slot / executor             = " + (.env.ANTHROPIC_DEFAULT_SONNET_MODEL // "<unset -> sonnet default>"),
               "recon slot / scout                 = " + (.env.ANTHROPIC_DEFAULT_HAIKU_MODEL // "<unset -> haiku default>")' \
            "$SETTINGS" 2>/dev/null || echo "tier-set: cannot read $SETTINGS" >&2
        if [ -n "$cur_model" ] && [ -x "$DERIVE" ]; then
            if trio=$("$DERIVE" "$cur_model" 2>/dev/null); then
                echo "derived trio for top=$cur_model  = $trio"
            else
                echo "note: top '$cur_model' is OFF-LADDER (custom/unmanaged) — slots are left as-is, not auto-derived"
            fi
        fi
    else
        echo "no settings file at $SETTINGS"
    fi
    echo "trio is auto-derived from the top: worker/recon = the next two rungs down (fable>opus>sonnet>haiku, floored)."
    echo "verifier & oracle inherit the orchestrator's model; /model is the primary in-session lever (the reconciler keeps the trio linked)."
    echo "worker/recon slots apply in-session (next subagent spawn); the orchestrator moves only via /model."
    exit 0
fi

# Only the TOP model is user-chosen now; worker+recon are DERIVED from it.
TOP_ARG=$1
if [ $# -gt 1 ]; then
    shift
    echo "tier: extra args ignored — the trio is auto-derived from the top now (dropped: $*)" >&2
fi

R=$(pick top "$(alias_id "$TOP_ARG")" claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5-20251001) || exit 1
if trio=$("$DERIVE" "$R" 2>/dev/null); then   # derive worker+recon from the bound top
    # shellcheck disable=SC2086 # trio is three shell-safe ids, intentional split
    set -- $trio
    R=$1; W=$2; C=$3
else
    # Off-ladder custom top: not derivable — bind it across all three and say so.
    W=$R; C=$R
    echo "tier: top '$R' is off-ladder — worker/recon set to the same model (not derivable)" >&2
fi

if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    printf '{}\n' > "$SETTINGS"
fi

orig_mode=$(stat -c %a "$SETTINGS" 2>/dev/null) || orig_mode=644
tmp=$(mktemp "$SETTINGS.XXXXXX") || exit 1
if jq --arg r "$R" --arg w "$W" --arg c "$C" '
        .model = $r
        | .env = ((.env // {})
                  | .ANTHROPIC_DEFAULT_OPUS_MODEL   = $r
                  | .ANTHROPIC_DEFAULT_SONNET_MODEL = $w
                  | .ANTHROPIC_DEFAULT_HAIKU_MODEL  = $c
                  | del(.CLAUDE_CODE_SUBAGENT_MODEL))
    ' "$SETTINGS" > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
    chmod "$orig_mode" "$tmp" 2>/dev/null
    mv "$tmp" "$SETTINGS"
else
    rm -f "$tmp"
    echo "tier-set: failed to update $SETTINGS (left unchanged — is it valid JSON?)" >&2
    exit 1
fi

echo "tier bound  top=$R  →  worker=$W  recon=$C  (worker/recon derived from the top)"
echo "· LIVE in this session: executor=$W and scout=$C — subagents spawned from now on use them"
echo "  (Claude Code re-reads settings.json env on each subagent spawn)."
echo "· NOT moved in this session: the orchestrator (=$R) and inherit agents (verifier/oracle) —"
echo "  a running session's own model changes only via /model. To move it now, run:  /model $R"
echo "  (/model is the primary lever: the reconciler re-derives the trio from .model on your next prompt.)"
echo "· NEW sessions get all three; a plain launch uses orchestrator=$R."
