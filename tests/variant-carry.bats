#!/usr/bin/env bats
#
# variant-carry.bats -- a role's reasoning-effort variant (tier.json
# roles.<role>.variant, claude-orca-1w8) must actually reach opencode on
# both the interactive launch path (workers_opencode_command -> `opencode`
# TUI) and the batch path (bin/delegate run -> `opencode run`)
# (claude-orca-1w8 slice B, claude-orca-dav).
#
# Verified in this container on opencode 1.18.25 (2026-09-16): the TUI has
# no --variant flag, but a config file naming
# provider.openrouter.models.<vendor/model>.options.reasoning.effort turns
# reasoning tokens on; opencode honours OPENCODE_CONFIG pointed at it.
#
# FROZEN from RED-AT onward: this file must not be edited after its RED
# commit. If a case here turns out to be wrong, stop and report -- do not
# edit it.

bats_require_minimum_version 1.5.0

load helpers/setup

SCRIPT="$REPO_ROOT/scripts/delegate.sh"
WORKERS_LIB="$REPO_ROOT/scripts/lib/workers.sh"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cost-mirror"

    LUNA_ROUTES="$BATS_TEST_TMPDIR/luna-routes.json"
    cat > "$LUNA_ROUTES" <<'EOF'
{ "routes": {
    "luna":      { "runner": "opencode", "model": "openrouter/openai/gpt-5.6-luna",
                   "grade": "executor" },
    "luna-high": { "runner": "opencode", "model": "openrouter/openai/gpt-5.6-luna",
                   "grade": "executor", "variant": "high" }
} }
EOF

    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    write_stub_opencode "$STUB_BIN/opencode"
    export PATH="$STUB_BIN:$PATH"

    unset OPENROUTER_API_KEY OPENAI_API_KEY GEMINI_API_KEY
}

# make_repo <dir> -- scratch git repo with one commit and a .claude-dev
# root, same shape tests/delegate.bats uses.
make_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name "Test"
    printf 'scratch fixture\n' > "$dir/README.md"
    printf '.claude-dev/\n' > "$dir/.gitignore"
    git -C "$dir" add README.md .gitignore
    git -C "$dir" commit -qm init
    mkdir -p "$dir/.claude-dev"
}

job_dirs() {
    find "$1/.claude-dev/delegate" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort
}

# opencode_config_from_env <env-file> -- the OPENCODE_CONFIG path an
# workers_opencode_command env file resolves to, sourced the same way the
# printed command sources it.
opencode_config_from_env() {
    bash -c "set -a; . '$1'; set +a; printf '%s' \"\$OPENCODE_CONFIG\""
}

# ── 1-4: workers_opencode_command (interactive launch path) ─────────────

@test "workers_opencode_command: variant only (no token) -- reasoning.effort set, no baseURL" {
    RUN_DIR="$BATS_TEST_TMPDIR/run1"
    mkdir -p "$RUN_DIR"
    run bash -c ". '$WORKERS_LIB'; workers_opencode_command 'openrouter/openai/gpt-5.6-luna' '$RUN_DIR' high"
    [ "$status" -eq 0 ]
    [[ "$output" == *"opencode --model openrouter/openai/gpt-5.6-luna"* ]]
    [[ "$output" == *"openrouter-guard.env"* ]]

    env_file="$RUN_DIR/openrouter-guard.env"
    [ -f "$env_file" ]
    grep -q '^OPENCODE_CONFIG=' "$env_file"
    cfg="$(opencode_config_from_env "$env_file")"
    [ -f "$cfg" ]
    run jq -e '.provider.openrouter.models["openai/gpt-5.6-luna"].options.reasoning.effort == "high"' "$cfg"
    [ "$status" -eq 0 ]
    run jq -e '.provider.openrouter.options == null' "$cfg"
    [ "$status" -eq 0 ]
}

@test "workers_opencode_command: variant + token -- baseURL and apiKey also set, env carries the key" {
    RUN_DIR="$BATS_TEST_TMPDIR/run2"
    mkdir -p "$RUN_DIR"
    printf 'tok-xyz\n' > "$RUN_DIR/openrouter-guard.token"
    run bash -c ". '$WORKERS_LIB'; workers_opencode_command 'openrouter/openai/gpt-5.6-luna' '$RUN_DIR' high"
    [ "$status" -eq 0 ]

    env_file="$RUN_DIR/openrouter-guard.env"
    [ -f "$env_file" ]
    grep -q '^OPENROUTER_API_KEY=' "$env_file"
    grep -q '^OPENCODE_CONFIG=' "$env_file"
    cfg="$(opencode_config_from_env "$env_file")"
    [ -f "$cfg" ]
    run jq -e '.provider.openrouter.options.baseURL == "http://127.0.0.1:4141/api/v1"' "$cfg"
    [ "$status" -eq 0 ]
    run jq -e '.provider.openrouter.options.apiKey == "{env:OPENROUTER_API_KEY}"' "$cfg"
    [ "$status" -eq 0 ]
    run jq -e '.provider.openrouter.models["openai/gpt-5.6-luna"].options.reasoning.effort == "high"' "$cfg"
    [ "$status" -eq 0 ]
}

@test "workers_opencode_command: no variant, no token -- sources an env file naming a permission-only config, no models, no baseURL" {
    # Edited for claude-orca-gh9 (permission block now written on every
    # launch so a dispatched worker never stalls on opencode's interactive
    # "ask" default) -- coordinator-authorised one-case change to this
    # closed bead's (claude-orca-y0y) frozen file; see claude-orca-gh9 notes.
    RUN_DIR="$BATS_TEST_TMPDIR/run3"
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
    run jq -e '.permission != null' "$cfg"
    [ "$status" -eq 0 ]
    run jq -e '.provider.openrouter.models == null' "$cfg"
    [ "$status" -eq 0 ]
    run jq -e '.provider.openrouter.options == null' "$cfg"
    [ "$status" -eq 0 ]
}

@test "workers_opencode_command: the per-launch config file is mode 600" {
    RUN_DIR="$BATS_TEST_TMPDIR/run4"
    mkdir -p "$RUN_DIR"
    run bash -c ". '$WORKERS_LIB'; workers_opencode_command 'openrouter/openai/gpt-5.6-luna' '$RUN_DIR' high"
    [ "$status" -eq 0 ]
    env_file="$RUN_DIR/openrouter-guard.env"
    cfg="$(opencode_config_from_env "$env_file")"
    [ -f "$cfg" ]
    [ "$(stat -c '%a' "$cfg")" = "600" ]
}

# ── 5-7: delegate run (batch path) ────────────────────────────────────────

@test "delegate run --route luna-high: reasoning.effort high, receipt.variant high" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    run env DELEGATE_REPO="$repo" DELEGATE_ROUTES="$LUNA_ROUTES" OPENROUTER_API_KEY=sk-or-test \
        bash "$SCRIPT" run --route luna-high --prompt "do the thing"
    [ "$status" -eq 0 ]

    job_dir="$(job_dirs "$repo" | grep -- '/luna-high-')"
    [ -d "$job_dir" ]
    cfg="$job_dir/config/opencode/opencode.json"
    [ -f "$cfg" ]
    run jq -e '.provider.openrouter.models["openai/gpt-5.6-luna"].options.reasoning.effort == "high"' "$cfg"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.variant' "$job_dir/receipt.json")" = "high" ]
}

@test "delegate run --route luna --variant low: CLI overrides the route's (absent) default" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    run env DELEGATE_REPO="$repo" DELEGATE_ROUTES="$LUNA_ROUTES" OPENROUTER_API_KEY=sk-or-test \
        bash "$SCRIPT" run --route luna --variant low --prompt "do the thing"
    [ "$status" -eq 0 ]

    job_dir="$(job_dirs "$repo" | grep -- '/luna-' | grep -v -- '-high-')"
    [ -d "$job_dir" ]
    cfg="$job_dir/config/opencode/opencode.json"
    [ -f "$cfg" ]
    run jq -e '.provider.openrouter.models["openai/gpt-5.6-luna"].options.reasoning.effort == "low"' "$cfg"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.variant' "$job_dir/receipt.json")" = "low" ]
}

@test "delegate run --route luna with no variant anywhere: no reasoning key, receipt.variant null" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    run env DELEGATE_REPO="$repo" DELEGATE_ROUTES="$LUNA_ROUTES" OPENROUTER_API_KEY=sk-or-test \
        bash "$SCRIPT" run --route luna --prompt "do the thing"
    [ "$status" -eq 0 ]

    job_dir="$(job_dirs "$repo" | grep -- '/luna-' | grep -v -- '-high-')"
    [ -d "$job_dir" ]
    cfg="$job_dir/config/opencode/opencode.json"
    [ -f "$cfg" ]
    run jq -e '.provider.openrouter.models["openai/gpt-5.6-luna"].options | has("reasoning") | not' "$cfg"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.variant' "$job_dir/receipt.json")" = "null" ]
}

# ── 9: shipped config ─────────────────────────────────────────────────────

@test "config/delegate-routes.json ships luna and luna-high, and delegate check lists every route" {
    SHIPPED="$REPO_ROOT/config/delegate-routes.json"
    [ "$(jq -r '.routes.luna.runner' "$SHIPPED")" = "opencode" ]
    [ "$(jq -r '.routes.luna.model' "$SHIPPED")" = "openrouter/~openai/gpt-luna-latest" ]
    [ "$(jq -r '.routes.luna.grade' "$SHIPPED")" = "executor" ]
    [ "$(jq -r '.routes.luna | has("variant")' "$SHIPPED")" = "false" ]
    [ "$(jq -r '.routes["luna-high"].runner' "$SHIPPED")" = "opencode" ]
    [ "$(jq -r '.routes["luna-high"].model' "$SHIPPED")" = "openrouter/~openai/gpt-luna-latest" ]
    [ "$(jq -r '.routes["luna-high"].variant' "$SHIPPED")" = "high" ]
    [ "$(jq -r '.routes["luna-high"].grade' "$SHIPPED")" = "executor" ]

    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    run env DELEGATE_REPO="$repo" bash "$SCRIPT" check
    [ "$status" -eq 0 ]
    for r in $(jq -r '.routes | keys[]' "$SHIPPED"); do
        [[ "$output" == *"$r"* ]]
    done
}
