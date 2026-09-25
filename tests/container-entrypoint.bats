#!/usr/bin/env bats
#
# v3 S1 acceptance contract (claude-orca-qa2.1) -- FROZEN from RED-AT
# onward. The VM half of v3: the container image and the in-VM entrypoint
# that brings Orca up headless in serve mode. There is no CI workflow any
# more -- the image is built locally by acquire_image the first time a
# folder registers, so the pins below are all that is left to assert
# statically; whether the image itself works is proven by running it.
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

# The extracted AppImage (squashfs-root/orca-ide). Overridable so the same
# contract runs wherever the extraction lives, but never optional.
# A REAL Orca Linux binary, wherever this box keeps one. The image
# installs it at /opt/Orca, which is where it is when the suite runs
# inside the container -- and that is the only place it can be counted on.
# The old default was a scratchpad path belonging to one session on one
# machine (/tmp/claude-1000/-workspace/<uuid>/...), so the case below
# failed everywhere else, which is the same as having no signal at all.
real_orca_bin() {
    local cand
    for cand in "${CLAUDE_ORCA_APPIMAGE_ROOT:-}/orca-ide" \
                /opt/Orca/orca-ide \
                /opt/orca/orca-ide; do
        [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    done
    return 1
}
REAL_ORCA_BIN="$(real_orca_bin || true)"

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

# Orca is an Electron app and needs an X display; a bats run has none, so
# the real-Orca case below brings its own up and exports DISPLAY at it.
# Asking Xvfb to take a display rather than trusting a file check is what
# makes this race-free -- a display already in use makes Xvfb exit. Peers
# on this box hold their own displays and must never be touched, so this
# only ever kills the server it started itself (see teardown).
start_xvfb() {
    local n=180
    EP_DISPLAY=""
    EP_XVFB_PID=""
    while [ "$n" -lt 220 ]; do
        if [ ! -e "/tmp/.X11-unix/X$n" ] && [ ! -e "/tmp/.X$n-lock" ]; then
            Xvfb ":$n" -screen 0 1280x900x24 -nolisten tcp \
                > "$TMP/xvfb.log" 2>&1 &
            EP_XVFB_PID=$!
            sleep 2
            if kill -0 "$EP_XVFB_PID" 2>/dev/null && [ -e "/tmp/.X11-unix/X$n" ]; then
                EP_DISPLAY=":$n"
                export DISPLAY="$EP_DISPLAY"
                return 0
            fi
            kill -KILL "$EP_XVFB_PID" 2>/dev/null || true
            EP_XVFB_PID=""
        fi
        n=$((n + 1))
    done
    return 1
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
}

teardown() {
    stop_entrypoint
    # Only the Xvfb this test started, never a peer's.
    [ -n "${EP_XVFB_PID:-}" ] && kill -TERM "$EP_XVFB_PID" 2>/dev/null
    # Orca's daemon is detached and outlives the entrypoint's process group,
    # so it needs its own kill -- scoped to THIS test's user-data dir
    # ($HOME/.config/orca under the per-test $TMP), which every process of
    # that runtime carries on its command line (--user-data-dir=, the
    # daemon's --socket/--token paths). Never `pkill -x orca-ide`: other
    # sessions on this box run their own Orca runtimes and must survive.
    [ -n "${TMP:-}" ] && pkill -f -- "$TMP/home/.config/orca" 2>/dev/null
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    return 0
}

# --- startup v4 (claude-orca-qa2.9) --------------------------------------
#
# The container installs and seeds itself: the entrypoint runs setup.sh at
# every start (before the privilege drop) and seeds the four things the Mac
# launcher used to seed. Everything this slice adds happens BEFORE Orca is
# started, so these cases point ORCA_BIN at nothing: the entrypoint does the
# work, dies at "ORCA_BIN is not executable", and what it left on disk is
# the evidence. That die is also the ordering proof.

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

@test "entrypoint runs setup.sh before dropping privileges and logs it to run/setup.log" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" before after
    make_project "$proj"
    : > "$TMP/setup.argv"
    write_setup_stub "$TMP/setup.sh"

    run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SETUP="$TMP/setup.sh" \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"

    # It got as far as starting Orca, which is after the setup step.
    [ "$status" -ne 0 ]
    [[ "$output" == *"ORCA_BIN is not executable"* ]]

    # First start: --check said the toolchain is not there, so the user
    # gets told why the VM is going to sit there for minutes.
    [[ "$output" == *"First start: installing the toolchain"* ]]

    # --check first, then the real run with no arguments.
    grep -qxF 'argv:--check' "$TMP/setup.argv"
    grep -qxF 'argv:' "$TMP/setup.argv"

    # tee'd, so the install output is both on the console and in the file
    # every failure message points at.
    [ -f "$proj/.claude-dev/run/setup.log" ]
    grep -qF 'stub setup: installing everything' "$proj/.claude-dev/run/setup.log"
    [[ "$output" == *"stub setup: installing everything"* ]]

    # Second start: --check passes now, so no notice -- but setup still runs.
    run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SETUP="$TMP/setup.sh" \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    [[ "$output" != *"First start:"* ]]

    # The skip knob keeps it out of the way entirely.
    before="$(wc -l < "$TMP/setup.argv" | tr -d '[:space:]')"
    run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SETUP="$TMP/setup.sh" \
        CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    after="$(wc -l < "$TMP/setup.argv" | tr -d '[:space:]')"
    [ "$before" = "$after" ]
    [[ "$output" == *"skipping setup"* ]]

    # An absent setup script is a logged skip, not a crash (base image
    # without the template mounted yet).
    run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SETUP="$TMP/no-setup.sh" \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    [[ "$output" == *"skipping setup"* ]]
    [[ "$output" == *"$TMP/no-setup.sh"* ]]

    # A failing setup says where to look and carries on (claude-orca-dbu.6):
    # on the built-image path setup.sh is a verification pass, so its
    # failure means the image is wrong -- and killing the container there
    # removes the only thing that could report that. The run goes on to the
    # one die that is still fatal, the missing Orca binary.
    run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SETUP="$TMP/setup.sh" \
        CLAUDE_ORCA_STUB_SETUP_STATUS=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"setup.sh failed"* ]]
    [[ "$output" == *"$proj/.claude-dev/run/setup.log"* ]]
    [[ "$output" == *"ORCA_BIN is not executable"* ]]
}

# write_setup_stub's failing twin (claude-orca-dbu.6). --check passes, so
# there is no first-start notice to confuse the assertions; the real run
# prints a line (which still has to reach run/setup.log) and exits 1.
write_failing_setup_stub() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "--check" ]; then exit 0; fi
echo "stub setup: this image is not what it promised"
exit 1
STUB
    chmod +x "$path"
}

@test "a failing setup.sh does not stop the entrypoint: Orca still starts and run/orca-web-url.txt is still written" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" urlfile port
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin"
    write_failing_setup_stub "$TMP/setup.sh"
    port="$(free_port)"

    # A stub Orca that speaks serve's URL line and then stays up.
    cat > "$TMP/bin/orca-ide" <<'STUB'
#!/usr/bin/env bash
port=""
prev=""
for arg in "$@"; do
    [ "$prev" = "--port" ] && port="$arg"
    prev="$arg"
done
echo "Web client URL: http://127.0.0.1:${port}/web-index.html#pairing=x"
exec sleep 300
STUB
    chmod +x "$TMP/bin/orca-ide"

    export HOME="$TMP/home"
    export PROJECT_DIR="$proj"
    export ORCA_PORT="$port"
    export ORCA_BIN="$TMP/bin/orca-ide"
    export ORCA_CLI=/bin/true
    export CLAUDE_ORCA_SETUP="$TMP/setup.sh"
    export CLAUDE_ORCA_SKIP_BEADS=1
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=30

    start_entrypoint_bg

    urlfile="$proj/.claude-dev/run/orca-web-url.txt"
    if ! wait_for_file "$urlfile" 40; then
        echo "--- entrypoint stdout ---" >&2
        cat "$TMP/entrypoint.out" >&2 || true
        false
    fi

    run cat "$urlfile"
    [ "$status" -eq 0 ]
    [ "$output" = "http://127.0.0.1:${port}/web-index.html#pairing=x" ]

    # The failure was not silent: it is on the console, in setup.log, and
    # in the status file -- and Orca came up anyway.
    grep -qF 'setup.sh failed' "$TMP/entrypoint.out"
    grep -qF 'stub setup: this image is not what it promised' \
        "$proj/.claude-dev/run/setup.log"
    [ "$(cat "$proj/.claude-dev/run/provision/setup.status" | tr -d '[:space:]')" = "1" ]
}

@test "a failing setup.sh leaves a non-zero run/provision/setup.status and a warning, not a die" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project"
    make_project "$proj"
    write_failing_setup_stub "$TMP/setup.sh"

    run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SETUP="$TMP/setup.sh" \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"

    # Warned, named the log, and carried on: the only die it reaches is the
    # one for a missing Orca, which is downstream of everything setup does.
    [[ "$output" == *"setup.sh failed"* ]]
    [[ "$output" == *"$proj/.claude-dev/run/setup.log"* ]]
    [[ "$output" == *"ORCA_BIN is not executable"* ]]

    run cat "$proj/.claude-dev/run/provision/setup.status"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | tr -d '[:space:]')" = "1" ]
}

@test "a succeeding setup.sh leaves run/provision/setup.status 0" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project"
    make_project "$proj"
    : > "$TMP/setup.argv"
    write_setup_stub "$TMP/setup.sh"

    run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SETUP="$TMP/setup.sh" \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    [[ "$output" == *"setup done"* ]]
    [[ "$output" != *"setup.sh failed"* ]]

    # 0 is written too, so "ran fine" and "never ran" are distinguishable.
    run cat "$proj/.claude-dev/run/provision/setup.status"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | tr -d '[:space:]')" = "0" ]
}

@test "an ORCA_BIN that is not executable still fails the entrypoint" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project"
    make_project "$proj"
    : > "$TMP/setup.argv"
    write_setup_stub "$TMP/setup.sh"

    # Nothing to serve is still fatal: this is the one die the demotion
    # above leaves standing.
    run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SETUP="$TMP/setup.sh" \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ORCA_BIN is not executable"* ]]
    [[ "$output" == *"$TMP/bin/no-such-orca"* ]]
}

@test "entrypoint starts Orca serve headless from ORCA_BIN, writes run/orca-web-url.txt with the pairing URL and run/port, and the URL serves Orca Web" {
    # Checked against the REAL Orca binary wherever this box has one --
    # which, run inside the image, it always does. A box without Orca
    # skips rather than failing: this case is about the entrypoint, and a
    # red row that only says "this machine has no Orca" buries the ones
    # that mean something.
    [ -n "$REAL_ORCA_BIN" ] && [ -x "$REAL_ORCA_BIN" ] \
        || skip "no Orca binary on this box (set CLAUDE_ORCA_APPIMAGE_ROOT, or run the suite inside the image)"
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

    # Orca is Electron: with no DISPLAY it segfaults before it can serve.
    # A bats run has none, so this case brings its own X server up.
    start_xvfb

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

    # This box bakes /opt/claude-orca, which would otherwise win the
    # entrypoint's template-root race (see "where the template is" in
    # entrypoint.sh) and provision from the IMAGE's frozen provision.d
    # instead of the repo under test -- so an unintended sixth CLI call
    # added to a provision.d step here would never show up. Give the
    # folder's own template an executable setup.sh (the same tiebreak
    # case 14 exercises) so TEMPLATE_ROOT picks $proj/.claude-dev/template;
    # it carries no provision-run.sh of its own, so the entrypoint's
    # fallback (provision_runner="$SCRIPT_DIR/provision-run.sh") runs
    # THIS repo's provision-run.sh, whose own provision.d is next to it --
    # exactly the tree this test edits. CLAUDE_ORCA_SKIP_SETUP=1 below
    # means that stub setup.sh is never actually executed; it only has to
    # exist and be +x for the template-root check.
    mkdir -p "$proj/.claude-dev/template/scripts/container"
    : > "$proj/.claude-dev/template/scripts/container/setup.sh"
    chmod +x "$proj/.claude-dev/template/scripts/container/setup.sh"

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
    export CLAUDE_ORCA_SKIP_SETUP=1

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

    # And the CLI is called by exactly the provision steps that need it,
    # in exactly this order: repo add (60-orca-repo-add), then the
    # skill's --json check, plain-text fallback and install
    # (75-orca-skills). 65-worktree-sweep asks Orca nothing here: it
    # probes reachability only when it has a worktree to remove, and a
    # fresh project has none. A fifth line -- or any reordering -- means
    # some step grew a call it must not make.
    cat > "$TMP/expected-cli.log" <<EXPECTED
repo add --path $proj --json
skills installed --json
skills installed
skills install --skill orchestration --local
EXPECTED
    run diff -u "$TMP/expected-cli.log" "$TMP/cli.log"
    [ "$status" -eq 0 ]

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

@test "Dockerfile, setup.sh and smoke.sh exist, and setup.sh pins Orca 1.4.197" {
    [ -f "$DOCKERFILE" ]
    [ -x "$SETUP" ]
    [ -x "$SMOKE" ]
    [ -x "$ENTRYPOINT" ]

    # The Orca release the image installs, pinned -- never 'latest'.
    run grep -c '1\.4\.197' "${SETUP%/*}"/phases/orca.sh
    [ "$status" -eq 0 ]
    [ "$output" != "0" ]
    # claude-orca-qa2.6 re-pointed this one assertion: the AppImage cannot
    # be extracted under QEMU, so the image installs the release .deb.
    run grep -qE 'orca-ide_\$\{ORCA_VERSION\}_\$\{[A-Za-z_][A-Za-z0-9_]*\}\.deb' "$SETUP" "${SETUP%/*}"/phases/*.sh
    [ "$status" -eq 0 ]

    # The image runs the entrypoint under tini.
    run grep -q 'scripts/container/entrypoint.sh' "$DOCKERFILE"
    [ "$status" -eq 0 ]
}

@test "entrypoint seeds .gitignore, attachments/ and the home gitconfig from CLAUDE_ORCA_GIT_NAME and CLAUDE_ORCA_GIT_EMAIL" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" home pattern
    make_project "$proj"
    home="$proj/.claude-dev/home"

    # Twice, because the seed has to be idempotent: a folder is registered
    # again on every start.
    local i
    for i in 1 2; do
        run env HOME="$home" PROJECT_DIR="$proj" \
            ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
            CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
            CLAUDE_ORCA_GIT_NAME="Ada Lovelace" \
            CLAUDE_ORCA_GIT_EMAIL="ada@example.com" \
            bash "$ENTRYPOINT"
        [ "$status" -ne 0 ]
        [[ "$output" == *"ORCA_BIN is not executable"* ]]
    done

    # The same entries and marker seed_gitignore writes on the Mac, each
    # exactly once.
    [ -f "$proj/.gitignore" ]
    run grep -c '^# claude_orca$' "$proj/.gitignore"
    [ "$output" = "1" ]
    for pattern in '.claude-dev/' '.claude-dev-snapshots/' '/claude-dev' \
                   'Orca.app/' '.mcp.json' 'attachments/' '.claude/logs/'; do
        run grep -c -xF "$pattern" "$proj/.gitignore"
        [ "$output" = "1" ]
    done

    # Where take-screenshot drops images.
    [ -d "$proj/attachments" ]

    # A fresh .claude-dev/home has no git identity at all, so every commit
    # inside the VM would fail. The Mac passes its own as env.
    [ -f "$home/.gitconfig" ]
    run cat "$home/.gitconfig"
    [[ "$output" == *"name = Ada Lovelace"* ]]
    [[ "$output" == *"email = ada@example.com"* ]]

    # Never over an existing one: whatever the agent set up in there wins.
    run env HOME="$home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        CLAUDE_ORCA_GIT_NAME="Someone Else" \
        CLAUDE_ORCA_GIT_EMAIL="else@example.com" \
        bash "$ENTRYPOINT"
    run cat "$home/.gitconfig"
    [[ "$output" == *"Ada Lovelace"* ]]
    [[ "$output" != *"Someone Else"* ]]

    # Nothing to copy: no env, no file (and no empty [user] stanza).
    local proj2="$TMP/project2" home2
    make_project "$proj2"
    home2="$proj2/.claude-dev/home"
    # -u: a claude-orca container exports the identity into every shell,
    # and this leg is about the folder that ships none.
    run env -u CLAUDE_ORCA_GIT_NAME -u CLAUDE_ORCA_GIT_EMAIL \
        HOME="$home2" PROJECT_DIR="$proj2" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    [ ! -f "$home2/.gitconfig" ]
    [ -d "$proj2/attachments" ]
}

# --- first-run friction (claude-orca-qa2.17) ------------------------------
#
# Both cases come off the 2026-09-06 live demo on this box: the Orca CLI
# talked to the wrong runtime, and a Claude Code worker in a fresh
# .claude-dev/home sat on the trust dialog forever.

@test "entrypoint passes its own user-data dir to the Orca CLI for repo add" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" home="$TMP/home" port urlfile ud
    make_project "$proj"
    mkdir -p "$home" "$TMP/bin"
    port="$(free_port)"
    ud="$TMP/ud"

    cat > "$TMP/bin/orca-ide" <<'STUB'
#!/usr/bin/env bash
port=""
prev=""
for arg in "$@"; do
    [ "$prev" = "--port" ] && port="$arg"
    prev="$arg"
done
echo "Web client URL: http://127.0.0.1:${port}/web-index.html#pairing=x"
exec sleep 300
STUB
    chmod +x "$TMP/bin/orca-ide"

    # The CLI stub records the environment variable that decides WHICH
    # running Orca it talks to, not just its argv.
    cat > "$TMP/bin/orca" <<STUB
#!/usr/bin/env bash
printf 'udp=%s argv=%s\n' "\${ORCA_USER_DATA_PATH:-unset}" "\$*" >> "$TMP/cli.log"
exit 0
STUB
    chmod +x "$TMP/bin/orca"
    : > "$TMP/cli.log"

    export HOME="$home"
    export PROJECT_DIR="$proj"
    export ORCA_PORT="$port"
    export ORCA_BIN="$TMP/bin/orca-ide"
    export ORCA_CLI="$TMP/bin/orca"
    export ORCA_USER_DATA_DIR="$ud"
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    export CLAUDE_ORCA_SKIP_SETUP=1
    export CLAUDE_ORCA_SKIP_BEADS=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=30

    start_entrypoint_bg
    urlfile="$proj/.claude-dev/run/orca-web-url.txt"
    if ! wait_for_file "$urlfile" 30; then
        cat "$TMP/entrypoint.out" >&2 || true
        false
    fi
    local i
    for i in $(seq 1 20); do
        grep -q 'repo add' "$TMP/cli.log" && break
        sleep 0.5
    done
    stop_entrypoint

    run cat "$TMP/cli.log"
    [ "$status" -eq 0 ]
    [[ "$output" == *"udp=$ud"* ]]
    [[ "$output" != *"udp=unset"* ]]
    [[ "$output" == *"repo add --path $proj"* ]]
}

@test "entrypoint seeds the Claude Code trust and bypass-permissions keys without overwriting existing ones" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project" home cj sj
    make_project "$proj"
    home="$proj/.claude-dev/home"
    cj="$home/.claude.json"
    sj="$home/.claude/settings.json"

    run env HOME="$home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ORCA_BIN is not executable"* ]]

    # The folder-trust dialog and the first-run wizard.
    [ -f "$cj" ]
    run jq -r --arg p "$proj" '.projects[$p].hasTrustDialogAccepted' "$cj"
    [ "$output" = "true" ]
    run jq -r '.hasCompletedOnboarding' "$cj"
    [ "$output" = "true" ]

    # The disclaimer --dangerously-skip-permissions raises once per install.
    [ -f "$sj" ]
    run jq -r '.skipDangerousModePermissionPrompt' "$sj"
    [ "$output" = "true" ]

    # A value already on disk always wins, and nothing else in the file is
    # disturbed: these are the agent's own config files.
    jq -n --arg p "$proj" '{
        hasCompletedOnboarding: false,
        oauthAccount: {emailAddress: "someone@example.com"},
        projects: {($p): {hasTrustDialogAccepted: false, allowedTools: ["Bash"]}}
    }' > "$cj"
    jq -n '{skipDangerousModePermissionPrompt: false, model: "opus"}' > "$sj"

    run env HOME="$home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    run jq -r --arg p "$proj" '[.hasCompletedOnboarding,
        .projects[$p].hasTrustDialogAccepted,
        .projects[$p].allowedTools[0],
        .oauthAccount.emailAddress] | join(",")' "$cj"
    [ "$output" = "false,false,Bash,someone@example.com" ]
    run jq -r '[.skipDangerousModePermissionPrompt, .model] | join(",")' "$sj"
    [ "$output" = "false,opus" ]

    # A config file that is not JSON is left exactly as it was found --
    # never replaced, because that file is the agent's login.
    printf 'not json at all\n' > "$cj"
    run env HOME="$home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    run cat "$cj"
    [ "$output" = "not json at all" ]
}

@test "entrypoint restores the newest beads snapshot before bd init when the project has no beads" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" snaps
    make_project "$proj"
    snaps="$proj/.claude-dev-snapshots"
    mkdir -p "$snaps/20200101-000000" "$snaps/20240101-000000"
    echo '{"id":"old"}' > "$snaps/20200101-000000/issues.jsonl"
    echo '{"id":"newest"}' > "$snaps/20240101-000000/issues.jsonl"
    echo '{"prefix":"newest"}' > "$snaps/20240101-000000/metadata.json"
    [ ! -e "$proj/.beads" ]

    run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ORCA_BIN is not executable"* ]]

    # The newest snapshot, not the first one listed.
    [ -f "$proj/.beads/issues.jsonl" ]
    run cat "$proj/.beads/issues.jsonl"
    [ "$output" = '{"id":"newest"}' ]
    run cat "$proj/.beads/metadata.json"
    [ "$output" = '{"prefix":"newest"}' ]

    # A project that already carries beads keeps them: an older snapshot
    # must never overwrite live data.
    echo '{"id":"live"}' > "$proj/.beads/issues.jsonl"
    run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    run cat "$proj/.beads/issues.jsonl"
    [ "$output" = '{"id":"live"}' ]

    # No snapshots at all is a silent no-op, not a failure.
    local proj2="$TMP/project2"
    make_project "$proj2"
    run env HOME="$proj2/.claude-dev/home" PROJECT_DIR="$proj2" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    [[ "$output" == *"ORCA_BIN is not executable"* ]]
    [ ! -e "$proj2/.beads" ]
}

@test "entrypoint resolves the template from /opt/claude-orca or the mounted .claude-dev/template" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" expect_root
    make_project "$proj"

    # The prebuilt image carries the template at /opt/claude-orca; a base
    # image has only the folder's own mounted clone. The entrypoint's rule
    # (entrypoint.sh, "where the template is"): the folder's template wins
    # when it carries an executable setup.sh, then the baked copy, then
    # the folder clone bare. expect_root follows that same rule, so the
    # case holds on a base image, on the baked image, and on a project
    # that has pulled its own template clone -- whichever this box is.
    if [ -x "$proj/.claude-dev/template/scripts/container/setup.sh" ]; then
        expect_root="$proj/.claude-dev/template"
    elif [ -d /opt/claude-orca ]; then
        expect_root="/opt/claude-orca"
    else
        expect_root="$proj/.claude-dev/template"
    fi

    run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    [[ "$output" == *"template root: $expect_root"* ]]
    [[ "$output" == *"setup: $expect_root/scripts/container/setup.sh"* ]]

    # ...and that default is the script that actually runs.
    if [ ! -d /opt/claude-orca ]; then
        : > "$TMP/setup.argv"
        write_setup_stub "$proj/.claude-dev/template/scripts/container/setup.sh"
        run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
            ORCA_BIN="$TMP/bin/no-such-orca" \
            CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
            bash "$ENTRYPOINT"
        grep -qxF 'argv:' "$TMP/setup.argv"
        grep -qF 'stub setup: installing everything' \
            "$proj/.claude-dev/run/setup.log"
    fi

    # The image branch, which this box cannot exercise, is pinned here.
    run grep -qF '[ -d /opt/claude-orca ]' "$ENTRYPOINT"
    [ "$status" -eq 0 ]
}

@test "entrypoint prefers the folder's own template when it carries an executable setup.sh, even over a baked /opt/claude-orca" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project"
    make_project "$proj"

    # No setup.sh in the folder's clone yet: whichever root this box would
    # have picked before (see the test above) still wins.
    if [ -d /opt/claude-orca ]; then
        run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
            ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
            CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
            bash "$ENTRYPOINT"
        [[ "$output" == *"template root: /opt/claude-orca"* ]]
    fi

    # An executable setup.sh in the folder's own clone -- what `--update`
    # leaves behind -- outranks the baked copy even when /opt/claude-orca
    # is still there, so a scripts/container/* fix reaches a folder on the
    # next recreate with no image rebuild.
    write_setup_stub "$proj/.claude-dev/template/scripts/container/setup.sh"
    run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    [[ "$output" == *"template root: $proj/.claude-dev/template"* ]]
}

# --- the OpenRouter guard, wired in (claude-orca-qa2.21) ------------------
#
# The user's hard rule is that their data never routes to China, and the only
# thing that can enforce it is a chokepoint no client can edit: the in-VM
# guard (scripts/container/openrouter-guard.py + config/provider-policy.json,
# claude-orca-qa2.20) holds the real OPENROUTER_API_KEY alone and forces the
# provider allowlist onto every completion request. A guard nothing starts
# enforces nothing, so what these two cases check is the WIRING.
#
# Nothing here touches openrouter.ai: OPENROUTER_UPSTREAM points the guard at
# a python3 stdlib stub, exactly as tests/openrouter-guard.bats does.

# The key that must never be visible to an agent terminal.
REAL_KEY="sk-or-v1-real-secret-never-in-a-terminal"

# A stub Orca that dumps its own environment before behaving like serve.
# Orca's process env is what every terminal it spawns inherits, so that dump
# IS "what an agent terminal sees".
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

# A stub OpenRouter that records the bytes that would have left the VM. It
# self-terminates so a failed assertion cannot leave it running.
write_upstream_stub() {
    cat > "$TMP/upstream.py" <<'PY'
import os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
REC = os.environ["UPSTREAM_REC"]
threading.Timer(180, lambda: os._exit(0)).start()


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        with open(os.path.join(REC, "body.json"), "wb") as f:
            f.write(body)
        with open(os.path.join(REC, "headers.txt"), "w") as f:
            for k, v in self.headers.items():
                f.write("%s: %s\n" % (k.lower(), v))
        payload = b'{"id":"cmpl-1","choices":[{"message":{"content":"ok"}}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
}

wait_tcp_port() {
    local i=0
    while [ "$i" -lt 100 ]; do
        if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.3); sys.exit(0 if s.connect_ex(('127.0.0.1',$1))==0 else 1)"; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.2
    done
    echo "port $1 never came up" >&2
    return 1
}

# Boots the entrypoint in its own process group with whatever this test has
# exported, waits for the stub Orca to dump its environment, and stops the
# whole tree again unless asked to keep it up.
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

@test "the entrypoint starts the OpenRouter guard when a key is present and Orca terminals see only the guard token and base URL" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project" gport token gpid data a
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin"
    write_env_dump_orca "$TMP/bin/orca-ide"
    gport="$(free_port)"

    export_guard_test_env "$proj" "$TMP/ud"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    export OPENROUTER_API_KEY="$REAL_KEY"
    # the guard is started, but it is never allowed to reach the internet
    export OPENROUTER_UPSTREAM="http://127.0.0.1:1"

    boot_entrypoint keep

    # the guard is a real running process, and it is listening
    [ -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
    gpid="$(cat "$proj/.claude-dev/run/openrouter-guard.pid")"
    kill -0 "$gpid"
    wait_tcp_port "$gport"
    grep -qF 'openrouter-guard: listening' "$proj/.claude-dev/run/openrouter-guard.log"

    # the token it handed out is a credential of its own: owner-only, and
    # never the real key
    [ -s "$proj/.claude-dev/run/openrouter-guard.token" ]
    run stat -c '%a' "$proj/.claude-dev/run/openrouter-guard.token"
    [ "$output" = "600" ]
    token="$(cat "$proj/.claude-dev/run/openrouter-guard.token")"
    [ -n "$token" ]
    [ "$token" != "$REAL_KEY" ]

    # what every terminal Orca spawns inherits: the token and the guard's
    # loopback base URL, and the real key nowhere at all
    grep -qxF "OPENROUTER_API_KEY=$token" "$ORCA_ENV_DUMP"
    grep -qxF "OPENROUTER_BASE_URL=http://127.0.0.1:$gport/api/v1" "$ORCA_ENV_DUMP"
    run grep -c -- "$REAL_KEY" "$ORCA_ENV_DUMP"
    [ "$output" = "0" ]

    # ... and the same two variables reach the OpenRouter-speaking agents
    # through Orca's seeded per-agent environment
    data="$TMP/ud/profiles/local-default/orca-data.json"
    [ -f "$data" ]
    for a in opencode codex; do
        run jq -r --arg a "$a" '.settings.agentDefaultEnv[$a].OPENROUTER_API_KEY' "$data"
        [ "$output" = "$token" ]
        run jq -r --arg a "$a" '.settings.agentDefaultEnv[$a].OPENROUTER_BASE_URL' "$data"
        [ "$output" = "http://127.0.0.1:$gport/api/v1" ]
    done
    # the seed's existing content survives, and the key is not in the file
    run jq -r '.settings.agentDefaultEnv.opencode.OPENCODE_CONFIG' "$data"
    [ "$output" = "/home/agent/.config/opencode/opencode.json" ]
    run jq -r --arg p "$proj" '.settings.agentDefaultEnv.claude.CLAUDE_ORCA_ROOT == $p' "$data"
    [ "$output" = "true" ]
    run grep -c -- "$REAL_KEY" "$data"
    [ "$output" = "0" ]

    stop_entrypoint

    # Fail closed on the KEY, not on the boot: a guard that cannot start
    # leaves the VM without OpenRouter rather than with an unpoliced key in
    # every terminal.
    local proj2="$TMP/project2"
    make_project "$proj2"
    export_guard_test_env "$proj2" "$TMP/ud2"
    export CLAUDE_ORCA_GUARD_PORT="$(free_port)"
    export CLAUDE_ORCA_GUARD_SCRIPT="$TMP/no-such-guard.py"
    export OPENROUTER_API_KEY="$REAL_KEY"
    boot_entrypoint
    run grep -c -- "$REAL_KEY" "$ORCA_ENV_DUMP"
    [ "$output" = "0" ]
    run grep -c '^OPENROUTER_BASE_URL=' "$ORCA_ENV_DUMP"
    [ "$output" = "0" ]
    [ ! -s "$proj2/.claude-dev/run/openrouter-guard.pid" ]
    # and it says so loudly rather than failing silently
    run cat "$TMP/entrypoint.out"
    [[ "$output" == *"OpenRouter guard"* ]]

    # No key reached the VM at all: no guard, and nothing to inherit.
    local proj3="$TMP/project3"
    make_project "$proj3"
    export_guard_test_env "$proj3" "$TMP/ud3"
    export CLAUDE_ORCA_GUARD_PORT="$(free_port)"
    unset CLAUDE_ORCA_GUARD_SCRIPT
    export OPENROUTER_API_KEY=""
    boot_entrypoint
    [ ! -s "$proj3/.claude-dev/run/openrouter-guard.pid" ]
    run grep -c '^OPENROUTER_BASE_URL=' "$ORCA_ENV_DUMP"
    [ "$output" = "0" ]
    run jq -e '.settings.agentDefaultEnv.opencode | has("OPENROUTER_API_KEY") | not' \
        "$TMP/ud3/profiles/local-default/orca-data.json"
    [ "$status" -eq 0 ]
}

# --- claude-orca-376: the key file IS the container's own home ----------
#
# $AGENT_HOME/.openrouter.key (the same file `claude-dev key openrouter`
# writes on the Mac, since .claude-dev/home and /home/agent are the same
# directory) is now something the entrypoint can read for itself, so the
# Mac no longer has to put the key in the docker-run argv for the guard to
# start.

@test "the entrypoint starts the guard from AGENT_HOME/.openrouter.key when OPENROUTER_API_KEY is unset (claude-orca-376)" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project-keyfile-only" gport
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin"
    write_env_dump_orca "$TMP/bin/orca-ide"
    gport="$(free_port)"

    export_guard_test_env "$proj" "$TMP/ud"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    unset OPENROUTER_API_KEY
    export OPENROUTER_UPSTREAM="http://127.0.0.1:1"
    printf '%s\n' "$REAL_KEY" > "$TMP/home/.openrouter.key"
    chmod 600 "$TMP/home/.openrouter.key"

    boot_entrypoint keep

    [ -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
    wait_tcp_port "$gport"
    grep -qF 'openrouter-guard: listening' "$proj/.claude-dev/run/openrouter-guard.log"

    # the real key never reaches Orca's own environment (what a terminal
    # inherits), only the guard's token and base URL do
    run grep -c -- "$REAL_KEY" "$ORCA_ENV_DUMP"
    [ "$output" = "0" ]
    grep -qxF "OPENROUTER_BASE_URL=http://127.0.0.1:$gport/api/v1" "$ORCA_ENV_DUMP"

    # the durable key file is not the one-shot handoff file: it survives
    [ -f "$TMP/home/.openrouter.key" ]

    stop_entrypoint
}

@test "an explicit OPENROUTER_API_KEY still wins over AGENT_HOME/.openrouter.key (claude-orca-376)" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project-keyfile-override" gport upport rec other_key token base
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin" "$TMP/rec"
    rec="$TMP/rec"
    write_env_dump_orca "$TMP/bin/orca-ide"
    write_upstream_stub
    gport="$(free_port)"
    upport="$(free_port)"

    UPSTREAM_REC="$rec" python3 "$TMP/upstream.py" "$upport" \
        > "$TMP/upstream.log" 2>&1 &
    wait_tcp_port "$upport"

    export_guard_test_env "$proj" "$TMP/ud"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    other_key="sk-or-v1-explicit-env-wins-0000000000000"
    export OPENROUTER_API_KEY="$other_key"
    export OPENROUTER_UPSTREAM="http://127.0.0.1:$upport"
    # the file names a DIFFERENT key; the explicit env var must win
    printf '%s\n' "$REAL_KEY" > "$TMP/home/.openrouter.key"
    chmod 600 "$TMP/home/.openrouter.key"

    boot_entrypoint keep
    wait_tcp_port "$gport"

    token="$(sed -n 's/^OPENROUTER_API_KEY=//p' "$ORCA_ENV_DUMP")"
    base="$(sed -n 's/^OPENROUTER_BASE_URL=//p' "$ORCA_ENV_DUMP")"
    [ -n "$token" ]
    [ "$base" = "http://127.0.0.1:$gport/api/v1" ]

    run curl -s -o "$TMP/resp.json" -w '%{http_code}' --max-time 30 \
        -X POST "$base/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        --data-binary '{"model":"z-ai/glm-5.3","messages":[{"role":"user","content":"hi"}]}'
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]

    [ -f "$rec/headers.txt" ]
    grep -qxF "authorization: Bearer $other_key" "$rec/headers.txt"
    run grep -c -- "$REAL_KEY" "$rec/headers.txt"
    [ "$output" = "0" ]

    stop_entrypoint
    pkill -f -- "$TMP/upstream.py" 2>/dev/null || true
}

@test "no OPENROUTER_API_KEY and no key file leaves the guard off, unchanged (claude-orca-376)" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project-nokey" gport
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin"
    write_env_dump_orca "$TMP/bin/orca-ide"
    gport="$(free_port)"

    export_guard_test_env "$proj" "$TMP/ud"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    unset OPENROUTER_API_KEY
    [ ! -e "$TMP/home/.openrouter.key" ]

    boot_entrypoint
    [ ! -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
    run grep -c '^OPENROUTER_BASE_URL=' "$ORCA_ENV_DUMP"
    [ "$output" = "0" ]
    run cat "$TMP/entrypoint.out"
    [[ "$output" == *"no OPENROUTER_API_KEY"* ]]
}

# --- claude-orca-b30: opencode's own login is the third and last source -
#
# 'opencode auth login openrouter' already writes the real key to
# $AGENT_HOME/.local/share/opencode/auth.json (opencode's own auth store)
# inside the container. A fresh folder that only ever ran that login --
# never './claude-dev key openrouter', never a folder-side .openrouter.key
# -- must still get a working guard. The chain claude-orca-376 built grows
# a third rung, read fresh every boot and never mirrored to
# $AGENT_HOME/.openrouter.key: a cached copy would go stale the moment the
# user logs in again.

write_opencode_auth() {  # write_opencode_auth <path> <type> <key>
    mkdir -p "$(dirname "$1")"
    if [ -z "${3:-}" ]; then
        printf '{"openrouter":{"type":"%s"}}\n' "$2" > "$1"
    else
        printf '{"openrouter":{"type":"%s","key":"%s"}}\n' "$2" "$3" > "$1"
    fi
}

@test "the entrypoint starts the guard from opencode's own auth.json when no OPENROUTER_API_KEY and no key file exist (claude-orca-b30)" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project-auth-only" gport authfile
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin"
    write_env_dump_orca "$TMP/bin/orca-ide"
    gport="$(free_port)"
    authfile="$TMP/home/.local/share/opencode/auth.json"

    export_guard_test_env "$proj" "$TMP/ud"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    unset OPENROUTER_API_KEY
    export OPENROUTER_UPSTREAM="http://127.0.0.1:1"
    [ ! -e "$TMP/home/.openrouter.key" ]
    write_opencode_auth "$authfile" api "$REAL_KEY"

    boot_entrypoint keep

    [ -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
    wait_tcp_port "$gport"
    grep -qF 'openrouter-guard: listening' "$proj/.claude-dev/run/openrouter-guard.log"

    run grep -c -- "$REAL_KEY" "$ORCA_ENV_DUMP"
    [ "$output" = "0" ]
    grep -qxF "OPENROUTER_BASE_URL=http://127.0.0.1:$gport/api/v1" "$ORCA_ENV_DUMP"

    stop_entrypoint

    # auth.json is read-only input: still there, still exactly what opencode
    # wrote, never a cached copy at .openrouter.key
    [ -f "$authfile" ]
    run jq -r '.openrouter.key' "$authfile"
    [ "$output" = "$REAL_KEY" ]
    [ ! -e "$TMP/home/.openrouter.key" ]
}

@test "CLAUDE_ORCA_OPENCODE_AUTH overrides where the entrypoint looks for opencode's auth.json (claude-orca-b30)" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project-auth-override" gport authfile
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin" "$TMP/altauth"
    write_env_dump_orca "$TMP/bin/orca-ide"
    gport="$(free_port)"
    authfile="$TMP/altauth/auth.json"

    export_guard_test_env "$proj" "$TMP/ud"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    export CLAUDE_ORCA_OPENCODE_AUTH="$authfile"
    unset OPENROUTER_API_KEY
    export OPENROUTER_UPSTREAM="http://127.0.0.1:1"
    write_opencode_auth "$authfile" api "$REAL_KEY"
    # the default location is absent -- only the override should be read
    [ ! -e "$TMP/home/.local/share/opencode/auth.json" ]

    boot_entrypoint keep

    [ -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
    wait_tcp_port "$gport"

    stop_entrypoint
}

@test "AGENT_HOME/.openrouter.key wins over opencode's auth.json (claude-orca-b30)" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project-keyfile-over-auth" gport upport rec keyfile_key token base
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin" "$TMP/rec"
    rec="$TMP/rec"
    write_env_dump_orca "$TMP/bin/orca-ide"
    write_upstream_stub
    gport="$(free_port)"
    upport="$(free_port)"

    UPSTREAM_REC="$rec" python3 "$TMP/upstream.py" "$upport" \
        > "$TMP/upstream.log" 2>&1 &
    wait_tcp_port "$upport"

    export_guard_test_env "$proj" "$TMP/ud"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    unset OPENROUTER_API_KEY
    export OPENROUTER_UPSTREAM="http://127.0.0.1:$upport"
    keyfile_key="sk-or-v1-keyfile-wins-over-auth-json-000"
    printf '%s\n' "$keyfile_key" > "$TMP/home/.openrouter.key"
    chmod 600 "$TMP/home/.openrouter.key"
    # a DIFFERENT key in auth.json; the durable folder key file must win
    write_opencode_auth "$TMP/home/.local/share/opencode/auth.json" api "$REAL_KEY"

    boot_entrypoint keep
    wait_tcp_port "$gport"

    token="$(sed -n 's/^OPENROUTER_API_KEY=//p' "$ORCA_ENV_DUMP")"
    base="$(sed -n 's/^OPENROUTER_BASE_URL=//p' "$ORCA_ENV_DUMP")"
    [ -n "$token" ]

    run curl -s -o "$TMP/resp.json" -w '%{http_code}' --max-time 30 \
        -X POST "$base/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        --data-binary '{"model":"z-ai/glm-5.3","messages":[{"role":"user","content":"hi"}]}'
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]

    [ -f "$rec/headers.txt" ]
    grep -qxF "authorization: Bearer $keyfile_key" "$rec/headers.txt"
    run grep -c -- "$REAL_KEY" "$rec/headers.txt"
    [ "$output" = "0" ]

    stop_entrypoint
    pkill -f -- "$TMP/upstream.py" 2>/dev/null || true
}

@test "OPENROUTER_API_KEY wins over both AGENT_HOME/.openrouter.key and opencode's auth.json (claude-orca-b30)" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project-env-over-both" gport upport rec env_key token base
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin" "$TMP/rec"
    rec="$TMP/rec"
    write_env_dump_orca "$TMP/bin/orca-ide"
    write_upstream_stub
    gport="$(free_port)"
    upport="$(free_port)"

    UPSTREAM_REC="$rec" python3 "$TMP/upstream.py" "$upport" \
        > "$TMP/upstream.log" 2>&1 &
    wait_tcp_port "$upport"

    export_guard_test_env "$proj" "$TMP/ud"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    env_key="sk-or-v1-env-wins-over-both-0000000000"
    export OPENROUTER_API_KEY="$env_key"
    export OPENROUTER_UPSTREAM="http://127.0.0.1:$upport"
    printf '%s\n' "sk-or-v1-keyfile-loses-here-000000000" > "$TMP/home/.openrouter.key"
    chmod 600 "$TMP/home/.openrouter.key"
    write_opencode_auth "$TMP/home/.local/share/opencode/auth.json" api "$REAL_KEY"

    boot_entrypoint keep
    wait_tcp_port "$gport"

    token="$(sed -n 's/^OPENROUTER_API_KEY=//p' "$ORCA_ENV_DUMP")"
    base="$(sed -n 's/^OPENROUTER_BASE_URL=//p' "$ORCA_ENV_DUMP")"
    [ -n "$token" ]

    run curl -s -o "$TMP/resp.json" -w '%{http_code}' --max-time 30 \
        -X POST "$base/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        --data-binary '{"model":"z-ai/glm-5.3","messages":[{"role":"user","content":"hi"}]}'
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]

    [ -f "$rec/headers.txt" ]
    grep -qxF "authorization: Bearer $env_key" "$rec/headers.txt"
    run grep -c -- "$REAL_KEY" "$rec/headers.txt"
    [ "$output" = "0" ]

    stop_entrypoint
    pkill -f -- "$TMP/upstream.py" 2>/dev/null || true
}

@test "opencode's auth.json degrades quietly to the no-key path when absent, malformed, empty-key, or not type api (claude-orca-b30)" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj gport authfile case

    for case in absent malformed emptykey wrongtype; do
        proj="$TMP/project-auth-$case"
        make_project "$proj"
        rm -rf "$TMP/home"
        mkdir -p "$TMP/home" "$TMP/bin"
        write_env_dump_orca "$TMP/bin/orca-ide"
        gport="$(free_port)"
        authfile="$TMP/home/.local/share/opencode/auth.json"

        export_guard_test_env "$proj" "$TMP/ud-$case"
        export CLAUDE_ORCA_GUARD_PORT="$gport"
        unset OPENROUTER_API_KEY
        export OPENROUTER_UPSTREAM="http://127.0.0.1:1"

        case "$case" in
            absent)    ;;
            malformed) mkdir -p "$(dirname "$authfile")"; printf '{not json' > "$authfile" ;;
            emptykey)  write_opencode_auth "$authfile" api "" ;;
            wrongtype) write_opencode_auth "$authfile" oauth "$REAL_KEY" ;;
        esac

        boot_entrypoint
        [ ! -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
        run grep -c '^OPENROUTER_BASE_URL=' "$ORCA_ENV_DUMP"
        [ "$output" = "0" ]
        run cat "$TMP/entrypoint.out"
        [[ "$output" == *"no OPENROUTER_API_KEY"* ]]
    done
}

@test "opencode's auth.json is never written, moved, or unlinked by the entrypoint (claude-orca-b30)" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project-auth-readonly" gport authfile dir before after
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin"
    write_env_dump_orca "$TMP/bin/orca-ide"
    gport="$(free_port)"
    authfile="$TMP/home/.local/share/opencode/auth.json"
    dir="$(dirname "$authfile")"

    export_guard_test_env "$proj" "$TMP/ud"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    unset OPENROUTER_API_KEY
    export OPENROUTER_UPSTREAM="http://127.0.0.1:1"
    write_opencode_auth "$authfile" api "$REAL_KEY"
    chmod 644 "$authfile"
    before="$(cksum < "$authfile")"

    boot_entrypoint keep
    wait_tcp_port "$gport"
    stop_entrypoint

    [ -f "$authfile" ]
    after="$(cksum < "$authfile")"
    [ "$before" = "$after" ]
    run stat -c '%a' "$authfile"
    [ "$output" = "644" ]
    # no sibling temp/backup file left behind
    run ls -1 "$dir"
    [ "$output" = "auth.json" ]
}

@test "a completion request from inside the VM reaches upstream with the real key and the forced provider allowlist" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project" gport upport token base allow rec
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin" "$TMP/rec"
    rec="$TMP/rec"
    write_env_dump_orca "$TMP/bin/orca-ide"
    write_upstream_stub
    gport="$(free_port)"
    upport="$(free_port)"

    UPSTREAM_REC="$rec" python3 "$TMP/upstream.py" "$upport" \
        > "$TMP/upstream.log" 2>&1 &
    wait_tcp_port "$upport"

    export_guard_test_env "$proj" "$TMP/ud"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    export OPENROUTER_API_KEY="$REAL_KEY"
    export OPENROUTER_UPSTREAM="http://127.0.0.1:$upport"

    boot_entrypoint keep
    wait_tcp_port "$gport"

    # exactly what a terminal has to work with -- read out of Orca's own
    # environment, not out of the test's knowledge of the wiring
    token="$(sed -n 's/^OPENROUTER_API_KEY=//p' "$ORCA_ENV_DUMP")"
    base="$(sed -n 's/^OPENROUTER_BASE_URL=//p' "$ORCA_ENV_DUMP")"
    [ -n "$token" ]
    [ "$token" != "$REAL_KEY" ]
    [ "$base" = "http://127.0.0.1:$gport/api/v1" ]

    # a completion request that ASKS for a China-hosted provider
    run curl -s -o "$TMP/resp.json" -w '%{http_code}' --max-time 30 \
        -X POST "$base/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        --data-binary '{"model":"z-ai/glm-5.3","provider":{"order":["z-ai"],"allow_fallbacks":true,"data_collection":"allow"},"messages":[{"role":"user","content":"hi"}]}'
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]

    # what actually left the VM: the real key, and never the token
    [ -f "$rec/headers.txt" ]
    grep -qxF "authorization: Bearer $REAL_KEY" "$rec/headers.txt"
    run grep -c -- "$token" "$rec/headers.txt"
    [ "$output" = "0" ]

    # ... under the policy the client could not opt out of
    allow="$(jq -r '[.allow[].slug] | join(",")' "$REPO_ROOT/config/provider-policy.json")"
    run jq -r '.provider.only | join(",")' "$rec/body.json"
    [ "$output" = "$allow" ]
    run jq -e '.provider.allow_fallbacks == false and .provider.data_collection == "deny"' "$rec/body.json"
    [ "$status" -eq 0 ]
    # z-ai is not usable, so the guard forces its own explicit order in
    # place of the client's (claude-orca-c6b)
    run jq -r '.provider.order | join(",")' "$rec/body.json"
    [ "$output" = "$(jq -r '.order | join(",")' "$REPO_ROOT/config/provider-policy.json")" ]
    [ "$status" -eq 0 ]
    run jq -r '[.provider.only[] | select(. == "z-ai")] | length' "$rec/body.json"
    [ "$output" = "0" ]
    run jq -r '.model' "$rec/body.json"
    [ "$output" = "z-ai/glm-5.3" ]

    # the answer came back through the guard to the caller
    run jq -r '.id' "$TMP/resp.json"
    [ "$output" = "cmpl-1" ]

    # and the guard left an audit line for the request it forced
    run bash -c "grep '^{' '$proj/.claude-dev/run/openrouter-guard.log' | jq -se 'any(.[]; .path == \"/api/v1/chat/completions\" and .providers_forced == true and .client_order_dropped == true and .status == 200)'"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]

    stop_entrypoint
    pkill -f -- "$TMP/upstream.py" 2>/dev/null || true
}

@test "entrypoint config-syncs from the folder's own template clone, not the image's frozen copy" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project"
    make_project "$proj"

    # A folder clone carrying a config/ the image's copy could not have:
    # the marker command is what proves which source config-sync read.
    local tcfg="$proj/.claude-dev/template/config"
    mkdir -p "$tcfg/claude-commands"
    printf '{"hooks":{}}\n'        > "$tcfg/claude-settings.json"
    printf 'folder memory\n'       > "$tcfg/claude-user-memory.md"
    printf '#!/bin/sh\necho hi\n'  > "$tcfg/statusline.sh"
    printf 'folder-clone-marker\n' > "$tcfg/claude-commands/marker.md"

    run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"

    # On a prebuilt image /opt/claude-orca exists and used to win here; the
    # folder's clone is the source now, whichever box this runs on.
    [[ "$output" == *"config synced from $proj/.claude-dev/template/config"* ]]
    [ -f "$proj/.claude-dev/home/.claude/commands/marker.md" ]
    run cat "$proj/.claude-dev/home/.claude/CLAUDE.md"
    [ "$output" = "folder memory" ]
}

# --- early config sync (claude-orca-0jn) ---------------------------------
#
# config-sync used to run only from provision.d, after the web URL is
# published -- which meant a Claude Code session started the moment the
# workspace opened could read a settings.json that did not exist yet, or
# existed without statusLine, and Claude Code only reads statusLine at
# process start. These three cases pin the fix: a first sync BEFORE serve
# is even started, never fatal, never a second source of truth for the
# checksum gate.

@test "entrypoint syncs config before serve announces its web URL, on a brand-new project" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project" tcfg settingsfile urlfile fifo port
    mkdir -p "$proj"
    tcfg="$proj/.claude-dev/template/config"
    mkdir -p "$tcfg"
    cat > "$tcfg/claude-settings.json" <<'JSON'
{"statusLine": {"type": "command", "command": "__HOST__/template/bin/statusline"}, "hooks": {}}
JSON
    printf 'folder memory\n' > "$tcfg/claude-user-memory.md"
    printf '#!/bin/sh\necho hi\n' > "$tcfg/statusline.sh"

    mkdir -p "$TMP/bin"
    fifo="$TMP/orca.fifo"
    mkfifo "$fifo"
    port="$(free_port)"

    # A stub Orca that blocks on the fifo before it says anything: while it
    # is blocked, serve has been TOLD to start but has announced nothing,
    # so a settings.json seen now proves the sync ran before serve spoke,
    # not merely before the test happened to look.
    cat > "$TMP/bin/orca-ide" <<STUB
#!/usr/bin/env bash
port=""
prev=""
for arg in "\$@"; do
    [ "\$prev" = "--port" ] && port="\$arg"
    prev="\$arg"
done
cat "$fifo" > /dev/null
echo "Web client URL: http://127.0.0.1:\${port}/web-index.html#pairing=x"
exec sleep 300
STUB
    chmod +x "$TMP/bin/orca-ide"

    export HOME="$TMP/home"
    export PROJECT_DIR="$proj"
    export ORCA_PORT="$port"
    export ORCA_BIN="$TMP/bin/orca-ide"
    export ORCA_CLI=/bin/true
    export CLAUDE_ORCA_SKIP_SETUP=1
    export CLAUDE_ORCA_SKIP_BEADS=1
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=30

    start_entrypoint_bg

    settingsfile="$proj/.claude-dev/home/.claude/settings.json"
    urlfile="$proj/.claude-dev/run/orca-web-url.txt"
    if ! wait_for_file "$settingsfile" 30; then
        cat "$TMP/entrypoint.out" >&2 || true
        false
    fi

    run jq -r '.statusLine.command // empty' "$settingsfile"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ ! -e "$urlfile" ]

    echo go > "$fifo" &
    if ! wait_for_file "$urlfile" 30; then
        cat "$TMP/entrypoint.out" >&2 || true
        false
    fi
}

@test "a failing early config sync does not stop serve: orca-web-url.txt is still written" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" urlfile port
    make_project "$proj"
    # A template config directory that exists but is missing every file
    # config-sync.sh actually needs -- a real failure, not a stand-in.
    mkdir -p "$proj/.claude-dev/template/config"

    mkdir -p "$TMP/bin"
    port="$(free_port)"
    cat > "$TMP/bin/orca-ide" <<'STUB'
#!/usr/bin/env bash
port=""
prev=""
for arg in "$@"; do
    [ "$prev" = "--port" ] && port="$arg"
    prev="$arg"
done
echo "Web client URL: http://127.0.0.1:${port}/web-index.html#pairing=x"
exec sleep 300
STUB
    chmod +x "$TMP/bin/orca-ide"

    export HOME="$TMP/home"
    export PROJECT_DIR="$proj"
    export ORCA_PORT="$port"
    export ORCA_BIN="$TMP/bin/orca-ide"
    export ORCA_CLI=/bin/true
    export CLAUDE_ORCA_SKIP_SETUP=1
    export CLAUDE_ORCA_SKIP_BEADS=1
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=30

    start_entrypoint_bg

    urlfile="$proj/.claude-dev/run/orca-web-url.txt"
    if ! wait_for_file "$urlfile" 40; then
        cat "$TMP/entrypoint.out" >&2 || true
        false
    fi

    run cat "$urlfile"
    [ "$status" -eq 0 ]
    [ "$output" = "http://127.0.0.1:${port}/web-index.html#pairing=x" ]

    # Not silent: named as the early sync, and named as retried later --
    # exactly the pattern every other non-fatal step here follows.
    grep -qF 'early config sync' "$TMP/entrypoint.out"
    grep -qF 'will retry after the URL' "$TMP/entrypoint.out"
}

@test "the early config sync and the later provision.d/20-config-sync do not double-run destructively" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" tcfg fifo hashfile urlfile pdir port mtime1 mtime2
    make_project "$proj"
    tcfg="$proj/.claude-dev/template/config"
    mkdir -p "$tcfg/claude-commands"
    printf '{"hooks":{}}\n'        > "$tcfg/claude-settings.json"
    printf 'folder memory\n'       > "$tcfg/claude-user-memory.md"
    printf '#!/bin/sh\necho hi\n'  > "$tcfg/statusline.sh"
    printf 'marker\n'              > "$tcfg/claude-commands/marker.md"

    mkdir -p "$TMP/bin"
    fifo="$TMP/orca.fifo"
    mkfifo "$fifo"
    port="$(free_port)"
    cat > "$TMP/bin/orca-ide" <<STUB
#!/usr/bin/env bash
port=""
prev=""
for arg in "\$@"; do
    [ "\$prev" = "--port" ] && port="\$arg"
    prev="\$arg"
done
cat "$fifo" > /dev/null
echo "Web client URL: http://127.0.0.1:\${port}/web-index.html#pairing=x"
exec sleep 300
STUB
    chmod +x "$TMP/bin/orca-ide"

    export HOME="$TMP/home"
    export PROJECT_DIR="$proj"
    export ORCA_PORT="$port"
    export ORCA_BIN="$TMP/bin/orca-ide"
    export ORCA_CLI=/bin/true
    export CLAUDE_ORCA_SKIP_SETUP=1
    export CLAUDE_ORCA_SKIP_BEADS=1
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=30

    start_entrypoint_bg

    hashfile="$proj/.claude-dev/run/config-hash"
    urlfile="$proj/.claude-dev/run/orca-web-url.txt"
    if ! wait_for_file "$hashfile" 30; then
        cat "$TMP/entrypoint.out" >&2 || true
        false
    fi
    # The hash landed while Orca is still blocked on the fifo: it is the
    # EARLY sync's write, not provision.d's later one.
    [ ! -e "$urlfile" ]
    mtime1="$(stat -c %Y "$hashfile")"
    sleep 2

    echo go > "$fifo" &
    pdir="$proj/.claude-dev/run/provision"
    if ! wait_for_file "$pdir/20-config-sync.status" 60; then
        cat "$TMP/entrypoint.out" >&2 || true
        false
    fi
    [ "$(cat "$pdir/20-config-sync.status" | tr -d '[:space:]')" = "0" ]
    mtime2="$(stat -c %Y "$hashfile")"
    [ "$mtime1" = "$mtime2" ]
}

# --- provision.d (claude-orca-dbu.4) -------------------------------------
#
# The project-shaped work -- the toolchain verify, the config sync, the
# seeds, the tracker, the repo registration, the guard check -- is no
# longer in front of the thing that reports it. It runs from
# scripts/container/provision.d/ after serve has published its URL, and
# what it leaves behind is a status per step. The contract for the steps
# themselves is tests/provision.bats; this case is the wiring.

@test "entrypoint provisions the folder through provision.d after the web URL is published" {
    [ -x "$ENTRYPOINT" ]
    [ -d "$REPO_ROOT/scripts/container/provision.d" ]

    local proj="$TMP/project" port urlfile pdir step name
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin"
    # The same template-root pin as the stub-ORCA_BIN case: without it a
    # box that bakes /opt/claude-orca provisions from the IMAGE's frozen
    # provision.d, and a step added since that build has no status here.
    mkdir -p "$proj/.claude-dev/template/scripts/container"
    : > "$proj/.claude-dev/template/scripts/container/setup.sh"
    chmod +x "$proj/.claude-dev/template/scripts/container/setup.sh"
    port="$(free_port)"
    pdir="$proj/.claude-dev/run/provision"

    cat > "$TMP/bin/orca-ide" <<'STUB'
#!/usr/bin/env bash
port=""
prev=""
for arg in "$@"; do
    [ "$prev" = "--port" ] && port="$arg"
    prev="$arg"
done
echo "Web client URL: http://127.0.0.1:${port}/web-index.html#pairing=x"
exec sleep 300
STUB
    chmod +x "$TMP/bin/orca-ide"

    export HOME="$TMP/home"
    export PROJECT_DIR="$proj"
    export ORCA_PORT="$port"
    export ORCA_BIN="$TMP/bin/orca-ide"
    export ORCA_CLI=/bin/true
    export CLAUDE_ORCA_SKIP_SETUP=1
    export CLAUDE_ORCA_SKIP_BEADS=1
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=30

    start_entrypoint_bg
    urlfile="$proj/.claude-dev/run/orca-web-url.txt"
    if ! wait_for_file "$urlfile" 40; then
        cat "$TMP/entrypoint.out" >&2 || true
        false
    fi

    # Every real step ran and said how it went. The last one is what the
    # wait is on: they run in order, so a status for it means a status for
    # all of them.
    name="$(basename "$(ls -1 "$REPO_ROOT/scripts/container/provision.d" | sort | tail -1)")"
    if ! wait_for_file "$pdir/$name.status" 60; then
        cat "$TMP/entrypoint.out" >&2 || true
        ls -la "$pdir" >&2 || true
        false
    fi
    for step in "$REPO_ROOT"/scripts/container/provision.d/*; do
        [ -f "$pdir/$(basename "$step").status" ] \
            || { echo "no status for $(basename "$step")" >&3; false; }
    done

    # The URL beat all of it, and Orca is still serving.
    run cat "$urlfile"
    [ "$output" = "http://127.0.0.1:${port}/web-index.html#pairing=x" ]
}


# --- desktop Orca, S1 (claude-orca-8uo.2) --------------------------------
#
# `orca-ide --serve` announces two lines: the Web client URL and, on the
# very next line, `Pairing URL: orca://pair?code=<base64url json>`. The
# first is the browser handshake and has been written out since v3; the
# second is what a desktop Orca on the Mac needs to attach to this
# container's runtime. Both are credentials, so both are 0600 and owned by
# the agent. A serve that announces no pairing line at all (an older Orca)
# must still come up: the Mac half can decode the same URL out of the web
# URL's fragment, so the absence is a missing file, never a failed start.

@test "entrypoint writes run/orca-pairing-url.txt 0600 from the Pairing URL line" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" home="$TMP/home" port pairfile urlfile
    make_project "$proj"
    mkdir -p "$home" "$TMP/bin"
    port="$(free_port)"

    # A stub Orca speaking serve's two lines, in serve's own order.
    cat > "$TMP/bin/orca-ide" <<'STUB'
#!/usr/bin/env bash
port=""
prev=""
for arg in "$@"; do
    [ "$prev" = "--port" ] && port="$arg"
    prev="$arg"
done
echo "Orca server ready"
echo "Web client URL: http://127.0.0.1:${port}/web-index.html#pairing=orca%3A%2F%2Fpair%3Fcode%3DeyJ2IjoyfQ"
echo "Pairing URL: orca://pair?code=eyJ2IjoyfQ"
exec sleep 300
STUB
    chmod +x "$TMP/bin/orca-ide"

    cat > "$TMP/bin/orca" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$TMP/bin/orca"

    export HOME="$home"
    export PROJECT_DIR="$proj"
    export ORCA_PORT="$port"
    export ORCA_BIN="$TMP/bin/orca-ide"
    export ORCA_CLI="$TMP/bin/orca"
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=30

    start_entrypoint_bg

    pairfile="$proj/.claude-dev/run/orca-pairing-url.txt"
    if ! wait_for_file "$pairfile" 30; then
        cat "$TMP/entrypoint.out" >&2 || true
        false
    fi
    run cat "$pairfile"
    [ "$status" -eq 0 ]
    [ "$output" = "orca://pair?code=eyJ2IjoyfQ" ]
    [ "$(stat -c '%a' "$pairfile")" = "600" ]

    stop_entrypoint

    # An Orca that announces only the web URL: the pairing file is simply
    # absent, and the start is otherwise untouched.
    local proj2="$TMP/project2" home2="$TMP/home2" port2
    make_project "$proj2"
    mkdir -p "$home2"
    port2="$(free_port)"
    cat > "$TMP/bin/orca-nopair" <<'STUB'
#!/usr/bin/env bash
port=""
prev=""
for arg in "$@"; do
    [ "$prev" = "--port" ] && port="$arg"
    prev="$arg"
done
echo "Web client URL: http://127.0.0.1:${port}/web-index.html#pairing=x"
exec sleep 300
STUB
    chmod +x "$TMP/bin/orca-nopair"

    export EP_PGID_FILE="$TMP/ep2.pgid"
    export HOME="$home2"
    export PROJECT_DIR="$proj2"
    export ORCA_PORT="$port2"
    export ORCA_BIN="$TMP/bin/orca-nopair"
    setsid bash -c 'echo $$ > "$EP_PGID_FILE"; exec bash "$EP_SCRIPT"' \
        >"$TMP/entrypoint2.out" 2>&1 &

    urlfile="$proj2/.claude-dev/run/orca-web-url.txt"
    if ! wait_for_file "$urlfile" 30; then
        cat "$TMP/entrypoint2.out" >&2 || true
        false
    fi
    sleep 2
    [ ! -e "$proj2/.claude-dev/run/orca-pairing-url.txt" ]
    kill -TERM -"$(cat "$TMP/ep2.pgid")" 2>/dev/null || true
}

# --- managed settings (claude-orca-8a0.3) -------------------------------
#
# Claude Code reads /etc/claude-code/managed-settings.json as
# administrator policy; autoContinueAtUsageLimit there is what lets a
# dispatched worker sit out a usage-limit window and carry on instead of
# dying mid-slice. Only root can write that path, so the entrypoint does it
# BEFORE the privilege drop -- and skips silently when it is not root,
# which is how this unprivileged run reaches it through the override.

run_entrypoint_managed() {
    run env HOME="$1" PROJECT_DIR="$2" \
        CLAUDE_ORCA_MANAGED_SETTINGS="$3" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
}

@test "entrypoint writes managed settings with autoContinueAtUsageLimit when absent" {
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj home managed
    proj="$TMP/project"
    make_project "$proj"
    home="$proj/.claude-dev/home"
    managed="$TMP/managed/managed-settings.json"

    # Absent: written, with the key, readable by everyone (it is policy).
    run_entrypoint_managed "$home" "$proj" "$managed"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ORCA_BIN is not executable"* ]]
    [ -f "$managed" ]
    run jq -e '.autoContinueAtUsageLimit == true' "$managed"
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$managed")" = "644" ]

    # Present without the key: merged in, every other key kept.
    jq -n '{permissions: {allow: ["Bash"]}, apiKeyHelper: "/usr/local/bin/k"}' > "$managed"
    run_entrypoint_managed "$home" "$proj" "$managed"
    run jq -r '[.autoContinueAtUsageLimit, .permissions.allow[0], .apiKeyHelper]
        | map(tostring) | join(",")' "$managed"
    [ "$output" = "true,Bash,/usr/local/bin/k" ]

    # Present WITH the key: never overwritten -- the file is policy, and an
    # operator who turned it off meant it.
    jq -n '{autoContinueAtUsageLimit: false, permissions: {allow: ["Read"]}}' > "$managed"
    run_entrypoint_managed "$home" "$proj" "$managed"
    run jq -r '[.autoContinueAtUsageLimit, .permissions.allow[0]]
        | map(tostring) | join(",")' "$managed"
    [ "$output" = "false,Read" ]

    # Not JSON at all: left exactly as found, never replaced.
    printf 'not json at all\n' > "$managed"
    run_entrypoint_managed "$home" "$proj" "$managed"
    run cat "$managed"
    [ "$output" = "not json at all" ]

    # No override and no root: silent skip, and /etc keeps whatever it
    # had. The image bakes a managed-settings.json, so "the file must
    # not exist" is the wrong assertion on this box -- the right one is
    # "the run changed nothing": byte-identical when the file pre-exists,
    # still absent when it did not.
    if [ "$(id -u)" != "0" ]; then
        if [ -f /etc/claude-code/managed-settings.json ]; then
            cp /etc/claude-code/managed-settings.json "$TMP/etc-managed.before"
        fi
        run env HOME="$home" PROJECT_DIR="$proj" \
            ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
            CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
            bash "$ENTRYPOINT"
        [ "$status" -ne 0 ]
        [[ "$output" == *"ORCA_BIN is not executable"* ]]
        if [ -f /etc/claude-code/managed-settings.json ]; then
            cmp -s "$TMP/etc-managed.before" /etc/claude-code/managed-settings.json
        else
            [ ! -e /etc/claude-code/managed-settings.json ]
        fi
    fi
}


# --- where the real key actually lives (claude-orca-qa2.25) --------------
#
# The guard exists so that no agent terminal holds the real OpenRouter key.
# Handing it over in the environment or on a command line defeats that for
# anyone who goes looking: the guard runs as the SAME uid as every terminal
# in this container, so /proc/<guard>/environ and /proc/<guard>/cmdline are
# readable by `ps -ef | grep OPENROUTER` for the guard's whole uptime --
# hours -- while the agent's own env and config show nothing.
#
# The handover is a mode-600 file instead, read once and unlinked by the
# guard, so the window is the guard's startup rather than its lifetime.

@test "the real OpenRouter key is not in the guard process environment or argv, and the key file is gone once the guard is up" {
    [ -x "$ENTRYPOINT" ]
    [ -r /proc/self/cmdline ]

    local proj="$TMP/project" gport gpid tree steps
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin"
    write_env_dump_orca "$TMP/bin/orca-ide"
    gport="$(free_port)"

    # A step tree carrying the REAL guard step and nothing else: this case
    # is about where the key is, not about what the other steps do.
    tree="$TMP/tree/scripts/container"
    steps="$tree/provision.d"
    mkdir -p "$steps"
    ln -s "$REPO_ROOT/scripts/container/provision-lib.sh" "$tree/provision-lib.sh"
    ln -s "$REPO_ROOT/scripts/container/openrouter-guard.py" "$tree/openrouter-guard.py"
    ln -s "$REPO_ROOT/scripts/container/provision.d/70-openrouter-guard" \
        "$steps/70-openrouter-guard"

    export_guard_test_env "$proj" "$TMP/ud"
    export CLAUDE_ORCA_GUARD_PORT="$gport"
    export CLAUDE_ORCA_PROVISION_STEPS="$steps"
    export OPENROUTER_API_KEY="$REAL_KEY"
    # started, never allowed out
    export OPENROUTER_UPSTREAM="http://127.0.0.1:1"

    boot_entrypoint keep
    if ! wait_for_file "$proj/.claude-dev/run/provision/70-openrouter-guard.status" 60; then
        cat "$TMP/entrypoint.out" >&2 || true
        false
    fi

    # It did get a key: it is up, it is listening, and it is the guard.
    [ -s "$proj/.claude-dev/run/openrouter-guard.pid" ]
    gpid="$(cat "$proj/.claude-dev/run/openrouter-guard.pid")"
    kill -0 "$gpid"
    wait_tcp_port "$gport"
    grep -qF 'openrouter-guard: listening' "$proj/.claude-dev/run/openrouter-guard.log"

    # The two places a same-uid process reads a running process from.
    run bash -c "tr '\0' '\n' < /proc/$gpid/environ | grep -c -- '$REAL_KEY'"
    [ "$output" = "0" ]
    run bash -c "tr '\0' '\n' < /proc/$gpid/cmdline | grep -c -- '$REAL_KEY'"
    [ "$output" = "0" ]

    # The handover file is read once and unlinked, so nothing under run/
    # is still holding the key when the guard is serving.
    [ ! -e "$proj/.claude-dev/run/openrouter-guard.key" ]
    run bash -c "grep -rl -- '$REAL_KEY' '$proj/.claude-dev/run' | wc -l"
    [ "$output" = "0" ]

    # ... and no live process anywhere carries it on its command line.
    # The pattern comes from a file so that this check is not itself the
    # process that puts the key in an argv.
    printf '%s\n' "$REAL_KEY" > "$TMP/key.pat"
    run bash -c "ps -eo args= | grep -c -F -f $TMP/key.pat"
    [ "$output" = "0" ]
}

@test "the guard refuses to start without a key file and says so in its log" {
    local guard="$REPO_ROOT/scripts/container/openrouter-guard.py"
    local rund="$TMP/run" glog port
    mkdir -p "$rund"
    glog="$rund/openrouter-guard.log"
    port="$(free_port)"

    # Named but not there. A guard that cannot find its key file must not
    # quietly fall back to an environment every terminal here can read: it
    # refuses, and the refusal lands in the log the entrypoint points at.
    run bash -c "env -u OPENROUTER_API_KEY \
        CLAUDE_ORCA_GUARD_KEY_FILE='$TMP/no-such.key' \
        python3 '$guard' --port $port --run-dir '$rund' >>'$glog' 2>&1"
    [ "$status" -ne 0 ]
    grep -qF 'openrouter-guard' "$glog"
    grep -qF "$TMP/no-such.key" "$glog"

    # An empty key file is the same failure, not a guard with no key.
    : > "$TMP/empty.key"
    chmod 600 "$TMP/empty.key"
    : > "$glog"
    run bash -c "env -u OPENROUTER_API_KEY \
        CLAUDE_ORCA_GUARD_KEY_FILE='$TMP/empty.key' \
        python3 '$guard' --port $port --run-dir '$rund' >>'$glog' 2>&1"
    [ "$status" -ne 0 ]
    grep -qF "$TMP/empty.key" "$glog"

    # Nothing at all is a refusal too, and it names the key file rather
    # than pointing at an environment variable nobody should be setting.
    : > "$glog"
    run bash -c "env -u OPENROUTER_API_KEY \
        python3 '$guard' --port $port --run-dir '$rund' >>'$glog' 2>&1"
    [ "$status" -ne 0 ]
    grep -qF 'key file' "$glog"

    # And it never started: nothing is listening on that port.
    run python3 -c "import socket,sys
s = socket.socket()
s.settimeout(0.3)
sys.exit(0 if s.connect_ex(('127.0.0.1', $port)) == 0 else 1)"
    [ "$status" -ne 0 ]
}
