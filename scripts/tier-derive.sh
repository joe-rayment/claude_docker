#!/bin/sh
# tier-derive — the single source of truth for the tier ladder.
#
# Given the top model (an alias or a full id), print the derived trio as three
# space-separated CONCRETE ids:
#
#     <top> <worker> <recon>
#
# where worker and recon are the next two consecutive rungs down the ladder,
# clamped at the haiku floor. This is the ONLY place the ladder and the
# derivation live — tier-set (the /tier engine) and tier-reconcile (the hook)
# both call it, so they can never disagree.
#
# Ladder (high→low, ranks): fable(4) > opus(3) > sonnet(2) > haiku(1).
#   fable  → claude-fable-5 claude-opus-4-8 claude-sonnet-5
#   opus   → claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5-20251001
#   sonnet → claude-sonnet-5 claude-haiku-4-5-20251001 claude-haiku-4-5-20251001
#   haiku  → claude-haiku-4-5-20251001 (×3)
#
# A full family id keeps its exact value in the top slot (e.g. a dated
# "claude-opus-4-8-20260101" stays as-is and derives sonnet/haiku beneath it);
# a bare alias is resolved to its canonical id.
#
# Off-ladder / unknown top (a custom id, "best", a bare "sonnet[1m]", etc.):
# print NOTHING and exit 3. Callers must treat this as "custom/unmanaged" and
# leave the slots untouched — never clobber a top we can't place on the ladder.
#
# Two auxiliary modes (same ladder, no separate table to drift):
#   tier-derive --name <model-or-alias>   canonical DISPLAY NAME for a rung's
#                                          concrete id ("Opus 4.8"); exit 1 and
#                                          no output if off-ladder (caller
#                                          falls back to the raw id).
#   tier-derive --rank <model-or-alias>   numeric rank, 0 if off-ladder.
#
# Usage:  tier-derive <model-or-alias>
# Exit:   0 derived (three ids on stdout) · 2 usage · 3 off-ladder (no output)

set -u

id_for_rank() {  # canonical concrete id for a ladder rank
    case "$1" in
        4) echo claude-fable-5 ;;
        3) echo claude-opus-4-8 ;;
        2) echo claude-sonnet-5 ;;
        1) echo claude-haiku-4-5-20251001 ;;
    esac
}

name_for_rank() {  # human display name for a ladder rank
    case "$1" in
        4) echo "Fable 5" ;;
        3) echo "Opus 4.8" ;;
        2) echo "Sonnet 5" ;;
        1) echo "Haiku 4.5" ;;
    esac
}

rank_of() {  # alias OR full family id -> rank; 0 = off-ladder/unknown
    case "$1" in
        fable  | claude-fable-*)  echo 4 ;;
        opus   | claude-opus-*)   echo 3 ;;
        sonnet | claude-sonnet-*) echo 2 ;;
        haiku  | claude-haiku-*)  echo 1 ;;
        *)                        echo 0 ;;
    esac
}

[ $# -ge 1 ] && [ -n "${1:-}" ] || { echo "usage: tier-derive [--name|--rank] <model-or-alias>" >&2; exit 2; }

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

wr=$((r - 1)); [ "$wr" -lt 1 ] && wr=1   # worker = one rung down, floored
cr=$((r - 2)); [ "$cr" -lt 1 ] && cr=1   # recon  = two rungs down, floored

echo "$top_id $(id_for_rank "$wr") $(id_for_rank "$cr")"
