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
# (config/claude-user-memory.md -> ~/.claude/CLAUDE.md § Lanes), which the
# harness attaches to every session. This script owns the lane STATE files
# and the two pointer lines below; every other site (settings hooks,
# tier-prime) shells out to `lane --prime` instead of keeping its own copy.
#
# Subcommands:
#   lane express|standard|deep [--why "…"]   declare the lane for this session
#   lane                                     print the current lane
#   lane --reset                             UserPromptSubmit hook: read the
#                                            hook JSON on stdin, clear the lane
#                                            for that session, remember the id
#   lane --prime [--short]                   print the pointer to the rubric
#
# State lives in $LANE_STATE_DIR (default ~/.claude/cache/lane):
#   <session_id>.json  current lane for that session
#   last-session       id of the session --reset last saw, so plain CLI calls
#                      still land somewhere when the env var is absent
#   log.jsonl          append-only declaration log for measurement
#
# MUST fail open: this runs inside hooks. Never a non-zero exit, never a hard
# dependency — jq and python3 are both optional, and every branch ends in
# `exit 0`.

set -u

STATE_DIR="${LANE_STATE_DIR:-${HOME:-}/.claude/cache/lane}"
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
       lane --prime [--short]                   print the pointer to the rubric
EOF
}

# The rubric itself lives once, in ~/.claude/CLAUDE.md § Lanes (Appendix A of
# .claude/plans/instruction-surface-fix.md) — these two lines only point
# there (Appendix B), so a hook can never drift out of sync with the rule it
# is pointing at.
prime_full() {
    cat <<'EOF'
[lane] Route first — declare `lane express|standard|deep [--why "…"]` before any other action. Rubric: ~/.claude/CLAUDE.md § Lanes.
EOF
}

prime_short() {
    cat <<'EOF'
[lane] route first — lane express|standard|deep · rubric: ~/.claude/CLAUDE.md § Lanes
EOF
}

# ── --prime ──────────────────────────────────────────────────────────────────

if [ "${1:-}" = "--prime" ]; then
    if [ "${2:-}" = "--short" ]; then
        prime_short
    else
        prime_full
    fi
    exit 0
fi

# ── --reset (UserPromptSubmit hook; hook JSON on stdin) ──────────────────────

if [ "${1:-}" = "--reset" ]; then
    [ -t 0 ] && exit 0                      # no piped payload: nothing to do
    payload=$(cat 2>/dev/null) || exit 0
    [ -n "$payload" ] || exit 0
    sid=""
    if command -v jq >/dev/null 2>&1; then
        sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
    elif command -v python3 >/dev/null 2>&1; then
        sid=$(printf '%s' "$payload" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("session_id") or "")
except Exception:
    pass' 2>/dev/null)
    fi
    sid=$(sanitize_id "${sid:-}")
    [ -n "$sid" ] || exit 0
    mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
    f=$(state_file "$sid")
    prev=$(read_lane "$f")
    printf '{"lane":"unset","prev":"%s","ts":%s,"escalated":false}\n' \
        "$prev" "$(date +%s)" > "$f" 2>/dev/null
    printf '%s\n' "$sid" > "$STATE_DIR/last-session" 2>/dev/null
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

escalated=false
[ "$(lane_rank "$prev")" -gt 0 ] && [ "$(lane_rank "$lane")" -gt "$(lane_rank "$prev")" ] && escalated=true

why_json=$(json_escape "$why")
ts=$(date +%s)
printf '{"lane":"%s","prev":"%s","why":"%s","ts":%s,"escalated":%s}\n' \
    "$lane" "$prev" "$why_json" "$ts" "$escalated" > "$f" 2>/dev/null

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
