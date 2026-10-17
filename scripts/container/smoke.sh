#!/usr/bin/env bash
#
# smoke.sh -- proves a freshly built claude_orca image actually works, from
# inside it (v3 S1, claude-orca-qa2.1). CI runs this as the container's
# command on the linux/amd64 image it just built, before anything is
# pushed:
#
#   <runtime> run --rm -e CLAUDE_ORCA_SMOKE=1 <image> \
#       /opt/claude-orca/scripts/container/smoke.sh
#
# startup v4 (claude-orca-qa2.10) gives it a second job: the same script,
# run on the PUBLIC base image with this checkout mounted, is the only
# proof of the runtime-install path a folder takes when it cannot pull the
# prebuilt image --
#
#   docker run --rm -v "$PWD:/opt/claude-orca-mount" -e CLAUDE_ORCA_SMOKE=1 \
#       docker.io/library/ubuntu:24.04 \
#       bash /opt/claude-orca-mount/scripts/container/smoke.sh
#
# (both invocations are run by hand -- there is no CI in this repo)
#
# So nothing here may assume /opt/claude-orca exists or that the toolchain
# is installed yet: it creates its own throwaway git project, puts the
# checkout it was run from at <project>/.claude-dev/template (which is
# exactly where the entrypoint looks when /opt/claude-orca is absent), lays
# throwaway ssh keys out the way the Mac side does (<project>/.claude-dev/
# state/ssh), runs the real entrypoint against it -- setup.sh and all -- and
# only then asserts that the pinned toolchain is on PATH and that the
# container's sshd comes up and answers a real ssh login. There is no Orca
# in the image any more: the container's way in is sshd, so that is what
# "the image works" means. Any failure prints the sshd log and exits
# non-zero, so a broken image is never trusted.
#
# bash 3.2 clean (scripts/lint-bash32.sh scans all of scripts/).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ENTRYPOINT="$SCRIPT_DIR/entrypoint.sh"
SETUP="$SCRIPT_DIR/setup.sh"
# The root of the copy this script was read from -- /opt/claude-orca on the
# prebuilt image, the mount on a base image.
TEMPLATE_SRC="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

PREBUILT=0
if [ -d /opt/claude-orca ]; then
    PREBUILT=1
fi

PROJECT_DIR="${CLAUDE_ORCA_SMOKE_PROJECT:-/tmp/claude-orca-smoke}"
SSHD_PORT="${CLAUDE_ORCA_SSHD_PORT:-2222}"
AGENT_USER="${CLAUDE_ORCA_AGENT_USER:-agent}"
# On the prebuilt image the entrypoint's setup is a no-op and sshd answers in
# seconds; on a base image the same wait covers a whole toolchain install.
if [ "$PREBUILT" = "1" ]; then
    TIMEOUT="${CLAUDE_ORCA_SMOKE_TIMEOUT:-120}"
else
    TIMEOUT="${CLAUDE_ORCA_SMOKE_TIMEOUT:-1800}"
fi

RUN_DIR="$PROJECT_DIR/.claude-dev/run"
SSH_STATE="$PROJECT_DIR/.claude-dev/state/ssh"
READY_FILE="$RUN_DIR/sshd.ready"
SSHD_LOG="$RUN_DIR/sshd.log"
# The client side of the throwaway keys lives outside the project, so
# nothing the Mac side owns is ever confused with it. Removed on exit.
CLIENT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cdev-smoke-ssh.XXXXXX")"
trap 'rm -rf "$CLIENT_DIR"' EXIT

failures=0
pass() { printf 'ok   -- %s\n' "$*"; }
fail() { printf 'FAIL -- %s\n' "$*" >&2; failures=$((failures + 1)); }

dump_and_exit() {
    printf '\n--- sshd.log (tail) ---\n' >&2
    tail -60 "$SSHD_LOG" >&2 2>/dev/null || echo "(no sshd log)" >&2
    exit 1
}

# --- the toolchain the image promises -----------------------------------

check_version() {
    label="$1"; shift
    if ! out="$("$@" 2>&1)"; then
        fail "$label: '$*' exited non-zero: $(printf '%s' "$out" | head -2)"
        return 1
    fi
    if [ -z "$out" ]; then
        fail "$label: '$*' printed nothing"
        return 1
    fi
    pass "$label: $(printf '%s' "$out" | head -1)"
}

# The toolchain checks themselves run AFTER the entrypoint, because on a
# base image nothing is installed until setup.sh has run inside it.

# --- enough of a system to build the fixture ----------------------------
#
# git is what makes the throwaway project a repo, and ssh-keygen/ssh are what
# make its keys and prove the login; the base image has none of them.
# setup.sh's base phase installs them (git, openssh-server and its client,
# and zsh, which the user phase's useradd needs), so run those two phases
# here rather than inventing a second install path. On the prebuilt image
# they are already there and this is skipped.

if ! command -v git >/dev/null 2>&1; then
    printf 'no git yet: running setup.sh --phase base and --phase user first\n'
    if [ ! -x "$SETUP" ]; then
        fail "no setup script at $SETUP"
        exit 1
    fi
    "$SETUP" --phase base || { fail "setup.sh --phase base failed"; exit 1; }
    "$SETUP" --phase user || { fail "setup.sh --phase user failed"; exit 1; }
fi

# --- a throwaway project ------------------------------------------------

rm -rf "$PROJECT_DIR"
mkdir -p "$RUN_DIR" "$PROJECT_DIR/.claude-dev/home"

# Where the entrypoint looks for the template when /opt/claude-orca is not
# there (claude-orca-qa2.9): the folder's own clone, inside the project.
# `container run` bind-mounts that for real; here a symlink to the checkout
# this script came from does the same job.
if [ "$PREBUILT" != "1" ]; then
    ln -sfn "$TEMPLATE_SRC" "$PROJECT_DIR/.claude-dev/template"
    printf 'template for this run: %s -> %s\n' \
        "$PROJECT_DIR/.claude-dev/template" "$TEMPLATE_SRC"
fi

git init --quiet -b main "$PROJECT_DIR" >/dev/null 2>&1
git -C "$PROJECT_DIR" -c user.email=smoke@example.com -c user.name=smoke \
    commit --quiet --allow-empty -m smoke >/dev/null 2>&1

# --- throwaway ssh keys, laid out the way the Mac side lays them out ----
#
# state/ssh/host_ed25519(.pub) is the container's host key and
# state/ssh/authorized_keys the one client key allowed in; the entrypoint
# starts no sshd until all three exist. The client key stays in CLIENT_DIR.
# Made before the chown below so the agent user owns what sshd reads.

if ! command -v ssh-keygen >/dev/null 2>&1; then
    fail "no ssh-keygen on PATH (openssh-client is part of the base phase)"
    exit 1
fi
mkdir -p "$SSH_STATE"
chmod 700 "$SSH_STATE"
ssh-keygen -q -t ed25519 -N '' -C smoke-host -f "$SSH_STATE/host_ed25519" \
    || { fail "ssh-keygen could not make a host key"; exit 1; }
ssh-keygen -q -t ed25519 -N '' -C smoke-client -f "$CLIENT_DIR/client_key" \
    || { fail "ssh-keygen could not make a client key"; exit 1; }
cp "$CLIENT_DIR/client_key.pub" "$SSH_STATE/authorized_keys"
chmod 600 "$SSH_STATE/authorized_keys"

if id "$AGENT_USER" >/dev/null 2>&1; then
    chown -R "$AGENT_USER:$AGENT_USER" "$PROJECT_DIR" 2>/dev/null || true
fi

# --- run the real entrypoint --------------------------------------------

printf 'starting the entrypoint against %s, sshd on port %s\n' "$PROJECT_DIR" "$SSHD_PORT"
PROJECT_DIR="$PROJECT_DIR" CLAUDE_ORCA_SSHD_PORT="$SSHD_PORT" \
    bash "$ENTRYPOINT" &
EP_PID=$!

# sshd.ready exists only while sshd answers (the entrypoint removes it first
# on every boot), so its appearance is the signal; the entrypoint dying
# first is the failure.
waited=0
while [ "$waited" -lt "$TIMEOUT" ]; do
    [ -e "$READY_FILE" ] && break
    if ! kill -0 "$EP_PID" 2>/dev/null; then
        fail "the entrypoint exited before writing $READY_FILE"
        dump_and_exit
    fi
    sleep 1
    waited=$((waited + 1))
done

if [ ! -e "$READY_FILE" ]; then
    fail "no $READY_FILE after ${TIMEOUT} s"
    kill -TERM "$EP_PID" 2>/dev/null
    dump_and_exit
fi
pass "sshd.ready written after ${waited} s"

# --- the toolchain the image promises -----------------------------------
#
# Installed by the Dockerfile on the prebuilt image and by the entrypoint's
# own setup.sh run on a base image -- either way it has to be here by the
# time sshd is answering.

check_version "claude" claude --version
check_version "bd" bd --version

sshd_bin="${CLAUDE_ORCA_SSHD_BIN:-$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)}"
if [ -x "$sshd_bin" ]; then
    pass "sshd binary: $sshd_bin"
else
    fail "no executable sshd at $sshd_bin"
fi

# The image carries no Orca now; a leftover payload would mean a stale layer
# or a phase that crept back in.
if [ -e /opt/orca ]; then
    fail "/opt/orca exists -- the image should not carry Orca"
else
    pass "no Orca payload in the image"
fi

# --- a real ssh login ---------------------------------------------------
#
# The entrypoint runs sshd as the agent user when it can drop privileges
# (root here), as whoever runs this otherwise -- AllowUsers names the same
# one, so log in as that user. The host key is pinned from the .pub we made,
# so the login also proves sshd is using the key staged in state/ssh. The
# command goes through pane-entry (sshd's ForceCommand) into the agent's
# shell, so an answer means the whole way in works, not just the port.

if [ "$(id -u)" = "0" ] && id "$AGENT_USER" >/dev/null 2>&1; then
    login_user="$AGENT_USER"
else
    login_user="$(id -un)"
fi
printf '[127.0.0.1]:%s %s\n' "$SSHD_PORT" \
    "$(cut -d' ' -f1,2 "$SSH_STATE/host_ed25519.pub")" > "$CLIENT_DIR/known_hosts"

smoke_ssh() {
    ssh -F /dev/null -p "$SSHD_PORT" -i "$1" -o IdentitiesOnly=yes \
        -o BatchMode=yes -o ConnectTimeout=10 \
        -o UserKnownHostsFile="$CLIENT_DIR/known_hosts" \
        -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes \
        "$login_user@127.0.0.1" "$2" 2>&1
}

if ! command -v ssh >/dev/null 2>&1; then
    fail "no ssh client on PATH"
else
    out="$(smoke_ssh "$CLIENT_DIR/client_key" 'echo smoke-ssh-ok')"
    case "$out" in
        *smoke-ssh-ok*) pass "ssh login as $login_user answered through the pane shell" ;;
        *) fail "ssh login as $login_user did not answer: $(printf '%s' "$out" | head -3)" ;;
    esac

    # A key that is not in authorized_keys must be refused.
    ssh-keygen -q -t ed25519 -N '' -C smoke-stranger -f "$CLIENT_DIR/stranger_key"
    out="$(smoke_ssh "$CLIENT_DIR/stranger_key" 'echo smoke-ssh-ok')"
    case "$out" in
        *smoke-ssh-ok*) fail "ssh accepted a key that is not in authorized_keys" ;;
        *) pass "ssh refuses a key that is not in authorized_keys" ;;
    esac
fi

kill -TERM "$EP_PID" 2>/dev/null
wait "$EP_PID" 2>/dev/null

if [ "$failures" -ne 0 ]; then
    printf '\n%s check(s) failed\n' "$failures" >&2
    dump_and_exit
fi
printf '\nsmoke: all checks passed\n'
exit 0
