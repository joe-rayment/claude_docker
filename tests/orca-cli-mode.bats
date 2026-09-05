#!/usr/bin/env bats
#
# S9 acceptance contract (claude-orca-3sk.20) -- FROZEN from RED-AT onward.
# Covers the opt-in Orca CLI orchestration mode: sandbox.json's
# {"orca":{"cli":true}} widening gen-settings.sh's output by exactly the
# Orca runtime directory (a Unix socket dir + a read path), the wrapper
# passing ORCA_CLI_COMMAND through and installing the pinned orca-cli /
# orchestration skills plus the rulebook addendum, the launcher printing
# the residual escape-surface warning, and the selftest's orca-socket
# expectation flipping with the mode.
#
# The mode is OFF by default because the `orca` socket is a remote control
# for an UNSANDBOXED app; every case below therefore checks both states,
# never just the interesting one.

load helpers/setup

WRAPPER() {
    "$ORCA_HOST/bin/claude-orca-shell" "$@"
}

GEN_SETTINGS() {
    "$ORCA_HOST/template/scripts/sandbox/gen-settings.sh" "$@"
}

# Rewrites the project's sandbox.json orca.cli flag in place (true/false).
set_orca_cli() {
    local dir="$1" value="$2" tmp="$BATS_TEST_TMPDIR/sandbox.json.tmp"
    jq --argjson v "$value" '.orca.cli = $v' \
        "$dir/.claude-dev/sandbox.json" > "$tmp"
    mv "$tmp" "$dir/.claude-dev/sandbox.json"
}

# The Orca runtime dir under a given real (unsandboxed) home -- the same
# path the wrapper already exports as ORCA_USER_DATA_PATH.
orca_runtime_dir() {
    printf '%s\n' "$1/Library/Application Support/orca"
}

@test "default sandbox.json yields empty allowUnixSockets and no Orca runtime dir in allowRead" {
    make_project "$PROJECT_DIR"
    real_home="$(make_real_home)"
    primary="$(abspath "$PROJECT_DIR")"
    host="$(abspath "$ORCA_HOST")"

    # `claude-dev register` seeds orca.cli false; the untouched file is the
    # default this case pins.
    run jq -e '.orca.cli == false' "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]
    default_out="$output"

    [ "$(jq -c '.network.allowUnixSockets' <<<"$default_out")" = "[]" ]

    # allowRead is exactly the S2 list -- the Orca runtime dir is absent,
    # not merely last.
    expected_read="$(jq -nc --arg p "$primary" --arg h "$host" --arg rh "$real_home" \
        '[$p, $h, ($rh+"/.local/bin"), ($rh+"/.local/share/claude"), ($rh+"/.orca/agent-hooks")]')"
    [ "$(jq -c '.filesystem.allowRead' <<<"$default_out")" = "$expected_read" ]
    [[ "$default_out" != *"Application Support/orca"* ]]

    # An explicit false and a sandbox.json with no orca key at all both
    # produce byte-identical output to the default.
    set_orca_cli "$PROJECT_DIR" false
    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$default_out" ]

    jq 'del(.orca)' "$PROJECT_DIR/.claude-dev/sandbox.json" > "$BATS_TEST_TMPDIR/no-orca.json"
    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$BATS_TEST_TMPDIR/no-orca.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$default_out" ]
}

@test "orca.cli true yields allowUnixSockets with the Orca runtime dir, allowRead of it, and ORCA_CLI_COMMAND passthrough" {
    make_project "$PROJECT_DIR"
    real_home="$(abspath "$(make_real_home)")"
    primary="$(abspath "$PROJECT_DIR")"
    runtime_dir="$(orca_runtime_dir "$real_home")"

    set_orca_cli "$PROJECT_DIR" true

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    [ "$(jq -c '.network.allowUnixSockets' <<<"$output")" \
        = "$(jq -nc --arg d "$runtime_dir" '[$d]')" ]
    run_read="$(jq -c '.filesystem.allowRead' <<<"$output")"
    [ "$(jq --arg d "$runtime_dir" 'index($d) != null' <<<"$run_read")" = "true" ]

    # Widened by exactly one entry: the S2 five, plus the runtime dir.
    [ "$(jq 'length' <<<"$run_read")" -eq 6 ]

    # ...and nothing else moved: the real HOME is still denyRead, writes
    # are still the S2 three.
    [ "$(jq -c '.filesystem.denyRead' <<<"$output")" \
        = "$(jq -nc --arg h "$real_home" '[$h]')" ]
    [ "$(jq -c '.filesystem.allowWrite' <<<"$output")" \
        = "$(jq -nc --arg p "$primary" '[$p, ($p+"/.claude-dev/home"), ($p+"/.claude-dev/tmp")]')" ]

    # ORCA_CLI_COMMAND reaches the srt process untouched (Orca sets it for
    # managed sessions; both skills resolve the binary from it).
    export CLAUDE_ORCA_REAL_HOME="$real_home"
    export STUB_SRT_NOEXEC=1
    run env ORCA_CLI_COMMAND=/opt/orca/bin/orca-ide \
        "$ORCA_HOST/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]
    grep -qxF "ORCA_CLI_COMMAND=/opt/orca/bin/orca-ide" "$STUB_ENV"

    # --print-env reports it too, so `claude-dev` users can see it.
    run env ORCA_CLI_COMMAND=/opt/orca/bin/orca-ide \
        "$ORCA_HOST/bin/claude-orca-shell" --print-env --root "$primary" --cwd "$primary"
    [ "$status" -eq 0 ]
    grep -qxF "ORCA_CLI_COMMAND=/opt/orca/bin/orca-ide" <<<"$output"

    unset STUB_SRT_NOEXEC CLAUDE_ORCA_REAL_HOME
}

@test "generated settings with orca.cli on validate against the pinned srt schema" {
    real_srt_dir="$(ensure_real_srt)" || skip "no real node/npm available to fetch or run the pinned srt schema"

    make_project "$PROJECT_DIR"
    real_home="$(abspath "$(make_real_home)")"
    primary="$(abspath "$PROJECT_DIR")"
    set_orca_cli "$PROJECT_DIR" true

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$ORCA_HOST" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/settings.json"

    run env PATH="$ORIGINAL_PATH" node "$REPO_ROOT/tests/helpers/validate-srt-schema.mjs" \
        "$real_srt_dir/dist/index.js" "$BATS_TEST_TMPDIR/settings.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VALID"* ]]
}

@test "doctor prints the escape-surface warning only when the mode is on" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    doctor="$ORCA_HOST/bin/claude-dev"

    # OFF: not a word about it.
    run bash -c "cd '$primary' && '$doctor' --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Orca CLI mode is ON"* ]]
    [[ "$output" != *"Floating Workspace"* ]]

    # ON: the residual surface is stated, with the Orca settings to harden.
    set_orca_cli "$PROJECT_DIR" true
    run bash -c "cd '$primary' && '$doctor' --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Orca CLI mode is ON"* ]]
    [[ "$output" == *"outside"* ]]
    [[ "$output" == *"Floating Workspace"* ]]
    [[ "$output" == *"public artifact link"* ]]
    [[ "$output" == *"orca.yaml"* ]]

    # V1 (claude-orca-qt9.1): it is THIS FOLDER's flag. A per-folder
    # launcher reports its own project wherever it is run from...
    outside="$BATS_TEST_TMPDIR/outside"
    mkdir -p "$outside"
    run bash -c "cd '$outside' && '$doctor' --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Orca CLI mode is ON"* ]]

    # ... and a launcher that is not a per-folder install at all (the repo
    # checkout), run outside any project, prints the tool table alone.
    run bash -c "cd '$outside' && '$REPO_ROOT/scripts/launcher.sh' --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Orca CLI mode is ON"* ]]
}

@test "orca-cli and orchestration skills are installed into the config dir only when the mode is on" {
    make_project "$PROJECT_DIR"
    real_home="$(abspath "$(make_real_home)")"
    primary="$(abspath "$PROJECT_DIR")"
    config_dir="$primary/.claude-dev/home/.claude"
    export CLAUDE_ORCA_REAL_HOME="$real_home"
    export STUB_SRT_NOEXEC=1

    # The template carries a pinned snapshot, version-stamped.
    [ -f "$REPO_ROOT/config/orca-skills/orca-cli/SKILL.md" ]
    [ -f "$REPO_ROOT/config/orca-skills/orchestration/SKILL.md" ]
    [ -f "$REPO_ROOT/config/orca-skills/VERSION" ]
    grep -qF "1.4.197" "$REPO_ROOT/config/orca-skills/VERSION"
    grep -qF "Orca" "$REPO_ROOT/config/orca-skills/VERSION"
    [ -f "$REPO_ROOT/config/orca-cli-addendum.md" ]

    # OFF: a launch installs neither skill and leaves CLAUDE.md alone.
    run WRAPPER --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]
    [ ! -e "$config_dir/skills/orca-cli" ]
    [ ! -e "$config_dir/skills/orchestration" ]
    run grep -c "claude_orca orca-cli" "$config_dir/CLAUDE.md"
    [ "$output" = "0" ]
    base_memory="$(cat "$config_dir/CLAUDE.md")"

    # ON: both skills land, carrying the pin, and the rulebook addendum is
    # appended between markers.
    set_orca_cli "$PROJECT_DIR" true
    run WRAPPER --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]
    [ -f "$config_dir/skills/orca-cli/SKILL.md" ]
    [ -f "$config_dir/skills/orchestration/SKILL.md" ]
    grep -q "^name: orca-cli$" "$config_dir/skills/orca-cli/SKILL.md"
    grep -q "^name: orchestration$" "$config_dir/skills/orchestration/SKILL.md"
    run grep -rlF "1.4.197" "$config_dir/skills"
    [ "$status" -eq 0 ]

    [ "$(grep -c 'claude_orca orca-cli' "$config_dir/CLAUDE.md")" -eq 2 ]
    grep -qF "coordinator" "$config_dir/CLAUDE.md"
    grep -qF "orca orchestration worker-start" "$config_dir/CLAUDE.md"
    grep -qF -e "--worktree current" "$config_dir/CLAUDE.md"
    grep -qF "worker_done" "$config_dir/CLAUDE.md"
    grep -qF "beads remain the source of truth" "$config_dir/CLAUDE.md"
    with_addendum="$(cat "$config_dir/CLAUDE.md")"

    # Idempotent: a second launch appends nothing.
    run WRAPPER --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]
    [ "$(cat "$config_dir/CLAUDE.md")" = "$with_addendum" ]
    [ "$(grep -c 'claude_orca orca-cli' "$config_dir/CLAUDE.md")" -eq 2 ]

    # OFF again: skills and addendum are removed, and CLAUDE.md is byte-
    # identical to the un-addended one -- no residue of the mode.
    set_orca_cli "$PROJECT_DIR" false
    run WRAPPER --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]
    [ ! -e "$config_dir/skills/orca-cli" ]
    [ ! -e "$config_dir/skills/orchestration" ]
    [ "$(cat "$config_dir/CLAUDE.md")" = "$base_memory" ]

    unset STUB_SRT_NOEXEC CLAUDE_ORCA_REAL_HOME
}

# --- the orca-socket-unreachable probe (claude-orca-riu.2) -----------------
#
# Supersedes the single "selftest expectation for orca-socket flips with
# the mode" case, whose stub modelled `orca status --json` exiting 1 when
# the runtime is unreachable. The v1.4.197 binary falsifies that: its
# status handler sets exitCode=1 ONLY when --json was NOT passed, so with
# --json it always exits 0 and carries reachability in the JSON instead.
# The probe therefore reads reachability semantically, and the five cases
# below pin every branch of the resulting truth table.

# Writes an `orca` stub onto the test PATH that models the real CLI:
# `status --json` ALWAYS exits 0 and prints reachability in its JSON;
# plain `status` is the only form whose exit code carries it.
# $STUB_ORCA_REACHABLE (true/false) drives both; $STUB_ORCA_JSON_GARBAGE,
# when set, is printed instead of the JSON (still exit 0).
write_orca_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/orca" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "status" ]; then
    reachable="${STUB_ORCA_REACHABLE:-false}"
    if [ "${2:-}" = "--json" ]; then
        if [ -n "${STUB_ORCA_JSON_GARBAGE:-}" ]; then
            printf '%s\n' "$STUB_ORCA_JSON_GARBAGE"
        else
            printf '{"version":"1.4.197","runtime":{"reachable":%s,"endpoint":"/tmp/orca.sock"}}\n' "$reachable"
        fi
        exit 0
    fi
    [ "$reachable" = "true" ] && exit 0
    exit 1
fi
exit 0
STUB
    chmod +x "$BATS_TEST_TMPDIR/stubs/orca"
}

# A registered project, the stub above on PATH, and a fake-outcomes file
# ($SOCKET_FAKE) covering every probe EXCEPT orca-socket-unreachable --
# which is left to run for real against the stub.
setup_socket_probe() {
    make_project "$PROJECT_DIR"
    export CLAUDE_ORCA_ROOT="$(abspath "$PROJECT_DIR")"
    write_orca_stub
    SOCKET_FAKE="$BATS_TEST_TMPDIR/fake-except-orca.txt"
    : > "$SOCKET_FAKE"
    local name
    for name in write-outside-denied read-real-home-denied keychain-denied \
        project-writable worktree-writable sibling-worktree-denied \
        tmp-outside-denied network-blocked-domain network-allowed-domain \
        sandbox-exec-present srt-version-pinned git-hooks-audit; do
        echo "$name=0" >> "$SOCKET_FAKE"
    done
}

run_socket_probe() {
    "$ORCA_HOST/template/scripts/sandbox/selftest.sh" \
        --json-out "$BATS_TEST_TMPDIR/orca-probe.json" \
        --fake "$SOCKET_FAKE" >/dev/null 2>&1 || true
}

# $1 = "status" or "detail" from the last run_socket_probe.
socket_probe() {
    jq -r ".probes[] | select(.name == \"orca-socket-unreachable\") | .$1" \
        "$BATS_TEST_TMPDIR/orca-probe.json"
}

@test "socket probe: cli=false and runtime unreachable is a PASS" {
    setup_socket_probe
    set_orca_cli "$PROJECT_DIR" false
    export STUB_ORCA_REACHABLE=false

    run_socket_probe
    [ "$(socket_probe status)" = "PASS" ]
    [[ "$(socket_probe detail)" == *"unreachable"* ]]

    unset STUB_ORCA_REACHABLE CLAUDE_ORCA_ROOT
}

@test "socket probe: cli=false and runtime reachable is a FAIL naming the leak" {
    setup_socket_probe
    set_orca_cli "$PROJECT_DIR" false
    export STUB_ORCA_REACHABLE=true

    run_socket_probe
    [ "$(socket_probe status)" = "FAIL" ]

    # The detail has to say what actually broke -- a reachable runtime
    # with the mode off means the unix-socket deny did not hold.
    detail="$(socket_probe detail)"
    [[ "$detail" == *"LEAK"* ]]
    [[ "$detail" == *"socket"* ]]
    [[ "$detail" == *"orca.cli=false"* ]]

    unset STUB_ORCA_REACHABLE CLAUDE_ORCA_ROOT
}

@test "socket probe: cli=true and runtime reachable is a PASS" {
    setup_socket_probe
    set_orca_cli "$PROJECT_DIR" true
    export STUB_ORCA_REACHABLE=true

    run_socket_probe
    [ "$(socket_probe status)" = "PASS" ]
    [[ "$(socket_probe detail)" == *"orca.cli=true"* ]]

    unset STUB_ORCA_REACHABLE CLAUDE_ORCA_ROOT
}

@test "socket probe: cli=true and runtime unreachable is N/A telling the user to launch Orca" {
    setup_socket_probe
    set_orca_cli "$PROJECT_DIR" true
    export STUB_ORCA_REACHABLE=false

    # Not a FAIL: the app simply isn't running, which must never brick a
    # first-run registration the way a FAIL would.
    run_socket_probe
    [ "$(socket_probe status)" = "N/A" ]

    detail="$(socket_probe detail)"
    [[ "$detail" == *"launch"* ]]
    [[ "$detail" == *"Orca.app"* ]]
    [[ "$detail" == *"--doctor"* ]]

    unset STUB_ORCA_REACHABLE CLAUDE_ORCA_ROOT
}

@test "socket probe: unparseable status JSON falls back to the plain status exit code" {
    setup_socket_probe
    set_orca_cli "$PROJECT_DIR" false
    export STUB_ORCA_JSON_GARBAGE='orca: could not read runtime endpoint'

    # Plain `orca status` exits nonzero -> unreachable -> PASS with the
    # mode off, and the detail says where the answer came from.
    export STUB_ORCA_REACHABLE=false
    run_socket_probe
    [ "$(socket_probe status)" = "PASS" ]
    [[ "$(socket_probe detail)" == *"exit code"* ]]

    # ... and exits 0 -> reachable -> the same leak, still with the mode
    # off, proving the exit code (not the unparseable JSON) decided it.
    export STUB_ORCA_REACHABLE=true
    run_socket_probe
    [ "$(socket_probe status)" = "FAIL" ]
    [[ "$(socket_probe detail)" == *"exit code"* ]]

    unset STUB_ORCA_REACHABLE STUB_ORCA_JSON_GARBAGE CLAUDE_ORCA_ROOT
}
