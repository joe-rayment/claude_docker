# Helpers for tests/openai-stub-real.bats: start/stop the stub OpenAI
# (openai-stub.py beside this file) and shape the environment and fake
# login state the real opencode needs to talk to it.
#
# CA trust: NODE_EXTRA_CA_CERTS is what real opencode honours. Evidence
# (opencode 1.18.25, 2026-10-01): with only HTTPS_PROXY set, `opencode run
# -m openai/gpt-5.6-luna` against the stub fails with the event
# {"error":{"name":"UnknownError","data":{"message":"unable to verify the
# first certificate"}}} -- TLS is validated, not skipped; adding
# NODE_EXTRA_CA_CERTS=<dir>/ca.pem makes the same run return the stub's
# STUB-OK. So openai_stub_env exports NODE_EXTRA_CA_CERTS, never
# NODE_TLS_REJECT_UNAUTHORIZED=0.

openai_stub_start() {
    local dir="$1"
    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Fully detached: setsid+nohup so the stub survives the bats process
    # (and this terminal's whole process group) being torn down. The stub
    # writes its own pid to <dir>/pid because setsid forks when the shell
    # made the job a process-group leader, which would make $! wrong.
    setsid nohup python3 "$self_dir/openai-stub.py" --dir "$dir" \
        >"$dir/stub.log" 2>&1 </dev/null &
    local waited=0
    while [ "$waited" -lt 100 ]; do
        [ -s "$dir/port" ] && break
        sleep 0.1
        waited=$((waited + 1))
    done
    if [ ! -s "$dir/port" ]; then
        echo "openai_stub_start: no $dir/port after 10s" >&2
        [ -f "$dir/stub.log" ] && cat "$dir/stub.log" >&2
        return 1
    fi
    export OPENAI_STUB_DIR="$dir"
    export OPENAI_STUB_PORT
    OPENAI_STUB_PORT="$(cat "$dir/port")"
}

openai_stub_stop() {
    local dir="${1:-$OPENAI_STUB_DIR}"
    [ -n "$dir" ] && [ -f "$dir/pid" ] || return 0
    local pid
    pid="$(cat "$dir/pid")"
    kill "$pid" 2>/dev/null || true
    rm -f "$dir/pid"
}

openai_stub_env() {
    printf 'HTTPS_PROXY=http://127.0.0.1:%s\n' "$OPENAI_STUB_PORT"
    printf 'NODE_EXTRA_CA_CERTS=%s\n' "$OPENAI_STUB_DIR/ca.pem"
}

openai_stub_login() {
    local data_home="$1" mode="${2:-fresh}"
    local now exp expires_ms payload header jwt
    now="$(date +%s)"
    exp=$((now + 3600))
    expires_ms=$(((now + 86400) * 1000))
    if [ "$mode" = expired ]; then
        exp=$((now - 3600))
        expires_ms=$(((now - 3600) * 1000))
    fi
    payload="$(printf '{"https://api.openai.com/auth":{"chatgpt_account_id":"acct-test"},"exp":%s}' "$exp" \
        | base64 -w0 | tr '+/' '-_' | tr -d '=')"
    header="$(printf '{"alg":"RS256","typ":"JWT"}' \
        | base64 -w0 | tr '+/' '-_' | tr -d '=')"
    jwt="$header.$payload.sig"
    mkdir -p "$data_home/opencode"
    jq -n --arg access "$jwt" --argjson expires "$expires_ms" \
        '{openai: {type: "oauth", refresh: "rt-0", access: $access,
                    expires: $expires, accountId: "acct-test"}}' \
        >"$data_home/opencode/auth.json"
    chmod 600 "$data_home/opencode/auth.json"
}

openai_stub_home() {
    local dir="$1"
    local src="$HOME/.cache/opencode/models.json"
    [ -f "$src" ] || return 1
    mkdir -p "$dir/home/.cache/opencode"
    cp -f "$src" "$dir/home/.cache/opencode/models.json"
}
