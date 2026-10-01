#!/usr/bin/env bats
#
# opencode-openai-launch.bats -- an openai/... model (the user's ChatGPT
# subscription, signed in with opencode's own login) runs through the same
# two launch paths an openrouter/... model does: orca-dispatch (headless and
# --tui) and recon (epic claude-orca-c3p, slice B2 / claude-orca-c3p.2).
# Covers the readiness/catalogue/resolve helpers appended to
# scripts/lib/tier-roles.sh, the ONE per-launch config writer
# scripts/lib/opencode-launch.sh behind orca_opencode_command and recon,
# and the signed-in guards orca-dispatch and recon put in front of an
# openai/ launch. Every openrouter/ behaviour stays what it is today; the
# frozen files pin that, this file pins the new provider.
#
# Nothing here touches a network or a real opencode: the auth store is a
# fixture pointed at by TIER_OPENAI_AUTH_FILE, the catalogue is a fixture
# pointed at by TIER_OPENAI_MODELS_FILE (or a stub opencode via
# TIER_OPENCODE_BIN), and the Orca runtime is the stub in
# tests/helpers/orca-stub.bash. Scripts are pinned by repo path, never
# trusted to PATH; PROJECT_DIR/CLAUDE_ORCA_ROOT point at this test's own
# tmp dir so no ambient project is inherited.
#
# FROZEN from RED-AT onward: this file must not be edited after its RED
# commit. If a case here turns out to be wrong, stop and report -- do not
# edit it.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME:-.}/.." && pwd)"
ROLES="$REPO_ROOT/scripts/lib/tier-roles.sh"
LAUNCH="$REPO_ROOT/scripts/lib/opencode-launch.sh"
ORCA_ORCH="$REPO_ROOT/scripts/lib/orca-orch.sh"
DISPATCH="$REPO_ROOT/scripts/orca-dispatch.sh"
RECON="$REPO_ROOT/scripts/recon.sh"

setup() {
    T="$BATS_TEST_TMPDIR"
    # Never inherit the ambient project or a real credentials store.
    unset PROJECT_DIR BEADS_DIR TIER_STATE_FILE
    unset OPENROUTER_API_KEY OPENCODE_CONFIG
    unset TIER_OPENAI_AUTH_FILE TIER_OPENAI_MODELS_FILE TIER_OPENCODE_BIN \
        TIER_OPENCODE_MODELS_CACHE CLAUDE_ORCA_OPENCODE_PERMISSIONS
    unset RECON_STATE_FILE RECON_RUN_DIR CLAUDE_ORCA_RECON_TIMEOUT_S
    export HOME="$T/home"
    mkdir -p "$HOME"
    export CLAUDE_ORCA_ROOT="$T/root"
    export PROJECT_DIR="$CLAUDE_ORCA_ROOT"
    RUN="$CLAUDE_ORCA_ROOT/.claude-dev/run"
    mkdir -p "$RUN"
}

# auth_fixture <json> -- an opencode auth.json at the path
# tier_openai_auth_file resolves (tests pin the file, never a real login).
auth_fixture() {
    export TIER_OPENAI_AUTH_FILE="$T/auth.json"
    printf '%s\n' "$1" >"$TIER_OPENAI_AUTH_FILE"
}

# catalogue_fixture -- the models the (fake) subscription serves: two
# gpt-luna ids on one release date, two gpt-sol ids on a newer date (plus
# an older gpt-sol), and a lone gpt-mini.
catalogue_fixture() {
    export TIER_OPENAI_MODELS_FILE="$T/models.json"
    cat >"$TIER_OPENAI_MODELS_FILE" <<'JSON'
[
  {"id": "gpt-5.6-luna", "family": "gpt-luna", "release_date": "2026-07-09"},
  {"id": "gpt-5.6-luna-fast", "family": "gpt-luna", "release_date": "2026-07-09"},
  {"id": "gpt-5.6-sol", "family": "gpt-sol", "release_date": "2026-07-09"},
  {"id": "gpt-6.1-sol", "family": "gpt-sol", "release_date": "2026-09-29"},
  {"id": "gpt-6.1-sol-fast", "family": "gpt-sol", "release_date": "2026-09-29"},
  {"id": "gpt-5.4-mini", "family": "gpt-mini", "release_date": "2026-03-17"}
]
JSON
}

# opencode_stub -- an `opencode` on PATH that logs its argv one per line,
# records OPENROUTER_API_KEY / OPENCODE_CONFIG, and prints a canned
# --format json event stream (the tests/recon.bats stub, no sleep/exit).
opencode_stub() {
    mkdir -p "$T/bin"
    export STUB_LOG="$T/opencode-stub.log"
    export STUB_ENV="$T/opencode-stub.env"
    rm -f "$STUB_LOG" "$STUB_ENV"
    cat >"$T/bin/opencode" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    printf '%s\n' "$a" >>"$STUB_LOG"
done
{
    printf 'OPENROUTER_API_KEY=%s\n' "$OPENROUTER_API_KEY"
    printf 'OPENCODE_CONFIG=%s\n' "$OPENCODE_CONFIG"
} >>"$STUB_ENV"
printf '%s\n' '{"type":"text","part":{"text":"- scripts/a.sh:12 does X"}}'
printf '%s\n' '{"type":"step_finish","part":{"tokens":{"input":10,"output":20,"reasoning":5},"cost":0.001}}'
printf '%s\n' '{"type":"text","part":{"text":"- nothing under src/ matches"}}'
exit 0
STUB
    chmod +x "$T/bin/opencode"
    export PATH="$T/bin:$PATH"
}

# recon_fixture <model> -- tier.json binding recon to orca:opencode:<model>@high
# in this test's own root, the way tests/recon.bats builds one.
recon_fixture() {
    printf '{"name":"fixture","version":"0"}\n' \
        >"$CLAUDE_ORCA_ROOT/.claude-dev/claude-orca.json"
    jq -n --arg m "$1" \
        '{top:"fable", roles:{recon:{backend:"orca", agent:"opencode",
          model:$m, pinned:true, variant:"high"}}}' >"$RUN/tier.json"
    export RECON_STATE_FILE="$RUN/tier.json"
    export RECON_RUN_DIR="$RUN"
    export COST_MIRROR_STATE_DIR="$T/cost-mirror"
}

# ── tier_openai_ready ─────────────────────────────────────────────────────

@test "tier_openai_ready: an oauth login with a refresh token is ready" {
    # Guards: an OpenAI ChatGPT sign-in (opencode's own auth.json, oauth
    # type) is what an openai/ launch needs before it can run.
    # Fails if: tier_openai_ready stops reading the store or demands an
    # api key.
    # Run:      bats tests/opencode-openai-launch.bats
    auth_fixture '{"openai":{"type":"oauth","refresh":"rtok","access":"atok","expires":9999999999999}}'
    run bash -c ". '$ROLES'; tier_openai_ready && echo READY || echo NOT"
    [ "$status" -eq 0 ]
    [ "$output" = "READY" ]
}

@test "tier_openai_ready: an oauth login with an empty refresh token is not" {
    # Guards: an expired/empty oauth credential is treated as signed out,
    # so launch paths refuse instead of half-starting.
    # Fails if: the emptiness of .openai.refresh stops mattering.
    # Run:      bats tests/opencode-openai-launch.bats
    auth_fixture '{"openai":{"type":"oauth","refresh":"","access":"atok"}}'
    run bash -c ". '$ROLES'; tier_openai_ready && echo READY || echo NOT"
    [ "$status" -eq 0 ]
    [ "$output" = "NOT" ]
}

@test "tier_openai_ready: an api-key login is ready too" {
    # Guards: opencode's api-key shape of the same store counts as signed
    # in, so headless folders that key up can launch.
    # Fails if: only the oauth shape is accepted.
    # Run:      bats tests/opencode-openai-launch.bats
    auth_fixture '{"openai":{"type":"api","key":"sk-openai-test"}}'
    run bash -c ". '$ROLES'; tier_openai_ready && echo READY || echo NOT"
    [ "$status" -eq 0 ]
    [ "$output" = "READY" ]
}

@test "tier_openai_ready: a missing auth file is not ready" {
    # Guards: no sign-in at all reads as signed out, never as ready.
    # Fails if: the helper answers READY when the store does not exist.
    # Run:      bats tests/opencode-openai-launch.bats
    export TIER_OPENAI_AUTH_FILE="$T/no-such-auth.json"
    run bash -c ". '$ROLES'; tier_openai_ready && echo READY || echo NOT"
    [ "$status" -eq 0 ]
    [ "$output" = "NOT" ]
}

@test "tier_openai_ready: a non-JSON auth file is not ready" {
    # Guards: a corrupt or truncated store reads as signed out.
    # Fails if: a parse error is mistaken for a login.
    # Run:      bats tests/opencode-openai-launch.bats
    auth_fixture 'this is not json {'
    run bash -c ". '$ROLES'; tier_openai_ready && echo READY || echo NOT"
    [ "$status" -eq 0 ]
    [ "$output" = "NOT" ]
}

# ── tier_openai_resolve ───────────────────────────────────────────────────

@test "tier_openai_resolve: ~<family>-latest binds the family's newest id, shortest id wins ties" {
    # Guards: openai/~gpt-luna-latest and openai/~gpt-sol-latest resolve AT
    # LAUNCH to the newest id of that family the subscription serves --
    # highest release_date, then the shortest id (the non -fast twin).
    # Fails if: the alias is launched literally, an older release wins, or
    # -fast beats its shorter twin.
    # Run:      bats tests/opencode-openai-launch.bats
    catalogue_fixture
    run bash -c ". '$ROLES'; tier_openai_resolve 'openai/~gpt-luna-latest'"
    [ "$status" -eq 0 ]
    [ "$output" = "openai/gpt-5.6-luna" ]

    run bash -c ". '$ROLES'; tier_openai_resolve 'openai/~gpt-sol-latest'"
    [ "$status" -eq 0 ]
    [ "$output" = "openai/gpt-6.1-sol" ]
}

@test "tier_openai_resolve: an unknown family fails, naming the family and opencode models openai" {
    # Guards: a family the subscription does not serve is a clean refusal,
    # not a bare --model opencode will reject downstream.
    # Fails if: the resolver exits 0 with an empty/guessed model, or the
    # message stops naming the family or `opencode models openai`.
    # Run:      bats tests/opencode-openai-launch.bats
    catalogue_fixture
    run bash -c ". '$ROLES'; tier_openai_resolve 'openai/~gpt-astra-latest' 2>'$T/err.txt'"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    grep -q 'gpt-astra' "$T/err.txt"
    grep -q 'opencode models openai' "$T/err.txt"
}

@test "tier_openai_resolve: a concrete id or another provider passes through, catalogue never consulted" {
    # Guards: openai/<id> and openrouter/... launch exactly as written --
    # resolution is for the ~-latest aliases only.
    # Fails if: resolving a concrete model needs a catalogue (or rewrites
    # an openrouter alias).
    # Run:      bats tests/opencode-openai-launch.bats
    # No catalogue source at all: no fixture, not signed in, no cache.
    run bash -c ". '$ROLES'; tier_openai_resolve 'openai/gpt-5.4-mini'"
    [ "$status" -eq 0 ]
    [ "$output" = "openai/gpt-5.4-mini" ]

    run bash -c ". '$ROLES'; tier_openai_resolve 'openrouter/~z-ai/glm-latest'"
    [ "$status" -eq 0 ]
    [ "$output" = "openrouter/~z-ai/glm-latest" ]
}

# ── tier_openai_catalogue ─────────────────────────────────────────────────

@test "tier_openai_catalogue: the signed-in `opencode models openai --verbose` listing is parsed" {
    # Guards: with no fixture file, the catalogue comes from opencode's own
    # listing of what the subscription serves -- header lines dropped, the
    # JSON objects mapped to {id, family, release_date}.
    # Fails if: the opencode/ header lines reach the parser, or a family
    # or release_date is lost.
    # Run:      bats tests/opencode-openai-launch.bats
    auth_fixture '{"openai":{"type":"oauth","refresh":"rtok","access":"atok"}}'
    mkdir -p "$T/bin"
    cat >"$T/bin/opencode" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "models" ] && [ "${2:-}" = "openai" ]; then
    cat <<'OUT'
openai/gpt-5.6-luna
{
  "id": "gpt-5.6-luna",
  "family": "gpt-luna",
  "release_date": "2026-07-09"
}
openai/gpt-5.6-sol
{
  "id": "gpt-5.6-sol",
  "family": "gpt-sol",
  "release_date": "2026-07-09"
}
OUT
    exit 0
fi
exit 0
STUB
    chmod +x "$T/bin/opencode"
    export TIER_OPENCODE_BIN="$T/bin/opencode"

    run bash -c ". '$ROLES'; tier_openai_catalogue"
    [ "$status" -eq 0 ]
    [ "$(jq -r 'length' <<<"$output")" = "2" ]
    [ "$(jq -r '.[0].id' <<<"$output")" = "gpt-5.6-luna" ]
    [ "$(jq -r '.[0].family' <<<"$output")" = "gpt-luna" ]
    [ "$(jq -r '.[1].id' <<<"$output")" = "gpt-5.6-sol" ]
    [ "$(jq -r '.[1].family' <<<"$output")" = "gpt-sol" ]
}

# ── orca_opencode_command on an openai/ model ─────────────────────────────

@test "orca_opencode_command: an openai/ model carries reasoningEffort and no guard, even with a token file present" {
    # Guards: an openai launch's config keys the effort under
    # provider.openai.models.<id>.options.reasoningEffort (opencode's own
    # ChatGPT login supplies the credential) and its env file carries ONLY
    # OPENCODE_CONFIG -- never the guard token.
    # Fails if: the openrouter reasoning.effort key or an
    # OPENROUTER_API_KEY/OPENROUTER_ line leaks into an openai launch.
    # Run:      bats tests/opencode-openai-launch.bats
    printf 'tok-guard-secret\n' >"$RUN/openrouter-guard.token"
    run bash -c ". '$ORCA_ORCH'; orca_opencode_command 'openai/gpt-5.6-luna' '$RUN' high"
    [ "$status" -eq 0 ]
    [ "$output" = "set -a; . '$RUN/openrouter-guard.env'; set +a; opencode --model openai/gpt-5.6-luna" ]

    env_file="$RUN/openrouter-guard.env"
    [ -f "$env_file" ]
    grep -q '^OPENCODE_CONFIG=' "$env_file"
    ! grep -q 'OPENROUTER_' "$env_file"
    ! grep -q 'tok-guard-secret' "$env_file"
    cfg="$(sed -n "s/^OPENCODE_CONFIG='\(.*\)'/\1/p" "$env_file")"
    [ -f "$cfg" ]
    [ "$(jq -r '.provider.openai.models["gpt-5.6-luna"].options.reasoningEffort' "$cfg")" = "high" ]
    [ "$(jq -r '.provider.openrouter // "absent"' "$cfg")" = "absent" ]
    [ "$(jq -r '.permission["*"]' "$cfg")" = "allow" ]
    [ "$(jq -r '.["$schema"]' "$cfg")" = "https://opencode.ai/config.json" ]
    [ "$(stat -c '%a' "$cfg")" = "600" ]
}

# ── opencode_launch_config, the one writer ────────────────────────────────

@test "opencode_launch_config: an openrouter/ model with a base URL and a variant is today's config" {
    # Guards: the shared writer reproduces orca_opencode_command's
    # openrouter config exactly -- options.apiKey/baseURL plus
    # reasoning.effort under the vendor model.
    # Fails if: the openrouter options or the reasoning.effort nesting
    # drifts from what the frozen files pin.
    # Run:      bats tests/opencode-openai-launch.bats
    out="$T/launch-openrouter.json"
    run bash -c ". '$LAUNCH'; opencode_launch_config 'openrouter/~z-ai/glm-flash-latest' high allow '$out' 'http://127.0.0.1:4141/api/v1'"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.provider.openrouter.options.baseURL' "$out")" = "http://127.0.0.1:4141/api/v1" ]
    [ "$(jq -r '.provider.openrouter.options.apiKey' "$out")" = "{env:OPENROUTER_API_KEY}" ]
    [ "$(jq -r '.provider.openrouter.models["~z-ai/glm-flash-latest"].options.reasoning.effort' "$out")" = "high" ]
    [ "$(jq -r '.permission["*"]' "$out")" = "allow" ]
    [ "$(stat -c '%a' "$out")" = "600" ]
}

# ── recon on an openai/ model ─────────────────────────────────────────────

@test "recon: an openai/ recon model with no OpenAI sign-in is the exit-3 scout fallback" {
    # Guards: recon refuses an openai/ model cleanly when the folder is
    # not signed in, naming /tier auth openai, and never runs opencode.
    # Fails if: recon launches anyway, or the refusal stops naming the
    # sign-in command.
    # Run:      bats tests/opencode-openai-launch.bats
    recon_fixture "openai/~gpt-luna-latest"
    opencode_stub
    rm -f "$RUN/openrouter-guard.token"

    run --separate-stderr "$RECON" "q"
    [ "$status" -eq 3 ]
    grep -q '/tier auth openai' <<<"$stderr"
    [ ! -e "$STUB_LOG" ]
}

@test "recon: a signed-in openai/ recon model runs headless with no guard token and the readonly config" {
    # Guards: with OpenAI signed in and no guard token at all, recon runs
    # the RESOLVED model (openai/gpt-5.6-luna, not the ~ alias), strips any
    # ambient OPENROUTER_API_KEY from opencode's env, and carries the
    # read-only config: reasoningEffort high on the openai provider, edit
    # denied.
    # Fails if: recon still demands a guard token, launches the alias, or
    # leaks an OpenRouter credential into the run.
    # Run:      bats tests/opencode-openai-launch.bats
    recon_fixture "openai/~gpt-luna-latest"
    opencode_stub
    rm -f "$RUN/openrouter-guard.token"
    auth_fixture '{"openai":{"type":"oauth","refresh":"rtok","access":"atok"}}'
    catalogue_fixture
    OPENROUTER_API_KEY=ambient-decoy-key run --separate-stderr "$RECON" "q"
    [ "$status" -eq 0 ]

    [ "$(sed -n '1p' "$STUB_LOG")" = "run" ]
    [ "$(sed -n '2p' "$STUB_LOG")" = "-m" ]
    [ "$(sed -n '3p' "$STUB_LOG")" = "openai/gpt-5.6-luna" ]
    ! grep -q '^OPENROUTER_API_KEY=' "$STUB_ENV"
    cfg="$(sed -n 's/^OPENCODE_CONFIG=//p' "$STUB_ENV")"
    [ -n "$cfg" ]
    [ "$(jq -r '.provider.openai.models["gpt-5.6-luna"].options.reasoningEffort' "$cfg")" = "high" ]
    [ "$(jq -r '.permission.edit' "$cfg")" = "deny" ]
    [ "$(jq -r '.permission.write' "$cfg")" = "deny" ]
    [ "$(jq -r '.provider.openrouter // "absent"' "$cfg")" = "absent" ]
    ! grep -q 'ambient-decoy-key' "$cfg"
}

# ── orca-dispatch's signed-in guard ───────────────────────────────────────

@test "orca-dispatch: an openai/ model when the folder is not signed in dies with /tier auth openai and exit 2" {
    # Guards: orca-dispatch refuses an openai/ worker before composing any
    # launch, telling the orchestrator the one command that fixes it.
    # Fails if: the dispatch proceeds (exit 0/3) or the message loses
    # `/tier auth openai`.
    # Run:      bats tests/opencode-openai-launch.bats
    # shellcheck source=helpers/orca-stub.bash
    . "$BATS_TEST_DIRNAME/helpers/orca-stub.bash"
    orca_stub_init
    orca_stub_reply orchestration-run-create \
        '{"ok":true,"result":{"run":{"id":"run1","coordinator_handle":"term_coord"}}}'
    orca_stub_reply orchestration-task-create \
        '{"ok":true,"result":{"task":{"id":"t1"}}}'

    run --separate-stderr "$DISPATCH" b1 --agent opencode \
        --model "openai/~gpt-luna-latest" --worktree "path:$CLAUDE_ORCA_ROOT"
    [ "$status" -eq 2 ]
    grep -q '/tier auth openai' <<<"$stderr"
    [ -z "$(orca_stub_calls 'terminal create')" ]
}
