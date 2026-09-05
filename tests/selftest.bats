#!/usr/bin/env bats
#
# S3 acceptance contract (claude-orca-3sk.15) -- FROZEN from RED-AT onward.
# Exercises scripts/sandbox/selftest.sh directly (the probe runner) and
# scripts/launcher.sh --doctor (the bootstrap gate) -- see
# .claude/plans/orca-port.md S3. The runner is testable on this Linux host
# with no real Seatbelt/bubblewrap because probe execution can be replaced
# wholesale via a fake-outcomes file (CLAUDE_ORCA_SELFTEST_FAKE/--fake);
# helpers/setup.bash exports an all-pass fake by default so S1/S2's own
# registration cases (which know nothing about self-tests) keep passing.

load helpers/setup

require_bash32() {
    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/helpers/ensure_bash32"
}

ALL_PROBE_NAMES="write-outside-denied read-real-home-denied keychain-denied project-writable worktree-writable sibling-worktree-denied tmp-outside-denied network-blocked-domain network-allowed-domain orca-socket-unreachable sandbox-exec-present srt-version-pinned git-hooks-audit orca-profile-active home-redirected orca-data-in-folder host-files-write-denied"

# Writes a fake-outcomes file to $1 with every probe set to PASS (=0),
# except any NAME=CODE overrides passed as additional arguments.
write_allpass_fake() {
    local out="$1"
    shift
    local overrides=" $* "
    local name found override
    : > "$out"
    for name in $ALL_PROBE_NAMES; do
        found=""
        for override in $overrides; do
            case "$override" in
                "$name="*) found="${override#*=}" ;;
            esac
        done
        echo "$name=${found:-0}" >> "$out"
    done
}

@test "probe table lists exactly the 17 named probes in order" {
    make_project "$PROJECT_DIR"
    selftest="$ORCA_HOST/template/scripts/sandbox/selftest.sh"

    run "$selftest" --dry-run --json-out "$BATS_TEST_TMPDIR/unused.json"
    [ "$status" -eq 0 ]
    [ ! -f "$BATS_TEST_TMPDIR/unused.json" ]

    expected="write-outside-denied
read-real-home-denied
keychain-denied
project-writable
worktree-writable
sibling-worktree-denied
tmp-outside-denied
network-blocked-domain
network-allowed-domain
orca-socket-unreachable
sandbox-exec-present
srt-version-pinned
git-hooks-audit
orca-profile-active
home-redirected
orca-data-in-folder
host-files-write-denied"

    actual="$(printf '%s\n' "$output" | awk 'NR>1 && NF {print $1}')"
    [ "$actual" = "$expected" ]
    [ "$(printf '%s\n' "$actual" | wc -l)" -eq 17 ]
}

@test "runner marks a probe FAIL when its fake outcome is wrong and exits 1" {
    make_project "$PROJECT_DIR"
    selftest="$ORCA_HOST/template/scripts/sandbox/selftest.sh"

    fake="$BATS_TEST_TMPDIR/fake-one-fail.txt"
    write_allpass_fake "$fake" "network-allowed-domain=1"

    results="$BATS_TEST_TMPDIR/results.json"
    run "$selftest" --json-out "$results" --fake "$fake"
    [ "$status" -eq 1 ]
    [ -f "$results" ]

    run jq -e '.probes[] | select(.name == "network-allowed-domain") | .status == "FAIL"' "$results"
    [ "$status" -eq 0 ]
    run jq -e '.summary == {"pass":16,"fail":1,"na":0}' "$results"
    [ "$status" -eq 0 ]

    # every OTHER probe is unaffected -- the fake overrides exactly one.
    run jq -e '[.probes[] | select(.name != "network-allowed-domain") | .status] | unique == ["PASS"]' "$results"
    [ "$status" -eq 0 ]
}

@test "--dry-run prints the probes without executing any" {
    make_project "$PROJECT_DIR"
    selftest="$ORCA_HOST/template/scripts/sandbox/selftest.sh"

    results="$BATS_TEST_TMPDIR/out.json"
    trace="$BATS_TEST_TMPDIR/trace.log"

    # A fake that would fail loudly if it were ever consulted -- dry-run
    # must never get far enough to look it up.
    fake="$BATS_TEST_TMPDIR/fake.txt"
    write_allpass_fake "$fake" "write-outside-denied=1"

    export CLAUDE_ORCA_SELFTEST_TRACE="$trace"
    run "$selftest" --dry-run --json-out "$results" --fake "$fake"
    unset CLAUDE_ORCA_SELFTEST_TRACE
    [ "$status" -eq 0 ]

    # Discriminating on two independent signals: no results file, and no
    # per-probe trace entry (the same loop body that would run a probe,
    # real or faked, never executes in --dry-run).
    [ ! -f "$results" ]
    [ ! -f "$trace" ]
}

@test "doctor exits 2 when selftest.json is absent, stale (>24h) or failed, and 0 when fresh and passed" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    doctor="$ORCA_HOST/bin/claude-dev"
    wrapper="$ORCA_HOST/bin/claude-orca-shell"
    results="$primary/.claude-dev/run/selftest.json"

    # absent
    rm -f "$results"
    run bash -c "cd '$primary' && '$doctor' --doctor"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not run"* ]]

    # fresh and passed
    run "$wrapper" --selftest --root "$primary" --cwd "$primary"
    [ "$status" -eq 0 ]
    [ -f "$results" ]
    run bash -c "cd '$primary' && '$doctor' --doctor"
    [ "$status" -eq 0 ]

    # stale (>24h): rewrite the results file's mtime to 25h ago -- the
    # timestamp INSIDE the JSON is irrelevant to doctor, only file age is.
    touch -d '25 hours ago' "$results"
    run bash -c "cd '$primary' && '$doctor' --doctor"
    [ "$status" -eq 2 ]
    [[ "$output" == *"STALE"* ]]

    # fresh but failed
    jq '.summary.fail = 1 | .probes[0].status = "FAIL"' "$results" > "$BATS_TEST_TMPDIR/r.json"
    mv "$BATS_TEST_TMPDIR/r.json" "$results"
    run bash -c "cd '$primary' && '$doctor' --doctor"
    [ "$status" -eq 2 ]
}

# claude-orca-riu.2: a refusal that only says no is a dead end -- the
# user needs the failing probes and the two things to do about them.
@test "register refusal names the FAILed probes and the next step" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    launcher="$ORCA_HOST/bin/claude-dev"

    fake="$BATS_TEST_TMPDIR/fake-one-fail.txt"
    write_allpass_fake "$fake" "network-allowed-domain=1"
    export CLAUDE_ORCA_SELFTEST_FAKE="$fake"

    run bash -c "cd '$primary' && '$launcher' register"
    [ "$status" -eq 2 ]

    # The probe table (which probe, and why) ...
    [[ "$output" == *"[FAIL]"* ]]
    [[ "$output" == *"network-allowed-domain"* ]]
    # ... the refusal itself ...
    [[ "$output" == *"Refusing to hand off to Orca"* ]]
    # ... and what to do next: re-run the gate, read the per-probe detail.
    [[ "$output" == *"then re-run: claude-dev --doctor"* ]]
    [[ "$output" == *"$primary/.claude-dev/run/selftest.json"* ]]
}

@test "results JSON has timestamp, per-probe status and the srt version" {
    require_bash32
    make_project "$PROJECT_DIR"
    selftest="$ORCA_HOST/template/scripts/sandbox/selftest.sh"

    pin="$(grep -E '^SRT_VERSION=' "$REPO_ROOT/scripts/install-srt.sh" | head -1 | sed -E 's/^SRT_VERSION="([^"]*)".*/\1/')"
    [ -n "$pin" ]

    fake="$BATS_TEST_TMPDIR/fake-allpass.txt"
    write_allpass_fake "$fake"

    for shell_bin in "$BASH32" bash; do
        results="$BATS_TEST_TMPDIR/results.json"
        rm -f "$results"
        run "$shell_bin" "$selftest" --json-out "$results" --fake "$fake"
        [ "$status" -eq 0 ]
        [ -f "$results" ]

        run jq -e '(keys | sort) == ["platform","probes","root","srt_version","summary","timestamp","worktree"]' "$results"
        [ "$status" -eq 0 ]

        run jq -e --arg pin "$pin" '.srt_version == $pin' "$results"
        [ "$status" -eq 0 ]

        run jq -e '.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$results"
        [ "$status" -eq 0 ]

        run jq -e '.probes | length == 17' "$results"
        [ "$status" -eq 0 ]

        run jq -e '[.probes[] | (keys | sort)] | unique == [["detail","name","status"]]' "$results"
        [ "$status" -eq 0 ]

        run jq -e '[.probes[].status] | unique == ["PASS"]' "$results"
        [ "$status" -eq 0 ]

        run jq -e '.summary == {"pass":17,"fail":0,"na":0}' "$results"
        [ "$status" -eq 0 ]
    done
}
