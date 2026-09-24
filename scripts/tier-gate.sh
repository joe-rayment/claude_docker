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
# carries a model). An orca-backed role with a NON-Claude agent
# (opencode/codex/gemini) has no model the Agent tool would accept: the
# model-less spawn is DENIED, the reason naming the command the tier wants
# (`recon "<question>"` / `orca-dispatch <bead>`); the deny is never
# throttled. The GRADERS -- verifier and bead-auditor -- take the
# CHECKER rung (roles.checker.model, else `tier-derive --checker <top>`: the
# top capped at opus), so an in-process check runs from a seat that is
# neither the orchestrator's nor the worker's (claude-orca-8a0.2). A checker
# that resolves to "inherit" -- an off-ladder top, or an explicit
# `/tier checker inherit` -- is left untouched, which is what inherit means.
# oracle and professor are consults, not graders: never touched.
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
            *)  dir="$(case "$src" in (*/*) cd "${src%/*}/" ;; esac && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}
SCRIPT_DIR="$(_s="$(_resolve_script_path)"; case "$_s" in (*/*) cd "${_s%/*}/" ;; esac && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/tier-roles.sh
. "$SCRIPT_DIR/lib/tier-roles.sh"

IN=$(cat 2>/dev/null) || exit 0
[ -n "$IN" ] || exit 0

# Once-per-session-per-slot notice throttling. Claude Code surfaces every
# PreToolUse systemMessage as a visible "PreToolUse:Agent says: ..." line;
# repeating the same injection note on every recon/worker/checker spawn in
# a session is noise once the operator has seen it once. This NEVER
# touches updatedInput/the injection itself -- only whether the
# human-facing systemMessage is included. session_id comes off the hook's
# stdin JSON (falls back to "nosession" when absent, same as an unnamed
# session); the marker directory follows the same CLAUDE_CONFIG_DIR
# convention python/delegation_gate.py uses for its own state dir. Fails
# OPEN: an unwritable cache dir means the marker never persists, so the
# notice just keeps printing every call, same as before this existed.
# Every field this hook reads, in one jq call, one per line, then a "."
# so an empty last field survives $(...) dropping trailing newlines.
F=$(printf '%s' "$IN" | jq -r '(.session_id, .tool_name, .transcript_path,
    .tool_input.model, .tool_input.subagent_type
    | (. // "") | tostring | gsub("\n"; " ")), "."' 2>/dev/null) || F=""
SESSION_ID=${F%%$'\n'*}; F=${F#*$'\n'}
TOOL=${F%%$'\n'*}; F=${F#*$'\n'}
TP=${F%%$'\n'*}; F=${F#*$'\n'}
MODEL=${F%%$'\n'*}; F=${F#*$'\n'}
ST=${F%%$'\n'*}
[ -n "$SESSION_ID" ] || SESSION_ID="nosession"
TIER_GATE_NOTICE_DIR="$(claude_config_dir)/cache/tier-gate"

# _tier_gate_announce_once <marker-suffix> -- 0 (announce) the first time a
# given suffix is seen for this session, 1 (stay quiet) every time after.
# Creates the marker right when it decides to announce.
_tier_gate_announce_once() {
    local marker="$TIER_GATE_NOTICE_DIR/$SESSION_ID.$1"
    [ -f "$marker" ] && return 1
    mkdir -p "$TIER_GATE_NOTICE_DIR" 2>/dev/null
    : > "$marker" 2>/dev/null
    return 0
}

case "$TOOL" in Agent|Task) : ;; *) exit 0 ;; esac   # Task = legacy tool name

# Inside a subagent? Leave it alone (its parent already went through the gate).
case "$TP" in */subagents/*) exit 0 ;; esac

# Explicit model: the orchestrator chose — never override.
[ -n "$MODEL" ] && exit 0


SLOT=worker   # default: generic/unnamed spawns get the worker tier
case "$ST" in
    executor) SLOT=worker ;;
    scout)    SLOT=recon ;;
    verifier|bead-auditor) SLOT=checker ;;
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
if [ "$SLOT" = "checker" ]; then
    # The grader's rung. The file's own value wins when it names a model; a
    # bare "inherit" is re-derived from the top ONLY when it was not pinned
    # there on purpose -- that is the v1 read rule (a file written before the
    # checker rung existed), not an operator's explicit `/tier checker
    # inherit`, which stays inherit. Anything that still resolves to inherit,
    # or to nothing at all, means "run the orchestrator's own model": leave
    # the spawn exactly as it came in.
    CK_PINNED=false
    if [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
        TARGET_ID=$(tier_role_field "$STATE_FILE" checker model)
        CK_PINNED=$(tier_role_field "$STATE_FILE" checker pinned)
    fi
    if [ -z "$TARGET_ID" ] || { [ "$TARGET_ID" = "inherit" ] && [ "$CK_PINNED" != "true" ]; }; then
        TOP_ID=""
        if [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
            TOP_ID=$(jq -r '.top // empty' "$STATE_FILE" 2>/dev/null)
        fi
        if [ -z "$TOP_ID" ]; then
            SETTINGS="${TIER_GATE_SETTINGS:-$(claude_config_dir)/settings.json}"
            [ -f "$SETTINGS" ] && TOP_ID=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
        fi
        [ -n "$TOP_ID" ] || exit 0
        TARGET_ID=$("$DERIVE" --checker "$TOP_ID" 2>/dev/null) || TARGET_ID=""
    fi
    [ -n "$TARGET_ID" ] || exit 0
    [ "$TARGET_ID" = "inherit" ] && exit 0
elif [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
    # v2 (claude-orca-qa2.12): the role's BACKEND decides what happens here.
    # A v1 tier.json reads as backend "subagent" (lib/tier-roles.sh), so the
    # injection path below is byte-for-byte what it always was.
    BACKEND=$(tier_role_field "$STATE_FILE" "$SLOT" backend)
    if [ "$BACKEND" = "orca" ]; then
        # Orca-backed role: a claude-agent role injects its own model (or
        # the derived rung, if that model cannot be ranked), so the fallback
        # spawn never silently lands on the orchestrator's tier. A
        # non-Claude agent has no model the Agent tool would accept: the
        # model-less spawn is DENIED (claude-orca-424.2), the reason naming
        # the command the tier wants -- an explicit model on the call never
        # reaches this branch and stays the deliberate in-process fallback.
        RM=$(tier_role_field "$STATE_FILE" "$SLOT" model)
        RA=$(tier_role_field "$STATE_FILE" "$SLOT" agent)
        RV=$(tier_role_field "$STATE_FILE" "$SLOT" variant)
        RM_LABEL="$RM"
        [ -n "$RV" ] && RM_LABEL="${RM}@${RV}"
        ORCA_NOTE=" ${SLOT} backend is orca (${RA} ${RM_LABEL}) — prefer orca-dispatch for this slice."
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
            # guess: the tier is what the operator set, so the model-less
            # spawn is DENIED with the reason naming the exact command the
            # tier wants (claude-orca-424.2). The deny is never throttled --
            # its reason rides on every call; only the injection notice
            # below is once-per-session.
            case "$SLOT" in
                recon) REASON=$(printf 'tier-gate: recon backend is orca (%s %s) -- run `recon "<question>"` in Bash (several in one message, run_in_background, to fan out) instead of an in-process scout; an explicit model on the Agent call (model: haiku) is the deliberate in-process fallback when the recon backend is down.' "$RA" "$RM_LABEL") ;;
                *)     REASON=$(printf 'tier-gate: worker backend is orca (%s %s) -- dispatch the slice with `orca-dispatch <bead>` instead of an in-process executor; an explicit model on the Agent call is the deliberate in-process fallback when Orca is unreachable (orca-dispatch exits 3 and prints the spec).' "$RA" "$RM_LABEL") ;;
            esac
            jq -cn --arg r "$REASON" '{
                hookSpecificOutput: {
                    hookEventName: "PreToolUse",
                    permissionDecision: "deny",
                    permissionDecisionReason: $r
                }
            }' 2>/dev/null || exit 0
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
    TOP=""
    [ -f "$SETTINGS" ] && TOP=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
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

# The injection (updatedInput) happens on every call, unconditionally;
# only the human-facing systemMessage is throttled to once per session
# per slot.
ANNOUNCE=false
_tier_gate_announce_once "$SLOT" && ANNOUNCE=true

printf '%s' "$IN" | jq -c --arg m "$ALIAS" --arg id "$TARGET_ID" --arg slot "$SLOT" --arg note "${ORCA_NOTE:-}" --argjson announce "$ANNOUNCE" '
{
    hookSpecificOutput: {
        hookEventName: "PreToolUse",
        updatedInput: (.tool_input + {model: $m})
    }
} + (if $announce then {
    systemMessage: ("tier-gate:" + $note + " " + $slot + " spawn had no model — injected " + $slot + " tier \($m) (\($id)). An explicit model on the Agent call always wins.")
} else {} end)
' 2>/dev/null || exit 0
exit 0
