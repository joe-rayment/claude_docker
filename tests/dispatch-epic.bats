# Guards: `dispatch --epic` runs an epic in waves on bead blockers with no Orca -- ready beads together, path-sharing beads one after the other, never more than the slot cap, a failed blocker blocks its dependents, and only a fully done epic prints EPIC READY
# Fails if: a blocked bead starts before its blocker is done, two beads naming the same file run at once, the cap is exceeded, a failed slice still lets EPIC READY print, or a hung worker makes the run wait forever
# Run: bats tests/dispatch-epic.bats
bats_require_minimum_version 1.5.0

setup() {
    FIX="$BATS_TEST_TMPDIR"
    DISPATCH="$BATS_TEST_DIRNAME/../scripts/dispatch.sh"
    ROOTD="$FIX/proj"
    mkdir -p "$ROOTD" "$FIX/bin" "$FIX/home" "$FIX/wt" "$FIX/beads" "$FIX/running"
    git -C "$ROOTD" init -q -b main
    git -C "$ROOTD" -c user.name=t -c user.email=t@example.invalid \
        commit -q --allow-empty -m init

    # A bd that answers from files: list --parent / show <id> --json /
    # update <id> --append-notes <text> (recorded in notes.log).
    cat >"$FIX/bin/bd" <<'EOF'
#!/bin/sh
D="$BD_FIX"
case "$1" in
    list) cat "$D/list.json" ;;
    show) [ -f "$D/show.$2.json" ] && cat "$D/show.$2.json" || exit 1 ;;
    update) printf '%s %s\n' "$2" "$4" >>"$D/notes.log" ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$FIX/bin/bd"
    export PATH="$FIX/bin:$PATH" BD_FIX="$FIX/beads"

    # The runner seam. Like worker-run it gets the job dir and settles
    # job.json: "failed" for beads named in STUB_FAIL, never for STUB_HANG.
    # Before sleeping it logs which other beads are running right now.
    cat >"$FIX/runner.sh" <<'EOF'
#!/bin/sh
J="$1"; B="$(jq -r .bead "$J/job.json")"
mkdir "$RUN_DIR/$B"
printf 'start %s running=%s\n' "$B" "$(ls "$RUN_DIR" | tr '\n' ',')" >>"$RUN_LOG"
case " $STUB_HANG " in *" $B "*) sleep 3; exit 0 ;; esac
sleep "${STUB_SLEEP:-0.4}"
S=done; case " ${STUB_FAIL:-} " in *" $B "*) S=failed ;; esac
rmdir "$RUN_DIR/$B"
jq --arg s "$S" '.state = $s' "$J/job.json" >"$J/job.tmp" && mv "$J/job.tmp" "$J/job.json"
EOF
    chmod +x "$FIX/runner.sh"
    export RUN_DIR="$FIX/running" RUN_LOG="$FIX/run.log" STUB_FAIL="" STUB_HANG=""
    export CLAUDE_ORCA_WORKER_RUN="$FIX/runner.sh"

    export PROJECT_DIR="$ROOTD" CLAUDE_ORCA_ROOT="$ROOTD" HOME="$FIX/home"
    export CLAUDE_ORCA_WORKTREES_DIR="$FIX/wt" TIER_STATE_FILE="$FIX/tier.json"
    export CLAUDE_ORCA_EPIC_POLL_S=0.1
    unset CLAUDE_ORCA_MAX_WORKERS CLAUDE_ORCA_EPIC_IDLE_S
    : >"$RUN_LOG"
}

# mkbead <id> <description> [blocker-id:status ...] -- one bd show fixture.
mkbead() {
    local id="$1" desc="$2" deps="[]" d
    shift 2
    for d in "$@"; do
        deps="$(printf '%s' "$deps" | jq -c --arg i "${d%%:*}" --arg s "${d##*:}" \
            '. + [{id:$i,dependency_type:"blocks",status:$s}]')"
    done
    jq -n -c --arg id "$id" --arg desc "$desc" --argjson deps "$deps" \
        '[{id:$id,title:$id,description:$desc,acceptance_criteria:"",dependencies:$deps}]' \
        >"$BD_FIX/show.$id.json"
}

# mklist <id> ... -- the epic's open children, in this order.
mklist() {
    local out="[]" i
    for i in "$@"; do
        out="$(printf '%s' "$out" | jq -c --arg i "$i" '. + [{id:$i,status:"open",issue_type:"task"}]')"
    done
    printf '%s\n' "$out" >"$BD_FIX/list.json"
    mkbead EP "the epic"
}

# bats does not fail a test on a negated line (`! cmd`), so these say it with return 1.
absent_out() { if printf '%s\n' "$output" | grep -q -- "$1"; then return 1; fi; }
absent_log() { if grep -q -- "$1" "$RUN_LOG"; then return 1; fi; }

line_of() { printf '%s\n' "$output" | grep -n -- "$1" | head -1 | cut -d: -f1; }

@test "C blocked by A: wave 1 is A and B, wave 2 is C, then EPIC READY and a note on the epic" {
    mklist A B C
    mkbead A "do a"
    mkbead B "do b"
    mkbead C "do c" "A:open"
    run --separate-stderr "$DISPATCH" --epic EP
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qx 'wave 1: A B'
    printf '%s\n' "$output" | grep -qx 'wave 2: C'
    [ "$(line_of 'done A')" -lt "$(line_of 'wave 2')" ]
    printf '%s\n' "$output" | grep -qx 'EPIC READY EP work/EP'
    [ "$(printf '%s\n' "$output" | tail -1)" = "EPIC READY EP work/EP" ]
    grep -qx 'EP DISPATCH EPIC merge_ready branch=work/EP -- every slice done; merge after review' "$BD_FIX/notes.log"
    # all three slices ran in the one epic worktree, cut from main
    [ -d "$FIX/wt/EP" ]
    [ "$(git -C "$FIX/wt/EP" rev-parse --abbrev-ref HEAD)" = "work/EP" ]
    grep -q '^start C running=C,$' "$RUN_LOG"
}

@test "a blocker that is already closed does not hold a bead back" {
    mklist A
    mkbead A "do a" "X:closed"
    run --separate-stderr "$DISPATCH" --epic EP
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qx 'wave 1: A'
    printf '%s\n' "$output" | grep -qx 'EPIC READY EP work/EP'
}

@test "two beads naming the same file never run together; the second says it is serialising" {
    mklist A B C
    mkbead A "edit scripts/shared.sh to add a flag"
    mkbead B "also touches scripts/shared.sh"
    mkbead C "unrelated work in docs/other.md"
    run --separate-stderr "$DISPATCH" --epic EP
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qx 'serialising B (shares scripts/shared.sh with A)'
    printf '%s\n' "$output" | grep -qx 'wave 1: A C'
    printf '%s\n' "$output" | grep -qx 'wave 2: B'
    # when B started, A was no longer running
    grep -q '^start B ' "$RUN_LOG"
    absent_log '^start B running=.*A,'
    absent_log '^start A running=.*B,'
    printf '%s\n' "$output" | grep -qx 'EPIC READY EP work/EP'
}

@test "A failing: C is reported blocked-by-failed, exit 3, EPIC BLOCKED and never EPIC READY" {
    mklist A B C
    mkbead A "do a"
    mkbead B "do b"
    mkbead C "do c" "A:open"
    export STUB_FAIL="A"
    run --separate-stderr "$DISPATCH" --epic EP
    [ "$status" -eq 3 ]
    printf '%s\n' "$output" | grep -qx 'failed A'
    printf '%s\n' "$output" | grep -qx 'done B'
    printf '%s\n' "$output" | grep -qx 'C blocked-by-failed A'
    printf '%s\n' "$output" | grep -qx 'EPIC BLOCKED EP failed=A'
    absent_out 'EPIC READY'
    absent_log '^start C '
    if [ -f "$BD_FIX/notes.log" ] && grep -q merge_ready "$BD_FIX/notes.log"; then false; fi
}

@test "a failure two levels up blocks the grandchild too" {
    mklist A B C
    mkbead A "do a"
    mkbead B "do b" "A:open"
    mkbead C "do c" "B:open"
    export STUB_FAIL="A"
    run --separate-stderr "$DISPATCH" --epic EP
    [ "$status" -eq 3 ]
    printf '%s\n' "$output" | grep -qx 'B blocked-by-failed A'
    printf '%s\n' "$output" | grep -qx 'C blocked-by-failed B'
    absent_log '^start [BC] '
}

@test "CLAUDE_ORCA_MAX_WORKERS=1 runs three independent beads one at a time" {
    mklist A B C
    mkbead A "do a"
    mkbead B "do b"
    mkbead C "do c"
    export CLAUDE_ORCA_MAX_WORKERS=1
    run --separate-stderr "$DISPATCH" --epic EP
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qx 'wave 1: A'
    printf '%s\n' "$output" | grep -qx 'wave 2: B'
    printf '%s\n' "$output" | grep -qx 'wave 3: C'
    # each start saw only itself running
    [ "$(grep -c '^start [ABC] running=[ABC],$' "$RUN_LOG")" -eq 3 ]
    printf '%s\n' "$output" | grep -qx 'EPIC READY EP work/EP'
}

@test "the default cap of 3 lets four independent beads start as 3 then 1" {
    mklist A B C D
    mkbead A "do a"
    mkbead B "do b"
    mkbead C "do c"
    mkbead D "do d"
    run --separate-stderr "$DISPATCH" --epic EP
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qx 'wave 1: A B C'
    printf '%s\n' "$output" | grep -qx 'wave 2: D'
}

@test "a blocker outside the epic that is still open stalls the run: exit 5, EPIC STALLED" {
    mklist A
    mkbead A "do a" "X:open"
    mkbead X "someone else's bead"
    # X is open in bd, so bd show says so
    jq '.[0].status = "open"' "$BD_FIX/show.X.json" >"$BD_FIX/x.tmp" && mv "$BD_FIX/x.tmp" "$BD_FIX/show.X.json"
    run --separate-stderr "$DISPATCH" --epic EP
    [ "$status" -eq 5 ]
    printf '%s\n' "$output" | grep -qx 'waiting A on X'
    printf '%s\n' "$output" | grep -qx 'EPIC STALLED EP waiting=A'
    absent_out 'EPIC READY'
}

@test "a worker that never reports ends the run after CLAUDE_ORCA_EPIC_IDLE_S: exit 5" {
    mklist A
    mkbead A "do a"
    export STUB_HANG="A" CLAUDE_ORCA_EPIC_IDLE_S=1
    run --separate-stderr "$DISPATCH" --epic EP
    [ "$status" -eq 5 ]
    printf '%s\n' "$output" | grep -qx 'wave 1: A'
    printf '%s\n' "$output" | grep -qx 'EPIC STALLED EP waiting=A'
}

@test "an epic with no open children exits 0 and dispatches nothing" {
    mklist
    run --separate-stderr "$DISPATCH" --epic EP
    [ "$status" -eq 0 ]
    absent_out 'wave'
    [ ! -s "$RUN_LOG" ]
}

@test "--epic with no id exits 1 with a usage line" {
    run --separate-stderr "$DISPATCH" --epic
    [ "$status" -eq 1 ]
    printf '%s' "$stderr" | grep -q 'usage: dispatch --epic'
}

@test "an unknown epic id exits 1 and starts nothing" {
    run --separate-stderr "$DISPATCH" --epic NOPE
    [ "$status" -eq 1 ]
    printf '%s' "$stderr" | grep -q 'no such epic: NOPE'
    [ ! -s "$RUN_LOG" ]
}
