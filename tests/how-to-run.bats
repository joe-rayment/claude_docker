#!/usr/bin/env bats
#
# V3 acceptance contract (claude-orca-qt9.3) -- FROZEN from RED-AT onward.
# Layer 1 made visible: the four orca-layer probes appended to the S3
# runner, the doctor's Orca section, the run-it block a successful
# registration (and `claude-dev --how-to-run`) prints, and
# `./claude-dev open`.
#
# Why the orca-layer PROBE case lives here rather than in
# tests/selftest.bats: tests/run-dir.bats (V2c's frozen contract) pins
# tests/selftest.bats at exactly 5 cases and the combined plan at 1..34.
# Adding a sixth case there would fail that suite, so the new case is
# here -- the V3 CHECK runs both files, which is what the contract's TAP
# assertions are about.
#
# Nothing here needs Seatbelt: the four probes are gated on
# $CLAUDE_ORCA_LAYER (N/A outside a terminal Orca opened) and driven
# through the runner's fake-outcomes file everywhere else, exactly like
# the thirteen before them.

load helpers/setup

ORCA_LAYER_PROBES="orca-profile-active home-redirected orca-data-in-folder host-files-write-denied"

# Polls up to ~20s for $1 to exist (and, with $2, to contain it).
wait_for() {
    local target="$1" needle="${2:-}" i=0
    while [ "$i" -lt 200 ]; do
        if [ -f "$target" ]; then
            if [ -z "$needle" ] || grep -qF -- "$needle" "$target"; then
                return 0
            fi
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

# Guards a command that must return promptly: a `claude-dev open` that
# waited on its child would otherwise hang the suite instead of failing.
with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$@"
    else
        "$@"
    fi
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# CFBundleShortVersionString out of an XML plist (what the hdiutil stub
# fabricates); the launcher reads the same key through install-orca.sh.
plist_version() {
    sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' "$1" 2>/dev/null | head -1
}

# The doctor's Orca section: from its header up to (not including) the
# self-test section that follows it.
orca_section() {
    printf '%s\n' "$1" | awk '/^Orca layer /{f=1} f && /^Sandbox self-test/{f=0} f'
}

# Every clause of the run-it block the bead specifies, in one place: the
# double-click, the ./claude-dev open alternative, what Orca shows next,
# the login round trip, and how to check it worked.
assert_run_it_block() {
    local out="$1" project="$2"
    [[ "$out" == *"$project/Orca.app"* ]]
    [[ "$out" == *"right-click"* ]]
    [[ "$out" == *"./claude-dev open"* ]]
    [[ "$out" == *"pick Claude Code"* ]]
    [[ "$out" == *"[claude-orca] sandboxed:"* ]]
    [[ "$out" == *"login URL"* ]]
    [[ "$out" == *"./claude-dev --doctor"* ]]
}

@test "the four orca-layer probes report N/A outside an Orca terminal and PASS/FAIL from a fake outcome file" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    selftest="$ORCA_HOST/template/scripts/sandbox/selftest.sh"

    # (a) This terminal is not one Orca opened, so all four are N/A --
    # never PASS (nothing was proved) and never FAIL (nothing was
    # violated). $CLAUDE_ORCA_SELFTEST_FAKE is the all-pass file
    # helpers/setup.bash exports for the thirteen that came before.
    results="$BATS_TEST_TMPDIR/outside.json"
    run env -u CLAUDE_ORCA_LAYER CLAUDE_ORCA_ROOT="$primary" \
        "$selftest" --json-out "$results" --fake "$CLAUDE_ORCA_SELFTEST_FAKE"
    [ "$status" -eq 0 ]
    [ -f "$results" ]

    run jq -e '[.probes[]
                | select(.name == "orca-profile-active" or .name == "home-redirected"
                         or .name == "orca-data-in-folder" or .name == "host-files-write-denied")
                | .status] == ["N/A", "N/A", "N/A", "N/A"]' "$results"
    [ "$status" -eq 0 ]

    # ... and each says how to make it mean something.
    run jq -r '.probes[] | select(.name == "orca-profile-active") | .detail' "$results"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLAUDE_ORCA_LAYER"* ]]

    # (b) Driven from the fake-outcomes file, they report exactly what it
    # says -- and one FAIL is still the runner's verdict for the whole run.
    fake="$BATS_TEST_TMPDIR/fake-orca-layer.txt"
    cp "$CLAUDE_ORCA_SELFTEST_FAKE" "$fake"
    {
        echo "orca-profile-active=0"
        echo "home-redirected=0"
        echo "orca-data-in-folder=1"
        echo "host-files-write-denied=0"
    } >> "$fake"

    faked="$BATS_TEST_TMPDIR/faked.json"
    run env -u CLAUDE_ORCA_LAYER CLAUDE_ORCA_ROOT="$primary" \
        "$selftest" --json-out "$faked" --fake "$fake"
    [ "$status" -eq 1 ]

    run jq -e '[.probes[]
                | select(.name == "orca-profile-active" or .name == "home-redirected"
                         or .name == "orca-data-in-folder" or .name == "host-files-write-denied")
                | .status] == ["PASS", "PASS", "FAIL", "PASS"]' "$faked"
    [ "$status" -eq 0 ]
}

@test "doctor prints the Orca section with app version, profile hash and launcher presence and exits 2 when the launcher bundle or profile is missing" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    doctor="$ORCA_HOST/bin/claude-dev"
    profile="$primary/.claude-dev/state/orca.sb"
    bundle="$primary/Orca.app/Contents/MacOS/Orca"

    # Registration leaves both halves of layer 1 in the folder: the
    # profile sandbox-exec will be handed, and the bundle that hands it.
    [ -f "$profile" ]
    [ -x "$bundle" ]

    run bash -c "cd '$primary' && '$doctor' --doctor"
    [ "$status" -eq 0 ]
    section="$(orca_section "$output")"
    [ -n "$section" ]

    version="$(plist_version "$primary/.claude-dev/app/Orca.app/Contents/Info.plist")"
    [ -n "$version" ]
    [[ "$section" == *"app: $version"* ]]
    [[ "$section" == *"profile: sha256 $(sha256_of "$profile"), age "* ]]
    [[ "$section" == *"launcher: present"* ]]
    [[ "$section" == *"$bundle"* ]]

    # ... and the last word from inside layer 1: the four orca-layer
    # probes as the most recent self-test left them.
    for probe in $ORCA_LAYER_PROBES; do
        [[ "$section" == *"$probe"* ]]
    done

    # The bundle is the double-click entry point; without it the folder
    # has no sandboxed way in, and the doctor says so instead of passing.
    rm -rf "$primary/Orca.app"
    run bash -c "cd '$primary' && '$doctor' --doctor"
    [ "$status" -eq 2 ]
    [[ "$output" == *"launcher: MISSING"* ]]

    # Same for the profile: it IS the sandbox, so a folder without one
    # can only be opened unconfined.
    "$primary/.claude-dev/template/scripts/sandbox/make-launcher-app.sh" \
        --project "$primary" >/dev/null
    [ -x "$bundle" ]
    mv "$profile" "$BATS_TEST_TMPDIR/orca.sb.bak"
    run bash -c "cd '$primary' && '$doctor' --doctor"
    [ "$status" -eq 2 ]
    [[ "$output" == *"profile: MISSING"* ]]
    [[ "$output" != *"launcher: MISSING"* ]]
}

@test "a successful registration and claude-dev --how-to-run print the run-it block naming Orca.app, ./claude-dev open and ./claude-dev --doctor; a failed self-test prints the refusal instead" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    launcher="$ORCA_HOST/bin/claude-dev"

    # On demand, whenever the user needs it again.
    run bash -c "cd '$primary' && '$launcher' --how-to-run"
    [ "$status" -eq 0 ]
    assert_run_it_block "$output" "$primary"

    # ... and unprompted at the end of a registration that passed.
    run bash -c "cd '$primary' && '$launcher' register"
    [ "$status" -eq 0 ]
    assert_run_it_block "$output" "$primary"

    # A self-test that FAILED gets the refusal instead: nothing here may
    # tell the user how to open a folder we just refused to hand over.
    failing="$BATS_TEST_TMPDIR/fake-one-fail.txt"
    sed 's/^write-outside-denied=0$/write-outside-denied=1/' \
        "$CLAUDE_ORCA_SELFTEST_FAKE" > "$failing"
    grep -qx 'write-outside-denied=1' "$failing"
    export CLAUDE_ORCA_SELFTEST_FAKE="$failing"

    run bash -c "cd '$primary' && '$launcher' register"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Refusing to hand off to Orca"* ]]
    [[ "$output" != *"How to run it"* ]]
    [[ "$output" != *"./claude-dev open"* ]]
}

@test "./claude-dev open execs orca-launch (stubbed) in the background and returns 0" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    log="$primary/.claude-dev/state/orca-launch.log"
    marker="$BATS_TEST_TMPDIR/orca-launch-ran.txt"

    # sandbox-exec cannot run here, so the thing `open` must reach is
    # stubbed at the path the folder's own launcher resolves:
    # .claude-dev/bin/orca-launch. It sleeps before leaving its mark, so
    # a foregrounded launch is measurably distinguishable from a
    # backgrounded one.
    stub="$primary/.claude-dev/bin/orca-launch"
    rm -f "$stub"
    cat > "$stub" <<STUB
#!/usr/bin/env bash
echo "orca-launch stub: \$*"
sleep 4
printf '%s\n' "\$*" > "$marker"
STUB
    chmod +x "$stub"

    : > "$log"
    started="$SECONDS"
    run with_timeout bash -c "cd '$primary' && ./claude-dev open"
    elapsed=$((SECONDS - started))
    [ "$status" -eq 0 ]
    [ "$elapsed" -lt 4 ]

    # It really did start, with this folder, after `open` had returned.
    wait_for "$marker"
    grep -qF -- "--project $primary" "$marker"

    # Its stdio belongs in the launch log, not in the terminal that
    # started it -- which is also why `open` can return at all.
    wait_for "$log" "orca-launch stub:"
    [[ "$output" != *"orca-launch stub:"* ]]
    [[ "$output" == *"$log"* ]]
}
