#!/usr/bin/env bash
# outbound-guard — mechanically enforces "push and deploy are gated on
# GitHub auth" (config/claude-user-memory.md), the same pattern as bd-guard:
# one hook, one sentence of prose, instead of a paragraph the prior alone
# keeps failing to hold (beads_claude_docker-y2qe, re-gated on auth by
# beads_claude_docker-t1ym).
#
# PreToolUse (matcher Bash; hook JSON on stdin)
#   - deny any command containing a bare `snow`/`snowsql` invocation, or a
#     `snowflake.cli` module invocation (`python -m snowflake.cli …`,
#     `python3 -m snowflake.cli …`, or the dotted module path appearing any
#     other way) — word-boundary, anywhere in the line, including after
#     &&/;/|. Evaluated BEFORE anything else and therefore truly
#     unconditional: it fires for any valid-JSON payload naming tool_name
#     "Bash" with a command, regardless of GitHub auth state. No override:
#     no Snowflake credentials exist here and never will.
#   - deny `git push`, `gh pr create`, `gh repo create`, `bd dolt push` ONLY
#     when GitHub auth is positively absent. Auth counts as present if ANY
#     of: GH_TOKEN or GITHUB_TOKEN is non-empty (trusted directly, gh is
#     never invoked); gh is on PATH and `gh api user` exits 0 (a real API
#     round trip, bounded by `timeout` and cached per-HOME with a short TTL
#     — see gh_auth_valid below); or a private key exists in ~/.ssh (id_*).
#     Neither `gh auth token` nor `gh auth status` is trusted
#     (beads_claude_docker-iih3): `gh auth token` happily prints a token
#     that GitHub has since invalidated, and `gh auth status` ALSO exits 0
#     for a stale/expired token in this container (confirmed live: with the
#     invalid token here, `gh auth status` exits 0 while `gh api user`
#     exits 1) — it validates the on-disk config shape, not that GitHub
#     still honors the token. `gh api user` is the only one of the three
#     that actually asks GitHub. Do NOT go back to string-matching `gh auth
#     status`'s human-facing diagnostic ("invalid", "Failed to log in") —
#     that text is not a stable contract and will rot. This check runs only
#     after the push regex has matched, so the network call never touches
#     the per-Bash-call hot path for ordinary commands. Push/deploy is
#     otherwise unrestricted: no prompt wording, no per-session marker —
#     commit and push freely whenever auth is present.
#
# Word-boundary matching deliberately avoids GNU grep's `\b` extension (same
# reasoning as scripts/bd-guard.sh's own header comment: explicit character
# classes keep behavior stable) — a match requires the token to be flanked
# by start/end-of-string or a non `[A-Za-z0-9_-]` character, so `snow` does
# NOT fire inside `snowflake-cli` or `snowflake-snowpark-python` (the next
# character is a letter, not a boundary), only for a genuinely standalone
# `snow`/`snowsql` token. The module-form check (SNOW_MODULE_RE) reuses the
# same boundary style around the literal dotted path `snowflake.cli` — that
# exact substring (a literal `.`, not `-`) never appears in the allowed
# hyphenated package names (`snowflake-cli`, `snowflake-snowpark-python`,
# `snowflake-connector-python`), so no interpreter/`-m`-specific grammar is
# needed to keep those allowed while still catching `python -m
# snowflake.cli`/`python3 -m snowflake.cli`/any other way that dotted path
# shows up on the line.
#
# Deny output follows scripts/workflow-lint.sh's hookSpecificOutput shape
# (permissionDecision: "deny" + permissionDecisionReason), not bd-guard.sh's
# older exit-2/stderr contract — this hook always exits 0; the JSON itself
# is what blocks.
#
# MUST fail open, like every hook here: malformed/empty stdin or a non-Bash
# tool all exit 0 with no output. jq is a hard dependency of this image
# (Dockerfile-installed unconditionally); its absence still fails open
# rather than erroring.

set -u

command -v jq >/dev/null 2>&1 || exit 0

# Word-boundary alternation for a standalone snow/snowsql CLI invocation.
# Longer alternative first is not required for correctness (see header
# comment: the immediate-right-boundary check already keeps the two
# alternatives mutually exclusive at any given position), but is kept for
# readability.
SNOW_RE='(^|[^A-Za-z0-9_-])(snowsql|snow)([^A-Za-z0-9_-]|$)'

# `snowflake.cli` module invocation (python -m snowflake.cli, python3 -m
# snowflake.cli, or the dotted path appearing any other way) — see the
# header comment for why matching the literal dotted substring is enough on
# its own, without modeling `-m`/interpreter names.
SNOW_MODULE_RE='(^|[^A-Za-z0-9_-])snowflake\.cli([^A-Za-z0-9_-]|$)'

# git push / gh pr create / gh repo create / bd dolt push, same boundary style.
PUSH_RE='(^|[^A-Za-z0-9_-])(git[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+create|gh[[:space:]]+repo[[:space:]]+create|bd[[:space:]]+dolt[[:space:]]+push)([^A-Za-z0-9_-]|$)'

# Cache dir for the gh-auth validity check, one level under the same
# ~/.claude/cache convention scripts/lane.sh and scripts/session-title.sh
# use (per-HOME, so it isolates cleanly per container/user and per bats
# test HOME). Override exists only for tests/tooling; there is no reason to
# set it in normal use.
CACHE_DIR="${OUTBOUND_GUARD_CACHE_DIR:-${HOME:-}/.claude/cache/outbound-guard}"
GH_AUTH_CACHE_FILE="$CACHE_DIR/gh-auth-valid"

# Identifies which probe a cache entry was written by. This guard has
# already changed its validity probe once (gh auth status -> gh api user,
# beads_claude_docker-iih3, after gh auth status turned out to exit 0 for a
# genuinely invalid token) purely by renaming the cache file, which is
# fragile -- easy to forget on the next change. Stamping the probe into the
# cache CONTENT means a stale entry from a previous scheme is detected and
# ignored even if a future change reuses the same file name.
GH_AUTH_PROBE_ID="gh-api-user-v1"

# TTL for a cached `gh api user` result, in seconds. 300s (5 minutes) is
# long enough that a session doing several pushes in a row pays the network
# round trip once, short enough that a token revoked mid-session (rare, but
# it's exactly the failure this bead exists to catch) is re-checked well
# within the same working session rather than staying wrongly cached for
# the rest of the container's life.
GH_AUTH_CACHE_TTL=300

# Hard bound on the `gh api user` network call itself, in seconds. This
# check runs only after PUSH_RE has already matched (an actual push
# attempt, not the per-Bash-call hot path), so paying up to 5s here is
# cheap relative to a push; it is also short enough that a hung/unreachable
# gh cannot noticeably wedge the user's push.
GH_AUTH_TIMEOUT=5

# gh_auth_valid — cached, timeout-bounded validity check via `gh api user`.
# This is a real GitHub API round trip, deliberately NOT `gh auth token`
# (prints a stale token unchanged) and NOT `gh auth status` either: both
# were tried and both exited 0 for a genuinely invalid/expired token in
# this exact container (beads_claude_docker-iih3) -- `gh auth status`
# only validates the on-disk config shape, it does not ask GitHub whether
# the token still works. `gh api user` does. Returns 0 if a fresh-enough
# cached result (or a new call) says the token is valid, 1 otherwise. A
# cache miss or timeout still writes the result, so a hung gh doesn't get
# retried on every subsequent push within the TTL either.
gh_auth_valid() {
    local now cached_at cached_result cached_probe result

    now=$(date +%s 2>/dev/null) || return 1

    if [ -f "$GH_AUTH_CACHE_FILE" ]; then
        # cache format: "<epoch-seconds-of-check> <0-or-1> <probe-id>"
        cached_at=""
        cached_result=""
        cached_probe=""
        read -r cached_at cached_result cached_probe < "$GH_AUTH_CACHE_FILE" 2>/dev/null
        case "$cached_at" in
            ''|*[!0-9]*) ;; # not a plain integer -- treat as no usable cache
            *)
                if [ "$cached_probe" = "$GH_AUTH_PROBE_ID" ] \
                    && [ $((now - cached_at)) -lt "$GH_AUTH_CACHE_TTL" ]; then
                    [ "$cached_result" = "0" ] && return 0
                    return 1
                fi
                ;;
        esac
    fi

    if command -v timeout >/dev/null 2>&1; then
        timeout "${GH_AUTH_TIMEOUT}s" gh api user >/dev/null 2>&1
        result=$?
    else
        # No `timeout` binary available: skip the network call entirely
        # rather than risk an unbounded hang -- same posture as gh not
        # being on PATH at all (falls through to the ssh-key check below).
        return 1
    fi

    if mkdir -p "$CACHE_DIR" 2>/dev/null; then
        printf '%s %s %s\n' "$now" "$result" "$GH_AUTH_PROBE_ID" > "$GH_AUTH_CACHE_FILE" 2>/dev/null
    fi

    [ "$result" -eq 0 ]
}

# github_auth_present — checked only after PUSH_RE has already matched, so
# the network call inside gh_auth_valid never runs on the per-Bash-call
# hot path.
github_auth_present() {
    [ -n "${GH_TOKEN:-}" ] && return 0
    [ -n "${GITHUB_TOKEN:-}" ] && return 0

    if command -v gh >/dev/null 2>&1; then
        gh_auth_valid && return 0
    fi

    # A PRIVATE key only. The id_* glob also matches id_rsa.pub, and a
    # public key on its own is not authentication -- counting it would
    # allow exactly the push-with-no-credentials this guard exists to
    # stop (beads_claude_docker-t1ym).
    local f
    for f in "${HOME:-}"/.ssh/id_*; do
        case "$f" in *.pub) continue ;; esac
        [ -f "$f" ] && return 0
    done

    return 1
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

# snow/snowsql/snowflake.cli: unconditional — evaluated before the auth
# check below, so it fires regardless of GitHub auth state. No override.
if printf '%s' "$cmd_norm" | grep -Eq "$SNOW_RE" || printf '%s' "$cmd_norm" | grep -Eq "$SNOW_MODULE_RE"; then
    deny "outbound-guard: no Snowflake access from this container — never install or run snow/snowsql; mock Snowflake and run everything else locally."
fi

if printf '%s' "$cmd_norm" | grep -Eq "$PUSH_RE"; then
    if ! github_auth_present; then
        deny "outbound-guard: no GitHub authentication in this container — commit locally; run 'gh auth login' or set GH_TOKEN to unblock this."
    fi
fi

exit 0
