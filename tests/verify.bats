#!/usr/bin/env bats
#
# `claude-dev verify` -- the command that reads the seeding back.
#
# --doctor answers "can this folder open at all": the CLI, the daemon, the
# image, the container, the port, the URL. None of that says whether the
# folder is SET UP. The rulebook, the six agent definitions, the hooks
# (with Orca's own entries kept), the git identity, the Claude first-run
# keys, Orca's worktree base and theme, the beads database -- every one is
# written by code that logs a line and moves on, and nothing read any of
# it back. A folder whose seeding half failed looked exactly like one that
# worked, which is how an owner came to conclude on 2026-09-07 that the
# things they had asked for were "fundamentally missing" from the
# template. They were present; nothing could say so.
#
# Assertions are functions, never a bare `[[ ]]` (see run-tests.sh).

load helpers/setup

VERIFY_SH="${BATS_TEST_DIRNAME}/../scripts/container/verify-folder.sh"

contains() {
    case "$1" in
        *"$2"*) return 0 ;;
    esac
    printf 'expected to contain: %s\n           actual: %s\n' "$2" "$1" >&2
    return 1
}

@test "verify refuses a directory that was never registered" {
    mkdir -p "$BATS_TEST_TMPDIR/plain"
    run bash "$REPO_ROOT/scripts/launcher.sh" verify "$BATS_TEST_TMPDIR/plain"
    [ "$status" -ne 0 ]
    contains "$output" "is not registered"
}

@test "verify stops at the container when there is none, and says how to get one" {
    mkdir -p "$PROJECT_DIR"
    local primary name
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null
    name="claude-orca-$(basename "$primary")"
    rm -f "$CONTAINER_STUB_STATE/containers/$name"

    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 2 ]
    contains "$output" "container"
    contains "$output" "run ./claude-dev first"
}

@test "verify prints the Mac rows and the container's own rows, and passes when both are clean" {
    mkdir -p "$PROJECT_DIR"
    local primary
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null
    stub_sshd_up "$primary"

    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 0 ]
    # The Mac's own four.
    contains "$output" "container"
    contains "$output" "image"
    contains "$output" "port"
    contains "$output" "sshd"
    # ... and what only the container can answer, passed through.
    contains "$output" "mount point"
    contains "$output" "rulebook"
    contains "$output" "openrouter guard"
    contains "$output" "Everything this folder promises is there."
}

@test "one FAIL row from inside fails the command and names the way out" {
    mkdir -p "$PROJECT_DIR"
    local primary
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null
    stub_sshd_up "$primary"

    export CLAUDE_ORCA_TEST_VERIFY_FAIL=1
    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 2 ]
    contains "$output" "FAIL"
    contains "$output" "rulebook"
    contains "$output" "--update"
}

@test "the in-container checklist prints parseable rows and fails when the folder is wrong" {
    # Run natively, against a directory that is NOT a set-up folder: every
    # row is a FAIL or n/a, which is exactly what the format has to
    # survive. What matters here is the shape the launcher parses.
    run env PROJECT_DIR="$BATS_TEST_TMPDIR/nowhere" HOME="$BATS_TEST_TMPDIR/nohome" \
        bash "$VERIFY_SH"
    [ "$status" -eq 1 ]

    local line first
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        first="${line%%	*}"
        case "$first" in
            ok|FAIL|n/a) ;;
            *) echo "row does not start with ok/FAIL/n/a: $line"; return 1 ;;
        esac
        # name and detail are the other two fields
        case "$line" in
            *"	"*) ;;
            *) echo "row is not tab separated: $line"; return 1 ;;
        esac
    done <<< "$output"

    contains "$output" "mount point"
}

@test "a container whose image predates the checklist fails verify instead of passing it" {
    # The four Mac rows are about the container, not about the folder's
    # setup, so on their own they say nothing -- and an image older than
    # verify-folder.sh makes the exec answer nothing at all. Reporting
    # that as "everything this folder promises is there" would be the
    # exact failure this command was written to end.
    mkdir -p "$PROJECT_DIR"
    local primary
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null
    stub_sshd_up "$primary"

    export CLAUDE_ORCA_TEST_VERIFY_SILENT=1
    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 2 ]
    contains "$output" "answered nothing"
    contains "$output" "--update"
}

# --- claude-orca-8tx: the row must say something is wrong, not n/a --------
#
# config-sync copies opencode.json into every folder unconditionally, and
# its baseURL always names the guard. Gating this row on
# OPENROUTER_API_KEY/OPENROUTER_BASE_URL read n/a in every real run of this
# script: those are Orca agentDefaultEnv vars, visible inside a terminal
# Orca starts, never inside the fresh `docker exec` this script actually
# runs under. A folder whose synced client config points at a guard that
# is not running must fail this row, not skip it.

openrouter_guard_row() {
    printf '%s\n' "$output" | grep -F "	openrouter guard	"
}

@test "verify-folder FAILs openrouter guard when opencode names it and nothing answers" {
    local home port line
    home="$BATS_TEST_TMPDIR/home-noguard"
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    mkdir -p "$home/.config/opencode"
    printf '{"provider":{"openrouter":{"options":{"baseURL":"http://127.0.0.1:%s/api/v1"}}}}\n' \
        "$port" > "$home/.config/opencode/opencode.json"

    run env -u OPENROUTER_API_KEY -u OPENROUTER_BASE_URL \
        PROJECT_DIR="$BATS_TEST_TMPDIR/nowhere" HOME="$home" \
        bash "$VERIFY_SH"

    line="$(openrouter_guard_row)"
    [ -n "$line" ]
    case "$line" in
        FAIL*) ;;
        *) echo "expected a FAIL row for openrouter guard: $line"; return 1 ;;
    esac
    # claude-orca-376: names the in-container file first, the Mac command
    # only as the alternative that writes the same file.
    contains "$line" "$home/.openrouter.key"
    contains "$line" "./claude-dev key openrouter"
}

@test "verify-folder's openrouter guard FAIL row names 'opencode auth login openrouter' as the primary remedy (claude-orca-b30)" {
    local home port line
    home="$BATS_TEST_TMPDIR/home-noguard-b30"
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    mkdir -p "$home/.config/opencode"
    printf '{"provider":{"openrouter":{"options":{"baseURL":"http://127.0.0.1:%s/api/v1"}}}}\n' \
        "$port" > "$home/.config/opencode/opencode.json"

    run env -u OPENROUTER_API_KEY -u OPENROUTER_BASE_URL \
        PROJECT_DIR="$BATS_TEST_TMPDIR/nowhere" HOME="$home" \
        bash "$VERIFY_SH"

    line="$(openrouter_guard_row)"
    [ -n "$line" ]
    case "$line" in
        FAIL*) ;;
        *) echo "expected a FAIL row for openrouter guard: $line"; return 1 ;;
    esac
    # the login is named before the folder-key/Mac-command fallback, and
    # the row says a restart is needed
    contains "$line" "opencode auth login openrouter"
    contains "$line" "$home/.openrouter.key"
    contains "$line" "restart"
    case "$line" in
        *"opencode auth login openrouter"*"$home/.openrouter.key"*) ;;
        *) echo "expected the login to come before the key-file fallback: $line"; return 1 ;;
    esac
}

# --- claude-orca-0v6: a running guard answers 401 without its token ---------
#
# The row used to probe with `curl -f`, which treats any 4xx as failure, so a
# guard that was up (and answering 401 to a probe that carries no token)
# was reported as "nothing answers there". Any HTTP status means something
# listens; only a refused connection is down.

# Start a tiny HTTP server answering <status> to every GET on a free port.
# Sets GUARD_PID and GUARD_PORT; the caller kills GUARD_PID.
start_status_server() {
    local status="$1" i
    cat > "$BATS_TEST_TMPDIR/status-server.py" <<'PY'
import http.server, sys
status = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
    python3 -I "$BATS_TEST_TMPDIR/status-server.py" "$status" \
        > "$BATS_TEST_TMPDIR/status-server.port" 2>/dev/null 3>&- &
    GUARD_PID=$!
    GUARD_PORT=""
    for i in $(seq 1 50); do
        GUARD_PORT="$(cat "$BATS_TEST_TMPDIR/status-server.port" 2>/dev/null)"
        [ -n "$GUARD_PORT" ] && break
        sleep 0.1
    done
    [ -n "$GUARD_PORT" ]
}

# bats test_tags=size:medium
@test "verify-folder says the openrouter guard is listening when it answers 401 without its token (claude-orca-0v6)" {
    # Guards:   a running guard (it answers 401 to a tokenless probe) is reported ok, not "nothing answers"
    # Fails if: the probe goes back to `curl -f`, which turns any 4xx into "down"
    # Run:      bats -f '0v6' tests/verify.bats
    local home line
    home="$BATS_TEST_TMPDIR/home-guard401"
    start_status_server 401
    mkdir -p "$home/.config/opencode"
    printf '{"provider":{"openrouter":{"options":{"baseURL":"http://127.0.0.1:%s/api/v1"}}}}\n' \
        "$GUARD_PORT" > "$home/.config/opencode/opencode.json"

    # The real curl, not setup()'s stub (which fakes any `-o <file>` call).
    run env -u OPENROUTER_API_KEY -u OPENROUTER_BASE_URL \
        PATH="$ORIGINAL_PATH" PROJECT_DIR="$BATS_TEST_TMPDIR/nowhere" HOME="$home" \
        bash "$VERIFY_SH"
    kill "$GUARD_PID" 2>/dev/null || true

    line="$(openrouter_guard_row)"
    [ -n "$line" ]
    case "$line" in
        ok*) ;;
        *) echo "expected an ok row for a guard answering 401: $line"; return 1 ;;
    esac
    contains "$line" "listening on http://127.0.0.1:$GUARD_PORT/api/v1"
}

@test "verify-folder's openrouter guard row stays FAIL on a refused connection, not just on a bad status (claude-orca-0v6)" {
    # Guards:   a port with nothing listening still FAILs the guard row after the any-status rule
    # Fails if: the probe treats curl's empty/000 result as "something answered"
    # Run:      bats -f '0v6' tests/verify.bats
    local home port line
    home="$BATS_TEST_TMPDIR/home-closed-0v6"
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    mkdir -p "$home/.config/opencode"
    printf '{"provider":{"openrouter":{"options":{"baseURL":"http://127.0.0.1:%s/api/v1"}}}}\n' \
        "$port" > "$home/.config/opencode/opencode.json"

    # The real curl, not setup()'s stub (which fakes any `-o <file>` call).
    run env -u OPENROUTER_API_KEY -u OPENROUTER_BASE_URL \
        PATH="$ORIGINAL_PATH" PROJECT_DIR="$BATS_TEST_TMPDIR/nowhere" HOME="$home" \
        bash "$VERIFY_SH"

    line="$(openrouter_guard_row)"
    [ -n "$line" ]
    case "$line" in
        FAIL*) ;;
        *) echo "expected a FAIL row for a refused connection: $line"; return 1 ;;
    esac
    contains "$line" "nothing answers there"
}

@test "verify-folder still says n/a for openrouter guard when opencode names no guard" {
    local home line
    home="$BATS_TEST_TMPDIR/home-noopencode"
    mkdir -p "$home"

    run env -u OPENROUTER_API_KEY -u OPENROUTER_BASE_URL \
        PROJECT_DIR="$BATS_TEST_TMPDIR/nowhere" HOME="$home" \
        bash "$VERIFY_SH"

    line="$(openrouter_guard_row)"
    [ -n "$line" ]
    case "$line" in
        n/a*) ;;
        *) echo "expected an n/a row for openrouter guard: $line"; return 1 ;;
    esac
}
