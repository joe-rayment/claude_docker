#!/usr/bin/env bats
#
# claude-orca-qa2.20 acceptance contract -- FROZEN from RED-AT onward.
#
# Exercises the real scripts/container/openrouter-guard.py against a STUB
# upstream (a python3 stdlib server started by this file) so nothing here
# touches openrouter.ai. The guard is started with
# OPENROUTER_UPSTREAM=http://127.0.0.1:<stub-port> and the real key
# "real-secret"; every request goes through it with the guard token, and the
# assertions are on what the stub recorded -- i.e. on the bytes that would
# have left the VM.
#
# The allowlist is read from the SHIPPED config/provider-policy.json, so the
# policy file and the guard can never drift apart without this failing.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

GUARD="$REPO_ROOT/scripts/container/openrouter-guard.py"
POLICY="$REPO_ROOT/config/provider-policy.json"

setup() {
    STUB="$BATS_TEST_TMPDIR/upstream.py"
    REC="$BATS_TEST_TMPDIR/rec"
    RUN="$BATS_TEST_TMPDIR/run"
    mkdir -p "$REC" "$RUN"
    cat > "$STUB" <<'PY'
# Stub OpenRouter upstream: records what it was handed, answers canned.
import os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REC = os.environ["UPSTREAM_REC"]
MODE = os.environ.get("UPSTREAM_MODE", "json")

SSE = (b'data: {"choices":[{"delta":{"content":"he"}}]}\n\n'
       b'data: {"choices":[{"delta":{"content":"llo"}}]}\n\n'
       b'data: [DONE]\n\n')
JSON = b'{"id":"cmpl-1","choices":[{"message":{"content":"ok"}}]}'


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        with open(os.path.join(REC, "body.json"), "wb") as f:
            f.write(body)
        with open(os.path.join(REC, "headers.txt"), "w") as f:
            for k, v in self.headers.items():
                f.write("%s: %s\n" % (k.lower(), v))
        with open(os.path.join(REC, "path.txt"), "w") as f:
            f.write(self.path)
        if MODE == "sse":
            payload, ctype = SSE, "text/event-stream"
        else:
            payload, ctype = JSON, "application/json"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
}

teardown() {
    [ -n "${GUARD_PID:-}" ] && kill "$GUARD_PID" 2>/dev/null
    [ -n "${UP_PID:-}" ] && kill "$UP_PID" 2>/dev/null
    wait 2>/dev/null
    return 0
}

free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

wait_port() {  # wait_port <port>
    local i=0
    while [ "$i" -lt 150 ]; do
        if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(0 if s.connect_ex(('127.0.0.1',$1))==0 else 1)"; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "port $1 never came up" >&2
    return 1
}

start_upstream() {  # start_upstream [json|sse]
    UP_PORT="$(free_port)"
    UPSTREAM_REC="$REC" UPSTREAM_MODE="${1:-json}" \
        python3 "$STUB" "$UP_PORT" > "$BATS_TEST_TMPDIR/upstream.log" 2>&1 &
    UP_PID=$!
    wait_port "$UP_PORT"
}

start_guard() {
    GP="$(free_port)"
    OPENROUTER_API_KEY=real-secret \
    OPENROUTER_GUARD_TOKEN=guard-token-abc \
    OPENROUTER_UPSTREAM="http://127.0.0.1:$UP_PORT" \
        python3 "$GUARD" --port "$GP" --policy "$POLICY" --run-dir "$RUN" \
        > "$BATS_TEST_TMPDIR/guard.log" 2>&1 &
    GUARD_PID=$!
    wait_port "$GP"
}

allowlist_csv() {
    jq -r '[.allow[].slug] | join(",")' "$POLICY"
}

post() {  # post <path> <auth-header-value> <json-body> -- prints the HTTP code
    curl -s -o "$BATS_TEST_TMPDIR/resp.out" -w '%{http_code}' \
        -X POST "http://127.0.0.1:$GP$1" \
        -H "Authorization: $2" \
        -H 'Content-Type: application/json' \
        --data-binary "$3"
}

@test "the guard forces provider.only to the allowlist with allow_fallbacks false and data_collection deny on every completion request and swaps the guard token for the real key" {
    start_upstream json
    start_guard

    for p in /api/v1/chat/completions /api/v1/completions /api/v1/responses /api/v1/messages; do
        rm -f "$REC/body.json" "$REC/headers.txt" "$REC/path.txt"
        code="$(post "$p" 'Bearer guard-token-abc' '{"model":"z-ai/glm-5.3","messages":[{"role":"user","content":"hi"}]}')"
        [ "$code" = "200" ]

        # the request that actually left the box carries the forced policy
        run jq -r '.provider.only | join(",")' "$REC/body.json"
        [ "$status" -eq 0 ]
        [ "$output" = "$(allowlist_csv)" ]
        run jq -e '.provider.allow_fallbacks == false' "$REC/body.json"
        [ "$status" -eq 0 ]
        run jq -e '.provider.data_collection == "deny"' "$REC/body.json"
        [ "$status" -eq 0 ]
        # the client's own fields are untouched, and the path is preserved
        run jq -e '.model == "z-ai/glm-5.3" and (.messages | length) == 1' "$REC/body.json"
        [ "$status" -eq 0 ]
        [ "$(cat "$REC/path.txt")" = "$p" ]

        # the guard token was swapped for the real key: upstream sees the key
        # and never the token
        grep -qx 'authorization: Bearer real-secret' "$REC/headers.txt"
        run grep -c 'guard-token-abc' "$REC/headers.txt"
        [ "$output" = "0" ]
    done

    # the answer reaches the client unchanged
    run jq -r '.id' "$BATS_TEST_TMPDIR/resp.out"
    [ "$output" = "cmpl-1" ]
}

@test "the guard drops a client provider order that names a provider outside the allowlist and logs it" {
    start_upstream json
    start_guard

    # novita is not on the allowlist -> the whole client order is unusable, so
    # the policy's own explicit order is forced in its place (claude-orca-c6b)
    code="$(post /api/v1/chat/completions 'Bearer guard-token-abc' \
        '{"model":"z-ai/glm-5.3","provider":{"order":["novita","parasail"],"allow_fallbacks":true,"data_collection":"allow"},"messages":[]}')"
    [ "$code" = "200" ]
    run jq -r '.provider.order | join(",")' "$REC/body.json"
    [ "$output" = "$(jq -r '.order | join(",")' "$POLICY")" ]
    run jq -e '.provider.allow_fallbacks == false and .provider.data_collection == "deny"' "$REC/body.json"
    [ "$status" -eq 0 ]
    run jq -r '.provider.only | join(",")' "$REC/body.json"
    [ "$output" = "$(allowlist_csv)" ]

    # ... and the drop is on the record, with order_source naming the policy
    log="$RUN/openrouter-guard.log"
    [ -f "$log" ]
    run jq -e 'select(.client_order_dropped == true) | .model == "z-ai/glm-5.3" and .providers_forced == true and .order_source == "policy" and (.ts | length) > 0' "$log"
    [ "$status" -eq 0 ]

    # an order entirely INSIDE the allowlist is kept as the client sent it,
    # and the log names the client as the order's source
    rm -f "$REC/body.json"
    first="$(jq -r '.allow[0].slug' "$POLICY")"
    second="$(jq -r '.allow[1].slug' "$POLICY")"
    code="$(post /api/v1/chat/completions 'Bearer guard-token-abc' \
        "{\"model\":\"z-ai/glm-5.3\",\"provider\":{\"order\":[\"$first\",\"$second\"]},\"messages\":[]}")"
    [ "$code" = "200" ]
    run jq -r '.provider.order | join(",")' "$REC/body.json"
    [ "$output" = "$first,$second" ]
    run jq -e '.provider.allow_fallbacks == false and .provider.data_collection == "deny"' "$REC/body.json"
    [ "$status" -eq 0 ]
    run jq -r '.provider.only | join(",")' "$REC/body.json"
    [ "$output" = "$(allowlist_csv)" ]
    run jq -e 'select(.client_order_dropped == false) | .order_source == "client"' "$log"
    [ "$status" -eq 0 ]
}

@test "a completion request with no provider block at all gets provider.order forced to the policy's explicit order" {
    start_upstream json
    start_guard

    code="$(post /api/v1/chat/completions 'Bearer guard-token-abc' \
        '{"model":"z-ai/glm-5.3","messages":[]}')"
    [ "$code" = "200" ]

    run jq -r '.provider.order | join(",")' "$REC/body.json"
    [ "$output" = "$(jq -r '.order | join(",")' "$POLICY")" ]
    run jq -r '.provider.only | join(",")' "$REC/body.json"
    [ "$output" = "$(allowlist_csv)" ]
    run jq -e '.provider.allow_fallbacks == false' "$REC/body.json"
    [ "$status" -eq 0 ]

    log="$RUN/openrouter-guard.log"
    run jq -e 'select(.path == "/api/v1/chat/completions" and .status == 200) | .order_source == "policy"' "$log"
    [ "$status" -eq 0 ]
}

@test "the guard refuses to start when the policy's order names a provider outside the allow list" {
    BAD_POLICY="$BATS_TEST_TMPDIR/bad-policy.json"
    jq '.order = (.order // [.allow[].slug]) + ["not-a-real-provider"]' "$POLICY" > "$BAD_POLICY"

    GP="$(free_port)"
    run timeout 5 env OPENROUTER_API_KEY=real-secret OPENROUTER_GUARD_TOKEN=guard-token-abc \
        OPENROUTER_UPSTREAM="http://127.0.0.1:1" \
        python3 "$GUARD" --port "$GP" --policy "$BAD_POLICY" --run-dir "$RUN"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not-a-real-provider"* ]]
    [[ "$output" == *"order"* ]]
}

@test "a policy with no order field falls back to the allow list order and logs the fallback once" {
    NOORDER_POLICY="$BATS_TEST_TMPDIR/no-order-policy.json"
    jq 'del(.order)' "$POLICY" > "$NOORDER_POLICY"

    start_upstream json
    GP="$(free_port)"
    OPENROUTER_API_KEY=real-secret \
    OPENROUTER_GUARD_TOKEN=guard-token-abc \
    OPENROUTER_UPSTREAM="http://127.0.0.1:$UP_PORT" \
        python3 "$GUARD" --port "$GP" --policy "$NOORDER_POLICY" --run-dir "$RUN" \
        > "$BATS_TEST_TMPDIR/guard.log" 2>&1 &
    GUARD_PID=$!
    wait_port "$GP"

    code="$(post /api/v1/chat/completions 'Bearer guard-token-abc' '{"model":"z-ai/glm-5.3","messages":[]}')"
    [ "$code" = "200" ]
    run jq -r '.provider.order | join(",")' "$REC/body.json"
    [ "$output" = "$(allowlist_csv)" ]

    run grep -c 'falling back to the allow' "$BATS_TEST_TMPDIR/guard.log"
    [ "$output" = "1" ]
}

@test "the guard streams an SSE response through unchanged" {
    start_upstream sse
    start_guard

    code="$(post /api/v1/chat/completions 'Bearer guard-token-abc' \
        '{"model":"z-ai/glm-5.3","stream":true,"messages":[]}')"
    [ "$code" = "200" ]

    printf 'data: {"choices":[{"delta":{"content":"he"}}]}\n\ndata: {"choices":[{"delta":{"content":"llo"}}]}\n\ndata: [DONE]\n\n' \
        > "$BATS_TEST_TMPDIR/expect.sse"
    run cmp -s "$BATS_TEST_TMPDIR/expect.sse" "$BATS_TEST_TMPDIR/resp.out"
    [ "$status" -eq 0 ]

    # the content type survives the hop, so the client still sees a stream
    run curl -s -D "$BATS_TEST_TMPDIR/hdrs" -o /dev/null \
        -X POST "http://127.0.0.1:$GP/api/v1/chat/completions" \
        -H 'Authorization: Bearer guard-token-abc' \
        -H 'Content-Type: application/json' \
        --data-binary '{"model":"z-ai/glm-5.3","stream":true,"messages":[]}'
    [ "$status" -eq 0 ]
    run grep -ic 'content-type: text/event-stream' "$BATS_TEST_TMPDIR/hdrs"
    [ "$output" = "1" ]
}

@test "the guard refuses a request that does not carry the guard token" {
    start_upstream json
    start_guard

    # no Authorization header at all
    code="$(curl -s -o "$BATS_TEST_TMPDIR/resp.out" -w '%{http_code}' \
        -X POST "http://127.0.0.1:$GP/api/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        --data-binary '{"model":"z-ai/glm-5.3","messages":[]}')"
    [ "$code" = "401" ]
    [ ! -f "$REC/body.json" ]

    # a wrong key -- including the real upstream key -- is refused too
    code="$(post /api/v1/chat/completions 'Bearer real-secret' '{"model":"z-ai/glm-5.3","messages":[]}')"
    [ "$code" = "401" ]
    code="$(post /api/v1/chat/completions 'Bearer sk-or-somebody-elses' '{"model":"z-ai/glm-5.3","messages":[]}')"
    [ "$code" = "401" ]

    # nothing reached the upstream on any of those
    [ ! -f "$REC/body.json" ]

    # and the good token still works, so 401 is about the token and nothing else
    code="$(post /api/v1/chat/completions 'Bearer guard-token-abc' '{"model":"z-ai/glm-5.3","messages":[]}')"
    [ "$code" = "200" ]
    [ -f "$REC/body.json" ]
}

@test "provider-policy.json denies every China-hosted provider named in the policy and allows no provider without a country note" {
    [ -f "$POLICY" ]
    run jq -e . "$POLICY"
    [ "$status" -eq 0 ]

    # every allowed provider carries a slug and a hosting country ...
    run jq -e '(.allow | length) > 0 and ([.allow[] | select(((.slug // "") == "") or ((.country // "") == ""))] | length) == 0' "$POLICY"
    [ "$status" -eq 0 ]
    # ... and none of them is China
    run jq -e '[.allow[] | select(.country == "CN")] | length == 0' "$POLICY"
    [ "$status" -eq 0 ]

    # the China-hosted providers that serve GLM are named and denied, each
    # with a reason
    for slug in z-ai baidu alibaba siliconflow streamlake; do
        run jq -e --arg s "$slug" '[.deny[] | select(.slug == $s and ((.reason // "") != ""))] | length == 1' "$POLICY"
        [ "$status" -eq 0 ]
    done
    # every CN entry in the policy is on the deny side, never the allow side
    run jq -e '[.deny[] | select(.country == "CN")] | length >= 5' "$POLICY"
    [ "$status" -eq 0 ]

    # allow and deny never overlap
    run jq -e '([.allow[].slug] - [.deny[].slug]) == [.allow[].slug]' "$POLICY"
    [ "$status" -eq 0 ]

    # the forced request shape is part of the policy, not only of the guard
    run jq -e '.force.allow_fallbacks == false and .force.data_collection == "deny"' "$POLICY"
    [ "$status" -eq 0 ]

    # JSON has no comments: the OpenRouter field names this policy drives are
    # documented in _doc so the file explains itself
    run jq -r '._doc | tostring' "$POLICY"
    [[ "$output" == *"provider.only"* ]]
    [[ "$output" == *"allow_fallbacks"* ]]
    [[ "$output" == *"data_collection"* ]]
}
