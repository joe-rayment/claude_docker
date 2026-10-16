#!/usr/bin/env bats
#
# opencode-permissions.bats -- workers_opencode_command (scripts/lib/workers.sh)
# must never leave a dispatched opencode TUI worker stalled on an
# interactive "Permission required" prompt (claude-orca-gh9): opencode's own
# "ask" default on external_directory/doom_loop has nobody at the keyboard
# to answer it. The per-launch config now always carries a permission block
# ("*": allow, bash "git push *"/"git push": deny, external_directory: allow)
# unless CLAUDE_ORCA_OPENCODE_PERMISSIONS=ask opts back into opencode's own
# interactive defaults.
#
# FROZEN from RED-AT onward: this file must not be edited after its RED
# commit. If a case here turns out to be wrong, stop and report -- do not
# edit it.

bats_require_minimum_version 1.5.0

load helpers/setup

WORKERS_LIB="$REPO_ROOT/scripts/lib/workers.sh"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    unset CLAUDE_ORCA_OPENCODE_PERMISSIONS
}

# opencode_config_from_env <env-file> -- the OPENCODE_CONFIG path an
# workers_opencode_command env file resolves to, sourced the same way the
# printed command sources it.
opencode_config_from_env() {
    bash -c "set -a; . '$1'; set +a; printf '%s' \"\$OPENCODE_CONFIG\""
}

@test "no variant, no token -- command still sources an env file naming a config with the permission block, no models, no baseURL" {
    RUN_DIR="$BATS_TEST_TMPDIR/run1"
    mkdir -p "$RUN_DIR"
    run bash -c ". '$WORKERS_LIB'; workers_opencode_command 'openrouter/openai/gpt-5.6-luna' '$RUN_DIR'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"opencode --model openrouter/openai/gpt-5.6-luna"* ]]
    [[ "$output" == *"openrouter-guard.env"* ]]

    env_file="$RUN_DIR/openrouter-guard.env"
    [ -f "$env_file" ]
    grep -q '^OPENCODE_CONFIG=' "$env_file"
    cfg="$(opencode_config_from_env "$env_file")"
    [ -f "$cfg" ]

    run jq -e '.permission["*"] == "allow"' "$cfg"
    [ "$status" -eq 0 ]
    run jq -e '.permission.bash["git push *"] == "deny"' "$cfg"
    [ "$status" -eq 0 ]
    run jq -e '.permission.external_directory["*"] == "allow"' "$cfg"
    [ "$status" -eq 0 ]
    run jq -e '.provider.openrouter.models == null' "$cfg"
    [ "$status" -eq 0 ]
    run jq -e '.provider.openrouter.options == null' "$cfg"
    [ "$status" -eq 0 ]
}

@test "variant high + token -- permission block AND reasoning.effort AND baseURL all present" {
    RUN_DIR="$BATS_TEST_TMPDIR/run2"
    mkdir -p "$RUN_DIR"
    printf 'tok-xyz\n' > "$RUN_DIR/openrouter-guard.token"
    run bash -c ". '$WORKERS_LIB'; workers_opencode_command 'openrouter/openai/gpt-5.6-luna' '$RUN_DIR' high"
    [ "$status" -eq 0 ]

    env_file="$RUN_DIR/openrouter-guard.env"
    cfg="$(opencode_config_from_env "$env_file")"
    [ -f "$cfg" ]

    run jq -e '.permission["*"] == "allow"' "$cfg"
    [ "$status" -eq 0 ]
    run jq -e '.permission.bash["git push *"] == "deny"' "$cfg"
    [ "$status" -eq 0 ]
    run jq -e '.permission.external_directory["*"] == "allow"' "$cfg"
    [ "$status" -eq 0 ]
    run jq -e '.provider.openrouter.models["openai/gpt-5.6-luna"].options.reasoning.effort == "high"' "$cfg"
    [ "$status" -eq 0 ]
    run jq -e '.provider.openrouter.options.baseURL == "http://127.0.0.1:4141/api/v1"' "$cfg"
    [ "$status" -eq 0 ]
}

@test "CLAUDE_ORCA_OPENCODE_PERMISSIONS=ask -- config still written but has no .permission key" {
    RUN_DIR="$BATS_TEST_TMPDIR/run3"
    mkdir -p "$RUN_DIR"
    export CLAUDE_ORCA_OPENCODE_PERMISSIONS=ask
    run bash -c "export CLAUDE_ORCA_OPENCODE_PERMISSIONS=ask; . '$WORKERS_LIB'; workers_opencode_command 'openrouter/openai/gpt-5.6-luna' '$RUN_DIR'"
    [ "$status" -eq 0 ]

    env_file="$RUN_DIR/openrouter-guard.env"
    [ -f "$env_file" ]
    cfg="$(opencode_config_from_env "$env_file")"
    [ -f "$cfg" ]
    run jq -e '.permission == null' "$cfg"
    [ "$status" -eq 0 ]
}

@test "the per-launch config file stays mode 600 with the permission block written" {
    RUN_DIR="$BATS_TEST_TMPDIR/run4"
    mkdir -p "$RUN_DIR"
    run bash -c ". '$WORKERS_LIB'; workers_opencode_command 'openrouter/openai/gpt-5.6-luna' '$RUN_DIR' high"
    [ "$status" -eq 0 ]
    env_file="$RUN_DIR/openrouter-guard.env"
    cfg="$(opencode_config_from_env "$env_file")"
    [ -f "$cfg" ]
    mode="$(stat -c %a "$cfg" 2>/dev/null || stat -f %Lp "$cfg" 2>/dev/null)"
    [ "$mode" = "600" ]
}
