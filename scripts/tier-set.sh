#!/bin/sh
# tier-set — bind the model trio (orchestrator / worker / recon) for NEW sessions.
#
# This is the engine behind the /tier slash command (and the optional `tier`
# shell wrapper). It writes ~/.claude/settings.json:
#
#   .model                              = <reasoning id>  (plain-launch orchestrator)
#   .env.ANTHROPIC_DEFAULT_OPUS_MODEL   = <reasoning id>  (anything on the `opus` alias)
#   .env.ANTHROPIC_DEFAULT_SONNET_MODEL = <worker id>     (executor)
#   .env.ANTHROPIC_DEFAULT_HAIKU_MODEL  = <recon id>      (scout)
#
# and removes .env.CLAUDE_CODE_SUBAGENT_MODEL (it would flatten all tiers onto
# one model). Verifier & oracle use `model: inherit`, so they always track the
# orchestrator — they are never bound separately.
#
# Usage:
#   tier-set [reasoning [worker [recon]]]   # aliases (fable/opus/sonnet/haiku) or full ids
#   tier-set show                           # print the current binding
#   TIER_NO_PROBE=1 tier-set ...            # skip availability probing (bind blind)
#
# Semantics:
#   - Takes effect for NEW sessions. A running session keeps the slots it
#     started with; only /model can move a running orchestrator.
#   - Aliases are mapped to concrete ids BEFORE writing — never write an alias
#     into the env var that defines that alias.
#   - Each slot degrades DOWNWARD to the first available model (probe = one
#     tiny `claude -p` ping per candidate tried) and says so.
#   - Warns if a lower slot outranks the reasoning slot: the orchestrator
#     should be the most capable of the three.
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

rank() {  # capability rank for the orchestrator-is-strongest check
    case "$1" in
        claude-fable-*)  echo 4 ;;
        claude-opus-*)   echo 3 ;;
        claude-sonnet-*) echo 2 ;;
        claude-haiku-*)  echo 1 ;;
        *)               echo 0 ;;   # unknown -> check skipped
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

if [ "${1:-}" = "show" ]; then
    if [ -f "$SETTINGS" ]; then
        jq -r '"orchestrator (settings model)      = " + (.model // "<harness default>"),
               "reasoning slot (opus alias)        = " + (.env.ANTHROPIC_DEFAULT_OPUS_MODEL // "<unset -> opus default>"),
               "worker slot / executor             = " + (.env.ANTHROPIC_DEFAULT_SONNET_MODEL // "<unset -> sonnet default>"),
               "recon slot / scout                 = " + (.env.ANTHROPIC_DEFAULT_HAIKU_MODEL // "<unset -> haiku default>")' \
            "$SETTINGS" 2>/dev/null || echo "tier-set: cannot read $SETTINGS" >&2
    else
        echo "no settings file at $SETTINGS"
    fi
    echo "verifier & oracle inherit the orchestrator's model."
    exit 0
fi

R=$(pick reasoning "$(alias_id "${1:-claude-opus-4-8}")" claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5-20251001) || exit 1
W=$(pick worker    "$(alias_id "${2:-claude-sonnet-5}")" claude-sonnet-5 claude-haiku-4-5-20251001) || exit 1
C=$(pick recon     "$(alias_id "${3:-claude-haiku-4-5-20251001}")" claude-haiku-4-5-20251001 claude-sonnet-5) || exit 1

rr=$(rank "$R"); wr=$(rank "$W"); cr=$(rank "$C")
if [ "$rr" -gt 0 ] && { { [ "$wr" -gt 0 ] && [ "$wr" -gt "$rr" ]; } || \
                        { [ "$cr" -gt 0 ] && [ "$cr" -gt "$rr" ]; }; }; then
    echo "tier warning: a lower slot outranks the reasoning slot — the orchestrator should be the most capable of the three" >&2
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

echo "tier bound  orchestrator=$R  worker=$W  recon=$C"
echo "applies to NEW sessions; the current session keeps its binding (/model moves only the running orchestrator)"
