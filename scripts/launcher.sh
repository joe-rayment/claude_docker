#!/usr/bin/env bash
#
# claude-dev -- the claude_orca launcher. bootstrap.sh symlinks this file
# to <project>/.claude-dev/bin/claude-dev: one launcher per folder, no
# central install (V1, claude-orca-qt9.1).
#
# v3 (claude-orca-qa2.2 / qa2.3): one Docker Linux VM per folder
# (.claude/plans/container-v3.md). The Mac side owns exactly four things --
# the folder's config (claude-orca.json), the port, the image and the
# container -- and runs no agent itself, so there is no profile to generate,
# nothing to install into the folder beyond the template clone, and no block
# in anyone's shell rc. Everything else happens inside the VM.
#
# Usage:
#   claude-dev                    Open this folder's Orca in a browser
#   claude-dev [register] [dir]   Register a project (default: current dir)
#   claude-dev stop|shell|logs    Stop it / a shell inside it / its output
#   claude-dev verify             Check the folder is set up as promised
#   claude-dev key openrouter     Store this folder's OpenRouter key
#   claude-dev --how-to-run       Print the URL and the two commands
#   claude-dev --doctor           CLI, service, image, container, port, web url
#   claude-dev --update           Pull the template, rebuild the image, re-sync
#                                 the config, recreate
#   claude-dev --teardown         Snapshot beads, remove this folder's install
#   claude-dev --help             Show this help
#
# Trust boundary v3: the VM is the boundary. The container sees the project
# folder (bind-mounted at its own absolute path) and the folder's own
# .claude-dev/home as /home/agent, and nothing else under /Users. The
# folder's config is read as validated data -- jq only, never sourced, never
# executed.

set -euo pipefail

# Resolve through the .claude-dev/bin/claude-dev symlink to find the real
# template root this script lives in (scripts/.. ), independent of how deep
# the symlink chain is or how the script was invoked.
resolve_script_path() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        local link dir
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(cd "$(dirname "$src")" && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}

SCRIPT_PATH="$(resolve_script_path)"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
TEMPLATE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOST_DIR="$(dirname "$TEMPLATE_ROOT")"
# The folder this launcher belongs to: <project>/.claude-dev/template ->
# <project>. Every command defaults to it rather than to $PWD -- a
# per-folder launcher can only ever be about its own folder.
PROJECT_SELF="$(dirname "$HOST_DIR")"

# WHERE THE PROJECT LIVES INSIDE THE CONTAINER.
#
# /workspace/<name>, not the folder's own Mac path. Mounting it at the Mac
# path was deliberate once -- "every path Orca stores and every path an
# agent prints means the same thing on both sides" -- and the price of it
# was that the container spells out its owner's home directory and folder
# tree at every prompt. `pwd` answered /Users/<them>/Documents/<project>
# and `cd ..` walked a plausible-looking Mac, so a real owner read a
# working sandbox as a broken one on 2026-09-07. (Those parents are empty
# scaffolding Docker creates so the mount can sit at that path; the only
# host paths inside are the project and the folder's own home.)
#
# Nothing inside needs the two to agree: the entrypoint, seed-orca-state,
# `bd init`, the Claude trust seed and `orca repo add` all take the path
# from PROJECT_DIR. The Mac path still rides in as
# CLAUDE_ORCA_HOST_PROJECT_DIR, for messages that name a file a person has
# to open on the Mac.
guest_project_dir() { printf '/workspace/%s\n' "$(derive_project_name "$1")"; }

derive_project_name() {
    local raw name
    raw="$(basename "$1")"
    name=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
    [ -z "$name" ] && name="project"
    echo "$name"
}

# startup v4 (claude-orca-qa2.10): the .gitignore seed, the attachments
# directory, the beads-snapshot restore and the home .gitconfig are all
# written by the entrypoint inside the VM now -- the one place they can be
# run for real. What is left on the Mac is reading the global git identity
# and handing it over as env (see container_create).

# v3 (claude-orca-qa2.3): v2 put a marker-delimited block in the user's rc
# files so a login shell re-exec'd itself into a sandbox. v3 runs no agent
# on the Mac, so it installs no block -- but a folder upgraded from v2 may
# still carry one, and --teardown strips it. The markers and the remover
# are all that is left of it.
RC_MARKER_START="# >>> claude_orca >>>"
RC_MARKER_END="# <<< claude_orca <<<"

# Strips any existing marker-delimited block from $1, leaving everything
# else untouched -- including the single blank-line separator that used to
# sit immediately before the block, which is dropped here too so a removal
# restores the original file byte-for-byte instead of leaving a trailing
# blank line behind. A no-op if the file doesn't exist or has no block.
# (One line of lookahead: a line is only printed once we know it isn't the
# blank line immediately before START.)
rc_remove_block() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -qF "$RC_MARKER_START" "$file" || return 0

    local tmp
    tmp="$(mktemp "${file}.XXXXXX")"
    awk -v start="$RC_MARKER_START" -v end="$RC_MARKER_END" '
        $0 == start {
            skip = 1
            if (have_pending && pending != "") { print pending }
            have_pending = 0
            next
        }
        $0 == end { skip = 0; next }
        skip { next }
        {
            if (have_pending) { print pending }
            pending = $0
            have_pending = 1
        }
        END { if (have_pending) print pending }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# S5 (claude-orca-3sk.17), moved into the VM by startup v4
# (claude-orca-qa2.10): the container's HOME is the folder's own
# .claude-dev/home, so a fresh one has no git identity at all and every
# commit inside the VM fails. The Mac reads exactly user.name and
# user.email from its global config -- nothing else, no credential helper,
# no signing key, no host-only paths -- and the entrypoint writes
# /home/agent/.gitconfig from the two values.
git_identity_name()  { git config --global --get user.name  2>/dev/null || true; }
git_identity_email() { git config --global --get user.email 2>/dev/null || true; }

# V1 (claude-orca-qt9.1): the project root's ./claude-dev -- a two-line
# stub, not a symlink, so it survives `git clean` sanity and reads as what
# it is. Regenerated on every register (and removed by teardown); the
# gitignore seed keeps it out of the repo.
write_project_stub() {
    local dir="$1" stub="$1/claude-dev"
    # Unlink first, always: `>` FOLLOWS a symlink, so if ./claude-dev is
    # already a link -- a user's own convenience link, a hand-made or older
    # layout -- the stub is written straight through it into whatever it
    # points at. Pointed at .claude-dev/bin/claude-dev that is the
    # template's own launcher.sh, and register replaces 1100 lines with
    # these three, bricking the folder. A plain rm, not -r: a directory at
    # that path fails here and surfaces, which is what a human should see.
    rm -f "$stub"
    cat > "$stub" <<'STUB'
#!/usr/bin/env bash
# Generated by claude-dev register -- do not edit; not committed.
exec "$(cd "$(dirname "$0")" && pwd -P)/.claude-dev/bin/claude-dev" "$@"
STUB
    chmod +x "$stub"
}

# --- S12 (claude-orca-3sk.23): update / teardown -------------------------
#
# The template must be updatable and removable without losing beads (see
# knowledge-base/TEARDOWN_RECOVERY.md). Beads state is the one thing in a
# project that is expensive to lose and that lives nowhere else, so
# teardown snapshots it out of .claude-dev -- which it then deletes whole --
# into <project>/.claude-dev-snapshots/, and a later registration pulls it
# back. That sibling directory is inside the folder because in v2 and v3
# alike there is nothing outside the folder left to put it in.

# The exact lines the entrypoint's gitignore seed writes -- teardown is
# the Mac's own command, so the unseed stays here, and it can only ever
# remove what the seed put there.
GITIGNORE_MARKER="# claude_orca"

# Removes the marker block the seed added (marker line, the blank
# separator before it, and the seeded patterns that follow) and nothing
# else: any other line -- including a user's own '.mcp.json' elsewhere in
# the file -- is left byte-identical. Same one-line-lookahead trick as
# rc_remove_block.
gitignore_unseed() {
    local file="$1/.gitignore"
    [ -f "$file" ] || return 0
    grep -qF "$GITIGNORE_MARKER" "$file" || return 0

    local tmp
    tmp="$(mktemp "${file}.XXXXXX")"
    awk -v marker="$GITIGNORE_MARKER" '
        function seeded(l) {
            return l == ".claude-dev/" || l == ".claude-dev-snapshots/" || \
                   l == "/claude-dev" || l == "Orca.app/" || \
                   l == ".mcp.json" || l == "attachments/" || \
                   l == ".claude/logs/"
        }
        $0 == marker {
            skip = 1
            if (have_pending && pending != "") { print pending }
            have_pending = 0
            next
        }
        skip && seeded($0) { next }
        {
            skip = 0
            if (have_pending) { print pending }
            pending = $0
            have_pending = 1
        }
        END { if (have_pending) print pending }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# Copies .beads/issues.jsonl (+ metadata.json) to
# $HOST/state/<project>/<timestamp>/ and prints the snapshot dir. Silent
# no-op when the project has no exported beads. The Dolt DB itself is not
# copied -- it rebuilds from the JSONL.
# rm -rf, then verify -- with a bounded wait, because the thing that
# holds the directory open is Docker unmounting it and that finishes on
# its own. Returns non-zero only if it is STILL there afterwards.
remove_host_dir() {
    local dir="$1" tries=0
    while [ "$tries" -lt 10 ]; do
        rm -rf "$dir" 2>/dev/null
        [ -e "$dir" ] || return 0
        sleep 1
        tries=$((tries + 1))
    done
    rm -rf "$dir" 2>/dev/null
    [ ! -e "$dir" ]
}

snapshot_root() {
    printf '%s\n' "$1/.claude-dev-snapshots"
}

snapshot_beads() {
    local dir="$1" name="$2" ts snap
    [ -f "$dir/.beads/issues.jsonl" ] || return 0
    ts="$(date +%Y%m%d-%H%M%S)"
    snap="$(snapshot_root "$dir")/$ts"
    mkdir -p "$snap"
    cp "$dir/.beads/issues.jsonl" "$snap/issues.jsonl"
    if [ -f "$dir/.beads/metadata.json" ]; then
        cp "$dir/.beads/metadata.json" "$snap/metadata.json"
    fi
    printf '%s\n' "$snap"
}

# The other half of the round trip -- restoring the newest snapshot when
# the project side has no issues.jsonl of its own -- is the entrypoint's,
# from startup v4 (claude-orca-qa2.10): it runs there, before `bd init`,
# against the same .claude-dev-snapshots directory.

# ===== the container launcher (claude-orca-qa2.2, Docker) ================
#
# See .claude/plans/container-v3.md S5. Everything an agent runs is inside
# the VM, so the Mac side is only ever starting one, publishing its port,
# and opening the URL it printed.

# A local image name, because the image is built on this machine and
# published nowhere. It carried a ghcr.io/ prefix while it was pulled
# from a private package -- see acquire_image for why that path is gone.
IMAGE_REPO="${CLAUDE_ORCA_IMAGE_REPO:-claude-orca}"

# The tag lives in one file at the template root, so a folder that only
# ever runs `claude-dev --update` moves to the new image with the rebuild.
#
# The Orca version is folded in (<tag>-orca<version>, S4/claude-orca-8uo.5)
# because the image and the Mac's Orca.app are one pair: Orca's protocol
# check is a hard refusal on a mismatch, not a warning. A folder whose app
# has moved must therefore ask the daemon for a DIFFERENT ref -- otherwise
# it finds the image it already has under the same name, decides it is
# there, and runs a container the app cannot attach to. Everything reads
# the ref through image_ref, so nothing else has to know this.
image_tag() {
    local f tag="" ver=""
    for f in "$TEMPLATE_ROOT/IMAGE_TAG" "$HOST_DIR/template/IMAGE_TAG"; do
        if [ -f "$f" ]; then
            tag="$(tr -d '[:space:]' < "$f")"
            break
        fi
    done
    if [ -z "$tag" ]; then tag="latest"; fi
    ver="$(wanted_orca_version)"
    if [ -n "$ver" ]; then tag="$tag-orca$ver"; fi
    printf '%s\n' "$tag"
}

# CLAUDE_ORCA_IMAGE names a whole ref and wins over the IMAGE_TAG file: it
# points the launcher at an image someone else already built, which is how
# a hand-built or test image is driven through the real launcher.
image_ref() {
    if [ -n "${CLAUDE_ORCA_IMAGE:-}" ]; then
        printf '%s\n' "$CLAUDE_ORCA_IMAGE"
        return 0
    fi
    printf '%s:%s\n' "$IMAGE_REPO" "$(image_tag)"
}
container_name() { printf 'claude-orca-%s\n' "$(derive_project_name "$1")"; }

# Every runtime invocation goes through ctr(), so there is exactly one
# place that knows how to reach the runtime and one record of what was
# asked of it. GH_TOKEN rides into the VM as an env var, so the copy kept
# on disk has the value struck out; nothing else ever puts a secret in
# argv (the registry password goes in on stdin).
#
# The runtime is Docker. Apple's `container` was the v3 choice and could
# not be exercised anywhere this repo can test -- and its registry client
# refuses GHCR outright ("missing Bearer challenge in WWW-Authenticate
# header"). Docker is what CI runs, so the switch makes CI verify the
# runtime the Mac actually drives. The handful of subcommands whose shape
# differs are translated here rather than at every call site; `run`,
# `start`, `stop`, `rm`, `logs`, `exec` and `inspect` are already Docker's
# own and pass straight through.
#
# CLAUDE_ORCA_RUNTIME picks the backend: `docker` (the default, and what a
# Mac runs) or `local` (below).
CTR_RUNTIME="${CLAUDE_ORCA_RUNTIME:-docker}"
CTR_LOG=""
CTR_RUN_DIR=""

ctr_init() {
    mkdir -p "$1/.claude-dev/run" 2>/dev/null || true
    CTR_LOG="$1/.claude-dev/run/container.log"
    CTR_RUN_DIR="$1/.claude-dev/run"
}

ctr_log_line() {
    local out="" a
    for a in "$@"; do
        case "$a" in
            GH_TOKEN=*)           a="GH_TOKEN=***" ;;
            OPENROUTER_API_KEY=*) a="OPENROUTER_API_KEY=***" ;;
        esac
        out="$out $a"
    done
    # Stamped: the whole point of this file is answering "how long did
    # that take", and it could not (recovery plan step 0.2).
    printf '%s %s%s\n' "$(date '+%H:%M:%S')" "$CTR_RUNTIME" "$out"
}

# Every backend mirrors its argv into the folder's log, redaction and all
# -- except the container-state poll, which every wait loop runs once a
# second and which buried this file under 4,625 identical lines on a real
# Mac (2026-09-07), leaving the handful that say what actually happened
# unfindable. What the poll observes is logged by its caller instead.
ctr_mirror() {
    case "${1:-}" in
        inspect) return 0 ;;
    esac
    if [ -n "${CTR_LOG:-}" ]; then
        ctr_log_line "$@" >> "$CTR_LOG" 2>/dev/null || true
    fi
}

# The one call site of the docker binary: everything else goes through ctr().
ctr_docker() {
    ctr_mirror "$@"
    command docker "$@"
}

# `docker info` succeeding IS the daemon being up -- there is no separate
# service verb to ask. On a Mac the daemon is Docker Desktop, which `open`
# starts and which takes a while to answer; on Linux the daemon is the
# host's business and this never tries to start anything.
ctr_daemon_up() { ctr_docker info >/dev/null 2>&1; }

ctr_daemon_start() {
    local waited=0
    if ctr_daemon_up; then return 0; fi
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "==> Starting Docker Desktop"
        open -a Docker >/dev/null 2>&1 || true
        while [ "$waited" -lt 60 ]; do
            sleep 1
            waited=$((waited + 1))
            if ctr_daemon_up; then return 0; fi
        done
    fi
    {
        echo "Error: the Docker daemon is not responding -- 'docker info' failed."
        echo "  Start it and try again:"
        echo "    macOS:  open -a Docker"
        echo "    Linux:  sudo systemctl start docker"
    } >&2
    return 1
}

# ===== the `local` runtime backend =======================================
#
# CLAUDE_ORCA_RUNTIME=local runs the SAME in-VM entrypoint
# (scripts/container/entrypoint.sh) as an ordinary child process on this
# host, with the identical environment contract, instead of inside a
# container. It exists because a container cannot be started everywhere the
# launcher has to be provable: this repo's own dev box has an empty
# capability set (CapEff 0000000000000000, no CAP_SYS_ADMIN in the bounding
# set), so mount and unshare fail even for root and docker, podman and a
# private dockerd all die the same way. With this backend the launcher, the
# entrypoint and Orca can be exercised together for real.
#
# There is NO BOUNDARY here, and this does not pretend otherwise: --volume,
# -p, --cpus, --memory and --dns are parsed off the argv and ignored,
# because a plain child process has no filesystem, network or resource
# isolation to configure. `local` is a test and escape-hatch backend; the
# boundary this template ships is the container one.
#
# One record per container name under <project>/.claude-dev/run/local/:
# .project (the folder), .env (the -e values), .pid, .log.

ctr_local_dir() {
    if [ -n "${CTR_RUN_DIR:-}" ]; then
        printf '%s\n' "$CTR_RUN_DIR/local"
    else
        printf '%s\n' "${TMPDIR:-/tmp}/claude-orca-local"
    fi
}

# The recorded PROCESS GROUP id, not a bare pid: the entrypoint spawns
# Orca, which spawns more, and stop has to be able to signal the whole tree
# at once rather than trust one process to pass a signal down.
ctr_local_pid() {
    local f
    f="$(ctr_local_dir)/$1.pgid"
    [ -s "$f" ] || return 1
    head -1 "$f" | tr -d '[:space:]'
}

# running/exited, the same words Docker answers with -- and empty when
# there is no such container, which is what container_state needs.
ctr_local_state() {
    local pgid
    [ -f "$(ctr_local_dir)/$1.project" ] || return 0
    pgid="$(ctr_local_pid "$1")" || { printf 'exited\n'; return 0; }
    # A negative pid is the whole group: alive while any member is.
    if kill -0 -- "-$pgid" 2>/dev/null; then
        printf 'running\n'
    else
        printf 'exited\n'
    fi
}

# Starts (or restarts) the entrypoint for a recorded container. The child
# inherits this shell's environment -- DISPLAY above all, which is what
# Orca needs -- and the recorded -e values are layered on top of it.
ctr_local_spawn() {
    local name="$1" d proj entry log line waited
    d="$(ctr_local_dir)"
    [ -f "$d/$name.project" ] || { echo "local runtime: no container $name" >&2; return 1; }
    proj="$(head -1 "$d/$name.project")"
    entry="$proj/.claude-dev/template/scripts/container/entrypoint.sh"
    [ -f "$entry" ] || { echo "local runtime: no entrypoint at $entry" >&2; return 1; }
    log="$d/$name.log"

    set --
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        set -- "$@" "$line"
    done < "$d/$name.env"
    # The folder's own home is HOME here, so Orca's user-data dir lands
    # inside the project exactly as it does under /home/agent in the VM.
    # No privilege drop: there is no agent user on this side to drop to.
    set -- "$@" "HOME=$proj/.claude-dev/home" \
        "ORCA_BIN=${CLAUDE_ORCA_ORCA_BIN:-/opt/Orca/orca-ide}" \
        CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 \
        CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1

    mkdir -p "$proj/.claude-dev/home"
    : > "$log"
    rm -f "$d/$name.pgid"

    # Its own session, so the entrypoint and everything it spawns share one
    # process group that stop can signal as a unit. The group id is written
    # from INSIDE that shell rather than taken from $!: setsid may or may
    # not fork depending on whether the caller already leads a group, so $!
    # is not reliably the leader -- $$ in there always is.
    CTR_LOCAL_PGID="$d/$name.pgid" CTR_LOCAL_ENTRY="$entry" \
        nohup setsid bash -c \
            'printf "%s\n" "$$" > "$CTR_LOCAL_PGID"; exec env "$@" bash "$CTR_LOCAL_ENTRY"' \
            _ "$@" >> "$log" 2>&1 &

    waited=0
    while [ "$waited" -lt 50 ]; do
        [ -s "$d/$name.pgid" ] && break
        sleep 0.1
        waited=$((waited + 1))
    done
    [ -s "$d/$name.pgid" ] || { echo "local runtime: $name did not start" >&2; return 1; }
    printf '%s\n' "$name"
}

ctr_local_run() {
    local d name="" proj="" a prev=""
    for a in "$@"; do
        case "$prev" in
            --name) name="$a" ;;
        esac
        prev="$a"
    done
    [ -n "$name" ] || { echo "local runtime: run needs --name" >&2; return 1; }
    d="$(ctr_local_dir)"
    mkdir -p "$d"
    : > "$d/$name.env"
    prev=""
    for a in "$@"; do
        case "$prev" in
            -e|--env)
                printf '%s\n' "$a" >> "$d/$name.env"
                case "$a" in PROJECT_DIR=*) proj="${a#PROJECT_DIR=}" ;; esac
                ;;
        esac
        prev="$a"
    done
    [ -n "$proj" ] || { echo "local runtime: run needs -e PROJECT_DIR=..." >&2; return 1; }
    printf '%s\n' "$proj" > "$d/$name.project"
    ctr_local_spawn "$name"
}

# TERM the whole process group -- the entrypoint has its own trap for
# taking Orca down with it, and signalling the group catches whatever the
# trap does not. KILL only when the group will not go.
ctr_local_stop() {
    local name="$1" pgid waited=0
    pgid="$(ctr_local_pid "$name")" || return 0
    kill -TERM -- "-$pgid" 2>/dev/null || return 0
    while [ "$waited" -lt 15 ]; do
        kill -0 -- "-$pgid" 2>/dev/null || return 0
        sleep 1
        waited=$((waited + 1))
    done
    kill -KILL -- "-$pgid" 2>/dev/null || true
    return 0
}

ctr_local_exec() {
    local wd=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -i|-t|-it|-ti)  shift ;;
            --workdir)      wd="${2:-}"; shift 2 ;;
            --workdir=*)    wd="${1#--workdir=}"; shift ;;
            -*)             shift ;;
            *)              shift; break ;;
        esac
    done
    [ -n "$wd" ] || wd="$PWD"
    [ "$#" -gt 0 ] || set -- "${SHELL:-/bin/sh}" -l
    ( cd "$wd" 2>/dev/null || cd /; exec "$@" )
}

ctr_local() {
    local d name
    ctr_mirror "$@"
    d="$(ctr_local_dir)"
    case "${1:-} ${2:-}" in
        # No image and no daemon to speak to, so these succeed as no-ops.
        "image pull"|"image build"|"image ls"|"image list"|"image inspect") return 0 ;;
        "registry login"|"registry logout")                   return 0 ;;
        "system start"|"system status"|"system stop")         return 0 ;;
    esac
    case "${1:-}" in
        pull|build|login|logout|info) return 0 ;;
    esac
    case "${1:-}" in
        run)     shift; ctr_local_run "$@"; return $? ;;
        inspect)
            # `inspect -f '{{.State.Status}}' NAME`: the name is last.
            for name; do :; done
            ctr_local_state "$name"
            return 0 ;;
        start)   ctr_local_spawn "$2" >/dev/null; return $? ;;
        stop)    ctr_local_stop "$2"; return $? ;;
        rm)      ctr_local_stop "$2"
                 rm -f "$d/$2.pgid" "$d/$2.env" "$d/$2.project" "$d/$2.log"
                 return 0 ;;
        logs)    shift
                 case "${1:-}" in -f) shift; tail -n +1 -f "$d/${1:-}.log" ;;
                                  *)  cat "$d/${1:-}.log" ;; esac
                 return $? ;;
        exec)    shift; ctr_local_exec "$@"; return $? ;;
    esac
    return 0
}

ctr() {
    if [ "$CTR_RUNTIME" = "local" ]; then
        ctr_local "$@"
        return $?
    fi
    case "${1:-} ${2:-}" in
        "system start")  ctr_daemon_start; return $? ;;
        "system status") ctr_daemon_up;    return $? ;;
        "system stop")   return 0 ;;
        "image pull")    shift 2; ctr_docker pull "$@"; return $? ;;
        "image ls"|"image list"|"image inspect")
                         shift 2; ctr_docker image inspect "$@"; return $? ;;
        "registry login")  shift 2; ctr_docker login "$@";  return $? ;;
        "registry logout") shift 2; ctr_docker logout "$@"; return $? ;;
    esac
    ctr_docker "$@"
}

# The fallback when the build itself cannot run: the folder runs the
# PUBLIC base image with the mounted template's own entrypoint as its
# command, and setup.sh installs the toolchain inside it on that first
# start. Slow, but a working folder.
#
# This used to say an image build was "the one step this repo can never
# test here", which was true of the box and beside the point for the Mac:
# it kept the build in CI, and CI is where delivery then stopped.
BASE_IMAGE="${CLAUDE_ORCA_BASE_IMAGE:-docker.io/library/ubuntu:24.04}"
RUNTIME_INSTALL_NOTE="No image: the VM installs its toolchain on first start (several minutes); progress: ./claude-dev logs"

# Which of the two images this folder runs -- 'built' or 'runtime' --
# written by acquire_image and read back by container_create and the
# doctor, because the choice has to survive between commands.
record_image_source() {
    mkdir -p "$1/.claude-dev/run" 2>/dev/null || true
    printf '%s\n' "$2" > "$1/.claude-dev/run/image-source" 2>/dev/null || true
}

image_source() {
    local f="$1/.claude-dev/run/image-source"
    if [ -s "$f" ]; then
        head -1 "$f" | tr -d '[:space:]'
    fi
}


# One `docker build`, with the sound turned on. A build says a great deal
# and then goes quiet for minutes on a big layer, so silence is reported
# with the elapsed time rather than left to look like progress -- the same
# shape the setup.log wait uses. The caller reads BUILD_OUT because what
# the builder printed IS the diagnosis when it fails.
BUILD_OUT=""
BUILD_TICK="${CLAUDE_ORCA_BUILD_TICK:-10}"
BUILD_STALL="${CLAUDE_ORCA_BUILD_STALL:-180}"

try_build() {
    local ref="$1" ctx="$2" log rc=0 pid waited=0 quiet=0 last="" line="" said_how=0
    local ver=""
    log="${CTR_RUN_DIR:-${TMPDIR:-/tmp}}/build.log"
    : > "$log" 2>/dev/null || log="${TMPDIR:-/tmp}/claude-orca-build.log"
    # The app decides the version (S4/claude-orca-8uo.5) -- and only the
    # app. With no app on this host there is no build arg at all: the
    # Dockerfile's own default is the answer, and passing it back in would
    # be a second place for that pin to be wrong.
    #
    # --tag stays the FIRST flag: `docker build --tag <ref>` is what every
    # reader of the command line here greps for, the suite included.
    ver="$(app_orca_version)"
    if [ -n "$ver" ]; then
        ctr build --tag "$ref" --build-arg "ORCA_VERSION=$ver" "$ctx" > "$log" 2>&1 &
    else
        ctr build --tag "$ref" "$ctx" > "$log" 2>&1 &
    fi
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        [ "$((waited % BUILD_TICK))" -eq 0 ] || continue
        line="$(tail -1 "$log" 2>/dev/null)"
        if [ -n "$line" ] && [ "$line" != "$last" ]; then
            echo "  building (${waited}s): $line" >&2
            last="$line"
            quiet=0
        else
            quiet=$((quiet + BUILD_TICK))
            if [ "$quiet" -ge "$BUILD_STALL" ]; then
                echo "  the build has said nothing for ${quiet}s (${waited}s in)." >&2
                if [ "$said_how" -eq 0 ]; then
                    if [ -n "$last" ]; then
                        echo "    last it said: $last" >&2
                    fi
                    echo "    the whole log is at $log" >&2
                    echo "    ^C is safe -- bootstrap and ./claude-dev are both idempotent." >&2
                    said_how=1
                fi
                quiet=0
            fi
        fi
    done
    wait "$pid" || rc=$?
    BUILD_OUT="$(cat "$log" 2>/dev/null)"
    return "$rc"
}

# The image this folder runs, built HERE from the template clone the folder
# already carries. There is no registry in this path: no package, no token,
# no scope, no CI publish between a commit and the machine that needs it.
#
# WHY THIS IS A BUILD AND NOT A PULL. It was a pull until 2026-09-08, from
# a private GHCR package, and every link in that chain broke in the same
# week: the workflow that published the image failed twelve runs running,
# so `latest` was two days stale; the Mac's fine-grained PAT is refused the
# manifest of a private package outright (403), so the pull fell back to
# whatever copy the daemon already held; and the folder recorded "pulled"
# either way, so nothing downstream could tell a fresh image from an old
# one. A change could be committed, green and live in the folder's own
# clone and still not be in the container. `docker build` has none of those
# failure modes and one property the pull never had: its cache is keyed on
# the build inputs, so it is always in sync with the template on disk.
#
# The cost is one download of ~1.3 GB of pinned tools per MACHINE, not per
# folder -- the distinction the 2026-09-07 toolchain-in-the-folder
# experiment got wrong at ~18 minutes a folder. Every later folder, and
# every rebuild that only moves the repo copy, is a cache hit measured in
# seconds.
#
# Never fatal: a build that cannot run leaves the folder on the public base
# image with the toolchain installed inside it on first start, which is
# slow but works.
acquire_image() {
    local dir="$1" ref="$2" ctx=""
    # The local backend runs no image at all, so there is nothing to build.
    if [ "$CTR_RUNTIME" = "local" ]; then
        echo "==> Local runtime: no image to acquire"
        record_image_source "$dir" built
        return 0
    fi
    # CLAUDE_ORCA_IMAGE names an image someone else built and the daemon
    # already holds -- CI's path, and anyone testing a hand-built image.
    if [ -n "${CLAUDE_ORCA_IMAGE:-}" ] && ctr image inspect "$ref" >/dev/null 2>&1; then
        echo "==> Using the local image $ref (CLAUDE_ORCA_IMAGE)"
        record_image_source "$dir" built
        return 0
    fi
    ctx="$HOST_DIR/template"
    if [ -f "$ctx/Dockerfile" ]; then
        echo "==> Building $ref from $ctx"
        echo "    The first build on this machine downloads ~1.3 GB of pinned tools; folders after it are cache hits."
        if try_build "$ref" "$ctx"; then
            record_image_source "$dir" built
            return 0
        fi
        echo "The build failed; its last lines:" >&2
        printf '%s\n' "$BUILD_OUT" | tail -5 >&2
    else
        echo "No Dockerfile at $ctx -- nothing to build here." >&2
    fi
    # A failed build says nothing about whether the image is already HERE.
    if ctr image inspect "$ref" >/dev/null 2>&1; then
        echo "Using the copy of $ref already on this machine (this build did not replace it)."
        echo "  It may be older than this template; './claude-dev --update' rebuilds it."
        record_image_source "$dir" built
        return 0
    fi
    echo "$RUNTIME_INSTALL_NOTE"
    record_image_source "$dir" runtime
}

# What `--update` actually moved, in the same shape as the template line
# above it: a rebuild that was entirely cache hits and one that replaced
# every layer both just print steps. The local image id is the only
# thing that settles it. Reporting only -- an id that cannot be read
# prints nothing and is never fatal.
image_id_short() {
    local id=""
    [ "$CTR_RUNTIME" = "local" ] && return 0
    id="$(ctr image inspect "$1" --format '{{.Id}}' 2>/dev/null | head -1)" || id=""
    id="$(printf '%s' "$id" | tr -d '[:space:]')"
    id="${id#sha256:}"
    [ -n "$id" ] || return 0
    printf '%s\n' "${id:0:7}"
}

# The previous version of this image, which a pull leaves behind untagged:
# its layers stay on disk, several GB of them, and nothing ever collects
# them. Only ours (the repo half of image_ref), only <none>-tagged, never
# the one just acquired. `docker rmi` legitimately refuses an image some
# other container still references, so every failure here is skipped
# rather than reported: an update must not fail over disk it could not
# free.
prune_old_images() {
    local ref="$1" keep="$2" repo="" repository="" tag="" id="" freed=0 ids=""
    [ "$CTR_RUNTIME" = "local" ] && return 0
    repo="${ref%:*}"
    while read -r repository tag id; do
        [ -n "$id" ] || continue
        [ "$repository" = "$repo" ] || continue
        [ "$tag" = "<none>" ] || continue
        id="${id#sha256:}"
        id="${id:0:7}"
        [ "$id" = "$keep" ] && continue
        ctr rmi "$id" >/dev/null 2>&1 || continue
        freed=$((freed + 1))
        if [ -z "$ids" ]; then ids="$id"; else ids="$ids, $id"; fi
    done <<PRUNE
$(ctr images --format '{{.Repository}} {{.Tag}} {{.ID}}' 2>/dev/null || true)
PRUNE
    [ "$freed" -gt 0 ] || return 0
    if [ "$freed" -eq 1 ]; then
        echo "  removed 1 old image version ($ids)"
    else
        echo "  removed $freed old image versions ($ids)"
    fi
}

# run/ holds RESULTS (CLAUDE.md: state/ holds authority), and every one of
# them belongs to the container that wrote it: the pairing URL most of all
# -- opening a previous session's URL is opening nothing. So a folder that
# is about to get a new container starts from none of them. state/,
# claude-orca.json, the home, .beads and run/image-source are authority or
# input and are never touched here.
clear_run_results() {
    local run="$1/.claude-dev/run"
    rm -f "$run/orca-web-url.txt" \
          "$run/port" \
          "$run/orca-serve.log" \
          "$run/setup.log" 2>/dev/null || true
}

orca_json() { printf '%s\n' "$1/.claude-dev/claude-orca.json"; }

# qa2.7: the OpenRouter key the delegate routes need inside the VM. It
# belongs to the folder, so it lives in the folder-local home -- which is
# /home/agent in the container and gitignored on the Mac -- rather than in
# a shell rc or a keychain the container cannot see. Mode 600, never in
# argv on the Mac beyond the one `container run`, and struck out of the
# container.log mirror.
openrouter_key_file() { printf '%s\n' "$1/.claude-dev/home/.openrouter.key"; }

openrouter_key_value() {
    local f
    f="$(openrouter_key_file "$1")"
    [ -f "$f" ] || return 0
    head -1 "$f" | tr -d '[:space:]'
}

# The terminal, not stdin: a key typed into a pipe would sit in the shell's
# history and in whatever produced the pipe. CLAUDE_ORCA_KEY_INPUT names a
# file to read instead, for tests, which have no /dev/tty.
read_secret_value() {
    local prompt="$1" value=""
    if [ -n "${CLAUDE_ORCA_KEY_INPUT:-}" ]; then
        if [ -f "$CLAUDE_ORCA_KEY_INPUT" ]; then
            value="$(head -1 "$CLAUDE_ORCA_KEY_INPUT")"
        fi
    elif [ -r /dev/tty ]; then
        printf '%s' "$prompt" > /dev/tty
        stty -echo < /dev/tty 2>/dev/null || true
        IFS= read -r value < /dev/tty || value=""
        stty echo < /dev/tty 2>/dev/null || true
        printf '\n' > /dev/tty
    fi
    printf '%s\n' "$value" | tr -d '[:space:]'
}

cmd_key_v3() {
    local dir="$PROJECT_SELF" what="${1:-}" key file
    case "$what" in
        openrouter) ;;
        *) echo "Usage: claude-dev key openrouter" >&2; return 1 ;;
    esac
    shift
    if [ $# -gt 0 ] && [ -n "$1" ]; then dir="$1"; fi
    [ -d "$dir" ] || { echo "Error: directory does not exist: $dir" >&2; return 1; }
    dir="$(cd "$dir" && pwd -P)"

    key="$(read_secret_value "OpenRouter API key (not echoed): ")"
    if [ -z "$key" ]; then
        echo "Error: no key given -- nothing written." >&2
        return 1
    fi

    mkdir -p "$dir/.claude-dev/home"
    file="$(openrouter_key_file "$dir")"
    # Unlink first, always, and here it is a credential at stake: `>`
    # FOLLOWS a symlink, so a link planted at .openrouter.key sends the
    # user's real OpenRouter key straight through it into whatever it
    # points at -- and the chmod below then relaxes THAT file to 600. The
    # umask is no help, because an existing target keeps its own mode. After
    # the rm the key can only ever land on a fresh regular file the umask
    # governs.
    rm -f "$file"
    ( umask 077; printf '%s\n' "$key" > "$file" )
    chmod 600 "$file"
    echo "Saved the OpenRouter key to .claude-dev/home/.openrouter.key (mode 600)."
    echo "It rides into the container as OPENROUTER_API_KEY next time you run ./claude-dev."
}

# --- the desktop Orca on the Mac (S2, claude-orca-8uo.3) -----------------
#
# A folder runs one of two UIs: Orca Web in the browser, or the Orca.app on
# the Mac attached to the container's runtime. Which one is decided once,
# at register, and the three functions below are everything the decision
# and the doctor need to know about the app.

ORCA_DOWNLOAD_URL="https://orca.dev/download"

# The Orca.app bundle, or rc 1 and no output. macOS only: a Linux host has
# no .app to find, whatever the environment says.
#
# CLAUDE_ORCA_APP is consulted FIRST and is authoritative -- an explicit
# override that points nowhere is an answer ("this Mac has no Orca for
# this folder"), not a reason to carry on to /Applications. That is what
# lets a test, or a user with two Orca builds, say which one is meant on a
# machine that also has the ordinary one installed.
find_orca_app() {
    local app
    [ "$(uname -s)" = "Darwin" ] || return 1
    if [ -n "${CLAUDE_ORCA_APP:-}" ]; then
        [ -d "$CLAUDE_ORCA_APP" ] || return 1
        printf '%s\n' "$CLAUDE_ORCA_APP"
        return 0
    fi
    for app in "/Applications/Orca.app" "$HOME/Applications/Orca.app"; do
        if [ -d "$app" ]; then
            printf '%s\n' "$app"
            return 0
        fi
    done
    return 1
}

# The orca CLI that goes with a bundle. The app ships it under
# Contents/Resources/bin (`orca` since 1.4, `orca-ide` on older builds);
# an `orca` already on PATH -- a Homebrew install, a dev checkout -- is the
# last answer rather than the first, so the CLI matches the app whenever
# the app has one.
orca_cli() {
    local app="${1:-}" c
    if [ -n "$app" ]; then
        for c in "$app/Contents/Resources/bin/orca" "$app/Contents/Resources/bin/orca-ide"; do
            if [ -x "$c" ]; then
                printf '%s\n' "$c"
                return 0
            fi
        done
    fi
    c="$(command -v orca 2>/dev/null)" || c=""
    [ -n "$c" ] || return 1
    printf '%s\n' "$c"
}

# CFBundleShortVersionString, or empty. `defaults` is the only reader of a
# binary plist that is always on a Mac; off a Mac there is none and the
# version is simply unknown, which is a row the doctor can still print.
orca_app_version() {
    local app="${1:-}" v=""
    [ -n "$app" ] || return 0
    if command -v defaults >/dev/null 2>&1; then
        v="$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)" || v=""
    fi
    printf '%s\n' "$v"
}

# One scalar out of claude-orca.json, empty when absent, null or unreadable.
json_get() {
    local json v=""
    json="$(orca_json "$1")"
    if [ -f "$json" ] && command -v jq >/dev/null 2>&1; then
        v="$(jq -r "$2 // empty" "$json" 2>/dev/null || true)"
    fi
    if [ "$v" = "null" ]; then v=""; fi
    printf '%s\n' "$v"
}

# Which UI this folder runs. An absent key reads as web: every folder
# registered before this template had the key is a browser folder, and a
# folder whose config cannot be read is one too -- Orca Web is the answer
# that needs nothing on the Mac.
ui_of() {
    case "$(json_get "$1" '.ui')" in
        desktop) printf 'desktop\n' ;;
        *)       printf 'web\n' ;;
    esac
}

# Written once, at register, the same way the port is.
persist_ui() {
    local dir="$1" ui="$2" json tmp
    json="$(orca_json "$dir")"
    [ -f "$json" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    tmp="$json.tmp"
    if jq --arg u "$ui" '.ui = $u' "$json" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$json"
    else
        rm -f "$tmp"
    fi
}

# A free port is one nothing answers on: bash's own /dev/tcp connect,
# which needs no lsof/nc and no listener of our own.
port_is_free() {
    if ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; then
        return 1
    fi
    return 0
}

# Chosen once, at register, and reused forever after: the same number has
# to be free on both sides, because the pairing code the browser gets
# advertises ws://127.0.0.1:<port>.
choose_port() {
    local dir="$1" port tries=0
    port="$(json_get "$dir" '.port')"
    case "$port" in
        ''|*[!0-9]*) port="" ;;
    esac
    if [ -n "$port" ]; then
        printf '%s\n' "$port"
        return 0
    fi
    port="${CLAUDE_ORCA_PORT_BASE:-6768}"
    while [ "$tries" -lt 200 ]; do
        if port_is_free "$port"; then
            break
        fi
        port=$((port + 1))
        tries=$((tries + 1))
    done
    printf '%s\n' "$port"
}

persist_port() {
    local dir="$1" port="$2" json tmp
    json="$(orca_json "$dir")"
    mkdir -p "$dir/.claude-dev/run"
    printf '%s\n' "$port" > "$dir/.claude-dev/run/port"
    if [ -f "$json" ] && command -v jq >/dev/null 2>&1; then
        tmp="$json.tmp"
        if jq --argjson p "$port" '.port = $p' "$json" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$json"
        else
            rm -f "$tmp"
        fi
    fi
}

# The container's state word or empty when there is no container by that
# name. Docker answers it directly rather than in a table, so there is no
# column to parse and nothing a format change can silently invert: the
# states are created, running, paused, restarting, removing, exited and
# dead, and every caller here treats "running" as up and any other
# non-empty word as down.
container_state() {
    local name="$1" out=""
    out="$(ctr inspect -f '{{.State.Status}}' "$name" 2>/dev/null)" || out=""
    printf '%s' "$out" \
        | head -1 \
        | tr '[:upper:]' '[:lower:]' \
        | tr -d '[:space:]'
    printf '\n'
}

# The entrypoint writes <project>/.claude-dev/run/orca-web-url.txt (0600 --
# the fragment carries a pairing code) once Orca is serving. That file is
# the handshake between the two halves: everything before it is the Mac
# starting a VM, everything after is a browser talking to Orca.
# How long to wait for that handshake, and the one question that decides
# it: is this start going to INSTALL something? The image answers it. A
# folder running this template's image has the whole toolchain the
# moment the container starts and serves in seconds; a folder on the
# runtime path (plain ubuntu:24.04, where a failed build lands)
# installs apt on every start and the payload on the first, and
# needs minutes.
#
# A folder's own cache is deliberately NOT part of this. Keying the short
# timeout on it is what killed a working container at 2m12s on a real Mac
# (2026-09-06): the cache was full, so the wait was 120 s, while the apt
# half the cache cannot hold was still installing.
folder_installs_toolchain() {
    [ "$(image_source "$1")" = "runtime" ]
}

weburl_timeout() {
    local dir="$1"
    if [ -n "${CLAUDE_ORCA_WEBURL_TIMEOUT:-}" ]; then
        printf '%s\n' "$CLAUDE_ORCA_WEBURL_TIMEOUT"
    elif folder_installs_toolchain "$dir"; then
        printf '%s\n' "${CLAUDE_ORCA_WEBURL_TIMEOUT_RUNTIME:-1800}"
    else
        printf '%s\n' "120"
    fi
}

# Returns 0 with the URL on stdout, 1 on timeout, and -- when a container
# name is given -- 2 the moment that container is no longer running: a
# dead container writes no URL, so waiting out the timeout on it (a real
# Mac run on 2026-09-06 sat 1800 s on a VM setup.sh had already killed)
# is a wait for nothing. A just-created container may not be listed yet,
# so an empty state only counts as dead once a running state has been
# seen -- or, for a container that is never listed at all (removed, or
# gone before the first poll), once 20 s have passed with no running state
# ever observed: `container run -d` has long returned by then.
# Any other non-empty state (stopped, exited) counts at once.
wait_for_web_url() {
    local dir="$1" name="${2:-}" file setup_log timeout waited=0 url="" runtime="" last="" line="" state="" seen_running="" unlisted=0
    file="$dir/.claude-dev/run/orca-web-url.txt"
    setup_log="$dir/.claude-dev/run/setup.log"
    timeout="$(weburl_timeout "$dir")"
    if folder_installs_toolchain "$dir"; then runtime=1; fi
    while [ "$waited" -lt "$timeout" ]; do
        if [ -s "$file" ]; then
            url="$(head -1 "$file")"
            if [ -n "$url" ]; then
                printf '%s\n' "$url"
                return 0
            fi
        fi
        if [ -n "$name" ]; then
            state="$(container_state "$name")"
            case "$state" in
                running) seen_running=1; unlisted=0 ;;
                "")
                    if [ -n "$seen_running" ]; then return 2; fi
                    unlisted=$((unlisted + 1))
                    if [ "$unlisted" -ge 20 ]; then return 2; fi
                    ;;
                *)       return 2 ;;
            esac
        fi
        if [ "$waited" = "0" ]; then
            echo "Waiting for Orca to come up inside the container..." >&2
        fi
        # While the toolchain installs, the silence is the whole problem:
        # setup.sh is working, so show its last line every 15 s.
        if [ -n "$runtime" ] && [ "$((waited % 15))" = "0" ] && [ -s "$setup_log" ]; then
            line="$(tail -1 "$setup_log" 2>/dev/null)"
            if [ -n "$line" ] && [ "$line" != "$last" ]; then
                echo "  installing toolchain: $line" >&2
                last="$line"
            fi
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# The pairing URL Orca minted for this container -- what a desktop Orca on
# the Mac needs to attach to the runtime inside it -- by either of the two
# paths a folder can have it.
#
# run/orca-pairing-url.txt is serve's own `Pairing URL:` line, written by
# the entrypoint (0600; it is a credential). It only exists in a folder
# whose image carries that change, which is exactly why it is not the only
# path: the web URL's fragment has carried the same URL percent-encoded
# since v3, so `#pairing=orca%3A%2F%2Fpair%3Fcode%3D...` decoded is the
# same string, and every folder already running has it. A change that can
# only arrive in a rebuilt image reaches nobody.
#
# Decoding in bash 3.2 and no more: every %XX becomes \xXX and printf '%b'
# turns those into bytes. Prints nothing and returns 1 when neither file
# yields an orca://pair URL -- a truncated write or a web URL with no
# fragment is "no pairing URL", never a half-decoded one.
pairing_url_of() {
    local dir="$1" pfile wfile url="" frag=""
    pfile="$dir/.claude-dev/run/orca-pairing-url.txt"
    wfile="$dir/.claude-dev/run/orca-web-url.txt"

    if [ -s "$pfile" ]; then
        url="$(head -1 "$pfile")"
        case "$url" in
            orca://pair*) printf '%s\n' "$url"; return 0 ;;
        esac
    fi

    if [ -s "$wfile" ]; then
        url="$(head -1 "$wfile")"
        case "$url" in
            *'#pairing='*) frag="${url#*#pairing=}" ;;
            *)             frag="" ;;
        esac
        if [ -n "$frag" ]; then
            url="$(printf '%b' "${frag//%/\\x}")"
            case "$url" in
                orca://pair*) printf '%s\n' "$url"; return 0 ;;
            esac
        fi
    fi

    return 1
}

open_url() {
    local url="$1"
    if [ "${CLAUDE_ORCA_OPEN:-1}" = "0" ]; then
        return 0
    fi
    open "$url" || echo "Could not run 'open' -- paste this into a browser: $url" >&2
}

# --- the desktop hand-off (S3, claude-orca-8uo.4) -------------------------
#
# With ui = desktop the client is the Mac's own Orca.app and this folder's
# container is its runtime, attached over Orca's own pairing protocol
# (.claude/plans/desktop-orca.md). Nothing about the boundary moves: every
# agent, shell and tool call still runs inside the container. Three facts
# from the probe against 1.4.197 (bead claude-orca-8uo.1) shape every line
# below:
#
#   * `orca status --json` EXITS 0 whether the runtime is reachable or
#     not. The boolean in the JSON is the only signal there is.
#   * a second `environment add` under a name that already exists is
#     refused outright ("A server named ... already exists."), and a
#     recreated container mints a fresh offer -- so the saved one is
#     removed first, every time.
#   * the app registers no `orca://` protocol handler, so it is launched
#     by bundle (`open -a`) and paired through its CLI.
#
# All of it is best effort. The container is up and serving either way and
# Orca Web is a complete client, so a hand-off that cannot even start (no
# app, no CLI, no pairing offer, a runtime that never answers) says why on
# stderr and falls back to the browser rather than failing the open.

# The bundle a folder that has ALREADY decided it is a desktop folder
# hands its runtime to. An explicit CLAUDE_ORCA_APP is authoritative here
# on any host: find_orca_app's Darwin gate belongs to the REGISTER
# decision (a Linux host has no desktop Orca to find, so it registers a
# web folder whatever the environment says), and is the wrong question to
# ask of a folder whose `ui` key already says desktop and whose owner has
# named the bundle outright.
desktop_app() {
    if [ -n "${CLAUDE_ORCA_APP:-}" ]; then
        [ -d "$CLAUDE_ORCA_APP" ] || return 1
        printf '%s\n' "$CLAUDE_ORCA_APP"
        return 0
    fi
    find_orca_app
}

# The name this folder's runtime is saved under in the app: the container's
# own name, deliberately -- one folder, one name, on both sides.
orca_env_name() { container_name "$1"; }

# A Mac-side result, so run/ and not state/.
orca_env_file() { printf '%s\n' "$1/.claude-dev/run/orca-environment.json"; }

# The template's own ORCA_VERSION default, read rather than repeated: the
# pin lives at Dockerfile:30 and is mirrored once in setup.sh, and a third
# copy here is a third thing to forget. Empty when there is no Dockerfile
# to read, which is an answer -- the version is then simply not knowable.
dockerfile_orca_version() {
    local f="$TEMPLATE_ROOT/Dockerfile" v=""
    if [ -f "$f" ]; then
        v="$(sed -n 's/^ARG ORCA_VERSION=\([^ ]*\).*$/\1/p' "$f" | head -1)"
    fi
    printf '%s\n' "$v"
}

# The Orca version of the app on THIS host, or empty -- no app, no Mac, or
# a bundle whose Info.plist will not answer.
app_orca_version() {
    local app=""
    app="$(find_orca_app 2>/dev/null)" || return 0
    orca_app_version "$app"
}

# The version the image is BUILT at (S4/claude-orca-8uo.5): the app's when
# this host has one, because the app is the client that has to attach to
# it, and the template default when it has not. One answer, used by both
# the tag and the build arg, so the image a folder asks for and the image
# it would build are never two different things.
wanted_orca_version() {
    local v=""
    v="$(app_orca_version)"
    if [ -z "$v" ]; then v="$(dockerfile_orca_version)"; fi
    printf '%s\n' "$v"
}

# The ORCA_VERSION the image THIS MACHINE actually holds is at, read off
# the tag the build gave it. Orca's protocol check is a hard refusal on a
# mismatch (client-too-old / server-too-old), not a warning, so a
# difference between it and the app is worth saying out loud -- and since
# S4 the wanted version comes FROM the app, asking what this folder wants
# could never show one. Only the daemon can: a folder whose app moved and
# has not rebuilt still has the old image sitting there. Falls back to the
# template default when there is nothing of ours to read.
image_orca_version() {
    local repo="" repository tag id v=""
    repo="$(image_ref)"
    repo="${repo%:*}"
    if [ "${CTR_RUNTIME:-docker}" != "local" ]; then
        while read -r repository tag id; do
            [ -n "$tag" ] || continue
            [ "$repository" = "$repo" ] || continue
            case "$tag" in *-orca?*) ;; *) continue ;; esac
            v="${tag##*-orca}"
            break
        done <<IMAGES
$(ctr images --format '{{.Repository}} {{.Tag}} {{.ID}}' 2>/dev/null || true)
IMAGES
    fi
    if [ -z "$v" ]; then v="$(dockerfile_orca_version)"; fi
    printf '%s\n' "$v"
}

# Three readers for the CLI's --json answers. jq when the Mac has one and
# a glob when it does not: every other config read here is guarded the
# same way, and a missing jq must not be what silently turns a desktop
# folder into a browser folder.
orca_json_ok() {
    local json="$1" v=""
    if command -v jq >/dev/null 2>&1; then
        v="$(printf '%s' "$json" | jq -r '.ok // false' 2>/dev/null || echo false)"
        [ "$v" = "true" ]
        return
    fi
    case "$json" in
        *'"ok":true'*|*'"ok": true'*) return 0 ;;
    esac
    return 1
}

orca_json_reachable() {
    local json="$1" v=""
    if command -v jq >/dev/null 2>&1; then
        v="$(printf '%s' "$json" | jq -r '.result.runtime.reachable // false' 2>/dev/null || echo false)"
        [ "$v" = "true" ]
        return
    fi
    case "$json" in
        *'"reachable":true'*|*'"reachable": true'*) return 0 ;;
    esac
    return 1
}

orca_json_env_id() {
    local json="$1" v=""
    if command -v jq >/dev/null 2>&1; then
        v="$(printf '%s' "$json" | jq -r '.result.environment.id // empty' 2>/dev/null || true)"
    else
        v="$(printf '%s' "$json" | tr '{},' '\n' \
             | sed -n 's/^"id":"\([^"]*\)"$/\1/p' | head -1)"
    fi
    [ "$v" = "null" ] && v=""
    printf '%s\n' "$v"
}

# --- the conduit profile (claude-orca-qhq) --------------------------------
#
# Orca.app can open LOCAL workspaces (agents run on the Mac, no container
# around them) and 1.4.197 has no knob to refuse them. The detection at
# hand-off (claude-orca-4x7) was not enough, so the app is never launched
# on the user's own Orca profile again: it gets a profile the launcher owns
# outright, one per folder, that holds only this folder's environment. The
# user's own Orca profile is never touched.

# state/, not run/: the profile is authority the Mac side owns, the same
# footing as the container's own state, and ./claude-dev --teardown removes
# it exactly as it removes everything else under state/.
orca_profile_dir() { printf '%s/.claude-dev/state/orca-profile\n' "$1"; }

orca_profile_ensure() {
    local dir="$1" profile
    profile="$(orca_profile_dir "$dir")"
    mkdir -p "$profile"
    chmod 700 "$profile"
    printf '%s\n' "$profile"
}

# The conduit's own promise: it starts every session with zero local
# projects. `orca-data.json`'s `.repos` is where the app persists them --
# the CLI's own `repo list --json` reads the same store back -- and there
# is no `orca repo rm`, so this writes the store directly. Quiet whenever
# there is nothing to clear or no jq to clear it with (jq is required
# elsewhere already; missing here just means this run cannot self-heal a
# leak it also cannot detect any other way).
orca_profile_clear_repos() {
    local profile="$1" f tmp
    f="$profile/orca-data.json"
    [ -f "$f" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    case "$(jq -c '.repos // []' "$f" 2>/dev/null || echo '[]')" in
        '[]') return 0 ;;
    esac
    tmp="$f.tmp.$$"
    if jq '.repos = []' "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
    fi
}

# One status check against the folder's own profile -- the shape an
# earlier ./claude-dev left running behind it, in which case this run
# never launches a second instance.
orca_profile_reachable() {
    local cli="$1" profile="$2" out=""
    out="$(ORCA_USER_DATA_PATH="$profile" "$cli" status --json 2>/dev/null || true)"
    orca_json_reachable "$out"
}

# Poll until the app's runtime answers, <= CLAUDE_ORCA_ORCA_WAIT seconds
# (60, the plan's number). The exit code says nothing, so the JSON is read
# every time.
orca_wait_reachable() {
    local cli="$1" profile="$2" limit waited=0 out=""
    limit="${CLAUDE_ORCA_ORCA_WAIT:-60}"
    case "$limit" in
        ''|*[!0-9]*) limit=60 ;;
    esac
    while :; do
        out="$(ORCA_USER_DATA_PATH="$profile" "$cli" status --json 2>/dev/null || true)"
        if orca_json_reachable "$out"; then
            return 0
        fi
        if [ "$waited" -ge "$limit" ]; then
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

# Launch the app, wait for it, and save this folder's runtime as an
# environment. Returns 0 when the desktop app is this folder's client --
# whether or not the environment saved, because the block that follows
# says which -- and 1 when the caller should open the browser instead.
orca_hand_off() {
    local dir="$1" app="" cli="" pair="" name="" appver="" imgver="" out="" id="" profile=""

    app="$(desktop_app)" || {
        echo "  no Orca.app on this Mac -- opening Orca Web instead ($ORCA_DOWNLOAD_URL)" >&2
        return 1
    }
    pair="$(pairing_url_of "$dir")" || {
        echo "  this container published no pairing offer -- opening Orca Web instead" >&2
        return 1
    }
    cli="$(orca_cli "$app")" || {
        echo "  $app ships no orca CLI -- opening Orca Web instead" >&2
        return 1
    }

    # The launcher's own profile for this folder, never the user's own
    # Orca -- and it starts this session, as every session, with zero
    # local projects (claude-orca-qhq).
    profile="$(orca_profile_ensure "$dir")"
    orca_profile_clear_repos "$profile"

    appver="$(orca_app_version "$app")"
    imgver="$(image_orca_version)"
    if [ -n "$appver" ] && [ -n "$imgver" ] && [ "$appver" != "$imgver" ]; then
        {
            echo "  Warning: Orca.app is $appver and this folder's image runs Orca $imgver."
            echo "           Orca refuses a protocol mismatch outright, so if the app will"
            echo "           not attach, './claude-dev --update' rebuilds at the app's version."
        } >&2
    fi

    name="$(orca_env_name "$dir")"
    # Nothing may claim a saved environment until this run saves one.
    rm -f "$(orca_env_file "$dir")"

    if [ "${CLAUDE_ORCA_OPEN:-1}" != "0" ]; then
        if orca_profile_reachable "$cli" "$profile"; then
            : # an earlier ./claude-dev left this folder's conduit running
        else
            open -n -a "$app" --args --user-data-dir="$profile" \
                || echo "  Could not launch $app" >&2
        fi
    fi
    if ! orca_wait_reachable "$cli" "$profile"; then
        echo "  Orca.app did not answer in ${CLAUDE_ORCA_ORCA_WAIT:-60}s -- opening Orca Web instead" >&2
        return 1
    fi

    # Remove first, always. The name may be saved against the PREVIOUS
    # container's offer, which is dead, and `add` on a name that exists is
    # refused rather than replaced; an rm of a name that was never there
    # answers ok:false and is the no-op it looks like. (The bead says
    # "rm if the name exists"; doing it unconditionally is the same answer
    # without having to guess the shape of `environment list --json`.)
    ORCA_USER_DATA_PATH="$profile" "$cli" environment rm --environment "$name" --json >/dev/null 2>&1 || true

    out="$(ORCA_USER_DATA_PATH="$profile" "$cli" environment add --name "$name" --pairing-code "$pair" --json 2>/dev/null || true)"
    if orca_json_ok "$out"; then
        id="$(orca_json_env_id "$out")"
        printf '{"name":"%s","id":"%s"}\n' "$name" "$id" > "$(orca_env_file "$dir")"
        return 0
    fi

    # The manual fallback that always works: the offer goes on the
    # clipboard and the block below says where to paste it.
    if command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$pair" | pbcopy || true
        echo "  Orca could not save the environment; the pairing URL is on your clipboard." >&2
    else
        echo "  Orca could not save the environment; the pairing URL is $pair" >&2
    fi
    return 0
}

# Teardown's half: the app is left holding a saved environment whose
# runtime is about to stop existing, and the profile it ran that
# environment on has no reason to survive the folder either -- the user's
# own Orca profile was never the one holding it. Quiet and best effort --
# no app, no CLI or an environment that was never saved are all "nothing
# to remove".
orca_env_forget() {
    local dir="$1" app="" cli="" profile
    profile="$(orca_profile_dir "$dir")"
    app="$(desktop_app)" || { rm -rf "$profile"; return 0; }
    cli="$(orca_cli "$app")" || { rm -rf "$profile"; return 0; }
    ORCA_USER_DATA_PATH="$profile" "$cli" environment rm --environment "$(orca_env_name "$dir")" --json >/dev/null 2>&1 || true
    rm -f "$(orca_env_file "$dir")"
    rm -rf "$profile"
}

# The paths a `repo list --json` answer names. `repo list` with no
# --environment is the local list; there is no --host flag in 1.4.197
# (bead claude-orca-8uo.1, correcting the plan).
orca_json_repo_paths() {
    local json="$1"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r '.result.repos[]?.path // empty' 2>/dev/null || true
    else
        printf '%s' "$json" | tr '{},' '\n' | sed -n 's/^"path":"\(.*\)"$/\1/p'
    fi
}

# Is there ANY repo in it? Once the app only ever runs on a profile the
# launcher owns and only ever adds one environment to it, a local repo
# showing up there at all -- whatever path it names -- is a leak: nothing
# else ever puts one there but the app's own "+ Add project", which
# 1.4.197 has no knob to disable (claude-orca-qhq).
orca_lists_any_repo() {
    local json="$1" p=""
    while IFS= read -r p; do
        [ -n "$p" ] && return 0
    done <<REPOS
$(orca_json_repo_paths "$json")
REPOS
    return 1
}

# Nothing to pick, nothing named "Runtime Environments" (1.4.197 has no
# such pane -- confirmed against /opt/Orca/resources/app.asar, which
# titles the pane "Remote Hosts" both in Settings and in the status bar's
# own host popover). orca_hand_off already ran `environment add`, so by
# the time this prints the app already shows it Connected; what is left
# to say is where it landed. The app's sidebar groups workspaces under a
# PROJECT named after the repo (derive_project_name), and each workspace
# under that project carries a badge with the environment name
# (orca_env_name, truncated in the UI) -- that mapping, not an instruction
# to go pick something, is the whole hand-off.
#
# When nothing was saved the first line is the click path instead
# (AddRepoHostSelector in app.asar): sidebar "+" -> Add project -> Add
# remote host, then paste the pairing URL that is already on the
# clipboard (orca_hand_off's own pbcopy, above) and name it -- Remote
# Hosts is where it shows up once that is done.
print_desktop_block_v3() {
    local dir="$1" name project file
    name="$(orca_env_name "$dir")"
    project="$(derive_project_name "$dir")"
    file="$(orca_env_file "$dir")"
    if [ -s "$file" ]; then
        cat <<RUNIT

How to run it:
  Orca (the desktop app):  open and attached -- this folder is the project
                           "$project" in the sidebar; workspaces under it
                           badged "$name" run inside the container.
                           (Remote Hosts lists "$name" as Connected.)
  Reopen it later:         ./claude-dev
  A terminal inside it:    ./claude-dev shell
RUNIT
    else
        cat <<RUNIT

How to run it:
  Orca (the desktop app):  sidebar "+" > Add project > Add remote host,
                           paste the pairing URL (it is on the clipboard)
                           and name it "$name"; Remote Hosts then lists it.
  Reopen it later:         ./claude-dev
  A terminal inside it:    ./claude-dev shell
RUNIT
    fi
    orca_local_leak_note "$dir"
}

# The one warning cmd_verify's "local repos" doctor row could give but the
# hand-off never did: this folder's OWN conduit profile can ALSO hold a
# LOCAL project (the app's own "+ Add project", which 1.4.197 has no knob
# to disable), and agents opened there run on the Mac with no container
# around them. A detection, not a prevention -- the CLI has no
# `orca repo rm`, so the fix is naming where it gets cleared. Quiet
# whenever there is no app or no CLI to ask (same gate as cmd_verify's
# "n/a" row): a folder on Linux, or a Mac with no Orca.app, has nothing to
# warn about.
orca_local_leak_note() {
    local dir="$1" app cli profile
    app="$(find_orca_app 2>/dev/null)" || return 0
    cli="$(orca_cli "$app" 2>/dev/null)" || return 0
    profile="$(orca_profile_dir "$dir")"
    orca_lists_any_repo "$(ORCA_USER_DATA_PATH="$profile" "$cli" repo list --json 2>/dev/null || true)" || return 0
    cat <<WARNING

WARNING: this folder's Orca profile holds a LOCAL project.
         It will be emptied at the next ./claude-dev; agents opened
         there meanwhile run on the Mac with no sandbox
         (./claude-dev verify reports it as the "local repos" row).
WARNING
}

# The whole hand-off, in three lines: where Orca is, how to get back to
# it, and how to get a terminal inside the VM.
print_run_it_block_v3() {
    local dir="$1" url="${2:-}" file
    file="$dir/.claude-dev/run/orca-web-url.txt"
    if [ -z "$url" ] && [ -f "$file" ]; then
        url="$(head -1 "$file")"
    fi
    cat <<RUNIT

How to run it:
  Orca (open in a browser):  $url
  Reopen it later:           ./claude-dev
  A terminal inside it:      ./claude-dev shell
RUNIT
}

# `container run -d`. The project is mounted at its own absolute path, so
# every path Orca stores and every path an agent prints means the same
# thing on both sides; the folder-local home becomes /home/agent, so
# credentials and Orca state live and die with the folder.
#
# ... with ONE exception, and it is the reason a Mac could not boot a
# folder at all. Orca's --user-data-dir is where it puts its own unix
# domain sockets: the headless RPC socket it chmods on startup, and the
# daemon socket it publishes with link(2). A macOS bind mount is not a
# Linux filesystem -- Docker Desktop hands it through virtiofs, where a
# socket can be created and then neither chmod'd nor hard-linked:
#
#   chmod('<udd>/o-7563-9c89.sock')            -> EINVAL
#   link('<udd>/.pce...' -> 'daemon-v36.sock') -> ENOENT
#
# Orca takes the first as an unhandled rejection and the second as a fatal
# daemon start, so it never prints a Web client URL and the entrypoint
# gives up on it (verified on this Mac against orca-ide 1.4.197: the same
# image, the same mounts, a user-data-dir on the folder home publishes no
# URL, one on a real Linux filesystem is ready in two seconds). On Linux
# the same bind mount is an ordinary directory where all of this works, so
# the ubuntu-latest e2e stays green; and the macOS CI job runs Docker under
# colima, whose sshfs mount refuses setup.sh's chown outright ("Permission
# denied" on every path in the home, run 34122589713) -- it dies one step
# before Orca and has never reached this.
#
# So Orca's user-data-dir gets a docker volume -- a real Linux filesystem
# at the path Orca already expects. It is named after the container and
# removed by teardown, so the state still dies with the folder; what it
# no longer does is sit in the folder where the Mac can see it.
state_volume() { printf '%s-orca-state\n' "$1"; }

# --- the folder's toolchain cache, on the runtime path only -------------
#
# The built image carries the whole toolchain, so a folder that runs it
# mounts nothing here: a folder directory over /usr/local would HIDE
# the payload the image just shipped and hand that folder a fifteen-minute
# install it does not need.
#
# The runtime path is the exception and the reason this still exists. A
# folder whose image could not be built runs plain ubuntu:24.04, where
# there is no baked anything; setup.sh installs the payload at first start
# into <project>/.claude-dev/toolchain, mounted here over the three paths
# those tools live at, so at least the recreate after it is fast.
#
# One mount per path, never /opt itself: /opt also holds /opt/claude-orca,
# which IS the image's copy of this template.
TOOLCHAIN_MOUNTS="usr-local:/usr/local opt-Orca:/opt/Orca opt-claude:/opt/claude"

container_dns() {
    local dns=""
    if [ -n "${CLAUDE_ORCA_DNS+x}" ]; then
        dns="$CLAUDE_ORCA_DNS"
    else
        dns="$(json_get "$1" '.dns')"
        [ -n "$dns" ] || dns="1.1.1.1"
    fi
    if [ "$dns" = "auto" ]; then dns=""; fi
    printf '%s\n' "$dns"
}

container_create() {
    local dir="$1" name="$2" port="$3" ref src token cpus memory mount theme orkey dns guest
    guest="$(guest_project_dir "$dir")"
    # startup v4: a folder with no reachable prebuilt image runs the public
    # base image with the mounted template's entrypoint as its command --
    # the template clone sits inside the project, which is mounted at its
    # own absolute path, so the path means the same thing on both sides.
    src="$(image_source "$dir")"
    if [ "$src" = "runtime" ]; then
        ref="$BASE_IMAGE"
    else
        ref="$(image_ref)"
    fi
    token="$(gh auth token 2>/dev/null || true)"
    # claude-orca.json's `theme` picks the Orca theme the entrypoint seeds
    # on a folder's first run (dark|light|system); the project name is the
    # beads prefix it inits with.
    theme="$(json_get "$dir" '.theme')"
    [ -n "$theme" ] || theme="dark"
    # ... and `terminalTheme` picks the terminal PALETTE by name -- an Orca
    # builtin, "Homebrew" (green on black) by default. It reaches the folder
    # twice over on purpose: the entrypoint seeds the name for Orca's own
    # renderer, and the shipped .zshrc paints the same colours with OSC
    # escapes, which is the half that does not need the browser to have been
    # seeded or the image to have been rebuilt.
    terminal_theme="$(json_get "$dir" '.terminalTheme')"
    [ -n "$terminal_theme" ] || terminal_theme="Homebrew"
    mkdir -p "$dir/.claude-dev/run" "$dir/.claude-dev/home"
    # Never open a stale pairing URL from a previous container. (An
    # update, which is where a container is deliberately replaced, clears
    # the rest of the previous one's results too -- clear_run_results.)
    rm -f "$dir/.claude-dev/run/orca-web-url.txt"

    # The toolchain cache, made before the run so docker mounts real
    # directories rather than creating root-owned ones of its own -- and
    # only for a folder that is going to install into it.
    if [ "$src" = "runtime" ]; then
        for mount in $TOOLCHAIN_MOUNTS; do
            mkdir -p "$dir/.claude-dev/toolchain/${mount%%:*}"
        done
    fi

    set -- run -d --name "$name" \
        --volume "$dir:$guest" \
        --volume "$dir/.claude-dev/home:/home/agent" \
        --volume "$(state_volume "$name"):/home/agent/.config/orca" \
        -p "127.0.0.1:$port:$port" \
        -e "PROJECT_DIR=$guest" \
        -e "CLAUDE_ORCA_HOST_PROJECT_DIR=$dir" \
        -e "CLAUDE_ORCA_ROOT=$guest" \
        -e "BEADS_DIR=$guest/.beads" \
        -e "ORCA_PORT=$port" \
        -e "HOST_UID=$(id -u)" \
        -e "GH_TOKEN=$token" \
        -e "CLAUDE_ORCA_THEME=$theme" \
        -e "CLAUDE_ORCA_TERMINAL_THEME=$terminal_theme" \
        -e "CLAUDE_ORCA_PROJECT_NAME=$(derive_project_name "$dir")" \
        -e "CLAUDE_ORCA_GIT_NAME=$(git_identity_name)" \
        -e "CLAUDE_ORCA_GIT_EMAIL=$(git_identity_email)"

    # Deliver a scripts/container/* fix without an image rebuild: the
    # entrypoint already baked into today's image reads
    # SETUP="${CLAUDE_ORCA_SETUP:-$TEMPLATE_ROOT/scripts/container/setup.sh}",
    # so pointing that var at the folder's own template clone breaks the
    # gate on the next recreate alone -- no rebuild needed. Guarded on the
    # host path existing so a folder whose template clone predates setup.sh
    # falls through to the baked default instead of naming a file that
    # is not there.
    if [ -f "$dir/.claude-dev/template/scripts/container/setup.sh" ]; then
        set -- "$@" -e \
            "CLAUDE_ORCA_SETUP=$guest/.claude-dev/template/scripts/container/setup.sh"
    fi

    if [ "$src" = "runtime" ]; then
        for mount in $TOOLCHAIN_MOUNTS; do
            set -- "$@" --volume \
                "$dir/.claude-dev/toolchain/${mount%%:*}:${mount#*:}"
        done
    fi

    # qa2.7: only when the folder has a key -- an empty OPENROUTER_API_KEY
    # would read as "set" to the delegate routes. The value is in argv for
    # this one call; the log mirror redacts it.
    orkey="$(openrouter_key_value "$dir")"
    if [ -n "$orkey" ]; then
        set -- "$@" -e "OPENROUTER_API_KEY=$orkey"
    fi

    # The VM's resolver. A real Mac run on 2026-09-06 booted a VM whose
    # own resolv.conf answered nothing, so the toolchain install died on
    # "Temporary failure resolving". `docker run` takes --dns <ip>:
    # CLAUDE_ORCA_DNS wins, then claude-orca.json's `dns`, then 1.1.1.1;
    # "auto" (or CLAUDE_ORCA_DNS set empty) passes no flag and leaves the
    # runtime's own choice alone.
    dns="$(container_dns "$dir")"
    if [ -n "$dns" ]; then
        set -- "$@" --dns "$dns"
    fi

    cpus="$(json_get "$dir" '.cpus')"
    if [ -n "$cpus" ]; then
        set -- "$@" --cpus "$cpus"
    fi
    memory="$(json_get "$dir" '.memory')"
    if [ -n "$memory" ]; then
        set -- "$@" --memory "$memory"
    fi
    # Extra mounts are read-only, always: they are outside the project, so
    # the VM boundary is the only thing keeping them safe.
    while IFS= read -r mount; do
        if [ -n "$mount" ]; then
            set -- "$@" --volume "$mount:ro"
        fi
    done <<EXTRA
$(json_get "$dir" '.extraMounts[]?')
EXTRA

    set -- "$@" "$ref"
    if [ "$src" = "runtime" ]; then
        set -- "$@" bash "$guest/.claude-dev/template/scripts/container/entrypoint.sh"
    fi
    if [ "$CTR_RUNTIME" = "local" ]; then
        echo "==> Starting $name (local runtime: the entrypoint as a host process)"
    else
        echo "==> Starting the container $name ($ref)"
    fi
    # Checked, not trusted: errexit is off inside a function called under
    # `|| return`, so an unchecked failure here would fall through to a
    # two-minute wait for a URL no container is ever going to write.
    if ! ctr "$@" >/dev/null; then
        echo "Error: 'docker run' failed for $name -- see $dir/.claude-dev/run/container.log" >&2
        return 1
    fi
}

# --- config resync ------------------------------------------------------
#
# The image's entrypoint is what normally config-syncs a folder, and on
# 2026-09-08 that turned out to be a delivery path with a hole in it. The
# entrypoint change that makes the folder's own template clone beat the
# image's frozen config/ ships INSIDE the image, so a folder still running
# an older image syncs BACKWARDS -- it overwrites the agent's config dir
# (claude_config_dir(), under the folder's home) with whatever
# config/ said the day that image was built. Both changes that went
# missing that day (green terminal text, /tier's GLM help) were committed,
# were present in the folder's clone, and simply were not in the config
# dir the session actually reads.
# What hid it was the pull: `docker pull` came back 403 on the private
# package, the folder ran its stale local image anyway, and image-source
# still read "pulled", so nothing downstream could tell.
#
# So the host side asks for the sync too, from the one copy that cannot be
# stale -- the folder's own .claude-dev/template -- over `docker exec`,
# once the container is up. config-sync is checksum-gated and idempotent:
# when the entrypoint already did it right this is a single no-op exec,
# and when it did not, this is the repair. That makes the config path
# independent of the image's age, which is the whole point.
#
# It runs AFTER the web URL is published, on purpose. The entrypoint syncs
# before it starts `orca-ide --serve`, so waiting on the URL is what keeps
# two syncs from racing over the same config dir -- both of them `rm -rf`
# and repopulate .claude/commands, and a torn config dir is worse than a
# stale one.
#
# `-u agent` rather than a uid: the entrypoint re-maps agent to HOST_UID,
# so the name is the only stable way to land as the user that owns the
# home. Never fatal -- a folder that is up and serving is not worth
# failing over a config refresh -- and it says which of the two happened.
resync_config() {
    local dir="$1" name="$2" guest before after
    guest="$(guest_project_dir "$dir")"
    before="$(cat "$dir/.claude-dev/run/config-hash" 2>/dev/null || true)"
    if ! ctr exec -u agent "$name" \
            bash "$guest/.claude-dev/template/scripts/config-sync.sh" \
            --project "$guest" --host "$guest/.claude-dev" >/dev/null 2>&1; then
        echo "  config: could not re-sync from the folder's template (continuing)" >&2
        return 0
    fi
    after="$(cat "$dir/.claude-dev/run/config-hash" 2>/dev/null || true)"
    if [ "$before" = "$after" ]; then
        echo "  config: already current"
    else
        echo "  config: re-synced from the folder's template"
    fi
}

cmd_open_v3() {
    local dir="${1:-$PROJECT_SELF}" name port state url rc=0 t0 t1
    [ -d "$dir" ] || { echo "Error: directory does not exist: $dir" >&2; return 1; }
    dir="$(cd "$dir" && pwd -P)"
    if [ ! -f "$(orca_json "$dir")" ]; then
        echo "Error: $dir is not registered -- run './claude-dev register'" >&2
        return 1
    fi
    ctr_init "$dir"

    name="$(container_name "$dir")"
    port="$(choose_port "$dir")"
    persist_port "$dir" "$port"

    state="$(container_state "$name")"
    case "$state" in
        running)
            echo "Container $name is already running."
            ;;
        "")
            container_create "$dir" "$name" "$port" || return 1
            ;;
        *)
            echo "==> Starting $name (was $state)"
            if ! ctr start "$name" >/dev/null; then
                echo "Error: 'container start $name' failed" >&2
                return 1
            fi
            ;;
    esac

    t0="$(date +%s)"
    url="$(wait_for_web_url "$dir" "$name")" || rc=$?
    t1="$(date +%s)"
    if [ "$rc" -ne 0 ]; then
        {
            if [ "$rc" -eq 2 ]; then
                echo "Error: the container $name exited during startup before Orca published a web URL."
            else
                echo "Error: Orca did not publish a web URL within $(weburl_timeout "$dir")s."
            fi
            echo "  Look at what it printed:  ./claude-dev logs"
            if [ "$(image_source "$dir")" = "runtime" ]; then
                echo "  Toolchain install log:    $dir/.claude-dev/run/setup.log"
            fi
            echo "  Serve log:                $dir/.claude-dev/run/orca-serve.log"
            if [ "$rc" -eq 2 ]; then
                echo "  The VM is not running; ./claude-dev starts it again, and ./claude-dev logs shows why it stopped."
            else
                echo "  The VM keeps running: ./claude-dev attaches once it is up."
            fi
            # What setup.sh said last is usually the whole diagnosis
            # ("Unable to locate package ..." on a VM with no DNS), so show
            # it rather than only pointing at the file.
            if [ "$(image_source "$dir")" = "runtime" ] && [ -s "$dir/.claude-dev/run/setup.log" ]; then
                echo ""
                echo "Last lines of the toolchain install:"
                tail -15 "$dir/.claude-dev/run/setup.log" | sed 's/^/  /'
            fi
        } >&2
        return 1
    fi

    # The one number a person actually wants after typing ./claude-dev.
    echo "Orca is up ($((t1 - t0))s)"
    resync_config "$dir" "$name"
    # A desktop folder hands the runtime to the Mac's own Orca.app; a web
    # folder (and a desktop one whose hand-off could not start) opens the
    # browser, which is the same runtime through a different client.
    if [ "$(ui_of "$dir")" = "desktop" ] && orca_hand_off "$dir"; then
        print_desktop_block_v3 "$dir"
    else
        open_url "$url"
        print_run_it_block_v3 "$dir" "$url"
    fi
}

cmd_register_v3() {
    local dir="${1:-$PROJECT_SELF}" name port ui
    [ -d "$dir" ] || { echo "Error: directory does not exist: $dir" >&2; return 1; }
    dir="$(cd "$dir" && pwd -P)"
    name="$(derive_project_name "$dir")"

    mkdir -p "$dir/.claude-dev/home" "$dir/.claude-dev/run" "$dir/.claude-dev/state"
    ctr_init "$dir"

    # Defaults only if absent -- never reset a folder's own edits. cpus and
    # memory null mean "whatever `container` defaults to"; extraMounts are
    # host paths mounted read-only beside the project.
    if [ ! -f "$(orca_json "$dir")" ]; then
        # `-f` follows symlinks, so a link to an existing file takes the
        # branch that leaves a folder's own config alone -- but a DANGLING
        # link passes the guard, and `cat >` then follows it and creates the
        # defaults somewhere outside the project entirely. Unlink first: the
        # guard's answer for the ordinary cases is unchanged, and the write
        # can only ever land at this path.
        rm -f "$(orca_json "$dir")"
        cat > "$(orca_json "$dir")" <<'JSON'
{"version":3,"port":null,"cpus":null,"memory":null,"extraMounts":[]}
JSON
    fi

    write_project_stub "$dir"

    # Desktop or web, decided once. A config that already carries the key
    # keeps it: the folder's own answer outlives the app being installed,
    # moved or removed, and a re-register never quietly moves a working
    # folder to the other UI.
    if [ -z "$(json_get "$dir" '.ui')" ]; then
        case "${CLAUDE_ORCA_UI:-}" in
            desktop) ui="desktop" ;;
            web)     ui="web" ;;
            *)
                ui="web"
                if find_orca_app >/dev/null 2>&1; then ui="desktop"; fi
                ;;
        esac
        persist_ui "$dir" "$ui"
    fi

    port="$(choose_port "$dir")"
    persist_port "$dir" "$port"
    echo "Project '$name' registered at $dir (port $port)"

    # Everything else a folder needs seeding -- .gitignore, attachments/,
    # the beads snapshot, the home .gitconfig -- is the entrypoint's now
    # (startup v4, claude-orca-qa2.9).
    acquire_image "$dir" "$(image_ref)" || return 1

    cmd_open_v3 "$dir"
}

cmd_stop_v3() {
    local dir="${1:-$PROJECT_SELF}" name
    dir="$(cd "$dir" && pwd -P)"
    ctr_init "$dir"
    name="$(container_name "$dir")"
    ctr stop "$name" >/dev/null
    echo "Stopped $name. './claude-dev' starts it again."
}

# A login shell in the VM, in the project directory -- the one place a
# person runs `claude`, `bd` or `git` by hand in this design.
cmd_shell_v3() {
    local dir="${1:-$PROJECT_SELF}" name state
    dir="$(cd "$dir" && pwd -P)"
    ctr_init "$dir"
    name="$(container_name "$dir")"
    state="$(container_state "$name")"
    if [ -z "$state" ]; then
        echo "Error: no container $name -- run './claude-dev' first." >&2
        return 1
    fi
    if [ "$state" != "running" ]; then
        echo "==> Starting $name (was $state)"
        ctr start "$name" >/dev/null
    fi
    # -i -t only when there IS a terminal: `docker exec -t` with no tty
    # fails outright, and the suite runs this with stdin on a pipe.
    if [ -t 0 ]; then
        ctr exec -it --workdir "$(guest_project_dir "$dir")" "$name" zsh -l
    else
        ctr exec --workdir "$(guest_project_dir "$dir")" "$name" zsh -l
    fi
}

cmd_logs_v3() {
    local dir="${1:-$PROJECT_SELF}" name
    dir="$(cd "$dir" && pwd -P)"
    ctr_init "$dir"
    name="$(container_name "$dir")"
    ctr logs -f "$name"
}

doctor_row() {
    printf '  [%-7s] %-17s %s\n' "$1" "$2" "$3"
}

# Six rows, one per thing that has to be true for this folder to open:
# the CLI, the service, the image, the container, the port and the URL the
# entrypoint published. Exits 2 on any finding, so it is usable in a script.
cmd_doctor_v3() {
    local dir="$PROJECT_SELF" rc=0 ref name state port url_file src vol app ver cli
    local prov=0 st nm detail want="" imgver=""
    # Whichever image THIS folder runs: a runtime-install folder has no
    # prebuilt image and never will, so asking after one would be a finding
    # about something it does not use.
    src="$(image_source "$dir")"
    if [ "$src" = "runtime" ]; then
        ref="$BASE_IMAGE"
    else
        ref="$(image_ref)"
    fi

    # The local backend has no CLI, no daemon and no image to ask after, so
    # asking would be three findings about things it does not use. One row
    # naming the runtime, and the rows below carry the rest.
    if [ "$CTR_RUNTIME" = "local" ]; then
        doctor_row ok "runtime" "local -- the entrypoint runs as a host process, no container boundary"
        if [ -d "$dir/.claude-dev" ]; then
            ctr_init "$dir"
        fi
    else
        if command -v docker >/dev/null 2>&1; then
            doctor_row ok "docker CLI" "$(command -v docker)"
        else
            doctor_row missing "docker CLI" "install it: re-run the bootstrap one-liner (or https://docs.docker.com/get-docker/)"
            rc=2
        fi

        if [ -d "$dir/.claude-dev" ]; then
            ctr_init "$dir"
        fi

        if ctr system status >/dev/null 2>&1; then
            doctor_row ok "docker daemon" "running"
        else
            doctor_row missing "docker daemon" "start it: open -a Docker (macOS) or sudo systemctl start docker"
            rc=2
        fi

        if ctr image inspect "$ref" >/dev/null 2>&1; then
            doctor_row ok "image" "$ref"
        else
            doctor_row missing "image" "$ref (build it: ./claude-dev --update)"
            rc=2
        fi
    fi

    # The Mac half of the pair: the Orca.app this folder attaches to and
    # the CLI that goes with it. Never a finding -- a folder on Orca Web
    # needs neither, and a desktop folder whose app has gone still opens
    # in the browser -- so both rows report and neither touches rc.
    app="$(desktop_app)" || app=""
    if [ -n "$app" ]; then
        ver="$(orca_app_version "$app")"
        doctor_row ok "orca app" "$app (${ver:-version unknown})"
    elif [ "$(ui_of "$dir")" = "desktop" ]; then
        doctor_row warn "orca app" "missing -- this folder is set to the desktop Orca: $ORCA_DOWNLOAD_URL"
    else
        doctor_row n/a "orca app" "missing -- this folder is on Orca Web, which needs no app"
    fi

    cli="$(orca_cli "$app")" || cli=""
    if [ -n "$cli" ]; then
        doctor_row ok "orca cli" "$cli"
    else
        doctor_row n/a "orca cli" "missing -- only the desktop Orca ships one"
    fi

    # The two versions that have to agree. They normally do by
    # construction -- the image is built at the app's version and carries
    # it in its tag -- and they come apart in one real way: the user
    # upgraded Orca.app and this folder has not rebuilt yet. Never a
    # finding: the folder still opens, on Orca Web if nothing else, and
    # one rebuild fixes it. So a mismatch warns and leaves rc alone.
    want="$(wanted_orca_version)"
    imgver="$(image_orca_version)"
    if [ "$src" = "runtime" ]; then
        doctor_row n/a "orca versions" "app ${ver:-unknown} -- the runtime path installs orca ${want:-unknown} in the VM"
    elif [ -n "$imgver" ] && [ -n "$want" ] && [ "$imgver" != "$want" ]; then
        doctor_row warn "orca versions" "app ${ver:-$want}, image $imgver -- Orca refuses a protocol mismatch; ./claude-dev --update rebuilds the image at $want"
    else
        doctor_row ok "orca versions" "orca ${want:-unknown} -- the app and this folder's image agree"
    fi

    # built or runtime -- which one it is says whether this folder is
    # running this template's image or installing its toolchain in the VM.
    if [ -n "$src" ]; then
        doctor_row ok "image source" "$src"
    else
        doctor_row warn "image source" "unknown -- no $dir/.claude-dev/run/image-source"
    fi

    if [ ! -f "$(orca_json "$dir")" ]; then
        doctor_row missing "project" "$dir is not registered (run the bootstrap one-liner)"
        return 2
    fi

    name="$(container_name "$dir")"
    state="$(container_state "$name")"
    if [ -z "$state" ]; then
        doctor_row missing "container" "$name does not exist (run ./claude-dev)"
        rc=2
    elif [ "$state" = "running" ]; then
        doctor_row ok "container" "$name (running)"
    else
        doctor_row warn "container" "$name ($state) -- ./claude-dev starts it"
    fi

    # Orca cannot keep its user-data-dir on the folder home (a Mac bind
    # mount cannot chmod or link a unix socket), so it lives here; a
    # missing volume is not a fault, just a folder that has not started.
    if [ "$CTR_RUNTIME" != "local" ]; then
        vol="$(state_volume "$name")"
        if ctr volume inspect "$vol" >/dev/null 2>&1; then
            doctor_row ok "Orca state" "$vol (docker volume, mounted at /home/agent/.config/orca)"
        else
            doctor_row warn "Orca state" "no volume $vol yet -- ./claude-dev creates it"
        fi
    fi

    port=""
    if [ -f "$dir/.claude-dev/run/port" ]; then
        port="$(head -1 "$dir/.claude-dev/run/port")"
    fi
    if [ -n "$port" ]; then
        doctor_row ok "port" "$port (published on 127.0.0.1)"
    else
        doctor_row missing "port" "no $dir/.claude-dev/run/port -- run './claude-dev register'"
        rc=2
    fi

    # qa2.7: optional, so absence is a fact and never a finding -- the
    # value itself is never printed, only whether the folder has one.
    if [ -n "$(openrouter_key_value "$dir")" ]; then
        doctor_row ok "openrouter key" "present -- $(openrouter_key_file "$dir")"
    else
        doctor_row n/a "openrouter key" "absent -- optional: ./claude-dev key openrouter"
    fi

    # The URL itself is a credential (the fragment carries the pairing
    # code), so the doctor names the file, never its contents.
    url_file="$dir/.claude-dev/run/orca-web-url.txt"
    if [ -s "$url_file" ]; then
        doctor_row ok "web url" "published -- $url_file"
    else
        doctor_row missing "web url" "not published yet -- $url_file"
        rc=2
    fi

    # ... and one row per provisioning step (S5, claude-orca-dbu.5). The
    # steps run inside the container and write their status there; the
    # container is asked for them, the way `claude-dev verify` asks
    # verify-folder.sh, so a folder whose provisioning half failed cannot
    # look healthy from this side. Only worth asking a container that is
    # up -- one that is not has already been reported two rows above.
    if [ "$state" = "running" ]; then
        prov=0
        while IFS="$(printf '\t')" read -r st nm detail; do
            [ -n "$st" ] || continue
            prov=$((prov + 1))
            case "$st" in
                ok)  doctor_row ok   "$nm" "$detail" ;;
                n/a) doctor_row n/a  "$nm" "$detail" ;;
                *)   doctor_row FAIL "$nm" "$detail"; rc=2 ;;
            esac
        done <<PROVISION
$(ctr exec -u agent "$name" bash "$(guest_project_dir "$dir")/.claude-dev/template/bin/provision" status --tsv 2>/dev/null || true)
PROVISION
        # No rows is not a pass and not a fault: a container that has only
        # just come up has not finished provisioning, and one built from an
        # image older than this has no `provision` to ask.
        [ "$prov" -eq 0 ] && doctor_row warn "provisioning" "no step statuses yet -- ./claude-dev logs, or ./claude-dev --update"
    fi

    return "$rc"
}

# ===== claude-dev verify ================================================
#
# The doctor answers "can this folder open at all" -- six rows about the
# CLI, the daemon, the image, the container, the port and the URL. It says
# nothing about whether the folder is SET UP: the rulebook, the agents, the
# hooks, the git identity, the Claude first-run keys, Orca's worktree base,
# the beads database. All of that is seeded by code that logs a line and
# moves on, and until now nothing read any of it back -- so a folder whose
# seeding half failed looked exactly like one that worked, which is how
# "the basic things I asked to exist seem to be fundamentally missing"
# became a reasonable thing to conclude on 2026-09-07.
#
# The rows that have to be asked inside the container are asked there
# (scripts/container/verify-folder.sh prints them tab-separated); the ones
# only the Mac can answer are here.

# The image ref a container is actually running.
docker_image_of() {
    ctr inspect -f '{{.Config.Image}}' "$1" 2>/dev/null | head -1
}

cmd_verify_v3() {
    local dir="${1:-$PROJECT_SELF}" name state rc=0 url_file port st nm detail rows
    local app="" cli="" profile=""
    [ -d "$dir" ] || { echo "Error: directory does not exist: $dir" >&2; return 1; }
    dir="$(cd "$dir" && pwd -P)"
    if [ ! -f "$(orca_json "$dir")" ]; then
        echo "Error: $dir is not registered -- run the bootstrap one-liner" >&2
        return 1
    fi
    ctr_init "$dir"
    name="$(container_name "$dir")"

    echo "Verifying $dir"

    state="$(container_state "$name")"
    if [ "$state" = "running" ]; then
        doctor_row ok "container" "$name (running)"
    else
        doctor_row missing "container" "$name is ${state:-absent} -- run ./claude-dev first"
        return 2
    fi

    doctor_row ok "image" "$(image_source "$dir") -- $(docker_image_of "$name")"

    port=""
    [ -f "$dir/.claude-dev/run/port" ] && port="$(head -1 "$dir/.claude-dev/run/port")"
    if [ -n "$port" ]; then
        doctor_row ok "port" "$port (published on 127.0.0.1)"
    else
        doctor_row missing "port" "no $dir/.claude-dev/run/port"
        rc=2
    fi

    url_file="$dir/.claude-dev/run/orca-web-url.txt"
    if [ -s "$url_file" ]; then
        doctor_row ok "web url" "published -- $url_file"
    else
        doctor_row missing "web url" "not published -- $url_file"
        rc=2
    fi

    # The one row only the Mac can answer, and the guard for the one risk
    # the desktop client adds (.claude/plans/desktop-orca.md S5,
    # claude-orca-qhq): Orca's app can open LOCAL workspaces, which run
    # agents on the Mac with no container around them, and 1.4.197 has no
    # knob to disable them. The launcher only ever launches the app on
    # THIS folder's own conduit profile, never the user's own Orca -- this
    # reads that profile's own local list back and FAILs on any repo in
    # it, whatever path it names, since nothing else is ever added there.
    # A detection, not a prevention. `desktop_app()`, not `find_orca_app()`
    # -- once ui already says desktop, asking whether THIS host currently
    # looks like a Mac is the wrong question (same reasoning as
    # cmd_doctor_v3's own "orca app" row).
    if [ "$(ui_of "$dir")" != "desktop" ]; then
        doctor_row n/a "local repos" "this folder is on Orca Web -- nothing here can open the folder outside the container"
    else
        app="$(desktop_app)" || app=""
        if [ -n "$app" ]; then
            cli="$(orca_cli "$app")" || cli=""
        fi
        if [ -z "$cli" ]; then
            doctor_row n/a "local repos" "no Orca.app on this host -- nothing here can open the folder outside the container"
        else
            profile="$(orca_profile_dir "$dir")"
            if [ ! -d "$profile" ]; then
                doctor_row FAIL "local repos" "this folder's Orca profile is missing -- run ./claude-dev to create it"
                rc=2
            elif orca_lists_any_repo "$(ORCA_USER_DATA_PATH="$profile" "$cli" repo list --json 2>/dev/null || true)"; then
                doctor_row FAIL "local repos" "this folder's Orca profile holds a LOCAL project -- agents opened there run on the Mac, outside this container; ./claude-dev empties it at the next launch"
                rc=2
            else
                doctor_row ok "local repos" "this folder's Orca profile holds no local project"
            fi
        fi
    fi

    # ... and everything the container can see for itself.
    rows=0
    while IFS="$(printf '\t')" read -r st nm detail; do
        [ -n "$st" ] || continue
        rows=$((rows + 1))
        case "$st" in
            ok)  doctor_row ok   "$nm" "$detail" ;;
            n/a) doctor_row n/a  "$nm" "$detail" ;;
            *)   doctor_row FAIL "$nm" "$detail"; rc=2 ;;
        esac
    done <<VERIFY
$(ctr exec "$name" bash /opt/claude-orca/scripts/container/verify-folder.sh 2>/dev/null || true)
VERIFY

    # No rows at all is the ONE answer that must never read as a pass. It
    # is what a container built from an image older than this checklist
    # gives back -- the script is not in it, the exec fails, and the four
    # Mac rows above would otherwise stand alone and say everything is
    # fine. Which is exactly the failure this command exists to end.
    if [ "$rows" -eq 0 ]; then
        doctor_row FAIL "checklist" "the container answered nothing -- its image predates verify-folder.sh; ./claude-dev --update"
        rc=2
    fi

    if [ "$rc" -eq 0 ]; then
        echo "Everything this folder promises is there."
    else
        echo "Some of what this folder promises is missing (the FAIL rows above)." >&2
        echo "  ./claude-dev --update recreates the container and re-runs the seeding." >&2
    fi
    return "$rc"
}

cmd_update_v3() {
    local dir="${1:-$PROJECT_SELF}" tmpl before after ref name state
    local img_before="" img_after=""
    tmpl="$HOST_DIR/template"
    if [ ! -d "$tmpl/.git" ]; then
        echo "Error: no template clone at $tmpl -- re-run the bootstrap one-liner." >&2
        return 1
    fi
    dir="$(cd "$dir" && pwd -P)"
    ctr_init "$dir"

    echo "==> Updating the template at $tmpl"
    before="$(git -C "$tmpl" rev-parse HEAD 2>/dev/null || echo unknown)"
    # Same managed clone, same abort, same answer as bootstrap.sh: a local
    # change here is something that got written into a directory the tool
    # owns, and `pull --ff-only` refuses to move past it. Stash it, name
    # the stash, and say how to get it back.
    if [ -n "$(git -C "$tmpl" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        echo "  the template clone has local changes; stashing them:"
        git -C "$tmpl" status --short --untracked-files=no | sed 's/^/    /'
        if git -C "$tmpl" stash push --quiet \
                -m "claude-orca update $(date -u +%Y-%m-%dT%H:%M:%SZ)"; then
            echo "    stashed -- recover with: git -C $tmpl stash pop"
        else
            echo "    could not stash them; the pull below may fail" >&2
        fi
    fi
    git -C "$tmpl" pull --ff-only
    after="$(git -C "$tmpl" rev-parse HEAD)"
    if [ "$before" = "$after" ]; then
        echo "  template: already up to date (${after:0:7})"
    else
        echo "  template: ${before:0:7} -> ${after:0:7}"
    fi

    echo "==> Relinking $HOST_DIR/bin"
    "$SCRIPT_DIR/link-bin.sh" "$HOST_DIR"

    # The same decision as registration: an update whose build works moves
    # the folder onto the freshly built image, and one whose build cannot
    # moves it onto the base image and its runtime install.
    ref="$(image_ref)"
    # A rebuild that changed nothing and one that changed everything look
    # alike from out here -- the id says whether this folder moved.
    img_before="$(image_id_short "$ref")"
    acquire_image "$dir" "$ref" || return 1
    img_after="$(image_id_short "$ref")"
    if [ -n "$img_after" ]; then
        if [ -z "$img_before" ]; then
            echo "  image: $img_after (new)"
        elif [ "$img_before" = "$img_after" ]; then
            echo "  image: already up to date ($img_after)"
        else
            echo "  image: $img_before -> $img_after"
        fi
        # Only when an image of ours is what this folder runs: on the
        # runtime path there is no version of ours to collect. This read
        # "pulled" until the build replaced the pull, which record_image_
        # source no longer writes -- so the gate was never true and every
        # superseded image stayed on disk.
        if [ "$(image_source "$dir")" = "built" ]; then
            prune_old_images "$ref" "$img_after"
        fi
    fi

    # Recreate rather than restart: a new image only takes effect in a new
    # container, and everything that matters is in the mounted folder --
    # or, for Orca's own user-data-dir, in the named volume, which is why
    # this removes the container and never the volume.
    name="$(container_name "$dir")"
    state="$(container_state "$name")"
    if [ -n "$state" ]; then
        echo "==> Recreating $name"
        ctr stop "$name" >/dev/null 2>&1 || true
        ctr rm "$name" >/dev/null 2>&1 || true
    fi
    # The container that wrote run/ is gone, so its results go with it:
    # cmd_open_v3 below chooses the port again and the new container
    # writes its own URL and logs.
    clear_run_results "$dir"
    cmd_open_v3 "$dir"
}

cmd_teardown_v3() {
    local purge=0 dir="$PROJECT_SELF" name project snap rc_file
    while [ $# -gt 0 ]; do
        case "$1" in
            --purge-beads) purge=1 ;;
            -*) echo "Unknown option: $1" >&2; return 1 ;;
            *)  dir="$1" ;;
        esac
        shift
    done
    [ -d "$dir" ] || { echo "Error: directory does not exist: $dir" >&2; return 1; }
    dir="$(cd "$dir" && pwd -P)"
    ctr_init "$dir"

    project="$(derive_project_name "$dir")"
    name="$(container_name "$dir")"
    # Before the container goes: the desktop app is holding a saved
    # environment that points at a runtime which is about to stop
    # existing, and an environment that answers nothing is worse than no
    # environment at all.
    if [ "$(ui_of "$dir")" = "desktop" ]; then
        orca_env_forget "$dir"
    fi
    ctr stop "$name" >/dev/null 2>&1 || true
    ctr rm "$name" >/dev/null 2>&1 || true
    # Orca's user-data-dir is the one piece of folder state that lives in a
    # volume rather than in .claude-dev (see state_volume): teardown is
    # what keeps "dies with the folder" true of it. A `docker rm` on the
    # container never touches a NAMED volume, so this is not redundant.
    ctr volume rm "$(state_volume "$name")" >/dev/null 2>&1 || true

    snap="$(snapshot_beads "$dir" "$project")"
    if [ -n "$snap" ]; then
        echo "Beads snapshot saved to $snap"
    fi

    # `rm -rf` on the folder Docker Desktop was just told to release can
    # remove every file in it and still fail on the directory itself: the
    # container is gone but the virtiofs share is not unmounted yet.
    # tests/mac-e2e.sh caught it -- teardown said "complete" and left an
    # empty .claude-dev behind, which a re-register then reuses. So: try,
    # look, wait, try again, and say so if it really will not go.
    remove_host_dir "$dir/.claude-dev" \
        || echo "Warning: $dir/.claude-dev is still there; remove it by hand once Docker has settled" >&2
    rm -f "$dir/claude-dev"
    gitignore_unseed "$dir"

    # A folder upgraded from v2 may still carry the shell hook, and v3
    # never wants one: nothing on the Mac runs an agent any more.
    for rc_file in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile"; do
        rc_remove_block "$rc_file"
    done

    if [ "$purge" = "1" ]; then
        rm -rf "$dir/.beads"
        echo "Removed $dir/.beads (--purge-beads)"
    fi

    echo "Teardown complete for '$project' at $dir (container $name and its Orca state removed)"
    if [ -n "$snap" ]; then
        echo "Re-register this directory later to restore the snapshot."
    fi
}

cmd_help() {
    cat <<'HELP'
claude-dev -- claude_orca project launcher (one per folder)

Usage:
  claude-dev                    Open this folder's Orca (starts or creates
                                the container as needed)
  claude-dev [register] [dir]   Register a project (default: this folder)
  claude-dev open               Same as no arguments
  claude-dev stop               Stop this folder's container
  claude-dev shell              A login shell inside the container
  claude-dev verify             Check this folder is set up the way the
                                template promises: the boundary, the
                                toolchain, beads, the rulebook, agents,
                                hooks, git identity and Orca's own state
  claude-dev logs               Follow the container's output
  claude-dev key openrouter     Store this folder's OpenRouter key (not
                                echoed) for the delegate routes
  claude-dev --how-to-run       Print the URL and the two commands
  claude-dev --doctor           CLI, service, image, container, port, web url
  claude-dev --update           Pull the template, rebuild the image, re-sync
                                the config, recreate
  claude-dev --teardown [--purge-beads]
                                Snapshot beads, then remove this folder's install
  claude-dev --help             Show this help
HELP
}

case "${1:-}" in
    register)      shift; cmd_register_v3 "${1:-$PROJECT_SELF}" || exit $?; exit 0 ;;
    open)          shift; cmd_open_v3 "${1:-$PROJECT_SELF}" || exit $?; exit 0 ;;
    stop)          shift; cmd_stop_v3 "${1:-$PROJECT_SELF}" || exit $?; exit 0 ;;
    shell)         shift; cmd_shell_v3 "${1:-$PROJECT_SELF}" || exit $?; exit 0 ;;
    verify)        shift; cmd_verify_v3 "${1:-$PROJECT_SELF}" || exit $?; exit 0 ;;
    logs)          shift; cmd_logs_v3 "${1:-$PROJECT_SELF}" || exit $?; exit 0 ;;
    key)           shift; cmd_key_v3 "$@" || exit $?; exit 0 ;;
    --how-to-run)
        if [ "$(ui_of "$PROJECT_SELF")" = "desktop" ]; then
            print_desktop_block_v3 "$PROJECT_SELF"
        else
            print_run_it_block_v3 "$PROJECT_SELF"
        fi
        exit 0 ;;
    --doctor)      cmd_doctor_v3 || exit $?; exit 0 ;;
    --update)      shift; cmd_update_v3 "${1:-$PROJECT_SELF}" || exit $?; exit 0 ;;
    --teardown)    shift; cmd_teardown_v3 "$@" || exit $?; exit 0 ;;
    --help|-h)     cmd_help ;;
    "")            cmd_open_v3 "$PROJECT_SELF" || exit $?; exit 0 ;;
    *)
        echo "Unknown option: $1" >&2
        cmd_help
        exit 1
        ;;
esac
