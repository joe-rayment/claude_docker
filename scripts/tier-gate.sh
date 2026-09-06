#!/usr/bin/env bash
#
# tier-gate -- PreToolUse hook (matcher: Agent). See scripts/tier-set.sh's
# header for why this exists (frontmatter rewriting is write-denied inside
# the sandbox -- .claude/plans/orca-port.md S3.1, S3.6). Reads
# .claude-dev/run/tier.json instead of rewriting executor.md/scout.md's
# frontmatter; injects the WORKER model for executor spawns (and generic/
# unnamed spawns), the RECON model for scout spawns, whenever the Agent call
# omits `model` -- an explicit model always wins (also the idempotency
# guard: the injected call re-enters here and passes through, since it now
# carries a model). Named roles other than executor/scout (verifier/oracle/
# professor/bead-auditor) are model:inherit BY DESIGN and are never touched.
#
# tier.json already reflects overdrive/pin (tier-set/tier-reconcile keep it
# current), so this hook never re-derives or re-checks those flags itself --
# it only ever reads .worker/.recon straight off the file.
#
# Fails OPEN everywhere: malformed input, missing jq, no tier.json AND no
# derivable settings .model, off-ladder top -> exit 0, no output.
#
# Env (mainly for tests):
#   TIER_GATE_DISABLE=1     bypass entirely
#   TIER_GATE_STATE_FILE    tier.json to read (default: tier_state_file())
#   TIER_GATE_SETTINGS      settings.json to fall back to when tier.json is
#                           absent (default: claude_config_dir()/settings.json)
#   TIER_GATE_DERIVE        tier-derive to consult (default: sibling script
#                           or tier-derive on PATH)
#   TIER_GATE_GENERIC       space-separated generic type list override

set -u
[ "${TIER_GATE_DISABLE:-}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Resolve through a symlink chain (e.g. bin/tier-gate -> ../scripts/tier-gate.sh)
# to this script's real directory, so lib/paths.sh resolves whether this is
# invoked via the repo copy or the .claude-dev/template/bin/ symlink.
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
# shellcheck source=lib/tier-roles.sh
. "$SCRIPT_DIR/lib/tier-roles.sh"

IN=$(cat 2>/dev/null) || exit 0
[ -n "$IN" ] || exit 0

TOOL=$(printf '%s' "$IN" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
case "$TOOL" in Agent|Task) : ;; *) exit 0 ;; esac   # Task = legacy tool name

# Inside a subagent? Leave it alone (its parent already went through the gate).
TP=$(printf '%s' "$IN" | jq -r '.transcript_path // empty' 2>/dev/null)
case "$TP" in */subagents/*) exit 0 ;; esac

# Explicit model: the orchestrator chose — never override.
MODEL=$(printf '%s' "$IN" | jq -r '.tool_input.model // empty' 2>/dev/null)
[ -n "$MODEL" ] && exit 0

ST=$(printf '%s' "$IN" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)

SLOT=worker   # default: generic/unnamed spawns get the worker tier
case "$ST" in
    executor) SLOT=worker ;;
    scout)    SLOT=recon ;;
    "")       SLOT=worker ;;
    *)
        hit=0
        for g in ${TIER_GATE_GENERIC:-general-purpose claude Explore Plan}; do
            [ "$ST" = "$g" ] && { hit=1; break; }
        done
        [ "$hit" -eq 1 ] || exit 0   # named non-generic role (verifier/oracle/...): leave alone
        SLOT=worker
        ;;
esac

DERIVE="${TIER_GATE_DERIVE:-}"
if [ -z "$DERIVE" ]; then
    DERIVE=$(command -v tier-derive 2>/dev/null) || DERIVE="$SCRIPT_DIR/tier-derive.sh"
fi
[ -x "$DERIVE" ] || exit 0

STATE_FILE="${TIER_GATE_STATE_FILE:-}"
[ -n "$STATE_FILE" ] || STATE_FILE="$(tier_state_file 2>/dev/null)" || STATE_FILE=""

TARGET_ID=""
if [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
    # v2 (claude-orca-qa2.12): the role's BACKEND decides what happens here.
    # A v1 tier.json reads as backend "subagent" (lib/tier-roles.sh), so the
    # injection path below is byte-for-byte what it always was.
    BACKEND=$(tier_role_field "$STATE_FILE" "$SLOT" backend)
    if [ "$BACKEND" = "orca" ]; then
        # Orca-backed role: the spawn is ALLOWED (this hook never blocks) and
        # the orchestrator is told a supervised Orca worker was waiting for
        # it. It is still a WORKER spawn, though, so the invariant "expensive
        # tiers never take the worker seat" holds here too: a claude-agent
        # role injects its own model (or the derived rung, if that model
        # cannot be ranked), so the fallback spawn never silently lands on
        # the orchestrator's tier.
        RM=$(tier_role_field "$STATE_FILE" "$SLOT" model)
        RA=$(tier_role_field "$STATE_FILE" "$SLOT" agent)
        ORCA_NOTE=" ${SLOT} backend is orca (${RA} ${RM}) — prefer orca-dispatch for this slice."
        if [ "$RA" = "claude" ]; then
            TARGET_ID="$RM"
            # An off-ladder/unrankable model (or the bare "inherit") is not
            # injectable: fall back to the rung derived from the bound top.
            if [ "$("$DERIVE" --rank "$TARGET_ID" 2>/dev/null || echo 0)" = "0" ]; then
                TOP_ID=$(jq -r '.top // empty' "$STATE_FILE" 2>/dev/null)
                TRIO=$("$DERIVE" "$TOP_ID" 2>/dev/null) || TRIO=""
                case "$SLOT" in
                    worker) TARGET_ID=$(printf '%s' "$TRIO" | awk '{print $2}') ;;
                    recon)  TARGET_ID=$(printf '%s' "$TRIO" | awk '{print $3}') ;;
                esac
            fi
        else
            # A non-Claude agent (opencode/codex/gemini) has no model the
            # Agent tool would accept, and its rung is not this hook's to
            # guess: note only, no injection.
            jq -cn --arg slot "$SLOT" --arg m "$RM" --arg a "$RA" \
               '{systemMessage: ("tier-gate: " + $slot + " backend is orca (" + $a + " " + $m + ") — prefer orca-dispatch for this slice; the Agent-tool spawn was allowed and runs on the orchestrator'"'"'s own model.")}' \
               2>/dev/null || exit 0
            exit 0
        fi
    else
        TARGET_ID=$(tier_role_field "$STATE_FILE" "$SLOT" model)
    fi
fi

if [ -z "$TARGET_ID" ]; then
    # No tier.json yet (fresh project, /tier never run) -- fall back to
    # deriving straight from settings .model, same as the first /tier run
    # would have recorded.
    SETTINGS="${TIER_GATE_SETTINGS:-$(claude_config_dir)/settings.json}"
    TOP=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
    [ -n "$TOP" ] || exit 0
    TRIO=$("$DERIVE" "$TOP" 2>/dev/null) || exit 0
    case "$SLOT" in
        worker) TARGET_ID=$(printf '%s' "$TRIO" | awk '{print $2}') ;;
        recon)  TARGET_ID=$(printf '%s' "$TRIO" | awk '{print $3}') ;;
    esac
fi
[ -n "$TARGET_ID" ] || exit 0

# The Agent tool's model param accepts FAMILY ALIASES only (sonnet/opus/...),
# not concrete ids — verified live 2026-07-28 (see the old tier-gate.sh this
# supersedes). Map via the ladder's own rank so nothing here is hardcoded.
RANK=$("$DERIVE" --rank "$TARGET_ID" 2>/dev/null) || exit 0
case "$RANK" in
    4) ALIAS=fable ;;
    3) ALIAS=opus ;;
    2) ALIAS=sonnet ;;
    1) ALIAS=haiku ;;
    *) exit 0 ;;   # unrankable target: fail open
esac

printf '%s' "$IN" | jq -c --arg m "$ALIAS" --arg id "$TARGET_ID" --arg slot "$SLOT" --arg note "${ORCA_NOTE:-}" '{
    systemMessage: ("tier-gate:" + $note + " " + $slot + " spawn had no model — injected " + $slot + " tier \($m) (\($id)). An explicit model on the Agent call always wins."),
    hookSpecificOutput: {
        hookEventName: "PreToolUse",
        updatedInput: (.tool_input + {model: $m})
    }
}' 2>/dev/null || exit 0
exit 0
