#!/usr/bin/env bash
# lane — per-prompt complexity router: state + the pointer back to the
# routing rubric.
#
# Why this exists: every prompt used to get the full-court press (plan,
# beads, executor slices, verifier sign-off) regardless of size. The router
# asks the orchestrator to classify each prompt into one of three lanes and
# DECLARE it, so the route is visible in the transcript, enforceable by
# delegation-gate, and measurable by cost-mirror.
#
# Channel discipline (beads_claude_docker-mcuw): hooks carry state and
# pointers, never rules. The rubric itself lives once, in the rulebook
# (config/claude-user-memory.md -> the config dir's CLAUDE.md § Lanes),
# which the harness attaches to every session. This script owns the lane
# STATE files and the two pointer lines below; every other site (settings
# hooks, tier-prime) shells out to `lane --prime` instead of keeping its
# own copy.
#
# Subcommands:
#   lane express|standard|deep [--why "…"]   declare the lane for this session
#   lane                                     print the current lane
#   lane --prompt                            UserPromptSubmit hook: --reset then
#                                            --prime --short, in one process
#   lane --reset                             read the hook JSON on stdin, clear
#                                            the lane for that session, remember
#                                            the id
#   lane --prime [--short]                   print the pointer to the rubric
#
# Token diet (the --short primer): Claude Code fires UserPromptSubmit more
# than once per turn, and every firing used to print the pointer line. Now
# --reset records a fingerprint of the prompt it saw; a later firing that
# carries the SAME prompt is a re-fire, and it leaves a declared lane alone
# instead of clearing it. --prime --short reads the same hook JSON: it
# prints when the prompt is new or the lane is still unset, and nothing
# once the lane is declared -- so the reminder appears once per prompt and
# never again after the route was taken. The two hooks run in parallel, and
# both orders work because each decides from the payload, not from the
# other's write. `lane --prime` (long form) is unchanged and stateless.
#
# State lives in $LANE_STATE_DIR (default: the config dir's cache/lane --
# see lib/paths.sh's claude_config_dir()):
#   <session_id>.json  current lane for that session (+ "prompt": the
#                      fingerprint of the prompt --reset last saw)
#   last-session       id of the session --reset last saw, so plain CLI calls
#                      still land somewhere when the env var is absent
#   log.jsonl          append-only declaration log for measurement
#
# MUST fail open: this runs inside hooks. Never a non-zero exit, never a hard
# dependency — jq and python3 are both optional, and every branch ends in
# `exit 0`.

set -u

# Resolve through a symlink chain (e.g. bin/lane -> ../scripts/lane.sh) to
# this script's real directory, so lib/paths.sh resolves whether this is
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

STATE_DIR="${LANE_STATE_DIR:-$(claude_config_dir)/cache/lane}"
LOG="$STATE_DIR/log.jsonl"
LOG_MAX=5000
LOG_KEEP=2500

lane_rank() {
    case "$1" in
        express) echo 1 ;;
        standard) echo 2 ;;
        deep) echo 3 ;;
        *) echo 0 ;;     # "unset" and anything unknown never count as a lane
    esac
}

# Minimal JSON string escaping — control characters are dropped rather than
# encoded, which is enough for a --why blurb and keeps jq off the hot path.
json_escape() {
    printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

sanitize_id() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9._-'
}

state_file() {
    printf '%s/%s.json' "$STATE_DIR" "$1"
}

# Current lane recorded for a session, or "unset" when there is no readable
# state (missing file, missing key, truncated write).
read_lane() {
    f="$1"
    v=""
    if [ -f "$f" ]; then
        v=$(sed -n 's/.*"lane"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1)
    fi
    printf '%s' "${v:-unset}"
}

# The prompt fingerprint --reset stored for a session, or "" when none.
read_prompt() {
    f="$1"
    v=""
    if [ -f "$f" ]; then
        v=$(sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1)
    fi
    printf '%s' "${v:-}"
}

# Hook JSON on stdin -> PAYLOAD_SID / PAYLOAD_PROMPT (a short fingerprint
# of the prompt text, never the text itself). Both empty when stdin is a
# tty, empty, or unparseable. jq and python3 are both optional.
PAYLOAD_SID=""
PAYLOAD_PROMPT=""
read_payload() {
    [ -t 0 ] && return 0
    payload=$(cat 2>/dev/null) || return 0
    [ -n "$payload" ] || return 0
    fields=""
    if command -v jq >/dev/null 2>&1; then
        fields=$(printf '%s' "$payload" | jq -r '((.session_id // "") | tostring), ((.prompt // "") | tostring | gsub("\n"; " "))' 2>/dev/null)
    elif command -v python3 >/dev/null 2>&1; then
        fields=$(printf '%s' "$payload" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(str(d.get("session_id") or ""))
    print(str(d.get("prompt") or "").replace("\n"," "))
except Exception:
    pass' 2>/dev/null)
    fi
    prompt=""
    case "$fields" in
        *$'\n'*) prompt=${fields#*$'\n'}; prompt=${prompt%%$'\n'*} ;;
    esac
    PAYLOAD_SID=$(sanitize_id "${fields%%$'\n'*}")
    [ -n "$prompt" ] && PAYLOAD_PROMPT=$(printf '%s' "$prompt" | cksum | tr -cd '0-9 ' | tr ' ' '-')
    return 0
}

resolve_sid() {
    sid="${CLAUDE_CODE_SESSION_ID:-}"
    if [ -z "$sid" ] && [ -f "$STATE_DIR/last-session" ]; then
        sid=$(head -1 "$STATE_DIR/last-session" 2>/dev/null)
    fi
    sanitize_id "${sid:-}"
}

usage() {
    cat <<'EOF'
usage: lane express|standard|deep [--why "…"]   declare this prompt's lane
       lane                                     print the current lane
       lane --reset                             clear lane (hook JSON on stdin)
       lane --prompt                            --reset, then --prime --short (the hook)
       lane --prime [--short]                   print the pointer to the rubric
EOF
}

# The rubric itself lives once, in the config dir's CLAUDE.md § Lanes
# (the "one rulebook" plan, no longer in the repo) — these two
# pointer lines are built with claude_config_dir() (Appendix B), so a hook
# can never drift out of sync with the rule it is pointing at, and never
# hardcodes a path lib/paths.sh already owns.
prime_full() {
    printf '[lane] Route first — declare `lane express|standard|deep [--why "…"]` before any other action. Rubric: %s/CLAUDE.md § Lanes.\n' "$(claude_config_dir)"
}

prime_short() {
    printf '[lane] route first — lane express|standard|deep · rubric: %s/CLAUDE.md § Lanes\n' "$(claude_config_dir)"
}

# --prime --short's decision, from an already-read payload.
prime_short_for_prompt() {
    local sid f cur
    sid="$PAYLOAD_SID"
    [ -n "$sid" ] || sid=$(resolve_sid)
    if [ -z "$sid" ]; then
        prime_short                          # nowhere to look: always remind
        return 0
    fi
    f=$(state_file "$sid")
    cur=$(read_lane "$f")
    if [ "$(lane_rank "$cur")" -eq 0 ]; then
        prime_short                          # unset: the route is still owed
        return 0
    fi
    # Declared. A new prompt (fingerprint differs from the one --reset
    # stored, or none stored yet) still gets the reminder -- the reset
    # racing beside us is about to clear the lane anyway.
    if [ -n "$PAYLOAD_PROMPT" ] && [ "$PAYLOAD_PROMPT" != "$(read_prompt "$f")" ]; then
        prime_short
    fi
    return 0
}

# --reset's work, from an already-read payload.
reset_for_prompt() {
    local sid f prev
    sid="$PAYLOAD_SID"
    [ -n "$sid" ] || return 0               # no piped payload / no id: nothing to do
    [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    f=$(state_file "$sid")
    prev=$(read_lane "$f")
    # A re-fire: same prompt as the last reset, and a lane was declared
    # since -- the route was taken for this prompt, so keep it.
    if [ -n "$PAYLOAD_PROMPT" ] && [ "$(lane_rank "$prev")" -gt 0 ] \
       && [ "$PAYLOAD_PROMPT" = "$(read_prompt "$f")" ]; then
        printf '%s\n' "$sid" > "$STATE_DIR/last-session" 2>/dev/null
        return 0
    fi
    printf '{"lane":"unset","prev":"%s","prompt":"%s","ts":%s,"escalated":false}\n' \
        "$prev" "$PAYLOAD_PROMPT" "$(date +%s)" > "$f" 2>/dev/null
    printf '%s\n' "$sid" > "$STATE_DIR/last-session" 2>/dev/null
    return 0
}

# ── --prompt (the UserPromptSubmit hook): --reset, then --prime --short ──────
#
# One process instead of two hooks. Run in this order, the reminder shows
# on a new prompt and on an undeclared lane, and stays silent on a re-fire
# of a prompt whose lane was declared -- the same outcomes the two hooks
# reached running side by side.

if [ "${1:-}" = "--prompt" ]; then
    read_payload
    reset_for_prompt
    prime_short_for_prompt
    exit 0
fi

# ── --prime ──────────────────────────────────────────────────────────────────

if [ "${1:-}" = "--prime" ]; then
    if [ "${2:-}" != "--short" ]; then
        prime_full
        exit 0
    fi
    # --short: once per prompt, and silent once the lane is declared.
    read_payload
    prime_short_for_prompt
    exit 0
fi

# ── --reset (UserPromptSubmit hook; hook JSON on stdin) ──────────────────────

if [ "${1:-}" = "--reset" ]; then
    read_payload
    reset_for_prompt
    exit 0
fi

# ── no args: report the current lane ─────────────────────────────────────────

if [ $# -eq 0 ]; then
    sid=$(resolve_sid)
    if [ -z "$sid" ]; then
        echo "[lane] no session id — lane not recorded"
        exit 0
    fi
    echo "[lane] current: $(read_lane "$(state_file "$sid")")"
    exit 0
fi

# ── declare a lane ───────────────────────────────────────────────────────────

case "${1:-}" in
    express|standard|deep) : ;;
    *) usage; exit 0 ;;
esac

lane="$1"
shift
why=""
while [ $# -gt 0 ]; do
    case "$1" in
        --why)
            why="${2:-}"
            shift 2 2>/dev/null || shift
            ;;
        --why=*)
            why="${1#--why=}"
            shift
            ;;
        *) shift ;;
    esac
done

sid=$(resolve_sid)
if [ -z "$sid" ]; then
    echo "[lane] no session id — lane not recorded"
    exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || { echo "[lane] no session id — lane not recorded"; exit 0; }
f=$(state_file "$sid")
prev=$(read_lane "$f")
prompt_fp=$(read_prompt "$f")

escalated=false
[ "$(lane_rank "$prev")" -gt 0 ] && [ "$(lane_rank "$lane")" -gt "$(lane_rank "$prev")" ] && escalated=true

why_json=$(json_escape "$why")
ts=$(date +%s)
printf '{"lane":"%s","prev":"%s","prompt":"%s","why":"%s","ts":%s,"escalated":%s}\n' \
    "$lane" "$prev" "$prompt_fp" "$why_json" "$ts" "$escalated" > "$f" 2>/dev/null

printf '{"lane":"%s","prev":"%s","why":"%s","ts":%s,"escalated":%s,"session_id":"%s"}\n' \
    "$lane" "$prev" "$why_json" "$ts" "$escalated" "$sid" >> "$LOG" 2>/dev/null

# Keep the measurement log bounded: past LOG_MAX lines, drop all but the
# newest LOG_KEEP.
lines=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
case "$lines" in
    ''|*[!0-9]*) : ;;
    *)
        if [ "$lines" -gt "$LOG_MAX" ]; then
            if tail -n "$LOG_KEEP" "$LOG" > "$LOG.tmp" 2>/dev/null; then
                mv "$LOG.tmp" "$LOG" 2>/dev/null || rm -f "$LOG.tmp" 2>/dev/null
            fi
        fi
        ;;
esac

case "$lane" in
    express)  line="[lane] express — inline, no ceremony" ;;
    standard) line="[lane] standard — one slice, run-verify" ;;
    deep)     line="[lane] deep — full protocol: plan + contracts + verifier" ;;
esac
[ "$escalated" = true ] && line="$line (escalated from $prev)"
[ -n "$why" ] && line="$line — $why"
echo "$line"

exit 0
