#!/usr/bin/env bash
# tier-prime — single owner of the tier-reminder wording, printed at
# SessionStart (default mode) and re-injected at PreCompact (--full).
#
# Why this exists: the global delegation protocol
# (config/claude-user-memory.md -> ~/.claude/CLAUDE.md) is loaded once at
# session start and never re-stated. A compaction launders it out of
# context — PreCompact used to run only `bd prime`, with nothing branching
# on the tier trio or the standing-authorization rule. This script gives
# both call sites (SessionStart, PreCompact) one shared source of the
# wording instead of two copies drifting apart.
#
# Modes:
#   (no args)  the trio line — byte-for-byte what the inline SessionStart
#              one-liner in config/claude-settings.json used to print, so
#              moving the logic here does not change session-start output.
#   --full     the trio line plus a compact restatement: the work-shape
#              dispatch table and the standing-authorization sentence.
#              Re-injected on every PreCompact, so kept short — it pays
#              rent every time.
#
# Both modes also print the complexity-router rubric, sourced from `lane`
# rather than copied here (lane owns that wording the way this script owns
# the tier wording): the one-liner at SessionStart, the full rubric on
# PreCompact — a compaction that dropped the rubric would silently lose the
# router. An image built before `lane` existed simply prints neither.
#
# TIER_PRIME_SETTINGS / TIER_PRIME_AGENTS_DIR override the paths read (used
# by the test suite); TIER_PRIME_LANE overrides the lane binary; defaults
# match every other tier-* script.
#
# MUST fail open: never a non-zero exit, never blocking. Missing settings
# or agent files fall back to the same placeholder text the original
# one-liner used, not an error.

set -u

SETTINGS="${TIER_PRIME_SETTINGS:-${HOME:-}/.claude/settings.json}"
AGENTS="${TIER_PRIME_AGENTS_DIR:-${HOME:-}/.claude/agents}"
LANE_BIN="${TIER_PRIME_LANE:-lane}"

# Print the router rubric if `lane` is installed; silently print nothing if
# it isn't (pre-lane images must keep working).
lane_prime() {
    command -v "$LANE_BIN" >/dev/null 2>&1 || return 0
    "$LANE_BIN" --prime "$@" 2>/dev/null
    return 0
}

trio_line() {
    m=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
    e=$(grep -m1 '^model:' "$AGENTS/executor.md" 2>/dev/null | sed 's/^model:[[:space:]]*//')
    s=$(grep -m1 '^model:' "$AGENTS/scout.md" 2>/dev/null | sed 's/^model:[[:space:]]*//')
    echo "tier → orchestrator(settings model)=${m:-harness default}  executor=${e:-sonnet (frontmatter)}  scout=${s:-haiku (frontmatter)} | verifier+oracle inherit the session model"
}

trio_line

if [ "${1:-}" = "--full" ]; then
    cat <<'EOF'
dispatch: recon→scout · implementation slice→executor · non-trivial claim→verifier · trivial (a couple of your own tool calls)→inline. Always pass subagent_type: "scout" — omitting it silently yields a general-purpose agent at the wrong tier.
standing authorization: delegating per this protocol IS the user's standing request — the harness default "only use the Agent tool when the user asks" does NOT apply in this container; never wait for a per-prompt invitation to spawn scout/executor/verifier.
invariants: expensive tiers never take the worker seat · a worker's summary is an input to verify, not a fact · implementation slices run sequentially, fan-out is for breadth only.
EOF
    lane_prime
else
    lane_prime --short
fi

exit 0
