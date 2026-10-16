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
    grep -qxF '  ControlPath ~/.local/state/claude-dev/cm-%C' "$cfg"
    [ -d "$HOME/.local/state/claude-dev" ]
    [ "$(file_mode "$HOME/.local/state/claude-dev")" = "700" ]
    # The marker the remote-forward slice (B4) edits at.
    grep -qxF '  # B4: RemoteForward goes here' "$cfg"

    [ ! -e "$HOME/.ssh" ]
}
