#!/usr/bin/env bats

# beads_claude_docker-ip4: teardown/resume must automatically rebuild a
# project's beads database from its JSONL snapshot -- even when the snapshot
# carries no metadata.json (the reported failure shape) -- with no prompt.
#
# These tests source the REAL detect_beads_prefix()/seed_beads_memories()/
# ensure_beads() bodies out of scripts/entrypoint.sh, and the REAL
# restore_beads_snapshot() body out of scripts/launcher.sh -- not
# reimplementations of the logic -- and run them against throwaway
# directories under $BATS_TEST_TMPDIR. Every bd call is scoped to that
# throwaway directory (ensure_beads's own $dir parameter, or an explicit
# `cd`/$HOME override); none of this ever touches /workspace/.beads, the
# live 100-issue project database.

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT_SRC="$REPO_DIR/scripts/entrypoint.sh"
LAUNCHER_SRC="$REPO_DIR/scripts/launcher.sh"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    command -v bd   >/dev/null 2>&1 || skip "bd not installed"
    command -v dolt >/dev/null 2>&1 || skip "dolt not installed"
    command -v jq   >/dev/null 2>&1 || skip "jq not installed"

    # --- extract the real ensure_beads()/detect_beads_prefix()/
    # seed_beads_memories() bodies from entrypoint.sh, stopping before the
    # unconditional `ensure_beads` call at the bottom -- sourcing that would
    # run it against the default /workspace. ---
    local ep_start ep_end
    ep_start=$(grep -n '^detect_beads_prefix() {' "$ENTRYPOINT_SRC" | head -1 | cut -d: -f1)
    ep_end=$(grep -n '^ensure_beads$' "$ENTRYPOINT_SRC" | head -1 | cut -d: -f1)
    [ -n "$ep_start" ] && [ -n "$ep_end" ]
    sed -n "${ep_start},$((ep_end - 1))p" "$ENTRYPOINT_SRC" > "$BATS_TEST_TMPDIR/entrypoint-functions.sh"

    # --- extract the real restore_beads_snapshot() body from launcher.sh,
    # plus the C_* color vars it references. ---
    local ls_start ls_end
    ls_start=$(grep -n '^restore_beads_snapshot() {' "$LAUNCHER_SRC" | head -1 | cut -d: -f1)
    ls_end=$(awk -v s="$ls_start" 'NR>=s && /^}$/{print NR; exit}' "$LAUNCHER_SRC")
    [ -n "$ls_start" ] && [ -n "$ls_end" ]
    {
        grep '^C_[A-Z_]*=' "$LAUNCHER_SRC"
        sed -n "${ls_start},${ls_end}p" "$LAUNCHER_SRC"
    } > "$BATS_TEST_TMPDIR/launcher-functions.sh"

    # Small standalone runner so restore_beads_snapshot can be invoked in its
    # own process (clean stdin control) without fragile string-interpolated
    # `bash -c "..."` quoting.
    cat > "$BATS_TEST_TMPDIR/run-restore.sh" <<'EOF'
#!/bin/bash
source "$1"
restore_beads_snapshot "$2" "$3"
EOF
    chmod +x "$BATS_TEST_TMPDIR/run-restore.sh"

    # Stub dev-log: ensure_beads calls it, but its own behavior isn't under
    # test here, and the real binary would write into the live project's
    # /workspace/.claude/logs/.
    dev-log() { :; }

    source "$BATS_TEST_TMPDIR/entrypoint-functions.sh"

    PROJ="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$PROJ"
    export HOME="$BATS_TEST_TMPDIR/home"  # restore_beads_snapshot reads $HOME/.claude-dev-state
    mkdir -p "$HOME"
}

_bd_total() {
    (cd "$PROJ" && bd status --json) 2>/dev/null | jq -r '.summary.total_issues // 0'
}

# Count persistent memories ('bd remember'), excluding the schema_version
# key that's always present in `bd memories --json` output.
_bd_mem_count() {
    (cd "$PROJ" && bd memories --json) 2>/dev/null | jq '[keys[] | select(. != "schema_version")] | length'
}

# $1 = project dir -> prints its embeddeddolt db subdir. Discovered by
# listing rather than assumed from --prefix: bd sanitizes prefixes that
# don't start with a letter, so the two are not always identical.
_dolt_dir_for() {
    find "$1/.beads/embeddeddolt" -mindepth 1 -maxdepth 1 -type d | head -1
}

# Any bd write is followed by a THROTTLED auto-export (default 60s,
# .beads/export-state.json tracks the last one). Backdate it so the very
# next bd call in a test is unconditionally past the throttle --
# deterministic, and avoids a real 60s+ sleep per test. This is what makes
# beads_claude_docker-2fd's delete-on-empty-table behavior reproducible on
# demand instead of only intermittently, depending on wall-clock luck.
_backdate_export_state() {
    local f="$1/.beads/export-state.json"
    [ -f "$f" ] || return 0
    jq '.timestamp = (now - 300 | strftime("%Y-%m-%dT%H:%M:%S.000000000Z"))' "$f" > "$f.tmp" \
        && mv "$f.tmp" "$f"
}

@test "sandbox isolation holds: ensure_beads against a throwaway dir reports 0, not 100" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    [ "$(_bd_total)" = "0" ]
}

@test "fresh project (case A): ensure_beads initializes an empty database" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    [ -d "$PROJ/.beads" ]
    [ "$(_bd_total)" = "0" ]
}

@test "end-to-end: teardown snapshot with NO metadata.json -> automatic resume -> ensure_beads rebuilds identical issues, zero prompts" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"

    (cd "$PROJ" && bd create "Open issue" --quiet)
    id2=$(cd "$PROJ" && bd create "In progress issue" --json | jq -r '.id')
    id3=$(cd "$PROJ" && bd create "Closed issue" --json | jq -r '.id')
    (cd "$PROJ" && bd update "$id2" --claim --quiet)
    (cd "$PROJ" && bd close "$id3" --reason "done" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)  # full, non-throttled flush

    local ground_truth="$BATS_TEST_TMPDIR/ground-truth.txt"
    (cd "$PROJ" && bd list --all --flat) > "$ground_truth"
    [ "$(_bd_total)" = "3" ]

    # --- simulate scripts/launcher.sh cmd_teardown: snapshot issues.jsonl
    # ONLY (no metadata.json -- the reported failure shape), then remove
    # .git/ and .beads/ exactly as teardown does (launcher.sh's rm -rf of
    # $SCRIPT_DIR/.git and $SCRIPT_DIR/.beads). ---
    local project_name="resumetest"
    local state_root="$HOME/.claude-dev-state/$project_name"
    mkdir -p "$state_root/20260101-000000"
    cp "$PROJ/.beads/issues.jsonl" "$state_root/20260101-000000/"
    [ ! -f "$state_root/20260101-000000/metadata.json" ]
    rm -rf "$PROJ/.git" "$PROJ/.beads"

    # --- simulate re-bootstrapping in the same directory: the REAL
    # restore_beads_snapshot(), stdin from /dev/null so a leftover prompt
    # would surface as a hang/non-zero exit rather than silently pass. ---
    local restore_output restore_status
    restore_output=$("$BATS_TEST_TMPDIR/run-restore.sh" "$BATS_TEST_TMPDIR/launcher-functions.sh" "$PROJ" "$project_name" < /dev/null 2>&1)
    restore_status=$?
    [ "$restore_status" -eq 0 ]
    [[ "$restore_output" != *"[Y/n]"* ]]
    [[ "$restore_output" != *"Overwrite"* ]]
    [ -f "$PROJ/.beads/issues.jsonl" ]
    [ ! -f "$PROJ/.beads/metadata.json" ]
    [ -d "$PROJ/.git" ]

    # --- the actual code under test for the rebuild itself: the real,
    # unmodified ensure_beads() deciding to rebuild and rebuilding. ---
    ensure_beads "$PROJ"

    [ "$(_bd_total)" = "3" ]
    diff "$ground_truth" <(cd "$PROJ" && bd list --all --flat)
}

@test "idempotent: rerunning ensure_beads on an already-healthy project is a no-op" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Solo issue" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)

    local before_total before_list after_total after_list
    before_total=$(_bd_total)
    before_list=$(cd "$PROJ" && bd list --all --flat)

    ensure_beads "$PROJ"
    ensure_beads "$PROJ"

    after_total=$(_bd_total)
    after_list=$(cd "$PROJ" && bd list --all --flat)

    [ "$before_total" = "$after_total" ]
    [ "$before_list" = "$after_list" ]
}

@test "ambiguous case: project already has its own issues.jsonl -> non-interactive default is to NOT overwrite" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Existing issue, must survive untouched" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)
    local existing_md5
    existing_md5=$(md5sum "$PROJ/.beads/issues.jsonl" | cut -d' ' -f1)

    # An unrelated/stale snapshot also exists.
    local project_name="resumetest2"
    local state_root="$HOME/.claude-dev-state/$project_name"
    mkdir -p "$state_root/20260101-000000"
    echo '{"_type":"issue","id":"other-1","title":"Should NOT overwrite","status":"open"}' \
        > "$state_root/20260101-000000/issues.jsonl"

    "$BATS_TEST_TMPDIR/run-restore.sh" "$BATS_TEST_TMPDIR/launcher-functions.sh" "$PROJ" "$project_name" < /dev/null

    [ "$(md5sum "$PROJ/.beads/issues.jsonl" | cut -d' ' -f1)" = "$existing_md5" ]
}

@test "beads_claude_docker-2fd: a zero-importable export that bd itself would delete survives ensure_beads via the safety copy" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Open issue" --quiet)
    id2=$(cd "$PROJ" && bd create "In progress issue" --json | jq -r '.id')
    id3=$(cd "$PROJ" && bd create "Closed issue" --json | jq -r '.id')
    (cd "$PROJ" && bd update "$id2" --claim --quiet)
    (cd "$PROJ" && bd close "$id3" --reason "done" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)

    # Corrupt the LIVE DB directly with dolt sql (never via bd, which would
    # heal the fixture instead of building it): empty the issues table so
    # bd status's own auto-import/auto-export cycle -- not our repair -- is
    # what's under test.
    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    ( cd "$dbdir" \
      && dolt sql -q "delete from issue_snapshots" \
      && dolt sql -q "delete from events" \
      && dolt sql -q "delete from comments" \
      && dolt sql -q "delete from dependencies" \
      && dolt sql -q "delete from labels" \
      && dolt sql -q "delete from issues" )

    # A syntactically-valid JSONL line that is not an issue (a memory
    # record) -- parses cleanly but yields zero importable ISSUE records.
    printf '{"_type":"memory","content":"unrelated note","id":"mem-1"}\n' > "$PROJ/.beads/issues.jsonl"
    _backdate_export_state "$PROJ"

    local before_md5
    before_md5=$(md5sum "$PROJ/.beads/issues.jsonl" | cut -d' ' -f1)

    ensure_beads "$PROJ"

    # HARD CONSTRAINT: issues.jsonl must never be deleted. Nothing was
    # recoverable in this fixture (DB and export both empty of real
    # issues), so the only correct outcome is the export preserved
    # byte-for-byte -- not fabricated, not gone.
    [ -f "$PROJ/.beads/issues.jsonl" ]
    local after_md5
    after_md5=$(md5sum "$PROJ/.beads/issues.jsonl" | cut -d' ' -f1)
    [ "$before_md5" = "$after_md5" ]
}

@test "beads_claude_docker-cx8: reachable double-failure (embeddeddolt present, issue_prefix missing) is repaired by removing embeddeddolt and retrying" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Will be wiped" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)

    # Corrupt the LIVE DB directly with dolt sql: drop issue_prefix AND
    # empty the issues table, so the plain init+import repair pair is
    # reachable (total 0) and BOTH halves genuinely fail against it (init:
    # "already initialized"; import: "issue_prefix config is missing").
    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    ( cd "$dbdir" \
      && dolt sql -q "delete from config where \`key\`='issue_prefix'" \
      && dolt sql -q "delete from issue_snapshots" \
      && dolt sql -q "delete from events" \
      && dolt sql -q "delete from comments" \
      && dolt sql -q "delete from dependencies" \
      && dolt sql -q "delete from labels" \
      && dolt sql -q "delete from issues" )

    # Syntactically valid but missing the required "title" field -- yields
    # zero importable issues, same as the 2fd shape above (bd status's own
    # auto-export can delete this file too; ensure_beads's safety copy
    # restores it before bd import runs). With issue_prefix already gone
    # and embeddeddolt/ already present, that restored-but-still-unimportable
    # file is what lets bd import get far enough to hit the real
    # issue_prefix failure this bead is about, after bd init has already
    # refused with "already initialized".
    printf '{"_type":"issue","id":"cx8fix-xxx","status":"open"}\n' > "$PROJ/.beads/issues.jsonl"
    _backdate_export_state "$PROJ"

    local before_md5
    before_md5=$(md5sum "$PROJ/.beads/issues.jsonl" | cut -d' ' -f1)

    ensure_beads "$PROJ"

    # issues.jsonl must never be deleted -- nothing was recoverable in this
    # fixture either (DB emptied, export has zero importable issues), so it
    # must survive byte-for-byte.
    [ -f "$PROJ/.beads/issues.jsonl" ]
    local after_md5
    after_md5=$(md5sum "$PROJ/.beads/issues.jsonl" | cut -d' ' -f1)
    [ "$before_md5" = "$after_md5" ]

    # The write path must actually be fixed, not just "didn't crash": both
    # embeddeddolt/ (recreated) and a working bd create prove the escalation
    # ran and succeeded.
    [ -d "$PROJ/.beads/embeddeddolt" ]
    (cd "$PROJ" && bd create "post-repair write-path probe" --quiet)

    # The 2 starter memories (seeded by the initial ensure_beads case-A
    # call) live only in the Dolt DB -- never in issues.jsonl or a default
    # `bd export` -- so they were still present, untouched, right up until
    # the escalation's `rm -rf embeddeddolt`. They must survive the
    # removal-and-rebuild, not silently vanish with it.
    [ "$(_bd_mem_count)" = "2" ]
}

# THIRD DATA-LOSS PATH: the cx8 escalation's own capture-before-`rm -rf`
# step (fresh_export) had no fallback when its mktemp failed (unlike
# safety_copy a few lines above it) and a failed `bd export` was never
# treated as fatal -- so the destructive `rm -rf .beads/embeddeddolt` ran
# unconditionally, gated only on prefix_after, and the DB was rebuilt from
# whatever stale issues.jsonl happened to already be on disk. Same
# live-ahead fixture as a2s (issue_prefix dropped, issues table intact and
# ahead of a deliberately stale on-disk export), but here the failure mode
# under test is the CAPTURE step itself, not the health check.
@test "escalation capture with a read-only TMPDIR: live-ahead issues and memories both survive (was: stale export wins, data lost)" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"   # case A: seeds prefix + 2 starter memories
    (cd "$PROJ" && bd create "Issue present in stale export" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)   # deliberately stale
    (cd "$PROJ" && bd create "Issue missing from stale export" --quiet)
    id3=$(cd "$PROJ" && bd create "Closed issue missing from stale export" --json | jq -r '.id')
    (cd "$PROJ" && bd close "$id3" --reason "done" --quiet)

    local ground_truth="$BATS_TEST_TMPDIR/ro-tmpdir-ground-truth.txt"
    (cd "$PROJ" && bd list --all --flat) > "$ground_truth"
    [ "$(_bd_total)" = "3" ]
    [ "$(_bd_mem_count)" = "2" ]

    # Corrupt the write path only (drop issue_prefix); issues table stays
    # intact and legitimately ahead of the on-disk export.
    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    ( cd "$dbdir" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )
    # Deliberately do NOT backdate export-state.json here (unlike the 2fd/
    # cx8/a2s fixtures above): the create/close calls just above already
    # refreshed its timestamp, so bd's own throttled auto-export stays
    # dormant for the rest of this test. Backdating would let that
    # auto-export silently refresh issues.jsonl on disk before ensure_beads
    # ever reaches the escalation, masking the exact staleness this test
    # exists to exercise -- confirmed empirically while building this repro.

    local before_md5
    before_md5=$(md5sum "$PROJ/.beads/issues.jsonl" | cut -d' ' -f1)

    # A read-only TMPDIR for this one call only: mktemp fails, so the fix's
    # tier-2 fallback (a fixed name inside .beads/, which IS writable here)
    # is what's under test.
    local ro_tmpdir="$BATS_TEST_TMPDIR/ro-tmp"
    mkdir -p "$ro_tmpdir"
    chmod 0500 "$ro_tmpdir"
    TMPDIR="$ro_tmpdir" ensure_beads "$PROJ"
    chmod 0700 "$ro_tmpdir"   # restore before bats tries to clean up its own tmpdir

    [ "$(_bd_total)" = "3" ]
    diff "$ground_truth" <(cd "$PROJ" && bd list --all --flat)
    [ "$(_bd_mem_count)" = "2" ]
    (cd "$PROJ" && bd create "post-repair write-path probe" --quiet)
    # before_md5 is intentionally unused for the final assertion: with a
    # working tier-2 fallback the file legitimately gets REWRITTEN (the
    # on-disk copy was stale) -- correctness is asserted via the issue
    # list above, matching a2s's existing pattern.
    [ -n "$before_md5" ]

    # This is the one test that exercises the tier-2 fallback (mktemp is
    # what's read-only here, so the capture and its jq split all land
    # inside .beads/) -- confirm the transient capture and both split
    # derivatives are cleaned up, not left behind as committable cruft.
    [ ! -e "$PROJ/.beads/issues.jsonl.fresh" ]
    [ ! -e "$PROJ/.beads/issues.jsonl.fresh.issues" ]
    [ ! -e "$PROJ/.beads/issues.jsonl.fresh.memories" ]
}

@test "escalation capture when bd export itself fails: destructive rebuild is skipped, DB stays broken-but-intact (no data lost)" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Issue present in stale export" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)
    (cd "$PROJ" && bd create "Issue missing from stale export" --quiet)
    id3=$(cd "$PROJ" && bd create "Closed issue missing from stale export" --json | jq -r '.id')
    (cd "$PROJ" && bd close "$id3" --reason "done" --quiet)
    [ "$(_bd_total)" = "3" ]
    [ "$(_bd_mem_count)" = "2" ]

    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    # Sentinel proves the rm -rf never ran: mtime-independent, and dolt's
    # own commit machinery will never touch a file it doesn't manage.
    touch "$dbdir/SENTINEL_MUST_SURVIVE"
    ( cd "$dbdir" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )
    # Same reasoning as the read-only-TMPDIR test above: no backdating.

    local before_md5
    before_md5=$(md5sum "$PROJ/.beads/issues.jsonl" | cut -d' ' -f1)

    # PATH-shim `bd` so ONLY `bd export` fails (both the mktemp-path and
    # the .beads/-fallback attempts); every other subcommand reaches the
    # real binary untouched -- proves the fatal gate fires even with a
    # perfectly writable TMPDIR, whenever `bd export` itself is what fails.
    local shimdir="$BATS_TEST_TMPDIR/bd-export-fail-shim"
    mkdir -p "$shimdir"
    local real_bd; real_bd=$(command -v bd)
    cat > "$shimdir/bd" <<SHIMEOF
#!/bin/bash
if [ "\$1" = "export" ]; then
    exit 1
fi
exec "$real_bd" "\$@"
SHIMEOF
    chmod +x "$shimdir/bd"

    PATH="$shimdir:$PATH" ensure_beads "$PROJ"

    # Capture failed everywhere -> destruction must be skipped entirely:
    # issues.jsonl untouched, embeddeddolt/ (and the sentinel inside it)
    # survives un-rm'd. The live DB itself was never wiped, so its true
    # count still reads correctly even though the write path (issue_prefix)
    # stays broken until a future successful run.
    [ "$(md5sum "$PROJ/.beads/issues.jsonl" | cut -d' ' -f1)" = "$before_md5" ]
    [ -f "$dbdir/SENTINEL_MUST_SURVIVE" ]
    [ "$(_bd_total)" = "3" ]
    [ "$(_bd_mem_count)" = "2" ]
    run bash -c "cd '$PROJ' && bd create 'should still fail, write path unrepaired' --quiet"
    [ "$status" -ne 0 ]

    # A later run with a working bd export must self-heal completely --
    # the broken-but-intact state is recoverable, not a dead end.
    ensure_beads "$PROJ"
    [ "$(_bd_total)" = "3" ]
    [ "$(_bd_mem_count)" = "2" ]
    (cd "$PROJ" && bd create "post-repair write-path probe" --quiet)
}

@test "beads_claude_docker-9rk: capture-failed escalation does not log a false 'Rebuilt' claim" {
    # Same fixture shape as "escalation capture when bd export itself
    # fails" above -- the point here is not the data-safety outcome (that's
    # already pinned by that test) but the WORDING of the dev-log call: the
    # destructive rm -rf + reinit + import never ran, so the bottom-of-
    # function log must not claim "Rebuilt" just because the untouched,
    # still-broken database happens to report a nonzero pre-existing count.
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Issue present in stale export" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)
    (cd "$PROJ" && bd create "Issue missing from stale export" --quiet)
    id3=$(cd "$PROJ" && bd create "Closed issue missing from stale export" --json | jq -r '.id')
    (cd "$PROJ" && bd close "$id3" --reason "done" --quiet)
    [ "$(_bd_total)" = "3" ]

    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    ( cd "$dbdir" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )

    local shimdir="$BATS_TEST_TMPDIR/bd-export-fail-shim-9rk-log"
    mkdir -p "$shimdir"
    local real_bd; real_bd=$(command -v bd)
    cat > "$shimdir/bd" <<SHIMEOF
#!/bin/bash
if [ "\$1" = "export" ]; then
    exit 1
fi
exec "$real_bd" "\$@"
SHIMEOF
    chmod +x "$shimdir/bd"

    # Override the setup() no-op dev-log stub so this test can inspect what
    # ensure_beads actually LOGS -- route through a sandboxed copy of the
    # REAL /usr/local/bin/dev-log (only its hardcoded LOG_DIR patched to a
    # throwaway dir) rather than a free-text bash-function stub. dev-log's
    # own cmd_run validates the result field strictly (must be literally
    # "pass" or "fail") and renders it verbatim as "exit: $result" in
    # runs.log -- a grep over loose captured argv can't tell "pass" the
    # word in a sentence from "pass" the result field, but a real rendered
    # runs.log can. A shell function still wins name resolution over PATH,
    # so wrap-and-forward to the sandboxed binary by absolute path.
    local fakelog_dir="$BATS_TEST_TMPDIR/fake-claude-logs"
    mkdir -p "$fakelog_dir"
    local devlog_bin="$BATS_TEST_TMPDIR/dev-log-real-logic"
    sed "s#^LOG_DIR=.*#LOG_DIR=\"$fakelog_dir\"#" /usr/local/bin/dev-log > "$devlog_bin"
    chmod +x "$devlog_bin"
    dev-log() { "$devlog_bin" "$@"; }

    PATH="$shimdir:$PATH" ensure_beads "$PROJ"

    # The database's true (untouched) count is still 3 -- confirm the
    # false-positive precondition is actually live in this fixture.
    [ "$(_bd_total)" = "3" ]
    local runslog="$fakelog_dir/runs.log"
    [ -f "$runslog" ]
    cat "$runslog"
    # The run entry must actually have been recorded (never vacuously pass
    # because dev-log rejected a malformed result and wrote nothing).
    grep -q 'command: bd init + bd import' "$runslog"
    grep -q 'reason: Beads database left untouched.*destructive rebuild was skipped' "$runslog"
    ! grep -q 'reason: Rebuilt Beads database' "$runslog"
    # The result FIELD as runs.log actually renders it -- not just the
    # wording -- must say the run failed, never that it passed.
    grep -q '^exit: fail$' "$runslog"
    ! grep -q '^exit: pass$' "$runslog"
}

@test "beads_claude_docker-9rk: a genuine destructive rebuild does log the rebuild claim" {
    # a2s-shaped fixture: live DB genuinely ahead of a stale on-disk export,
    # issue_prefix dropped -> both the ordinary init+import pair fail ->
    # escalation captures the live 3 issues, adopts them, and DOES run the
    # real rm -rf + reinit + import. total ends up nonzero (3) from NEW work
    # this call actually performed, so this is the one case that must still
    # say "Rebuilt".
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Issue present in stale export" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)
    (cd "$PROJ" && bd create "Issue missing from stale export" --quiet)
    id3=$(cd "$PROJ" && bd create "Closed issue missing from stale export" --json | jq -r '.id')
    (cd "$PROJ" && bd close "$id3" --reason "done" --quiet)
    [ "$(_bd_total)" = "3" ]

    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    ( cd "$dbdir" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )
    _backdate_export_state "$PROJ"

    # Symmetric with the capture-failed sibling test above: route through a
    # sandboxed copy of the REAL /usr/local/bin/dev-log (only LOG_DIR
    # patched) instead of a free-text stub, so the assertion below pins the
    # rendered result FIELD ("exit: pass"/"exit: fail"), not just loose
    # argv text -- a regression that flipped this branch to log a "fail"
    # result while still mentioning "Rebuilt" in prose would slip past a
    # grep on wording alone but not past this.
    local fakelog_dir="$BATS_TEST_TMPDIR/fake-claude-logs-real-rebuild"
    mkdir -p "$fakelog_dir"
    local devlog_bin="$BATS_TEST_TMPDIR/dev-log-real-logic-rebuild"
    sed "s#^LOG_DIR=.*#LOG_DIR=\"$fakelog_dir\"#" /usr/local/bin/dev-log > "$devlog_bin"
    chmod +x "$devlog_bin"
    dev-log() { "$devlog_bin" "$@"; }

    ensure_beads "$PROJ"

    [ "$(_bd_total)" = "3" ]
    local runslog="$fakelog_dir/runs.log"
    [ -f "$runslog" ]
    cat "$runslog"
    grep -q 'command: bd init + bd import' "$runslog"
    grep -q 'reason: Rebuilt Beads database from issues.jsonl on startup' "$runslog"
    ! grep -q 'destructive rebuild was skipped' "$runslog"
    # The result FIELD as runs.log actually renders it -- must say the run
    # passed, never that it failed.
    grep -q '^exit: pass$' "$runslog"
    ! grep -q '^exit: fail$' "$runslog"
}

@test "beads_claude_docker-a2s: data-intact but issue_prefix missing is not 'healthy' -- write path fixed and live-ahead data not rolled back" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Issue present in stale export" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)   # export BEFORE the rest -> deliberately stale
    (cd "$PROJ" && bd create "Issue missing from stale export" --quiet)
    id3=$(cd "$PROJ" && bd create "Closed issue missing from stale export" --json | jq -r '.id')
    (cd "$PROJ" && bd close "$id3" --reason "done" --quiet)

    local ground_truth="$BATS_TEST_TMPDIR/a2s-ground-truth.txt"
    (cd "$PROJ" && bd list --all --flat) > "$ground_truth"
    [ "$(_bd_total)" = "3" ]

    # Corrupt the write path directly (never via bd, which would heal it):
    # remove the issue_prefix config row while leaving all 3 real issues
    # (incl. the closed one) untouched in the live DB, and leave the
    # on-disk export deliberately stale (1 issue, not 3) -- a live DB
    # legitimately ahead of its last export.
    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    ( cd "$dbdir" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )
    _backdate_export_state "$PROJ"

    # A count-only health check would call this healthy right here: the
    # table still reports 3. It is not -- the write path is broken.
    [ "$(_bd_total)" = "3" ]
    run bash -c "cd '$PROJ' && bd create 'should fail before the fix' --quiet"
    [ "$status" -ne 0 ]

    ensure_beads "$PROJ"

    # issues.jsonl must never be deleted, and by now it legitimately gets
    # REWRITTEN (the on-disk copy was stale) -- assert correctness via the
    # actual issue list (incl. the closed issue), not a byte checksum.
    [ -s "$PROJ/.beads/issues.jsonl" ]
    diff "$ground_truth" <(cd "$PROJ" && bd list --all --flat)

    # The write path must actually be fixed, not just the count.
    (cd "$PROJ" && bd create "post-repair write-path probe" --quiet)

    # This shape reaches the same embeddeddolt-removal escalation as cx8
    # (bd init refuses "already initialized", bd import fails on the
    # missing issue_prefix) -- so the 2 starter memories were just as much
    # at risk here as in cx8, and must survive too.
    [ "$(_bd_mem_count)" = "2" ]
}

@test "the embeddeddolt-removal escalation never fires on a healthy database" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Real issue" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)

    # A sentinel planted inside embeddeddolt/ is direct, mtime-independent
    # proof the destructive `rm -rf` never ran: dolt's own commit machinery
    # touches files it manages, but it will never touch this one.
    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    touch "$dbdir/SENTINEL_MUST_SURVIVE"

    local before_md5
    before_md5=$(md5sum "$PROJ/.beads/issues.jsonl" | cut -d' ' -f1)

    ensure_beads "$PROJ"
    ensure_beads "$PROJ"   # twice, matching the existing idempotency test

    [ -f "$dbdir/SENTINEL_MUST_SURVIVE" ]
    [ "$(_bd_total)" = "1" ]

    # On the healthy no-op path, ensure_beads only ever copies issues.jsonl
    # aside and deletes the copy -- the live file must be byte-identical.
    local after_md5
    after_md5=$(md5sum "$PROJ/.beads/issues.jsonl" | cut -d' ' -f1)
    [ "$before_md5" = "$after_md5" ]
}

@test "beads_claude_docker-9rk: _beads_issue_prefix reads a real prefix and a genuinely-empty-but-present prefix correctly" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"

    local expected_prefix
    expected_prefix=$(detect_beads_prefix "$PROJ")
    local got
    got=$(_beads_issue_prefix "$PROJ")
    [ -n "$got" ]
    [ "$got" != "__unknown__" ]
    [ "$got" = "$expected_prefix" ]

    # Delete the config row directly with dolt sql (real corruption, same
    # technique as the a2s/cx8 fixtures) -- empirically confirmed this makes
    # `bd config get issue_prefix --json` return {"value":""} with exit 0, a
    # genuinely-empty-but-PRESENT "value" key. Must still read back as ""
    # (confirmed-empty), not the __unknown__ failure sentinel.
    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    ( cd "$dbdir" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )
    got=$(_beads_issue_prefix "$PROJ")
    [ "$got" = "" ]
}

@test "beads_claude_docker-9rk: a jq that exits 0 with empty output reads as __unknown__, never ''" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"

    # Blanket-shim jq to always exit 0 printing nothing, regardless of
    # input -- simulates "a jq that exits 0 with empty output" directly
    # against the probe. Scoped to a command-substitution subshell so the
    # PATH override can never leak into the rest of this test.
    local shimdir="$BATS_TEST_TMPDIR/jq-silent-shim"
    mkdir -p "$shimdir"
    cat > "$shimdir/jq" <<'SHIMEOF'
#!/bin/bash
exit 0
SHIMEOF
    chmod +x "$shimdir/jq"

    local got
    got=$(PATH="$shimdir:$PATH" _beads_issue_prefix "$PROJ")
    [ "$got" = "__unknown__" ]
    [ "$got" != "" ]
}

@test "beads_claude_docker-9rk: a bd response missing the 'value' key (shape drift) reads as __unknown__, never ''" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"

    # Shim `bd` so `bd config get issue_prefix --json` returns valid JSON
    # that lacks the "value" key entirely (a future bd renaming it) --
    # every other subcommand reaches the real binary untouched.
    local shimdir="$BATS_TEST_TMPDIR/bd-shape-drift-shim"
    mkdir -p "$shimdir"
    local real_bd; real_bd=$(command -v bd)
    cat > "$shimdir/bd" <<SHIMEOF
#!/bin/bash
if [ "\$1" = "config" ] && [ "\$2" = "get" ] && [ "\$3" = "issue_prefix" ]; then
    echo '{"key":"issue_prefix","schema_version":1}'
    exit 0
fi
exec "$real_bd" "\$@"
SHIMEOF
    chmod +x "$shimdir/bd"

    local got
    got=$(PATH="$shimdir:$PATH" _beads_issue_prefix "$PROJ")
    [ "$got" = "__unknown__" ]
    [ "$got" != "" ]
}

@test "beads_claude_docker-9rk: a forged empty-prefix probe (bd exits 0 printing nothing) cannot force the destructive embeddeddolt-removal path open" {
    # cx8-shaped fixture: issue_prefix row AND the issues table both wiped,
    # so total=0 and the ordinary init+import pair genuinely both fail --
    # the escalation is reached for real, exactly as in the cx8 test. Only
    # the PROBE's own read of issue_prefix is additionally forged.
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Will be wiped" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)

    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    ( cd "$dbdir" \
      && dolt sql -q "delete from config where \`key\`='issue_prefix'" \
      && dolt sql -q "delete from issue_snapshots" \
      && dolt sql -q "delete from events" \
      && dolt sql -q "delete from comments" \
      && dolt sql -q "delete from dependencies" \
      && dolt sql -q "delete from labels" \
      && dolt sql -q "delete from issues" )
    printf '{"_type":"issue","id":"cx8fix-xxx","status":"open"}\n' > "$PROJ/.beads/issues.jsonl"
    _backdate_export_state "$PROJ"

    # Sentinel inside embeddeddolt/ -- direct, mtime-independent proof the
    # destructive rm -rf never ran.
    touch "$dbdir/SENTINEL_MUST_SURVIVE"

    local shimdir="$BATS_TEST_TMPDIR/bd-empty-prefix-shim"
    mkdir -p "$shimdir"
    local real_bd; real_bd=$(command -v bd)
    cat > "$shimdir/bd" <<SHIMEOF
#!/bin/bash
if [ "\$1" = "config" ] && [ "\$2" = "get" ] && [ "\$3" = "issue_prefix" ]; then
    exit 0
fi
exec "$real_bd" "\$@"
SHIMEOF
    chmod +x "$shimdir/bd"

    PATH="$shimdir:$PATH" ensure_beads "$PROJ"

    # Pre-fix, this forged "" would have been read as confirmed-empty and
    # unlocked the rm -rf; post-fix it must read as __unknown__ so the
    # destructive path stays closed -- sentinel and embeddeddolt/ survive.
    [ -f "$dbdir/SENTINEL_MUST_SURVIVE" ]
    [ -d "$PROJ/.beads/embeddeddolt" ]
}

@test "beads_claude_docker-9rk: a forged empty-prefix probe (missing value key) cannot force the destructive embeddeddolt-removal path open" {
    # Same cx8-shaped fixture as above; this time the forgery is shape
    # drift (a "value"-less bd response) rather than silent-empty output --
    # exercises the OTHER half of the probe's OR-gated failure check.
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Will be wiped" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)

    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    ( cd "$dbdir" \
      && dolt sql -q "delete from config where \`key\`='issue_prefix'" \
      && dolt sql -q "delete from issue_snapshots" \
      && dolt sql -q "delete from events" \
      && dolt sql -q "delete from comments" \
      && dolt sql -q "delete from dependencies" \
      && dolt sql -q "delete from labels" \
      && dolt sql -q "delete from issues" )
    printf '{"_type":"issue","id":"cx8fix-xxx","status":"open"}\n' > "$PROJ/.beads/issues.jsonl"
    _backdate_export_state "$PROJ"

    touch "$dbdir/SENTINEL_MUST_SURVIVE"

    local shimdir="$BATS_TEST_TMPDIR/bd-shape-drift-shim-e2e"
    mkdir -p "$shimdir"
    local real_bd; real_bd=$(command -v bd)
    cat > "$shimdir/bd" <<SHIMEOF
#!/bin/bash
if [ "\$1" = "config" ] && [ "\$2" = "get" ] && [ "\$3" = "issue_prefix" ]; then
    echo '{"key":"issue_prefix","schema_version":1}'
    exit 0
fi
exec "$real_bd" "\$@"
SHIMEOF
    chmod +x "$shimdir/bd"

    PATH="$shimdir:$PATH" ensure_beads "$PROJ"

    [ -f "$dbdir/SENTINEL_MUST_SURVIVE" ]
    [ -d "$PROJ/.beads/embeddeddolt" ]
}

@test "ensure_beads's rebuild path never calls read (no prompt possible)" {
    ! grep -q '^\s*read ' "$BATS_TEST_TMPDIR/entrypoint-functions.sh"
}

@test "bd doctor is gone from ensure_beads" {
    ! grep -q 'bd doctor' "$BATS_TEST_TMPDIR/entrypoint-functions.sh"
}

@test "launcher's teardown flush passes -o so it actually writes issues.jsonl (not just stdout)" {
    grep -q -- '-o \.beads/issues\.jsonl' "$LAUNCHER_SRC"
}

@test "built copy .claude-dev/scripts/entrypoint.sh carries the same ensure_beads fix" {
    local built="$REPO_DIR/.claude-dev/scripts/entrypoint.sh"
    local src="$ENTRYPOINT_SRC"
    [ -f "$built" ] || skip "no built copy present"
    # .claude-dev/ is a gitignored nested clone refreshed only by a
    # host-side rebuild -- it can legitimately lag behind the repo source
    # in-container. Only assert against it when it's caught up (equal
    # mtimes count as current: a rebuild using `cp -p` preserves the
    # source's mtime, and treating that as stale would make this
    # unreachable forever); a genuinely stale copy skips rather than fails,
    # so the suite can exit 0 in-container (beads_claude_docker-9rk).
    if [ "$src" -nt "$built" ]; then
        skip "built copy is stale ($built older than $src); refresh via host-side rebuild"
    fi
    grep -q 'total_issues // 0' "$built"
    # bd doctor is still named in the explanatory comment (documenting what's
    # NOT used and why) -- assert it is no longer CALLED anywhere in real
    # code, not just absent in one specific old invocation shape. A literal
    # '(cd "$dir" && bd doctor' pattern is too narrow: the stale pre-fix
    # copy's call is `(cd /workspace && bd doctor --fix --yes)` -- hardcoded
    # /workspace, never $dir -- so that pattern never matches it regardless
    # of whether the call is still present. Strip comment lines (anything
    # whose first non-blank character is #) and check for ANY remaining
    # mention of the command, so any invocation syntax is caught.
    ! grep -vE '^[[:space:]]*#' "$built" | grep -q 'bd doctor'
}

# ---------------------------------------------------------------------------
# beads_claude_docker-8zo: four degraded/adversarial shapes driven for real in
# a throwaway sandbox (never against /workspace/.beads), each pinned here
# after being reproduced independently outside this suite. See the comments
# at the corresponding code sites in scripts/entrypoint.sh for what was
# actually observed and why each was handled the way it was.
# ---------------------------------------------------------------------------

@test "beads_claude_docker-8zo: a failing-but-present dolt has no effect (bd never execs it); a truly absent dolt correctly no-ops instead" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Issue present in stale export" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)
    (cd "$PROJ" && bd create "Issue missing from stale export" --quiet)
    id3=$(cd "$PROJ" && bd create "Closed issue missing from stale export" --json | jq -r '.id')
    (cd "$PROJ" && bd close "$id3" --reason "done" --quiet)
    local ground_truth="$BATS_TEST_TMPDIR/dolt-fail-ground-truth.txt"
    (cd "$PROJ" && bd list --all --flat) > "$ground_truth"
    [ "$(_bd_total)" = "3" ]

    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    ( cd "$dbdir" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )
    _backdate_export_state "$PROJ"

    # Half 1: a `dolt` that EXISTS on PATH but exits nonzero on every
    # invocation, shadowing the real one throughout a full destructive
    # rebuild, logging every call it receives.
    local shimdir="$BATS_TEST_TMPDIR/failing-dolt-shim"
    mkdir -p "$shimdir"
    local invocation_log="$BATS_TEST_TMPDIR/dolt-invocations.log"
    : > "$invocation_log"
    cat > "$shimdir/dolt" <<SHIMEOF
#!/bin/bash
echo "\$*" >> "$invocation_log"
exit 1
SHIMEOF
    chmod +x "$shimdir/dolt"

    PATH="$shimdir:$PATH" ensure_beads "$PROJ"

    # bd 1.0.4 embeds Dolt directly; it never execs the external binary for
    # any command ensure_beads uses -- confirmed by an empty invocation log
    # even though the failing shim was first on PATH throughout, AND the
    # rebuild still fully succeeded (issues + memories both recovered).
    [ ! -s "$invocation_log" ]
    [ "$(_bd_total)" = "3" ]
    diff "$ground_truth" <(cd "$PROJ" && bd list --all --flat)
    [ "$(_bd_mem_count)" = "2" ]

    # Half 2 (this is what proves Half 1 isn't vacuous): dolt TRULY ABSENT
    # from PATH -- not merely broken -- does change the outcome. The
    # `command -v dolt` gate fires and ensure_beads returns before creating
    # anything, on a fresh project it would otherwise have initialized.
    local proj2="$BATS_TEST_TMPDIR/proj-no-dolt"
    mkdir -p "$proj2"
    git -C "$proj2" init --quiet
    local nodoltdir="$BATS_TEST_TMPDIR/no-dolt-path"
    mkdir -p "$nodoltdir"
    for tool in bd jq git; do ln -sf "$(command -v "$tool")" "$nodoltdir/$tool"; done
    PATH="$nodoltdir" ensure_beads "$proj2"
    [ ! -d "$proj2/.beads" ]
}

@test "beads_claude_docker-8zo: a symlinked embeddeddolt is bailed out on before any bd command runs; real data and the symlink itself survive untouched" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Healthy issue" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)
    [ "$(_bd_total)" = "1" ]

    # Move the real embeddeddolt out and replace it with a symlink pointing
    # to it -- the data itself is never touched, only its reachability via
    # .beads/embeddeddolt changes shape.
    local realdb="$BATS_TEST_TMPDIR/embeddeddolt-real"
    mv "$PROJ/.beads/embeddeddolt" "$realdb"
    ln -s "$realdb" "$PROJ/.beads/embeddeddolt"

    local shimdir="$BATS_TEST_TMPDIR/bd-argv-shim"
    mkdir -p "$shimdir"
    local real_bd; real_bd=$(command -v bd)
    local argv_log="$BATS_TEST_TMPDIR/bd-argv.log"
    : > "$argv_log"
    cat > "$shimdir/bd" <<SHIMEOF
#!/bin/bash
echo "\$*" >> "$argv_log"
exec "$real_bd" "\$@"
SHIMEOF
    chmod +x "$shimdir/bd"

    PATH="$shimdir:$PATH" ensure_beads "$PROJ"

    # No bd command was ever invoked -- the guard fires first, before the
    # very first health-check `bd status --json`.
    [ ! -s "$argv_log" ]
    # The symlink itself is untouched (same target, still a symlink).
    [ -L "$PROJ/.beads/embeddeddolt" ]
    [ "$(readlink "$PROJ/.beads/embeddeddolt")" = "$realdb" ]
    # The real data, accessed directly (never via bd, to avoid the very
    # project-root confusion under test), is untouched.
    local dbdir; dbdir=$(find "$realdb" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ "$(cd "$dbdir" && dolt sql -q 'select count(*) from issues' -r csv | tail -1)" = "1" ]
    # No stray "embeddeddolt/beads"-style database appeared in the symlink
    # TARGET's parent ($BATS_TEST_TMPDIR here, since $realdb is placed
    # directly under it) -- the empirically observed failure mode when bd's
    # own project-root resolution gets lost chasing the symlink target
    # (confirmed to follow the TARGET specifically, not $PROJ, by re-running
    # with the target relocated somewhere structurally unrelated to $PROJ;
    # this fixture places them as siblings, so this one assertion can't by
    # itself distinguish the two, but the guard fires before any bd call
    # regardless of where either lives).
    [ ! -e "$BATS_TEST_TMPDIR/embeddeddolt" ]
}

@test "beads_claude_docker-8zo: the observed SIGTERM-interrupted end-state recovers issues on the next run but not memories, without deleting the stray capture" {
    # CHARACTERIZATION / regression test, not a guard on a mechanism this
    # bead's diff introduces -- flagged in verification, recorded honestly
    # here rather than left to look like more than it is. It constructs the
    # on-disk state a real SIGTERM was independently driven into and
    # observed to produce (see the comment above the destructive rm -rf in
    # scripts/entrypoint.sh): embeddeddolt already removed, issues.jsonl
    # already holding the adopted capture (that cp runs BEFORE rm -rf), and
    # the capture's own memories file left behind, uncleaned, because the
    # process died before the memory-restore/cleanup steps could run.
    # Constructed directly rather than raced with a real signal, per this
    # bead's own instruction that bats can't reliably arbitrate a timing
    # race -- the race itself was driven standalone, outside this suite, and
    # reported separately.
    #
    # What this test DOES pin, with a real mutation-kill: the "issues
    # self-heal completely" assertion below (`_bd_total` = 3, then the
    # `diff` against ground truth) exercises the actual repair path this
    # bead wraps in a lock -- forcing an early `exit 0` right after lock
    # acquisition (a mutation of this diff's own code) turns it red. The
    # `_bd_mem_count` = 0 assertion right after it is ALSO genuinely
    # DB-dependent and killable by that same mutation (with embeddeddolt
    # never rebuilt, `bd memories --json` has no database to query and
    # `_bd_mem_count` reads back empty, not "0") -- confirmed by neutralizing
    # the two assertions above it and re-running the same `exit 0` mutation
    # in isolation: `_bd_mem_count` = 0 failed on its own. In the unmodified
    # test it is normally shadowed (bats stops at the first failing
    # assertion, and `_bd_total` = 3 fails first), which is why it can look
    # unkillable without actually being so -- it has real guard value here,
    # just not independent visibility.
    #
    # What genuinely CANNOT be killed by any mutation of this diff: the
    # three `$fresh_memories` assertions below (file exists, and both
    # remembered strings are still in it). `$fresh_memories` is a file this
    # TEST constructs to simulate a stray leftover from a hypothetical prior
    # run; no code in entrypoint.sh reads, writes, or deletes that exact
    # path in THIS invocation, so no mutation of this diff can touch them --
    # confirmed in verification (reverting the SIGTERM breadcrumb wording,
    # or deleting the touch bail-out entirely, both left this test green).
    # Those three still have value as a characterization of the end-to-end
    # recovery behavior described in the entrypoint.sh comment, just not as
    # a guard -- the breadcrumb wording and the lock-tier fallback are
    # pinned separately below, each with its own real mutation-kill.
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"   # case A: seeds prefix + 2 starter memories
    (cd "$PROJ" && bd create "Issue present in stale export" --quiet)
    (cd "$PROJ" && bd create "Issue missing from stale export" --quiet)
    id3=$(cd "$PROJ" && bd create "Closed issue missing from stale export" --json | jq -r '.id')
    (cd "$PROJ" && bd close "$id3" --reason "done" --quiet)
    local ground_truth="$BATS_TEST_TMPDIR/sigterm-ground-truth.txt"
    (cd "$PROJ" && bd list --all --flat) > "$ground_truth"
    [ "$(_bd_total)" = "3" ]
    [ "$(_bd_mem_count)" = "2" ]

    # The pre-destruction capture: a real `bd export --include-memories`,
    # exactly as the escalation itself performs, split the same way.
    local fresh_export="$BATS_TEST_TMPDIR/beads-issues-fresh.SIMULATED"
    (cd "$PROJ" && bd export --include-memories --quiet -o "$fresh_export")
    [ -s "$fresh_export" ]
    local fresh_memories="${fresh_export}.memories"
    jq -c 'select(._type == "memory")' "$fresh_export" > "$fresh_memories"
    [ -s "$fresh_memories" ]

    # The adoption that runs BEFORE rm -rf: issues.jsonl already reflects
    # the full captured set (already true here, from the earlier export).
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)
    local issues_md5_before; issues_md5_before=$(md5sum "$PROJ/.beads/issues.jsonl" | cut -d' ' -f1)

    # The destructive rm -rf itself, already complete -- this is the exact
    # filesystem state observed right after driving a real SIGTERM into that
    # call and letting the process die.
    rm -rf "$PROJ/.beads/embeddeddolt"
    [ ! -d "$PROJ/.beads/embeddeddolt" ]

    ensure_beads "$PROJ"   # "the next start"

    # Issues self-heal completely.
    [ "$(_bd_total)" = "3" ]
    diff "$ground_truth" <(cd "$PROJ" && bd list --all --flat)
    # Memories do NOT come back automatically -- the live DB was wiped
    # before the memory-restore step ever ran, and ensure_beads has no
    # mechanism to notice an orphaned capture file from a run it didn't
    # itself perform.
    [ "$(_bd_mem_count)" = "0" ]
    # But the captured memories are not silently destroyed either: the
    # stray file survives, byte-identical, available for a manual
    # `bd import`.
    [ -f "$fresh_memories" ]
    grep -q 'never-assign-beads-to-a-user-they-are' "$fresh_memories"
    grep -q 'code-changes-must-be-tested-in-realistic-settings' "$fresh_memories"
}

@test "beads_claude_docker-8zo: the pre-destruction log names the live capture's paths, so an interrupted run leaves an actionable breadcrumb in errors.log" {
    # Pins the SIGTERM hardening itself (scripts/entrypoint.sh's dev-log
    # call immediately before the destructive rm -rf): flagged in
    # verification as shipped without a test -- reverting the message to
    # its pre-hardening wording left the suite green. Real mutation-kill
    # below.
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Issue present in stale export" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)
    (cd "$PROJ" && bd create "Issue missing from stale export" --quiet)
    id3=$(cd "$PROJ" && bd create "Closed issue missing from stale export" --json | jq -r '.id')
    (cd "$PROJ" && bd close "$id3" --reason "done" --quiet)
    [ "$(_bd_total)" = "3" ]

    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    ( cd "$dbdir" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )
    _backdate_export_state "$PROJ"

    # Sandboxed real dev-log (only LOG_DIR patched), same technique as the
    # 9rk rebuild-claim tests above, so this reads the actually-rendered
    # errors.log rather than a loose captured-argv stub.
    local fakelog_dir="$BATS_TEST_TMPDIR/fake-claude-logs-breadcrumb"
    mkdir -p "$fakelog_dir"
    local devlog_bin="$BATS_TEST_TMPDIR/dev-log-real-logic-breadcrumb"
    sed "s#^LOG_DIR=.*#LOG_DIR=\"$fakelog_dir\"#" /usr/local/bin/dev-log > "$devlog_bin"
    chmod +x "$devlog_bin"
    dev-log() { "$devlog_bin" "$@"; }

    ensure_beads "$PROJ"

    [ "$(_bd_total)" = "3" ]
    local errslog="$fakelog_dir/errors.log"
    [ -f "$errslog" ]
    cat "$errslog"
    # The three capture paths (combined export, issues split, memories
    # split) all actually appear, and the manual-recovery command is
    # spelled out -- not just "removing embeddeddolt and rebuilding" with
    # no further detail.
    grep -q 'live capture at .*beads-issues-fresh' "$errslog"
    grep -q 'issues at .*beads-issues-fresh.*\.issues' "$errslog"
    grep -q 'memories at .*beads-issues-fresh.*\.memories' "$errslog"
    grep -q "bd import .*beads-issues-fresh.*\.memories" "$errslog"
}

@test "beads_claude_docker-8zo: lock acquisition degrades through three tiers rather than bailing out -- tier 1 (.beads/), tier 2 (deterministic TMPDIR fallback), and unlocked-but-still-repairing when neither is writable" {
    # REGRESSION CAUGHT IN VERIFICATION: the first version of the
    # concurrency fix bailed out of repair entirely (`return 0`, no repair
    # attempted) whenever `touch "$dir/.beads/.ensure_beads.lock"` failed --
    # a real loss of function on a project whose .beads/ directory is
    # read-only but whose embeddeddolt subtree and issues.jsonl are still
    # writable (a real, reachable shape: `rm -rf` can empty a directory's
    # CONTENTS without write permission on the PARENT needed to unlink the
    # directory entry itself, so this exact fixture repaired successfully at
    # HEAD before this bead). Tests all three tiers the fix now degrades
    # through.
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Issue" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)
    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    ( cd "$dbdir" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )
    _backdate_export_state "$PROJ"
    [ "$(_bd_total)" = "1" ]

    # --- Tier 1: normal, writable .beads/ -- the lockfile actually lands there. ---
    ensure_beads "$PROJ"
    [ "$(_bd_total)" = "1" ]
    (cd "$PROJ" && bd create "post-repair write-path probe (tier 1)" --quiet)
    [ -f "$PROJ/.beads/.ensure_beads.lock" ]

    # --- Tier 2: .beads/ read-only (tier 1's touch fails), TMPDIR writable
    # -- repair must still complete via a deterministic, per-project TMPDIR
    # lock file, not a bail-out. ---
    local proj2="$BATS_TEST_TMPDIR/proj-tier2"
    mkdir -p "$proj2"
    git -C "$proj2" init --quiet
    ensure_beads "$proj2"
    (cd "$proj2" && bd create "Issue" --quiet)
    (cd "$proj2" && bd export -o .beads/issues.jsonl --quiet)
    local dbdir2; dbdir2=$(_dolt_dir_for "$proj2")
    ( cd "$dbdir2" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )
    _backdate_export_state "$proj2"
    chmod a-w "$proj2/.beads"

    local devlog2="$BATS_TEST_TMPDIR/devlog-tier2.txt"
    : > "$devlog2"
    dev-log() { printf '%s\n' "$*" >> "$devlog2"; }
    ensure_beads "$proj2"
    chmod u+w "$proj2/.beads"   # restore so bats can clean up, and so we can probe below

    [ "$(cd "$proj2" && bd status --json | jq -r '.summary.total_issues')" = "1" ]
    (cd "$proj2" && bd create "post-repair write-path probe (tier 2)" --quiet)
    # Tier 1 must NOT have been used (the directory was read-only).
    [ ! -f "$proj2/.beads/.ensure_beads.lock" ]
    # The deterministic TMPDIR lock file must exist and be reproducible from
    # the project's own absolute path -- NOT a mktemp'd, invocation-unique
    # name (a mktemp'd tier 2 would make concurrent runs lock different
    # files, silently defeating mutual exclusion while still looking
    # protected -- this is why it must be deterministic, not merely present).
    # Hashed the SAME way production does (`(cd "$dir" && pwd -P)`, the
    # PHYSICAL path with symlinks resolved) rather than the raw $proj2
    # string -- they happen to coincide here since $BATS_TEST_TMPDIR isn't
    # itself a symlink, but hashing the unresolved string would silently
    # drift from production the moment that stopped being true.
    local expected_dir_abs expected_hash expected_lock
    expected_dir_abs=$( (cd "$proj2" 2>/dev/null && pwd -P) 2>/dev/null ) || expected_dir_abs="$proj2"
    expected_hash=$(printf '%s' "$expected_dir_abs" | cksum | cut -d' ' -f1)
    expected_lock="${TMPDIR:-/tmp}/beads-ensure-lock.$expected_hash"
    [ -f "$expected_lock" ]
    rm -f "$expected_lock"

    # --- Tier 3: BOTH .beads/ and TMPDIR unwritable. Both of the lock's own
    # tiers need exactly the same two resources safety_copy's pre-existing,
    # protected two-tier fallback already needs (TMPDIR for its mktemp
    # first choice, .beads for its own fallback) -- so this exact
    # combination ALSO makes safety_copy's own bail-out fire, entirely
    # independently of the lock. That's correct, not a gap: "unrepaired
    # beats unprotected" is safety_copy's call to make, not the lock's, and
    # this bead must not touch that gate. What's actually under test here is
    # narrower and still real: the lock degrades all the way to logging
    # "running WITHOUT concurrency protection" and lets execution CONTINUE
    # into the repair body, rather than short-circuiting with its own
    # `return 0` the moment neither tier is writable (the exact regression
    # caught in verification for the .beads-only case above). Proof that it
    # reached the body: the SEPARATE, pre-existing safety_copy message is
    # ALSO present -- if the lock still bailed out early, only the lock's
    # own message would appear and safety_copy's would not, since the code
    # would never reach it.
    local proj3="$BATS_TEST_TMPDIR/proj-tier3"
    mkdir -p "$proj3"
    git -C "$proj3" init --quiet
    ensure_beads "$proj3"
    (cd "$proj3" && bd create "Issue" --quiet)
    (cd "$proj3" && bd export -o .beads/issues.jsonl --quiet)
    local dbdir3; dbdir3=$(_dolt_dir_for "$proj3")
    ( cd "$dbdir3" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )
    _backdate_export_state "$proj3"
    local issues_before; issues_before=$(cat "$proj3/.beads/issues.jsonl")
    chmod a-w "$proj3/.beads"
    local ro_tmp="$BATS_TEST_TMPDIR/tier3-ro-tmp"
    mkdir -p "$ro_tmp"
    chmod a-w "$ro_tmp"

    local devlog3="$BATS_TEST_TMPDIR/devlog-tier3.txt"
    : > "$devlog3"
    dev-log() { printf '%s\n' "$*" >> "$devlog3"; }
    TMPDIR="$ro_tmp" ensure_beads "$proj3"
    chmod u+w "$proj3/.beads" "$ro_tmp"

    cat "$devlog3"
    grep -q 'running repair WITHOUT concurrency protection' "$devlog3"
    grep -q 'cannot create a safety copy of issues.jsonl' "$devlog3"
    # Nothing was lost: issues.jsonl is exactly what it was before this run
    # -- safety_copy's bail-out means repair was correctly skipped, not that
    # data went missing.
    [ "$(cat "$proj3/.beads/issues.jsonl")" = "$issues_before" ]
}

@test "beads_claude_docker-8zo: concurrent invocations serialize via flock -- a contended run skips entirely rather than touching anything" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Sentinel-bearing issue" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)
    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    touch "$dbdir/SENTINEL_MUST_SURVIVE_IF_LOCKED"
    [ "$(_bd_total)" = "1" ]

    local lockfile="$PROJ/.beads/.ensure_beads.lock"
    # Hold the lock externally in a real background process, exactly the
    # way a concurrent ensure_beads invocation would hold it.
    ( exec 8>"$lockfile"; flock 8; sleep 5 ) &
    local holder_pid=$!
    sleep 0.3   # let the holder actually acquire the lock before racing it

    local devlog="$BATS_TEST_TMPDIR/devlog-contention.txt"
    : > "$devlog"
    dev-log() { printf '%s\n' "$*" >> "$devlog"; }

    ensure_beads "$PROJ"

    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true

    cat "$devlog"
    grep -q 'another instance is already repairing' "$devlog"
    # The contended run touched nothing at all: sentinel survives, count
    # unchanged (still whatever it was before -- not even the harmless
    # read-only health check ran).
    [ -f "$dbdir/SENTINEL_MUST_SURVIVE_IF_LOCKED" ]
    [ "$(_bd_total)" = "1" ]
}

# $1 = project dir -> prints the deterministic tier-2 lock path production
# would compute for it, given the current $TMPDIR. Mirrors the formula at
# entrypoint.sh's tier-2 fallback (and the inline computation the tier-2
# section of the three-tier test above already duplicates).
_xgm_tier2_lock_path() {
    local dir_abs dir_hash
    dir_abs=$( (cd "$1" 2>/dev/null && pwd -P) 2>/dev/null ) || dir_abs="$1"
    dir_hash=$(printf '%s' "$dir_abs" | cksum 2>/dev/null | cut -d' ' -f1)
    printf '%s/beads-ensure-lock.%s' "${TMPDIR:-/tmp}" "$dir_hash"
}

# beads_claude_docker-xgm: a REAL bash subprocess with set -e active is
# required to observe this -- bats' own `run` still spawns one (that part is
# fine), but sourcing the extracted functions directly into bats' own test
# shell, the way the rest of this file's tests do for convenience, is NOT
# equivalent: it never reproduces entrypoint.sh's own top-level `set -e` +
# bare, unguarded `ensure_beads` call aborting the REST OF THE SCRIPT before
# `exec "$@"`. So this test (and the one below) builds a standalone runner
# script -- sourcing the SAME extracted entrypoint-functions.sh setup()
# already wrote, structured exactly like entrypoint.sh itself (set -e, a
# bare ensure_beads call, more code after it standing in for the remainder
# through exec) -- and drives it with `run bash`, a genuine child process.
@test "beads_claude_docker-xgm: tier-1 lock probes OPENABILITY, not just creatability -- a same-user mode-000 pre-existing lockfile no longer aborts entrypoint.sh under set -e" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Issue" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)
    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    ( cd "$dbdir" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )
    _backdate_export_state "$PROJ"
    [ "$(_bd_total)" = "1" ]

    # Owner may set a file's timestamps without holding write permission on
    # it -- `touch` on this file SUCCEEDS despite mode 000, which is exactly
    # the gap the old creatability-only probe missed.
    : > "$PROJ/.beads/.ensure_beads.lock"
    chmod 000 "$PROJ/.beads/.ensure_beads.lock"
    touch "$PROJ/.beads/.ensure_beads.lock" 2>/dev/null \
        || skip "precondition not met: touch did not succeed on the mode-000 lockfile in this environment"

    local devlog="$BATS_TEST_TMPDIR/devlog-xgm-tier1.txt"
    : > "$devlog"
    cat > "$BATS_TEST_TMPDIR/runner-xgm-tier1.sh" <<EOF
#!/bin/bash
set -e
dev-log() { printf '%s\n' "\$*" >> "$devlog"; }
source "$BATS_TEST_TMPDIR/entrypoint-functions.sh"
ensure_beads "$PROJ"
echo XGM_END
EOF
    run bash "$BATS_TEST_TMPDIR/runner-xgm-tier1.sh"

    echo "$output"
    cat "$devlog"
    # Before the fix: status 1, no XGM_END, "Permission denied" from the
    # subshell's own bare `9>"$lockfile"` -- entrypoint.sh would have
    # aborted here, before its final `exec "$@"`.
    [ "$status" -eq 0 ]
    [[ "$output" == *"XGM_END"* ]]

    # The mode-000 tier-1 file was correctly recognized as unopenable and
    # left alone -- never truncated by a successful `9>` open. Checked
    # BEFORE the chmod u+w restore below, which would otherwise mask this.
    [ "$(stat -c '%s %a' "$PROJ/.beads/.ensure_beads.lock")" = "0 0" ]
    chmod u+w "$PROJ/.beads/.ensure_beads.lock"   # restore so bats can clean up

    # Tier 2 (TMPDIR) is what actually got used.
    local lock2; lock2=$(_xgm_tier2_lock_path "$PROJ")
    [ -f "$lock2" ]
    rm -f "$lock2"

    # Not just "didn't crash" -- the repair actually ran and succeeded: the
    # write path works again, proven the same way the ordinary tier-1 test
    # above proves it (a real `bd create`), not by asserting a literal
    # prefix string (which would depend on this container's own
    # $CLAUDE_PROJECT_NAME rather than on the fix under test).
    [ "$(_bd_total)" = "1" ]
    (cd "$PROJ" && bd create "post-repair write-path probe (xgm tier1)" --quiet)
    [ "$(_bd_total)" = "2" ]
}

@test "beads_claude_docker-xgm: tier-2 (TMPDIR) lock gets the same openability probe -- a same-user mode-000 pre-existing tier-2 lockfile falls through to tier 3 instead of aborting" {
    local t2proj="$BATS_TEST_TMPDIR/proj-xgm-tier2"
    mkdir -p "$t2proj"
    git -C "$t2proj" init --quiet
    ensure_beads "$t2proj"
    (cd "$t2proj" && bd create "Issue" --quiet)
    (cd "$t2proj" && bd export -o .beads/issues.jsonl --quiet)
    local dbdir2; dbdir2=$(_dolt_dir_for "$t2proj")
    ( cd "$dbdir2" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )
    _backdate_export_state "$t2proj"
    [ "$(cd "$t2proj" && bd status --json | jq -r '.summary.total_issues')" = "1" ]

    # Force tier 1 to legitimately fail over (read-only .beads/, the SAME
    # mechanism the ordinary tier-2 path above uses) -- not the bug shape by
    # itself. The bug shape is layered on top, at tier 2.
    chmod a-w "$t2proj/.beads"

    local lock2; lock2=$(_xgm_tier2_lock_path "$t2proj")
    : > "$lock2"
    chmod 000 "$lock2"
    touch "$lock2" 2>/dev/null \
        || { chmod u+w "$t2proj/.beads"; skip "precondition not met: touch did not succeed on the mode-000 tier-2 lockfile in this environment"; }

    local devlog="$BATS_TEST_TMPDIR/devlog-xgm-tier2.txt"
    : > "$devlog"
    cat > "$BATS_TEST_TMPDIR/runner-xgm-tier2.sh" <<EOF
#!/bin/bash
set -e
dev-log() { printf '%s\n' "\$*" >> "$devlog"; }
source "$BATS_TEST_TMPDIR/entrypoint-functions.sh"
ensure_beads "$t2proj"
echo XGM_END
EOF
    run bash "$BATS_TEST_TMPDIR/runner-xgm-tier2.sh"
    chmod u+w "$t2proj/.beads"   # restore so bats can clean up

    echo "$output"
    cat "$devlog"
    [ "$status" -eq 0 ]
    [[ "$output" == *"XGM_END"* ]]
    grep -q 'running repair WITHOUT concurrency protection' "$devlog"

    # The mode-000 tier-2 file was correctly recognized as unopenable and
    # left alone -- never truncated by a successful `9>` open, and never
    # even reached by a tier-1 retry (checked below). Checked before
    # removing it.
    [ "$(stat -c '%s %a' "$lock2")" = "0 0" ]
    rm -f "$lock2"

    [ "$(cd "$t2proj" && bd status --json | jq -r '.summary.total_issues')" = "1" ]
    # Write path works again -- proven with a real `bd create`, not a
    # literal prefix string (see the tier-1 test above for why).
    (cd "$t2proj" && bd create "post-repair write-path probe (xgm tier2)" --quiet)
    [ "$(cd "$t2proj" && bd status --json | jq -r '.summary.total_issues')" = "2" ]
    # Tier 1 correctly never got a lockfile (dir was read-only throughout).
    [ ! -f "$t2proj/.beads/.ensure_beads.lock" ]
}

# beads_claude_docker-pef: a FIFO planted at a lock path is worse than the
# mode-000 shape the two xgm cases above cover. A write-only open of a FIFO
# with no reader attached BLOCKS in open(2) rather than failing fast, so both
# the openability probe (`( : 9>"$lockfile" )`) and -- if that path were still
# selected -- the repair subshell's own `9>"$lockfile"` hang forever: no abort,
# no log line, and entrypoint.sh never reaches its final `exec "$@"`, so the
# container start just looks like nothing happened.
#
# Harness notes, both cases below:
#   * `timeout 30` bounds the wall clock INSIDE the test, so a regression
#     surfaces as an ordinary assertion failure (rc 124) instead of a bats run
#     that never returns.
#   * the runner's stdout/stderr go to a FILE, not bats' `run` pipe, and fd 3
#     (bats' own status descriptor) is closed on the way in: `timeout` kills
#     only its direct child, so with the bug present a forked subshell is still
#     parked in open() afterwards, and a descriptor it inherited would keep the
#     suite waiting on EOF long after the timeout fired.
#   * that leftover subshell is killed BEFORE the first assertion. Bats test
#     bodies are errexit: a failed assertion aborts the body, so cleanup placed
#     after the assertions would never run on the RED path.
@test "beads_claude_docker-pef: a FIFO at the tier-1 lock path degrades to tier 2 instead of blocking forever in open()" {
    git -C "$PROJ" init --quiet
    ensure_beads "$PROJ"
    (cd "$PROJ" && bd create "Issue" --quiet)
    (cd "$PROJ" && bd export -o .beads/issues.jsonl --quiet)
    local dbdir; dbdir=$(_dolt_dir_for "$PROJ")
    ( cd "$dbdir" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )
    _backdate_export_state "$PROJ"
    [ "$(_bd_total)" = "1" ]

    # The ensure_beads calls above already created an ordinary tier-1
    # lockfile, so it has to go before the FIFO can take its place.
    local lock1="$PROJ/.beads/.ensure_beads.lock"
    rm -f "$lock1"
    mkfifo "$lock1"
    [ -p "$lock1" ]

    local devlog="$BATS_TEST_TMPDIR/devlog-pef-tier1.txt"
    : > "$devlog"
    local runner="$BATS_TEST_TMPDIR/runner-pef-tier1.sh"
    cat > "$runner" <<EOF
#!/bin/bash
set -e
dev-log() { printf '%s\n' "\$*" >> "$devlog"; }
source "$BATS_TEST_TMPDIR/entrypoint-functions.sh"
ensure_beads "$PROJ"
echo PEF_END
EOF
    local out="$BATS_TEST_TMPDIR/out-pef-tier1.txt"
    local rc=0
    timeout 30 bash "$runner" >"$out" 2>&1 </dev/null 3>&- || rc=$?
    pkill -KILL -f 'runner-pef-tier1\.sh' 2>/dev/null || true

    echo "rc=$rc"
    cat "$out"
    cat "$devlog"
    # rc 124 means `timeout` had to kill it: that IS the hang under test.
    [ "$rc" -eq 0 ]
    grep -q PEF_END "$out"

    # The FIFO was recognized as unusable and left exactly as planted --
    # never opened, never replaced by a regular file.
    [ -p "$lock1" ]
    rm -f "$lock1"

    # Tier 2 is what actually got used.
    local lock2; lock2=$(_xgm_tier2_lock_path "$PROJ")
    [ -f "$lock2" ]
    rm -f "$lock2"

    # Not just "didn't hang": the repair body really ran to its normal
    # outcome -- count intact, and the write path works again (a real
    # `bd create`, the same proof the xgm cases use).
    [ "$(_bd_total)" = "1" ]
    (cd "$PROJ" && bd create "post-repair write-path probe (pef tier1)" --quiet)
    [ "$(_bd_total)" = "2" ]
}

@test "beads_claude_docker-pef: a FIFO at the tier-2 (TMPDIR) lock path degrades to the /dev/null last resort instead of blocking forever in open()" {
    local t2proj="$BATS_TEST_TMPDIR/proj-pef-tier2"
    mkdir -p "$t2proj"
    git -C "$t2proj" init --quiet
    ensure_beads "$t2proj"
    (cd "$t2proj" && bd create "Issue" --quiet)
    (cd "$t2proj" && bd export -o .beads/issues.jsonl --quiet)
    local dbdir2; dbdir2=$(_dolt_dir_for "$t2proj")
    ( cd "$dbdir2" && dolt sql -q "delete from config where \`key\`='issue_prefix'" )
    _backdate_export_state "$t2proj"
    [ "$(cd "$t2proj" && bd status --json | jq -r '.summary.total_issues')" = "1" ]

    # Tier 1 fails over legitimately (read-only .beads/, the same mechanism
    # the xgm tier-2 case uses); the FIFO is layered on top, at tier 2.
    chmod a-w "$t2proj/.beads"
    local lock2; lock2=$(_xgm_tier2_lock_path "$t2proj")
    rm -f "$lock2"
    mkfifo "$lock2"
    [ -p "$lock2" ]

    local devlog="$BATS_TEST_TMPDIR/devlog-pef-tier2.txt"
    : > "$devlog"
    local runner="$BATS_TEST_TMPDIR/runner-pef-tier2.sh"
    cat > "$runner" <<EOF
#!/bin/bash
set -e
dev-log() { printf '%s\n' "\$*" >> "$devlog"; }
source "$BATS_TEST_TMPDIR/entrypoint-functions.sh"
ensure_beads "$t2proj"
echo PEF_END
EOF
    local out="$BATS_TEST_TMPDIR/out-pef-tier2.txt"
    local rc=0
    timeout 30 bash "$runner" >"$out" 2>&1 </dev/null 3>&- || rc=$?
    chmod u+w "$t2proj/.beads"   # restore so bats can clean up
    pkill -KILL -f 'runner-pef-tier2\.sh' 2>/dev/null || true

    echo "rc=$rc"
    cat "$out"
    cat "$devlog"
    [ "$rc" -eq 0 ]
    grep -q PEF_END "$out"
    # Neither lock tier was usable, so the /dev/null last resort ran the
    # repair unlocked -- and said so.
    grep -q 'running repair WITHOUT concurrency protection' "$devlog"

    # The FIFO was left exactly as planted, and tier 1 never got a lockfile
    # (its directory was read-only throughout).
    [ -p "$lock2" ]
    rm -f "$lock2"
    [ ! -f "$t2proj/.beads/.ensure_beads.lock" ]

    [ "$(cd "$t2proj" && bd status --json | jq -r '.summary.total_issues')" = "1" ]
    (cd "$t2proj" && bd create "post-repair write-path probe (pef tier2)" --quiet)
    [ "$(cd "$t2proj" && bd status --json | jq -r '.summary.total_issues')" = "2" ]
}
