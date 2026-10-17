#!/usr/bin/env bash
#
# mac-e2e.sh -- the whole product, on the platform it is for, with a clock.
#
# WHY THIS EXISTS. Everything else in tests/ drives stubs: helpers/setup.bash
# puts a fake `docker`, `open`, `gh` and `uname` on PATH, so the
# bats suite (tests/*.bats) proves the launcher's LOGIC and nothing about a Mac. There is
# no CI in this repo any more (.github/workflows/image.yml, the one job
# that ever drove a real daemon on macOS, via colima, is gone -- it never
# passed anyway), so nothing runs this suite, stubbed or not, without a
# human asking for it. The result, through the first week of September
# 2026: changes to the Mac side were reported as fixed without anyone
# having run them, four days in a row, and the only person who ever
# actually ran the product was its owner.
#
# So this script runs the real thing: the real bootstrap.sh, into a real
# throwaway folder, building or reusing a real image, starting a real
# container on the real Docker daemon, and logging in to its sshd with the
# folder's own key and host key -- then it asks the container what it looks
# like from the inside, recreates it, updates it, and tears it down. Every check is a row in a table
# with the seconds it took. Nothing here is stubbed, and nothing here is
# allowed to pass by being skipped.
#
#   tests/mac-e2e.sh                     # a throwaway folder, real image, teardown
#   tests/mac-e2e.sh --keep              # leave the folder and container up
#   tests/mac-e2e.sh --image REF         # a locally built image (no registry)
#   tests/mac-e2e.sh --folder DIR        # check a folder that already exists
#   tests/mac-e2e.sh --dirty-ok          # allow an uncommitted working tree
#
# THE CLONE IS OF HEAD. bootstrap.sh clones the template, and a `git clone`
# of a local path takes the committed state, never the working tree. A
# dirty tree therefore tests something that is not what you just edited,
# so this refuses to run on one unless --dirty-ok says otherwise.
#
# bash 3.2 clean (macOS ships 3.2.57 and this must run on a stock Mac):
# no arrays, none of the bash-4 builtins that read a file into one, none
# of its case-conversion expansions, and no append onto an empty array
# under set -u -- scripts/lint-bash32.sh names each one and is a grep, so
# this paragraph spells them out rather than quoting them. Results
# accumulate in a file rather than an array for the same reason.
#
# THE SSH ROWS (section 3) are the only evidence anywhere that the Mac's
# own `ssh` reaches the container's sshd: the bats suite stubs ssh, so it
# proves the launcher's argv and nothing about a real login. They check
# run/sshd.ready and run/port, then `ssh -F state/ssh/config <alias> pwd`
# with the host key verified (and refused when it is not known), then the
# doctor's sshd / ssh master / ssh key auth rows. One more row runs
# `./claude-dev pane` itself under macOS `script -q /dev/null` (a pty, as a
# terminal tab gives it) and expects the in-container /workspace/<name> from
# a typed `pwd`. Section 5b plants an old
# <container>-orca-state volume (what a folder from before the ssh panes
# left behind) and checks that `./claude-dev --update` removes it.
#

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

KEEP=0
DIRTY_OK=0
IMAGE_REF=""
EXISTING_FOLDER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --keep)      KEEP=1 ;;
        --dirty-ok)  DIRTY_OK=1 ;;
        --image)     IMAGE_REF="${2:-}"; shift ;;
        --folder)    EXISTING_FOLDER="${2:-}"; shift ;;
        -h|--help)   sed -n '3,35p' "$0"; exit 0 ;;
        *)           echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# --- the results table --------------------------------------------------

LOG_DIR="$REPO_ROOT/tests/.cache"
mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$LOG_DIR/mac-e2e-$STAMP.log"
RESULTS="$LOG_DIR/mac-e2e-$STAMP.rows"
: > "$RUN_LOG"
: > "$RESULTS"

FAILED=0

# row <status> <seconds|-> <name> <detail>
row() {
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"
    if [ "$1" = "FAIL" ]; then FAILED=$((FAILED + 1)); fi
    printf '  [%-4s] %-52s %s\n' "$1" "$3" "$4"
}

# check <name> <command...> -- ok when the command exits 0. Its output goes
# to the run log, and its last line becomes the detail on failure, because
# with docker and curl the reason IS the diagnosis.
check() {
    local name="$1" out rc=0 t0 t1
    shift
    t0="$(date +%s)"
    out="$("$@" 2>&1)" || rc=$?
    t1="$(date +%s)"
    {
        printf '===== %s (exit %s)\n' "$name" "$rc"
        printf '%s\n' "$out"
    } >> "$RUN_LOG"
    if [ "$rc" -eq 0 ]; then
        row ok "$((t1 - t0))" "$name" ""
    else
        row FAIL "$((t1 - t0))" "$name" "$(printf '%s' "$out" | tail -1 | cut -c1-90)"
    fi
    return 0
}

# check_detail <name> <command...> -- check(), except the command's last
# line becomes the row's detail when it PASSES too. For rows whose value
# IS what they print (an app version, an environment id, the path a remote
# runtime lists back), because this table is the evidence that gets pasted
# into the bead, and "ok" alone would prove nothing about which app or
# which runtime answered.
check_detail() {
    local name="$1" out rc=0 t0 t1
    shift
    t0="$(date +%s)"
    out="$("$@" 2>&1)" || rc=$?
    t1="$(date +%s)"
    {
        printf '===== %s (exit %s)\n' "$name" "$rc"
        printf '%s\n' "$out"
    } >> "$RUN_LOG"
    if [ "$rc" -eq 0 ]; then
        row ok "$((t1 - t0))" "$name" "$(printf '%s' "$out" | tail -1 | cut -c1-90)"
    else
        row FAIL "$((t1 - t0))" "$name" "$(printf '%s' "$out" | tail -1 | cut -c1-90)"
    fi
    return 0
}

note() { printf '\n== %s\n' "$*"; printf '\n===== %s\n' "$*" >> "$RUN_LOG"; }

# --- refuse to run on the wrong box, or on a tree that is not what it says

if [ "$(uname -s)" != "Darwin" ]; then
    echo "mac-e2e: this is the MAC check and this box is $(uname -s)." >&2
    echo "  There is nothing to substitute: a Linux run proves the Linux path," >&2
    echo "  which the stubbed bats suite already covers." >&2
    exit 2
fi

if ! docker info >/dev/null 2>&1; then
    echo "mac-e2e: the Docker daemon is not answering ('docker info' failed)." >&2
    echo "  Start Docker Desktop:  open -a Docker" >&2
    exit 2
fi

if [ "$DIRTY_OK" -eq 0 ] && [ -z "$EXISTING_FOLDER" ]; then
    # .beads/ is excluded: bd re-exports issues.jsonl on almost every
    # command, so a tracker-only diff is not a source change and must not
    # stand between a person and this check.
    dirty="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no 2>/dev/null \
        | grep -v ' \.beads/')"
    if [ -n "$dirty" ]; then
        echo "mac-e2e: the working tree has uncommitted changes." >&2
        echo "  bootstrap.sh CLONES the template, and a clone takes HEAD -- so this" >&2
        echo "  run would test the last commit, not what you just edited." >&2
        echo "  Commit first, or re-run with --dirty-ok to test HEAD deliberately." >&2
        printf '%s\n' "$dirty" | sed 's/^/    /' >&2
        exit 2
    fi
fi

# --- the folder under test ----------------------------------------------

TMP_ROOT=""
if [ -n "$EXISTING_FOLDER" ]; then
    [ -d "$EXISTING_FOLDER" ] || { echo "mac-e2e: no such directory: $EXISTING_FOLDER" >&2; exit 2; }
    PROJECT="$(cd "$EXISTING_FOLDER" && pwd -P)"
    [ -f "$PROJECT/.claude-dev/claude-orca.json" ] \
        || { echo "mac-e2e: $PROJECT is not registered (no .claude-dev/claude-orca.json)" >&2; exit 2; }
else
    TMP_ROOT="$(mktemp -d /tmp/orca-e2e.XXXXXX)"
    PROJECT="$TMP_ROOT/e2e-$$"
fi

# derive_project_name() in scripts/launcher.sh, reproduced: the container
# name has to be predictable from out here.
project_name() {
    local n
    n="$(basename "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' \
        | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')"
    [ -n "$n" ] || n="project"
    printf '%s\n' "$n"
}
CNAME="claude-orca-$(project_name "$PROJECT")"
HOST="$PROJECT/.claude-dev"

cleanup() {
    if [ "$KEEP" -eq 1 ] || [ -n "$EXISTING_FOLDER" ]; then
        return 0
    fi
    docker rm -f "$CNAME" >/dev/null 2>&1
    # legacy: the old Orca state volume, planted by section 5b/6 below
    docker volume rm "$CNAME-orca-state" >/dev/null 2>&1
    [ -n "$TMP_ROOT" ] && rm -rf "$TMP_ROOT"
    return 0
}
trap 'cleanup' EXIT

echo "mac-e2e: $(sw_vers -productName) $(sw_vers -productVersion), docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
echo "         repo   $REPO_ROOT @ $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)"
echo "         folder $PROJECT"
echo "         log    $RUN_LOG"

export CLAUDE_ORCA_OPEN=0
if [ -n "$IMAGE_REF" ]; then
    export CLAUDE_ORCA_IMAGE="$IMAGE_REF"
    echo "         image  $IMAGE_REF (local; no registry is contacted)"
fi


# =========================================================================
# 1. bootstrap (steps 1-3 of the pipeline: preflight, register, image)
# =========================================================================

BOOTSTRAP_SECS="-"
if [ -z "$EXISTING_FOLDER" ]; then
    note "bootstrap: the real one-liner's work, against a throwaway folder"
    mkdir -p "$PROJECT"
    git init -q -b main "$PROJECT" >/dev/null 2>&1
    git -C "$PROJECT" -c user.email=e2e@example.com -c user.name=e2e \
        commit -q --allow-empty -m e2e >/dev/null 2>&1

    # A leftover container from an interrupted run would make every later
    # row lie about which container it is looking at.
    docker rm -f "$CNAME" >/dev/null 2>&1
    # legacy: an old Orca state volume left by an interrupted run
    docker volume rm "$CNAME-orca-state" >/dev/null 2>&1

    t0="$(date +%s)"
    CLAUDE_ORCA_TEMPLATE_URL="$REPO_ROOT" \
        bash "$REPO_ROOT/bootstrap.sh" "$PROJECT" >> "$RUN_LOG" 2>&1
    rc=$?
    t1="$(date +%s)"
    BOOTSTRAP_SECS="$((t1 - t0))"
    if [ "$rc" -eq 0 ]; then
        row ok "$BOOTSTRAP_SECS" "bootstrap.sh ran to completion" ""
    else
        row FAIL "$BOOTSTRAP_SECS" "bootstrap.sh ran to completion" "exit $rc -- see $RUN_LOG"
        tail -25 "$RUN_LOG" | sed 's/^/    /'
    fi
else
    note "existing folder: skipping bootstrap"
fi

# =========================================================================
# 2. the layout bootstrap leaves on the Mac (pipeline step 2)
# =========================================================================

note "layout: what the Mac side is allowed to have created"

layout_dirs() { [ -d "$HOST/template" ] && [ -d "$HOST/bin" ] && [ -d "$HOST/home" ]; }
layout_clone() { [ -d "$HOST/template/.git" ]; }
layout_symlink() {
    [ -L "$HOST/bin/claude-dev" ] || return 1
    [ "$(readlink "$HOST/bin/claude-dev")" = "../template/scripts/launcher.sh" ] || return 1
    [ -x "$HOST/bin/claude-dev" ]
}
layout_stub() { [ -x "$PROJECT/claude-dev" ]; }
layout_json() {
    jq -e '.version == 3' "$HOST/claude-orca.json" >/dev/null || return 1
    local port
    port="$(jq -r '.port' "$HOST/claude-orca.json")"
    case "$port" in ''|*[!0-9]*) echo "port is '$port'"; return 1 ;; esac
    [ "$port" -ge 6768 ] || { echo "port $port below the 6768 base"; return 1; }
    [ "$(cat "$HOST/run/port")" = "$port" ] || { echo "run/port disagrees"; return 1; }
    printf 'port %s\n' "$port"
}
layout_nothing_outside() {
    [ ! -e "$HOME/.claude-dev" ] || { echo "$HOME/.claude-dev was created"; return 1; }
}

check "layout: .claude-dev/{template,bin,home}"      layout_dirs
check "layout: the template is a git clone"          layout_clone
check "layout: bin/claude-dev -> ../template/..."    layout_symlink
check "layout: the ./claude-dev stub is executable"  layout_stub
check "layout: claude-orca.json v3 and the port"     layout_json
check "layout: nothing created outside the folder"   layout_nothing_outside

# =========================================================================
# 3. the container, and sshd answering on the published port (steps 4, 7)
# =========================================================================

note "container: what the Mac started, and whether sshd answers"

PORT="$(cat "$HOST/run/port" 2>/dev/null || echo "")"
READY_FILE="$HOST/run/sshd.ready"
SSH_BIN="${CLAUDE_ORCA_SSH:-ssh}"
SSH_CFG="$HOST/state/ssh/config"
# ssh_host_alias() in scripts/launcher.sh, reproduced.
SSH_ALIAS="claude-dev-$(project_name "$PROJECT")"
DOCTOR_OUT="$LOG_DIR/mac-e2e-$STAMP.doctor.txt"

c_running() {
    local s
    s="$(docker inspect -f '{{.State.Status}}' "$CNAME" 2>&1)" || { echo "$s"; return 1; }
    [ "$s" = "running" ] || { echo "$CNAME is '$s'"; return 1; }
    printf '%s\n' "$CNAME"
}
c_image() { docker inspect -f '{{.Config.Image}}' "$CNAME"; }
c_loopback() {
    local p
    p="$(docker inspect -f '{{json .NetworkSettings.Ports}}' "$CNAME")"
    case "$p" in *127.0.0.1*) printf '%s\n' "$p" ;; *) echo "not bound to loopback: $p"; return 1 ;; esac
}
# run/port is the port the container publishes on loopback AND the port
# sshd listens on inside (launcher.sh publishes -p 127.0.0.1:P:P).
c_port_published() {
    local hp
    [ -n "$PORT" ] || { echo "no $HOST/run/port"; return 1; }
    hp="$(docker inspect -f "{{(index (index .NetworkSettings.Ports \"$PORT/tcp\") 0).HostPort}}" "$CNAME" 2>&1)" \
        || { echo "$hp"; return 1; }
    [ "$hp" = "$PORT" ] || { echo "run/port is $PORT, docker publishes '$hp'"; return 1; }
    printf 'port %s\n' "$PORT"
}
# run/sshd.ready is the handshake the container writes once sshd listens:
# `port=N` and `host_key_sha256=SHA256:...`. The fingerprint has to be the
# one in this folder's state/ssh, or the Mac would refuse the connection.
c_sshd_ready() {
    local p fp want
    [ -s "$READY_FILE" ] || { echo "no $READY_FILE"; return 1; }
    p="$(sed -n 's/^port=//p' "$READY_FILE" | head -1)"
    [ "$p" = "$PORT" ] || { echo "sshd.ready says port '$p', run/port says '$PORT'"; return 1; }
    fp="$(sed -n 's/^host_key_sha256=//p' "$READY_FILE" | head -1)"
    want="$(ssh-keygen -lf "$HOST/state/ssh/host_ed25519.pub" 2>/dev/null | awk 'NR == 1 { print $2 }')"
    [ -n "$want" ] && [ "$fp" = "$want" ] \
        || { echo "host key: the container presents '${fp:-none}', the folder's is '${want:-unreadable}'"; return 1; }
    printf 'port %s, host key %s\n' "$p" "$fp"
}
# The login a pane does, minus the multiplexing: ControlPath=none makes
# this connection do its own host key check instead of riding a master
# that did it earlier. The config says StrictHostKeyChecking yes and
# known_hosts is keyed by the alias, so a pass means the key was VERIFIED.
c_ssh_pwd() {
    local out
    out="$("$SSH_BIN" -F "$SSH_CFG" -o ControlMaster=no -o ControlPath=none \
        -o BatchMode=yes -o ConnectTimeout=15 "$SSH_ALIAS" pwd 2>&1 | tr -d '\r')" \
        || { printf '%s\n' "$out" | tail -1; return 1; }
    out="$(printf '%s\n' "$out" | tail -1)"
    [ "$out" = "$GUEST_DIR" ] || { echo "ssh pwd printed '$out', want $GUEST_DIR"; return 1; }
    printf '%s (host key verified)\n' "$out"
}
# ... and the verification is real: with no known_hosts entry the same
# login must be REFUSED, not trusted on first use.
c_ssh_refuses_unknown() {
    local kh out
    kh="$LOG_DIR/mac-e2e-$STAMP.empty_known_hosts"
    : > "$kh"
    if out="$("$SSH_BIN" -F "$SSH_CFG" -o ControlMaster=no -o ControlPath=none \
            -o UserKnownHostsFile="$kh" -o BatchMode=yes -o ConnectTimeout=15 \
            "$SSH_ALIAS" pwd 2>&1)"; then
        echo "logged in with an empty known_hosts: $out"
        return 1
    fi
    printf 'refused: %s\n' "$(printf '%s' "$out" | tail -1 | cut -c1-70)"
}
# One login through the config as it stands starts the folder's
# ControlMaster, which is what the doctor's "ssh master" row looks for.
c_ssh_master() {
    "$SSH_BIN" -F "$SSH_CFG" -o BatchMode=yes -o ConnectTimeout=15 "$SSH_ALIAS" true || return 1
    "$SSH_BIN" -F "$SSH_CFG" -O check "$SSH_ALIAS" 2>&1
}
# The pane itself, the way a terminal tab runs it. `./claude-dev pane` ends in
# `exec ssh -tt <alias>`, so it needs a terminal: macOS `script -q /dev/null`
# supplies a pty, and a delayed writer types `pwd` then `exit` into it (the
# delay lets the login finish; the pty queues anything typed early). Only the
# in-container path on a line of its own counts -- the prompt may print the
# path too -- and the "NOT sandboxed" banner (a Mac shell, which the pane falls
# back to when it cannot reach the container) fails the row outright. A
# watchdog stands in for `timeout`, which a stock Mac does not have.
c_pane_pwd() {
    local out_file pid i
    out_file="$LOG_DIR/mac-e2e-$STAMP.pane.txt"
    : > "$out_file"
    ( sleep 3; printf 'pwd\r'; sleep 2; printf 'exit\r'; sleep 1 ) \
        | ( cd "$PROJECT" && script -q /dev/null ./claude-dev pane ) > "$out_file" 2>&1 &
    pid=$!
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 90 ]; do
        sleep 1
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        echo "the pane was still running after 90 s (output in $out_file)"
        return 1
    fi
    wait "$pid" 2>/dev/null
    tr -d '\r' < "$out_file" > "$out_file.clean"
    if grep -q 'NOT sandboxed' "$out_file.clean"; then
        echo "the pane fell back to a Mac shell (NOT sandboxed)"
        return 1
    fi
    grep -qx -- "$GUEST_DIR" "$out_file.clean" \
        || { echo "pane pwd: no line '$GUEST_DIR' in $out_file"; return 1; }
    printf '%s (a real pane, on a pty)\n' "$GUEST_DIR"
}
# A doctor row by name, from the one doctor run in $DOCTOR_OUT. Only the
# [ok] form passes: n/a (master not running) and FAIL both fail here.
doctor_row_ok() {
    local line
    line="$(grep -E "^  \[ok +\] $1 " "$DOCTOR_OUT" | head -1)"
    [ -n "$line" ] || {
        echo "doctor has no ok row '$1': $(grep -E "^  \[[^]]*\] $1 " "$DOCTOR_OUT" | head -1 | cut -c1-80)"
        return 1
    }
    printf '%s\n' "$line" | sed 's/^  \[[^]]*\] *//'
}

check "container: running"                       c_running
check "container: image it runs"                 c_image
check "container: port published on 127.0.0.1"   c_loopback
check "run/port is the published port"           c_port_published
check "handshake: run/sshd.ready and its host key" c_sshd_ready

# =========================================================================
# 4. what the container looks like FROM THE INSIDE (steps 5, 6, and the
#    boundary the whole design rests on)
# =========================================================================

note "inside: the boundary, the toolchain and the tracker"

# The guest path the project is mounted at. Read from the container rather
# than assumed, so this file keeps working across the /workspace move.
GUEST_DIR="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CNAME" 2>/dev/null \
    | sed -n 's/^PROJECT_DIR=//p' | head -1)"
[ -n "$GUEST_DIR" ] || GUEST_DIR="$PROJECT"

inc() { docker exec -u agent -e HOME=/home/agent "$CNAME" "$@"; }
inc_wd() { local wd="$1"; shift; docker exec -u agent -e HOME=/home/agent -w "$wd" "$CNAME" "$@"; }

# setup.sh --check is the whole toolchain answering for itself. Its exit
# status cannot be the gate: the entrypoint remaps `agent` to the Mac's uid
# (501), so the uid row always reports FAIL in a running container. That
# one row is allowed; nothing else is.
in_toolchain_shape() {
    local out notok
    out="$(docker exec "$CNAME" /opt/claude-orca/scripts/container/setup.sh --check 2>&1)"
    printf '%s\n' "$out" >> "$RUN_LOG"
    notok="$(printf '%s\n' "$out" | grep -v '^\[check\] ok' | grep . )"
    if [ -z "$notok" ]; then printf 'every row ok\n'; return 0; fi
    if [ "$(printf '%s\n' "$notok" | grep -c .)" = "1" ] \
       && printf '%s' "$notok" | grep -q 'agent user: want uid'; then
        printf 'every row ok but the remapped uid (expected)\n'
        return 0
    fi
    printf '%s\n' "$notok"
    return 1
}

in_no_mac_paths() {
    # The boundary a person can SEE. A project mounted at its own Mac path
    # makes the container spell out its owner's home directory and folder
    # tree, which is what made a working sandbox look broken to its owner
    # on 2026-09-07.
    #
    # Asserted on the guest path, not on /Users: a throwaway folder under
    # /tmp has no /Users inside either, so that check would pass while the
    # thing it is about is still wrong.
    case "$GUEST_DIR" in
        /workspace/*) ;;
        *) echo "the project is mounted at $GUEST_DIR (want /workspace/<name>)"; return 1 ;;
    esac
    [ "$GUEST_DIR" != "$PROJECT" ] \
        || { echo "the guest path is the Mac path"; return 1; }
    if inc ls /Users >/dev/null 2>&1; then
        echo "/Users exists inside the container"
        return 1
    fi
    printf '%s, and no /Users\n' "$GUEST_DIR"
}

in_one_folder() {
    local up
    up="$(inc_wd "$GUEST_DIR" sh -c 'ls -A ..' 2>&1 | grep -c .)"
    [ "$up" = "1" ] || { echo "the parent of the project holds $up entries, want 1"; return 1; }
    printf 'the project is the only thing beside it\n'
}

in_pwd() {
    local p
    p="$(inc_wd "$GUEST_DIR" zsh -lic pwd 2>/dev/null | tail -1 | tr -d '\r')"
    [ "$p" = "$GUEST_DIR" ] || { echo "a login shell lands in '$p', want $GUEST_DIR"; return 1; }
    printf '%s\n' "$p"
}

# The tracker is no longer made at provision: the first pane's startup menu
# asks. Answer it the way a user would -- yes to beads, no to GitHub, then 2
# at the Claude Code offer -- through the container's own template bin.
in_startup_menu_made_beads() {
    printf 'y\nn\n2\n' | docker exec -i -u agent -e HOME=/home/agent -w "$GUEST_DIR" \
        "$CNAME" bash -lc "PATH='$GUEST_DIR/.claude-dev/template/bin':\$PATH startup-menu" >/dev/null 2>&1
    inc_wd "$GUEST_DIR" test -d .beads
}
in_bd_in_project() { inc_wd "$GUEST_DIR" bd status; }
in_bd_anywhere() {
    # bd walks UP for .beads, so from / it can only work if the container
    # carries BEADS_DIR (recovery plan step 5). This is the check behind
    # "bd status said no beads database found" on 2026-09-07.
    inc_wd / bd status
}

# "Its pin" is what the launcher asked the build for, which for bd and
# dolt is setup.sh's literal. Claude Code is the
# exception -- the home's native install at the LATEST release
# (provision.d/15-claude-on-path), never an image pin -- so its want is
# resolved live from downloads.claude.ai, and when that cannot be fetched
# the claude pair is skipped with a note rather than failing a correct
# container on this box's own network. The image itself must carry no
# Claude Code either: the one-binary assertion below is how that reads
# in a running container.
in_versions() {
    local want got bad="" claude_want=""
    claude_want="$(curl -fsSL --max-time 10 \
        https://downloads.claude.ai/claude-code-releases/latest 2>/dev/null \
        | tr -d '[:space:]')"
    for pair in \
        "bd:$(sed -n 's/^BD_VERSION="${BD_VERSION:-\(.*\)}"$/\1/p' "$REPO_ROOT/scripts/container/setup.sh")" \
        "dolt:$(sed -n 's/^DOLT_VERSION="${DOLT_VERSION:-\(.*\)}"$/\1/p' "$REPO_ROOT/scripts/container/setup.sh")"
    do
        want="${pair#*:}"
        case "${pair%%:*}" in
            bd)     got="$(inc bd version 2>/dev/null | sed -n 's/^bd version \([0-9][^ ]*\).*/\1/p' | head -1)" ;;
            dolt)   got="$(inc dolt version 2>/dev/null | sed -n 's/^dolt version \([0-9][^ ]*\).*/\1/p' | head -1)" ;;
        esac
        [ "$got" = "$want" ] || bad="$bad ${pair%%:*}(want $want got ${got:-none})"
    done
    if [ -n "$claude_want" ]; then
        # The native install in the folder's home -- `claude` resolves to
        # ~/.local/bin/claude, the one provision.d/15-claude-on-path keeps
        # at the latest release.
        got="$(inc claude --version 2>/dev/null | awk '{print $1}')"
        [ "$got" = "$claude_want" ] \
            || bad="$bad claude(want $claude_want got ${got:-none})"
    else
        printf 'claude: could not fetch the latest release, pin check skipped\n'
    fi
    # One binary, and it is the native one: `which -a claude` prints
    # exactly /home/agent/.local/bin/claude, and that resolves into
    # ~/.local/share/claude/versions/ -- a stray image binary or a second
    # PATH hit means the folder is not running the install `claude update`
    # keeps current.
    local cl_where cl_target
    cl_where="$(inc which -a claude 2>/dev/null | tr -d '\r')"
    cl_target="$(inc readlink -f /home/agent/.local/bin/claude 2>/dev/null | tr -d '\r')"
    if [ "$cl_where" = "/home/agent/.local/bin/claude" ] \
        && printf '%s' "$cl_target" \
            | grep -q '^/home/agent/.local/share/claude/versions/'; then
        :
    else
        bad="$bad claude(not one native install: got '${cl_where:-none}' -> '${cl_target:-none}')"
    fi
    [ -z "$bad" ] || { echo "pins disagree:$bad"; return 1; }
    printf 'claude/bd/dolt all at their pins\n'
}

in_uid_maps() {
    # A file an agent writes must belong to the person on the Mac, or the
    # folder cannot be deleted by its owner.
    local probe owner
    probe=".mac-e2e-uid-probe"
    inc_wd "$GUEST_DIR" sh -c "printf x > $probe" || return 1
    owner="$(stat -f '%Su' "$PROJECT/$probe" 2>/dev/null)"
    rm -f "$PROJECT/$probe"
    [ "$owner" = "$(id -un)" ] || { echo "a file written inside is owned by '$owner', want $(id -un)"; return 1; }
    printf 'writes inside land as %s outside\n' "$owner"
}

in_mounts() {
    # Exactly what the design says is visible, and nothing else.
    local m
    m="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$CNAME")"
    printf '%s\n' "$m"
}

check "inside: setup.sh --check (the toolchain's own shape)"  in_toolchain_shape
check "inside: no Mac paths visible (step 4)"                 in_no_mac_paths
check "inside: the project is the only folder beside it"      in_one_folder
check "inside: a login shell lands in the project"            in_pwd
check "inside: startup menu created .beads"                  in_startup_menu_made_beads
check "inside: bd works in the project"                       in_bd_in_project
check "inside: bd works from any directory (step 5)"          in_bd_anywhere
check "inside: every tool is at its pin"                      in_versions
check "inside: writes map to the Mac user"                    in_uid_maps
check "inside: the mount list"                                in_mounts

# =========================================================================
# 4a. the login -- the Mac's own ssh against the container's sshd
# =========================================================================

note "ssh: a real login with the folder's key, host key verified"

check_detail "ssh: pwd prints the project path"              c_ssh_pwd
check_detail "ssh: an unknown host key is refused"           c_ssh_refuses_unknown
check_detail "ssh: the folder's ControlMaster comes up"      c_ssh_master
check_detail "pane: a real pane lands in the project"        c_pane_pwd
# The doctor, once, after the master is up so "ssh master" can read ok.
( cd "$PROJECT" && ./claude-dev --doctor ) > "$DOCTOR_OUT" 2>&1
cat "$DOCTOR_OUT" >> "$RUN_LOG"
check_detail "doctor: sshd row ok"                           doctor_row_ok "sshd"
check_detail "doctor: ssh master row ok"                     doctor_row_ok "ssh master"
check_detail "doctor: ssh key auth row ok"                   doctor_row_ok "ssh key auth"

# =========================================================================
# 5. the recreate -- the number a person feels every day
# =========================================================================

if [ -z "$EXISTING_FOLDER" ]; then
    note "recreate: same folder, new container"
    docker rm -f "$CNAME" >/dev/null 2>&1
    t0="$(date +%s)"
    ( cd "$PROJECT" && ./claude-dev ) >> "$RUN_LOG" 2>&1
    rc=$?
    t1="$(date +%s)"
    RECREATE_SECS="$((t1 - t0))"
    if [ "$rc" -eq 0 ]; then
        row ok "$RECREATE_SECS" "recreate: it came back up" ""
    else
        row FAIL "$RECREATE_SECS" "recreate: it came back up" "exit $rc -- see $RUN_LOG"
    fi
    PORT="$(cat "$HOST/run/port" 2>/dev/null || echo "")"
    check_detail "recreate: sshd answers again, same host key"  c_sshd_ready
    check_detail "recreate: ssh pwd prints the project path"    c_ssh_pwd
else
    RECREATE_SECS="-"
fi

# =========================================================================
# 5b. the update -- a folder from the Orca days loses its old state volume
# =========================================================================
#
# LEGACY, on purpose: <container>-orca-state is the docker volume the old
# Orca image mounted at ~/.config/orca. Nothing mounts it now, so
# `./claude-dev --update` removes it (cmd_update_v3). A fresh folder never
# has one, so the volume is planted here with `docker volume create` -- the
# real thing an Orca-era folder carries -- and the update is the real update.

if [ -z "$EXISTING_FOLDER" ]; then
    note "update: ./claude-dev --update on a folder with an old Orca state volume"
    UPDATE_OUT="$LOG_DIR/mac-e2e-$STAMP.update.txt"
    up_planted() { docker volume inspect "$CNAME-orca-state" >/dev/null; }
    up_volume_gone() {
        if docker volume inspect "$CNAME-orca-state" >/dev/null 2>&1; then
            echo "$CNAME-orca-state is still there after --update"
            return 1
        fi
        grep -q 'removed the old Orca state volume' "$UPDATE_OUT" \
            || { echo "--update did not say it removed the old Orca state volume"; return 1; }
        printf 'gone, and --update said so\n'
    }
    docker volume create "$CNAME-orca-state" >/dev/null 2>&1
    check "update: the old Orca state volume is planted" up_planted
    t0="$(date +%s)"
    ( cd "$PROJECT" && ./claude-dev --update ) > "$UPDATE_OUT" 2>&1
    rc=$?
    t1="$(date +%s)"
    cat "$UPDATE_OUT" >> "$RUN_LOG"
    if [ "$rc" -eq 0 ]; then
        row ok "$((t1 - t0))" "update: ./claude-dev --update ran" ""
    else
        row FAIL "$((t1 - t0))" "update: ./claude-dev --update ran" "exit $rc -- see $UPDATE_OUT"
    fi
    check_detail "update: it removed the old Orca state volume"  up_volume_gone
    PORT="$(cat "$HOST/run/port" 2>/dev/null || echo "")"
    check_detail "update: sshd answers on the new container"     c_sshd_ready
    check_detail "update: ssh pwd prints the project path"       c_ssh_pwd
fi

# =========================================================================
# 6. teardown -- the folder must be removable by the person who owns it
# =========================================================================

if [ "$KEEP" -eq 0 ] && [ -z "$EXISTING_FOLDER" ]; then
    note "teardown: the folder goes, and takes its container and volume with it"
    td_runs() { ( cd "$PROJECT" && ./claude-dev --teardown ); }
    td_gone() { [ ! -e "$HOST" ] || { echo "$(du -sh "$HOST" | cut -f1) left behind"; return 1; }; }
    # LEGACY: plant an old Orca state volume again; a `docker rm` never
    # touches a named volume, so teardown has to remove it by name.
    docker volume create "$CNAME-orca-state" >/dev/null 2>&1
    td_volume_gone() {
        docker volume inspect "$CNAME-orca-state" >/dev/null 2>&1 \
            && { echo "the old Orca state volume survived teardown"; return 1; }
        return 0
    }
    td_container_gone() {
        docker inspect "$CNAME" >/dev/null 2>&1 \
            && { echo "$CNAME still exists after teardown"; return 1; }
        return 0
    }

    check  "teardown: ./claude-dev --teardown"          td_runs
    check  "teardown: .claude-dev is gone"              td_gone
    check  "teardown: the container is gone"            td_container_gone
    check  "teardown: the old Orca state volume is gone" td_volume_gone
fi

# =========================================================================
# the table
# =========================================================================

echo
echo "================ mac-e2e summary ================"
printf '%-6s %8s  %s\n' "result" "seconds" "check"
while IFS="$(printf '\t')" read -r st secs name detail; do
    printf '%-6s %8s  %s%s\n' "$st" "$secs" "$name" \
        "$([ -n "$detail" ] && printf ' -- %s' "$detail")"
done < "$RESULTS"
echo "-------------------------------------------------"
printf 'bootstrap to serving: %ss    recreate: %ss\n' "$BOOTSTRAP_SECS" "${RECREATE_SECS:--}"
printf 'checks: %s ok, %s FAILED\n' "$(grep -c '^ok' "$RESULTS")" "$FAILED"
printf 'full log: %s\n' "$RUN_LOG"
if [ "$KEEP" -eq 1 ]; then
    printf 'kept: %s (container %s) -- remove with: cd %s && ./claude-dev --teardown\n' \
        "$PROJECT" "$CNAME" "$PROJECT"
fi

[ "$FAILED" -eq 0 ] || exit 1
exit 0
