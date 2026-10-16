#!/usr/bin/env bats
# Guards:   the entrypoint starts the container's sshd beside Orca when the Mac side has made the ssh keys, says why when it does not, and never lets a missing key or an unusable runtime dir stop Orca from coming up
# Fails if: start_sshd is not wired into entrypoint.sh, a missing key makes the boot die (or leaves a stale sshd.ready), a failed mkdir of the runtime dir is fatal, or a TERM to the entrypoint leaves an sshd behind
# Run:      bats tests/container-entrypoint-sshd.bats
bats_require_minimum_version 1.5.0
#
# The entrypoint runs NATIVELY here, as it does in tests/container-entrypoint.bats
# (no privilege drop, a stub Orca that dumps its environment and sleeps). The
# real-sshd case uses the OpenSSH binaries extracted without root under
# ~/.cache/claude-orca-test/openssh and skips when they are absent.
# claude-orca-9bh.6 (B1).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/scripts/container/entrypoint.sh"
OPENSSH_DIR="$HOME/.cache/claude-orca-test/openssh"
OPENSSH_LIB="$OPENSSH_DIR/usr/lib/aarch64-linux-gnu"
SSHD="$OPENSSH_DIR/usr/sbin/sshd"
SSH="$OPENSSH_DIR/usr/bin/ssh"
SSH_KEYGEN="$OPENSSH_DIR/usr/bin/ssh-keygen"

# AF_UNIX paths cap at ~108 bytes, so every fixture lives under a short prefix.
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

make_project() {
    local dir="$1"
    mkdir -p "$dir/.claude-dev/run" "$dir/.claude-dev/home"
    git init --quiet -b main "$dir" >/dev/null 2>&1
    git -C "$dir" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m init >/dev/null 2>&1
}

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

# A stub Orca that dumps its own environment before behaving like serve.
write_env_dump_orca() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
env > "$ORCA_ENV_DUMP"
port=""
prev=""
for arg in "$@"; do
    [ "$prev" = "--port" ] && port="$arg"
    prev="$arg"
done
echo "Web client URL: http://127.0.0.1:${port}/web-index.html#pairing=x"
exec sleep 300
STUB
    chmod +x "$path"
}

# Everything the entrypoint needs to reach the point of launching Orca, with
# no real Orca, no beads, no setup and no network.
export_guard_test_env() {  # export_guard_test_env <project> <user-data-dir>
    export HOME="$TMP/home"
    export PROJECT_DIR="$1"
    export ORCA_USER_DATA_DIR="$2"
    export ORCA_PORT="$(free_port)"
    export ORCA_BIN="$TMP/bin/orca-ide"
    export ORCA_CLI=/bin/true
    export ORCA_ENV_DUMP="$TMP/orca.env"
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    export CLAUDE_ORCA_SKIP_SETUP=1
    export CLAUDE_ORCA_SKIP_BEADS=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=30
    export CLAUDE_ORCA_GUARD_TIMEOUT=20
}

# Boots the entrypoint in its own process group, waits for the stub Orca to
# dump its environment, and stops the tree again unless asked to keep it up.
boot_entrypoint() {  # boot_entrypoint [keep]
    rm -f "$ORCA_ENV_DUMP" "$TMP/ep.pgid"
    start_entrypoint_bg || return 1
    local i=0
    while [ "$i" -lt 60 ]; do
        [ -s "$ORCA_ENV_DUMP" ] && break
        sleep 0.5
        i=$((i + 1))
    done
    [ "${1:-}" = "keep" ] || stop_entrypoint
    if [ ! -s "$ORCA_ENV_DUMP" ]; then
        echo "--- entrypoint stdout ---" >&2
        cat "$TMP/entrypoint.out" >&2 || true
        return 1
    fi
    return 0
}

setup() {
    unset OPENROUTER_API_KEY OPENROUTER_BASE_URL OPENCODE_CONFIG \
        CLAUDE_ORCA_SETUP CLAUDE_ORCA_RUNTIME_DIR CLAUDE_ORCA_SSHD_BIN \
        CLAUDE_ORCA_SSHD_PORT CLAUDE_ORCA_HOST_PROJECT_DIR \
        CLAUDE_ORCA_HOST_LINK_ROOT
    TMP="$(short_tmpdir)"
    export TMP
    export EP_PGID_FILE="$TMP/ep.pgid"
    export EP_SCRIPT="$ENTRYPOINT"
    RT=""
}

teardown() {
    stop_entrypoint
    [ -n "${RT:-}" ] && pkill -f -- "$RT/sshd_config" 2>/dev/null
    [ -n "${TMP:-}" ] && pkill -f -- "$TMP/home/.config/orca" 2>/dev/null
    [ -n "${RT:-}" ] && rm -rf "$RT"
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    return 0
}

@test "no ssh keys in state/ssh: sshd.log says so, no sshd.ready, and Orca still comes up" {
    local proj="$TMP/project"
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin"
    write_env_dump_orca "$TMP/bin/orca-ide"
    export_guard_test_env "$proj" "$TMP/ud"
    # a stale ready file from a previous boot must be cleared, not believed
    echo "port=1" > "$proj/.claude-dev/run/sshd.ready"

    boot_entrypoint

    [ -s "$ORCA_ENV_DUMP" ]
    grep -qF 'no ssh keys in state/ssh yet -- the Mac side creates them on the next ./claude-dev' \
        "$proj/.claude-dev/run/sshd.log"
    [ ! -e "$proj/.claude-dev/run/sshd.ready" ]
}

@test "keys present but the runtime dir cannot be made: one log line, no sshd, Orca still comes up" {
    local proj="$TMP/project"
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin" "$proj/.claude-dev/state/ssh"
    write_env_dump_orca "$TMP/bin/orca-ide"
    export_guard_test_env "$proj" "$TMP/ud"
    # non-empty stand-ins: start_sshd must stop at the runtime dir, before it parses them
    for f in host_ed25519 host_ed25519.pub authorized_keys; do
        echo placeholder > "$proj/.claude-dev/state/ssh/$f"
    done
    export CLAUDE_ORCA_RUNTIME_DIR=/proc/no-such-dir/cdev

    boot_entrypoint

    [ -s "$ORCA_ENV_DUMP" ]
    grep -qF 'not creatable' "$TMP/entrypoint.out"
    grep -qF 'not writable' "$proj/.claude-dev/run/sshd.log"
    [ ! -e "$proj/.claude-dev/run/sshd.ready" ]
}

@test "real sshd: the entrypoint starts it, an ssh pane lands in the project with the boot env, TERM to the entrypoint leaves no sshd" {
    [ -x "$SSHD" ] && [ -x "$SSH" ] && [ -x "$SSH_KEYGEN" ] || skip "extracted OpenSSH absent"
    local proj="$TMP/project" port want i pid epid
    RT="/tmp/cdev-b1-$$"
    rm -rf "$RT"
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin" "$proj/.claude-dev/state/ssh" "$RT"
    write_env_dump_orca "$TMP/bin/orca-ide"
    export_guard_test_env "$proj" "$TMP/ud"
    LD_LIBRARY_PATH="$OPENSSH_LIB" "$SSH_KEYGEN" -q -t ed25519 -N '' -f "$proj/.claude-dev/state/ssh/host_ed25519" -C host
    LD_LIBRARY_PATH="$OPENSSH_LIB" "$SSH_KEYGEN" -q -t ed25519 -N '' -f "$TMP/client" -C client
    cp "$TMP/client.pub" "$proj/.claude-dev/state/ssh/authorized_keys"
    port="$(free_port)"
    printf '[127.0.0.1]:%s %s\n' "$port" "$(cut -d' ' -f1,2 "$proj/.claude-dev/state/ssh/host_ed25519.pub")" > "$TMP/known_hosts"
    # The entrypoint starts sshd as `$bin -D -e -f cfg`. A real image finds the
    # runtime dir at /run/cdev; here it is a fixture, so the wrapper hands the
    # sessions CLAUDE_ORCA_RUNTIME_DIR (SetEnv) and the extracted libs.
    printf '#!/bin/sh\nexport LD_LIBRARY_PATH="%s"\nexec "%s" "$@" -o "SetEnv=CLAUDE_ORCA_RUNTIME_DIR=%s"\n' \
        "$OPENSSH_LIB" "$SSHD" "$RT" > "$TMP/bin/sshd-wrap"
    chmod +x "$TMP/bin/sshd-wrap"
    export CLAUDE_ORCA_RUNTIME_DIR="$RT" CLAUDE_ORCA_SSHD_BIN="$TMP/bin/sshd-wrap" CLAUDE_ORCA_SSHD_PORT="$port"
    export DUMMY_VAR="dummy-value-$$" CLAUDE_ORCA_PANE_SHELL=/usr/bin/z""sh

    boot_entrypoint keep
    wait_for_file "$proj/.claude-dev/run/sshd.ready" 30

    want="$(LD_LIBRARY_PATH="$OPENSSH_LIB" "$SSH_KEYGEN" -lf "$proj/.claude-dev/state/ssh/host_ed25519.pub" | awk '{print $2}')"
    grep -Fxq "port=$port" "$proj/.claude-dev/run/sshd.ready"
    grep -Fxq "host_key_sha256=$want" "$proj/.claude-dev/run/sshd.ready"
    for f in env sshd_config ssh/host_ed25519; do
        [ "$(stat -c %a "$RT/$f")" = "600" ]
    done

    run --separate-stderr env LD_LIBRARY_PATH="$OPENSSH_LIB" "$SSH" -T -F /dev/null -i "$TMP/client" \
        -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
        -o UserKnownHostsFile="$TMP/known_hosts" -o GlobalKnownHostsFile=/dev/null \
        -o StrictHostKeyChecking=yes -p "$port" 127.0.0.1 'pwd; printf %s "$DUMMY_VAR"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$(cd "$proj" && pwd -P)" ]
    [ "${lines[1]}" = "$DUMMY_VAR" ]

    # TERM to the entrypoint ONLY (not its group, which would kill sshd directly):
    # its own trap has to take the restart loop and sshd down.
    epid="$(cat "$TMP/ep.pgid")"
    kill -TERM "$epid"
    for i in $(seq 1 50); do
        pgrep -f "$RT/sshd_config" >/dev/null || break
        sleep 0.2
    done
    run pgrep -f "$RT/sshd_config"
    [ "$status" -ne 0 ]
    [ ! -e "$proj/.claude-dev/run/sshd.ready" ]
}
