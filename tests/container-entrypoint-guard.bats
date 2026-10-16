#!/usr/bin/env bats
# Guards:   the OpenRouter guard is wired into the entrypoint -- it starts when a
#           key exists (env var, then AGENT_HOME/.openrouter.key, then opencode's
#           auth.json), sshd (and so every ssh pane) inherits only its token and
#           loopback base URL, never the real key, and a request through it
#           carries the real key and the forced provider allowlist.
# Fails if: the entrypoint exports the real key to sshd, starts no guard when a key
#           file exists, picks the wrong key source, or lets the client's provider
#           choice through.
# Run:      bats tests/container-entrypoint-guard.bats
#
# Ported from tests/container-entrypoint.bats :1208-1857 and :2349-2450 (slice
# E2 of the C1a split). The Orca env-dump stub is now a stub sshd: the
# entrypoint exports the guard's token before it starts sshd, so the stub's
# environment IS what an ssh pane inherits. Nothing here touches openrouter.ai:
# OPENROUTER_UPSTREAM points the guard at a python3 stdlib stub.

load helpers/entrypoint-boot

# The key that must never be visible to an agent terminal.
REAL_KEY="sk-or-v1-real-secret-never-in-a-terminal"

# A stub sshd that dumps its own environment, then idles like sshd -D.
write_env_dump_sshd() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
env > "$SSHD_ENV_DUMP"
exec sleep 300
STUB
    chmod +x "$path"
}

# The three files the entrypoint insists on before it will try sshd at all
# (a host key pair, in a form the fingerprinting can read, and an
# authorized_keys). The key material is a throwaway blob, not a real key.
stage_ssh_keys() {  # stage_ssh_keys <project>
    local d="$1/.claude-dev/state/ssh"
    mkdir -p "$d"
    printf 'fixture-private-key\n' > "$d/host_ed25519"
    printf 'ssh-ed25519 %s fixture\n' \
        "$(printf 'fixture-public-key-blob-0123456789' | base64 | tr -d '\n')" \
        > "$d/host_ed25519.pub"
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIfixture fixture\n' > "$d/authorized_keys"
}

# A stub OpenRouter that records the bytes that would have left the VM. It
# self-terminates so a failed assertion cannot leave it running.
write_upstream_stub() {
    cat > "$TMP/upstream.py" <<'PY'
import os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
REC = os.environ["UPSTREAM_REC"]
threading.Timer(180, lambda: os._exit(0)).start()


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
        payload = b'{"id":"cmpl-1","choices":[{"message":{"content":"ok"}}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
}

wait_tcp_port() {
    local i=0
    while [ "$i" -lt 100 ]; do
        if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.3); sys.exit(0 if s.connect_ex(('127.0.0.1',$1))==0 else 1)"; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.2
    done
    echo "port $1 never came up" >&2
    return 1
}

# Boots the entrypoint in its own process group with whatever this test has
# exported, waits for the stub sshd to dump its environment, and stops the
# whole tree again unless asked to keep it up.
boot_entrypoint() {  # boot_entrypoint [keep]
    rm -f "$SSHD_ENV_DUMP" "$TMP/ep.pgid"
    start_entrypoint_bg || return 1
    local i=0
    while [ "$i" -lt 80 ]; do
        [ -s "$SSHD_ENV_DUMP" ] && break
        sleep 0.5
        i=$((i + 1))
    done
    [ "${1:-}" = "keep" ] || stop_entrypoint
    if [ ! -s "$SSHD_ENV_DUMP" ]; then
        echo "--- entrypoint stdout ---" >&2
        cat "$TMP/entrypoint.out" >&2 || true
        return 1
    fi
    return 0
}

# Everything the entrypoint needs to reach the point of starting sshd, with a
# stub sshd, staged ssh keys, no beads, no setup, no provisioning and no
# network. HOME is $TMP/home, so AGENT_HOME/.openrouter.key is $TMP/home/....
export_guard_test_env() {  # export_guard_test_env <project>
    export HOME="$TMP/home"
    export PROJECT_DIR="$1"
    mkdir -p "$TMP/home" "$TMP/bin"
    write_env_dump_sshd "$TMP/bin/sshd-stub"
    stage_ssh_keys "$1"
    export CLAUDE_ORCA_SSHD_BIN="$TMP/bin/sshd-stub"
    export CLAUDE_ORCA_SSHD_PORT="$(free_port)"
    export CLAUDE_ORCA_RUNTIME_DIR="$RT"
    export SSHD_ENV_DUMP="$TMP/sshd.env"
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    export CLAUDE_ORCA_SKIP_SETUP=1
    export CLAUDE_ORCA_SKIP_BEADS=1
    export CLAUDE_ORCA_SKIP_PROVISION=1
    export CLAUDE_ORCA_GUARD_TIMEOUT=20
}

# A second boot inside one case needs its own sshd runtime dir (the first
# one's files are still under the old one).
new_runtime_dir() {
    [ -n "${RT:-}" ] && rm -rf "$RT"
    RT="$(mktemp -d /tmp/cdev-c1a-XXXXXX)"
    export RT
}

# Guards:   with a key in the environment the entrypoint starts the guard and
#           sshd -- so every ssh pane -- gets its token and loopback URL only.
# Fails if: the real key reaches sshd's environment, the token file is not
#           mode 600, or no guard is listening.
# Run:      bats -f 'starts the OpenRouter guard when a key is present' tests/container-entrypoint-guard.bats
@test "the entrypoint starts the OpenRouter guard when a key is present and ssh panes see only the guard token and base URL" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" gport token gpid
    make_project "$proj"
    gport="$(free_port)"

    export_guard_test_env "$proj"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    export OPENROUTER_API_KEY="$REAL_KEY"
    # the guard is started, but it is never allowed to reach the internet
    export OPENROUTER_UPSTREAM="http://127.0.0.1:1"

    boot_entrypoint keep

    # the guard is a real running process, and it is listening
    [ -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
    gpid="$(cat "$proj/.claude-dev/run/openrouter-guard.pid")"
    kill -0 "$gpid"
    wait_tcp_port "$gport"
    grep -qF 'openrouter-guard: listening' "$proj/.claude-dev/run/openrouter-guard.log"

    # the token it handed out is a credential of its own: owner-only, and
    # never the real key
    [ -s "$proj/.claude-dev/run/openrouter-guard.token" ]
    run stat -c '%a' "$proj/.claude-dev/run/openrouter-guard.token"
    [ "$output" = "600" ]
    token="$(cat "$proj/.claude-dev/run/openrouter-guard.token")"
    [ -n "$token" ]
    [ "$token" != "$REAL_KEY" ]

    # what every ssh pane inherits from sshd: the token and the guard's
    # loopback base URL, and the real key nowhere at all
    grep -qxF "OPENROUTER_API_KEY=$token" "$SSHD_ENV_DUMP"
    grep -qxF "OPENROUTER_BASE_URL=http://127.0.0.1:$gport/api/v1" "$SSHD_ENV_DUMP"
    run grep -c -- "$REAL_KEY" "$SSHD_ENV_DUMP"
    [ "$output" = "0" ]

    stop_entrypoint
}

# Guards:   a guard that cannot start fails closed on the KEY, not on the boot:
#           sshd still comes up, with no OpenRouter variables and no real key.
# Fails if: the entrypoint falls back to passing the real key to sshd when the
#           guard script is missing, or says nothing about it.
# Run:      bats -f 'guard that cannot start' tests/container-entrypoint-guard.bats
@test "a guard that cannot start leaves sshd without OpenRouter instead of with an unpoliced key" {
    local proj="$TMP/project2"
    make_project "$proj"
    export_guard_test_env "$proj"
    export CLAUDE_ORCA_GUARD_PORT="$(free_port)"
    export CLAUDE_ORCA_GUARD_SCRIPT="$TMP/no-such-guard.py"
    export OPENROUTER_API_KEY="$REAL_KEY"

    boot_entrypoint
    run grep -c -- "$REAL_KEY" "$SSHD_ENV_DUMP"
    [ "$output" = "0" ]
    run grep -c '^OPENROUTER_BASE_URL=' "$SSHD_ENV_DUMP"
    [ "$output" = "0" ]
    [ ! -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
    # and it says so loudly rather than failing silently
    run cat "$TMP/entrypoint.out"
    [[ "$output" == *"OpenRouter guard"* ]]
}

# Guards:   with no key anywhere the guard is simply off and sshd has nothing
#           OpenRouter-shaped to hand to a pane.
# Fails if: a guard is started without a key, or OPENROUTER_BASE_URL leaks into
#           sshd's environment anyway.
# Run:      bats -f 'no key reached the VM' tests/container-entrypoint-guard.bats
@test "when no key reached the VM there is no guard and nothing for a pane to inherit" {
    local proj="$TMP/project3"
    make_project "$proj"
    export_guard_test_env "$proj"
    export CLAUDE_ORCA_GUARD_PORT="$(free_port)"
    export OPENROUTER_API_KEY=""

    boot_entrypoint
    [ ! -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
    run grep -c '^OPENROUTER_BASE_URL=' "$SSHD_ENV_DUMP"
    [ "$output" = "0" ]
}

# --- claude-orca-376: the key file IS the container's own home ----------
#
# $AGENT_HOME/.openrouter.key (the same file `claude-dev key openrouter`
# writes on the Mac, since .claude-dev/home and /home/agent are the same
# directory) is something the entrypoint reads for itself, so the Mac side
# does not have to put the key in the docker-run argv for the guard to start.

# Guards:   a key in AGENT_HOME/.openrouter.key alone starts the guard, the key
#           never reaches sshd's environment, and the file survives the boot.
# Fails if: the entrypoint ignores the key file, leaks its content to sshd, or
#           deletes it like a one-shot handoff.
# Run:      bats -f 'from AGENT_HOME/.openrouter.key when OPENROUTER_API_KEY is unset' tests/container-entrypoint-guard.bats
@test "the entrypoint starts the guard from AGENT_HOME/.openrouter.key when OPENROUTER_API_KEY is unset (claude-orca-376)" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project-keyfile-only" gport
    make_project "$proj"
    gport="$(free_port)"

    export_guard_test_env "$proj"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    unset OPENROUTER_API_KEY
    export OPENROUTER_UPSTREAM="http://127.0.0.1:1"
    printf '%s\n' "$REAL_KEY" > "$TMP/home/.openrouter.key"
    chmod 600 "$TMP/home/.openrouter.key"

    boot_entrypoint keep

    [ -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
    wait_tcp_port "$gport"
    grep -qF 'openrouter-guard: listening' "$proj/.claude-dev/run/openrouter-guard.log"

    # the real key never reaches sshd's environment (what an ssh pane
    # inherits), only the guard's token and base URL do
    run grep -c -- "$REAL_KEY" "$SSHD_ENV_DUMP"
    [ "$output" = "0" ]
    grep -qxF "OPENROUTER_BASE_URL=http://127.0.0.1:$gport/api/v1" "$SSHD_ENV_DUMP"

    # the durable key file is not the one-shot handoff file: it survives
    [ -f "$TMP/home/.openrouter.key" ]

    stop_entrypoint
}

# Guards:   an explicit OPENROUTER_API_KEY outranks the key file: the request
#           that comes out of the guard carries the env key, not the file's.
# Fails if: the key file is read first, so the file's key goes upstream.
# Run:      bats -f 'explicit OPENROUTER_API_KEY still wins over AGENT_HOME' tests/container-entrypoint-guard.bats
@test "an explicit OPENROUTER_API_KEY still wins over AGENT_HOME/.openrouter.key (claude-orca-376)" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project-keyfile-override" gport upport rec other_key token base
    make_project "$proj"
    mkdir -p "$TMP/rec"
    rec="$TMP/rec"
    write_upstream_stub
    gport="$(free_port)"
    upport="$(free_port)"

    UPSTREAM_REC="$rec" python3 "$TMP/upstream.py" "$upport" \
        > "$TMP/upstream.log" 2>&1 &
    wait_tcp_port "$upport"

    export_guard_test_env "$proj"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    other_key="sk-or-v1-explicit-env-wins-0000000000000"
    export OPENROUTER_API_KEY="$other_key"
    export OPENROUTER_UPSTREAM="http://127.0.0.1:$upport"
    # the file names a DIFFERENT key; the explicit env var must win
    printf '%s\n' "$REAL_KEY" > "$TMP/home/.openrouter.key"
    chmod 600 "$TMP/home/.openrouter.key"

    boot_entrypoint keep
    wait_tcp_port "$gport"

    token="$(sed -n 's/^OPENROUTER_API_KEY=//p' "$SSHD_ENV_DUMP")"
    base="$(sed -n 's/^OPENROUTER_BASE_URL=//p' "$SSHD_ENV_DUMP")"
    [ -n "$token" ]
    [ "$base" = "http://127.0.0.1:$gport/api/v1" ]

    run curl -s -o "$TMP/resp.json" -w '%{http_code}' --max-time 30 \
        -X POST "$base/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        --data-binary '{"model":"z-ai/glm-5.3","messages":[{"role":"user","content":"hi"}]}'
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]

    [ -f "$rec/headers.txt" ]
    grep -qxF "authorization: Bearer $other_key" "$rec/headers.txt"
    run grep -c -- "$REAL_KEY" "$rec/headers.txt"
    [ "$output" = "0" ]

    stop_entrypoint
    pkill -f -- "$TMP/upstream.py" 2>/dev/null || true
}

# Guards:   with neither the env var nor any key file the guard stays off, and
#           the log says why.
# Fails if: a guard starts with no key, or the entrypoint stays silent about it.
# Run:      bats -f 'no OPENROUTER_API_KEY and no key file leaves the guard off' tests/container-entrypoint-guard.bats
@test "no OPENROUTER_API_KEY and no key file leaves the guard off, unchanged (claude-orca-376)" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project-nokey" gport
    make_project "$proj"
    gport="$(free_port)"

    export_guard_test_env "$proj"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    unset OPENROUTER_API_KEY
    [ ! -e "$TMP/home/.openrouter.key" ]

    boot_entrypoint
    [ ! -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
    run grep -c '^OPENROUTER_BASE_URL=' "$SSHD_ENV_DUMP"
    [ "$output" = "0" ]
    run cat "$TMP/entrypoint.out"
    [[ "$output" == *"no OPENROUTER_API_KEY"* ]]
}

# --- claude-orca-b30: opencode's own login is the third and last source -
#
# 'opencode auth login openrouter' already writes the real key to
# $AGENT_HOME/.local/share/opencode/auth.json (opencode's own auth store)
# inside the container. A fresh folder that only ever ran that login must
# still get a working guard. The chain grows a third rung, read fresh every
# boot and never mirrored to $AGENT_HOME/.openrouter.key: a cached copy
# would go stale the moment the user logs in again.

write_opencode_auth() {  # write_opencode_auth <path> <type> <key>
    mkdir -p "$(dirname "$1")"
    if [ -z "${3:-}" ]; then
        printf '{"openrouter":{"type":"%s"}}\n' "$2" > "$1"
    else
        printf '{"openrouter":{"type":"%s","key":"%s"}}\n' "$2" "$3" > "$1"
    fi
}

# Guards:   opencode's own auth.json is enough to start the guard, and the file
#           is left exactly as opencode wrote it (no cached .openrouter.key).
# Fails if: auth.json is not consulted, its key reaches sshd's environment, or
#           the entrypoint mirrors it into AGENT_HOME/.openrouter.key.
# Run:      bats -f "from opencode's own auth.json when no OPENROUTER_API_KEY" tests/container-entrypoint-guard.bats
@test "the entrypoint starts the guard from opencode's own auth.json when no OPENROUTER_API_KEY and no key file exist (claude-orca-b30)" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project-auth-only" gport authfile
    make_project "$proj"
    gport="$(free_port)"
    authfile="$TMP/home/.local/share/opencode/auth.json"

    export_guard_test_env "$proj"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    unset OPENROUTER_API_KEY
    export OPENROUTER_UPSTREAM="http://127.0.0.1:1"
    [ ! -e "$TMP/home/.openrouter.key" ]
    write_opencode_auth "$authfile" api "$REAL_KEY"

    boot_entrypoint keep

    [ -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
    wait_tcp_port "$gport"
    grep -qF 'openrouter-guard: listening' "$proj/.claude-dev/run/openrouter-guard.log"

    run grep -c -- "$REAL_KEY" "$SSHD_ENV_DUMP"
    [ "$output" = "0" ]
    grep -qxF "OPENROUTER_BASE_URL=http://127.0.0.1:$gport/api/v1" "$SSHD_ENV_DUMP"

    stop_entrypoint

    # auth.json is read-only input: still there, still exactly what opencode
    # wrote, never a cached copy at .openrouter.key
    [ -f "$authfile" ]
    run jq -r '.openrouter.key' "$authfile"
    [ "$output" = "$REAL_KEY" ]
    [ ! -e "$TMP/home/.openrouter.key" ]
}

# Guards:   CLAUDE_ORCA_OPENCODE_AUTH moves the place the entrypoint looks.
# Fails if: the override is ignored and only the default path is read.
# Run:      bats -f 'CLAUDE_ORCA_OPENCODE_AUTH overrides' tests/container-entrypoint-guard.bats
@test "CLAUDE_ORCA_OPENCODE_AUTH overrides where the entrypoint looks for opencode's auth.json (claude-orca-b30)" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project-auth-override" gport authfile
    make_project "$proj"
    mkdir -p "$TMP/altauth"
    gport="$(free_port)"
    authfile="$TMP/altauth/auth.json"

    export_guard_test_env "$proj"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    export CLAUDE_ORCA_OPENCODE_AUTH="$authfile"
    unset OPENROUTER_API_KEY
    export OPENROUTER_UPSTREAM="http://127.0.0.1:1"
    write_opencode_auth "$authfile" api "$REAL_KEY"
    # the default location is absent -- only the override should be read
    [ ! -e "$TMP/home/.local/share/opencode/auth.json" ]

    boot_entrypoint keep

    [ -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
    wait_tcp_port "$gport"

    stop_entrypoint
}

# Guards:   the durable key file outranks opencode's auth.json: the request
#           that leaves the guard carries the key file's key.
# Fails if: auth.json is read before the key file.
# Run:      bats -f 'AGENT_HOME/.openrouter.key wins over' tests/container-entrypoint-guard.bats
@test "AGENT_HOME/.openrouter.key wins over opencode's auth.json (claude-orca-b30)" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project-keyfile-over-auth" gport upport rec keyfile_key token base
    make_project "$proj"
    mkdir -p "$TMP/rec"
    rec="$TMP/rec"
    write_upstream_stub
    gport="$(free_port)"
    upport="$(free_port)"

    UPSTREAM_REC="$rec" python3 "$TMP/upstream.py" "$upport" \
        > "$TMP/upstream.log" 2>&1 &
    wait_tcp_port "$upport"

    export_guard_test_env "$proj"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    unset OPENROUTER_API_KEY
    export OPENROUTER_UPSTREAM="http://127.0.0.1:$upport"
    keyfile_key="sk-or-v1-keyfile-wins-over-auth-json-000"
    printf '%s\n' "$keyfile_key" > "$TMP/home/.openrouter.key"
    chmod 600 "$TMP/home/.openrouter.key"
    # a DIFFERENT key in auth.json; the durable folder key file must win
    write_opencode_auth "$TMP/home/.local/share/opencode/auth.json" api "$REAL_KEY"

    boot_entrypoint keep
    wait_tcp_port "$gport"

    token="$(sed -n 's/^OPENROUTER_API_KEY=//p' "$SSHD_ENV_DUMP")"
    base="$(sed -n 's/^OPENROUTER_BASE_URL=//p' "$SSHD_ENV_DUMP")"
    [ -n "$token" ]

    run curl -s -o "$TMP/resp.json" -w '%{http_code}' --max-time 30 \
        -X POST "$base/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        --data-binary '{"model":"z-ai/glm-5.3","messages":[{"role":"user","content":"hi"}]}'
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]

    [ -f "$rec/headers.txt" ]
    grep -qxF "authorization: Bearer $keyfile_key" "$rec/headers.txt"
    run grep -c -- "$REAL_KEY" "$rec/headers.txt"
    [ "$output" = "0" ]

    stop_entrypoint
    pkill -f -- "$TMP/upstream.py" 2>/dev/null || true
}

# Guards:   OPENROUTER_API_KEY in the environment outranks both the key file and
#           opencode's auth.json.
# Fails if: either file is consulted before the env var.
# Run:      bats -f 'wins over both AGENT_HOME' tests/container-entrypoint-guard.bats
@test "OPENROUTER_API_KEY wins over both AGENT_HOME/.openrouter.key and opencode's auth.json (claude-orca-b30)" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project-env-over-both" gport upport rec env_key token base
    make_project "$proj"
    mkdir -p "$TMP/rec"
    rec="$TMP/rec"
    write_upstream_stub
    gport="$(free_port)"
    upport="$(free_port)"

    UPSTREAM_REC="$rec" python3 "$TMP/upstream.py" "$upport" \
        > "$TMP/upstream.log" 2>&1 &
    wait_tcp_port "$upport"

    export_guard_test_env "$proj"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    env_key="sk-or-v1-env-wins-over-both-0000000000"
    export OPENROUTER_API_KEY="$env_key"
    export OPENROUTER_UPSTREAM="http://127.0.0.1:$upport"
    printf '%s\n' "sk-or-v1-keyfile-loses-here-000000000" > "$TMP/home/.openrouter.key"
    chmod 600 "$TMP/home/.openrouter.key"
    write_opencode_auth "$TMP/home/.local/share/opencode/auth.json" api "$REAL_KEY"

    boot_entrypoint keep
    wait_tcp_port "$gport"

    token="$(sed -n 's/^OPENROUTER_API_KEY=//p' "$SSHD_ENV_DUMP")"
    base="$(sed -n 's/^OPENROUTER_BASE_URL=//p' "$SSHD_ENV_DUMP")"
    [ -n "$token" ]

    run curl -s -o "$TMP/resp.json" -w '%{http_code}' --max-time 30 \
        -X POST "$base/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        --data-binary '{"model":"z-ai/glm-5.3","messages":[{"role":"user","content":"hi"}]}'
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]

    [ -f "$rec/headers.txt" ]
    grep -qxF "authorization: Bearer $env_key" "$rec/headers.txt"
    run grep -c -- "$REAL_KEY" "$rec/headers.txt"
    [ "$output" = "0" ]

    stop_entrypoint
    pkill -f -- "$TMP/upstream.py" 2>/dev/null || true
}

# Guards:   an auth.json that is absent, malformed, has an empty key or is not
#           type api falls back quietly to the no-key path (no guard, no crash).
# Fails if: a bad auth.json aborts the boot, or a non-api credential starts a
#           guard.
# Run:      bats -f "auth.json degrades quietly" tests/container-entrypoint-guard.bats
@test "opencode's auth.json degrades quietly to the no-key path when absent, malformed, empty-key, or not type api (claude-orca-b30)" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj gport authfile case

    for case in absent malformed emptykey wrongtype; do
        proj="$TMP/project-auth-$case"
        make_project "$proj"
        rm -rf "$TMP/home"
        new_runtime_dir
        gport="$(free_port)"
        authfile="$TMP/home/.local/share/opencode/auth.json"

        export_guard_test_env "$proj"
        export CLAUDE_ORCA_GUARD_PORT="$gport"
        unset OPENROUTER_API_KEY
        export OPENROUTER_UPSTREAM="http://127.0.0.1:1"

        case "$case" in
            absent)    ;;
            malformed) mkdir -p "$(dirname "$authfile")"; printf '{not json' > "$authfile" ;;
            emptykey)  write_opencode_auth "$authfile" api "" ;;
            wrongtype) write_opencode_auth "$authfile" oauth "$REAL_KEY" ;;
        esac

        boot_entrypoint
        [ ! -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
        run grep -c '^OPENROUTER_BASE_URL=' "$SSHD_ENV_DUMP"
        [ "$output" = "0" ]
        run cat "$TMP/entrypoint.out"
        [[ "$output" == *"no OPENROUTER_API_KEY"* ]]
    done
}

# Guards:   opencode's auth.json is read-only input: same bytes, same mode, no
#           temp or backup file next to it after a boot.
# Fails if: the entrypoint rewrites, moves, chmods or unlinks auth.json.
# Run:      bats -f "auth.json is never written" tests/container-entrypoint-guard.bats
@test "opencode's auth.json is never written, moved, or unlinked by the entrypoint (claude-orca-b30)" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project-auth-readonly" gport authfile dir before after
    make_project "$proj"
    gport="$(free_port)"
    authfile="$TMP/home/.local/share/opencode/auth.json"
    dir="$(dirname "$authfile")"

    export_guard_test_env "$proj"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    unset OPENROUTER_API_KEY
    export OPENROUTER_UPSTREAM="http://127.0.0.1:1"
    write_opencode_auth "$authfile" api "$REAL_KEY"
    chmod 644 "$authfile"
    before="$(cksum < "$authfile")"

    boot_entrypoint keep
    wait_tcp_port "$gport"
    stop_entrypoint

    [ -f "$authfile" ]
    after="$(cksum < "$authfile")"
    [ "$before" = "$after" ]
    run stat -c '%a' "$authfile"
    [ "$output" = "644" ]
    # no sibling temp/backup file left behind
    run ls -1 "$dir"
    [ "$output" = "auth.json" ]
}

# --- the guard's forced provider allowlist, end to end ------------------

# Guards:   a completion request made the way a pane would make it, with the
#           token and base URL read out of sshd's environment, leaves the guard
#           carrying the real key and the forced provider policy, and the
#           client cannot opt out of it.
# Fails if: the token (not the real key) goes upstream, the client's provider
#           order or data_collection survives, or no audit line is written.
# Run:      bats -f 'forced provider allowlist' tests/container-entrypoint-guard.bats
@test "a completion request from inside the VM reaches upstream with the real key and the forced provider allowlist" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project" gport upport token base allow rec
    make_project "$proj"
    mkdir -p "$TMP/rec"
    rec="$TMP/rec"
    write_upstream_stub
    gport="$(free_port)"
    upport="$(free_port)"

    UPSTREAM_REC="$rec" python3 "$TMP/upstream.py" "$upport" \
        > "$TMP/upstream.log" 2>&1 &
    wait_tcp_port "$upport"

    export_guard_test_env "$proj"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    export OPENROUTER_API_KEY="$REAL_KEY"
    export OPENROUTER_UPSTREAM="http://127.0.0.1:$upport"

    boot_entrypoint keep
    wait_tcp_port "$gport"

    # exactly what an ssh pane has to work with -- read out of sshd's own
    # environment, not out of the test's knowledge of the wiring
    token="$(sed -n 's/^OPENROUTER_API_KEY=//p' "$SSHD_ENV_DUMP")"
    base="$(sed -n 's/^OPENROUTER_BASE_URL=//p' "$SSHD_ENV_DUMP")"
    [ -n "$token" ]
    [ "$token" != "$REAL_KEY" ]
    [ "$base" = "http://127.0.0.1:$gport/api/v1" ]

    # a completion request that ASKS for a China-hosted provider
    run curl -s -o "$TMP/resp.json" -w '%{http_code}' --max-time 30 \
        -X POST "$base/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        --data-binary '{"model":"z-ai/glm-5.3","provider":{"order":["z-ai"],"allow_fallbacks":true,"data_collection":"allow"},"messages":[{"role":"user","content":"hi"}]}'
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]

    # what actually left the VM: the real key, and never the token
    [ -f "$rec/headers.txt" ]
    grep -qxF "authorization: Bearer $REAL_KEY" "$rec/headers.txt"
    run grep -c -- "$token" "$rec/headers.txt"
    [ "$output" = "0" ]

    # ... under the policy the client could not opt out of
    allow="$(jq -r '[.allow[].slug] | join(",")' "$REPO_ROOT/config/provider-policy.json")"
    run jq -r '.provider.only | join(",")' "$rec/body.json"
    [ "$output" = "$allow" ]
    run jq -e '.provider.allow_fallbacks == false and .provider.data_collection == "deny"' "$rec/body.json"
    [ "$status" -eq 0 ]
    # z-ai is not usable, so the guard forces its own explicit order in
    # place of the client's (claude-orca-c6b)
    run jq -r '.provider.order | join(",")' "$rec/body.json"
    [ "$output" = "$(jq -r '.order | join(",")' "$REPO_ROOT/config/provider-policy.json")" ]
    [ "$status" -eq 0 ]
    run jq -r '[.provider.only[] | select(. == "z-ai")] | length' "$rec/body.json"
    [ "$output" = "0" ]
    run jq -r '.model' "$rec/body.json"
    [ "$output" = "z-ai/glm-5.3" ]

    # the answer came back through the guard to the caller
    run jq -r '.id' "$TMP/resp.json"
    [ "$output" = "cmpl-1" ]

    # and the guard left an audit line for the request it forced
    run bash -c "grep '^{' '$proj/.claude-dev/run/openrouter-guard.log' | jq -se 'any(.[]; .path == \"/api/v1/chat/completions\" and .providers_forced == true and .client_order_dropped == true and .status == 200)'"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]

    stop_entrypoint
    pkill -f -- "$TMP/upstream.py" 2>/dev/null || true
}
