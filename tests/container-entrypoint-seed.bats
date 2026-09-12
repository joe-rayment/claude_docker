#!/usr/bin/env bats
#
# v3 S4 acceptance contract (claude-orca-qa2.5) -- FROZEN from RED-AT
# onward. The in-folder polish the entrypoint does before Orca serves: it
# seeds Orca's own state (the project's worktree base path inside the
# bind mount, the theme, the agent env) and initializes beads, both
# exactly once and never over a folder that already has them.
#
# Everything here runs against stubs -- a stub orca-ide, a stub orca CLI
# and a stub bd -- because what is under test is the entrypoint's
# decisions, not Orca. The real-Orca half of this slice is checked by
# hand against the extracted Linux AppImage and recorded on the bead.
#
# Deliberately self-contained: no `load` of tests/helpers, so the frozen
# contract cannot drift when a shared helper changes.
#
# See .claude/plans/container-v3.md S3 and scripts/container/seed-orca-state.sh.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/scripts/container/entrypoint.sh"

# Orca's Electron runtime binds unix sockets under the user-data-dir and
# AF_UNIX paths cap at ~108 bytes, so every fixture lives under a short
# /tmp prefix (same reason as tests/container-entrypoint.bats).
short_tmpdir() {
    mktemp -d /tmp/co-seed-XXXXXX
}

free_port() {
    python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

make_project() {
    local dir="$1"
    mkdir -p "$dir/.claude-dev/run" "$dir/.claude-dev/home"
    git init --quiet -b main "$dir" >/dev/null 2>&1
    git -C "$dir" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m init >/dev/null 2>&1
}

# A stub Orca that speaks serve's log lines and then stays up, a stub CLI
# that swallows `repo add`, and a stub bd that records its argv and makes
# the .beads marker a real `bd init` would make.
write_stubs() {
    mkdir -p "$TMP/bin"

    cat > "$TMP/bin/orca-ide" <<'STUB'
#!/usr/bin/env bash
port=""
prev=""
for arg in "$@"; do
    [ "$prev" = "--port" ] && port="$arg"
    prev="$arg"
done
echo "Orca server ready"
echo "Web client URL: http://127.0.0.1:${port}/web-index.html#pairing=x"
exec sleep 300
STUB

    cat > "$TMP/bin/orca" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

    cat > "$TMP/bin/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BD_STUB_LOG"
if [ "${1:-}" = "init" ]; then
    prefix=""
    while [ $# -gt 0 ]; do
        [ "$1" = "--prefix" ] && { prefix="${2:-}"; }
        shift
    done
    mkdir -p "$PWD/.beads"
    printf '%s\n' "$prefix" > "$PWD/.beads/stub-prefix"
fi
exit 0
STUB

    chmod +x "$TMP/bin/orca-ide" "$TMP/bin/orca" "$TMP/bin/bd"
}

# One entrypoint run in its own process group, backgrounded, with the
# stub toolchain on PATH. $1 is a label used for the pgid/log files; the
# caller exports whatever else it wants first.
#
# CLAUDE_ORCA_SKIP_SETUP=1 for the same reason the toolchain is stubbed:
# what is under test is the seeding the entrypoint does, and nothing here
# asserts anything about setup.sh. Without it the run reached the real
# setup.sh, which refuses to install apt packages as anyone but root
# ("error: must run as root (phase: base)") and took the entrypoint down
# with it before a single seed was written -- so the case could only ever
# pass as root, for a reason it does not measure. It is the idiom every
# other entrypoint-driving file already uses (tests/container-
# entrypoint.bats, tests/first-start-dns.bats).
start_ep() {
    local label="$1" proj="$2" home="$3"
    mkdir -p "$home"
    EP_PGID_FILE="$TMP/$label.pgid" \
    EP_SCRIPT="$ENTRYPOINT" \
    HOME="$home" \
    PROJECT_DIR="$proj" \
    ORCA_BIN="$TMP/bin/orca-ide" \
    ORCA_CLI="$TMP/bin/orca" \
    PATH="$TMP/bin:$PATH" \
    BD_STUB_LOG="$TMP/bd.log" \
    CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
    CLAUDE_ORCA_WEBURL_TIMEOUT=30 \
    CLAUDE_ORCA_SKIP_SETUP=1 \
    ORCA_PORT="$(free_port)" \
    CLAUDE_ORCA_THEME="${EP_THEME:-}" \
    CLAUDE_ORCA_PROJECT_NAME="${EP_PROJECT_NAME:-}" \
        setsid bash -c 'echo $$ > "$EP_PGID_FILE"; exec bash "$EP_SCRIPT"' \
        >"$TMP/$label.out" 2>&1 &

    local urlfile="$proj/.claude-dev/run/orca-web-url.txt" i=0
    while [ "$i" -lt 60 ]; do
        [ -s "$urlfile" ] && return 0
        sleep 0.5
        i=$((i + 1))
    done
    echo "--- $label stdout ---" >&2
    cat "$TMP/$label.out" >&2 || true
    return 1
}

stop_all() {
    local f pgid
    for f in "$TMP"/*.pgid; do
        [ -f "$f" ] || continue
        pgid="$(cat "$f")"
        kill -TERM -"$pgid" 2>/dev/null || true
    done
    sleep 0.5
    for f in "$TMP"/*.pgid; do
        [ -f "$f" ] || continue
        pgid="$(cat "$f")"
        kill -KILL -"$pgid" 2>/dev/null || true
    done
}

setup() {
    TMP="$(short_tmpdir)"
    export TMP
    : > "$TMP/bd.log"
    write_stubs
}

teardown() {
    stop_all
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    return 0
}

@test "entrypoint seeds Orca global settings with the in-folder worktree base path and the dark theme only when absent, and claude-orca.json theme selects light or system" {
    [ -x "$ENTRYPOINT" ]

    # Orca keeps its global state per profile, under the --user-data-dir
    # the entrypoint passes; `local-default` is the profile it creates on
    # a first run.
    local data_rel=".config/orca/profiles/local-default/orca-data.json"

    # --- 1. a fresh folder gets the seed ---------------------------------
    local proj="$TMP/p1" home="$TMP/h1" data
    make_project "$proj"
    EP_THEME="" EP_PROJECT_NAME="" start_ep p1 "$proj" "$home"

    data="$home/$data_rel"
    [ -f "$data" ]
    run jq -r '.settings.theme' "$data"
    [ "$status" -eq 0 ]
    [ "$output" = "dark" ]

    # The worktree base path is per-repo, and it points inside the folder
    # so worktrees survive the VM.
    run jq -r '.repos[0].path' "$data"
    [ "$output" = "$proj" ]
    run jq -r '.repos[0].worktreeBasePath' "$data"
    [ "$output" = "$proj/.orca-worktrees" ]

    # Agents Orca launches learn where the folder root is.
    run jq -r '.settings.agentDefaultEnv.claude.CLAUDE_ORCA_ROOT' "$data"
    [ "$output" = "$proj" ]

    # ...and the tracker exists, from exactly one `bd init`, prefixed with
    # the folder name when nothing else names it.
    [ -d "$proj/.beads" ]
    run grep -c '^init --prefix p1$' "$TMP/bd.log"
    [ "$output" = "1" ]
    run grep -c '^init' "$TMP/bd.log"
    [ "$output" = "1" ]

    # --- 2. a folder that already has both is left alone -----------------
    local proj2="$TMP/p2" home2="$TMP/h2" data2 before after
    make_project "$proj2"
    mkdir -p "$proj2/.beads" "$home2/.config/orca/profiles/local-default"
    data2="$home2/$data_rel"
    printf '%s' '{"settings":{"theme":"light"}}' > "$data2"
    before="$(md5sum < "$data2")"
    : > "$TMP/bd.log"

    EP_THEME="" EP_PROJECT_NAME="" start_ep p2 "$proj2" "$home2"

    after="$(md5sum < "$data2")"
    [ "$before" = "$after" ]
    run grep -q 'orca state present, not seeded' "$TMP/p2.out"
    [ "$status" -eq 0 ]

    # bd never INITIALIZES a folder that already has beads. This read
    # "bd is never run at all" when the only bd call seed-project.sh made
    # was `init`; 45c41a1 added quiet_bd_metrics, an unconditional
    # `bd metrics off` that silences the once-per-config metrics banner
    # and runs whether or not the tracker already exists. So the log is
    # pinned to exactly that one line, which is both the narrowest
    # statement of what "left alone" means here and stricter than a bare
    # count: a second `bd init` would show up as an extra line AND as a
    # line that is not `metrics off`.
    run grep -c '^init' "$TMP/bd.log"
    [ "$(printf '%s' "$output" | tr -d '[:space:]')" = "0" ]
    run grep -cv '^metrics off$' "$TMP/bd.log"
    [ "$(printf '%s' "$output" | tr -d '[:space:]')" = "0" ]

    # --- 3. claude-orca.json's theme rides in and wins -------------------
    local proj3="$TMP/p3" home3="$TMP/h3" data3
    make_project "$proj3"
    : > "$TMP/bd.log"

    EP_THEME="system" EP_PROJECT_NAME="my-proj" start_ep p3 "$proj3" "$home3"

    data3="$home3/$data_rel"
    [ -f "$data3" ]
    run jq -r '.settings.theme' "$data3"
    [ "$output" = "system" ]
    run jq -r '.repos[0].worktreeBasePath' "$data3"
    [ "$output" = "$proj3/.orca-worktrees" ]

    # CLAUDE_ORCA_PROJECT_NAME is the beads prefix the Mac side derives.
    run grep -c '^init --prefix my-proj$' "$TMP/bd.log"
    [ "$output" = "1" ]

    stop_all
}
