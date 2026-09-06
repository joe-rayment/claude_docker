#!/usr/bin/env bats
#
# v3 S1 acceptance contract (claude-orca-qa2.1) -- FROZEN from RED-AT
# onward. The VM half of v3: the container image, the in-VM entrypoint
# that brings Orca up headless in serve mode, and the CI workflow that
# builds and pushes the image.
#
# This box cannot run containers (no mount namespaces), so the entrypoint
# is exercised NATIVELY here: case 1 points ORCA_BIN at the real extracted
# Orca Linux AppImage, case 2 at stubs. Case 1 never skips -- an absent
# AppImage is a FAILURE, because "we could not check" must not read as
# green. Extract it with:
#
#   cd <scratchpad>/orca-extract && ./orca-linux-arm64.AppImage --appimage-extract
#
# See .claude/plans/container-v3.md S3-S4, S7 and S9 slice 1.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/scripts/container/entrypoint.sh"
SMOKE="$REPO_ROOT/scripts/container/smoke.sh"
DOCKERFILE="$REPO_ROOT/Dockerfile"
# The install logic the Dockerfile used to carry inline. It lives here so
# it can be run for real (scripts/container/verify-rootfs.sh), and the
# version pins moved with it.
SETUP="$REPO_ROOT/scripts/container/setup.sh"
IMAGE_WORKFLOW="$REPO_ROOT/.github/workflows/image.yml"

# The extracted AppImage (squashfs-root/orca-ide). Overridable so the same
# contract runs wherever the extraction lives, but never optional.
ORCA_EXTRACT_ROOT="${CLAUDE_ORCA_APPIMAGE_ROOT:-/tmp/claude-1000/-workspace/0bcf8495-68f6-4270-aefc-7f12a96464a8/scratchpad/orca-extract/squashfs-root}"
REAL_ORCA_BIN="$ORCA_EXTRACT_ROOT/orca-ide"

# Orca's Electron runtime binds unix sockets under the user-data-dir, and
# AF_UNIX paths cap at ~108 bytes -- $BATS_TEST_TMPDIR under a long TMPDIR
# blows straight past that ("listen EINVAL", verified 2026-09-06). Every
# fixture here therefore lives under a deliberately short /tmp prefix.
short_tmpdir() {
    mktemp -d /tmp/co-ep-XXXXXX
}

free_port() {
    python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# A throwaway git repo with the .claude-dev skeleton the entrypoint writes
# into (run/ for the web-url file and logs, home/ for the agent HOME).
make_project() {
    local dir="$1"
    mkdir -p "$dir/.claude-dev/run" "$dir/.claude-dev/home"
    git init --quiet -b main "$dir" >/dev/null 2>&1
    git -C "$dir" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m init >/dev/null 2>&1
}

# Starts the entrypoint in its own session so the whole tree (entrypoint +
# the Orca child it spawns) can be signalled as one process group, and
# records that group's pgid in $TMP/ep.pgid.
start_entrypoint_bg() {
    setsid bash -c 'echo $$ > "$EP_PGID_FILE"; exec bash "$EP_SCRIPT"' \
        >"$TMP/entrypoint.out" 2>&1 &
    for _ in $(seq 1 50); do
        [ -s "$TMP/ep.pgid" ] && return 0
        sleep 0.1
    done
    return 1
}

stop_entrypoint() {
    local pgid
    if [ -s "$TMP/ep.pgid" ]; then
        pgid="$(cat "$TMP/ep.pgid")"
        kill -TERM -"$pgid" 2>/dev/null || true
        sleep 1
        kill -KILL -"$pgid" 2>/dev/null || true
    fi
}

wait_for_file() {
    local path="$1" deadline="$2" i=0
    while [ "$i" -lt "$deadline" ]; do
        [ -s "$path" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

setup() {
    TMP="$(short_tmpdir)"
    export TMP
    export EP_PGID_FILE="$TMP/ep.pgid"
    export EP_SCRIPT="$ENTRYPOINT"
}

teardown() {
    stop_entrypoint
    pkill -x orca-ide 2>/dev/null || true
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    return 0
}

@test "entrypoint starts Orca serve headless from ORCA_BIN, writes run/orca-web-url.txt with the pairing URL and run/port, and the URL serves Orca Web" {
    # Not a skip: the contract is that this is checked against the real
    # Orca Linux binary, so a missing extraction fails loudly.
    if [ ! -x "$REAL_ORCA_BIN" ]; then
        echo "extracted Orca Linux binary not found at $REAL_ORCA_BIN" >&2
        echo "run: cd \$(dirname $ORCA_EXTRACT_ROOT) && ./orca-linux-arm64.AppImage --appimage-extract" >&2
        false
    fi
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" home="$TMP/home" port urlfile origin
    make_project "$proj"
    mkdir -p "$home"
    port="$(free_port)"

    export HOME="$home"
    export PROJECT_DIR="$proj"
    export ORCA_PORT="$port"
    export ORCA_BIN="$REAL_ORCA_BIN"
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=120

    start_entrypoint_bg

    urlfile="$proj/.claude-dev/run/orca-web-url.txt"
    if ! wait_for_file "$urlfile" 120; then
        echo "--- entrypoint stdout ---" >&2
        cat "$TMP/entrypoint.out" >&2 || true
        echo "--- orca-serve.log ---" >&2
        tail -40 "$proj/.claude-dev/run/orca-serve.log" >&2 || true
        false
    fi

    # The pairing offer must be in the fragment: without it the browser
    # lands on an unpaired "paste a pairing URL" form.
    run cat "$urlfile"
    [ "$status" -eq 0 ]
    [[ "$output" == *"#pairing=orca%3A%2F%2Fpair"* ]]
    [[ "$output" == *"127.0.0.1:$port"* ]]

    # The port the Mac side will publish and open.
    run cat "$proj/.claude-dev/run/port"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | tr -d '[:space:]')" = "$port" ]

    # Credentials live in that pairing code -- owner-only.
    run stat -c '%a' "$urlfile"
    [ "$status" -eq 0 ]
    [ "$output" = "600" ]

    # ...and the URL actually serves Orca Web.
    origin="$(sed -E 's#^(https?://[^/]+).*#\1#' "$urlfile")"
    run curl -s --max-time 30 "$origin/"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Orca Web"* ]]
}

@test "entrypoint with a stub ORCA_BIN writes the web-url file, runs repo add once, and exits non-zero within the timeout when no Web client URL appears" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" home="$TMP/home" port urlfile
    make_project "$proj"
    mkdir -p "$home" "$TMP/bin"
    port="$(free_port)"

    # A stub Orca that speaks serve's two log lines and then stays up. It
    # reads --port off its own argv, so the entrypoint failing to pass the
    # port through is itself a failure here.
    cat > "$TMP/bin/orca-ide" <<'STUB'
#!/usr/bin/env bash
port=""
prev=""
for arg in "$@"; do
    [ "$prev" = "--port" ] && port="$arg"
    prev="$arg"
done
echo "[serve] orca CLI install: installed"
echo "Orca server ready"
echo "Web client URL: http://127.0.0.1:${port}/web-index.html#pairing=x"
exec sleep 300
STUB
    chmod +x "$TMP/bin/orca-ide"

    # A stub Orca CLI recording one line of argv per invocation.
    cat > "$TMP/bin/orca" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/cli.log"
exit 0
STUB
    chmod +x "$TMP/bin/orca"
    : > "$TMP/cli.log"

    export HOME="$home"
    export PROJECT_DIR="$proj"
    export ORCA_PORT="$port"
    export ORCA_BIN="$TMP/bin/orca-ide"
    export ORCA_CLI="$TMP/bin/orca"
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=30

    start_entrypoint_bg

    urlfile="$proj/.claude-dev/run/orca-web-url.txt"
    if ! wait_for_file "$urlfile" 30; then
        cat "$TMP/entrypoint.out" >&2 || true
        false
    fi
    run cat "$urlfile"
    [ "$status" -eq 0 ]
    [ "$output" = "http://127.0.0.1:${port}/web-index.html#pairing=x" ]

    # `orca repo add` runs exactly once -- registering the project with
    # Orca, not on a loop that would re-add it every second.
    for _ in $(seq 1 20); do
        grep -q "repo add --path $proj" "$TMP/cli.log" && break
        sleep 0.5
    done
    sleep 3
    run grep -c "repo add --path $proj" "$TMP/cli.log"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    run wc -l < "$TMP/cli.log"
    [ "$(printf '%s' "$output" | tr -d '[:space:]')" = "1" ]

    stop_entrypoint

    # A serve that never announces a Web client URL must not hang the
    # container: bounded wait, non-zero exit, and the log named so the
    # Mac side can print where to look.
    local proj2="$TMP/project2" home2="$TMP/home2"
    make_project "$proj2"
    mkdir -p "$home2"
    cat > "$TMP/bin/orca-silent" <<'STUB'
#!/usr/bin/env bash
exec sleep 300
STUB
    chmod +x "$TMP/bin/orca-silent"

    HOME="$home2" PROJECT_DIR="$proj2" ORCA_PORT="$(free_port)" \
        ORCA_BIN="$TMP/bin/orca-silent" ORCA_CLI="$TMP/bin/orca" \
        CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 CLAUDE_ORCA_WEBURL_TIMEOUT=3 \
        run bash "$ENTRYPOINT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$proj2/.claude-dev/run/orca-serve.log"* ]]
    [ ! -f "$proj2/.claude-dev/run/orca-web-url.txt" ]
}

@test "Dockerfile, setup.sh, smoke.sh and image.yml exist, setup.sh pins Orca 1.4.197 and the Claude Code version from install-claude.sh, and image.yml pushes to ghcr.io/joe-rayment/claude_orca" {
    [ -f "$DOCKERFILE" ]
    [ -x "$SETUP" ]
    [ -x "$SMOKE" ]
    [ -f "$IMAGE_WORKFLOW" ]
    [ -x "$ENTRYPOINT" ]

    # The Orca release the image installs, pinned -- never 'latest'.
    run grep -c '1\.4\.197' "$SETUP"
    [ "$status" -eq 0 ]
    [ "$output" != "0" ]
    # claude-orca-qa2.6 re-pointed this one assertion: the AppImage cannot
    # be extracted under QEMU, so the image installs the release .deb.
    run grep -qE 'orca-ide_\$\{ORCA_VERSION\}_\$\{[A-Za-z_][A-Za-z0-9_]*\}\.deb' "$SETUP"
    [ "$status" -eq 0 ]

    # ONE Claude Code pin in this repo: scripts/install-claude.sh's.
    local pin
    pin="$(sed -n 's/^CLAUDE_CODE_VERSION="\([^"]*\)".*/\1/p' \
        "$REPO_ROOT/scripts/install-claude.sh" | head -1)"
    [ -n "$pin" ]
    run grep -qF "$pin" "$SETUP"
    [ "$status" -eq 0 ]

    # The image runs the entrypoint under tini.
    run grep -q 'scripts/container/entrypoint.sh' "$DOCKERFILE"
    [ "$status" -eq 0 ]

    # CI publishes to the project's GHCR repo.
    run grep -q 'ghcr.io/joe-rayment/claude_orca' "$IMAGE_WORKFLOW"
    [ "$status" -eq 0 ]
    run grep -q 'packages: write' "$IMAGE_WORKFLOW"
    [ "$status" -eq 0 ]
    run grep -q 'smoke.sh' "$IMAGE_WORKFLOW"
    [ "$status" -eq 0 ]
}
