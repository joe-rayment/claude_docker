#!/bin/sh
# workflow-lint — PreToolUse hook (matcher: Workflow): deny workflow scripts
# whose agent() calls omit an explicit model.
#
# Why here: Workflow's internal agent() spawns run as the built-in
# workflow-subagent type, which has no model binding and inherits the
# main-loop model — the single largest measured misroute on this machine
# (18.1M cache-read tokens at the top tier; bead mi9). Those internal spawns
# are not reliably reachable by an Agent-matched hook, but the SCRIPT is: the
# orchestrator authors it and it arrives in tool_input.script, so the model
# requirement is enforced at the only boundary we own with certainty. A deny
# costs one round trip against the fan-out it guards — the orchestrator
# rewrites the script it wrote one message earlier.
#
# Best-effort BY DESIGN (a guardrail, not a JS parser): a call site passes if
# `model:` appears on the agent( line or within the next 5 lines. Dynamic
# opts objects a line-scan cannot see can be annotated with
#     /* workflow-lint: model-ok */
# on (or just after) the call line to suppress. Saved workflows invoked by
# {name} and unreadable scriptPath files pass through (fail open).
#
# Env (mainly for tests): WORKFLOW_LINT_DISABLE=1 bypasses entirely.

set -u

[ "${WORKFLOW_LINT_DISABLE:-}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

IN=$(cat 2>/dev/null) || exit 0
[ -n "$IN" ] || exit 0

TOOL=$(printf '%s' "$IN" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL" = "Workflow" ] || exit 0

SCRIPT=$(printf '%s' "$IN" | jq -r '.tool_input.script // empty' 2>/dev/null)
if [ -z "$SCRIPT" ]; then
    SP=$(printf '%s' "$IN" | jq -r '.tool_input.scriptPath // empty' 2>/dev/null)
    [ -n "$SP" ] && [ -r "$SP" ] || exit 0   # named/saved workflow or unreadable: fail open
    SCRIPT=$(cat "$SP" 2>/dev/null) || exit 0
fi
[ -n "$SCRIPT" ] || exit 0

OFFENDERS=$(printf '%s\n' "$SCRIPT" | awk '
    { L[NR] = $0 }
    END {
        for (i = 1; i <= NR; i++) {
            if (L[i] !~ /(^|[^A-Za-z0-9_])agent[[:space:]]*\(/) continue
            ok = 0
            for (j = i; j <= i + 5 && j <= NR; j++) {
                if (L[j] ~ /model[[:space:]]*:/) { ok = 1; break }
                if (L[j] ~ /workflow-lint:[[:space:]]*model-ok/) { ok = 1; break }
            }
            if (!ok) printf "  line %d: %s\n", i, substr(L[i], 1, 100)
        }
    }')

[ -n "$OFFENDERS" ] || exit 0

REASON="workflow-lint: every agent() call in a workflow script must set an explicit model, or the spawn inherits the orchestrator's (most expensive) model — the largest measured token leak on this machine. Offending call sites:
$OFFENDERS
Fix: add model: to each call's opts, choosing the cheapest capable tier (recon/mechanical -> the scout tier, implementation -> the worker tier; run tier-derive for the session's concrete ids). If a call's model is genuinely set dynamically, annotate the call line with /* workflow-lint: model-ok */. Then re-issue the Workflow call with the revised script."

jq -cn --arg r "$REASON" '{
    hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
    }
}' 2>/dev/null || exit 0
exit 0
