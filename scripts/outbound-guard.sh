#!/usr/bin/env bash
# outbound-guard — mechanically enforces "push and deploy are the user's
# actions" (config/claude-user-memory.md), the same pattern as bd-guard: one
# hook, one sentence of prose, instead of a paragraph the prior alone keeps
# failing to hold (beads_claude_docker-y2qe).
#
# Two modes, two hook events:
#
#   PreToolUse (matcher Bash; hook JSON on stdin)
#     - deny any command containing a bare `sno` + `w`/`sno` + `wsql`
#       invocation, or a `sno` + `wflake.cli` module invocation
#       (`python -m sno` + `wflake.cli …`, `python3 -m sno` + `wflake.cli
#       …`, or the dotted module path appearing any other way) —
#       word-boundary, anywhere in the line, including after &&/;/|.
#       Evaluated BEFORE the session_id gate below and therefore truly
#       unconditional: it fires for any valid-JSON payload naming
#       tool_name "Bash" with a command, session_id or not. No override: no
#       Snowflake credentials exist here and never will.
#     - deny `git push`, `gh pr create`, `gh repo create`, `bd dolt push`
#       unless a per-session marker says the CURRENT prompt asked for it —
#       this rule alone needs a session_id (to look up the marker), so a
#       payload missing one fails OPEN for a push command specifically,
#       same as every other incomplete-payload case.
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
# the config dir's cache/outbound-guard -- see lib/paths.sh's
# claude_config_dir()), named <sanitized-session-id>.push -- presence means
# "this prompt asked for a push"; same sanitize/state-dir pattern as
# scripts/lane.sh.
#
# Word-boundary matching deliberately avoids GNU grep's `\b` extension (same
# reasoning as scripts/bd-guard.sh's own header comment: explicit character
# classes keep behavior stable) — a match requires the token to be flanked
# by start/end-of-string or a non `[A-Za-z0-9_-]` character, so the vendor
# name does NOT fire inside its "-cli" or "-snowpark-python" packaged forms
# (the next character is a letter, not a boundary), only for a genuinely
# standalone CLI-name token. The module-form check (SNOW_MODULE_RE) reuses
# the same boundary style around the literal dotted path for that vendor's
# `cli` module — that exact substring (a literal `.`, not `-`) never
# appears in the allowed hyphenated package names (`*-cli`,
# `*-snowpark-python`, `*-connector-python`), so no interpreter/`-m`-specific
# grammar is needed to keep those allowed while still catching `python -m
# <vendor>.cli`/`python3 -m <vendor>.cli`/any other way that dotted path
# shows up on the line.
#
# Deny output follows scripts/workflow-lint.sh's hookSpecificOutput shape
# (permissionDecision: "deny" + permissionDecisionReason), not bd-guard.sh's
# older exit-2/stderr contract — this hook always exits 0; the JSON itself
# is what blocks.
#
# MUST fail open, like every hook here: malformed/empty stdin or a non-Bash
# tool all exit 0 with no output. A payload with no session_id fails open
# too, but ONLY for the push/marker rule (which needs a session_id to look
# up its marker) — the vendor-CLI deny is evaluated first and does not
# depend on session_id at all. jq is a hard dependency of this template;
# its absence still fails open rather than erroring.

set -u

# Resolve through a symlink chain (e.g. bin/outbound-guard -> ../scripts/
# outbound-guard.sh) to this script's real directory, so lib/paths.sh
# resolves whether this is invoked via the repo copy or the
# .claude-dev/template/bin/ symlink.
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

command -v jq >/dev/null 2>&1 || exit 0

STATE_DIR="${OUTBOUND_GUARD_STATE_DIR:-$(claude_config_dir)/cache/outbound-guard}"

# Word-boundary alternation for a standalone vendor-CLI invocation (built
# from two halves so this file's own source never spells the full token —
# see the header comment on why that matters for a Bash-command guard
# scanning its own source during the port).
_sno='sno'
SNOW_RE='(^|[^A-Za-z0-9_-])('"${_sno}"'wsql|'"${_sno}"'w)([^A-Za-z0-9_-]|$)'

# vendor.cli module invocation (python -m vendor.cli, python3 -m
# vendor.cli, or the dotted path appearing any other way) — see the header
# comment for why matching the literal dotted substring is enough on its
# own, without modeling `-m`/interpreter names.
SNOW_MODULE_RE='(^|[^A-Za-z0-9_-])'"${_sno}"'wflake\.cli([^A-Za-z0-9_-]|$)'

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

tool_name=$(printf '%s' "$payload" | jq -r 'if has("tool_name") then .tool_name else empty end' 2>/dev/null) || exit 0
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command? // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Fold tabs to spaces so a tab between tokens can't hide a match (same
# defensive step scripts/bd-guard.sh takes before its own rules run).
cmd_norm=$(printf '%s' "$cmd" | tr '\t' ' ')

# vendor-CLI/module: unconditional — evaluated before the session_id gate
# below, so it fires regardless of whether this payload carries a
# session_id. No override, no marker involved.
if printf '%s' "$cmd_norm" | grep -Eq "$SNOW_RE" || printf '%s' "$cmd_norm" | grep -Eq "$SNOW_MODULE_RE"; then
    deny "outbound-guard: no Snowflake access from this sandbox — never install or run its CLI; mock Snowflake and run everything else locally."
fi

# Everything past this point (push/deploy) needs a session_id to look up
# its marker — fail open on a payload missing one, same posture as every
# other incomplete-input case, but scoped to this rule only.
has_sid=$(printf '%s' "$payload" | jq -r 'has("session_id")' 2>/dev/null) || exit 0
[ "$has_sid" = "true" ] || exit 0
sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
sid=$(sanitize_id "$sid")
[ -n "$sid" ] || exit 0

if printf '%s' "$cmd_norm" | grep -Eq "$PUSH_RE"; then
    if [ ! -f "$(marker_file "$sid")" ]; then
        deny "outbound-guard: push/deploy is opt-in — the prompt has to ask for it; commit locally instead."
    fi
fi

exit 0
