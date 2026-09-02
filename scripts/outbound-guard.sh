#!/usr/bin/env bash
# outbound-guard — mechanically enforces "push and deploy are the user's
# actions" (config/claude-user-memory.md), the same pattern as bd-guard: one
# hook, one sentence of prose, instead of a paragraph the prior alone keeps
# failing to hold (beads_claude_docker-y2qe).
#
# Two modes, two hook events:
#
#   PreToolUse (matcher Bash; hook JSON on stdin)
#     - deny any command containing a bare `snow` or `snowsql` invocation
#       (word-boundary, anywhere in the line, including after &&/;/|) —
#       unconditional, no override: no Snowflake credentials exist here and
#       never will.
#     - deny `git push`, `gh pr create`, `gh repo create`, `bd dolt push`
#       unless a per-session marker says the CURRENT prompt asked for it.
#
#   outbound-guard --prompt (UserPromptSubmit; hook JSON on stdin)
#     - sets the marker for session_id when the prompt's own wording asks
#       for a push/publish/PR (case-insensitive); clears it otherwise. This
#       is the ONLY place the marker is written, so a prompt that doesn't
#       ask for a push clears any marker a PRIOR prompt in the same session
#       left set — "push only when asked, in that moment," never a standing
#       grant.
#
# State: one flag file per session under $OUTBOUND_GUARD_STATE_DIR (default
# $HOME/.claude/cache/outbound-guard), named <sanitized-session-id>.push —
# presence means "this prompt asked for a push"; same sanitize/state-dir
# pattern as scripts/lane.sh.
#
# Word-boundary matching deliberately avoids GNU grep's `\b` extension (same
# reasoning as scripts/bd-guard.sh's own header comment: explicit character
# classes keep behavior stable) — a match requires the token to be flanked
# by start/end-of-string or a non `[A-Za-z0-9_-]` character, so `snow` does
# NOT fire inside `snowflake-cli` or `snowflake-snowpark-python` (the next
# character is a letter, not a boundary), only for a genuinely standalone
# `snow`/`snowsql` token.
#
# Deny output follows scripts/workflow-lint.sh's hookSpecificOutput shape
# (permissionDecision: "deny" + permissionDecisionReason), not bd-guard.sh's
# older exit-2/stderr contract — this hook always exits 0; the JSON itself
# is what blocks.
#
# MUST fail open, like every hook here: malformed/empty stdin, a payload
# with no session_id, or a non-Bash tool all exit 0 with no output. jq is a
# hard dependency of this image (Dockerfile-installed unconditionally); its
# absence still fails open rather than erroring.

set -u

command -v jq >/dev/null 2>&1 || exit 0

STATE_DIR="${OUTBOUND_GUARD_STATE_DIR:-${HOME:-}/.claude/cache/outbound-guard}"

# Word-boundary alternation for a standalone snow/snowsql CLI invocation.
# Longer alternative first is not required for correctness (see header
# comment: the immediate-right-boundary check already keeps the two
# alternatives mutually exclusive at any given position), but is kept for
# readability.
SNOW_RE='(^|[^A-Za-z0-9_-])(snowsql|snow)([^A-Za-z0-9_-]|$)'

# git push / gh pr create / gh repo create / bd dolt push, same boundary style.
PUSH_RE='(^|[^A-Za-z0-9_-])(git[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+create|gh[[:space:]]+repo[[:space:]]+create|bd[[:space:]]+dolt[[:space:]]+push)([^A-Za-z0-9_-]|$)'

# Push/publish/pull-request wording a prompt uses to ask for an outbound
# action, case-insensitive. Deliberately narrow phrases, not a bare
# "publish"/"push" substring check inside unrelated words (see the
# individual alternatives — each is itself a real word/phrase).
PROMPT_RE='(push|publish|pull[[:space:]]+request|open[[:space:]]+a[[:space:]]+pr|create[[:space:]]+a[[:space:]]+pr)'

sanitize_id() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9._-'
}

marker_file() {
    printf '%s/%s.push' "$STATE_DIR" "$1"
}

# deny <reason> — emit the PreToolUse hookSpecificOutput deny JSON and exit.
# Always exits 0: the JSON payload is what blocks the tool call, not the
# process exit code (matches scripts/workflow-lint.sh / scripts/tier-gate.sh,
# not scripts/bd-guard.sh's older exit-2 contract). A jq construction
# failure still fails open rather than leaving the hook non-zero.
deny() {
    jq -cn --arg r "$1" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $r
        }
    }' 2>/dev/null || true
    exit 0
}

# ── --prompt (UserPromptSubmit hook; JSON on stdin) ─────────────────────────

if [ "${1:-}" = "--prompt" ]; then
    [ -t 0 ] && exit 0
    payload=$(cat 2>/dev/null) || exit 0
    [ -n "$payload" ] || exit 0

    has_sid=$(printf '%s' "$payload" | jq -r 'has("session_id")' 2>/dev/null) || exit 0
    [ "$has_sid" = "true" ] || exit 0
    sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
    sid=$(sanitize_id "$sid")
    [ -n "$sid" ] || exit 0

    prompt=$(printf '%s' "$payload" | jq -r 'if has("prompt") then (.prompt // "") else "" end' 2>/dev/null) || exit 0

    mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
    f=$(marker_file "$sid")
    if printf '%s' "$prompt" | grep -qiE "$PROMPT_RE"; then
        printf '1\n' > "$f" 2>/dev/null
    else
        rm -f "$f" 2>/dev/null
    fi
    exit 0
fi

# ── PreToolUse (matcher Bash; JSON on stdin) ────────────────────────────────

[ -t 0 ] && exit 0
payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Fail open on a payload with no session_id at all — same posture as every
# other malformed/incomplete-input case below, applied up front so a
# corrupted payload chain can never brick a session's Bash calls.
has_sid=$(printf '%s' "$payload" | jq -r 'has("session_id")' 2>/dev/null) || exit 0
[ "$has_sid" = "true" ] || exit 0
sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
sid=$(sanitize_id "$sid")
[ -n "$sid" ] || exit 0

tool_name=$(printf '%s' "$payload" | jq -r 'if has("tool_name") then .tool_name else empty end' 2>/dev/null) || exit 0
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command? // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Fold tabs to spaces so a tab between tokens can't hide a match (same
# defensive step scripts/bd-guard.sh takes before its own rules run).
cmd_norm=$(printf '%s' "$cmd" | tr '\t' ' ')

if printf '%s' "$cmd_norm" | grep -Eq "$SNOW_RE"; then
    deny "outbound-guard: no Snowflake access from this container — never install or run snow/snowsql; mock Snowflake and run everything else locally."
fi

if printf '%s' "$cmd_norm" | grep -Eq "$PUSH_RE"; then
    if [ ! -f "$(marker_file "$sid")" ]; then
        deny "outbound-guard: push/deploy is opt-in — the prompt has to ask for it; commit locally instead."
    fi
fi

exit 0
