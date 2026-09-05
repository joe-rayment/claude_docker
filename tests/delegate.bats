#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# delegate.bats -- scripts/delegate.sh: routes config, `check` health table,
# `run` (job worktree under the primary's .claude-dev, scrubbed-env runner
# invocation, JSON receipt, bead stamping), `ps` and `report`
# (claude-orca-3sk.28, S8 -- re-registered from claude-orca-3sk.19, whose
# frozen copy of this file carried two assertions no implementation could
# satisfy: a jq that indexed a string with "network", and an --acceptance
# needle the test's own bd fixture always planted).
#
# FROZEN per the bead's acceptance contract: this file must not be edited
# after its RED commit. If a case here turns out to be wrong, stop and
# report -- do not edit it.
#
# Ported from the old template's tests/delegate.bats. What changed and why:
#   - REPO_DIR is discovered from `git rev-parse --git-common-dir`, never a
#     hardcoded /workspace, so the same script serves the primary and every
#     linked worktree.
#   - job dirs live under <primary>/.claude-dev/delegate/<job>, inside the
#     sandbox's own writable scope, not a top-level .delegate/.
#   - egress preflight reads the sandbox allowlist (gen-settings.sh's
#     DEFAULT_DOMAINS + .claude-dev/sandbox.json's extraAllowedDomains, plus
#     the provider host implied by a present key) instead of inspecting
#     firewall rules -- there is no firewall inside this sandbox to read.
#   - three runners (opencode/codex/gemini), selected by route.runner.
#
# No real network and no real runner call anywhere below: stub opencode,
# codex, gemini and bd go first on PATH (tests/helpers/setup.bash), and
# every git/bd operation goes through a scratch fixture repo via
# $DELEGATE_REPO or an explicit cwd -- this repo's own worktree list and
# beads DB are never touched.

load helpers/setup

SCRIPT="$REPO_ROOT/scripts/delegate.sh"
SHIPPED_ROUTES="$REPO_ROOT/config/delegate-routes.json"
GITIGNORE="$REPO_ROOT/.gitignore"
GEN_SETTINGS="$REPO_ROOT/scripts/sandbox/gen-settings.sh"

# Overrides the helper's template-snapshot fixture: nothing here needs it.
setup_file() {
    export ORIGINAL_PATH="$PATH"
}

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"

    # Fixture HOME and cost-mirror state dir: delegate.sh hands every
    # receipt to cost-mirror, whose ledger otherwise defaults to
    # $HOME/.claude/cache/cost-mirror -- this machine's real one.
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cost-mirror"

    # Isolated routes config, same shape as the shipped one -- tests use the
    # $DELEGATE_ROUTES override so they never depend on production config
    # staying byte-for-byte stable; the shipped content is checked on its
    # own below by reading $SHIPPED_ROUTES directly.
    ROUTES="$BATS_TEST_TMPDIR/delegate-routes.json"
    cat > "$ROUTES" <<'EOF'
{ "routes": {
    "glm":    { "runner": "opencode", "model": "openrouter/z-ai/glm-5.2",
                "pin": { "order": ["novita","parasail"], "allow_fallbacks": false },
                "grade": "executor" },
    "local":  { "runner": "opencode", "model": "ollama/qwen3-coder:30b",
                "grade": "scout" },
    "cdx":    { "runner": "codex", "model": "openai/gpt-5-codex",
                "grade": "executor" },
    "gem":    { "runner": "gemini", "model": "gemini/gemini-3-pro",
                "grade": "executor" } } }
EOF
    export DELEGATE_ROUTES="$ROUTES"

    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    write_stub_opencode "$STUB_BIN/opencode"
    write_stub_codex    "$STUB_BIN/codex"
    write_stub_gemini   "$STUB_BIN/gemini"
    write_stub_bd       "$STUB_BIN/bd"
    export PATH="$STUB_BIN:$PATH"

    export BD_STUB_LOG="$BATS_TEST_TMPDIR/bd.log"
    : > "$BD_STUB_LOG"

    # A curated PATH carrying everything delegate.sh needs EXCEPT the three
    # runners, for the "runner absent" reason -- built from whatever this
    # machine resolves, so it never goes stale.
    NO_RUNNER_BIN="$BATS_TEST_TMPDIR/no-runner-bin"
    mkdir -p "$NO_RUNNER_BIN"
    for b in jq curl git python3 sed awk grep cat mkdir date dirname basename env tee wc bash sh kill sleep sort head tail cut printf; do
        src=$(command -v "$b" 2>/dev/null) || continue
        ln -sf "$src" "$NO_RUNNER_BIN/$b" 2>/dev/null || true
    done
    ln -sf "$STUB_BIN/bd" "$NO_RUNNER_BIN/bd"

    unset OPENROUTER_API_KEY OPENAI_API_KEY GEMINI_API_KEY
}

# make_repo <dir> [extra-allowed-domain ...] -- scratch git repo with one
# commit (so `worktree add ... HEAD` has something to branch from) and a
# .claude-dev/sandbox.json carrying the given extra allowed domains.
make_repo() {
    local dir="$1"; shift
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name "Test"
    printf 'scratch fixture\n' > "$dir/README.md"
    printf '.claude-dev/\n' > "$dir/.gitignore"
    git -C "$dir" add README.md .gitignore
    git -C "$dir" commit -qm init
    mkdir -p "$dir/.claude-dev"
    local domains
    domains=$(printf '%s\n' "$@" | jq -R . | jq -s -c 'map(select(. != ""))')
    jq -n --argjson d "$domains" \
        '{network: {extraAllowedDomains: $d}, filesystem: {extraAllowWrite: []}}' \
        > "$dir/.claude-dev/sandbox.json"
}

# make_bead <dir> <title> -- creates a bead through the bd stub, prints its id.
make_bead() {
    bd -C "$1" create "$2" -d "Do the delegated thing." \
        --acceptance "CHECK: true
PASS-IF: always green" | awk '{print $2}'
}

# fake_curl <bindir> ok|fail -- stands in for the reachability probe of a
# locally-served (loopback) model runtime.
fake_curl() {
    mkdir -p "$1"
    if [ "$2" = "ok" ]; then
        printf '#!/usr/bin/env bash\nexit 0\n' > "$1/curl"
    else
        printf '#!/usr/bin/env bash\nexit 7\n' > "$1/curl"
    fi
    chmod +x "$1/curl"
}

# job_dirs <repo> -- every job directory under the primary's delegate root.
job_dirs() {
    find "$1/.claude-dev/delegate" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort
}

# route_line <route> -- the $output row for one route of a `check` table.
route_line() {
    printf '%s\n' "$output" | grep -E "^$1[[:space:]]"
}

# ── check: per-route reason table ────────────────────────────────────────

@test "check: runner absent on PATH -> every route degraded with that reason" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" openrouter.ai api.openai.com generativelanguage.googleapis.com

    run env PATH="$NO_RUNNER_BIN" DELEGATE_REPO="$repo" \
        OPENROUTER_API_KEY=k OPENAI_API_KEY=k GEMINI_API_KEY=k \
        bash "$SCRIPT" check
    [ "$status" -eq 0 ]

    [[ "$(route_line glm)" == *degraded*"opencode not found on PATH"* ]]
    [[ "$(route_line cdx)" == *degraded*"codex not found on PATH"* ]]
    [[ "$(route_line gem)" == *degraded*"gemini not found on PATH"* ]]
}

@test "check: missing OPENROUTER_API_KEY -> glm degraded with that reason" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" openrouter.ai

    run env DELEGATE_REPO="$repo" bash "$SCRIPT" check
    [ "$status" -eq 0 ]
    [[ "$(route_line glm)" == *degraded*"OPENROUTER_API_KEY not set"* ]]
}

@test "check: ollama unreachable -> local degraded with that reason" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    fake_curl "$STUB_BIN" fail

    run env DELEGATE_REPO="$repo" bash "$SCRIPT" check
    [ "$status" -eq 0 ]
    [[ "$(route_line local)" == *degraded*"ollama unreachable"* ]]
}

@test "egress preflight fails with a clear message when the provider host is not in the allowlist" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"

    run env DELEGATE_REPO="$repo" bash "$SCRIPT" check
    [ "$status" -eq 0 ]
    line="$(route_line glm)"
    [[ "$line" == *degraded* ]]
    [[ "$line" == *openrouter.ai* ]]
    [[ "$line" == *"not in the sandbox allowlist"* ]]
    [[ "$line" == *extraAllowedDomains* ]]

    run env DELEGATE_REPO="$repo" bash "$SCRIPT" run --route glm --prompt "hello"
    [ "$status" -ne 0 ]
    [[ "$output" == *openrouter.ai* ]]
    [[ "$output" == *"not in the sandbox allowlist"* ]]
    [[ "$output" == *extraAllowedDomains* ]]
    [ -z "$(job_dirs "$repo")" ]
}

@test "check: allowlisted hosts and present keys -> every route live" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" openrouter.ai api.openai.com generativelanguage.googleapis.com
    fake_curl "$STUB_BIN" ok

    run env DELEGATE_REPO="$repo" \
        OPENROUTER_API_KEY=k OPENAI_API_KEY=k GEMINI_API_KEY=k \
        bash "$SCRIPT" check
    [ "$status" -eq 0 ]
    for r in glm local cdx gem; do
        [[ "$(route_line "$r")" == *live* ]]
    done
    [[ "$output" != *degraded* ]]
}

@test "check: an unavailable route never blocks the command -- exit is always 0" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"

    run env PATH="$NO_RUNNER_BIN" DELEGATE_REPO="$repo" bash "$SCRIPT" check
    [ "$status" -eq 0 ]
    [[ "$output" == *degraded* ]]
}

# ── run: dispatch guards ─────────────────────────────────────────────────

@test "run: unknown route lists known routes and exits nonzero" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"

    run env DELEGATE_REPO="$repo" bash "$SCRIPT" run --route nope --prompt hi
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown route 'nope'"* ]]
    [[ "$output" == *glm* ]]
    [[ "$output" == *local* ]]
}

@test "run: preflight failure is a loud error with the concrete reason, no job dir created" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" openrouter.ai

    run env DELEGATE_REPO="$repo" bash "$SCRIPT" run --route glm --prompt hi
    [ "$status" -ne 0 ]
    [[ "$output" == *"preflight failed"* ]]
    [[ "$output" == *"OPENROUTER_API_KEY not set"* ]]
    [ -z "$(job_dirs "$repo")" ]
}

@test "run: scout-grade route refuses --bead dispatch" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    fake_curl "$STUB_BIN" ok
    bead="$(make_bead "$repo" "delegated slice")"

    run env DELEGATE_REPO="$repo" bash "$SCRIPT" run --route local --bead "$bead"
    [ "$status" -ne 0 ]
    [[ "$output" == *"scout-grade"* ]]
    [ -z "$(job_dirs "$repo")" ]
}

@test "run: scout-grade route accepts prompt-only dispatch" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    fake_curl "$STUB_BIN" ok

    run env DELEGATE_REPO="$repo" bash "$SCRIPT" run --route local --prompt "look around"
    [ "$status" -eq 0 ]
    [ -n "$(job_dirs "$repo")" ]
}

# ── run: repo discovery and job layout ───────────────────────────────────

@test "REPO_DIR resolves from git-common-dir and never mentions /workspace" {
    run grep -nE '/workspace|/home/agent' "$SCRIPT"
    [ "$status" -eq 1 ]
    [ -z "$output" ]

    primary="$BATS_TEST_TMPDIR/primary"
    make_repo "$primary" openrouter.ai
    wt="$BATS_TEST_TMPDIR/primary-wt"
    git -C "$primary" worktree add -q -b side "$wt" HEAD

    run bash -c "cd '$wt' && env -u DELEGATE_REPO OPENROUTER_API_KEY=sk-test \
        DELEGATE_ROUTES='$ROUTES' bash '$SCRIPT' run --route glm --prompt hi"
    [ "$status" -eq 0 ]

    # The job landed under the PRIMARY, discovered from git-common-dir --
    # not under the linked worktree the command was issued from.
    [ -n "$(job_dirs "$primary")" ]
    [ ! -d "$wt/.claude-dev" ]

    # ...and `ps` issued from the linked worktree sees the same job root.
    run bash -c "cd '$wt' && env -u DELEGATE_REPO DELEGATE_ROUTES='$ROUTES' \
        bash '$SCRIPT' ps"
    [ "$status" -eq 0 ]
    [[ "$output" == *glm-* ]]
}

@test "job worktrees are created under <primary>/.claude-dev/delegate/<job>" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" openrouter.ai

    run env DELEGATE_REPO="$repo" OPENROUTER_API_KEY=sk-test \
        bash "$SCRIPT" run --route glm --prompt hi
    [ "$status" -eq 0 ]

    job_dir="$(job_dirs "$repo")"
    [ -d "$job_dir" ]
    job="$(basename "$job_dir")"
    [[ "$job" =~ ^glm-[0-9]+-[0-9a-f]+$ ]]
    [ "$job_dir" = "$repo/.claude-dev/delegate/$job" ]

    # a real linked git worktree on its own delegate/<job> branch
    [ -e "$job_dir/worktree/.git" ]
    run git -C "$repo" worktree list
    [[ "$output" == *"$job_dir/worktree"* ]]
    run git -C "$repo" rev-parse --verify "delegate/$job"
    [ "$status" -eq 0 ]
    [[ "$(cat "$job_dir/branch" 2>/dev/null || echo "delegate/$job")" == "delegate/$job" ]]
}

# ── run: the three runners ───────────────────────────────────────────────

@test "runner opencode, codex and gemini are each invoked with the route's model (stubbed binaries) and produce a receipt.json with the unchanged schema" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" openrouter.ai api.openai.com generativelanguage.googleapis.com

    schema="bead,branch,exit_code,finished_at,job,model,route,started_at,tokens_in,tokens_out,usd,wall_seconds"

    while read -r route runner model_arg full_model; do
        run env DELEGATE_REPO="$repo" \
            OPENROUTER_API_KEY=sk-or OPENAI_API_KEY=sk-oai GEMINI_API_KEY=sk-gem \
            bash "$SCRIPT" run --route "$route" --prompt "do the thing"
        [ "$status" -eq 0 ]

        job_dir="$(job_dirs "$repo" | grep -- "/$route-")"
        [ -d "$job_dir" ]

        # the stub that ran, and the model it was handed
        [ "$(cat "$job_dir/home/runner")" = "$runner" ]
        run grep -Fx -- "$model_arg" "$job_dir/home/$runner.argv"
        [ "$status" -eq 0 ]

        receipt="$job_dir/receipt.json"
        [ -f "$receipt" ]
        [ "$(jq -r 'keys | sort | join(",")' "$receipt")" = "$schema" ]
        [ "$(jq -r '.route' "$receipt")" = "$route" ]
        [ "$(jq -r '.model' "$receipt")" = "$full_model" ]
        [ "$(jq -r '.exit_code' "$receipt")" = "0" ]
        [ "$(jq -r '.bead' "$receipt")" = "null" ]
        [ "$(jq -r '.tokens_in | type' "$receipt")" = "number" ]
        [ "$(jq -r '.tokens_out | type' "$receipt")" = "number" ]
        [ "$(jq -r '.usd | type' "$receipt")" = "number" ]
        [ "$(jq -r '.wall_seconds | type' "$receipt")" = "number" ]
    done <<'ROUTES_EOF'
glm opencode openrouter/z-ai/glm-5.2 openrouter/z-ai/glm-5.2
cdx codex gpt-5-codex openai/gpt-5-codex
gem gemini gemini-3-pro gemini/gemini-3-pro
ROUTES_EOF
}

@test "run --route glm --bead: invokes opencode with the exact expected argv" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" openrouter.ai
    bead="$(make_bead "$repo" "delegated slice")"

    run env DELEGATE_REPO="$repo" OPENROUTER_API_KEY=sk-test \
        bash "$SCRIPT" run --route glm --bead "$bead"
    [ "$status" -eq 0 ]

    job_dir="$(job_dirs "$repo")"
    argv="$job_dir/home/opencode.argv"
    [ "$(sed -n 1p "$argv")" = "run" ]
    [ "$(sed -n 2p "$argv")" = "-m" ]
    [ "$(sed -n 3p "$argv")" = "openrouter/z-ai/glm-5.2" ]
    [ "$(sed -n 4p "$argv")" = "--dir" ]
    [ "$(sed -n 5p "$argv")" = "$job_dir/worktree" ]
    [ "$(sed -n 6p "$argv")" = "--auto" ]
    [ "$(sed -n 7p "$argv")" = "--format" ]
    [ "$(sed -n 8p "$argv")" = "json" ]
    # the composed brief: bead id, title, description and acceptance
    prompt="$(sed -n '9,$p' "$argv")"
    [[ "$prompt" == *"$bead"* ]]
    [[ "$prompt" == *"delegated slice"* ]]
    [[ "$prompt" == *"Do the delegated thing."* ]]
    [[ "$prompt" == *"CHECK: true"* ]]
}

@test "run --route cdx --prompt: invokes codex exec with the exact expected argv" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" api.openai.com

    run env DELEGATE_REPO="$repo" OPENAI_API_KEY=sk-test \
        bash "$SCRIPT" run --route cdx --prompt "port the thing"
    [ "$status" -eq 0 ]

    job_dir="$(job_dirs "$repo")"
    argv="$job_dir/home/codex.argv"
    [ "$(sed -n 1p "$argv")" = "exec" ]
    [ "$(sed -n 2p "$argv")" = "--model" ]
    [ "$(sed -n 3p "$argv")" = "gpt-5-codex" ]
    [ "$(sed -n 4p "$argv")" = "--cd" ]
    [ "$(sed -n 5p "$argv")" = "$job_dir/worktree" ]
    [ "$(sed -n 6p "$argv")" = "--json" ]
    [ "$(sed -n 7p "$argv")" = "--full-auto" ]
    [ "$(sed -n 8p "$argv")" = "port the thing" ]
    [ "$(sed -n 9p "$argv")" = "" ]
}

@test "run --route gem --prompt: invokes gemini with the exact expected argv, inside the job worktree" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" generativelanguage.googleapis.com

    run env DELEGATE_REPO="$repo" GEMINI_API_KEY=sk-test \
        bash "$SCRIPT" run --route gem --prompt "scout the thing"
    [ "$status" -eq 0 ]

    job_dir="$(job_dirs "$repo")"
    argv="$job_dir/home/gemini.argv"
    [ "$(sed -n 1p "$argv")" = "-m" ]
    [ "$(sed -n 2p "$argv")" = "gemini-3-pro" ]
    [ "$(sed -n 3p "$argv")" = "--yolo" ]
    [ "$(sed -n 4p "$argv")" = "-p" ]
    [ "$(sed -n 5p "$argv")" = "scout the thing" ]
    [ "$(sed -n 6p "$argv")" = "" ]
    # gemini has no --dir flag: it must be run WITH THE JOB WORKTREE as cwd
    [ "$(cat "$job_dir/home/gemini.cwd")" = "$job_dir/worktree" ]
}

# ── run: generated runner config and scrubbed env ────────────────────────

@test "run --route glm --bead: generated opencode config carries pin order, allow_fallbacks, and the env-var apiKey placeholder" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" openrouter.ai
    bead="$(make_bead "$repo" "delegated slice")"

    run env DELEGATE_REPO="$repo" OPENROUTER_API_KEY=sk-test \
        bash "$SCRIPT" run --route glm --bead "$bead"
    [ "$status" -eq 0 ]

    cfg="$(job_dirs "$repo")/config/opencode/opencode.json"
    [ -f "$cfg" ]
    m='.provider.openrouter.models["z-ai/glm-5.2"].options.provider'
    [ "$(jq -r '.provider.openrouter.options.apiKey' "$cfg")" = "{env:OPENROUTER_API_KEY}" ]
    [ "$(jq -r "$m.order | join(\",\")" "$cfg")" = "novita,parasail" ]
    [ "$(jq -r "$m.allow_fallbacks" "$cfg")" = "false" ]
}

@test "run --route local --prompt: generated config uses the openai-compatible ollama provider at the loopback endpoint" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    fake_curl "$STUB_BIN" ok

    run env DELEGATE_REPO="$repo" bash "$SCRIPT" run --route local --prompt hi
    [ "$status" -eq 0 ]

    cfg="$(job_dirs "$repo")/config/opencode/opencode.json"
    [ "$(jq -r '.provider.ollama.npm' "$cfg")" = "@ai-sdk/openai-compatible" ]
    [ "$(jq -r '.provider.ollama.options.baseURL' "$cfg")" = "http://127.0.0.1:11434/v1" ]
    [ "$(jq -r '.provider.ollama.models | keys | join(",")' "$cfg")" = "qwen3-coder:30b" ]
}

@test "run --route glm --bead: env handed to the runner has no ANTHROPIC_* vars and carries the key only because it's needed" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" openrouter.ai
    bead="$(make_bead "$repo" "delegated slice")"

    run env DELEGATE_REPO="$repo" OPENROUTER_API_KEY=sk-test \
        ANTHROPIC_API_KEY=sk-ant ANTHROPIC_MODEL=claude-fake \
        bash "$SCRIPT" run --route glm --bead "$bead"
    [ "$status" -eq 0 ]

    job_dir="$(job_dirs "$repo")"
    envfile="$job_dir/home/opencode.env"
    run grep -c '^ANTHROPIC' "$envfile"
    [ "$status" -ne 0 ]
    run grep -c '^DELEGATE_' "$envfile"
    [ "$status" -ne 0 ]
    grep -qx 'OPENROUTER_API_KEY=sk-test' "$envfile"
    grep -qx "HOME=$job_dir/home" "$envfile"
    grep -qx "XDG_CONFIG_HOME=$job_dir/config" "$envfile"
    grep -qx 'TERM=dumb' "$envfile"
}

@test "run --route local --prompt: env handed to the runner carries no OPENROUTER_API_KEY (not needed by this route)" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    fake_curl "$STUB_BIN" ok

    run env DELEGATE_REPO="$repo" OPENROUTER_API_KEY=sk-test \
        bash "$SCRIPT" run --route local --prompt hi
    [ "$status" -eq 0 ]

    run grep -c 'OPENROUTER_API_KEY' "$(job_dirs "$repo")/home/opencode.env"
    [ "$status" -ne 0 ]
}

@test "provider keys are emitted as srt credentials masks with the provider's injectHosts and never appear in the job env file" {
    # (a) the settings side: gen-settings.sh turns each present provider key
    #     into an srt credentials mask alongside the existing GH_TOKEN entry.
    primary="$BATS_TEST_TMPDIR/gs-primary"
    host="$BATS_TEST_TMPDIR/gs-host"
    real_home="$BATS_TEST_TMPDIR/gs-real-home"
    mkdir -p "$primary" "$host" "$real_home"
    sbx="$BATS_TEST_TMPDIR/gs-sandbox.json"
    echo '{}' > "$sbx"

    run bash "$GEN_SETTINGS" --primary "$primary" --worktree "$primary" \
        --real-home "$real_home" --host "$host" --sandbox-json "$sbx" \
        --gh-token-present --openrouter-key-present --openai-key-present \
        --gemini-key-present
    [ "$status" -eq 0 ]
    settings="$BATS_TEST_TMPDIR/settings.json"
    printf '%s\n' "$output" > "$settings"

    [ "$(jq -r '.credentials.envVars | length' "$settings")" = "4" ]
    [ "$(jq -r '[.credentials.envVars[].name] | join(",")' "$settings")" \
        = "GH_TOKEN,OPENROUTER_API_KEY,OPENAI_API_KEY,GEMINI_API_KEY" ]
    [ "$(jq -r '[.credentials.envVars[].mode] | unique | join(",")' "$settings")" = "mask" ]
    for pair in "OPENROUTER_API_KEY openrouter.ai" \
                "OPENAI_API_KEY api.openai.com" \
                "GEMINI_API_KEY generativelanguage.googleapis.com"; do
        set -- $pair
        [ "$(jq -r --arg n "$1" \
            '.credentials.envVars[] | select(.name == $n) | .injectHosts | join(",")' \
            "$settings")" = "$2" ]
    done
    # srt rejects an injectHost that allowedDomains cannot reach
    [ "$(jq -r '[.credentials.envVars[].injectHosts[]] - [.network.allowedDomains[]] | length' "$settings")" = "0" ]
    [ "$(jq -r '.network.tlsTerminate | type' "$settings")" = "object" ]

    # (b) the job side: the key value never lands in the env file the job writes.
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" openrouter.ai
    secret="sk-or-v1-supersecretkeymaterial"

    run env DELEGATE_REPO="$repo" OPENROUTER_API_KEY="$secret" \
        bash "$SCRIPT" run --route glm --prompt hi
    [ "$status" -eq 0 ]

    job_env="$(job_dirs "$repo")/env"
    [ -f "$job_env" ]
    grep -q 'OPENROUTER_API_KEY' "$job_env"
    run grep -F "$secret" "$job_env"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# ── run: receipt, redaction, bead stamping ───────────────────────────────

@test "run --route glm --bead: writes a receipt with the full schema and correct values" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" openrouter.ai
    bead="$(make_bead "$repo" "delegated slice")"

    run env DELEGATE_REPO="$repo" OPENROUTER_API_KEY=sk-test \
        bash "$SCRIPT" run --route glm --bead "$bead"
    [ "$status" -eq 0 ]

    job_dir="$(job_dirs "$repo")"
    job="$(basename "$job_dir")"
    r="$job_dir/receipt.json"
    [ "$(jq -r '.job' "$r")" = "$job" ]
    [ "$(jq -r '.route' "$r")" = "glm" ]
    [ "$(jq -r '.model' "$r")" = "openrouter/z-ai/glm-5.2" ]
    [ "$(jq -r '.bead' "$r")" = "$bead" ]
    [ "$(jq -r '.branch' "$r")" = "delegate/$job" ]
    [ "$(jq -r '.tokens_in' "$r")" = "1234" ]
    [ "$(jq -r '.tokens_out' "$r")" = "567" ]
    [ "$(jq -r '.usd' "$r")" = "0.0089" ]
    [ "$(jq -r '.exit_code' "$r")" = "0" ]
    [[ "$(jq -r '.started_at' "$r")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
    [[ "$(jq -r '.finished_at' "$r")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
    [ "$(jq -r '.wall_seconds | type' "$r")" = "number" ]

    # the run also reports the branch and the receipt path on stdout
    [[ "$output" == *"branch: delegate/$job"* ]]
    [[ "$output" == *"receipt: $r"* ]]
}

@test "run --route local --prompt: receipt has null bead and null tokens/usd when the event stream carries none" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    fake_curl "$STUB_BIN" ok
    # a runner whose stream carries no usage/cost event at all
    cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
echo '{"type":"message","role":"assistant","text":"working"}'
exit 0
STUB
    chmod +x "$STUB_BIN/opencode"

    run env DELEGATE_REPO="$repo" bash "$SCRIPT" run --route local --prompt hi
    [ "$status" -eq 0 ]

    r="$(job_dirs "$repo")/receipt.json"
    [ "$(jq -r '.bead' "$r")" = "null" ]
    [ "$(jq -r '.tokens_in' "$r")" = "null" ]
    [ "$(jq -r '.tokens_out' "$r")" = "null" ]
    [ "$(jq -r '.usd' "$r")" = "null" ]
    [ "$(jq -r '.exit_code' "$r")" = "0" ]
}

@test "run --route glm --bead: no key material anywhere in the receipt or the log" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" openrouter.ai
    bead="$(make_bead "$repo" "delegated slice")"
    secret="sk-or-v1-leakcanary0123456789"
    # a runner that echoes its own key back into the event stream
    cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$HOME"
printf '%s\n' "$@" > "$HOME/opencode.argv"
env > "$HOME/opencode.env"
echo opencode > "$HOME/runner"
printf '{"type":"message","text":"key is %s"}\n' "$OPENROUTER_API_KEY"
printf '{"type":"finish","usage":{"inputTokens":1,"outputTokens":2,"cost":0.1}}\n'
exit 0
STUB
    chmod +x "$STUB_BIN/opencode"

    run env DELEGATE_REPO="$repo" OPENROUTER_API_KEY="$secret" \
        bash "$SCRIPT" run --route glm --bead "$bead"
    [ "$status" -eq 0 ]

    job_dir="$(job_dirs "$repo")"
    run grep -rF "$secret" "$job_dir/receipt.json" "$job_dir/runner.log" "$job_dir/env"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    grep -qF 'REDACTED' "$job_dir/runner.log"
}

@test "bead notes receive delegated-to, branch and receipt lines" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" openrouter.ai
    bead="$(make_bead "$repo" "delegated slice")"

    run env DELEGATE_REPO="$repo" OPENROUTER_API_KEY=sk-test \
        bash "$SCRIPT" run --route glm --bead "$bead"
    [ "$status" -eq 0 ]

    job_dir="$(job_dirs "$repo")"
    job="$(basename "$job_dir")"
    notes="$(bd -C "$repo" show "$bead" --json | jq -r '.[0].notes')"
    [[ "$notes" == *"delegated-to: glm"* ]]
    [[ "$notes" == *"branch: delegate/$job"* ]]
    [[ "$notes" == *"receipt: $job_dir/receipt.json"* ]]

    # appended, never a rewrite of the bead's acceptance field (the
    # fixture's own `bd create --acceptance` is not delegate.sh's doing)
    grep -q -- "--append-notes" "$BD_STUB_LOG"
    run grep -- "update .* --acceptance" "$BD_STUB_LOG"
    [ "$status" -ne 0 ]
}

@test "run --route local --prompt: no bead given -> no bd stamping attempted, run still succeeds" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    fake_curl "$STUB_BIN" ok

    run env DELEGATE_REPO="$repo" bash "$SCRIPT" run --route local --prompt hi
    [ "$status" -eq 0 ]
    [ -f "$(job_dirs "$repo")/receipt.json" ]
    run grep -- "--append-notes" "$BD_STUB_LOG"
    [ "$status" -ne 0 ]
}

@test "run --route glm --bead: the receipt is handed to cost-mirror's delegate ledger" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo" openrouter.ai
    bead="$(make_bead "$repo" "delegated slice")"
    state="$BATS_TEST_TMPDIR/cost-state"
    mkdir -p "$state"

    run env DELEGATE_REPO="$repo" OPENROUTER_API_KEY=sk-test \
        COST_MIRROR_STATE_DIR="$state" \
        bash "$SCRIPT" run --route glm --bead "$bead"
    [ "$status" -eq 0 ]

    job="$(basename "$(job_dirs "$repo")")"
    [ -f "$state/lifetime.json" ]
    [ "$(jq -r --arg j "$job" \
        '[.sessions[] | select(.side == "delegate" and .sessionId == $j)] | length' \
        "$state/lifetime.json")" = "1" ]
}

# ── ps: job listing ──────────────────────────────────────────────────────

@test "ps: lists a running job (pid alive, no receipt) and a done job (receipt present, retained)" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    root="$repo/.claude-dev/delegate"
    mkdir -p "$root/glm-1700000000-aaaa" "$root/local-1700000001-bbbb"
    sleep 30 &
    live=$!
    echo "$live" > "$root/glm-1700000000-aaaa/pid"
    echo '{}' > "$root/local-1700000001-bbbb/receipt.json"

    run env DELEGATE_REPO="$repo" bash "$SCRIPT" ps
    kill "$live" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$(printf '%s\n' "$output" | grep glm-1700000000-aaaa)" == *running* ]]
    [[ "$(printf '%s\n' "$output" | grep local-1700000001-bbbb)" == *done* ]]
    [ -d "$root/local-1700000001-bbbb" ]
}

@test "ps: a job whose pid is no longer alive and has no receipt is not reported as running" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    root="$repo/.claude-dev/delegate"
    mkdir -p "$root/glm-1700000000-cccc"
    sleep 0 &
    dead=$!
    wait "$dead" 2>/dev/null || true
    echo "$dead" > "$root/glm-1700000000-cccc/pid"

    run env DELEGATE_REPO="$repo" bash "$SCRIPT" ps
    [ "$status" -eq 0 ]
    [[ "$(printf '%s\n' "$output" | grep glm-1700000000-cccc)" != *running* ]]
}

@test "ps: no jobs dir yet -> empty table, exit 0" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"

    run env DELEGATE_REPO="$repo" bash "$SCRIPT" ps
    [ "$status" -eq 0 ]
    [[ "$output" == *JOB* ]]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

# ── shipped config ───────────────────────────────────────────────────────

@test "config/delegate-routes.json: ships glm and local plus codex and gemini example routes" {
    [ -f "$SHIPPED_ROUTES" ]
    run jq -e . "$SHIPPED_ROUTES"
    [ "$status" -eq 0 ]

    [ "$(jq -r '.routes | keys | join(",")' "$SHIPPED_ROUTES")" = "codex,gemini,glm,local" ]
    [ "$(jq -r '.routes.glm.runner' "$SHIPPED_ROUTES")" = "opencode" ]
    [ "$(jq -r '.routes.glm.model' "$SHIPPED_ROUTES")" = "openrouter/z-ai/glm-5.2" ]
    [ "$(jq -r '.routes.glm.pin.order | join(",")' "$SHIPPED_ROUTES")" = "novita,parasail" ]
    [ "$(jq -r '.routes.glm.pin.allow_fallbacks' "$SHIPPED_ROUTES")" = "false" ]
    [ "$(jq -r '.routes.glm.grade' "$SHIPPED_ROUTES")" = "executor" ]
    [ "$(jq -r '.routes.local.runner' "$SHIPPED_ROUTES")" = "opencode" ]
    [ "$(jq -r '.routes.local.grade' "$SHIPPED_ROUTES")" = "scout" ]
    [ "$(jq -r '.routes.codex.runner' "$SHIPPED_ROUTES")" = "codex" ]
    [ "$(jq -r '.routes.codex.model | split("/") | .[0]' "$SHIPPED_ROUTES")" = "openai" ]
    [ "$(jq -r '.routes.gemini.runner' "$SHIPPED_ROUTES")" = "gemini" ]
    [ "$(jq -r '.routes.gemini.model | split("/") | .[0]' "$SHIPPED_ROUTES")" = "gemini" ]
    [ "$(jq -r '[.routes[].grade] | unique | join(",")' "$SHIPPED_ROUTES")" = "executor,scout" ]
}

@test ".gitignore: the delegate job root is ignored" {
    grep -qxF '.claude-dev/' "$GITIGNORE"
}

# ── report: per-route jobs, verdicts and dollars ─────────────────────────

# stamp <repo> <bead> <text> -- appends one note block, as cmd_run does.
stamp() {
    bd -C "$1" update "$2" --append-notes "$3"
}

@test "report: no delegated beads and no ledger rows -> clear empty-state line, no table, exit 0" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"

    run env DELEGATE_REPO="$repo" COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/empty" \
        bash "$SCRIPT" report
    [ "$status" -eq 0 ]
    [[ "$output" == *"no delegated beads yet"* ]]
    [[ "$output" != *ROUTE* ]]
}

@test "report: one bead delegated to glm with a PASS verdict -> jobs=1 PASS=1 FAIL=0 TAMPERED=0, \$0.00 with no ledger row" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    bead="$(make_bead "$repo" "delegated slice")"
    stamp "$repo" "$bead" "delegated-to: glm
branch: delegate/glm-1700000000-aaaa
receipt: /nowhere/receipt.json"
    stamp "$repo" "$bead" "VERIFIED: PASS"

    run env DELEGATE_REPO="$repo" COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/empty" \
        bash "$SCRIPT" report
    [ "$status" -eq 0 ]
    [[ "$output" == *ROUTE* ]]
    [[ "$(route_line glm)" =~ ^glm[[:space:]]+1[[:space:]]+1[[:space:]]+0[[:space:]]+0[[:space:]]+\$0\.00$ ]]
}

@test "report: ledger USD joins onto the bead-derived route row by route name" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    bead="$(make_bead "$repo" "delegated slice")"
    stamp "$repo" "$bead" "delegated-to: glm
branch: delegate/glm-1700000000-aaaa"

    state="$BATS_TEST_TMPDIR/state"
    mkdir -p "$state"
    jq -n '{sessions: {"k": {sessionId: "glm-1700000000-aaaa", side: "delegate", cost_total: 1.25}}}' \
        > "$state/lifetime.json"

    run env DELEGATE_REPO="$repo" COST_MIRROR_STATE_DIR="$state" bash "$SCRIPT" report
    [ "$status" -eq 0 ]
    [[ "$(route_line glm)" =~ ^glm[[:space:]]+1[[:space:]]+0[[:space:]]+0[[:space:]]+0[[:space:]]+\$1\.25$ ]]
}

@test "report: a bead redone onto a different route -- each verdict is counted against the route it actually followed" {
    repo="$BATS_TEST_TMPDIR/repo"
    make_repo "$repo"
    bead="$(make_bead "$repo" "delegated slice")"
    stamp "$repo" "$bead" "delegated-to: glm"
    stamp "$repo" "$bead" "VERIFIED: FAIL"
    stamp "$repo" "$bead" "delegated-to: cdx"
    stamp "$repo" "$bead" "VERIFIED: PASS"

    run env DELEGATE_REPO="$repo" COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/empty" \
        bash "$SCRIPT" report
    [ "$status" -eq 0 ]
    [[ "$(route_line glm)" =~ ^glm[[:space:]]+1[[:space:]]+0[[:space:]]+1[[:space:]]+0 ]]
    [[ "$(route_line cdx)" =~ ^cdx[[:space:]]+1[[:space:]]+1[[:space:]]+0[[:space:]]+0 ]]
}
