#!/usr/bin/env bash
# tier-prime — single owner of the tier-reminder wording, printed at
# SessionStart. `--full` is accepted and produces BYTE-IDENTICAL output to
# the bare form — kept only so a stale PreCompact hook entry elsewhere still
# calls something valid; see below for why PreCompact no longer needs it.
#
# Why this exists: the global delegation protocol
# (config/claude-user-memory.md -> ~/.claude/CLAUDE.md) is loaded once at
# session start. It used to be re-stated in full at PreCompact too (a
# dispatch table, a standing-authorization sentence, an invariants list),
# on the theory that compaction could launder it out of context otherwise.
#
# Channel discipline (beads_claude_docker-mcuw): per the official docs
# (code.claude.com/docs/en/hooks, /memory), SessionStart's matchers include
# `compact` — so SessionStart hooks, this one included, already re-run
# after every compaction — and Claude re-reads CLAUDE.md from disk after
# `/compact`. SessionStart already covers compaction, so the PreCompact
# hook entries that used to call this script with --full are deleted
# (config/claude-settings.json), and this script no longer carries a
# restated dispatch table, standing-authorization sentence, or invariants
# list — that text lives once, in the rulebook itself
# (~/.claude/CLAUDE.md § Delegation), and this script only points to it.
#
# Output, identical in both modes: the tier trio line, a one-line pointer
# to the rulebook section, then the lane pointer line (sourced from `lane`
# rather than copied here — lane owns that wording the way this script owns
# the tier wording). An image built before `lane` existed simply omits the
# third line.
#
# The trio line also names OVERDRIVE when the settings file carries
# .env.TIER_OVERDRIVE="1" (see trio_line) — the sticky worker-cap lift is
# expensive and must never be silently on; without the flag the line is
# byte-identical to what it has always printed.
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

# Print the router pointer if `lane` is installed; silently print nothing if
# it isn't (pre-lane images must keep working).
lane_prime() {
    command -v "$LANE_BIN" >/dev/null 2>&1 || return 0
    "$LANE_BIN" --prime 2>/dev/null
    return 0
}

trio_line() {
    m=$(jq -r '.model // empty' "$SETTINGS" 2>/dev/null)
    e=$(grep -m1 '^model:' "$AGENTS/executor.md" 2>/dev/null | sed 's/^model:[[:space:]]*//')
    s=$(grep -m1 '^model:' "$AGENTS/scout.md" 2>/dev/null | sed 's/^model:[[:space:]]*//')
    # `tier-set overdrive` parks .env.TIER_OVERDRIVE="1" (tier-set.sh owns that
    # flag) to lift the worker cap — an expensive binding that must never run
    # silently, so it is stated here rather than left to be inferred from the
    # executor id above. Appended to the SAME line: this text is re-injected at
    # every PreCompact and pays rent each time. Only the literal "1" counts,
    # matching tier-gate/tier-reconcile.
    od=$(jq -r '.env.TIER_OVERDRIVE // empty' "$SETTINGS" 2>/dev/null)
    [ "$od" = "1" ] && od=" | OVERDRIVE: worker cap lifted — /tier <top> to clear" || od=""
    echo "tier → orchestrator(settings model)=${m:-harness default}  executor=${e:-sonnet (frontmatter)}  scout=${s:-haiku (frontmatter)} | verifier+oracle inherit the session model${od}"
}

trio_line

cat <<'EOF'
protocol: ~/.claude/CLAUDE.md § Delegation · § Lanes
EOF

lane_prime

exit 0
