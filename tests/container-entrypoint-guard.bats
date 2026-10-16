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
        "$(printf 'fixture-public-key-blob-0123456789' | base64 | tr -d '\n=')" \
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
