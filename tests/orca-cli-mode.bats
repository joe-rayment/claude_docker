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
    "$CLAUDE_ORCA_HOME/bin/claude-orca-shell" "$@"
}

GEN_SETTINGS() {
    "$CLAUDE_ORCA_HOME/template/scripts/sandbox/gen-settings.sh" "$@"
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
    host="$(abspath "$CLAUDE_ORCA_HOME")"

    # `claude-dev register` seeds orca.cli false; the untouched file is the
    # default this case pins.
    run jq -e '.orca.cli == false' "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
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
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
        --sandbox-json "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$default_out" ]

    jq 'del(.orca)' "$PROJECT_DIR/.claude-dev/sandbox.json" > "$BATS_TEST_TMPDIR/no-orca.json"
    run GEN_SETTINGS \
        --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
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
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
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
        "$CLAUDE_ORCA_HOME/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]
    grep -qxF "ORCA_CLI_COMMAND=/opt/orca/bin/orca-ide" "$STUB_ENV"

    # --print-env reports it too, so `claude-dev` users can see it.
    run env ORCA_CLI_COMMAND=/opt/orca/bin/orca-ide \
        "$CLAUDE_ORCA_HOME/bin/claude-orca-shell" --print-env --root "$primary" --cwd "$primary"
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
        --real-home "$real_home" --host "$CLAUDE_ORCA_HOME" \
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
    doctor="$CLAUDE_ORCA_HOME/bin/claude-dev"

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

    # It is the CWD PROJECT's flag, not a global one: outside any
    # registered project the tool table stands alone.
    outside="$BATS_TEST_TMPDIR/outside"
    mkdir -p "$outside"
    run bash -c "cd '$outside' && '$doctor' --doctor"
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
    grep -qF "--worktree current" "$config_dir/CLAUDE.md"
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

# Runs the probe runner with every probe faked EXCEPT
# orca-socket-unreachable -- which runs for real against the stubbed
# `orca` on PATH -- and prints just that probe's status.
orca_probe_status() {
    "$CLAUDE_ORCA_HOME/template/scripts/sandbox/selftest.sh" \
        --json-out "$BATS_TEST_TMPDIR/orca-probe.json" --fake "$1" >/dev/null 2>&1 || true
    jq -r '.probes[] | select(.name == "orca-socket-unreachable") | .status' \
        "$BATS_TEST_TMPDIR/orca-probe.json"
}

@test "selftest expectation for orca-socket flips with the mode" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"

    # `orca status --json` reachable (exit 0) or not (exit 1), on demand.
    cat > "$BATS_TEST_TMPDIR/stubs/orca" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "status" ]; then
    exit "${STUB_ORCA_STATUS_EXIT:-1}"
fi
exit 0
STUB
    chmod +x "$BATS_TEST_TMPDIR/stubs/orca"

    fake="$BATS_TEST_TMPDIR/fake-except-orca.txt"
    : > "$fake"
    for name in write-outside-denied read-real-home-denied keychain-denied \
        project-writable worktree-writable sibling-worktree-denied \
        tmp-outside-denied network-blocked-domain network-allowed-domain \
        sandbox-exec-present srt-version-pinned git-hooks-audit; do
        echo "$name=0" >> "$fake"
    done

    export CLAUDE_ORCA_ROOT="$primary"

    # Socket reachable: a violation with the mode off, the point of the
    # mode when it is on.
    export STUB_ORCA_STATUS_EXIT=0
    set_orca_cli "$PROJECT_DIR" false
    [ "$(orca_probe_status "$fake")" = "FAIL" ]
    set_orca_cli "$PROJECT_DIR" true
    [ "$(orca_probe_status "$fake")" = "PASS" ]

    # Socket unreachable: exactly the other way round.
    export STUB_ORCA_STATUS_EXIT=1
    [ "$(orca_probe_status "$fake")" = "FAIL" ]
    set_orca_cli "$PROJECT_DIR" false
    [ "$(orca_probe_status "$fake")" = "PASS" ]

    unset STUB_ORCA_STATUS_EXIT CLAUDE_ORCA_ROOT
}
