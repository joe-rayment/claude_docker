#!/usr/bin/env bats
#
# The one end-to-end case in this repo: the REAL launcher starts the REAL
# entrypoint, which starts the REAL Orca, and the URL it publishes is
# fetched over HTTP and checked for Orca's own markup. No stubs are loaded
# here at all -- helpers/setup.bash is deliberately NOT sourced, because
# everything it puts on PATH (docker, open, gh, uname) is the opposite of
# what this case is for.
#
# Why it can run at all: a container cannot be started on this box. Its
# capability set is empty (CapEff 0000000000000000, no CAP_SYS_ADMIN in the
# bounding set), so mount and unshare fail even for root and docker, podman
# and a private dockerd all die the same way. CLAUDE_ORCA_RUNTIME=local is
# the launcher's second backend: it runs the same entrypoint, with the same
# environment contract, as an ordinary host process. Everything above the
# runtime boundary -- the launcher's argv, the entrypoint, config-sync, the
# Orca seed, serve, the pairing URL, the web server -- is the same code the
# container path runs.
#
# Two environment facts this case works around, both real constraints and
# neither a weakening of what it asserts:
#   * Orca's IPC socket lives under the folder's own home, and a unix
#     socket path is capped at ~108 bytes -- so the project goes in a SHORT
#     directory of its own rather than under $BATS_TEST_TMPDIR.
#   * Orca needs an X display. This case starts its own Xvfb on a display
#     it has proved is free, and kills only that one. Peers on this box run
#     their own Orca runtimes on their own displays; nothing here may touch
#     them, which is why teardown greps for this test's own user-data dir
#     and never for a bare "orca-ide".

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"

# Orca needs a few seconds to serve; the launcher's own wait is bounded by
# CLAUDE_ORCA_WEBURL_TIMEOUT below and this is the outer belt.
E2E_TIMEOUT=240

setup() {
    # A box without these cannot run this case at all: skip and name it,
    # the way the other real-Orca cases do, rather than fail in setup.
    command -v Xvfb >/dev/null 2>&1 || skip "no Xvfb on this box"
    command -v curl >/dev/null 2>&1 || skip "no curl on this box"
    [ -x "${CLAUDE_ORCA_ORCA_BIN:-/opt/Orca/orca-ide}" ] \
        || skip "no Orca binary at ${CLAUDE_ORCA_ORCA_BIN:-/opt/Orca/orca-ide}"

    # A short path, for the unix-socket limit, and unique, so teardown can
    # match this run's processes and only this run's.
    E2E_ROOT="$(mktemp -d /tmp/orca-e2e-XXXXXX)"
    E2E_PROJECT="$E2E_ROOT/p"
    E2E_USER_DATA="$E2E_PROJECT/.claude-dev/home/.config/orca"
    mkdir -p "$E2E_PROJECT/.claude-dev/template"

    git -C "$E2E_PROJECT" init --quiet -b main
    git -C "$E2E_PROJECT" -c user.email=e2e@example.com -c user.name=e2e \
        commit --quiet --allow-empty -m init

    # The template clone a real folder carries, taken from the WORKING tree
    # rather than from HEAD: this case must exercise the launcher as edited.
    tar -cf - -C "$REPO_ROOT" \
        --exclude=.git --exclude=node_modules --exclude=__pycache__ . \
        | tar -xf - -C "$E2E_PROJECT/.claude-dev/template"
    "$E2E_PROJECT/.claude-dev/template/scripts/link-bin.sh" "$E2E_PROJECT/.claude-dev"

    e2e_start_xvfb
}

# The lowest display in a private range that Xvfb will actually take. Peers
# hold :99, :100 and :102; asking Xvfb rather than trusting a file check is
# what makes this race-free -- a display already in use makes it exit.
e2e_start_xvfb() {
    local n=140
    E2E_DISPLAY=""
    E2E_XVFB_PID=""
    while [ "$n" -lt 180 ]; do
        if [ ! -e "/tmp/.X11-unix/X$n" ] && [ ! -e "/tmp/.X$n-lock" ]; then
            Xvfb ":$n" -screen 0 1280x900x24 -nolisten tcp \
                > "$E2E_ROOT/xvfb.log" 2>&1 &
            E2E_XVFB_PID=$!
            sleep 2
            if kill -0 "$E2E_XVFB_PID" 2>/dev/null && [ -e "/tmp/.X11-unix/X$n" ]; then
                E2E_DISPLAY=":$n"
                return 0
            fi
            kill -KILL "$E2E_XVFB_PID" 2>/dev/null || true
            E2E_XVFB_PID=""
        fi
        n=$((n + 1))
    done
    return 1
}

teardown() {
    if [ -n "${E2E_PROJECT:-}" ] && [ -x "$E2E_PROJECT/claude-dev" ]; then
        ( cd "$E2E_PROJECT" && CLAUDE_ORCA_RUNTIME=local \
            timeout 60 ./claude-dev stop ) >/dev/null 2>&1 || true
    fi
    # This run's Orca only, matched on this run's own user-data dir. Never
    # a bare pkill of orca-ide: other sessions on this box run their own.
    if [ -n "${E2E_USER_DATA:-}" ]; then
        pkill -f -- "--user-data-dir=$E2E_USER_DATA" 2>/dev/null || true
        sleep 1
        pkill -KILL -f -- "--user-data-dir=$E2E_USER_DATA" 2>/dev/null || true
    fi
    if [ -n "${E2E_XVFB_PID:-}" ]; then
        kill -TERM "$E2E_XVFB_PID" 2>/dev/null || true
    fi
    if [ -n "${E2E_ROOT:-}" ]; then
        rm -rf "$E2E_ROOT"
    fi
}

@test "end to end on the local runtime: the launcher starts the real entrypoint, Orca serves, and the published URL answers with Orca Web" {
    [ -n "$E2E_DISPLAY" ]

    run env -u CLAUDE_ORCA_IMAGE \
        CLAUDE_ORCA_RUNTIME=local \
        CLAUDE_ORCA_OPEN=0 \
        CLAUDE_ORCA_PORT_BASE=7810 \
        CLAUDE_ORCA_WEBURL_TIMEOUT=180 \
        DISPLAY="$E2E_DISPLAY" \
        timeout "$E2E_TIMEOUT" \
        "$E2E_PROJECT/.claude-dev/bin/claude-dev" register "$E2E_PROJECT"
    [ "$status" -eq 0 ]

    # The handshake file, written by the entrypoint and nothing else. The
    # fragment carries a pairing code, so the mode is part of the contract.
    url_file="$E2E_PROJECT/.claude-dev/run/orca-web-url.txt"
    [ -s "$url_file" ]
    [ "$(stat -c '%a' "$url_file")" = "600" ]

    url="$(head -1 "$url_file")"
    [[ "$url" == http://127.0.0.1:* ]]
    [[ "$url" == *"#pairing="* ]]

    # Orca itself, over HTTP. The fragment is a browser-side thing and is
    # not sent, so the request is the URL up to the '#'.
    base="${url%%#*}"
    run curl -sS --max-time 30 -o "$E2E_ROOT/body.html" -w '%{http_code}' "$base"
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]
    grep -qF "Orca Web" "$E2E_ROOT/body.html"

    # And the launcher agrees the thing it started is up.
    run env CLAUDE_ORCA_RUNTIME=local timeout 60 \
        "$E2E_PROJECT/.claude-dev/bin/claude-dev" --doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"runtime"* ]]
    [[ "$output" == *"local"* ]]
    [[ "$output" == *"claude-orca-p (running)"* ]]
    [[ "$output" == *"sshd"* ]]
}
