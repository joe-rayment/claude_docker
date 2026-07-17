#!/bin/sh
# tier-set — bind the model tier (top / worker / recon).
#
# Default (ONE arg): worker and recon are DERIVED as the next two consecutive
# rungs down the ladder from the top — see tier-derive, the single source of
# truth for that derivation. Explicit (TWO or THREE args): you name the
# worker/recon slot(s) yourself, for a shared 2-level config or a fully
# independent 3-level one — see "Usage" below.
#
# This is the engine behind the /tier slash command (and the optional `tier`
# shell wrapper). It writes ~/.claude/settings.json:
#
#   .model                                  = <top id>     (plain-launch orchestrator)
#   .env.ANTHROPIC_DEFAULT_OPUS_MODEL       = <top id>     (reasoning / anything on the `opus` alias)
#   .env.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME  = <top name>   (honest label for the above, see below)
#   .env.ANTHROPIC_DEFAULT_SONNET_MODEL(_NAME) = <worker id/name>  (executor — one rung down)
#   .env.ANTHROPIC_DEFAULT_HAIKU_MODEL(_NAME)  = <recon id/name>   (scout — two rungs down)
#   .env.TIER_EXPLICIT_PIN                  = "1" iff an explicit (2/3-arg) bind is active
#
# and removes .env.CLAUDE_CODE_SUBAGENT_MODEL (it would flatten all tiers onto
# one model). Verifier & oracle use `model: inherit`, so they always track the
# orchestrator — they are never bound separately.
#
# Why the _NAME vars: Claude Code's own /model picker reads the SAME
# ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL vars to build its "Opus" /
# "Sonnet" / "Haiku" menu rows, and each row's label defaults to
# ANTHROPIC_DEFAULT_<ROLE>_MODEL_NAME, falling back to the raw model id when
# unset (confirmed by reading the shipped `claude` binary's own menu-builder,
# e.g. `label: process.env.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME ?? e`). Without
# the _NAME write the menu's "Opus" row silently showed whatever the tier
# system had bound to that slot — a top=fable session mislabeled its rows
# "Opus"->Fable 5, "Sonnet"->Opus 4.8, "Haiku"->Sonnet 5. Setting _NAME makes
# each row display the model it ACTUALLY is, so the picker stays truthful and
# selecting a row writes a value that matches what was shown.
#
# The same slots are kept in sync automatically by tier-reconcile (a
# SessionStart + UserPromptSubmit hook) whenever .model changes via /model —
# unless an explicit (2/3-arg) pin is active, in which case the reconciler
# leaves the pinned slots alone (see tier-reconcile.sh). /model is the primary
# in-session lever for the derived default; /tier is the explicit set.
#
# Usage:
#   tier-set                        # NO ARGS -> print the current binding (same as `show`)
#   tier-set <top>                  # 1 model  -> worker/recon AUTO-DERIVED (consecutive rungs down)
#   tier-set <top> <worker>         # 2 models -> a 2-level config: recon SHARES the worker slot
#   tier-set <top> <worker> <recon> # 3 models -> fully independent 3-level config
#   tier-set show                   # print the current binding
#   TIER_NO_PROBE=1 tier-set ...    # skip availability probing (bind blind)
#
# Ladder: fable > opus > sonnet > haiku.  1-arg default -> (top, top-1, top-2), floored:
#   fable→fable/opus/sonnet · opus→opus/sonnet/haiku · sonnet→sonnet/haiku/haiku · haiku→haiku×3
# A 2- or 3-arg explicit bind is NOT required to be consecutive rungs — any
# combination is accepted (each slot is independently probed/degraded).
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
#   - Each slot degrades DOWNWARD to the first available model (probe = one
#     tiny `claude -p` ping per candidate tried); the 1-arg form derives the
#     trio from whichever top actually bound.
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

name_for() {  # concrete id/alias -> display name, or empty if off-ladder (caller falls back to the raw id)
    "$DERIVE" --name "$1" 2>/dev/null || true
}

if [ $# -eq 0 ] || [ "${1:-}" = "show" ]; then   # no args or `show` -> just print state
    if [ -f "$SETTINGS" ]; then
        cur_model=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
        pinned=$(jq -r '.env.TIER_EXPLICIT_PIN // empty' "$SETTINGS" 2>/dev/null)
        jq -r '"orchestrator (settings model)      = " + (.model // "<harness default>"),
               "reasoning slot (opus alias)        = " + (.env.ANTHROPIC_DEFAULT_OPUS_MODEL // "<unset -> opus default>") + (if .env.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME then "  [\"" + .env.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME + "\" in the /model picker]" else "" end),
               "worker slot / executor             = " + (.env.ANTHROPIC_DEFAULT_SONNET_MODEL // "<unset -> sonnet default>") + (if .env.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME then "  [\"" + .env.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME + "\" in the /model picker]" else "" end),
               "recon slot / scout                 = " + (.env.ANTHROPIC_DEFAULT_HAIKU_MODEL // "<unset -> haiku default>") + (if .env.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME then "  [\"" + .env.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME + "\" in the /model picker]" else "" end)' \
            "$SETTINGS" 2>/dev/null || echo "tier-set: cannot read $SETTINGS" >&2
        if [ "$pinned" = "1" ]; then
            echo "explicit pin: ON — worker/recon were set manually (tier-set <top> <worker> [<recon>]); the reconciler leaves them alone until you run a 1-arg /tier <top> again."
        elif [ -n "$cur_model" ] && [ -x "$DERIVE" ]; then
            if trio=$("$DERIVE" "$cur_model" 2>/dev/null); then
                echo "derived trio for top=$cur_model  = $trio"
            else
                echo "note: top '$cur_model' is OFF-LADDER (custom/unmanaged) — slots are left as-is, not auto-derived"
            fi
        fi
    else
        echo "no settings file at $SETTINGS"
    fi
    echo "1-arg /tier auto-derives worker/recon as the next two rungs down (fable>opus>sonnet>haiku, floored)."
    echo "2/3-arg /tier <top> <worker> [<recon>] pins those slots explicitly (see the header of tier-set.sh)."
    echo "verifier & oracle inherit the orchestrator's model; /model is the primary in-session lever for the derived default."
    echo "worker/recon slots apply in-session (next subagent spawn); the orchestrator moves only via /model."
    exit 0
fi

explicit=0
if [ $# -eq 1 ]; then
    R=$(pick top "$(alias_id "$1")" claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5-20251001) || exit 1
    if trio=$("$DERIVE" "$R" 2>/dev/null); then   # derive worker+recon from the bound top
        # shellcheck disable=SC2086 # trio is three shell-safe ids, intentional split
        set -- $trio
        R=$1; W=$2; C=$3
    else
        # Off-ladder custom top: not derivable — bind it across all three and say so.
        W=$R; C=$R
        echo "tier: top '$R' is off-ladder — worker/recon set to the same model (not derivable)" >&2
    fi
else
    explicit=1
    R=$(pick top    "$(alias_id "$1")" claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5-20251001) || exit 1
    W=$(pick worker "$(alias_id "$2")" claude-sonnet-5 claude-haiku-4-5-20251001) || exit 1
    if [ $# -ge 3 ]; then
        C=$(pick recon "$(alias_id "$3")" claude-haiku-4-5-20251001) || exit 1
        [ $# -gt 3 ] && shift 3 && echo "tier: extra args ignored (dropped: $*)" >&2
    else
        C=$W   # 2-arg form: a 2-level config — recon shares the worker slot
    fi
fi

NR=$(name_for "$R"); NW=$(name_for "$W"); NC=$(name_for "$C")

if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    printf '{}\n' > "$SETTINGS"
fi

orig_mode=$(stat -c %a "$SETTINGS" 2>/dev/null) || orig_mode=644
tmp=$(mktemp "$SETTINGS.XXXXXX") || exit 1
if jq --arg r "$R" --arg w "$W" --arg c "$C" \
      --arg nr "$NR" --arg nw "$NW" --arg nc "$NC" \
      --argjson pin "$([ "$explicit" -eq 1 ] && echo true || echo false)" '
        .model = $r
        | .env = ((.env // {})
                  | .ANTHROPIC_DEFAULT_OPUS_MODEL   = $r
                  | .ANTHROPIC_DEFAULT_SONNET_MODEL = $w
                  | .ANTHROPIC_DEFAULT_HAIKU_MODEL  = $c
                  | (if $nr != "" then .ANTHROPIC_DEFAULT_OPUS_MODEL_NAME   = $nr else del(.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME)   end)
                  | (if $nw != "" then .ANTHROPIC_DEFAULT_SONNET_MODEL_NAME = $nw else del(.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME) end)
                  | (if $nc != "" then .ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME  = $nc else del(.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME)  end)
                  | (if $pin then .TIER_EXPLICIT_PIN = "1" else del(.TIER_EXPLICIT_PIN) end)
                  | del(.CLAUDE_CODE_SUBAGENT_MODEL))
    ' "$SETTINGS" > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
    chmod "$orig_mode" "$tmp" 2>/dev/null
    mv "$tmp" "$SETTINGS"
else
    rm -f "$tmp"
    echo "tier-set: failed to update $SETTINGS (left unchanged — is it valid JSON?)" >&2
    exit 1
fi

if [ "$explicit" -eq 1 ]; then
    echo "tier bound (explicit)  top=$R  worker=$W  recon=$C"
    echo "· pinned — the reconciler will NOT auto-derive over this until you run a 1-arg /tier <top>."
else
    echo "tier bound  top=$R  →  worker=$W  recon=$C  (worker/recon derived from the top)"
fi
echo "· /model picker rows now read: Opus=\"${NR:-$R}\"  Sonnet=\"${NW:-$W}\"  Haiku=\"${NC:-$C}\" (honest labels, not the hardcoded Opus/Sonnet/Haiku names)."
echo "· LIVE in this session: executor=$W and scout=$C — subagents spawned from now on use them"
echo "  (Claude Code re-reads settings.json env on each subagent spawn)."
echo "· NOT moved in this session: the orchestrator (=$R) and inherit agents (verifier/oracle) —"
echo "  a running session's own model changes only via /model. To move it now, run:  /model $R"
echo "  (/model is the primary lever: the reconciler re-derives the trio from .model on your next prompt,"
echo "  unless an explicit pin is active.)"
echo "· NEW sessions get all three; a plain launch uses orchestrator=$R."
