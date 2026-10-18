#!/usr/bin/env bats
# Guards:   sshd is the entrypoint's one long-running child: PID 1 waits on its supervisor, which retries (no keys yet, no sshd binary, an unusable runtime dir) instead of dying, starts a real sshd the moment the refusal clears, and a TERM takes everything down in under 5 s with exit 143
# Fails if: start_sshd is not wired into entrypoint.sh, a refusal makes the boot die or leaves a stale sshd.ready, the supervisor does not retry, PID 1 exits while the supervisor lives (or outlives it), or a TERM leaves an sshd behind or exits with anything but 143
# Run:      bats tests/container-entrypoint-sshd.bats
# bats file_tags=size:medium

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

# The shared teardown stops the entrypoint's process group; this one also
# kills any sshd still holding this case's runtime dir, so a failed case
# never leaves a listener behind (the wrapper execs the real sshd, whose
# command line carries "$RT/sshd_config").
teardown() {
    stop_entrypoint
    [ -n "${RT:-}" ] && pkill -f -- "$RT/sshd_config" 2>/dev/null
    [ -n "${RT:-}" ] && rm -rf "$RT"
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    return 0
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

# Guards:   keys that appear AFTER the boot (the Mac side makes them on its next ./claude-dev) bring a real sshd up with no restart: sshd.ready names the port and the host key's fingerprint, its files are mode 600, and a pane lands in the project with the boot env
# Fails if: the supervisor gives up after the first refusal, sshd.ready carries the wrong port or fingerprint, a staged file is world-readable, or a pane does not see the project dir and the boot environment
# Run:      bats -f 'keys made later' tests/container-entrypoint-sshd.bats
@test "keys made later: a real sshd starts, sshd.ready names port and fingerprint, a pane gets the project dir and the boot env" {
    need_openssh
    local proj="$TMP/project" run_dir
    make_project "$proj"
    run_dir="$proj/.claude-dev/run"
    export_ep_env "$proj"
    write_sshd_wrap "$TMP/bin/sshd"
    export CLAUDE_ORCA_SSHD_BIN="$TMP/bin/sshd" CLAUDE_ORCA_PANE_SHELL=/bin/bash
    export DUMMY_VAR=boot-env-marker

    boot_ep
    wait_for_line "$run_dir/sshd.log" 'no ssh keys in state/ssh yet' 30
    [ ! -e "$run_dir/sshd.ready" ]

    stage_real_keys "$proj"
    wait_for_file "$run_dir/sshd.ready" 30

    local fpr
    fpr="$(env LD_LIBRARY_PATH="$OPENSSH_LIB" "$SSH_KEYGEN" -lf "$proj/.claude-dev/state/ssh/host_ed25519.pub" | awk '{print $2}')"
    grep -qx "port=$CLAUDE_ORCA_SSHD_PORT" "$run_dir/sshd.ready"
    grep -qx "host_key_sha256=$fpr" "$run_dir/sshd.ready"
    local f
    for f in env sshd_config ssh/host_ed25519; do
        [ "$(stat -c %a "$RT/$f")" = "600" ]
    done

    echo "[127.0.0.1]:$CLAUDE_ORCA_SSHD_PORT $(awk '{print $1, $2}' "$proj/.claude-dev/state/ssh/host_ed25519.pub")" \
        > "$TMP/known_hosts"
    run --separate-stderr env LD_LIBRARY_PATH="$OPENSSH_LIB" "$SSH" -F /dev/null -i "$TMP/client" \
        -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile="$TMP/known_hosts" \
        -p "$CLAUDE_ORCA_SSHD_PORT" 127.0.0.1 'pwd; printf %s "$DUMMY_VAR"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$(realpath "$proj")" ]
    [ "${lines[1]}" = "boot-env-marker" ]
}

# Guards:   a missing sshd binary is a logged, retried refusal (no sshd.ready), and the supervisor starts sshd on its own within a retry or two once the binary shows up
# Fails if: a missing binary kills the boot, the refusal names the wrong path, or the supervisor never retries so sshd stays down after the binary is installed
# Run:      bats -f 'no sshd binary' tests/container-entrypoint-sshd.bats
@test "no sshd binary: sshd.log names the missing path, no sshd.ready, and the supervisor retries until the binary appears" {
    need_openssh
    local proj="$TMP/project" run_dir
    make_project "$proj"
    run_dir="$proj/.claude-dev/run"
    export_ep_env "$proj"
    stage_real_keys "$proj"
    export CLAUDE_ORCA_SSHD_BIN="$TMP/bin/no-such-sshd"

    boot_ep
    wait_for_line "$run_dir/sshd.log" 'no executable sshd at' 30
    grep -qF "no executable sshd at $TMP/bin/no-such-sshd; sshd not started" "$run_dir/sshd.log"
    [ ! -e "$run_dir/sshd.ready" ]
    kill -0 "$(cat "$TMP/ep.pid")"

    # the binary is installed: the next retry (every 5 s) brings sshd up
    write_sshd_wrap "$TMP/bin/no-such-sshd"
    wait_for_file "$run_dir/sshd.ready" 30
    grep -qx "port=$CLAUDE_ORCA_SSHD_PORT" "$run_dir/sshd.ready"
    pgrep -f -- "$RT/sshd_config" >/dev/null
}

# Guards:   PID 1 waits on the sshd supervisor: the pid it names is a live child of the entrypoint, the entrypoint stays up while it lives, and when the supervisor ends PID 1 ends with its status and takes sshd along
# Fails if: the entrypoint exits (or sits on something else) while the supervisor lives, the logged pid is not its child, the exit status is not the supervisor's, or an sshd outlives it
# Run:      bats -f 'PID 1 waits' tests/container-entrypoint-sshd.bats
@test "PID 1 waits on the sshd supervisor: a live child of the entrypoint, and PID 1 leaves with its status when it ends" {
    need_openssh
    local proj="$TMP/project" run_dir
    make_project "$proj"
    run_dir="$proj/.claude-dev/run"
    export_ep_env "$proj"
    stage_real_keys "$proj"
    write_sshd_wrap "$TMP/bin/sshd"
    export CLAUDE_ORCA_SSHD_BIN="$TMP/bin/sshd"

    boot_ep
    wait_for_file "$run_dir/sshd.ready" 30
    wait_for_line "$TMP/entrypoint.out" 'waiting on the sshd supervisor' 10

    local ep sup
    ep="$(cat "$TMP/ep.pid")"
    sup="$(sed -n 's/.*waiting on the sshd supervisor (pid \([0-9][0-9]*\)).*/\1/p' "$TMP/entrypoint.out" | head -1)"
    [ -n "$sup" ]
    kill -0 "$sup"
    [ "$(ps -o ppid= -p "$sup" | tr -d ' ')" = "$ep" ]
    pgrep -f -- "$RT/sshd_config" >/dev/null
    sleep 1
    kill -0 "$ep"
    [ ! -e "$TMP/ep.rc" ]

    # the supervisor ends (TERM, the one signal it answers): PID 1 follows with its status
    kill -TERM "$sup"
    wait_for_file "$TMP/ep.rc" 10
    [ "$(cat "$TMP/ep.rc")" = "0" ]
    grep -qF 'the sshd supervisor exited with status 0' "$TMP/entrypoint.out"
    local i
    for i in $(seq 1 30); do
        pgrep -f -- "$RT/sshd_config" >/dev/null || break
        sleep 0.2
    done
    run ! pgrep -f -- "$RT/sshd_config"
}

# Guards:   docker stop: a TERM to the entrypoint alone takes the supervisor and the real sshd down, removes sshd.ready and exits 143 in under 5 s
# Fails if: the TERM trap is lost or slow (>= 5 s, the grace docker gives), the status is not 143, an sshd_config process survives, or sshd.ready is left behind
# Run:      bats -f 'TERM exits 143' tests/container-entrypoint-sshd.bats
@test "TERM exits 143 in under 5 s with no sshd left and no sshd.ready" {
    need_openssh
    local proj="$TMP/project" run_dir
    make_project "$proj"
    run_dir="$proj/.claude-dev/run"
    export_ep_env "$proj"
    stage_real_keys "$proj"
    write_sshd_wrap "$TMP/bin/sshd"
    export CLAUDE_ORCA_SSHD_BIN="$TMP/bin/sshd"

    boot_ep
    wait_for_file "$run_dir/sshd.ready" 30
    wait_for_line "$TMP/entrypoint.out" 'waiting on the sshd supervisor' 10
    pgrep -f -- "$RT/sshd_config" >/dev/null

    # the entrypoint ONLY, as docker stop sends it -- not its process group
    local t0 elapsed i
    t0="$(date +%s.%N)"
    kill -TERM "$(cat "$TMP/ep.pid")"
    for i in $(seq 1 100); do
        [ -s "$TMP/ep.rc" ] && break
        sleep 0.1
    done
    elapsed="$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.2f", b - a }')"
    echo "# TERM to exit: ${elapsed}s" >&3
    [ -s "$TMP/ep.rc" ]
    [ "$(cat "$TMP/ep.rc")" = "143" ]
    awk -v e="$elapsed" 'BEGIN { exit !(e < 5) }'
    run ! pgrep -f -- "$RT/sshd_config"
    [ ! -e "$run_dir/sshd.ready" ]
}

# Guards:   docker stop during a slow provisioning step: PID 1 leaves with 143 in under 5 s (docker SIGKILLs at 10 s) and the step, its child and the runner's tee are all gone -- nothing of the boot outlives PID 1 -- while sshd was started and run/port written BEFORE the step began
# Fails if: provisioning runs in the foreground again (the TERM trap waits out the 60 s step, measured at 18.9 s before the fix), stop_provision signals only the runner so the step's sleep or tee survives, a later step starts after the TERM, or run/port is only written after provisioning
# Run:      bats -f 'TERM during a slow provisioning step' tests/container-entrypoint-sshd.bats
@test "TERM during a slow provisioning step exits 143 in under 5 s and leaves none of the step's processes" {
    local proj="$TMP/project" run_dir steps="$TMP/steps" t0 elapsed i p
    make_project "$proj"
    run_dir="$proj/.claude-dev/run"
    export_ep_env "$proj"
    export CLAUDE_ORCA_SKIP_PROVISION=0 CLAUDE_ORCA_PROVISION_STEPS="$steps"
    export CLAUDE_ORCA_PROVISION_TIMEOUT=120

    # step 1 announces itself, then sleeps in a CHILD (a curl would be one);
    # step 2 must never start once PID 1 has been told to stop
    mkdir -p "$steps"
    printf '#!/bin/bash\necho $$ > "%s/step.pid"\nsleep 60 &\necho $! > "%s/sleep.pid"\nwait\n' \
        "$TMP" "$TMP" > "$steps/10-slow"
    printf '#!/bin/bash\ntouch "%s/after.marker"\n' "$TMP" > "$steps/20-after"
    chmod +x "$steps/10-slow" "$steps/20-after"

    boot_ep
    wait_for_file "$TMP/sleep.pid" 30
    # the ordering contract: the port is already published, sshd already started
    [ -s "$run_dir/port" ]
    grep -qF 'sshd supervisor started' "$TMP/entrypoint.out"
    ! grep -qF 'waiting on the sshd supervisor' "$TMP/entrypoint.out"
    pgrep -f -- "$TMP/steps/10-slow" >/dev/null

    t0="$(date +%s.%N)"
    kill -TERM "$(cat "$TMP/ep.pid")"
    for i in $(seq 1 100); do
        [ -s "$TMP/ep.rc" ] && break
        sleep 0.1
    done
    elapsed="$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.2f", b - a }')"
    echo "# TERM during provisioning to exit: ${elapsed}s" >&3
    [ -s "$TMP/ep.rc" ]
    [ "$(cat "$TMP/ep.rc")" = "143" ]
    awk -v e="$elapsed" 'BEGIN { exit !(e < 5) }'

    # nothing of the boot is left: the step, its sleep, the tee (its command
    # line names the fixture), and -- by after.marker below -- the runner
    for p in "$(cat "$TMP/step.pid")" "$(cat "$TMP/sleep.pid")"; do
        run ! kill -0 "$p"
    done
    run ! pgrep -f -- "$TMP"
    [ ! -e "$TMP/after.marker" ]
}
