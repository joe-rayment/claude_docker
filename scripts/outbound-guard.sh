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
#     - deny `git push` unless there is a live GitHub connection (`gh auth
#       status` exits 0, within OUTBOUND_GUARD_GH_TIMEOUT seconds, default
#       10) — connected -> allow; gh absent, not connected, or the check
#       timing out -> deny. This check runs ONLY when the command matches
#       `git push`, so an ordinary Bash call never pays for the ~0.4s `gh`
#       invocation, and it needs no session_id at all: there's no marker
#       to look up for this verb any more.
#     - deny `gh pr create`, `gh repo create`, `bd dolt push` unless a
#       per-session marker says the CURRENT prompt asked for it — this
#       rule alone needs a session_id (to look up the marker), so a
#       payload missing one fails OPEN for these commands specifically,
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
# for the marker-gated verbs (gh pr create, gh repo create, bd dolt push),
# which need one to look up their marker — the vendor-CLI deny and the git
# push connection check are evaluated first and need no session_id at all.
# jq is a hard dependency of this template; its absence still fails open
# rather than erroring.

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

# git push -- gated on a live GitHub connection, not the marker below.
GIT_PUSH_RE='(^|[^A-Za-z0-9_-])git[[:space:]]+push([^A-Za-z0-9_-]|$)'

# gh pr create / gh repo create / bd dolt push -- still marker-gated, same
# boundary style as GIT_PUSH_RE above.
MARKER_RE='(^|[^A-Za-z0-9_-])(gh[[:space:]]+pr[[:space:]]+create|gh[[:space:]]+repo[[:space:]]+create|bd[[:space:]]+dolt[[:space:]]+push)([^A-Za-z0-9_-]|$)'

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

# gh_connected — true iff `gh` is on PATH and reports a live GitHub
# connection within OUTBOUND_GUARD_GH_TIMEOUT seconds (default 10). gh
# absent, `gh auth status` failing, or the timeout firing (exit 124) all
# read the same way here: not connected, since a push would hang or fail
# too. Only called for a command that already matched GIT_PUSH_RE, so an
# ordinary Bash call never pays for the ~0.4s `gh auth status` call.
gh_connected() {
    command -v gh >/dev/null 2>&1 || return 1
    timeout "${OUTBOUND_GUARD_GH_TIMEOUT:-10}" gh auth status >/dev/null 2>&1
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

    # One jq call: has-session-id, session id, then the prompt (which may
    # span lines) as the rest.
    fields=$(printf '%s' "$payload" | jq -r '(has("session_id") | tostring),
        (.session_id // "" | tostring),
        (if has("prompt") then (.prompt // "") else "" end), "."' 2>/dev/null) || exit 0
    has_sid=${fields%%$'\n'*}; fields=${fields#*$'\n'}
    sid=${fields%%$'\n'*}; fields=${fields#*$'\n'}
    prompt=${fields%.}; prompt=${prompt%$'\n'}
    while [ "${prompt%$'\n'}" != "$prompt" ]; do prompt=${prompt%$'\n'}; done
    [ "$has_sid" = "true" ] || exit 0
    [ -n "$sid" ] || exit 0
    sid=$(sanitize_id "$sid")
    [ -n "$sid" ] || exit 0

    [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
    f=$(marker_file "$sid")
    if printf '%s' "$prompt" | grep -qiE "$PROMPT_RE"; then
        printf '1\n' > "$f" 2>/dev/null
    elif [ -e "$f" ] || [ -L "$f" ]; then
        rm -f "$f" 2>/dev/null
    fi
    exit 0
fi

# ── PreToolUse (matcher Bash; JSON on stdin) ────────────────────────────────

[ -t 0 ] && exit 0
payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# One jq call: tool name, has-session-id, session id, then the command
# (which may span lines) as the rest.
fields=$(printf '%s' "$payload" | jq -r '(if has("tool_name") then .tool_name else "" end | tostring),
    (has("session_id") | tostring), (.session_id // "" | tostring),
    (.tool_input.command? // ""), "."' 2>/dev/null) || exit 0
tool_name=${fields%%$'\n'*}; fields=${fields#*$'\n'}
has_sid=${fields%%$'\n'*}; fields=${fields#*$'\n'}
sid=${fields%%$'\n'*}; fields=${fields#*$'\n'}
cmd=${fields%.}; cmd=${cmd%$'\n'}
while [ "${cmd%$'\n'}" != "$cmd" ]; do cmd=${cmd%$'\n'}; done   # as $(...) would
[ "$tool_name" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0

# Fold tabs to spaces so a tab between tokens can't hide a match (same
# defensive step scripts/bd-guard.sh takes before its own rules run).
cmd_norm=${cmd//$'\t'/ }

# Every rule below needs one of these words in the command; most Bash
# calls have none of them and are done here.
case "$cmd_norm" in
    *"${_sno}w"*|*git*|*gh*|*bd*) ;;
    *) exit 0 ;;
esac

# vendor-CLI/module: unconditional — evaluated before the session_id gate
# below, so it fires regardless of whether this payload carries a
# session_id. No override, no marker involved.
case "$cmd_norm" in *"${_sno}w"*)
if printf '%s' "$cmd_norm" | grep -Eq "$SNOW_RE" || printf '%s' "$cmd_norm" | grep -Eq "$SNOW_MODULE_RE"; then
    deny "outbound-guard: no Snowflake access from this sandbox — never install or run its CLI; mock Snowflake and run everything else locally."
fi ;;
esac

# git push: gated on gh_connected, not the marker below. No session_id
# needed at all — there's no marker to look up for this verb — so this
# runs before, and independently of, the session_id gate further down. A
# connected push falls through instead of exiting here, so a compound
# command like `git push && gh pr create` still reaches MARKER_RE below
# (claude-orca-cc5) — MARKER_RE doesn't match a lone `git push`, so that
# case still ends in a clean allow at the bottom of the script.
case "$cmd_norm" in *git*)
if printf '%s' "$cmd_norm" | grep -Eq "$GIT_PUSH_RE"; then
    if ! gh_connected; then
        deny "outbound-guard: no GitHub connection (gh auth status failed) — a push would fail; run 'gh auth login' or commit locally."
    fi
fi ;;
esac

# Everything past this point (gh pr/repo create, bd dolt push) needs a
# session_id to look up its marker — fail open on a payload missing one,
# same posture as every other incomplete-input case, but scoped to this
# rule only.
case "$cmd_norm" in *gh*|*bd*) ;; *) exit 0 ;; esac
[ "$has_sid" = "true" ] || exit 0
[ -n "$sid" ] || exit 0
sid=$(sanitize_id "$sid")
[ -n "$sid" ] || exit 0

if printf '%s' "$cmd_norm" | grep -Eq "$MARKER_RE"; then
    if [ ! -f "$(marker_file "$sid")" ]; then
        deny "outbound-guard: push/deploy is opt-in — the prompt has to ask for it; commit locally instead."
    fi
fi

exit 0
