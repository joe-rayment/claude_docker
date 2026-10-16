# Shared fixture for the container-entrypoint*.bats files: paths, short
# socket-safe tmp dirs, a throwaway project, and the background boot /
# TERM helpers. The entrypoint never exits by itself (PID 1 waits on the
# sshd supervisor), so every case boots it in the background and stops it.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/scripts/container/entrypoint.sh"
SMOKE="$REPO_ROOT/scripts/container/smoke.sh"
DOCKERFILE="$REPO_ROOT/Dockerfile"
# The install logic the Dockerfile used to carry inline. It lives here so
# it can be run for real (scripts/container/verify-rootfs.sh), and the
# version pins moved with it.
SETUP="$REPO_ROOT/scripts/container/setup.sh"

# Unix socket paths (sshd's runtime dir, ControlPaths) cap at ~108 bytes --
# $BATS_TEST_TMPDIR under a long TMPDIR blows straight past that. Every
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
# into (run/ for the port file and logs, home/ for the agent HOME).
make_project() {
    local dir="$1"
    mkdir -p "$dir/.claude-dev/run" "$dir/.claude-dev/home"
    git init --quiet -b main "$dir" >/dev/null 2>&1
    git -C "$dir" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m init >/dev/null 2>&1
}

# Starts the entrypoint in its own session so the whole tree (entrypoint +
# the sshd supervisor and the stub sshd it spawns) can be signalled as one
# process group, and records that group's pgid in $TMP/ep.pgid.
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

# Boots the entrypoint once and stops it. The arguments are VAR=value words
# for its environment (HOME and the sshd runtime dir are defaulted; later
# words win, and the provisioning skip is on unless a case says
# CLAUDE_ORCA_SKIP_PROVISION=0). It waits for the entrypoint's steady state
# -- the "waiting on the sshd supervisor" line, printed after setup, seeds,
# the early config sync, the sshd start, run/port and provisioning -- sends
# TERM as `docker stop` would, and leaves everything it printed in $output
# and its exit status in $ep_status (143 on a clean TERM). Use it where the
# old suite ran `run bash "$ENTRYPOINT"` and read what it printed.
run_entrypoint_once() {
    local i out="$TMP/once.out"
    rm -f "$TMP/once.rc" "$TMP/once.pid" "$out"
    : > "$out"
    RT="${RT:-$(mktemp -d /tmp/cdev-c1a-XXXXXX)}"
    export EP_ONCE_RC="$TMP/once.rc" EP_ONCE_PID="$TMP/once.pid"
    setsid bash -c '
        echo $$ > "$EP_PGID_FILE"
        env "$@" bash "$EP_SCRIPT" &
        echo $! > "$EP_ONCE_PID"
        wait $!
        echo $? > "$EP_ONCE_RC"' _ "CLAUDE_ORCA_RUNTIME_DIR=$RT" \
        "CLAUDE_ORCA_SKIP_PROVISION=1" "$@" >"$out" 2>&1 &
    for i in $(seq 1 600); do
        grep -qF 'waiting on the sshd supervisor' "$out" && break
        [ -s "$TMP/once.rc" ] && break
        sleep 0.1
    done
    [ -s "$TMP/once.pid" ] && kill -TERM "$(cat "$TMP/once.pid")" 2>/dev/null
    for i in $(seq 1 100); do
        [ -s "$TMP/once.rc" ] && break
        sleep 0.1
    done
    ep_status="$(cat "$TMP/once.rc" 2>/dev/null || echo none)"
    output="$(cat "$out")"
    stop_entrypoint
}

setup() {
    # A terminal inside this container inherits the live runtime's own
    # exports -- the guard's OPENROUTER_* pair, the opencode launch
    # config, and CLAUDE_ORCA_SETUP pointing at the folder this terminal
    # was spawned from. Every case here stages its own key state, CLI
    # and setup path; anything ambient that survives into the entrypoint
    # makes the same case pass here and fail on a clean box (and vice
    # versa). Strip the four that change behaviour; the rest are inert.
    unset OPENROUTER_API_KEY OPENROUTER_BASE_URL OPENCODE_CONFIG \
        CLAUDE_ORCA_SETUP
    TMP="$(short_tmpdir)"
    export TMP
    export EP_PGID_FILE="$TMP/ep.pgid"
    export EP_SCRIPT="$ENTRYPOINT"
    # sshd's runtime dir: short, and never /run/cdev.
    RT="$(mktemp -d /tmp/cdev-c1a-XXXXXX)"
    export RT
}

teardown() {
    stop_entrypoint
    [ -n "${RT:-}" ] && rm -rf "$RT"
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    return 0
}

# --- startup v4 (claude-orca-qa2.9) --------------------------------------
#
# The container installs and seeds itself: the entrypoint runs setup.sh at
# every start (before the privilege drop) and the folder's seeds run as
# provision.d steps. Without Orca there is no "die at ORCA_BIN" any more to
# stop the entrypoint early, so each case boots it to its steady state with
# run_entrypoint_once (above) and reads what it printed and left on disk.

# A stub setup.sh. Records every invocation's argv (and the uid it ran as)
# in $TMP/setup.argv, answers --check with a failure the FIRST time only --
# so the first-start notice prints once -- and prints a line on stdout that
# the entrypoint's tee must land in run/setup.log.
write_setup_stub() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<STUB
#!/usr/bin/env bash
printf 'argv:%s\n' "\$*" >> "$TMP/setup.argv"
if [ "\${1:-}" = "--check" ]; then
    if [ -e "$TMP/setup.checked" ]; then exit 0; fi
    : > "$TMP/setup.checked"
    exit 1
fi
printf 'uid:%s\n' "\$(id -u)" >> "$TMP/setup.argv"
echo "stub setup: installing everything"
exit \${CLAUDE_ORCA_STUB_SETUP_STATUS:-0}
STUB
    chmod +x "$path"
}


# Stages a hermetic folder template at <proj>/.claude-dev/template so a case
# that sets CLAUDE_ORCA_SKIP_PROVISION=0 runs ONLY the provision.d steps it
# names -- not the whole baked set under /opt/claude-orca (which exists on
# the image and on this box, and holds slow steps that wait on things the
# test does not have). It copies provision-run.sh, provision-lib.sh,
# seed-project.sh and the named steps (e.g. 30-claude-first-run
# 40-git-identity 50-seed-project) into the same layout the repo has, and
# adds an executable stub setup.sh: the entrypoint picks the folder's
# template exactly when that file is executable (entrypoint.sh, "where the
# template is"). Pair it with CLAUDE_ORCA_SKIP_SETUP=1 unless the case is
# about setup.sh itself. Needs $TMP (write_setup_stub records there).
stage_template_tree() {
    local proj="$1" step c
    shift
    c="$proj/.claude-dev/template/scripts/container"
    mkdir -p "$c/provision.d"
    cp "$REPO_ROOT/scripts/container/provision-run.sh" \
        "$REPO_ROOT/scripts/container/provision-lib.sh" \
        "$REPO_ROOT/scripts/container/seed-project.sh" "$c/"
    for step in "$@"; do
        cp "$REPO_ROOT/scripts/container/provision.d/$step" "$c/provision.d/$step"
        chmod +x "$c/provision.d/$step"
    done
    write_setup_stub "$c/setup.sh"
}
