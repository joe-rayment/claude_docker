#!/bin/sh
# tier-gate — PreToolUse hook (matcher: Agent): default-cheap model for generic
# subagent spawns.
#
# Principle: enforce the DEFAULT, never the CHOICE (bd memory
# enforce-default-not-choice). The orchestrator's judgement is untouched — an
# explicit `model` on the Agent call always wins, on any agent type. What this
# hook redirects is SILENCE: a spawn with no model and a generic subagent_type
# would inherit the orchestrator's (most expensive) model; instead it gets the
# tier ladder's WORKER model, with a systemMessage so nothing happens silently.
# Measured motivation: 31.5M cache-read tokens of recon billed at the top tier
# via exactly these generic spawns (bead c2r, 2026-07-28).
#
# Scope:
#   - Generic types only: subagent_type absent/empty or one of
#     $TIER_GATE_GENERIC (default: general-purpose claude Explore Plan).
#   - Named roles are never touched — scout/executor carry tier-set
#     frontmatter; verifier/oracle are model:inherit BY DESIGN (a checker must
#     not be weaker than the claims it checks).
#   - The injected model comes from tier-derive's worker slot AT RUNTIME —
#     never hardcoded — so this gate can never disagree with /tier.
#
# Failure posture: fail OPEN everywhere (malformed input, missing jq/derive,
# off-ladder top → exit 0, no output). Idempotent: an injected call re-enters
# with model set and passes through. Spawns made INSIDE a subagent are left
# alone (best-effort child detection via the transcript path).
#
# Env (mainly for tests):
#   TIER_GATE_DISABLE=1    bypass entirely
#   TIER_GATE_SETTINGS     settings.json to read .model from (default ~/.claude/settings.json)
#   TIER_GATE_DERIVE       tier-derive to consult (default: from PATH)
#   TIER_GATE_GENERIC      space-separated generic type list override

set -u

[ "${TIER_GATE_DISABLE:-}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

IN=$(cat 2>/dev/null) || exit 0
[ -n "$IN" ] || exit 0

TOOL=$(printf '%s' "$IN" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
case "$TOOL" in Agent|Task) : ;; *) exit 0 ;; esac   # Task = legacy tool name

# Inside a subagent? Leave it alone (its parent already went through the gate).
TP=$(printf '%s' "$IN" | jq -r '.transcript_path // empty' 2>/dev/null)
case "$TP" in */subagents/*) exit 0 ;; esac

# Explicit model: the orchestrator chose — never override (also the
# idempotency guard: our own injection re-enters here and passes through).
MODEL=$(printf '%s' "$IN" | jq -r '.tool_input.model // empty' 2>/dev/null)
[ -n "$MODEL" ] && exit 0

# Named role: its frontmatter/inherit binding governs; only generics default.
ST=$(printf '%s' "$IN" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)
if [ -n "$ST" ]; then
    hit=0
    for g in ${TIER_GATE_GENERIC:-general-purpose claude Explore Plan}; do
        [ "$ST" = "$g" ] && { hit=1; break; }
    done
    [ "$hit" -eq 1 ] || exit 0
fi

# Worker tier from the live ladder: tier-derive(.model), field 2.
SETTINGS="${TIER_GATE_SETTINGS:-$HOME/.claude/settings.json}"
TOP=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
[ -n "$TOP" ] || exit 0
DERIVE="${TIER_GATE_DERIVE:-}"
if [ -z "$DERIVE" ]; then
    DERIVE=$(command -v tier-derive 2>/dev/null) || exit 0
fi
[ -x "$DERIVE" ] || exit 0
TRIO=$("$DERIVE" "$TOP" 2>/dev/null) || exit 0   # off-ladder top: fail open
WORKER=$(printf '%s' "$TRIO" | awk '{print $2}')
[ -n "$WORKER" ] || exit 0

# The Agent tool's model param accepts FAMILY ALIASES only (sonnet/opus/...),
# not concrete ids — verified live 2026-07-28: injecting claude-sonnet-5
# failed the tool's input validation. Map the worker id to its alias via the
# ladder's own rank (still runtime-derived, nothing hardcoded).
RANK=$("$DERIVE" --rank "$WORKER" 2>/dev/null) || exit 0
case "$RANK" in
    4) ALIAS=fable ;;
    3) ALIAS=opus ;;
    2) ALIAS=sonnet ;;
    1) ALIAS=haiku ;;
    *) exit 0 ;;   # unrankable worker: fail open
esac

printf '%s' "$IN" | jq -c --arg m "$ALIAS" --arg id "$WORKER" '{
    systemMessage: ("tier-gate: generic subagent spawn had no model — injected worker tier \($m) (\($id)). An explicit model on the Agent call always wins."),
    hookSpecificOutput: {
        hookEventName: "PreToolUse",
        updatedInput: (.tool_input + {model: $m})
    }
}' 2>/dev/null || exit 0
exit 0
