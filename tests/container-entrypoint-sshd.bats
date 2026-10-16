#!/usr/bin/env bats
# Guards:   sshd is the entrypoint's one long-running child: PID 1 waits on its supervisor, which retries (no keys yet, no sshd binary, an unusable runtime dir) instead of dying, starts a real sshd the moment the refusal clears, and a TERM takes everything down in under 5 s with exit 143
# Fails if: start_sshd is not wired into entrypoint.sh, a refusal makes the boot die or leaves a stale sshd.ready, the supervisor does not retry, PID 1 exits while the supervisor lives (or outlives it), or a TERM leaves an sshd behind or exits with anything but 143
# Run:      bats tests/container-entrypoint-sshd.bats
bats_require_minimum_version 1.5.0
#
# The entrypoint runs NATIVELY here (no privilege drop, no setup, no
# provisioning), as in tests/container-entrypoint.bats. Cases that need a
# working sshd use the real OpenSSH binaries extracted without root under
# ~/.cache/claude-orca-test/openssh and skip when they are absent; the
# refusal cases need no sshd at all. claude-orca-9bh.6 (B1), .11 (C1a).

load helpers/entrypoint-boot

OPENSSH_DIR="$HOME/.cache/claude-orca-test/openssh"
OPENSSH_LIB="$OPENSSH_DIR/usr/lib/aarch64-linux-gnu"
SSHD="$OPENSSH_DIR/usr/sbin/sshd"
SSH="$OPENSSH_DIR/usr/bin/ssh"
SSH_KEYGEN="$OPENSSH_DIR/usr/bin/ssh-keygen"

need_openssh() {
    [ -x "$SSHD" ] && [ -x "$SSH" ] && [ -x "$SSH_KEYGEN" ] || skip "extracted OpenSSH absent"
}

# The environment of a native, Orca-free boot: the fixture project as HOME's
# parent, sshd's runtime dir at the short $RT, a free port, and every step
# that is not under test (privilege drop, setup, beads, provisioning) off.
export_ep_env() {  # export_ep_env <project>
    mkdir -p "$1/.claude-dev/home"
    export HOME="$1/.claude-dev/home"
    export PROJECT_DIR="$1"
    export CLAUDE_ORCA_RUNTIME_DIR="$RT"
    export CLAUDE_ORCA_SSHD_PORT="$(free_port)"
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 CLAUDE_ORCA_SKIP_SETUP=1
    export CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_SKIP_PROVISION=1
    unset CLAUDE_ORCA_SSHD_BIN
}

# Boots the entrypoint in its own session, like start_entrypoint_bg, but
# also records the entrypoint's pid ($TMP/ep.pid) and, once it exits, its
# exit status ($TMP/ep.rc) -- the shared helper keeps neither.
boot_ep() {
    rm -f "$TMP/ep.pgid" "$TMP/ep.pid" "$TMP/ep.rc"
    setsid bash -c '
        echo $$ > "$EP_PGID_FILE"
        bash "$EP_SCRIPT" &
        echo $! > "$TMP/ep.pid"
        wait $!
        echo $? > "$TMP/ep.rc"' >"$TMP/entrypoint.out" 2>&1 &
    local i
    for i in $(seq 1 50); do
        [ -s "$TMP/ep.pid" ] && return 0
        sleep 0.1
    done
    return 1
}

# wait_for_line <file> <fixed string> <seconds>
wait_for_line() {
    local i=0
    while [ "$i" -lt "$3" ]; do
        grep -qF -- "$2" "$1" 2>/dev/null && return 0
        sleep 1
        i=$((i + 1))
    done
    echo "--- no '$2' in $1 after $3 s ---" >&2
    cat "$1" >&2 2>/dev/null || true
    return 1
}

# Real keys: a host key under state/ssh (with the authorized_keys file the
# entrypoint insists on) and a client key the test dials with.
stage_real_keys() {  # stage_real_keys <project>
    local d="$1/.claude-dev/state/ssh"
    mkdir -p "$d"
    LD_LIBRARY_PATH="$OPENSSH_LIB" "$SSH_KEYGEN" -q -t ed25519 -N '' -f "$d/host_ed25519" -C host
    LD_LIBRARY_PATH="$OPENSSH_LIB" "$SSH_KEYGEN" -q -t ed25519 -N '' -f "$TMP/client" -C client
    cp "$TMP/client.pub" "$d/authorized_keys"
}

# The entrypoint starts sshd as `$bin -D -e -f cfg`. A real image finds the
# runtime dir at /run/cdev; here it is a fixture, so this wrapper hands the
# sessions CLAUDE_ORCA_RUNTIME_DIR (SetEnv) and the extracted libs.
write_sshd_wrap() {  # write_sshd_wrap <path>
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\nexport LD_LIBRARY_PATH="%s"\nexec "%s" "$@" -o "SetEnv=CLAUDE_ORCA_RUNTIME_DIR=%s"\n' \
        "$OPENSSH_LIB" "$SSHD" "$RT" > "$1"
    chmod +x "$1"
}

# Guards:   with no keys in state/ssh the boot still finishes: the reason is in sshd.log, run/port is written, a stale sshd.ready is gone, and PID 1 keeps waiting
# Fails if: a missing key makes the entrypoint exit, the refusal is not logged, a previous boot's sshd.ready survives, or run/port is not written
# Run:      bats -f 'no ssh keys' tests/container-entrypoint-sshd.bats
@test "no ssh keys in state/ssh: sshd.log says so, no sshd.ready, run/port is written and PID 1 keeps waiting" {
    local proj="$TMP/project"
    make_project "$proj"
    export_ep_env "$proj"
    # a stale ready file from a previous boot must be cleared, not believed
    echo "port=1" > "$proj/.claude-dev/run/sshd.ready"

    boot_ep
    wait_for_line "$TMP/entrypoint.out" 'waiting on the sshd supervisor' 30

    grep -qF 'no ssh keys in state/ssh yet -- the Mac side creates them on the next ./claude-dev' \
        "$proj/.claude-dev/run/sshd.log"
    [ ! -e "$proj/.claude-dev/run/sshd.ready" ]
    [ "$(cat "$proj/.claude-dev/run/port")" = "$CLAUDE_ORCA_SSHD_PORT" ]
    sleep 1
    kill -0 "$(cat "$TMP/ep.pid")"
    [ ! -e "$TMP/ep.rc" ]
}

# Guards:   keys in state/ssh but a runtime dir that cannot be made is a logged, retried refusal, not a dead boot: both logs name it, no sshd.ready, run/port is written
# Fails if: an uncreatable runtime dir makes the entrypoint die, the refusal is only silent, or a run/sshd.ready appears without an sshd
# Run:      bats -f 'runtime dir cannot be made' tests/container-entrypoint-sshd.bats
@test "keys present but the runtime dir cannot be made: both logs say so, no sshd.ready, run/port is written" {
    local proj="$TMP/project"
    make_project "$proj"
    export_ep_env "$proj"
    export CLAUDE_ORCA_RUNTIME_DIR=/proc/no-such-dir/cdev
    local st="$proj/.claude-dev/state/ssh"
    mkdir -p "$st"
    echo placeholder > "$st/host_ed25519"
    echo placeholder > "$st/host_ed25519.pub"
    echo placeholder > "$st/authorized_keys"

    boot_ep
    wait_for_line "$TMP/entrypoint.out" 'waiting on the sshd supervisor' 30
    wait_for_line "$proj/.claude-dev/run/sshd.log" 'not writable' 10

    grep -qF 'is not creatable; sshd will not start' "$TMP/entrypoint.out"
    grep -qF 'sshd runtime dir /proc/no-such-dir/cdev/ssh is not writable; sshd not started' \
        "$proj/.claude-dev/run/sshd.log"
    [ ! -e "$proj/.claude-dev/run/sshd.ready" ]
    [ "$(cat "$proj/.claude-dev/run/port")" = "$CLAUDE_ORCA_SSHD_PORT" ]
    kill -0 "$(cat "$TMP/ep.pid")"
    [ ! -e "$TMP/ep.rc" ]
}
