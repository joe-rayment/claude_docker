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
    # NOT used and why) -- assert it is no longer CALLED, i.e. doesn't appear
    # as a command inside a (...) subshell invocation like the old code did.
    ! grep -qE '\(cd "\$dir" && bd doctor' "$built"
}
