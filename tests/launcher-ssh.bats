#!/usr/bin/env bats
#
# Guards:   the launcher gives every folder its own ssh identity (client and
#           host keys, authorized_keys, known_hosts, config) under
#           .claude-dev/state/ssh, never touches ~/.ssh, and starts the
#           container with sshd on the folder's port.
# Fails if: the keys are re-made on every open (the host fingerprint would
#           change), authorized_keys loses its `restrict` prefix, the config
#           stops quoting a folder path with a space in it, the docker run
#           argv loses CLAUDE_ORCA_SSHD_PORT, or a container made before the
#           ssh panes is kept instead of recreated.
# Run:      bats tests/launcher-ssh.bats
#
# Claude Code in a pane is `ssh -F <state/ssh/config> claude-dev-<name>`
# (claude-orca-9bh.7). `docker` is the stub from tests/helpers/setup.bash; it
# stands in for the container's sshd by writing run/sshd.ready, and the keys
# are made by a real OpenSSH ssh-keygen (the stub in $STUB_BIN).

load helpers/setup

# The one line the `docker` stub logged for the invocation whose argv
# starts with $1 (its log is one line per invocation, argv joined).
ctr_line() {
    grep "^$1" "$CONTAINER_STUB_LOG" | head -1
}

# A bootstrapped, opened folder at $1 (the bootstrap runs the first open).
# Sets $primary, $sd (its state/ssh) and $port.
open_folder() {
    mkdir -p "$1"
    primary="$(abspath "$1")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    sd="$primary/.claude-dev/state/ssh"
    port="$(cat "$primary/.claude-dev/run/port")"
}

# wait_for_sshd_ready (and the helpers it calls) out of the launcher, run in
# a subshell: the launcher's own copy with its command dispatch cut off, put
# beside it so its paths resolve. $1 is the folder, the rest are the args.
run_wait_for_sshd_ready() {
    local dir="$1" lib
    shift
    lib="$dir/.claude-dev/template/scripts/launcher-lib-test.sh"
    sed '/^case "${1:-}" in$/,$d' "$dir/.claude-dev/template/scripts/launcher.sh" > "$lib"
    bash -c 'set -euo pipefail; source "$1"; shift; wait_for_sshd_ready "$@"' _ "$lib" "$dir" "$@"
}

# bats test_tags=size:medium
@test "open makes the client and host keys once and keeps them on the next open" {
    open_folder "$PROJECT_DIR"
    [ -s "$sd/client_ed25519" ]
    [ -s "$sd/client_ed25519.pub" ]
    [ -s "$sd/host_ed25519" ]
    [ -s "$sd/host_ed25519.pub" ]
    [ "$(file_mode "$sd")" = "700" ]
    [ "$(file_mode "$sd/client_ed25519")" = "600" ]
    [ "$(file_mode "$sd/host_ed25519")" = "600" ]

    before="$(cksum "$sd/client_ed25519" "$sd/host_ed25519")"
    touch "$BATS_TEST_TMPDIR/marker"
    sleep 1
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    # Same bytes and not rewritten at all: the host fingerprint a pane
    # trusts must outlive every open.
    [ "$(cksum "$sd/client_ed25519" "$sd/host_ed25519")" = "$before" ]
    [ ! "$sd/client_ed25519" -nt "$BATS_TEST_TMPDIR/marker" ]
    [ ! "$sd/host_ed25519" -nt "$BATS_TEST_TMPDIR/marker" ]
}

@test "open writes authorized_keys as the restricted client key and known_hosts keyed by the alias" {
    open_folder "$PROJECT_DIR"
    name="$(basename "$primary")"

    [ "$(wc -l < "$sd/authorized_keys" | tr -d ' ')" = "1" ]
    read -r type blob rest < "$sd/client_ed25519.pub"
    [ "$type" = "ssh-ed25519" ]
    [ "$(cat "$sd/authorized_keys")" = "restrict,pty,port-forwarding $type $blob $rest" ]

    read -r htype hblob hrest < "$sd/host_ed25519.pub"
    [ "$(wc -l < "$sd/known_hosts" | tr -d ' ')" = "1" ]
    [ "$(cat "$sd/known_hosts")" = "claude-dev-$name $htype $hblob" ]
}

@test "open writes state/ssh/config with quoted paths, a short ControlPath under the home, and nothing under ~/.ssh" {
    open_folder "$BATS_TEST_TMPDIR/My Project"
    cfg="$sd/config"
    [ "$(basename "$primary")" = "My Project" ]

    grep -qx 'Host claude-dev-my-project' "$cfg"
    grep -qx '  HostName 127.0.0.1' "$cfg"
    grep -qx "  Port $port" "$cfg"
    grep -qx '  User agent' "$cfg"
    # A folder with a space in its name: every path is quoted.
    grep -qxF "  IdentityFile \"$sd/client_ed25519\"" "$cfg"
    grep -qxF "  UserKnownHostsFile \"$sd/known_hosts\"" "$cfg"
    grep -qx '  StrictHostKeyChecking yes' "$cfg"
    grep -qx '  HostKeyAlias claude-dev-my-project' "$cfg"
    # The socket lives under the Mac user's home, not the long folder path.
    grep -qxF "  ControlPath \"$HOME/.local/state/claude-dev/cm-%C\"" "$cfg"
    [ -d "$HOME/.local/state/claude-dev" ]
    [ "$(file_mode "$HOME/.local/state/claude-dev")" = "700" ]
    # The clipboard bridge's forward (claude-orca-9bh.9): the container's
    # fixed socket back to the Mac listener under the home, no
    # ExitOnForwardFailure.
    grep -qxF "  RemoteForward /tmp/cdev-clip.sock \"$HOME/.local/state/claude-dev/clip-my-project.sock\"" "$cfg"
    ! grep -q ExitOnForwardFailure "$cfg"

    [ ! -e "$HOME/.ssh" ]
}

# Guards:   the ssh config names the control-socket directory the launcher made as a literal path (a % doubled), never `~`, which ssh resolves through the passwd entry instead of $HOME
# Fails if: ssh_write_config goes back to `ControlPath ~/...` (the master then cannot bind when HOME is not the passwd home), or a % in HOME is left single (ssh would read it as an escape)
# Run:      bats -f 'literal path' tests/launcher-ssh.bats
@test "the ControlPath is the literal path of the directory made, not a ~ that ssh resolves through passwd" {
    export HOME="$BATS_TEST_TMPDIR/odd 100%home"
    mkdir -p "$HOME"
    open_folder "$PROJECT_DIR"

    grep -qxF "  ControlPath \"$BATS_TEST_TMPDIR/odd 100%%home/.local/state/claude-dev/cm-%C\"" "$sd/config"
    ! grep -q 'ControlPath ~' "$sd/config"
    [ -d "$HOME/.local/state/claude-dev" ]
}

@test "docker run publishes sshd on the folder's port and passes no second (Orca) port" {
    open_folder "$PROJECT_DIR"

    line="$(ctr_line "run ")"
    [ -n "$line" ]
    [[ "$line" == *"-e CLAUDE_ORCA_SSHD_PORT=$port "* ]]
    [[ "$line" != *"ORCA_PORT="* ]]
    # One published port, on loopback only, and it is sshd's.
    [ "$(printf '%s\n' "$line" | grep -o ' -p [^ ]*' | wc -l | tr -d ' ')" = "1" ]
    [[ "$line" == *" -p 127.0.0.1:$port:$port"* ]]
}

@test "open recreates a running container that has no sshd on its port" {
    open_folder "$PROJECT_DIR"
    name="claude-orca-$(basename "$primary")"
    image="$(cat "$CONTAINER_STUB_STATE/image")"

    rm -f "$CONTAINER_STUB_STATE/preset-applied"
    export DOCKER_STUB_PRESET_CONTAINER="$name:$image:$primary:$port"
    export DOCKER_STUB_PRESET_NO_SSHD=1
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"has no sshd on port $port"* ]]
    [[ "$output" != *"already running"* ]]

    # Stopped, removed, then run again -- in that order.
    stop_at="$(grep -n "^stop " "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)"
    rm_at="$(grep -n "^rm " "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)"
    run_at="$(grep -n "^run .*--name $name" "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)"
    [ -n "$stop_at" ]
    [ -n "$rm_at" ]
    [ -n "$run_at" ]
    [ "$stop_at" -lt "$rm_at" ]
    [ "$rm_at" -lt "$run_at" ]
}

@test "open removes a stale run/sshd.ready before it starts a stopped container" {
    open_folder "$PROJECT_DIR"
    name="claude-orca-$(basename "$primary")"
    ready="$primary/.claude-dev/run/sshd.ready"

    echo exited > "$CONTAINER_STUB_STATE/containers/$name"
    printf 'port=%s\nhost_key_sha256=SHA256:stale\n' "$port" > "$ready"
    [ -s "$ready" ]

    # No new sshd.ready ever appears (CLAUDE_ORCA_TEST_NO_SSHD), so open
    # times out waiting -- and only the launcher's rm can explain the stale
    # file's absence afterwards.
    : > "$CONTAINER_STUB_LOG"
    CLAUDE_ORCA_TEST_NO_SSHD=1 CLAUDE_ORCA_WEBURL_TIMEOUT=2 run bash -c "cd '$primary' && ./claude-dev open 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Starting $name"* ]]
    [[ "$output" == *"sshd did not come up within 2s"* ]]
    grep -q "^start $name" "$CONTAINER_STUB_LOG"
    [ ! -e "$ready" ]

    # With the stub's restarted entrypoint writing its own file, open
    # succeeds and the file it waited for is the new one, not the stale one.
    echo exited > "$CONTAINER_STUB_STATE/containers/$name"
    printf 'port=%s\nhost_key_sha256=SHA256:stale\n' "$port" > "$ready"
    run bash -c "cd '$primary' && ./claude-dev open 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sshd is up"* ]]
    [ -s "$ready" ]
    ! grep -q 'SHA256:stale' "$ready"
}

@test "wait_for_sshd_ready returns 0 and prints nothing when the ready file carries this folder's host key" {
    open_folder "$PROJECT_DIR"
    [ -s "$primary/.claude-dev/run/sshd.ready" ]

    run run_wait_for_sshd_ready "$primary"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "wait_for_sshd_ready returns 1 when sshd never comes up within the timeout" {
    open_folder "$PROJECT_DIR"
    rm -f "$primary/.claude-dev/run/sshd.ready"

    CLAUDE_ORCA_WEBURL_TIMEOUT=2 run run_wait_for_sshd_ready "$primary"
    [ "$status" -eq 1 ]
}

@test "wait_for_sshd_ready returns 3 and names both fingerprints when sshd has another host key" {
    open_folder "$PROJECT_DIR"
    printf 'port=%s\nhost_key_sha256=SHA256:bogus\n' "$port" > "$primary/.claude-dev/run/sshd.ready"
    want="$("${CLAUDE_ORCA_SSH_KEYGEN:-ssh-keygen}" -lf "$sd/host_ed25519.pub" | awk 'NR == 1 { print $2 }')"
    [[ "$want" == SHA256:* ]]

    # stdout and stderr apart: the fingerprints belong on stderr only.
    run_wait_for_sshd_ready "$primary" > "$BATS_TEST_TMPDIR/out" 2> "$BATS_TEST_TMPDIR/err" && rc=0 || rc=$?
    [ "$rc" -eq 3 ]
    [ ! -s "$BATS_TEST_TMPDIR/out" ]
    grep -qF "SHA256:bogus" "$BATS_TEST_TMPDIR/err"
    grep -qF "$want" "$BATS_TEST_TMPDIR/err"
}

@test "wait_for_sshd_ready returns 2 when the named container has exited" {
    open_folder "$PROJECT_DIR"
    name="claude-orca-$(basename "$primary")"
    rm -f "$primary/.claude-dev/run/sshd.ready"
    echo exited > "$CONTAINER_STUB_STATE/containers/$name"

    CLAUDE_ORCA_WEBURL_TIMEOUT=5 run run_wait_for_sshd_ready "$primary" "$name"
    [ "$status" -eq 2 ]
}

@test "the generated ssh config parses with the real ssh and names the folder's port and alias" {
    ossh="$ORIGINAL_HOME/.cache/claude-orca-test/openssh"
    if [ ! -x "$ossh/usr/bin/ssh" ]; then
        skip "no extracted OpenSSH at $ossh"
    fi
    open_folder "$PROJECT_DIR"
    name="$(basename "$primary")"

    run env LD_LIBRARY_PATH="$ossh/usr/lib/aarch64-linux-gnu" \
        "$ossh/usr/bin/ssh" -F "$sd/config" -G "claude-dev-$name"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nhostname 127.0.0.1\n'* ]]
    [[ "$output" == *$'\nport '"$port"$'\n'* ]]
    [[ "$output" == *$'\nhostkeyalias claude-dev-'* ]]
    [[ "$output" == *$'\nuser agent\n'* ]]
}
