#!/bin/sh
# tier-derive — the single source of truth for the tier ladder.
#
# Given the top model (an alias or a full id), print the derived trio as three
# space-separated CONCRETE ids:
#
#     <top> <worker> <recon>
#
# where worker is the next rung down CAPPED at sonnet-class, and recon is one
# rung below the worker, both clamped at the haiku floor. The cap encodes the
# DEFAULT tiering rule: the orchestrator plans, delegates, and reviews — the
# expensive tiers (opus/fable) stay out of the worker seat however high the
# top is, unless the cap is deliberately lifted (see --overdrive below). This
# is the ONLY place the ladder and the derivation live — tier-set (the /tier
# engine) and tier-reconcile (the hook) both call it, so they can never
# disagree.
#
# Ladder (high→low, ranks): fable(4) > opus(3) > sonnet(2) > haiku(1).
#   fable  → claude-fable-5 claude-sonnet-5 claude-haiku-4-5-20251001
#   opus   → claude-opus-5 claude-sonnet-5 claude-haiku-4-5-20251001
#   sonnet → claude-sonnet-5 claude-haiku-4-5-20251001 claude-haiku-4-5-20251001
#   haiku  → claude-haiku-4-5-20251001 (×3)
#
# A full family id keeps its exact value in the top slot (e.g. a dated
# "claude-opus-4-8-20260101" stays as-is and derives sonnet/haiku beneath it);
# a bare alias is resolved to its canonical id.
#
# Off-ladder / unknown top (a custom id, "best", a vendor-routed id — note a
# "[1m]"-style variant like "sonnet[1m]" is NOT off-ladder; it ranks by family):
# print NOTHING and exit 3. Callers must treat this as "custom/unmanaged" and
# leave the slots untouched — never clobber a top we can't place on the ladder.
#
# --overdrive is the sanctioned exception to the cap: the worker rung becomes
# the TOP itself (exact value and all, dated/variant suffix included), for the
# runs where the slice needs the expensive tier in the worker seat. Recon is
# still derived from the CAPPED worker, so it never inflates along with it:
#   --overdrive fable  → claude-fable-5 claude-fable-5 claude-haiku-4-5-20251001
#   --overdrive opus   → claude-opus-5 claude-opus-5 claude-haiku-4-5-20251001
#   --overdrive haiku  → unchanged (nothing to lift at the bottom rung)
# tier-derive stays a PURE FUNCTION of its arguments and reads no state: the
# flag is sticky in settings.json, and the CALLER (tier-set/tier-reconcile/
# tier-gate) reads it there and passes --overdrive as a LEADING argument —
# trailing it is silently ignored, as extra arguments always have been.
#
# Two auxiliary modes (same ladder, no separate table to drift):
#   tier-derive --name <model-or-alias>   canonical DISPLAY NAME for a rung's
#                                          concrete id ("Opus 5"); exit 1 and
#                                          no output if off-ladder (caller
#                                          falls back to the raw id).
#   tier-derive --rank <model-or-alias>   numeric rank, 0 if off-ladder.
#
# Usage:  tier-derive [--overdrive] <model-or-alias>
# Exit:   0 derived (three ids on stdout) · 2 usage · 3 off-ladder (no output)

set -u

id_for_rank() {  # canonical concrete id for a ladder rank
    case "$1" in
        4) echo claude-fable-5 ;;
        3) echo claude-opus-5 ;;
        2) echo claude-sonnet-5 ;;
        1) echo claude-haiku-4-5-20251001 ;;
    esac
}

name_for_rank() {  # human display name for a ladder rank
    case "$1" in
        4) echo "Fable 5" ;;
        3) echo "Opus 5" ;;
        2) echo "Sonnet 5" ;;
        1) echo "Haiku 4.5" ;;
    esac
}

rank_of() {  # alias OR full family id -> rank; 0 = off-ladder/unknown
    # A trailing [variant] suffix (e.g. "claude-fable-5[1m]", "opus[1m]") is
    # stripped for RANKING only — the /model picker persists such values, and
    # with the env-var remap retired an alias always means its native family,
    # so ranking the base is unambiguous. The caller keeps the exact original
    # value in the top slot.
    case "${1%\[*}" in
        fable  | claude-fable-*)  echo 4 ;;
        opus   | claude-opus-*)   echo 3 ;;
        sonnet | claude-sonnet-*) echo 2 ;;
        haiku  | claude-haiku-*)  echo 1 ;;
        *)                        echo 0 ;;
    esac
}

usage() { echo "usage: tier-derive [--name|--rank|--overdrive] <model-or-alias>" >&2; exit 2; }

[ $# -ge 1 ] && [ -n "${1:-}" ] || usage

overdrive=0
if [ "$1" = "--overdrive" ]; then   # leading modifier on the default mode
    overdrive=1
    shift
    [ $# -ge 1 ] && [ -n "${1:-}" ] || usage
fi

case "$1" in
    --name)
        [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "usage: tier-derive --name <model-or-alias>" >&2; exit 2; }
        r=$(rank_of "$2")
        [ "$r" -eq 0 ] && exit 1   # off-ladder: no canonical name, caller falls back to the raw id
        name_for_rank "$r"
        exit 0
        ;;
    --rank)
        [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "usage: tier-derive --rank <model-or-alias>" >&2; exit 2; }
        rank_of "$2"
        exit 0
        ;;
esac

top=$1
r=$(rank_of "$top")
[ "$r" -eq 0 ] && exit 3   # off-ladder: signal custom, emit nothing

# Resolve the top slot: a bare alias becomes its canonical id; a full id keeps
# its exact value (so a specific/dated/variant family id is preserved on top).
case "$top" in
    fable|opus|sonnet|haiku) top_id=$(id_for_rank "$r") ;;
    *)                       top_id=$top ;;
esac

wr=$((r - 1))
[ "$wr" -gt 2 ] && wr=2                   # worker CAP (default): sonnet-class — opus/fable stay out of the worker seat
[ "$wr" -lt 1 ] && wr=1                   # worker floor: haiku
cr=$((wr - 1)); [ "$cr" -lt 1 ] && cr=1   # recon = one rung below the CAPPED worker, floored

# --overdrive lifts the cap for the worker slot ONLY: it becomes the top's own
# exact value (so a dated/variant id is preserved there too). Recon keeps the
# capped derivation above, so lifting the worker never drags recon up with it.
if [ "$overdrive" -eq 1 ]; then
    worker_id=$top_id
else
    worker_id=$(id_for_rank "$wr")
fi

echo "$top_id $worker_id $(id_for_rank "$cr")"
