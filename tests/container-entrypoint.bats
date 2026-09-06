#!/usr/bin/env bats
#
# v3 S1 acceptance contract (claude-orca-qa2.1) -- FROZEN from RED-AT
# onward. The VM half of v3: the container image, the in-VM entrypoint
# that brings Orca up headless in serve mode, and the CI workflow that
# builds and pushes the image.
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
IMAGE_WORKFLOW="$REPO_ROOT/.github/workflows/image.yml"

# The extracted AppImage (squashfs-root/orca-ide). Overridable so the same
# contract runs wherever the extraction lives, but never optional.
ORCA_EXTRACT_ROOT="${CLAUDE_ORCA_APPIMAGE_ROOT:-/tmp/claude-1000/-workspace/0bcf8495-68f6-4270-aefc-7f12a96464a8/scratchpad/orca-extract/squashfs-root}"
REAL_ORCA_BIN="$ORCA_EXTRACT_ROOT/orca-ide"

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
    TMP="$(short_tmpdir)"
    export TMP
    export EP_PGID_FILE="$TMP/ep.pgid"
    export EP_SCRIPT="$ENTRYPOINT"
}

teardown() {
    stop_entrypoint
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

    # A failing setup is fatal, and says where to look.
    run env HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SETUP="$TMP/setup.sh" \
        CLAUDE_ORCA_STUB_SETUP_STATUS=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        bash "$ENTRYPOINT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"setup.sh failed"* ]]
    [[ "$output" == *"$proj/.claude-dev/run/setup.log"* ]]
    [[ "$output" != *"ORCA_BIN is not executable"* ]]
}

@test "entrypoint starts Orca serve headless from ORCA_BIN, writes run/orca-web-url.txt with the pairing URL and run/port, and the URL serves Orca Web" {
    # Not a skip: the contract is that this is checked against the real
    # Orca Linux binary, so a missing extraction fails loudly.
    if [ ! -x "$REAL_ORCA_BIN" ]; then
        echo "extracted Orca Linux binary not found at $REAL_ORCA_BIN" >&2
        echo "run: cd \$(dirname $ORCA_EXTRACT_ROOT) && ./orca-linux-arm64.AppImage --appimage-extract" >&2
        false
    fi
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
    run wc -l < "$TMP/cli.log"
    [ "$(printf '%s' "$output" | tr -d '[:space:]')" = "1" ]

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

@test "Dockerfile, setup.sh, smoke.sh and image.yml exist, setup.sh pins Orca 1.4.197 and the Claude Code version from install-claude.sh, and image.yml pushes to ghcr.io/joe-rayment/claude_orca" {
    [ -f "$DOCKERFILE" ]
    [ -x "$SETUP" ]
    [ -x "$SMOKE" ]
    [ -f "$IMAGE_WORKFLOW" ]
    [ -x "$ENTRYPOINT" ]

    # The Orca release the image installs, pinned -- never 'latest'.
    run grep -c '1\.4\.197' "$SETUP"
    [ "$status" -eq 0 ]
    [ "$output" != "0" ]
    # claude-orca-qa2.6 re-pointed this one assertion: the AppImage cannot
    # be extracted under QEMU, so the image installs the release .deb.
    run grep -qE 'orca-ide_\$\{ORCA_VERSION\}_\$\{[A-Za-z_][A-Za-z0-9_]*\}\.deb' "$SETUP"
    [ "$status" -eq 0 ]

    # ONE Claude Code pin in this repo: scripts/install-claude.sh's.
    local pin
    pin="$(sed -n 's/^CLAUDE_CODE_VERSION="\([^"]*\)".*/\1/p' \
        "$REPO_ROOT/scripts/install-claude.sh" | head -1)"
    [ -n "$pin" ]
    run grep -qF "$pin" "$SETUP"
    [ "$status" -eq 0 ]

    # The image runs the entrypoint under tini.
    run grep -q 'scripts/container/entrypoint.sh' "$DOCKERFILE"
    [ "$status" -eq 0 ]

    # CI publishes to the project's GHCR repo.
    run grep -q 'ghcr.io/joe-rayment/claude_orca' "$IMAGE_WORKFLOW"
    [ "$status" -eq 0 ]
    run grep -q 'packages: write' "$IMAGE_WORKFLOW"
    [ "$status" -eq 0 ]
    run grep -q 'smoke.sh' "$IMAGE_WORKFLOW"
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
    run env HOME="$home2" PROJECT_DIR="$proj2" \
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
    # image has only the folder's own mounted clone. Whichever this box is,
    # the entrypoint must name the one that is there.
    if [ -d /opt/claude-orca ]; then
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
