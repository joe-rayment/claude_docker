#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Guards:   the container's sshd library (scripts/container/sshd-lib.sh): the config text it writes, the env snapshot ssh panes source, the Mac-path symlink, the host-key fingerprint, and a real sshd kept alive by the restart loop
# Fails if: a directive drops out of the config, a snapshot value with quotes/newlines comes back different or an OpenRouter key leaks into it, the host link follows a relative / .. / system path, the fingerprint differs from ssh-keygen's, or the loop does not restart a killed sshd or leaves one behind on TERM
# Run:      bats tests/container-sshd.bats
#
# The last group runs the real OpenSSH 9.6 server and client extracted without
# root into ~/.cache/claude-orca-test/openssh and SKIPS when that is absent.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$REPO_ROOT/scripts/container/sshd-lib.sh"
BASH_BIN="$(command -v bash)"
# Captured before setup() points HOME at a fixture.
OPENSSH_DIR="$HOME/.cache/claude-orca-test/openssh"
OPENSSH_LIB="$OPENSSH_DIR/usr/lib/aarch64-linux-gnu"
SSHD="$OPENSSH_DIR/usr/sbin/sshd"
SSH="$OPENSSH_DIR/usr/bin/ssh"
SSH_KEYGEN="$OPENSSH_DIR/usr/bin/ssh-keygen"

setup() {
  export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  export CLAUDE_ORCA_ROOT="$BATS_TEST_TMPDIR/root"
  export HOME="$BATS_TEST_TMPDIR/home"
  export CLAUDE_ORCA_HOST_LINK_ROOT="$BATS_TEST_TMPDIR/linkroot"
  mkdir -p "$PROJECT_DIR" "$HOME" "$CLAUDE_ORCA_HOST_LINK_ROOT"
}

# Run a library function in a fresh bash.
lib() { run "$BASH_BIN" -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"; }

@test "sshd_config carries every directive and quotes paths with spaces" {
  lib cdev_sshd_config "/tmp/my run" "/tmp/my proj" 2222 agent "/opt/with space/pane-entry"
  [ "$status" -eq 0 ]
  for want in 'Port 2222' 'ListenAddress 0.0.0.0' \
      'HostKey "/tmp/my run/ssh/host_ed25519"' 'PidFile "/tmp/my run/sshd.pid"' \
      'AuthorizedKeysFile "/tmp/my proj/.claude-dev/state/ssh/authorized_keys"' \
      'PubkeyAuthentication yes' 'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' 'UsePAM no' 'StrictModes no' \
      'AllowUsers agent' 'PermitRootLogin no' 'AllowTcpForwarding no' \
      'X11Forwarding no' 'AllowAgentForwarding no' 'PermitTunnel no' \
      'AllowStreamLocalForwarding remote' 'StreamLocalBindUnlink yes' \
      'PermitUserEnvironment no' 'PrintMotd no' \
      'AcceptEnv TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM CDEV_CWD LANG LC_*' \
      "ForceCommand '/opt/with space/pane-entry'" 'LogLevel INFO'; do
    printf '%s\n' "$output" | grep -Fxq -- "$want" || { echo "missing: $want"; false; }
  done
  ! printf '%s\n' "$output" | grep -q '^Subsystem'
}

@test "sshd_config leaves plain paths bare and escapes a quote in ForceCommand" {
  lib cdev_sshd_config /run/cdev /workspace/p 22 bob "/x/it's/pane-entry"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fxq 'HostKey /run/cdev/ssh/host_ed25519'
  printf '%s\n' "$output" | grep -Fxq "ForceCommand '/x/it'\\''s/pane-entry'"
}

# Produce a snapshot from a controlled environment, source it in an empty one.
snapshot_env() {
  env -i PATH=/usr/bin:/bin HOME=/root AGENT_HOME=/home/zed LANG=C.UTF-8 \
    PROJECT_DIR=/workspace/p DISPLAY=:7 GH_TOKEN=ghp_fixture \
    OPENROUTER_BASE_URL=http://127.0.0.1:1/v1 \
    TERM=xterm SSH_CONNECTION=1 TERM_PROGRAM=ghostty COLORTERM=truecolor \
    CDEV_CWD=sub USER=u LOGNAME=u SHELL=/bin/sh MAIL=/m \
    WEIRD="it's \"quoted\" \$HOME \`id\`
second line" \
    SECRET_KEY="sk-or-v1-TESTFIXTURE-not-a-key" \
    "$BASH_BIN" -c 'source "$1"; cdev_env_snapshot "$2"' _ "$LIB" "$1"
}

@test "env snapshot round-trips awkward values and is mode 600" {
  out="$BATS_TEST_TMPDIR/env"
  run --separate-stderr snapshot_env "$out"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$out")" = 600 ]
  env -i "$BASH_BIN" -c 'source "$1"; printf "%s" "$WEIRD" >"$2"' _ "$out" "$BATS_TEST_TMPDIR/got"
  printf '%s' "it's \"quoted\" \$HOME \`id\`
second line" >"$BATS_TEST_TMPDIR/want"
  cmp "$BATS_TEST_TMPDIR/got" "$BATS_TEST_TMPDIR/want"
  got=$(env -i "$BASH_BIN" -c 'source "$1"; printf "%s|%s|%s|%s|%s" "$HOME" "$PROJECT_DIR" "$DISPLAY" "$GH_TOKEN" "$LANG"' _ "$out")
  [ "$got" = "/home/zed|/workspace/p|:7|ghp_fixture|C.UTF-8" ]
  grep -q '^export OPENROUTER_BASE_URL=' "$out"
}

@test "env snapshot drops an OpenRouter key and logs only the name; skips noise" {
  out="$BATS_TEST_TMPDIR/env"
  run --separate-stderr snapshot_env "$out"
  [ "$status" -eq 0 ]
  ! grep -q 'sk-or-v1-' "$out"
  ! grep -q '^export SECRET_KEY=' "$out"
  [[ $stderr == *SECRET_KEY* ]]
  [[ $stderr != *TESTFIXTURE* ]]
  for noise in TERM SHLVL PWD OLDPWD _ SSH_CONNECTION TERM_PROGRAM COLORTERM CDEV_CWD USER LOGNAME SHELL MAIL; do
    ! grep -q "^export $noise=" "$out" || { echo "noise kept: $noise"; false; }
  done
}

@test "host link creates the link under the root with 755 parents" {
  [[ $CLAUDE_ORCA_HOST_LINK_ROOT == "$BATS_TEST_TMPDIR"/* ]]
  lib cdev_host_link "/Users/joe/My Proj/" "$PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ "$(readlink "$CLAUDE_ORCA_HOST_LINK_ROOT/Users/joe/My Proj")" = "$PROJECT_DIR" ]
  [ "$(stat -c %a "$CLAUDE_ORCA_HOST_LINK_ROOT/Users/joe")" = 755 ]
}

@test "host link refuses relative, .., root and system paths and creates nothing" {
  for bad in "Users/joe/p" "/Users/../etc/x" "/" "/etc/p" "/workspace/p" \
      "/home/agent/p" "/usr" "/root/p" "/proc/x" "/var/lib/x"; do
    lib cdev_host_link "$bad" "$PROJECT_DIR"
    [ "$status" -eq 0 ] || { echo "nonzero for $bad"; false; }
    [[ $output == *refusing* ]] || { echo "no refusal for $bad: $output"; false; }
  done
  [ -z "$(ls -A "$CLAUDE_ORCA_HOST_LINK_ROOT")" ]
}

@test "host link leaves an existing real path alone, accepts an identical link" {
  mkdir -p "$CLAUDE_ORCA_HOST_LINK_ROOT/Users/joe/real"
  lib cdev_host_link /Users/joe/real "$PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ $output == *"not a symlink"* ]]
  [ -d "$CLAUDE_ORCA_HOST_LINK_ROOT/Users/joe/real" ] && [ ! -L "$CLAUDE_ORCA_HOST_LINK_ROOT/Users/joe/real" ]
  lib cdev_host_link /Users/joe/p "$PROJECT_DIR"
  lib cdev_host_link /Users/joe/p "$PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ $output == *"already"* ]]
  ln -s /elsewhere "$CLAUDE_ORCA_HOST_LINK_ROOT/Users/joe/other"
  lib cdev_host_link /Users/joe/other "$PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ "$(readlink "$CLAUDE_ORCA_HOST_LINK_ROOT/Users/joe/other")" = /elsewhere ]
}

@test "host key fingerprint equals ssh-keygen -lf" {
  [ -x "$SSH_KEYGEN" ] || skip "extracted OpenSSH absent"
  k="$BATS_TEST_TMPDIR/k"
  for t in ed25519 ecdsa; do
    LD_LIBRARY_PATH="$OPENSSH_LIB" "$SSH_KEYGEN" -q -t "$t" -N '' -f "$k.$t" -C fixture
    want=$(LD_LIBRARY_PATH="$OPENSSH_LIB" "$SSH_KEYGEN" -lf "$k.$t.pub" | awk '{print $2}')
    lib cdev_host_key_fpr "$k.$t.pub"
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ]
  done
  lib cdev_host_key_fpr "$BATS_TEST_TMPDIR/nope.pub"
  [ "$status" -ne 0 ]
}

# ---- the real sshd ---------------------------------------------------------

# Poll "$@" every 50 ms for up to $WAIT_TRIES tries.
wait_for() {
  local i
  for ((i = 0; i < ${WAIT_TRIES:-200}; i++)); do
    "$@" && return 0
    sleep 0.05
  done
  return 1
}
ready_gone() { [ ! -e "$D/ready" ]; }
ready_there() { [ -e "$D/ready" ]; }
loop_dead() { ! kill -0 "$LOOP" 2>/dev/null; }
no_sshd() { ! pgrep -f "$D/sshd_config" >/dev/null; }
sshd_child() { pgrep -P "$LOOP" -x sshd | head -n1; }
new_child() { c=$(sshd_child); [ -n "$c" ] && [ "$c" != "$OLD" ]; }

ssh_marker() {
  LD_LIBRARY_PATH="$OPENSSH_LIB" "$SSH" -T -F /dev/null -i "$D/client" \
    -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
    -o UserKnownHostsFile="$D/known_hosts" -o GlobalKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=yes -p "$PORT" 127.0.0.1 "$@"
}

teardown() {
  [ -n "${LOOP:-}" ] && kill "$LOOP" 2>/dev/null
  [ -n "${D:-}" ] && { pkill -f "$D/sshd_config" 2>/dev/null; rm -rf "$D"; }
  return 0
}

@test "real sshd: loop starts it, a killed sshd is restarted, TERM leaves nothing" {
  [ -x "$SSHD" ] && [ -x "$SSH" ] && [ -x "$SSH_KEYGEN" ] || skip "extracted OpenSSH absent"
  D="/tmp/cdev-t-$$"
  rm -rf "$D"
  mkdir -p "$D/rt/ssh" "$D/my proj/.claude-dev/state/ssh" "$D/my bin"
  export LD_LIBRARY_PATH="$OPENSSH_LIB"
  "$SSH_KEYGEN" -q -t ed25519 -N '' -f "$D/rt/ssh/host_ed25519" -C host
  "$SSH_KEYGEN" -q -t ed25519 -N '' -f "$D/client" -C client
  cp "$D/client.pub" "$D/my proj/.claude-dev/state/ssh/authorized_keys"
  printf '[127.0.0.1]:%s %s\n' "$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')" \
    "$(cut -d' ' -f1,2 "$D/rt/ssh/host_ed25519.pub")" >"$D/known_hosts"
  PORT=$(cut -d' ' -f1 "$D/known_hosts" | sed 's/.*://; s/\]//')
  printf '#!/bin/sh\necho "cdev-marker:${SSH_ORIGINAL_COMMAND:-none}"\n' >"$D/my bin/pane-entry"
  chmod +x "$D/my bin/pane-entry"

  # The config the entrypoint will write: paths with spaces in two directives.
  run "$BASH_BIN" -c 'source "$1"; shift; cdev_sshd_config "$@"' _ "$LIB" \
    "$D/rt" "$D/my proj" "$PORT" "$(id -un)" "$D/my bin/pane-entry"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$D/sshd_config"
  chmod 600 "$D/sshd_config"
  FPR=$("$BASH_BIN" -c 'source "$1"; cdev_host_key_fpr "$2"' _ "$LIB" "$D/rt/ssh/host_ed25519.pub")
  [[ $FPR == SHA256:* ]]
  "$SSHD" -t -f "$D/sshd_config"

  "$BASH_BIN" -c 'source "$1"; shift; cdev_sshd_loop "$@"' _ "$LIB" \
    "$SSHD" "$D/sshd_config" "$D/sshd.log" "$D/ready" "$PORT" "$FPR" \
    >/dev/null 2>&1 3>&- &
  LOOP=$!

  wait_for ready_there
  grep -Fxq "port=$PORT" "$D/ready"
  grep -Fxq "host_key_sha256=$FPR" "$D/ready"
  run ssh_marker
  [ "$status" -eq 0 ]
  [ "$output" = "cdev-marker:none" ]
  run ssh_marker "echo hi"
  [ "$output" = "cdev-marker:echo hi" ]

  # kill -9 the sshd: the ready file goes away, the loop brings it back.
  OLD=$(sshd_child)
  [ -n "$OLD" ]
  kill -9 "$OLD"
  wait_for ready_gone
  WAIT_TRIES=300 wait_for new_child
  wait_for ready_there
  run ssh_marker
  [ "$status" -eq 0 ]
  [ "$output" = "cdev-marker:none" ]

  # TERM the loop: no sshd, no ready file, loop gone.
  kill -TERM "$LOOP"
  wait_for loop_dead
  [ ! -e "$D/ready" ]
  wait_for no_sshd
  [ -z "$(sshd_child)" ]
  LOOP=
}
