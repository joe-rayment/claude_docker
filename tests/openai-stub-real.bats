#!/usr/bin/env bats
#
# The REAL opencode against a stub OpenAI (claude-orca-c3p.1).
#
# No other test in the suite runs the real opencode binary against a fake
# ChatGPT backend; this file proves the launch path end to end: a fake
# oauth login in auth.json, an intercepting HTTP proxy that terminates TLS
# for chatgpt.com / auth.openai.com with a test CA, and opencode none the
# wiser. Every other host is tunnelled blind, so catalogue fetches still
# work.
#
# CA trust: the harness exports NODE_EXTRA_CA_CERTS=<dir>/ca.pem and that
# is what opencode needed -- with only HTTPS_PROXY set the real run fails
# with {"error":{"name":"UnknownError","data":{"message":"unable to verify
# the first certificate"}}} (opencode 1.18.25, 2026-10-01), and adding
# NODE_EXTRA_CA_CERTS=<dir>/ca.pem makes the same run succeed. So opencode
# honours NODE_EXTRA_CA_CERTS; NODE_TLS_REJECT_UNAUTHORIZED=0 is not needed.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
load "helpers/openai-stub.bash"

setup_file() {
    # Ambient launch config would force a different provider/auth than the
    # one under test; the cases below set everything they need themselves.
    unset OPENCODE_CONFIG OPENCODE_CONFIG_CONTENTS
    command -v opencode >/dev/null 2>&1 || skip "opencode is not on PATH"
    command -v openssl >/dev/null 2>&1 || skip "openssl is not on PATH"
    command -v python3 >/dev/null 2>&1 || skip "python3 is not on PATH"
}

setup() {
    T="$BATS_TEST_TMPDIR"
    openai_stub_home "$T" || skip "no \$HOME/.cache/opencode/models.json on this box"
    openai_stub_start "$T"
}

teardown() {
    openai_stub_stop
}

# Every opencode call runs with a clean provider/auth environment: no API
# keys, the folder's own HOME and XDG_DATA_HOME, the stub's proxy and CA.
oc() {
    env -u OPENAI_API_KEY -u OPENROUTER_API_KEY \
        HOME="$T/home" XDG_DATA_HOME="$T/data" \
        $(openai_stub_env) opencode "$@"
}

@test "a fake ChatGPT login reaches the stub through opencode's own OAuth path" {
    # Guards: the end-to-end launch path -- opencode with a fake oauth
    # auth.json must send its requests to the stub's chatgpt.com with the
    # fake bearer token, the fake account id and the requested model, and
    # must accept the stub's Responses-API SSE stream (STUB-OK text back).
    # Fails if: opencode ignores the fake login, sends the token anywhere
    # else, drops the chatgpt-account-id header, sends a different model,
    # or chokes on the SSE shape.
    # Run: bats tests/openai-stub-real.bats
    openai_stub_login "$T/data"
    ACCESS="$(jq -r .openai.access "$T/data/opencode/auth.json")"
    run oc run -m openai/gpt-5.6-luna --format json "say hi"
    [ "$status" -eq 0 ]
    grep -q "STUB-OK" <<<"$output"
    # requests.jsonl is JSONL (one object per line); jq -s slurps it into
    # one array so map() runs over the request objects, not a single
    # object's string values.
    jq -s -e --arg tok "$ACCESS" '
        map(select(.host == "chatgpt.com" and .method == "POST"
                   and .path == "/backend-api/codex/responses"))
        | map(select(.headers.authorization == "Bearer " + $tok
                     and .headers["chatgpt-account-id"] == "acct-test"
                     and .body.model == "gpt-5.6-luna"))
        | length > 0' "$T/requests.jsonl" >/dev/null
}

@test "an expired access token is refreshed and written back" {
    # Guards: the refresh flow -- when auth.json carries an expired access
    # token, opencode must refresh it against the stub's auth.openai.com
    # (grant_type=refresh_token, the stored refresh token rt-0) and write
    # the rotated refresh token rt-1 back to auth.json, before answering.
    # Fails if: opencode uses the expired token without refreshing, sends
    # the wrong grant_type/refresh_token, or fails to persist the rotation.
    # Run: bats tests/openai-stub-real.bats
    openai_stub_login "$T/data" expired
    run oc run -m openai/gpt-5.6-luna --format json "say hi"
    [ "$status" -eq 0 ]
    grep -q "STUB-OK" <<<"$output"
    jq -s -e '
        map(select(.host == "auth.openai.com" and .method == "POST"
                   and .path == "/oauth/token"
                   and .body.grant_type == "refresh_token"
                   and .body.refresh_token == "rt-0"))
        | length > 0' "$T/requests.jsonl" >/dev/null
    [ "$(jq -r .openai.refresh "$T/data/opencode/auth.json")" = "rt-1" ]
}

@test "the effort reaches the request" {
    # Guards: the --variant flag -- a high reasoning-effort variant must
    # arrive in the codex request body as reasoning.effort "high", not be
    # swallowed between the CLI and the HTTP client.
    # Fails if: opencode drops the variant (all codex requests show effort
    # "none" or another level) or errors out on the flag.
    # Run: bats tests/openai-stub-real.bats
    openai_stub_login "$T/data"
    run oc run -m openai/gpt-5.6-luna --variant high --format json "say hi"
    [ "$status" -eq 0 ]
    grep -q "STUB-OK" <<<"$output"
    jq -s -e '
        map(select(.host == "chatgpt.com" and .method == "POST"
                   and .path == "/backend-api/codex/responses"
                   and .body.reasoning.effort == "high"))
        | length > 0' "$T/requests.jsonl" >/dev/null
}

@test "the model list is what the subscription serves" {
    # Guards: the models command -- with the fake ChatGPT login,
    # `opencode models openai` lists the subscription's catalogue
    # (openai/gpt-5.6-luna is there) and not what a plain API key would
    # see (openai/gpt-6-luna stays hidden).
    # Fails if: the list is served unfiltered (gpt-6-luna shows up) or
    # the login makes the command fail so gpt-5.6-luna never shows.
    # Run: bats tests/openai-stub-real.bats
    openai_stub_login "$T/data"
    run oc models openai
    [ "$status" -eq 0 ]
    grep -q "openai/gpt-5.6-luna" <<<"$output"
    ! grep -q "openai/gpt-6-luna" <<<"$output"
}

# ── B4 (claude-orca-c3p.4): the whole OpenAI path, end to end ──────────────

# tier.json fixture: recon bound to the ~-latest family alias at effort high.
recon_fixture() {
    local root="$1" run="$2"
    git init -q "$root"
    mkdir -p "$run"
    jq -n '{top:"fable", roles:{recon:{backend:"orca", agent:"opencode",
              model:"openai/~gpt-luna-latest", pinned:true, variant:"high"}}}' \
        >"$run/tier.json"
    export RECON_STATE_FILE="$run/tier.json"
    export RECON_RUN_DIR="$run"
    export CLAUDE_ORCA_ROOT="$root"
    export PROJECT_DIR="$root"
    export COST_MIRROR_STATE_DIR="$T/cost-mirror"
}

# The family catalogue as a fixture (the alias resolution itself is pinned
# by tests/opencode-openai-launch.bats; this file proves the run).
openai_catalogue_fixture() {
    export TIER_OPENAI_MODELS_FILE="$T/models.json"
    cat >"$TIER_OPENAI_MODELS_FILE" <<'JSON'
[
  {"id": "gpt-5.6-luna", "family": "gpt-luna", "release_date": "2026-07-09"},
  {"id": "gpt-5.6-luna-fast", "family": "gpt-luna", "release_date": "2026-07-09"},
  {"id": "gpt-5.6-terra", "family": "gpt-terra", "release_date": "2026-07-09"}
]
JSON
}

@test "openai-auth.sh signs the real opencode in to the stub, end to end" {
    # Guards: the sign-in helper against the REAL opencode and the stub
    #   auth server -- the headless device flow runs (no TTY, stdin
    #   /dev/null), writes an oauth login with a refresh token into
    #   auth.json, and the helper then lists the subscription's models.
    # Fails if: the login never reaches the stub's deviceauth/usercode,
    #   deviceauth/token and oauth/token routes, the rotated refresh token
    #   is not persisted, or the helper exits non-zero on a working flow.
    # Run: bats -f 'signs the real opencode in' tests/openai-stub-real.bats
    run env -u OPENAI_API_KEY -u OPENROUTER_API_KEY -u OPENAI_AUTH_OPENCODE_BIN \
        HOME="$T/home" XDG_DATA_HOME="$T/data" \
        $(openai_stub_env) \
        "$REPO_ROOT/scripts/openai-auth.sh" </dev/null
    [ "$status" -eq 0 ]
    [ "$(jq -r '.openai.type' "$T/data/opencode/auth.json")" = "oauth" ]
    [ "$(jq -r '.openai.refresh' "$T/data/opencode/auth.json")" = "rt-1" ]
    jq -s -e '
        map(select(.host == "auth.openai.com" and .method == "POST"
                   and .path == "/api/accounts/deviceauth/usercode"))
        | length > 0' "$T/requests.jsonl" >/dev/null
    jq -s -e '
        map(select(.host == "auth.openai.com" and .method == "POST"
                   and .path == "/api/accounts/deviceauth/token"))
        | length > 0' "$T/requests.jsonl" >/dev/null
    jq -s -e '
        map(select(.host == "auth.openai.com" and .method == "POST"
                   and .path == "/oauth/token"))
        | length > 0' "$T/requests.jsonl" >/dev/null
}

@test "recon answers on the subscription model through the stub, end to end" {
    # Guards: recon's whole openai/ path -- tier.json recon bound to the
    #   ~-latest alias at variant high, the folder signed in, no guard
    #   token anywhere -- resolves the alias, launches the real opencode
    #   headless with the readonly config, and the stub receives the codex
    #   request with model gpt-5.6-luna and reasoning.effort high.
    # Fails if: recon fell back to exit 3, launched the alias verbatim,
    #   dropped the effort, or sent the request with anything but the
    #   fake login's bearer.
    # Run: bats -f 'recon answers on the subscription model' tests/openai-stub-real.bats
    openai_stub_login "$T/data"
    openai_catalogue_fixture
    recon_fixture "$T/proj" "$T/run"
    local access
    access="$(jq -r .openai.access "$T/data/opencode/auth.json")"
    run env -u OPENAI_API_KEY -u OPENROUTER_API_KEY -u OPENCODE_CONFIG \
        HOME="$T/home" XDG_DATA_HOME="$T/data" \
        $(openai_stub_env) \
        "$REPO_ROOT/scripts/recon.sh" --dir "$T/proj" "what is 2+2"
    [ "$status" -eq 0 ]
    grep -q "STUB-OK" <<<"$output"
    jq -s -e --arg tok "$access" '
        map(select(.host == "chatgpt.com" and .method == "POST"
                   and .path == "/backend-api/codex/responses"
                   and .headers.authorization == "Bearer " + $tok
                   and .body.model == "gpt-5.6-luna"
                   and .body.reasoning.effort == "high"))
        | length > 0' "$T/requests.jsonl" >/dev/null
}

@test "the headless worker path runs the subscription model through the stub, end to end" {
    # Guards: orca-dispatch's headless composition driven for real --
    #   orca_opencode_command writes the openai env file (OPENCODE_CONFIG,
    #   no token), orca-worker-run sources it and runs the REAL opencode
    #   headless on the subscription, the stub receives the codex request
    #   with the fake login's bearer, and the receipt records exit 0.
    # Fails if: the env file leaked a guard token into an openai launch,
    #   the worker exited non-zero, or the stub saw no authenticated codex
    #   request.
    # Run: bats -f 'headless worker path' tests/openai-stub-real.bats
    openai_stub_login "$T/data"
    local access
    access="$(jq -r .openai.access "$T/data/opencode/auth.json")"

    # Orca CLI and cost-mirror stubs, the technique of
    # tests/orca-worker-run.bats: the CLI logs argv and answers ok.
    mkdir -p "$T/bin"
    cat >"$T/bin/orca-ide" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ORCA_STUB_LOG"
printf '{"ok":true}\n'
STUB
    cat >"$T/bin/cost-mirror" <<'STUB'
#!/usr/bin/env bash
:
STUB
    chmod +x "$T/bin/orca-ide" "$T/bin/cost-mirror"
    export ORCA_STUB_LOG="$T/orca-calls.log"
    : >"$ORCA_STUB_LOG"

    git init -q "$T/proj"
    local run="$T/run"
    mkdir -p "$run/orchestration/dispatch"
    bash -c ". '$REPO_ROOT/scripts/lib/orca-orch.sh'; \
        orca_opencode_command 'openai/gpt-5.6-luna' '$run' >/dev/null"
    [ -f "$run/openrouter-guard.env" ]
    ! grep -q 'OPENROUTER' "$run/openrouter-guard.env"
    printf '{"task_id":"task_e2e","dispatch_id":"ctx_e2e"}\n' \
        >"$run/orchestration/dispatch/ctx_e2e.json"
    printf 'say hi\n' >"$T/spec.txt"
    export CLAUDE_ORCA_WORKER_DISPATCH_WAIT_S=1

    run env -u OPENAI_API_KEY -u OPENROUTER_API_KEY \
        HOME="$T/home" XDG_DATA_HOME="$T/data" PATH="$T/bin:$PATH" \
        $(openai_stub_env) \
        "$REPO_ROOT/scripts/orca-worker-run.sh" \
        --task task_e2e --spec "$T/spec.txt" --model openai/gpt-5.6-luna \
        --dir "$T/proj" --run-dir "$run" --env "$run/openrouter-guard.env" \
        --bead claude-orca-c3p.4
    [ "$status" -eq 0 ]
    jq -s -e --arg tok "$access" '
        map(select(.host == "chatgpt.com" and .method == "POST"
                   and .path == "/backend-api/codex/responses"
                   and .headers.authorization == "Bearer " + $tok
                   and .body.model == "gpt-5.6-luna"))
        | length > 0' "$T/requests.jsonl" >/dev/null
    [ "$(jq -r '.exit_code' "$run/orchestration/workers/task_e2e.receipt.json")" = "0" ]
    grep -q 'worker_done' "$ORCA_STUB_LOG"
}
