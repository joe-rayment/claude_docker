# hook.sh -- what the PreToolUse guards print. Sourced, never run; needs jq.

# hook_deny <reason>: print Claude Code's PreToolUse deny decision. The
# caller exits 0 afterwards -- the JSON blocks the call, not the exit code.
hook_deny() {
    jq -cn --arg r "$1" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $r
        }
    }' 2>/dev/null || true
}
