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
#   claude-dev --doctor           CLI, service, image, container, port, sshd, ssh
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
# `claude-dev ghostty` and the Ghostty rows of doctor/verify (functions only).
# shellcheck source=mac/ghostty-install.sh
. "$SCRIPT_DIR/mac/ghostty-install.sh"
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
                   l == ".claude/logs/" || l == ".orca/" || \
                   l == ".orca-worktrees/" || l == "orca.yaml" || \
                   l == "graphify-out/" || l == "__pycache__/" || \
                   l == ".agents/skills/orchestration/" || \
                   l == ".claude/skills/orchestration" || \
                   l == "skills-lock.json"
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
    #
    # And the folder's REAL path everywhere the docker argv spells the
    # guest one. The container path mounts the folder at /workspace/<name>
    # and hands the entrypoint PROJECT_DIR=/workspace/<name>; with no
    # container there is no mount, so those paths name nothing and the
    # entrypoint stops at "no entrypoint at /workspace/<name>/...". These
    # go on the END of the argv, after the recorded -e values, because
    # `env` applies its assignments in order and the last one wins.
    set -- "$@" "HOME=$proj/.claude-dev/home" \
        "PROJECT_DIR=$proj" \
        "CLAUDE_ORCA_HOST_PROJECT_DIR=$proj" \
        "CLAUDE_ORCA_ROOT=$proj" \
        "BEADS_DIR=$proj/.beads" \
        "CLAUDE_ORCA_SETUP=$proj/.claude-dev/template/scripts/container/setup.sh" \
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

# The folder recorded in <name>.project is the one on THIS filesystem.
# `-e PROJECT_DIR=` carries the guest path (/workspace/<name>), which only
# means anything behind a mount, so CLAUDE_ORCA_HOST_PROJECT_DIR -- the
# real path the docker argv passes alongside it -- wins here when present.
ctr_local_run() {
    local d name="" proj="" host_proj="" a prev=""
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
                case "$a" in
                    PROJECT_DIR=*) proj="${a#PROJECT_DIR=}" ;;
                    CLAUDE_ORCA_HOST_PROJECT_DIR=*)
                        host_proj="${a#CLAUDE_ORCA_HOST_PROJECT_DIR=}" ;;
                esac
                ;;
        esac
        prev="$a"
    done
    [ -n "$host_proj" ] && proj="$host_proj"
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

# The callers name the folder by its GUEST path (/workspace/<name>), which
# only exists behind a container's mount; here the folder is where
# <name>.project says, so a --workdir or argument under the guest path is
# rewritten to the real one (config-sync.sh, provision status, the shell's
# starting directory all live there).
ctr_local_exec() {
    local wd="" name="" proj="" guest="" a n i
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -i|-t|-it|-ti)  shift ;;
            --workdir)      wd="${2:-}"; shift 2 ;;
            --workdir=*)    wd="${1#--workdir=}"; shift ;;
            # -u/--user take a value (`exec -u agent NAME cmd`): dropping the
            # flag alone would make the user name the container name and the
            # container name the command.
            -u|--user)      shift; [ "$#" -eq 0 ] || shift ;;
            -*)             shift ;;
            *)              name="$1"; shift; break ;;
        esac
    done
    proj="$(cat "$(ctr_local_dir)/$name.project" 2>/dev/null || true)"
    if [ -n "$proj" ]; then
        guest="/workspace/$(derive_project_name "$proj")"
        case "$wd" in "$guest"|"$guest"/*) wd="$proj${wd#"$guest"}" ;; esac
        n="$#"; i=0
        while [ "$i" -lt "$n" ]; do
            a="$1"; shift
            case "$a" in "$guest"|"$guest"/*) a="$proj${a#"$guest"}" ;; esac
            set -- "$@" "$a"
            i=$((i + 1))
        done
    fi
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
    local ver="" args=()
    log="${CTR_RUN_DIR:-${TMPDIR:-/tmp}}/build.log"
    : > "$log" 2>/dev/null || log="${TMPDIR:-/tmp}/claude-orca-build.log"
    # The app decides the ORCA_VERSION (S4/claude-orca-8uo.5) -- and only
    # the app. With no app on this host there is no build arg at all: the
    # Dockerfile's own default is the answer, and passing it back in would
    # be a second place for that pin to be wrong.
    #
    # --tag stays the FIRST flag: `docker build --tag <ref>` is what every
    # reader of the command line here greps for, the suite included.
    ver="$(app_orca_version)"
    if [ -n "$ver" ]; then
        args+=(--build-arg "ORCA_VERSION=$ver")
    fi
    ctr build --tag "$ref" ${args[@]+"${args[@]}"} "$ctx" > "$log" 2>&1 &
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

# The tagged refs a BUILT update supersedes -- the version-less
# claude-orca:latest a pre-S4 folder was built at most of all -- are
# invisible to prune_old_images, which collects <none> layers only, so
# they sit on the Mac for GBs. After a successful build at R, every OTHER
# ref of our repository is garbage unless a container still uses it, and
# `docker ps -a` -- stopped ones included -- is what "in use" means: the
# Image column carries the ref a container was run from, or its image id
# when the tag it was run from has since moved. The rmi goes by ref, and
# a refusal (an image some container still references behind its last
# tag) is a normal answer -- skipped, never fatal, like prune_old_images.
# One log line per removal; silence when there is nothing to remove.
prune_old_refs() {
    local ref="$1" repo="" ntag="" used="" rt="" id=""
    [ "$CTR_RUNTIME" = "local" ] && return 0
    repo="${ref%:*}"
    ntag="${ref##*:}"
    used="$(ctr ps -a --format '{{.Image}}' 2>/dev/null || true)"
    while read -r rt id || [ -n "$rt" ]; do
        [ -n "$id" ] || continue
        case "$rt" in *:*) ;; *) continue ;; esac
        [ "${rt%:*}" = "$repo" ] || continue
        [ "${rt##*:}" = "$ntag" ] && continue
        [ "${rt##*:}" = "<none>" ] && continue
        id="${id#sha256:}"
        # Exact lines -- claude-orca:latest is a PREFIX of every
        # claude-orca:latest-orca<v>, so a substring match here would
        # spare an image its container moved off long ago.
        if printf '%s\n' "$used" | grep -Fxq -e "$rt" -e "sha256:$id" \
                -e "${id:0:12}"; then
            continue
        fi
        if ctr rmi "$rt" >/dev/null 2>&1; then
            echo "  removed old image ref $rt"
        fi
    done <<PRUNE
$(ctr images --format '{{.Repository}}:{{.Tag}} {{.ID}}' 2>/dev/null || true)
PRUNE
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
          "$run/sshd.ready" \
          "$run/port" \
          "$run/orca-serve.log" \
          "$run/setup.log" 2>/dev/null || true
}

# The folder's ssh identity (claude-orca-9bh.7). The Mac side of an ssh
# pane is `ssh -F <state/ssh/config> claude-dev-<name>`: the keys, the
# known_hosts and the config all live in the folder's state/ssh (authority,
# so teardown owns them) and nothing is ever written to ~/.ssh. The name is
# derive_project_name's [a-z0-9-], which makes the alias a safe Host pattern.
ssh_state_dir() { printf '%s\n' "$1/.claude-dev/state/ssh"; }
ssh_host_alias() { printf 'claude-dev-%s\n' "$(derive_project_name "$1")"; }

# Makes the client and host keys once (a private key that is already there
# is kept, so the host fingerprint the container presents never changes) and
# rewrites authorized_keys and known_hosts from them on every call -- cheap,
# and it heals a file somebody deleted. `restrict` turns off agent, X11 and
# tcp forwarding for this key; pty and port-forwarding give back what a pane
# and the clipboard bridge's unix-socket RemoteForward need (sshd-lib.sh's
# sshd_config says `AllowTcpForwarding remote` + `PermitListen none`, so a
# -R of a tcp port is still refused). known_hosts is keyed by the alias, so
# there is no trust-on-first-use prompt. Done BEFORE the container starts: sshd reads the host
# key and authorized_keys at boot.
ssh_ensure_keys() {
    local dir="$1" sd name alias keygen which key pub type blob rest tmp
    sd="$(ssh_state_dir "$dir")"
    name="$(derive_project_name "$dir")"
    alias="$(ssh_host_alias "$dir")"
    keygen="${CLAUDE_ORCA_SSH_KEYGEN:-ssh-keygen}"
    if ! mkdir -p "$sd" || ! chmod 700 "$sd"; then
        echo "Error: cannot create $sd for the folder's ssh keys" >&2
        return 1
    fi
    for which in client host; do
        key="$sd/${which}_ed25519"
        pub="$key.pub"
        if [ ! -f "$key" ]; then
            rm -f "$pub"
            if ! "$keygen" -q -t ed25519 -N '' -C "claude-dev-$name-$which" -f "$key" >/dev/null; then
                echo "Error: '$keygen' could not make $key" >&2
                return 1
            fi
        elif [ ! -s "$pub" ]; then
            # The private key is the identity; the .pub is derived from it,
            # so a lost .pub is rebuilt (same fingerprint), not re-keyed.
            tmp="$pub.tmp.$$"
            if ! "$keygen" -y -f "$key" > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
                rm -f "$tmp"
                echo "Error: '$keygen' could not rebuild $pub from $key" >&2
                return 1
            fi
            mv -f "$tmp" "$pub"
        fi
        if [ ! -s "$pub" ]; then
            echo "Error: $pub is missing or empty" >&2
            return 1
        fi
    done
    tmp="$sd/authorized_keys.tmp.$$"
    {
        printf 'restrict,pty,port-forwarding '
        head -1 "$sd/client_ed25519.pub"
    } > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$sd/authorized_keys" || {
        rm -f "$tmp"
        echo "Error: cannot write $sd/authorized_keys" >&2
        return 1
    }
    read -r type blob rest < "$sd/host_ed25519.pub" || true
    tmp="$sd/known_hosts.tmp.$$"
    printf '%s %s %s\n' "$alias" "$type" "$blob" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$sd/known_hosts" || {
        rm -f "$tmp"
        echo "Error: cannot write $sd/known_hosts" >&2
        return 1
    }
}

# The clipboard bridge (claude-orca-9bh.9). The Mac side is scripts/mac/
# clip-listen: a unix socket under ~/.local/state/claude-dev that the
# container reaches through the pane's ssh RemoteForward, answering the
# Mac clipboard's IMAGE and nothing else. <base>.sock / .pid / .log are its
# files. A unix socket path must stay under ~100 bytes, so a folder name too
# long for that is replaced by a checksum of itself in the file name.
clip_base() {
    local dir base
    dir="$HOME/.local/state/claude-dev"
    base="$dir/clip-$(derive_project_name "$1")"
    if [ "${#base}" -gt 90 ]; then
        base="$dir/clip-$(derive_project_name "$1" | cksum | cut -d' ' -f1)"
    fi
    printf '%s\n' "$base"
}

# 0 unless claude-orca.json says "clipboard": false (read as data, by jq).
# json_get cannot tell false from absent (`// empty`), hence the own jq.
clip_enabled() {
    local json
    json="$(orca_json "$1")"
    [ -f "$json" ] && command -v jq >/dev/null 2>&1 || return 0
    [ "$(jq -r '.clipboard' "$json" 2>/dev/null)" != "false" ]
}

# Starts the folder's clip-listen unless the pid in its pidfile is alive --
# the cost of the common case is one `kill -0`. Detached: nohup, so closing
# the terminal that started it does not take it down (it ends by itself when
# the folder's ssh master is gone), and setsid where the OS has one (macOS
# does not). Never fatal: a pane without the bridge is still a pane.
clip_listen_ensure() {
    local dir="$1" base pid listen
    clip_enabled "$dir" || return 0
    base="$(clip_base "$dir")"
    pid="$(cat "$base.pid" 2>/dev/null)" || pid=""
    case "$pid" in
        '' | *[!0-9]*) ;;
        *) kill -0 "$pid" 2>/dev/null && return 0 ;;
    esac
    listen="${CLAUDE_ORCA_CLIP_LISTEN:-$SCRIPT_DIR/mac/clip-listen}"
    [ -x "$listen" ] || return 0
    mkdir -p "${base%/*}" && chmod 700 "${base%/*}" || return 0
    if command -v setsid >/dev/null 2>&1; then
        ( setsid nohup "$listen" "$base.sock" "$(ssh_state_dir "$dir")/config" \
            "$(ssh_host_alias "$dir")" </dev/null >/dev/null 2>&1 & )
    else
        ( nohup "$listen" "$base.sock" "$(ssh_state_dir "$dir")/config" \
            "$(ssh_host_alias "$dir")" </dev/null >/dev/null 2>&1 & )
    fi
    return 0
}

# Stops the folder's clip-listen and removes its socket and pidfile ($2 =
# "log" removes the log too). The pid is signalled only when it is still a
# clip-listen, so a pid the OS has since given to someone else is left alone.
clip_listen_stop() {
    local dir="$1" base pid
    base="$(clip_base "$dir")"
    pid="$(cat "$base.pid" 2>/dev/null)" || pid=""
    case "$pid" in
        '' | *[!0-9]*) ;;
        *)
            if kill -0 "$pid" 2>/dev/null; then
                case "$(ps -p "$pid" -o args= 2>/dev/null)" in
                    *clip-listen*) kill "$pid" 2>/dev/null || true ;;
                esac
            fi
            ;;
    esac
    rm -f "$base.sock" "$base.pid"
    if [ "${2:-}" = "log" ]; then rm -f "$base.log"; fi
    return 0
}

# state/ssh/config, regenerated on every open: the one place the port, the
# key paths and the multiplexing live, so a pane is `ssh -F config <alias>`
# and nothing else. Paths are quoted because the folder may have spaces in
# it. The ControlPath is under the Mac user's home, not the folder: a unix
# socket path must stay under ~100 bytes and %C keeps it short and unique.
ssh_write_config() {
    local dir="$1" port="$2" sd alias cm cmp tmp
    sd="$(ssh_state_dir "$dir")"
    alias="$(ssh_host_alias "$dir")"
    cm="$HOME/.local/state/claude-dev"
    # The config names the directory made just above as a literal path, not
    # `~`: ssh resolves `~` through the passwd entry, which is $HOME on a Mac
    # but not wherever HOME is set to something else (a fixture, sudo -E),
    # and the master would then fail to bind in a directory nobody made.
    # `%` is ssh's own escape in ControlPath, so a literal one is doubled.
    cmp="$(printf '%s' "$cm" | sed 's/%/%%/g')"
    if ! mkdir -p "$sd" "$cm" || ! chmod 700 "$cm"; then
        echo "Error: cannot create $cm for the ssh control sockets" >&2
        return 1
    fi
    case "$dir" in *'"'*)
        echo "Error: a folder path containing a double quote cannot go in an ssh config: $dir" >&2
        return 1 ;;
    esac
    tmp="$sd/config.tmp.$$"
    {
        printf 'Host %s\n' "$alias"
        printf '  HostName 127.0.0.1\n'
        printf '  Port %s\n' "$port"
        printf '  User agent\n'
        printf '  IdentityFile "%s/client_ed25519"\n' "$sd"
        printf '  IdentitiesOnly yes\n'
        printf '  UserKnownHostsFile "%s/known_hosts"\n' "$sd"
        printf '  HostKeyAlias %s\n' "$alias"
        printf '  StrictHostKeyChecking yes\n'
        printf '  ControlMaster auto\n'
        printf '  ControlPath "%s/cm-%%C"\n' "$cmp"
        printf '  ControlPersist 30m\n'
        printf '  ServerAliveInterval 30\n'
        printf '  ForwardAgent no\n'
        printf '  ForwardX11 no\n'
        printf '  LogLevel ERROR\n'
        # The clipboard bridge: the container's /tmp/cdev-clip.sock is this
        # session's way back to the Mac listener (clip_listen_ensure). Left
        # out with "clipboard": false. No ExitOnForwardFailure: a forward
        # that cannot bind must never stop the pane from opening.
        if clip_enabled "$dir"; then
            case "$(clip_base "$dir")" in
                *'"'*) ;;
                *) printf '  RemoteForward /tmp/cdev-clip.sock "%s.sock"\n' "$(clip_base "$dir")" ;;
            esac
        fi
    } > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$sd/config" || {
        rm -f "$tmp"
        echo "Error: cannot write $sd/config" >&2
        return 1
    }
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
    echo "That file is /home/agent/.openrouter.key inside the container; the entrypoint reads it there next time you run ./claude-dev."
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
    local dir="$1" port
    port="$(json_get "$dir" '.port')"
    case "$port" in
        ''|*[!0-9]*) port="" ;;
    esac
    if [ -n "$port" ]; then
        printf '%s\n' "$port"
        return 0
    fi
    next_free_port "$(container_name "$dir")"
}

# "<name> <host port>", one line per port a container on this machine was
# created to publish -- running or not, which is the point. Docker's own
# allocator only holds the ports of RUNNING containers and a connect probe
# only hears the ones answering, so a folder whose container is down owns
# its number invisibly; .HostConfig.PortBindings is the one place the claim
# survives a stop (.NetworkSettings.Ports is empty until the next start).
# Names come back docker's way, with the leading slash. Nothing at all when
# docker cannot answer: the probe is then the only question, as it was.
container_port_claims() {
    local ids
    if [ "$CTR_RUNTIME" = "local" ]; then
        return 0
    fi
    ids="$(ctr ps -aq 2>/dev/null | tr '\n' ' ' || true)"
    case "$ids" in
        *[!\ ]*) ;;
        *) return 0 ;;
    esac
    # shellcheck disable=SC2086
    ctr inspect -f '{{$n := .Name}}{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{$n}} {{.HostPort}}{{"\n"}}{{end}}{{end}}' $ids 2>/dev/null || true
}

# Is this port someone else's? Something answering on it is, and so is a
# number another container was created with -- the container named $2 is
# this folder's own and its claim never counts against it. $3 is a
# container_port_claims answer the caller already has.
port_taken() {
    local port="$1" own="$2" claims n p
    if ! port_is_free "$port"; then
        return 0
    fi
    claims="${3-$(container_port_claims)}"
    while read -r n p; do
        if [ "$p" = "$port" ] && [ "$n" != "/$own" ] && [ "$n" != "$own" ]; then
            return 0
        fi
    done <<CLAIMS
$claims
CLAIMS
    return 1
}

# The first port from the base up that is nobody's (port_taken).
next_free_port() {
    local own="$1" port tries=0 claims
    port="${CLAUDE_ORCA_PORT_BASE:-6768}"
    claims="$(container_port_claims)"
    while [ "$tries" -lt 200 ]; do
        if ! port_taken "$port" "$own" "$claims"; then
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

# The ssh twin of wait_for_web_url: waits for run/sshd.ready, which the
# container's sshd-lib writes (`port=N`, `host_key_sha256=SHA256:...`) once
# sshd is listening. Same return codes -- 0 ready, 1 timeout, 2 the container
# died while waiting -- and the same timeout (weburl_timeout), plus 3 when
# the host key sshd presents is not the one in state/ssh (a stale
# container: the Mac would refuse the connection, so say so here, naming
# both fingerprints). Nothing on stdout; the messages go to stderr.
wait_for_sshd_ready() {
    local dir="$1" name="${2:-}" file setup_log timeout waited=0 runtime="" last="" line="" state="" seen_running="" unlisted=0
    local want got
    file="$dir/.claude-dev/run/sshd.ready"
    setup_log="$dir/.claude-dev/run/setup.log"
    timeout="$(weburl_timeout "$dir")"
    if folder_installs_toolchain "$dir"; then runtime=1; fi
    while [ "$waited" -lt "$timeout" ]; do
        if [ -s "$file" ]; then
            want="$(ssh_host_key_fingerprint "$dir")"
            got="$(sed -n 's/^host_key_sha256=//p' "$file" | head -1)"
            if [ -n "$want" ] && [ "$got" = "$want" ]; then
                return 0
            fi
            {
                echo "Error: sshd in the container presents host key '${got:-<none>}', but this folder's key is '${want:-<unreadable>}'."
                echo "  The container was made with another host key; ./claude-dev --update recreates it."
            } >&2
            return 3
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
            echo "Waiting for sshd to come up inside the container..." >&2
        fi
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

# SHA256:... of the folder's host key, in the form sshd-lib writes into
# run/sshd.ready (field 2 of `ssh-keygen -lf`); empty when unreadable.
ssh_host_key_fingerprint() {
    "${CLAUDE_ORCA_SSH_KEYGEN:-ssh-keygen}" -lf "$(ssh_state_dir "$1")/host_ed25519.pub" 2>/dev/null \
        | awk 'NR == 1 { print $2 }' || true
}

# Ghostty's terminfo entry, pushed into the container once per Ghostty
# version (claude-orca-9bh.7): the image has no xterm-ghostty, and without it
# a pane's pane-entry falls back to xterm-256color (still works, loses a few
# Ghostty-only capabilities). Only when this terminal IS xterm-ghostty and
# the Mac's infocmp can print the entry; run/terminfo.stamp holds the
# TERM_PROGRAM_VERSION already pushed. One warning line on failure, never
# fatal, and no stamp then, so the next open tries again.
ssh_push_terminfo() {
    local dir="$1" stamp ver entry cfg alias
    [ "${TERM:-}" = "xterm-ghostty" ] || return 0
    command -v infocmp >/dev/null 2>&1 || return 0
    entry="$(infocmp -x xterm-ghostty 2>/dev/null)" || return 0
    [ -n "$entry" ] || return 0
    ver="${TERM_PROGRAM_VERSION:-}"
    stamp="$dir/.claude-dev/run/terminfo.stamp"
    if [ -f "$stamp" ] && [ "$(head -1 "$stamp")" = "$ver" ]; then
        return 0
    fi
    cfg="$(ssh_state_dir "$dir")/config"
    alias="$(ssh_host_alias "$dir")"
    if printf '%s\n' "$entry" \
        | "${CLAUDE_ORCA_SSH:-ssh}" -F "$cfg" -o BatchMode=yes "$alias" 'tic -x -o ~/.terminfo - ' >/dev/null 2>&1; then
        mkdir -p "$dir/.claude-dev/run" && printf '%s\n' "$ver" > "$stamp"
    else
        echo "  terminfo: could not install xterm-ghostty in the sandbox (continuing; panes use xterm-256color)" >&2
    fi
    return 0
}

# True when stdin and stdout are both terminals (CLAUDE_ORCA_PANE_FORCE_TTY=1
# says they are, for tests).
pane_has_terminal() {
    [ -n "${CLAUDE_ORCA_PANE_FORCE_TTY:-}" ] || { [ -t 0 ] && [ -t 1 ]; }
}

# Turns THIS terminal into a sandbox pane: `exec ssh -F config -tt alias`.
# $2 is the directory the pane should start in (default $PWD), sent as
# CDEV_CWD relative to the project (empty at the root or outside it --
# pane-entry then lands in the project root); $3 names the path taken, for
# run/pane.log ("slow" when open/pane did the whole bring-up, "fast" when the
# master connection was already up). ssh honours only the FIRST -o SetEnv,
# so every variable rides in one option; a value with a space is wrapped in
# double quotes inside it, and empty variables are left out. Without a
# terminal on stdin and stdout (a script, a bats case) it does not exec: it
# says how to get a pane and returns 0. CLAUDE_ORCA_PANE_FORCE_TTY=1 is the
# test seam that treats both as terminals.
pane_exec() {
    local dir="$1" cwd="${2:-$PWD}" mode="${3:-slow}" rel="" real cfg alias log setenv="" pair
    if ! pane_has_terminal; then
        echo "ready: run ./claude-dev pane in a terminal"
        return 0
    fi
    real="$(cd "$cwd" 2>/dev/null && pwd -P)" || real="$cwd"
    case "$real" in
        "$dir") rel="" ;;
        "$dir"/*) rel="${real#"$dir"/}" ;;
        *) rel="" ;;
    esac
    case "$rel" in *'"'* | *'\'*)
        echo "  pane: '$rel' has a quote or backslash ssh cannot carry; starting at the project root" >&2
        rel="" ;;
    esac
    cfg="$(ssh_state_dir "$dir")/config"
    alias="$(ssh_host_alias "$dir")"
    for pair in "CDEV_CWD=$rel" "TERM_PROGRAM=${TERM_PROGRAM:-}" \
        "TERM_PROGRAM_VERSION=${TERM_PROGRAM_VERSION:-}" "COLORTERM=${COLORTERM:-}"; do
        case "$pair" in *=) continue ;; esac
        case "$pair" in
            *' '*) pair="${pair%%=*}=\"${pair#*=}\"" ;;
        esac
        setenv="${setenv:+$setenv }$pair"
    done
    log="$dir/.claude-dev/run/pane.log"
    mkdir -p "$dir/.claude-dev/run" 2>/dev/null \
        && printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$mode" "$rel" >> "$log" 2>/dev/null || true
    # Both paths end here, so this is the one place the clipboard bridge's
    # listener is started (a no-op while the last one is still alive).
    clip_listen_ensure "$dir"
    if [ -n "$setenv" ]; then
        exec "${CLAUDE_ORCA_SSH:-ssh}" -F "$cfg" -tt -o "SetEnv=$setenv" "$alias"
    fi
    exec "${CLAUDE_ORCA_SSH:-ssh}" -F "$cfg" -tt "$alias"
}

# Three doctor/verify rows about the ssh path to the folder's container, in
# the order a failure is easiest to read:
#   sshd         run/sshd.ready names a port, and that port answers an
#                SSH-2.0 banner (read over bash's /dev/tcp, no client);
#   ssh master   the folder's ControlMaster connection (-O check). A pane
#                starts one on demand, so down is n/a, never a finding, and
#                it is asked BEFORE key auth because the key-auth probe
#                below starts a master of its own;
#   ssh key auth `ssh -F config -o BatchMode=yes <alias> true` exits 0 --
#                the folder's key is accepted. Skipped (n/a) when sshd is
#                not answering, since it could only repeat that finding.
# Returns 2 when a row is a finding (missing or FAIL), else 0.
doctor_ssh_rows() {
    local dir="$1" ready cfg alias sshd_port="" banner="" rc=0 sshd_ok="" krc=0
    ready="$dir/.claude-dev/run/sshd.ready"
    cfg="$(ssh_state_dir "$dir")/config"
    alias="$(ssh_host_alias "$dir")"
    if [ ! -s "$ready" ]; then
        doctor_row missing "sshd" "not ready -- no $ready; ./claude-dev starts it"
        rc=2
    else
        sshd_port="$(sed -n 's/^port=//p' "$ready" | head -1)"
        case "$sshd_port" in
            '' | *[!0-9]*) sshd_port="" ;;
        esac
        if [ -n "$sshd_port" ]; then
            banner="$( (
                exec 3<>"/dev/tcp/127.0.0.1/$sshd_port" || exit 1
                IFS= read -r -t 3 -u 3 line || true
                printf '%s' "${line:-}"
            ) 2>/dev/null | tr -d '\r' || true)"
        fi
        case "$banner" in
            SSH-2.0-*)
                doctor_row ok "sshd" "port $sshd_port answers $banner"
                sshd_ok=1
                ;;
            *)
                doctor_row FAIL "sshd" "${sshd_port:+port $sshd_port }gave no SSH banner -- ./claude-dev logs, $dir/.claude-dev/run/sshd.log"
                rc=2
                ;;
        esac
    fi
    if "${CLAUDE_ORCA_SSH:-ssh}" -F "$cfg" -O check "$alias" >/dev/null 2>&1; then
        doctor_row ok "ssh master" "up -- panes reuse one connection"
    else
        doctor_row n/a "ssh master" "not running -- the next pane starts it"
    fi
    if [ -z "$sshd_ok" ]; then
        doctor_row n/a "ssh key auth" "skipped -- sshd is not answering"
    else
        "${CLAUDE_ORCA_SSH:-ssh}" -F "$cfg" -o BatchMode=yes -o ConnectTimeout=10 "$alias" true >/dev/null 2>&1 || krc=$?
        if [ "$krc" -eq 0 ]; then
            doctor_row ok "ssh key auth" "$alias accepts this folder's key"
        else
            doctor_row FAIL "ssh key auth" "ssh -F $cfg $alias true exited $krc -- the container may predate this folder's key; ./claude-dev --update"
            rc=2
        fi
    fi
    return "$rc"
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

# The name this folder's runtime is saved under in the app. The sidebar
# badge on every workspace under this project IS this name, truncated to
# about 17 characters ("claude-orca-claud..."), so the word the user
# actually reads has to come FIRST: "remote-<project>" reads as remote
# against the local badge's "Local Mac", where the container name read as
# nothing at all. The container keeps its own name (claude-orca-<project>);
# only what the app shows changes.
orca_env_name() { printf 'remote-%s\n' "$(derive_project_name "$1")"; }

# What the same folder was saved under before the rename -- a folder
# opened once under the old name still has that environment in the app,
# pointed at a container offer that is dead. Removed alongside the new
# name on every add and on teardown, so no folder ends up with two.
orca_env_legacy_name() { container_name "$1"; }

# A Mac-side result, so run/ and not state/.
orca_env_file() { printf '%s\n' "$1/.claude-dev/run/orca-environment.json"; }

# The other Mac-side result of a hand-off: one line saying why this folder
# is STILL a local project in the Mac's own Orca, written when the launcher
# could not remove it and removed at the top of every hand-off. Also run/
# and not state/ -- it is what the last run observed, never authority; the
# block printer asks the app itself as well.
orca_leak_file() { printf '%s\n' "$1/.claude-dev/run/orca-local-leak"; }

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

# --- one installed Orca.app, never a second one (claude-orca-tgr) --------
#
# Orca.app can open LOCAL workspaces (agents run on the Mac, no container
# around them) and 1.4.197 has no knob to refuse them. claude-orca-qhq's
# answer was a private per-folder profile, which opens a SECOND instance
# of the app -- there must be exactly one Orca, the installed one, no
# exception. So this enforces the invariant on THAT app instead: this
# folder is never a local project there, self-healing (quit, strip,
# relaunch) when it finds out otherwise.

# `.result.app.running` -- distinct from `.result.runtime.reachable` --
# says whether the desktop process itself is up, which is what decides
# whether it is safe to rewrite orca-data.json out from under it and
# whether a launch would be a first one or a second instance.
orca_json_app_running() {
    local json="$1" v=""
    if command -v jq >/dev/null 2>&1; then
        v="$(printf '%s' "$json" | jq -r '.result.app.running // false' 2>/dev/null || echo false)"
        [ "$v" = "true" ]
        return
    fi
    case "$json" in
        *'"running":true'*|*'"running": true'*) return 0 ;;
    esac
    return 1
}

# `.result.app.pid` -- the running app's own process id, the one thing
# lsof discovery (below) needs and `status --json` is the only place to
# read it from. Empty when absent, null, or unreadable.
orca_json_app_pid() {
    local json="$1" v=""
    if command -v jq >/dev/null 2>&1; then
        v="$(printf '%s' "$json" | jq -r '.result.app.pid // empty' 2>/dev/null || true)"
    else
        v="$(printf '%s' "$json" | tr '{},' '\n' | sed -n 's/^"pid":\([0-9]*\)$/\1/p' | head -1)"
    fi
    [ "$v" = "null" ] && v=""
    printf '%s\n' "$v"
}

# The one line this prints whenever nothing below can name the Mac's own
# Orca "user data" directory at all -- a guess that used to no-op quietly
# is now something that SAYS so, on stderr from the strip and in the
# detail column from cmd_verify's own row.
orca_no_data_dir_message() {
    printf "cannot find Orca's data folder (looked for %s); set ORCA_USER_DATA_PATH to it" \
        "$HOME/Library/Application Support/{Orca,ArchitectureGrammar}"
}

# The file Orca keeps its local project list in, under a user data dir.
# Since Orca grew profiles (verified 1.4.197, still so on 1.4.218) that is
# <dir>/profiles/<activeProfileId>/orca-data.json, with the active profile
# named by <dir>/orca-profile-index.json -- the same resolution
# seed-orca-state.sh does on the container side; the root <dir>/orca-data.json
# is only the pre-profiles legacy copy Orca copies forward once and then
# never reads again, so a reader aimed at it edits a file the app has
# abandoned (the strip "succeeds", the app still lists the folder). One
# helper, so no two readers of the list can disagree about which store
# they read: the active profile's file when it exists, the legacy root
# file when there is no profile (an Orca old enough to have neither).
orca_data_json_file() {
    local dir="$1" id="" f
    if command -v jq >/dev/null 2>&1; then
        id="$(jq -r '.activeProfileId // empty' "$dir/orca-profile-index.json" 2>/dev/null || true)"
    fi
    [ -n "$id" ] || id="local-default"
    f="$dir/profiles/$id/orca-data.json"
    if [ -f "$f" ]; then
        printf '%s\n' "$f"
        return 0
    fi
    printf '%s\n' "$dir/orca-data.json"
}

# The Mac's own Orca "user data" directory -- where it persists
# orca-data.json, its local project list. In order: $ORCA_USER_DATA_PATH,
# when the environment already carries one, is authoritative outright;
# then the cache this discovered last time (.claude-dev/state/, Mac-side
# authority the same as the legacy-profile cleanup above), as long as the
# directory it named still exists; then discovery, while the app is
# running ($2, its CLI) -- `status --json`'s own `.result.app.pid` and the
# first line of `lsof -p <pid> -Fn` naming orca-environments.json or
# orca-data.json, whose dirname is the answer -- or, when the open file is
# a profile's own orca-data.json and the dirname ends in profiles/<id>,
# that directory's grandparent -- cached for next time; and
# only then the two Library guesses (the bundle's package name is
# ArchitectureGrammar and the running app calls app.setName at startup, so
# the ordinary default is one of the two -- the mac-e2e run settles
# which). Empty when none of the above found anything -- the launcher
# never invents a path to write one at, and every caller says so instead
# of silently no-op'ing.
orca_user_data_dir() {
    local dir="${1:-}" cli="${2:-}" cache d pid lsof_line found="" rest
    if [ -n "${ORCA_USER_DATA_PATH:-}" ]; then
        printf '%s\n' "$ORCA_USER_DATA_PATH"
        return 0
    fi
    if [ -n "$dir" ]; then
        cache="$dir/.claude-dev/state/orca-data-dir"
        if [ -s "$cache" ]; then
            d="$(head -1 "$cache")"
            if [ -n "$d" ] && [ -d "$d" ]; then
                printf '%s\n' "$d"
                return 0
            fi
        fi
    fi
    if [ -n "$cli" ] && command -v lsof >/dev/null 2>&1; then
        pid="$(orca_json_app_pid "$("$cli" status --json 2>/dev/null || true)")"
        if [ -n "$pid" ]; then
            while IFS= read -r lsof_line; do
                case "$lsof_line" in
                    n*orca-environments.json|n*orca-data.json)
                        found="$(dirname "${lsof_line#n}")"
                        # Since Orca grew profiles, the open file can be
                        # the active profile's orca-data.json, whose
                        # dirname is .../profiles/<id> -- the user data
                        # dir is that directory's grandparent.
                        case "$found" in
                            */profiles/*)
                                rest="${found##*/profiles/}"
                                case "$rest" in
                                    */*) ;;   # deeper than one profile level
                                    *) found="${found%/profiles/$rest}" ;;
                                esac ;;
                        esac
                        break ;;
                esac
            done <<LSOF
$(lsof -p "$pid" -Fn 2>/dev/null || true)
LSOF
            if [ -n "$found" ] && [ -d "$found" ]; then
                if [ -n "$dir" ]; then
                    mkdir -p "$dir/.claude-dev/state"
                    printf '%s\n' "$found" > "$dir/.claude-dev/state/orca-data-dir"
                fi
                printf '%s\n' "$found"
                return 0
            fi
        fi
    fi
    for d in "$HOME/Library/Application Support/Orca" \
             "$HOME/Library/Application Support/ArchitectureGrammar"; do
        if [ -d "$d" ]; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    return 0
}

# Rewrites the store orca_data_json_file resolves -- the active profile's
# orca-data.json, or the pre-profiles root legacy file -- removing every
# LOCAL .repos entry
# that names this folder ($CLAUDE_ORCA_HOST_PROJECT_DIR too, when set) --
# every other repo, every remote-host entry and every other top-level key
# preserved untouched. Which entries those are is decided in shell, by the
# same reader the caller's own precondition uses, so the rewrite can never
# select differently from the check that follows it.
#
# And a check DOES follow it: this returns 0 only when the store no longer
# lists the folder afterwards. A silent 0 for a no-op that left the folder
# listed is exactly how the hand-off used to launch an app that still held
# it and then quit that app again (claude-orca-tgr follow-up) -- every way
# this can fail to land now says which on stderr and returns non-zero.
#
# Three kinds of non-zero, because they are three different situations:
#   1  the folder IS listed and the rewrite did not remove it -- the
#      caller must not hand this folder to the app; OR the store is a
#      SQLite-era profile (profile-state.db beside it), which must never
#      be edited at all -- the caller's in-app removal steps are the
#      answer for both (claude-orca-pow).
#   2  there is no store to read here at all (no data folder, no
#      orca-data.json, no jq): said out loud, but it is not evidence of a
#      leak -- a Mac whose Orca has never been launched has neither a
#      folder to strip nor a project in it.
#
# Callers only ever run this while the app is NOT running: the app's
# shutdown flushes this same file in parallel with stopping its RPC, so a
# rewrite done the instant `status --json` says "not running" is a rewrite
# the flush clobbers. The launcher never quits Orca to get that window
# (claude-orca, 2026-09-13) -- it takes the one it is given, and says what
# to remove by hand when there is none.
orca_strip_local_repo() {
    local dir="$1" cli="${2:-}" data f tmp p db="" drop=""
    data="$(orca_user_data_dir "$dir" "$cli")"
    if [ -z "$data" ]; then
        echo "  $(orca_no_data_dir_message)" >&2
        return 2
    fi
    f="$(orca_data_json_file "$data")"
    if [ ! -f "$f" ]; then
        echo "  $f not found" >&2
        return 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "  jq not installed, so $f cannot be rewritten" >&2
        return 2
    fi
    if ! orca_data_json_lists_dir "$f" "$dir"; then
        return 0
    fi

    # A SQLite-era profile (Orca 1.4.219+) keeps its state in
    # profiles/<id>/profile-state.db and treats orca-data.json as its
    # export: ANY byte change to that JSON makes the user's next Orca
    # start refuse outright ("cannot safely choose a profile-state
    # authority", proven on the real 1.4.219 .deb). The rewrite below
    # would brick the desktop app it is trying to help -- so this never
    # edits such a profile, and says why: the caller's could-not-strip
    # path (the in-app removal steps) is the answer.
    db="${f%/orca-data.json}/profile-state.db"
    if [ -f "$db" ]; then
        echo "  Orca keeps this profile in SQLite; the launcher will not edit it" >&2
        return 1
    fi

    # The paths to drop, chosen here and handed to jq as data: string
    # prefixes both ways AND a pwd -P comparison, which no jq filter can
    # do for a path that is a symlink on this Mac.
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if orca_path_is_this_folder "$p" "$dir"; then
            drop="$drop$p
"
        fi
    done <<REPOS
$(orca_data_json_repo_paths "$f")
REPOS

    tmp="$f.tmp.$$"
    # The same removal in .projects[].sourceRepoIds: a project references
    # its repos by id, so the ids this rewrite removes from .repos come out
    # of every project's list too, and a project left referencing nothing
    # goes with them. A project that never referenced anything is not
    # touched.
    if jq --arg drop "$drop" '
        def islocal: ((.executionHostId // "local") | . == "" or . == "local");
        ($drop | split("\n") | map(select(. != ""))) as $d
        | (.repos // []) as $old
        | ($old | map(. as $r | select(
            (($r | islocal) and (($d | index($r.path)) != null)) | not))) as $kept
        | ($old | map(. as $r
              | select(($r | islocal) and (($d | index($r.path)) != null))
              | (.id // ""))
            | map(select(. != ""))) as $gone
        | .repos = $kept
        | .projects = ((.projects // []) | map(
              (.sourceRepoIds // []) as $s
              | if ($s | length) > 0
                then .sourceRepoIds = ($s | map(
                    . as $sid | select(($gone | index($sid)) == null)))
                     | select((.sourceRepoIds | length) > 0)
                else . end))
    ' "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi

    if orca_data_json_lists_dir "$f" "$dir"; then
        echo "  $f still lists $dir after the rewrite" >&2
        return 1
    fi
    return 0
}

# Poll until the app's runtime answers, <= CLAUDE_ORCA_ORCA_WAIT seconds
# (60, the plan's number). The exit code says nothing, so the JSON is read
# every time.
orca_wait_reachable() {
    local cli="$1" limit waited=0 out=""
    limit="${CLAUDE_ORCA_ORCA_WAIT:-60}"
    case "$limit" in
        ''|*[!0-9]*) limit=60 ;;
    esac
    while :; do
        out="$("$cli" status --json 2>/dev/null || true)"
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
# whether or not the environment saved, and whether or not this folder is
# ALSO a local project there, because the block that follows says which --
# and 1 only when the hand-off cannot happen at all (no app, no CLI, no
# pairing offer, an app that never answers), which is the one case the
# browser is still the answer for.
#
# Nothing here ever quits Orca (the user's decision, 2026-09-13): their
# windows and their running agents are worth more than the one thing a
# quit buys, a writable orca-data.json. A local project this run could
# not remove is reported instead -- the diagnostic below names the entry
# that matched, and print_desktop_block_v3 prints the clicks that remove
# it -- while the remote environment is registered regardless, so the
# sandboxed workspace exists to open.
orca_hand_off() {
    local dir="$1" app="" cli="" pair="" name="" legacy="" appver="" imgver="" \
          out="" id="" strip_rc=0 leak=0 leak_why=""

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

    # A folder may still carry the private per-folder profile
    # claude-orca-qhq created (4a1882c): that decision is reversed and
    # nothing reads one any more, so clean it up the moment this folder
    # is opened again.
    if [ -e "$dir/.claude-dev/state/orca-profile" ]; then
        echo "  removing this folder's old private Orca profile (no longer used)" >&2
        rm -rf "$dir/.claude-dev/state/orca-profile"
    fi

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
    legacy="$(orca_env_legacy_name "$dir")"
    # Nothing may claim a saved environment until this run saves one, and
    # nothing may claim a local project until this run sees one.
    rm -f "$(orca_env_file "$dir")"
    rm -f "$(orca_leak_file "$dir")"

    # Two paths, and which one this is decides everything below: the app
    # is already up (a launch would be a SECOND instance, which
    # claude-orca-tgr forbids, and its store is being written under us,
    # so there is no safe rewrite to attempt at all), or it is not (the
    # store is ours to rewrite, and the app this run starts starts
    # without this folder in it).
    if orca_json_app_running "$("$cli" status --json 2>/dev/null || true)"; then
        # Ask for the data dir while the process still exists: discovery
        # goes through `lsof -p <pid>`, so the answer is only obtainable
        # now, and it is cached under state/ for every later run that has
        # no pid to ask about -- including the diagnostic below.
        orca_user_data_dir "$dir" "$cli" >/dev/null
        if ! orca_wait_reachable "$cli"; then
            echo "  Orca.app did not answer in ${CLAUDE_ORCA_ORCA_WAIT:-60}s -- opening Orca Web instead" >&2
            return 1
        fi
        if orca_lists_local_repo "$("$cli" repo list --json 2>/dev/null || true)" "$dir"; then
            leak=1
            leak_why="Orca lists this folder as a LOCAL project"
            orca_report_local_leak "$dir" "$cli"
        fi
    else
        # Not running: strip first, THEN launch. In this order the app
        # this run starts has never held the folder -- and when the strip
        # could not land, the hand-off still happens; the block at the end
        # is what asks for the two clicks that finish it.
        if [ "${CLAUDE_ORCA_OPEN:-1}" != "0" ]; then
            strip_rc=0
            orca_strip_local_repo "$dir" "$cli" || strip_rc=$?
            # 2 is "there is no store here to read" -- said on stderr
            # already, and no evidence of a leak. 1 is a folder this Mac's
            # Orca still holds after the rewrite, which it also said.
            if [ "$strip_rc" -eq 1 ]; then
                leak=1
                leak_why="this Mac's orca-data.json still lists this folder after the strip"
            fi
            open -a "$app" || echo "  Could not launch $app" >&2
        fi
        if ! orca_wait_reachable "$cli"; then
            echo "  Orca.app did not answer in ${CLAUDE_ORCA_ORCA_WAIT:-60}s -- opening Orca Web instead" >&2
            return 1
        fi
        if orca_lists_local_repo "$("$cli" repo list --json 2>/dev/null || true)" "$dir"; then
            leak=1
            leak_why="Orca re-added this folder as a LOCAL project on launch"
            orca_report_local_leak "$dir" "$cli"
        fi
    fi

    # A result, not authority: what the block printer says without having
    # to ask the app a second time (it still asks, so a leak that appears
    # between here and the block is reported too).
    if [ "$leak" -eq 1 ]; then
        mkdir -p "$dir/.claude-dev/run"
        printf '%s\n' "$leak_why" > "$(orca_leak_file "$dir")"
    fi

    # Remove first, always. The name may be saved against the PREVIOUS
    # container's offer, which is dead, and `add` on a name that exists is
    # refused rather than replaced; an rm of a name that was never there
    # answers ok:false and is the no-op it looks like. (The bead says
    # "rm if the name exists"; doing it unconditionally is the same answer
    # without having to guess the shape of `environment list --json`.)
    # Both names: a folder opened before the rename still has one saved
    # under the container's name, pointed at a dead offer.
    "$cli" environment rm --environment "$name" --json >/dev/null 2>&1 || true
    "$cli" environment rm --environment "$legacy" --json >/dev/null 2>&1 || true

    out="$("$cli" environment add --name "$name" --pairing-code "$pair" --json 2>/dev/null || true)"
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
# runtime is about to stop existing. Quiet and best effort -- no app, no
# CLI or an environment that was never saved are all "nothing to remove".
# A profile from before claude-orca-qhq was reversed (4a1882c) has no
# reason to survive the folder either, so teardown is where any last trace
# of it goes even if a folder never got opened again to trigger the
# hand-off's own cleanup.
orca_env_forget() {
    local dir="$1" app="" cli=""
    rm -rf "$dir/.claude-dev/state/orca-profile"
    app="$(desktop_app)" || return 0
    cli="$(orca_cli "$app")" || return 0
    "$cli" environment rm --environment "$(orca_env_name "$dir")" --json >/dev/null 2>&1 || true
    "$cli" environment rm --environment "$(orca_env_legacy_name "$dir")" --json >/dev/null 2>&1 || true
    rm -f "$(orca_env_file "$dir")"
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

# The same answer with the two fields that say WHICH entry this is:
# path<TAB>host<TAB>id, one line each. Orca's own record (out/shared/
# execution-host.js in 1.4.197) carries executionHostId normalised to
# "local", "ssh:<target>" or "runtime:<env>", with connectionId as the
# older spelling -- so the host column is the one thing that tells this
# folder's own container workspace apart from a real local project.
# Deliberately UNFILTERED: the diagnostic that prints these exists
# precisely because a CLI answer and the persisted store disagreed once,
# and hiding the host of whatever matched is how that stayed a mystery.
# Empty without jq; the caller falls back to the path list.
orca_json_repo_rows() {
    local json="$1"
    command -v jq >/dev/null 2>&1 || return 0
    printf '%s' "$json" | jq -r '.result.repos[]?
        | [(.path // ""), (.executionHostId // .connectionId // "local"), (.id // "")]
        | @tsv' 2>/dev/null || true
}

# What the launcher saw, whenever `repo list` says this folder is a local
# project in the Mac's own Orca. On a real Mac (2026-09-13) the CLI said
# local and orca-data.json did not name the folder at all, and nothing in
# the output said which entry had matched -- so every run that meets this
# again prints the matching rows with their host, this folder's own path,
# and what the persisted store lists locally. stderr, one line each.
orca_report_local_leak() {
    local dir="$1" cli="$2" json="" tab p host id data="" f="" locals="" sep=""
    tab="$(printf '\t')"
    json="$("$cli" repo list --json 2>/dev/null || true)"
    echo "  Orca lists this folder as a LOCAL project:" >&2
    if command -v jq >/dev/null 2>&1; then
        while IFS="$tab" read -r p host id; do
            [ -n "$p" ] || continue
            orca_path_is_this_folder "$p" "$dir" || continue
            echo "    $p  host=${host:-local}  id=$id" >&2
        done <<ROWS
$(orca_json_repo_rows "$json")
ROWS
    else
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            orca_path_is_this_folder "$p" "$dir" || continue
            echo "    $p" >&2
        done <<PATHS
$(orca_json_repo_paths "$json")
PATHS
    fi
    echo "    this folder: $dir" >&2
    data="$(orca_user_data_dir "$dir" "$cli")"
    if [ -n "$data" ]; then f="$(orca_data_json_file "$data")"; fi
    if [ -n "$f" ] && [ -f "$f" ]; then
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            locals="$locals$sep$p"
            sep=", "
        done <<LOCALS
$(orca_data_json_repo_paths "$f")
LOCALS
        [ -n "$locals" ] || locals="none"
        echo "    $f local entries: $locals" >&2
    else
        echo "    $(orca_no_data_dir_message)" >&2
    fi
}

# Same list, read straight off the Mac's own persisted store instead of
# through the CLI -- the only way to ask while the app is not running,
# since there is no `orca status` to answer with the process down.
# LOCAL entries only. A repo attached to a remote host lives in this SAME
# array, told apart by `executionHostId` (absent, null, "" or "local" is
# the Mac itself) -- so an unfiltered read counts the container's own
# workspace as a local leak, which is how this folder could look like two
# "main" workspaces where one of them is ours.
orca_data_json_repo_paths() {
    local f="$1"
    [ -f "$f" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r '.repos[]?
           | select((.executionHostId // "local") | . == "" or . == "local")
           | .path // empty' "$f" 2>/dev/null || true
}

# Two paths naming the same directory. String equality first, because
# neither side has to exist for that to be an answer; then `pwd -P` on
# both, which is the only way /Users/joe/proj and the /Volumes path it is
# a symlink to compare equal. `realpath` is not on a stock Mac, hence the
# subshell.
same_dir_path() {
    local a="${1:-}" b="${2:-}" ra rb
    [ -n "$a" ] && [ -n "$b" ] || return 1
    [ "$a" = "$b" ] && return 0
    ra="$(cd -P "$a" 2>/dev/null && pwd -P)" || ra=""
    rb="$(cd -P "$b" 2>/dev/null && pwd -P)" || rb=""
    [ -n "$ra" ] && [ -n "$rb" ] && [ "$ra" = "$rb" ]
}

# Does ONE repo path name this folder -- itself, a folder inside it, a
# folder containing it, as a string or through symlinks? The single rule
# the precondition, the doctor row and the strip's own selection all ask,
# so no two of them can disagree about what to remove.
orca_path_is_this_folder() {
    local p="$1" dir="$2" host="${CLAUDE_ORCA_HOST_PROJECT_DIR:-}"
    if orca_paths_include_dir "$dir" "$p"; then return 0; fi
    if same_dir_path "$p" "$dir"; then return 0; fi
    if [ -n "$host" ] && same_dir_path "$p" "$host"; then return 0; fi
    return 1
}

# The same question of the persisted store: does <file> list <dir> as a
# LOCAL project? This is what makes the strip verifiable -- the hand-off
# asks it before quitting anything (no point quitting an app over a file
# that does not name this folder) and the strip asks it again afterwards.
orca_data_json_lists_dir() {
    local f="$1" dir="$2" p
    [ -f "$f" ] || return 1
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if orca_path_is_this_folder "$p" "$dir"; then return 0; fi
    done <<REPOS
$(orca_data_json_repo_paths "$f")
REPOS
    return 1
}

# Is this folder one of them -- itself, a folder inside it, or a folder
# that contains it? Any of the three is a workspace the desktop app can
# open with no container around it. $2 is a newline-separated path list
# (from either of the two readers above).
orca_paths_include_dir() {
    local dir="$1" paths="$2" host="${CLAUDE_ORCA_HOST_PROJECT_DIR:-}" p=""
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$dir" in
            "$p"|"$p"/*) return 0 ;;
        esac
        case "$p" in
            "$dir"/*) return 0 ;;
        esac
        if [ -n "$host" ]; then
            case "$host" in
                "$p"|"$p"/*) return 0 ;;
            esac
            case "$p" in
                "$host"/*) return 0 ;;
            esac
        fi
    done <<REPOS
$paths
REPOS
    return 1
}

# Folder-scoped again (claude-orca-tgr reverses claude-orca-qhq's
# any-repo semantics along with the profile it depended on): is DIR
# itself, a folder inside it, or a folder that contains it, one of the
# paths a `repo list --json` answer names?
orca_lists_local_repo() {
    orca_paths_include_dir "$2" "$(orca_json_repo_paths "$1")"
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

# The two clicks that finish a hand-off the launcher could not finish
# itself: the same folder is ALSO a LOCAL project in the Mac's own Orca
# (badge "Local Mac"), where agents run with no container around them.
# Since 2026-09-13 that is no longer a reason to withhold the app -- the
# remote environment is registered either way -- so this is the ACTION,
# not a warning printed on the way to the browser.
#
# Two sources, because neither alone is enough: the file orca_hand_off
# wrote when it saw the leak itself (run/orca-local-leak, this run's own
# observation), and the app's own answer right now -- which catches a
# project added between the hand-off and this block, and keeps the note
# working for every caller that never ran a hand-off at all. Quiet when
# there is no app or no CLI to ask (the same gate as cmd_verify's "n/a"
# row): a folder on Linux, or a Mac with no Orca.app, has nothing to say.
#
# The labels are Orca 1.4.197's own (renderer bundle): the workspace
# context menu says "Remove Project from Orca", the local badge is
# "Local Mac", the sidebar button is "New workspace" and its host picker
# is "Run on". Settings > Remove Project is a DIFFERENT command --
# "Remove this project from Orca on all configured hosts" -- which would
# take the container's workspace with it, hence the warning against it.
orca_local_leak_note() {
    local dir="$1" name project app cli
    if [ ! -s "$(orca_leak_file "$dir")" ]; then
        app="$(find_orca_app 2>/dev/null)" || return 0
        cli="$(orca_cli "$app" 2>/dev/null)" || return 0
        orca_lists_local_repo "$("$cli" repo list --json 2>/dev/null || true)" "$dir" || return 0
    fi
    name="$(orca_env_name "$dir")"
    project="$(derive_project_name "$dir")"
    cat <<ACTION

ACTION NEEDED in Orca, once. This folder is ALSO open there as a LOCAL project,
and agents started in that workspace run on the Mac with no sandbox.
  1. In Orca's sidebar, under the project "$project", find the workspace
     badged "Local Mac".
  2. Right-click that workspace and choose "Remove Project from Orca".
     Do NOT use Settings > Remove Project: that removes it on every host,
     the container's copy included.
  3. The workspace badged "$name" is the sandboxed one -- open it.
     To make another: click "+" (New workspace), pick the project
     "$project", and under "Run on" choose "$name".
  If the "$name" workspace is missing afterwards, rerun ./claude-dev.
ACTION
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

# --- the scratch volumes (claude-orca-7uy) --------------------------------
#
# The other write-heavy, regenerable agent state gets the same treatment
# as Orca's user-data-dir, because file-creating work on the bind-mount
# share is what the Docker VM pays for (measured in claude-orca-19o: 3000
# small files create/stat/rm = 901 ms and 61,129 VM interrupts on the
# share vs 59 ms and 330 on a docker volume; a full checkout 842 ms /
# 55,654 vs 283 ms / 10,848). Caches, opencode's session data and the
# worktrees Orca links live on four more per-container volumes -- named
# after the container like the state volume, so teardown can remove them
# without a record, and the container half (claude-orca-1eh) migrates the
# shadowed copies onto them. The project folder itself and the rest of
# /home/agent STAY bind mounts: the user must keep seeing the folder the
# template was started in, on the Mac and in Orca. The guest paths are the
# one interface with the container: they ride in as CLAUDE_ORCA_VOLUME_DIRS.
SCRATCH_VOLUMES="cache:/home/agent/.cache npm:/home/agent/.npm opencode:/home/agent/.local/share/opencode worktrees:/home/agent/worktrees"
scratch_volume() { printf '%s-%s\n' "$1" "$2"; }        # <container name> <suffix>

# --- the cpu cap (claude-orca-wda) ---------------------------------------
#
# A container may use every core of the Docker VM, and nothing anywhere
# limits how many agents run inside one -- so parallel agents saturate the
# Mac (measured in claude-orca-19o: cgroup cpu.max read "max" on a 10-core
# VM). A folder that wants its own answer writes "cpus" in
# claude-orca.json; null -- what register seeds -- now means a DEFAULT cap
# of half the VM's cores, and an explicit 0 stays docker's own "no
# limit": the documented opt-out.
#
# default_cpus halves what `docker info` reports as NCPU, integer
# division, never below one -- a one-core VM still gets one core, never
# zero -- and prints nothing when docker does not answer with a positive
# integer, so a half-broken daemon costs a folder nothing. The local
# runtime has no cgroup to cap, so there is never a cap there.
default_cpus() {
    local n
    if [ "$CTR_RUNTIME" = "local" ]; then return 0; fi
    n="$(ctr info --format '{{.NCPU}}' 2>/dev/null)"
    case "$n" in
        ''|*[!0-9]*|0*) return 0 ;;
    esac
    n=$((n / 2))
    if [ "$n" -lt 1 ]; then n=1; fi
    printf '%s\n' "$n"
}

# The cap THIS folder runs at: its own "cpus" verbatim when it has one
# (2, 2.5 and 0 all read as written), the default otherwise.
desired_cpus() {
    local cpus
    cpus="$(json_get "$1" '.cpus')"
    if [ -n "$cpus" ]; then
        printf '%s\n' "$cpus"
    else
        default_cpus
    fi
}

# A kept container -- container_matches said it is this folder's and the
# launcher reuses it instead of recreating -- gets the cap applied live:
# `docker update`, never fatal, never a recreate. Skipped when the
# container is already at the cap, and on the local runtime, which has no
# cgroup to update.
apply_cpu_cap() {
    local dir="$1" name="$2" cpus have want
    if [ "$CTR_RUNTIME" = "local" ]; then return 0; fi
    cpus="$(desired_cpus "$dir")"
    if [ -z "$cpus" ]; then return 0; fi
    have="$(ctr inspect -f '{{.HostConfig.NanoCpus}}' "$name" 2>/dev/null | head -1 | tr -d '[:space:]')"
    # NanoCpus is nanoseconds of CPU per second -- 5e9 is five cores -- and
    # the desired value may be a decimal, so the product goes through awk
    # rather than $(( )). LC_ALL=C: a decimal point is a decimal point
    # whatever the Mac's locale says.
    want="$(LC_ALL=C awk -v c="$cpus" 'BEGIN { printf "%d", c*1e9 }')"
    if [ "$have" != "$want" ]; then
        ctr update --cpus "$cpus" "$name" >/dev/null 2>&1 || \
            echo "  could not apply the cpu cap to $name" >&2
    fi
}

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
TOOLCHAIN_MOUNTS="usr-local:/usr/local opt-Orca:/opt/Orca"

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

# The image ref THIS folder's container runs. startup v4: a folder with no
# reachable prebuilt image runs the public base image with the mounted
# template's entrypoint as its command, so "the image we build" is not the
# answer for every folder. container_create picks the ref through here and
# container_matches compares against the same function -- asking image_ref
# directly would read every runtime-path folder's own container as a
# stranger's and recreate it on every open.
folder_image_ref() {
    if [ "$(image_source "$1")" = "runtime" ]; then
        printf '%s\n' "$BASE_IMAGE"
    else
        image_ref
    fi
}

container_create() {
    local dir="$1" name="$2" port="$3" ref src token cpus memory mount theme dns guest ver
    guest="$(guest_project_dir "$dir")"
    src="$(image_source "$dir")"
    ref="$(folder_image_ref "$dir")"
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
    rm -f "$dir/.claude-dev/run/orca-web-url.txt" "$dir/.claude-dev/run/sshd.ready"

    # The toolchain cache, made before the run so docker mounts real
    # directories rather than creating root-owned ones of its own -- and
    # only for a folder that is going to install into it.
    if [ "$src" = "runtime" ]; then
        for mount in $TOOLCHAIN_MOUNTS; do
            mkdir -p "$dir/.claude-dev/toolchain/${mount%%:*}"
        done
    fi

    # The two bind mounts stay first, then the state volume and the four
    # scratch ones -- these lines and SCRATCH_VOLUMES (see state_volume)
    # say the same thing, in the same order.
    #
    # The published port is sshd's (CLAUDE_ORCA_SSHD_PORT, the port the
    # Mac's ssh config names). Orca still runs inside until it is removed,
    # one port up and NOT published: the Mac no longer talks to it.
    set -- run -d --name "$name" \
        --volume "$dir:$guest" \
        --volume "$dir/.claude-dev/home:/home/agent" \
        --volume "$(state_volume "$name"):/home/agent/.config/orca" \
        --volume "$(scratch_volume "$name" cache):/home/agent/.cache" \
        --volume "$(scratch_volume "$name" npm):/home/agent/.npm" \
        --volume "$(scratch_volume "$name" opencode):/home/agent/.local/share/opencode" \
        --volume "$(scratch_volume "$name" worktrees):/home/agent/worktrees" \
        -e "CLAUDE_ORCA_VOLUME_DIRS=/home/agent/.cache:/home/agent/.npm:/home/agent/.local/share/opencode:/home/agent/worktrees" \
        -p "127.0.0.1:$port:$port" \
        -e "PROJECT_DIR=$guest" \
        -e "CLAUDE_ORCA_HOST_PROJECT_DIR=$dir" \
        -e "CLAUDE_ORCA_ROOT=$guest" \
        -e "BEADS_DIR=$guest/.beads" \
        -e "CLAUDE_ORCA_SSHD_PORT=$port" \
        -e "ORCA_PORT=$((port + 1))" \
        -e "HOST_UID=$(id -u)" \
        -e "GH_TOKEN=$token" \
        -e "CLAUDE_ORCA_THEME=$theme" \
        -e "CLAUDE_ORCA_TERMINAL_THEME=$terminal_theme" \
        -e "CLAUDE_ORCA_PROJECT_NAME=$(derive_project_name "$dir")" \
        -e "CLAUDE_ORCA_GIT_NAME=$(git_identity_name)" \
        -e "CLAUDE_ORCA_GIT_EMAIL=$(git_identity_email)"

    # The image was built at wanted_orca_version -- the ONE answer the tag
    # and the build arg already use -- so boot-time setup.sh must not fall
    # back to its own pin: measured 2026-09-19 as 1.4.197 reinstalled over
    # an image built at 1.4.203, a download and a downgrade per recreate.
    ver="$(wanted_orca_version)"
    if [ -n "$ver" ]; then
        set -- "$@" -e "ORCA_VERSION=$ver"
    fi

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

    # claude-orca-376: no -e OPENROUTER_API_KEY here any more.
    # .claude-dev/home and /home/agent are the same directory inside the
    # container (same device, same inode), so a key
    # `claude-dev key openrouter` wrote to .claude-dev/home/.openrouter.key
    # is already on the mount the entrypoint reads -- putting it in the
    # docker-run argv too just put it in PID 1's /proc/<pid>/environ for
    # the whole container uptime, which is the exact exposure the guard
    # exists to prevent.

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

    cpus="$(desired_cpus "$dir")"
    if [ -n "$cpus" ]; then
        set -- "$@" --cpus "$cpus"
        if [ -z "$(json_get "$dir" '.cpus')" ]; then
            echo "  cpu cap: $cpus of $(ctr info --format '{{.NCPU}}' 2>/dev/null) cores (default; set \"cpus\" in claude-orca.json -- 0 = no cap)" >&2
        fi
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

# Docker Desktop's VM spells a Mac bind mount's host path in its own
# namespace: the folder the launcher mounts as /Users/joe/Harness test is
# answered by `docker inspect` as /host_mnt/Users/joe/Harness test (real
# Mac, 2026-10-03 -- every start read "not this folder's ... recreating it"
# and no container survived two opens). The launcher spells paths the Mac
# way, so a docker-reported Source is compared only after ONE leading
# /host_mnt is stripped -- and only when what follows it is itself an
# absolute path, so a Mac folder whose own name merely begins with
# host_mnt is never mangled.
docker_host_path() {
    local p="$1"
    case "$p" in
        /host_mnt/*) p="${p#/host_mnt}" ;;
    esac
    printf '%s\n' "$p"
}

# A container with the right NAME is not necessarily this folder's
# container. The name is derived from the folder's basename alone, an
# older generation of this template used the same one, and bootstrap moves
# that generation's .claude-dev aside without touching what it left
# running -- so a fresh bootstrap of a second folder found a container by
# the right name, reused it, and paired the Mac's Orca.app to a runtime
# holding someone else's mounts: the project appeared in the sidebar and
# was empty, no shell, no agents (a real Mac, 2026-09-13).
#
# So reuse is conditional on the five things that decide WHICH runtime the
# app is about to be handed: the image, the project mount, the home mount,
# the published port and the sshd port in its env. Returns 0 when all five
# are this folder's, and
# otherwise prints one line naming the FIRST mismatch and returns 1.
# It never looks at the state volume -- that is Orca's own user-data dir,
# it survives a recreate on purpose, and it is keyed by container name.
container_matches() {
    local name="$1" dir="$2" port="$3" guest want have want_id have_id have_port have_ssh mounts m found="" facts
    # CTR_RUNTIME=local runs the entrypoint as a host process: no image, no
    # mounts and no port map exist, and ctr_local's `inspect` answers the
    # state word to every template whatever it asks for. There is nothing
    # to compare, so a container by the right name is the right container.
    if [ "$CTR_RUNTIME" = "local" ]; then
        return 0
    fi

    # Image, by name first. A tag that was re-pointed since this container
    # started (a rebuild under the same IMAGE_TAG) reads as a mismatch by
    # name and as a match by id, and the id is the one that says whether it
    # is the same filesystem -- so the name differing only counts once the
    # id does too. An image inspect that cannot answer at all leaves the
    # name comparison standing.
    want="$(folder_image_ref "$dir")"
    # Everything compared below comes from ONE `docker inspect` (each is a
    # round trip to the daemon): image name, image id, the published port
    # (blank when it publishes none), then one Source:Destination per mount.
    # The port comes from .HostConfig.PortBindings, not .NetworkSettings.Ports:
    # moby's releaseNetwork empties the latter the moment a container stops
    # (v27.5.1 daemon/container_operations.go:999, Ports = nil at :1016), so
    # every stopped container of this folder read as "port: none" and was
    # recreated instead of started. HostConfig.PortBindings is the record of
    # what the container was created to publish, and the one place the claim
    # survives a stop.
    #
    # The fourth line is the env check, asked as a yes/no inside the
    # template (the line says "ssh" or is blank) so no env value -- the
    # GitHub token is one -- ever comes back through the pipe: a container
    # made before the ssh panes has no CLAUDE_ORCA_SSHD_PORT=<port> in its
    # env, runs no sshd on that port, and is recreated (the migration for
    # old folders).
    facts="$(ctr inspect -f "{{println .Config.Image}}{{println .Image}}{{with index .HostConfig.PortBindings \"$port/tcp\"}}{{(index . 0).HostPort}}{{end}}{{println}}{{range .Config.Env}}{{if eq . \"CLAUDE_ORCA_SSHD_PORT=$port\"}}ssh{{end}}{{end}}{{println}}{{range .Mounts}}{{.Source}}:{{println .Destination}}{{end}}" "$name" 2>/dev/null || true)"
    { IFS= read -r have; IFS= read -r have_id; IFS= read -r have_port
      IFS= read -r have_ssh
      mounts="$(cat)"; } <<FACTS
$facts
FACTS
    have="${have//[[:space:]]/}"; have_id="${have_id//[[:space:]]/}"
    have_port="${have_port//[[:space:]]/}"; have_ssh="${have_ssh//[[:space:]]/}"
    if [ "$have" != "$want" ]; then
        want_id="$(ctr image inspect "$want" --format '{{.Id}}' 2>/dev/null | head -1 | tr -d '[:space:]')"
        if [ -z "$have_id" ] || [ -z "$want_id" ] || [ "$have_id" != "$want_id" ]; then
            echo "  container $name is not this folder's (image: ${have:-unknown} vs $want) -- recreating it" >&2
            return 1
        fi
    fi
    if [ "$have_ssh" != "ssh" ]; then
        echo "  container $name has no sshd on port $port (made before the ssh panes) -- recreating it" >&2
        return 1
    fi

    # The project mount, then the home mount, each as one source:destination
    # pair out of the container's own Mounts. A stranger's container is
    # usually caught here: it mounts ANOTHER folder, or mounts this kind of
    # folder at a path this generation no longer uses. The Source is
    # docker-reported, so it goes through docker_host_path first: Docker
    # Desktop spells a Mac path /host_mnt/Users/... and the launcher spells
    # it /Users/....
    guest="$(guest_project_dir "$dir")"
    have=""
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        case "$m" in
            *":$guest")
                have="${m%:$guest}"
                if [ "$(docker_host_path "$have")" = "$dir" ]; then found=1; fi
                ;;
        esac
    done <<MOUNTS
$mounts
MOUNTS
    if [ -z "$found" ]; then
        echo "  container $name is not this folder's (mount: ${have:-none} vs $dir at $guest) -- recreating it" >&2
        return 1
    fi
    found=""
    while IFS= read -r m; do
        case "$m" in
            *":/home/agent")
                if [ "$(docker_host_path "${m%:/home/agent}")" = "$dir/.claude-dev/home" ]; then found=1; fi
                ;;
        esac
    done <<MOUNTS
$mounts
MOUNTS
    if [ -z "$found" ]; then
        echo "  container $name is not this folder's (home mount: none vs $dir/.claude-dev/home) -- recreating it" >&2
        return 1
    fi

    # The scratch volumes (claude-orca-7uy): a container from before the
    # launcher mounted them still matches on image, mounts and port, but
    # its writes would land on the macOS share the volumes exist to keep
    # the VM off -- so it is recreated too.
    for pair in $SCRATCH_VOLUMES; do
        p="${pair#*:}"
        found=""
        while IFS= read -r m; do
            [ -n "$m" ] || continue
            case "$m" in
                *":$p") found=1 ;;
            esac
        done <<MOUNTS
$mounts
MOUNTS
        if [ -z "$found" ]; then
            echo "  container $name predates the scratch volumes (nothing mounted at $p) -- recreating it" >&2
            return 1
        fi
    done

    # The published port. A container that publishes none reads blank --
    # a mismatch: the URL this folder is about to open would reach nothing.
    if [ "$have_port" != "$port" ]; then
        echo "  container $name is not this folder's (port: ${have_port:-none} vs $port) -- recreating it" >&2
        return 1
    fi
    return 0
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
    local dir="${1:-$PROJECT_SELF}" name port was state rc=0 t0 t1
    # An older Ghostty install is re-applied here (one line, never fatal).
    ghostty_refresh_if_stale || true
    [ -d "$dir" ] || { echo "Error: directory does not exist: $dir" >&2; return 1; }
    dir="$(cd "$dir" && pwd -P)"
    if [ ! -f "$(orca_json "$dir")" ]; then
        echo "Error: $dir is not registered -- run './claude-dev register'" >&2
        return 1
    fi
    ctr_init "$dir"

    name="$(container_name "$dir")"
    port="$(choose_port "$dir")"

    # The image ref follows the Mac's Orca.app (image_tag), and the app
    # updates itself: a plain open after an app update (1.4.219 -> .220,
    # a real Mac, 2026-10-06) wanted claude-orca:latest-orca1.4.220, which
    # only --update would have built -- so the old container was removed as
    # a stranger's and `docker run` went off to pull the new tag from Docker
    # Hub ("pull access denied for claude-orca"). A built folder whose image
    # is missing builds it here, before anything is torn down; the build is
    # a cache hit for every layer below the Orca one.
    if [ "$CTR_RUNTIME" != "local" ] && [ "$(image_source "$dir")" != "runtime" ] \
        && ! ctr image inspect "$(image_ref)" >/dev/null 2>&1; then
        echo "  image $(image_ref) is not on this machine (the Orca app moved?) -- building it"
        acquire_image "$dir" "$(image_ref)" || return 1
    fi

    # Adopt a container only when it is this folder's (container_matches
    # says which of image, mounts and port is not). A stranger's is stopped
    # and removed -- never its state volume, which is Orca's user-data dir
    # and is keyed by the same name -- and the create path below builds
    # this folder's own. Its run/ results go with it for the same reason
    # cmd_update_v3 clears them: the pairing URL of a container that is
    # gone opens nothing.
    state="$(container_state "$name")"
    if [ -n "$state" ] && ! container_matches "$name" "$dir" "$port"; then
        ctr stop "$name" >/dev/null 2>&1 || true
        ctr rm -f "$name" >/dev/null 2>&1 || true
        clear_run_results "$dir"
        state=""
    fi

    # The port was chosen once and is reused forever -- but that is only
    # this folder's promise. While its container is down nothing holds the
    # number (container_port_claims says why), so the next folder to
    # register is handed the same one, and whichever of the two starts
    # second dies in `docker run` on "Bind for 127.0.0.1:<port> failed:
    # port is already allocated" -- on every start, because the number is
    # persisted, and each failed run leaves a `created` container behind
    # for the next one to trip over (a real Mac, 2026-09-19). So a folder
    # about to create or start its container asks again, and moves when the
    # number is someone else's now. A running container of this folder's
    # own already holds its port and is never asked; one that is down was
    # created for the old number and goes, the way a stranger's does.
    if [ "$state" != "running" ] && port_taken "$port" "$name"; then
        was="$port"
        port="$(next_free_port "$name")"
        echo "  port $was is in use by something else on this machine -- this folder moves to $port" >&2
        if [ -n "$state" ]; then
            ctr rm -f "$name" >/dev/null 2>&1 || true
            state=""
        fi
        clear_run_results "$dir"
    fi
    persist_port "$dir" "$port"

    # The folder's ssh keys and config exist before the container is created
    # or started: sshd reads the host key and authorized_keys at boot.
    ssh_ensure_keys "$dir" || return 1
    ssh_write_config "$dir" "$port" || return 1

    # A kept container gets the cap applied live (apply_cpu_cap): the
    # create path below already passes --cpus, so this is only for the
    # container the launcher is about to reuse. An empty $state here means
    # the container was removed above and the create path handles the cap.
    if [ -n "$state" ]; then
        apply_cpu_cap "$dir" "$name"
    fi

    case "$state" in
        running)
            echo "Container $name is already running."
            ;;
        "")
            container_create "$dir" "$name" "$port" || return 1
            ;;
        *)
            echo "==> Starting $name (was $state)"
            # sshd.ready belongs to the run that wrote it; the restarted
            # container writes its own, and waiting must not see the old one.
            rm -f "$dir/.claude-dev/run/sshd.ready"
            if ! ctr start "$name" >/dev/null; then
                echo "Error: 'container start $name' failed" >&2
                return 1
            fi
            ;;
    esac

    # What open waits for is sshd, not Orca's web URL: the Mac no longer
    # talks to the Orca inside the container (it stays until C1 deletes it).
    # wait_for_sshd_ready returns 3 after printing its own host-key message.
    t0="$(date +%s)"
    wait_for_sshd_ready "$dir" "$name" || rc=$?
    t1="$(date +%s)"
    if [ "$rc" -eq 3 ]; then
        return 1
    elif [ "$rc" -ne 0 ]; then
        {
            if [ "$rc" -eq 2 ]; then
                echo "Error: the container $name exited during startup before sshd was ready."
            else
                echo "Error: sshd did not come up within $(weburl_timeout "$dir")s."
            fi
            echo "  Look at what it printed:  ./claude-dev logs"
            if [ "$(image_source "$dir")" = "runtime" ]; then
                echo "  Toolchain install log:    $dir/.claude-dev/run/setup.log"
            fi
            echo "  sshd log:                 $dir/.claude-dev/run/sshd.log"
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
            # sshd's own output is the other half of the diagnosis, and a
            # container that died is in no state to show it (claude-orca-cey).
            # It carries no credentials, so it is shown as written.
            if [ -s "$dir/.claude-dev/run/sshd.log" ]; then
                echo ""
                echo "Last lines of sshd's log:"
                tail -20 "$dir/.claude-dev/run/sshd.log" | sed 's/^/  /'
            fi
        } >&2
        return 1
    fi

    # The one number a person actually wants after typing ./claude-dev.
    echo "sshd is up ($((t1 - t0))s)"
    resync_config "$dir" "$name"
    ssh_push_terminfo "$dir"
    if [ "${TERM_PROGRAM:-}" != "ghostty" ] && pane_has_terminal; then
        echo "  tip: ./claude-dev ghostty sets up Ghostty, the terminal these panes are made for"
    fi
    # The terminal that typed ./claude-dev becomes the pane (or, without a
    # terminal, is told how to get one). `pane` hands its directory in
    # PANE_CWD; an `open` pane starts where it was typed.
    pane_exec "$dir" "${PANE_CWD:-$PWD}" slow
}

# `claude-dev pane [dir]`: make THIS terminal a sandbox pane for the folder
# that contains dir (default $PWD) -- what Ghostty's new tabs and splits run.
# Fast path: the folder's ssh master connection answers `-O check`, so the
# pane is one `exec ssh` and not a single docker call (ctr_init is NOT run:
# the ssh_* helpers and derive_project_name never touch docker). Otherwise it
# is `open` (start the container, wait for sshd, push terminfo) ending in the
# same pane_exec. Whatever goes wrong -- no folder above dir, not registered,
# the sandbox would not come up -- the reason goes to stderr and the terminal
# becomes a Mac login shell under a banner that says it is NOT sandboxed, so
# a new tab is never a dead one. Exit codes: whatever the shell exits with
# (it is exec'd); 0 when there is no terminal and the pane was only announced.
cmd_pane_v3() {
    local start d="" cand cfg alias reason="" rc
    start="$(cd "${1:-$PWD}" 2>/dev/null && pwd -P)" || start=""
    if [ -z "$start" ]; then
        reason="the directory ${1:-$PWD} does not exist"
    else
        cand="$start"
        while :; do
            if [ -f "$(orca_json "$cand")" ]; then d="$cand"; break; fi
            [ "$cand" = "/" ] && break
            cand="$(dirname "$cand")"
        done
        [ -n "$d" ] || reason="$start is not inside a claude-dev folder"
    fi
    if [ -z "$reason" ]; then
        cfg="$(ssh_state_dir "$d")/config"
        alias="$(ssh_host_alias "$d")"
        if "${CLAUDE_ORCA_SSH:-ssh}" -F "$cfg" -O check "$alias" >/dev/null 2>&1; then
            pane_exec "$d" "$start" fast
            return $?
        fi
        rc=0
        PANE_CWD="$start" cmd_open_v3 "$d" || rc=$?
        [ "$rc" -eq 0 ] && return 0
        reason="the sandbox for $d would not come up (see above)"
    fi
    {
        echo "claude-dev pane: $reason"
        echo "== Mac shell -- NOT sandboxed =="
    } >&2
    exec "${SHELL:-/bin/zsh}" -l
}

cmd_register_v3() {
    local dir="${1:-$PROJECT_SELF}" name port ui
    [ -d "$dir" ] || { echo "Error: directory does not exist: $dir" >&2; return 1; }
    dir="$(cd "$dir" && pwd -P)"
    name="$(derive_project_name "$dir")"

    mkdir -p "$dir/.claude-dev/home" "$dir/.claude-dev/run" "$dir/.claude-dev/state"
    ctr_init "$dir"

    # Defaults only if absent -- never reset a folder's own edits. cpus
    # null now means the default cap (half the VM's cores) and cpus 0
    # means no cap; memory null means "whatever `container` defaults to";
    # extraMounts are host paths mounted read-only beside the project.
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
    clip_listen_stop "$dir"
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
    local dir="$PROJECT_SELF" rc=0 ref name state port src vol app ver cli
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

    # What `open` and `pane` actually use: sshd answering on the folder's
    # port, the ControlMaster, and the folder's key being accepted. These
    # replace the old `web url` row -- the Mac no longer talks to Orca.
    doctor_ssh_rows "$dir" || rc=2

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

    ghostty_doctor_rows || rc=2
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
    local dir="${1:-$PROJECT_SELF}" name state rc=0 port st nm detail rows
    local app="" cli="" data="" src="" running=""
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

    # sshd / ssh master / ssh key auth, in place of the old `web url` row.
    doctor_ssh_rows "$dir" || rc=2

    # The one row only the Mac can answer, and the guard for the one risk
    # the desktop client adds (.claude/plans/desktop-orca.md S5,
    # claude-orca-tgr): Orca's app can open LOCAL workspaces, which run
    # agents on the Mac with no container around them, and 1.4.197 has no
    # knob to disable them. Folder-scoped again, against the one installed
    # app -- claude-orca-qhq's own profile (and its any-repo semantics) is
    # gone. n/a only when there is no app to ask at all; otherwise this
    # reads the live `repo list --json` while the app is running (the
    # source the hand-off's own self-heal reads) or orca-data.json
    # directly when it is not (the only way to ask with the process down)
    # and says which source it read.
    app="$(find_orca_app)" || app=""
    if [ -z "$app" ]; then
        doctor_row n/a "local repos" "no Orca.app on this host -- nothing here can open the folder outside the container"
    else
        cli="$(orca_cli "$app")" || cli=""
        running=""
        if [ -n "$cli" ] && orca_json_app_running "$("$cli" status --json 2>/dev/null || true)"; then
            running=1
        fi
        if [ -n "$running" ]; then
            src="repo list --json"
            if orca_lists_local_repo "$("$cli" repo list --json 2>/dev/null || true)" "$dir"; then
                doctor_row FAIL "local repos" "the Mac's own Orca tracks this folder as a LOCAL repo ($src) -- agents opened there run on the Mac, outside this container; remove it in Orca"
                rc=2
            else
                doctor_row ok "local repos" "the Mac's own Orca does not track this folder locally ($src)"
            fi
        else
            data="$(orca_user_data_dir "$dir" "$cli")"
            if [ -n "$data" ]; then
                src="$(orca_data_json_file "$data")"
                if orca_data_json_lists_dir "$src" "$dir"; then
                    doctor_row FAIL "local repos" "the Mac's own Orca tracks this folder as a LOCAL repo ($src) -- agents opened there run on the Mac, outside this container; remove it in Orca"
                    rc=2
                else
                    doctor_row ok "local repos" "the Mac's own Orca does not track this folder locally ($src)"
                fi
            else
                doctor_row ok "local repos" "$(orca_no_data_dir_message)"
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

    ghostty_doctor_rows || rc=2
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
            prune_old_refs "$ref"
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
    # The folder's ssh ControlMaster is a process on the Mac, not in the
    # container: left alone it would outlive the folder it points at. The
    # keys, config and known_hosts under state/ssh go with .claude-dev below.
    if [ -f "$(ssh_state_dir "$dir")/config" ]; then
        "${CLAUDE_ORCA_SSH:-ssh}" -F "$(ssh_state_dir "$dir")/config" -O exit "$(ssh_host_alias "$dir")" >/dev/null 2>&1 || true
    fi
    clip_listen_stop "$dir" log
    ctr stop "$name" >/dev/null 2>&1 || true
    ctr rm "$name" >/dev/null 2>&1 || true
    # Orca's user-data-dir is the one piece of folder state that lives in a
    # volume rather than in .claude-dev (see state_volume): teardown is
    # what keeps "dies with the folder" true of it. A `docker rm` on the
    # container never touches a NAMED volume, so this is not redundant.
    ctr volume rm "$(state_volume "$name")" >/dev/null 2>&1 || true
    # The scratch volumes (see state_volume) are named after the container
    # too, so teardown names them the same way -- regenerable state, but
    # "dies with the folder" is still the promise.
    for pair in $SCRATCH_VOLUMES; do
        ctr volume rm "$(scratch_volume "$name" "${pair%%:*}")" >/dev/null 2>&1 || true
    done

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
    # Orca's on-disk residue (claude-orca-aeu): the linked worktrees under
    # .orca-worktrees/ carry a .git FILE each, which `git add -A` stages as
    # embedded-repo gitlinks and a push then rejects, and root .orca/ is
    # Orca's drop state. Removing them through `git worktree remove` first
    # keeps the worktree metadata (.git/worktrees, the branch itself) sane;
    # prune clears the entries whose directory a user deleted by hand. A
    # folder that is not a git repo gets the plain rm only, silently.
    if [ -d "$dir/.orca-worktrees" ] || [ -d "$dir/.orca" ]; then
        if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            for wt_dir in "$dir"/.orca-worktrees/*/; do
                [ -d "$wt_dir" ] || continue
                git -C "$dir" worktree remove --force "${wt_dir%/}" >/dev/null 2>&1 || true
            done
            git -C "$dir" worktree prune >/dev/null 2>&1 || true
        fi
        rm -rf "$dir/.orca-worktrees" "$dir/.orca"
        echo "Removed .orca-worktrees and .orca from $dir"
    fi
    gitignore_unseed "$dir"

    # claude-orca-gwl's output directory is Orca residue like .orca above.
    if [ -d "$dir/graphify-out" ]; then
        rm -rf "$dir/graphify-out"
        echo "Removed graphify-out from $dir"
    fi

    # The .git this setup may have created (claude-orca-avp): a folder that
    # was never a repository got one from provision.d/55-git-init, whose
    # root commit carries the marker "claude_orca: seed commit". Teardown
    # removes .git only when every one of these holds: the folder is the
    # repository's toplevel (a folder folded into a larger repo, or a
    # linked worktree whose .git is a pointer into another repository,
    # never qualifies); the history has exactly one root commit; and that
    # root's subject carries the marker. User commits on top of a seed
    # root still lose .git -- the ask is a folder that folds into a larger
    # repo and pushes. Anything else keeps .git, with the reason in one
    # line; a folder with no .git of its own says nothing.
    if [ -d "$dir/.git" ]; then
        keep=""
        top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
        if [ "$top" != "$dir" ]; then
            keep="the folder is not the repository toplevel"
        fi
        if [ -z "$keep" ]; then
            root_count=0
            root_sha=""
            roots="$(git -C "$dir" rev-list --max-parents=0 HEAD 2>/dev/null || true)"
            for root in $roots; do
                root_count=$((root_count + 1))
                root_sha="$root"
            done
            case "$root_count" in
                0) keep="git cannot read the repository history" ;;
                1) ;;
                *) keep="the repository has $root_count root commits" ;;
            esac
        fi
        if [ -z "$keep" ]; then
            subject="$(git -C "$dir" log -1 --format=%s "$root_sha" 2>/dev/null)"
            case "$subject" in
                "claude_orca: seed commit"*) ;;
                *) keep="the root commit is not claude_orca's seed commit" ;;
            esac
        fi
        if [ -z "$keep" ]; then
            rm -rf "$dir/.git"
            echo "removed .git (claude_orca created it)"
        else
            echo "kept .git ($keep)"
        fi
    fi

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
  claude-dev pane [dir]         A sandbox pane in this terminal (fast when one
                                is already up)
  claude-dev stop               Stop this folder's container
  claude-dev shell              A login shell inside the container
  claude-dev verify             Check this folder is set up the way the
                                template promises: the boundary, the
                                toolchain, beads, the rulebook, agents,
                                hooks, git identity and Orca's own state
  claude-dev logs               Follow the container's output
  claude-dev ghostty [--uninstall|--check]
                                Route Ghostty panes into sandboxed folders
                                (one include line in your Ghostty config);
                                --uninstall gives the config back unchanged
  claude-dev key openrouter     Store this folder's OpenRouter key (not
                                echoed) for the delegate routes
  claude-dev --how-to-run       Print the URL and the two commands
  claude-dev --doctor           CLI, service, image, container, port, sshd, ssh
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
    pane)          shift; cmd_pane_v3 "${1:-}"; exit $? ;;
    stop)          shift; cmd_stop_v3 "${1:-$PROJECT_SELF}" || exit $?; exit 0 ;;
    shell)         shift; cmd_shell_v3 "${1:-$PROJECT_SELF}" || exit $?; exit 0 ;;
    verify)        shift; cmd_verify_v3 "${1:-$PROJECT_SELF}" || exit $?; exit 0 ;;
    logs)          shift; cmd_logs_v3 "${1:-$PROJECT_SELF}" || exit $?; exit 0 ;;
    key)           shift; cmd_key_v3 "$@" || exit $?; exit 0 ;;
    ghostty)       shift; ghostty_main "$@" || exit $?; exit 0 ;;
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
