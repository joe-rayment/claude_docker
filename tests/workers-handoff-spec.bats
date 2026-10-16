#!/usr/bin/env bats
#
# Guards:   a dispatch re-reads its bead's notes: the LAST "HANDOFF-AT" block
#           is folded into the next worker's spec (once, before the WORKER
#           RULES), and a bead whose notes hold no HANDOFF-AT line gets a spec
#           byte-identical to the same bead without notes. Ported from
#           orca-relay.bats when the Orca scripts were deleted (C1c).
# Fails if: orch_spec (scripts/lib/workers.sh) folds in the first block
#           instead of the last, folds it in twice, puts it after WORKER
#           RULES, or lets ordinary notes change the spec.
# Run:      bats tests/workers-handoff-spec.bats

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/workers.sh"

setup() {
    export CLAUDE_ORCA_ROOT="$BATS_TEST_TMPDIR/root"
    export PROJECT_DIR="$CLAUDE_ORCA_ROOT"
    mkdir -p "$CLAUDE_ORCA_ROOT"
}

@test "orch_spec folds the last of two HANDOFF-AT notes in before WORKER RULES" {
    . "$LIB"
    notes='HANDOFF-AT 2026-09-23T01:00:00Z dispatch=d1
done: first pass
left: more
facts: a.sh:1
next: first-next-line
relay: this agent is finished -- start a fresh one from this block; never message or resume it.
ORCA WORKER_DONE outcome=succeeded task=t2 dispatch=d2 files=a.sh
worker two report
HANDOFF-AT 2026-09-23T02:00:00Z dispatch=d2
done: second pass
left: less
facts: b.sh:2
next: second-next-line
relay: this agent is finished -- start a fresh one from this block; never message or resume it.'
    bj="$(jq -n --arg n "$notes" \
        '{title:"probe", description:"d", acceptance_criteria:"CHECK: true", notes:$n}')"
    spec="$(orch_spec "$bj" b1)"

    count="$(printf '%s\n' "$spec" | grep -c -e 'CONTINUE FROM HANDOFF')"
    [ "$count" = "1" ]
    printf '%s\n' "$spec" | grep -q -e 'next: second-next-line'
    run bash -c "printf '%s\n' \"\$1\" | grep -q -e 'next: first-next-line'" _ "$spec"
    [ "$status" -ne 0 ]

    before="$(printf '%s\n' "$spec" | grep -n -e 'CONTINUE FROM HANDOFF' | head -1 | cut -d: -f1)"
    after="$(printf '%s\n' "$spec" | grep -n -e 'WORKER RULES' | head -1 | cut -d: -f1)"
    [ -n "$before" ]
    [ -n "$after" ]
    [ "$before" -lt "$after" ]
}

@test "orch_spec without HANDOFF-AT is byte-identical to the same bead without notes" {
    . "$LIB"
    bj_plain='{"title":"probe","description":"d","acceptance_criteria":"CHECK: true"}'
    bj_notes='{"title":"probe","description":"d","acceptance_criteria":"CHECK: true","notes":"ORCA WORKER_DONE outcome=succeeded task=t1 dispatch=d1 files=a.sh\nno handoff here"}'

    spec_plain="$(orch_spec "$bj_plain" b1)"
    spec_notes="$(orch_spec "$bj_notes" b1)"
    [ "$spec_plain" = "$spec_notes" ]
}
