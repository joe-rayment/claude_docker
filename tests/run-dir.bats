#!/usr/bin/env bats
#
# V2c acceptance contract (claude-orca-qt9.7) -- FROZEN from RED-AT onward.
# One theme, two moves. (a) Everything the SANDBOX writes leaves the
# host-owned state/ tree for a new, agent-writable .claude-dev/run:
# tier.json (tier-set runs inside), selftest.json and the srt-debug
# capture (the self-test runs inside). state/ keeps only host-written
# artifacts, so V2's deny list can stay absolute. (b) .claude-dev/
# sandbox.json joins that deny list: its orca.profileExceptions and
# extraAllowWrite/extraAllowedDomains widen BOTH sandbox layers at the
# next launch, so an agent that can edit it can grant itself the real
# home. Reads of it stay allowed -- both generators still consume it.
# See .claude/plans/orca-port.md S9.2.

load helpers/setup

GEN_PROFILE() { "$REPO_ROOT/scripts/sandbox/gen-orca-profile.sh" "$@"; }
GEN_SETTINGS() { "$REPO_ROOT/scripts/sandbox/gen-settings.sh" "$@"; }

# A folder carrying only what the two generators read: both are pure
# functions of (project, real home, sandbox.json), so no bootstrap, no
# DMG and no srt install are needed to exercise them.
make_light_project() {
    local dir="$1"
    mkdir -p "$dir/.claude-dev/state" "$dir/.claude-dev/home" \
             "$dir/.claude-dev/tmp" "$dir/.claude-dev/bin"
    printf '%s\n' \
        '{"version":1,"network":{"extraAllowedDomains":[]},"filesystem":{"extraAllowWrite":[]},"orca":{"cli":false}}' \
        > "$dir/.claude-dev/sandbox.json"
    ln -sfn "$REPO_ROOT" "$dir/.claude-dev/template"
}

# A child bats run with this run's own BATS_* state stripped and the
# unstubbed PATH restored, so the suites below see the same environment
# they get from run-tests.sh.
nested_bats() {
    env -u BATS_TEST_TMPDIR -u BATS_RUN_TMPDIR -u BATS_SUITE_TMPDIR \
        -u BATS_TMPDIR -u BATS_TEST_NAME -u BATS_TEST_FILENAME \
        -u CLAUDE_ORCA_SELFTEST_FAKE -u CLAUDE_ORCA_ROOT \
        PATH="${ORIGINAL_PATH:-$PATH}" bats "$@"
}

@test "tier.json, selftest.json and srt-debug logs are written under .claude-dev/run and never under .claude-dev/state" {
    # (a) the shared helper names the run directory, and tier-set -- which
    # runs INSIDE the sandbox -- writes the bound tier there.
    root="$BATS_TEST_TMPDIR/tierroot"
    mkdir -p "$root/.claude-dev/state"
    run env CLAUDE_ORCA_ROOT="$root" bash -c \
        ". '$REPO_ROOT/scripts/lib/paths.sh'; run_dir; tier_state_file"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$root/.claude-dev/run" ]
    [ "${lines[1]}" = "$root/.claude-dev/run/tier.json" ]

    run env CLAUDE_ORCA_ROOT="$root" CLAUDE_CONFIG_DIR="$root/.claude" \
        "$REPO_ROOT/scripts/tier-set.sh" opus
    [ "$status" -eq 0 ]
    [ -f "$root/.claude-dev/run/tier.json" ]
    [ ! -f "$root/.claude-dev/state/tier.json" ]

    # (b) the self-test's results and srt's captured stderr, both written
    # from inside the sandbox by the wrapper's --selftest mode.
    make_project "$PROJECT_DIR"
    p="$(abspath "$PROJECT_DIR")"
    rm -rf "$p/.claude-dev/run"
    rm -f "$p/.claude-dev/state/selftest.json"
    rm -f "$p"/.claude-dev/state/srt-debug-*.log

    run "$ORCA_HOST/bin/claude-orca-shell" --selftest --root "$p" --cwd "$p"
    [ "$status" -eq 0 ]
    [ -f "$p/.claude-dev/run/selftest.json" ]
    [ ! -f "$p/.claude-dev/state/selftest.json" ]
    [ -n "$(find "$p/.claude-dev/run" -name 'srt-debug-*.log' 2>/dev/null)" ]
    [ -z "$(find "$p/.claude-dev/state" -name 'srt-debug-*.log' 2>/dev/null)" ]
}

@test "the host-owned deny list contains .claude-dev/sandbox.json and neither profile allows writing it" {
    make_light_project "$PROJECT_DIR"
    p="$(abspath "$PROJECT_DIR")"
    rh="$(make_real_home)"
    sj="$p/.claude-dev/sandbox.json"

    # the one shared list
    . "$REPO_ROOT/scripts/sandbox/host-owned-paths.sh"
    run bash -c ". '$REPO_ROOT/scripts/sandbox/host-owned-paths.sh'; host_owned_paths '$p'"
    [ "$status" -eq 0 ]
    grep -qxF "$sj" <<<"$output"

    # layer 2 (the agents' srt settings): denied, and not re-opened by an
    # allowWrite entry of its own.
    run GEN_SETTINGS --primary "$p" --worktree "$p" --real-home "$rh" \
        --host "$p/.claude-dev" --sandbox-json "$sj"
    [ "$status" -eq 0 ]
    run jq -e --arg f "$sj" '(.filesystem.denyWrite | index($f)) != null' <<<"$output"
    [ "$status" -eq 0 ]
    settings="$(GEN_SETTINGS --primary "$p" --worktree "$p" --real-home "$rh" \
        --host "$p/.claude-dev" --sandbox-json "$sj")"
    run jq -e --arg f "$sj" '(.filesystem.allowWrite | index($f)) == null' <<<"$settings"
    [ "$status" -eq 0 ]

    # layer 1 (the Orca app's Seatbelt profile): denied, and denied LAST --
    # SBPL is last-match-wins, so no allow above may follow it.
    run GEN_PROFILE --project "$p" --real-home "$rh" --sandbox-json "$sj"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/profile.sb"
    grep -qxF "(deny file-write* (subpath \"$sj\"))" "$BATS_TEST_TMPDIR/profile.sb"
    deny_line="$(grep -nxF "(deny file-write* (subpath \"$sj\"))" \
        "$BATS_TEST_TMPDIR/profile.sb" | cut -d: -f1)"
    last_allow="$(grep -n 'allow file-write\*\|allow file-read\* file-write\*' \
        "$BATS_TEST_TMPDIR/profile.sb" | tail -1 | cut -d: -f1)"
    [ -n "$deny_line" ]
    [ -n "$last_allow" ]
    [ "$deny_line" -gt "$last_allow" ]

    # reads stay allowed: an exception in the same file is still honoured,
    # which is only possible if the generator can read it.
    jq '.orca.profileExceptions.allowRead = ["/opt/example"]' "$sj" \
        > "$BATS_TEST_TMPDIR/sj.json"
    mv "$BATS_TEST_TMPDIR/sj.json" "$sj"
    run GEN_PROFILE --project "$p" --real-home "$rh" --sandbox-json "$sj"
    [ "$status" -eq 0 ]
    grep -qF '(allow file-read* (subpath "/opt/example"))' <<<"$output"
}

@test "registration creates .claude-dev/run and the doctor reads the self-test result from it" {
    make_project "$PROJECT_DIR"
    p="$(abspath "$PROJECT_DIR")"
    doctor="$ORCA_HOST/bin/claude-dev"

    [ -d "$p/.claude-dev/run" ]
    [ -f "$p/.claude-dev/run/selftest.json" ]

    # The verdict follows run/, not state/: a passing copy parked in the
    # host-owned tree is not a self-test result any more.
    mkdir -p "$p/.claude-dev/state"
    cp "$p/.claude-dev/run/selftest.json" "$p/.claude-dev/state/selftest.json"
    rm -f "$p/.claude-dev/run/selftest.json"
    run bash -c "cd '$p' && '$doctor' --doctor"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not run"* ]]

    # ... and passes again as soon as the result is back where it belongs.
    mv "$p/.claude-dev/state/selftest.json" "$p/.claude-dev/run/selftest.json"
    run bash -c "cd '$p' && '$doctor' --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" != *"not run"* ]]
}

@test "every pre-existing tier-hooks and selftest case still passes" {
    # The counts this slice inherited: nothing here may quietly drop a case
    # to make the move green.
    run nested_bats --count "$REPO_ROOT/tests/tier-hooks.bats"
    [ "$status" -eq 0 ]
    [ "$output" = "29" ]
    run nested_bats --count "$REPO_ROOT/tests/selftest.bats"
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]

    run nested_bats --tap "$REPO_ROOT/tests/tier-hooks.bats" \
        "$REPO_ROOT/tests/selftest.bats"
    printf '%s\n' "$output"
    [ "$status" -eq 0 ]
    grep -qx '1\.\.34' <<<"$output"
    ! grep -q '^not ok' <<<"$output"
    ! grep -q '# skip' <<<"$output"
}

@test "the orca profile allows file-read-metadata on /Users, the real home and every ancestor of the project" {
    make_light_project "$PROJECT_DIR"
    p="$(abspath "$PROJECT_DIR")"
    rh="$(abspath "$(make_real_home)")"
    sb="$BATS_TEST_TMPDIR/profile.sb"

    run GEN_PROFILE --project "$p" --real-home "$rh"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$sb"

    meta_line="$(grep -n '^(allow file-read-metadata ' "$sb" | head -1 | cut -d: -f1)"
    [ -n "$meta_line" ]
    meta_rule="$(sed -n "${meta_line}p" "$sb")"

    # /Users and the real home, named outright ...
    grep -qF '(literal "/Users")' <<<"$meta_rule"
    grep -qF "(literal \"$rh\")" <<<"$meta_rule"

    # ... and every directory between the project and the root, so looking
    # up the folder's own absolute path never crosses an un-stat-able
    # parent inside the denied tree.
    d="$(dirname "$p")"
    while [ "$d" != "/" ]; do
        grep -qF "(literal \"$d\")" <<<"$meta_rule"
        d="$(dirname "$d")"
    done

    # Metadata only, and directory entries only: never a subpath, so
    # nothing INSIDE those directories becomes readable.
    ! grep -q 'subpath' <<<"$meta_rule"

    # Last-match-wins: the allow has to sit below the denies it qualifies.
    users_deny="$(grep -n '^(deny file-read\* (subpath "/Users"))$' "$sb" | cut -d: -f1)"
    home_deny="$(grep -n "^(deny file-read\* (subpath \"$rh\"))$" "$sb" | cut -d: -f1)"
    [ -n "$users_deny" ]
    [ -n "$home_deny" ]
    [ "$meta_line" -gt "$users_deny" ]
    [ "$meta_line" -gt "$home_deny" ]
}
