#!/bin/sh
# tier-set — bind the model tier (top / worker / recon).
#
# MECHANISM (v2 — per-agent frontmatter binding; the env-var remap is RETIRED):
#
#   top    -> settings .model                        (plain-launch orchestrator default)
#   worker -> $AGENTS/executor.md  `model:` line     (concrete id in frontmatter)
#   recon  -> $AGENTS/scout.md     `model:` line     (concrete id in frontmatter)
#
# The previous mechanism remapped ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL.
# That corrupted Claude Code's native /model picker: the picker builds its
# Opus/Sonnet/Haiku rows from those SAME env vars, and selecting a row persists
# the BARE ALIAS ("opus"/"sonnet"/"haiku") into .model — so with slots remapped,
# an alias meant one thing at selection time and another after any slot rewrite,
# and the reconciler re-deriving a trio from the alias NAME (not the slot's
# content) walked the whole trio down the ladder. Observed live 2026-07-17:
# the picker offering only Fable/Sonnet-1M/Haiku, "/model opus" landing on
# Fable and later on Haiku. Frontmatter binding removes the collision at the
# root: the picker and every alias stay NATIVE and honest ("opus" always means
# the Opus family), and the tier binding lives where only subagent definitions
# read it. tier-set and tier-reconcile now PURGE those env vars — plus
# CLAUDE_CODE_SUBAGENT_MODEL, which would flatten all tiers onto one model —
# wherever they find them: all of them are standing footguns now.
#
# Semantics (empirically verified 2026-07-17 on Claude Code 2.1.x):
#   - Agent definitions are SNAPSHOTTED at session start: a mid-session
#     frontmatter edit does NOT change spawns in the already-running session;
#     a fresh session honors it, including a full concrete model id. So
#     worker/recon bindings apply to NEW sessions — the SessionStart
#     tier-reconcile hook guarantees every session is consistent with .model
#     from its first spawn. If the CURRENT session needs a different tier for
#     one spawn, pass an explicit `model` on that Agent call.
#   - The orchestrator (settings .model) and model:-inherit agents
#     (verifier/oracle) move only via /model in a running session — a file
#     write cannot move a running session's own model.
#   - Aliases are resolved to concrete ids before writing, so a binding never
#     drifts with alias defaults.
#   - Probing is OPT-IN for known ladder ids: the four ladder models are
#     trusted and bind instantly (a probe is a real `claude -p` round trip,
#     ~5-10s each — probing all slots made /tier take 15-25s and one transient
#     API blip hard-failed the whole bind). Off-ladder/custom ids are still
#     probed (typo guard), with one retry. TIER_PROBE=1 forces probing of
#     every candidate (downward degradation for gated/off-plan models).
#     A probe failure is NEVER fatal: if no candidate passes, the requested
#     id is bound anyway with a WARNING — it may then fail at spawn time.
#   - A container rebuild resets the agent files and settings from the
#     template; the SessionStart reconciler re-derives from .model, so no
#     manual re-run is needed.
#
# Usage:
#   tier-set                        # NO ARGS -> print the current binding (same as `show`)
#   tier-set <top>                  # 1 model  -> worker/recon AUTO-DERIVED (consecutive rungs down)
#   tier-set <top> <worker>         # 2 models -> a 2-level config: recon SHARES the worker model
#   tier-set <top> <worker> <recon> # 3 models -> fully independent 3-level config
#   tier-set show                   # print the current binding
#   TIER_NO_PROBE=1 tier-set ...    # never probe, even off-ladder ids (bind blind)
#   TIER_PROBE=1 tier-set ...       # probe EVERY candidate (downward degradation)
#
# Ladder: fable > opus > sonnet > haiku.  1-arg default -> (top, top-1, top-2), floored:
#   fable→fable/opus/sonnet · opus→opus/sonnet/haiku · sonnet→sonnet/haiku/haiku · haiku→haiku×3
# A 2- or 3-arg explicit bind is NOT required to be consecutive rungs — any
# combination is accepted (each slot independently probed/degraded). An
# explicit bind sets .env.TIER_EXPLICIT_PIN="1" so the reconciler leaves the
# pinned worker/recon alone; a 1-arg bind clears the pin.
#
# TIER_SETTINGS and TIER_AGENTS_DIR override the paths (used by the test suite).

set -u
SETTINGS="${TIER_SETTINGS:-$HOME/.claude/settings.json}"
AGENTS="${TIER_AGENTS_DIR:-$HOME/.claude/agents}"
EXEC_MD="$AGENTS/executor.md"
SCOUT_MD="$AGENTS/scout.md"

alias_id() {  # alias -> concrete id; unknown strings pass through (full ids)
    case "$1" in
        fable)  echo claude-fable-5 ;;
        opus)   echo claude-opus-4-8 ;;
        sonnet) echo claude-sonnet-5 ;;
        haiku)  echo claude-haiku-4-5-20251001 ;;
        *)      echo "$1" ;;
    esac
}

LADDER_IDS=" claude-fable-5 claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5-20251001 "

should_probe() {  # 0 -> this id gets an availability probe
    [ -n "${TIER_NO_PROBE:-}" ] && return 1
    [ -n "${TIER_PROBE:-}" ] && return 0
    case "$LADDER_IDS" in (*" $1 "*) return 1 ;; esac   # known ladder id: trusted, bind instantly
    return 0
}

probe() {  # 0 if the model looks usable; best-effort
    command -v claude >/dev/null 2>&1 || return 0   # can't probe -> trust the bind
    timeout 30 claude --model "$1" -p 'reply: ok' >/dev/null 2>&1
}

# pick <slot-label> <candidate>... — sets PICKED to the chosen id, degrading
# downward past candidates that fail their probe. NEVER fails: on exhaustion it
# binds the requested id unverified and appends to WARNINGS (a probe failure is
# advisory — a hard exit here bricked the /tier slash command on one API blip).
WARNINGS=""
pick() {
    local slot want seen m
    slot=$1; shift
    want=$1
    seen=" "
    for m in "$@"; do
        case "$seen" in (*" $m "*) continue ;; esac
        seen="$seen$m "
        if ! should_probe "$m" || probe "$m" || probe "$m"; then   # one retry on transient blips
            [ "$m" = "$want" ] || echo "tier[$slot] falling back -> $m" >&2
            PICKED=$m
            return 0
        fi
        echo "tier[$slot] $m unavailable, trying next..." >&2
    done
    WARNINGS="${WARNINGS}WARNING: tier[$slot] no candidate passed the probe — bound '$want' UNVERIFIED (it may fail at spawn time)
"
    PICKED=$want
    return 0
}

# Locate tier-derive whether installed (/usr/local/bin) or run from the repo.
DERIVE=$(command -v tier-derive 2>/dev/null) || DERIVE="$(dirname "$0")/tier-derive.sh"

fm_model() {  # current frontmatter `model:` value of an agent file ('' if none/missing)
    grep -m1 '^model:' "$1" 2>/dev/null | sed 's/^model:[[:space:]]*//'
}

fm_set() {  # fm_set <agent-file> <model-id> — rewrite the frontmatter model: line atomically
    local f id mode tmp
    f=$1; id=$2
    case "$id" in (*[!]a-zA-Z0-9._[-]*|'')   # only safe id chars: sed/YAML injection guard
        echo "tier-set: refusing unsafe model id '$id' — slot NOT bound" >&2
        return 1 ;;
    esac
    if ! grep -q '^model:' "$f" 2>/dev/null; then
        echo "tier-set: $f missing or has no 'model:' line — slot NOT bound" >&2
        return 1
    fi
    mode=$(stat -c %a "$f" 2>/dev/null) || mode=644
    tmp=$(mktemp "$f.XXXXXX") || return 1
    if sed "0,/^model:/s|^model:.*|model: $id|" "$f" > "$tmp"; then
        chmod "$mode" "$tmp" 2>/dev/null
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        return 1
    fi
}

if [ $# -eq 0 ] || [ "${1:-}" = "show" ]; then   # no args or `show` -> just print state
    if [ -f "$SETTINGS" ]; then
        cur_model=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
        pinned=$(jq -r '.env.TIER_EXPLICIT_PIN // empty' "$SETTINGS" 2>/dev/null)
        w=$(fm_model "$EXEC_MD"); c=$(fm_model "$SCOUT_MD")
        echo "orchestrator (settings model)      = ${cur_model:-<harness default>}"
        echo "worker / executor (frontmatter)    = ${w:-<no executor.md>}"
        echo "recon / scout (frontmatter)        = ${c:-<no scout.md>}"
        if [ "$pinned" = "1" ]; then
            echo "explicit pin: ON — worker/recon were set manually (tier-set <top> <worker> [<recon>]); the reconciler leaves them alone until you run a 1-arg /tier <top> again."
        elif [ -n "$cur_model" ] && [ -x "$DERIVE" ]; then
            if trio=$("$DERIVE" "$cur_model" 2>/dev/null); then
                echo "derived trio for top=$cur_model  = $trio"
            else
                echo "note: top '$cur_model' is OFF-LADDER (custom/unmanaged) — worker/recon are left as-is, not auto-derived"
            fi
        fi
        # Flag any leftover picker-corrupting env vars (tier-set/tier-reconcile purge these on their next write)
        if jq -e '(.env // {}) | keys | map(select(test("^ANTHROPIC_DEFAULT_(OPUS|SONNET|HAIKU)_MODEL(_NAME)?$") or . == "CLAUDE_CODE_SUBAGENT_MODEL")) | length > 0' "$SETTINGS" >/dev/null 2>&1; then
            echo "WARNING: legacy ANTHROPIC_DEFAULT_*/CLAUDE_CODE_SUBAGENT_MODEL vars present — they corrupt the native /model picker; run any /tier bind (or wait for the reconciler) to purge them."
        fi
    else
        echo "no settings file at $SETTINGS"
    fi
    echo "1-arg /tier auto-derives worker/recon as the next two rungs down (fable>opus>sonnet>haiku, floored)."
    echo "2/3-arg /tier <top> <worker> [<recon>] pins those bindings explicitly (see the header of tier-set.sh)."
    echo "verifier & oracle inherit the orchestrator's model; /model is the primary in-session lever for the derived default."
    echo "worker/recon bindings apply to NEW sessions (agent files are snapshotted at session start); the orchestrator moves only via /model."
    exit 0
fi

explicit=0
if [ $# -eq 1 ]; then
    pick top "$(alias_id "$1")" claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5-20251001; R=$PICKED
    if trio=$("$DERIVE" "$R" 2>/dev/null); then   # derive worker+recon from the bound top
        # shellcheck disable=SC2086 # intentional split; set -f so ids like opus[1m] can't glob-expand
        set -f; set -- $trio; set +f
        R=$1; W=$2; C=$3
    else
        # Off-ladder custom top: not derivable — bind it across all three and say so.
        W=$R; C=$R
        echo "tier: top '$R' is off-ladder — worker/recon set to the same model (not derivable)" >&2
    fi
else
    explicit=1
    pick top    "$(alias_id "$1")" claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5-20251001; R=$PICKED
    pick worker "$(alias_id "$2")" claude-sonnet-5 claude-haiku-4-5-20251001; W=$PICKED
    if [ $# -ge 3 ]; then
        pick recon "$(alias_id "$3")" claude-haiku-4-5-20251001; C=$PICKED
        [ $# -gt 3 ] && shift 3 && echo "tier: extra args ignored (dropped: $*)" >&2
    else
        C=$W   # 2-arg form: a 2-level config — recon shares the worker model
    fi
fi

if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    printf '{}\n' > "$SETTINGS"
fi

orig_mode=$(stat -c %a "$SETTINGS" 2>/dev/null) || orig_mode=644
tmp=$(mktemp "$SETTINGS.XXXXXX") || exit 1
if jq --arg r "$R" \
      --argjson pin "$([ "$explicit" -eq 1 ] && echo true || echo false)" '
        .model = $r
        | .env = ((.env // {})
                  | (if $pin then .TIER_EXPLICIT_PIN = "1" else del(.TIER_EXPLICIT_PIN) end)
                  | del(.ANTHROPIC_DEFAULT_OPUS_MODEL, .ANTHROPIC_DEFAULT_SONNET_MODEL, .ANTHROPIC_DEFAULT_HAIKU_MODEL,
                        .ANTHROPIC_DEFAULT_OPUS_MODEL_NAME, .ANTHROPIC_DEFAULT_SONNET_MODEL_NAME, .ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME,
                        .CLAUDE_CODE_SUBAGENT_MODEL))
    ' "$SETTINGS" > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
    chmod "$orig_mode" "$tmp" 2>/dev/null
    mv "$tmp" "$SETTINGS"
else
    rm -f "$tmp"
    echo "tier-set: failed to update $SETTINGS (left unchanged — is it valid JSON?)" >&2
    exit 1
fi

bind_fail=0
fm_set "$EXEC_MD" "$W" || bind_fail=1
fm_set "$SCOUT_MD" "$C" || bind_fail=1
if [ "$bind_fail" -eq 1 ]; then
    echo "tier: PARTIAL bind — top=$R written to settings, but a worker/recon slot above FAILED (see stderr); fix the agent file and re-run."
    exit 1
fi

if [ "$explicit" -eq 1 ]; then
    echo "tier bound (explicit, pinned)  top=$R  worker=$W  recon=$C  — a 1-arg /tier <top> clears the pin"
else
    echo "tier bound  top=$R  →  worker=$W  recon=$C  (worker/recon derived from the top)"
fi
[ -n "$WARNINGS" ] && printf '%s' "$WARNINGS"
echo "→ run  /model $R  to move THIS session's model now — new sessions pick everything up automatically."
