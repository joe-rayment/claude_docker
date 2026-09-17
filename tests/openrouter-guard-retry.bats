#!/usr/bin/env bats
#
# claude-orca-m57 acceptance contract -- FROZEN from RED-AT onward.
#
# A transient upstream 429/502/503/529 must be absorbed by the guard itself
# (scripts/container/openrouter-guard.py) with exponential backoff, not
# handed straight to the client to sit idle on. Exercises the real guard
# against a STUB upstream (a python3 stdlib server started by this file)
# that answers a scripted sequence of statuses per request, so nothing here
# touches openrouter.ai.
#
# OPENROUTER_GUARD_RETRY_BASE_S=0.1 keeps every non-Retry-After case fast;
# the Retry-After case uses a real "Retry-After: 1" header and asserts
# sleep_s == 1 in the guard's JSON log.

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
# Stub OpenRouter upstream: serves a scripted sequence of statuses, one per
# request, clamping to the last entry once the sequence is exhausted -- so
# "429 always" is just a one-entry list. Every request is counted so the
# test can assert how many times the guard actually reached upstream.
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REC = os.environ["UPSTREAM_REC"]
STATUSES = [int(s) for s in os.environ["UPSTREAM_STATUSES"].split(",") if s]
RETRY_AFTER = os.environ.get("UPSTREAM_RETRY_AFTER", "")

LOCK = threading.Lock()
COUNT = {"n": 0}

OK_BODY = b'{"id":"cmpl-1","choices":[{"message":{"content":"ok"}}]}'


def err_body(status):
    return json.dumps({"error": {"code": status, "message": "upstream said no"}}).encode("utf-8")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        with LOCK:
            idx = COUNT["n"]
            COUNT["n"] += 1
        status = STATUSES[idx] if idx < len(STATUSES) else STATUSES[-1]
        with open(os.path.join(REC, "req-%d.json" % idx), "wb") as f:
            f.write(body)
        with open(os.path.join(REC, "count.txt"), "w") as f:
            f.write(str(COUNT["n"]))
        payload = OK_BODY if status == 200 else err_body(status)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        if status == 429 and RETRY_AFTER:
            self.send_header("Retry-After", RETRY_AFTER)
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

start_upstream() {  # start_upstream <csv-statuses> [retry-after-value]
    UP_PORT="$(free_port)"
    UPSTREAM_REC="$REC" UPSTREAM_STATUSES="$1" UPSTREAM_RETRY_AFTER="${2:-}" \
        python3 "$STUB" "$UP_PORT" > "$BATS_TEST_TMPDIR/upstream.log" 2>&1 &
    UP_PID=$!
    wait_port "$UP_PORT"
}

start_guard() {  # start_guard [extra env assignments...]
    GP="$(free_port)"
    env "$@" \
        OPENROUTER_API_KEY=real-secret \
        OPENROUTER_GUARD_TOKEN=guard-token-abc \
        OPENROUTER_UPSTREAM="http://127.0.0.1:$UP_PORT" \
        python3 "$GUARD" --port "$GP" --policy "$POLICY" --run-dir "$RUN" \
        > "$BATS_TEST_TMPDIR/guard.log" 2>&1 &
    GUARD_PID=$!
    wait_port "$GP"
}

post() {  # post <path> <auth-header-value> <json-body> -- prints the HTTP code
    curl -s -o "$BATS_TEST_TMPDIR/resp.out" -w '%{http_code}' \
        -X POST "http://127.0.0.1:$GP$1" \
        -H "Authorization: $2" \
        -H 'Content-Type: application/json' \
        --data-binary "$3"
}

LOG() { echo "$RUN/openrouter-guard.log"; }

@test "429 twice then 200: the client gets 200 and the guard log has two retry lines" {
    start_upstream "429,429,200"
    start_guard OPENROUTER_GUARD_RETRY_BASE_S=0.1

    code="$(post /api/v1/chat/completions 'Bearer guard-token-abc' '{"model":"z-ai/glm-5.3","messages":[]}')"
    [ "$code" = "200" ]
    run jq -r '.id' "$BATS_TEST_TMPDIR/resp.out"
    [ "$output" = "cmpl-1" ]

    [ "$(cat "$REC/count.txt")" = "3" ]

    log="$(LOG)"
    [ -f "$log" ]
    # the two retry lines are numbered 1 and 2, each against status 429
    retry_count="$(jq -c 'select(.retry != null)' "$log" | wc -l | tr -d ' ')"
    [ "$retry_count" -eq 2 ]
    first_retry="$(jq -c 'select(.retry != null)' "$log" | sed -n '1p')"
    second_retry="$(jq -c 'select(.retry != null)' "$log" | sed -n '2p')"
    run jq -e '.retry == 1 and .status == 429' <<< "$first_retry"
    [ "$status" -eq 0 ]
    run jq -e '.retry == 2 and .status == 429' <<< "$second_retry"
    [ "$status" -eq 0 ]
    # the final, non-retry completion line records the eventual success
    final="$(jq -c 'select(.retry == null)' "$log" | tail -n1)"
    run jq -e '.status == 200 and (.retries_exhausted // false) == false' <<< "$final"
    [ "$status" -eq 0 ]
}

@test "429 always with GUARD_RETRY_MAX=2: the client gets 429 and the log records retries_exhausted" {
    start_upstream "429"
    start_guard OPENROUTER_GUARD_RETRY_MAX=2 OPENROUTER_GUARD_RETRY_BASE_S=0.1

    code="$(post /api/v1/chat/completions 'Bearer guard-token-abc' '{"model":"z-ai/glm-5.3","messages":[]}')"
    [ "$code" = "429" ]
    run jq -e '.error.code == 429' "$BATS_TEST_TMPDIR/resp.out"
    [ "$status" -eq 0 ]

    # exactly 3 requests reached upstream: the original plus 2 retries
    [ "$(cat "$REC/count.txt")" = "3" ]

    log="$(LOG)"
    retry_count="$(jq -c 'select(.retry != null)' "$log" | wc -l | tr -d ' ')"
    [ "$retry_count" -eq 2 ]

    final="$(jq -c 'select(.retry == null)' "$log" | tail -n1)"
    run jq -e '.status == 429 and .retries_exhausted == true' <<< "$final"
    [ "$status" -eq 0 ]
}

@test "Retry-After: 1 on a 429 is honoured -- sleep_s == 1 in the log" {
    start_upstream "429,200" "1"
    start_guard OPENROUTER_GUARD_RETRY_BASE_S=0.1

    code="$(post /api/v1/chat/completions 'Bearer guard-token-abc' '{"model":"z-ai/glm-5.3","messages":[]}')"
    [ "$code" = "200" ]

    log="$(LOG)"
    retry_line="$(jq -c 'select(.retry != null)' "$log")"
    run jq -e '.retry == 1 and .status == 429 and .sleep_s == 1' <<< "$retry_line"
    [ "$status" -eq 0 ]
}

@test "OPENROUTER_GUARD_RETRY_MAX=0 disables retries: a single 429 passes straight through, no retry line" {
    start_upstream "429"
    start_guard OPENROUTER_GUARD_RETRY_MAX=0

    code="$(post /api/v1/chat/completions 'Bearer guard-token-abc' '{"model":"z-ai/glm-5.3","messages":[]}')"
    [ "$code" = "429" ]

    # exactly one request reached upstream -- no retry was attempted
    [ "$(cat "$REC/count.txt")" = "1" ]

    log="$(LOG)"
    retries="$(jq -c 'select(.retry != null)' "$log")"
    [ -z "$retries" ]
}

@test "the existing guard test suite stays green alongside the retry logic" {
    run bats "$REPO_ROOT/tests/openrouter-guard.bats"
    [ "$status" -eq 0 ]
}
