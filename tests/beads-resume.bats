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
    [ -f "$built" ] || skip "no built copy present"
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
