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
#   claude-dev key openrouter     Store this folder's OpenRouter key
#   claude-dev --how-to-run       Print the URL and the two commands
#   claude-dev --doctor           CLI, service, image, container, port, web url
#   claude-dev --update           Pull the template and the image, recreate
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

IMAGE_REPO="${CLAUDE_ORCA_IMAGE_REPO:-ghcr.io/joe-rayment/claude_orca}"

# The pinned tag lives in one file at the template root, so a folder that
# only ever runs `claude-dev --update` moves to the new image with the pull.
image_tag() {
    local f tag=""
    for f in "$TEMPLATE_ROOT/IMAGE_TAG" "$HOST_DIR/template/IMAGE_TAG"; do
        if [ -f "$f" ]; then
            tag="$(tr -d '[:space:]' < "$f")"
            break
        fi
    done
    if [ -z "$tag" ]; then tag="latest"; fi
    printf '%s\n' "$tag"
}

# CLAUDE_ORCA_IMAGE names a whole ref and wins over the IMAGE_TAG file: CI
# builds the image locally and points the launcher at it, so the runtime the
# workflow exercises is the one the Mac runs.
image_ref() {
    if [ -n "${CLAUDE_ORCA_IMAGE:-}" ]; then
        printf '%s\n' "$CLAUDE_ORCA_IMAGE"
        return 0
    fi
    printf '%s:%s\n' "$IMAGE_REPO" "$(image_tag)"
}
image_registry() { printf '%s\n' "${IMAGE_REPO%%/*}"; }
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
    printf '%s%s\n' "$CTR_RUNTIME" "$out"
}

# Every backend mirrors its argv into the folder's log, redaction and all.
ctr_mirror() {
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
        "image pull"|"image ls"|"image list"|"image inspect") return 0 ;;
        "registry login"|"registry logout")                   return 0 ;;
        "system start"|"system status"|"system stop")         return 0 ;;
    esac
    case "${1:-}" in
        pull|login|logout|info) return 0 ;;
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

# qa2.8: a stock gh OAuth token (repo, read:org, gist, workflow) can log in
# to ghcr.io and still be denied the manifest, so the pull is worth
# attempting only when the token actually carries read:packages. The scopes
# come from the X-Oauth-Scopes response header of any authenticated API
# call: `gh auth status` prints them too, but its wording moves between gh
# versions, while the header does not. Header name matched
# case-insensitively (lowercased under HTTP/2), value comma-separated.
# Never prompts and never runs `gh auth refresh` -- that is interactive.
#
# Three outcomes, not two: the header exists only for classic OAuth tokens.
# A fine-grained PAT (github_pat_...) or a GitHub App token never sends it,
# so for those the scopes are UNKNOWN, not empty -- and a user on such a
# token (the real Mac run of 2026-09-06) was being sent down the runtime
# install path on every folder for a pull that would have worked.
#   0  the header is present and lists the scope
#   1  the header is present and does not list it (the qa2.8 finding: a
#      classic token that GHCR will refuse)
#   2  no X-Oauth-Scopes header at all: unknown, worth one pull attempt
gh_has_scope() {
    local want="$1" header="" scopes=""
    command -v gh >/dev/null 2>&1 || return 1
    header="$(gh api -i user 2>/dev/null \
        | tr -d '\r' \
        | tr '[:upper:]' '[:lower:]' \
        | sed -n 's/^x-oauth-scopes:/&/p' \
        | head -1)" || header=""
    [ -n "$header" ] || return 2
    scopes="$(printf '%s\n' "$header" \
        | sed 's/^x-oauth-scopes:[[:space:]]*//' \
        | tr -d '[:space:]')"
    case ",$scopes," in
        *",$want,"*) return 0 ;;
    esac
    return 1
}

# startup v4 (claude-orca-qa2.10): when the prebuilt image is out of reach
# the folder runs the PUBLIC base image instead, with the mounted
# template's own entrypoint as its command -- setup.sh then installs the
# toolchain inside the VM on that first start. No image build on the
# Mac: an image build is the one step this repo can never test here, and
# the builder VM was where registration kept dying.
BASE_IMAGE="${CLAUDE_ORCA_BASE_IMAGE:-docker.io/library/ubuntu:24.04}"
RUNTIME_INSTALL_NOTE="No prebuilt image: the VM installs its toolchain on first start (several minutes); progress: ./claude-dev logs"

# Which of the two images this folder runs -- 'pulled' or 'runtime' --
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

# The image is on GHCR, which needs a login even for a public package when
# pulled by tag from a private-by-default account. The token goes in on
# stdin: never in argv, never in the container log.
registry_login() {
    local registry token user
    registry="$(image_registry)"
    token="$(gh auth token 2>/dev/null || true)"
    user="$(gh api user --jq .login 2>/dev/null || true)"
    [ -n "$token" ] || return 0
    if printf '%s' "$token" \
            | ctr registry login "$registry" --username "${user:-token}" --password-stdin \
              >/dev/null 2>&1; then
        echo "Signed in to $registry as ${user:-the gh token}"
    else
        echo "Warning: 'docker login $registry' failed -- the pull may fail too" >&2
    fi
}

# One `docker pull`, keeping what it printed: with this registry the
# reason a pull was refused IS the diagnosis, so the caller reads PULL_OUT
# rather than guessing from the exit status.
PULL_OUT=""
try_pull() {
    local rc=0
    PULL_OUT="$(ctr image pull "$1" 2>&1)" || rc=$?
    return "$rc"
}

# Which image this folder is going to run, decided once per register or
# update. The prebuilt one when the token carries read:packages and GHCR
# hands it over; the public base image, installed into at first start,
# every other time. Both outcomes are a working folder, so this never
# fails -- there is nothing left for it to fail at.
acquire_image() {
    local dir="$1" ref="$2" scope_rc=0
    # The local backend runs no image at all, so there is nothing to log in
    # for, pull, or fall back from.
    if [ "$CTR_RUNTIME" = "local" ]; then
        echo "==> Local runtime: no image to acquire"
        record_image_source "$dir" pulled
        return 0
    fi
    # An image the daemon already holds is the whole answer: CI builds one
    # locally and points CLAUDE_ORCA_IMAGE at it, and so does anyone who has
    # the image but no working registry access. Consulting GHCR from there
    # can only fail and drop a perfectly good folder onto the slow runtime
    # path, so this returns before the scope check, the login and the pull.
    if [ -n "${CLAUDE_ORCA_IMAGE:-}" ] && ctr image inspect "$ref" >/dev/null 2>&1; then
        echo "==> Using the local image $ref (CLAUDE_ORCA_IMAGE)"
        record_image_source "$dir" pulled
        return 0
    fi
    # qa2.8: a classic token whose header lacks read:packages can only ever
    # be denied the manifest, so skip the login and the pull entirely rather
    # than make the user watch both fail. A token with no scopes header at
    # all (fine-grained PAT, App token) gets the one attempt: a refused pull
    # is handled below and costs a round trip, while skipping it costs a
    # 30-minute in-VM install every time.
    gh_has_scope read:packages || scope_rc=$?
    if [ "$scope_rc" -eq 0 ] || [ "$scope_rc" -eq 2 ]; then
        registry_login
        echo "==> Pulling $ref"
        if try_pull "$ref"; then
            record_image_source "$dir" pulled
            return 0
        fi
        # With this registry the reason a pull was refused IS the
        # diagnosis, so its own last line is what the user sees.
        printf '%s\n' "$PULL_OUT" | tail -1 >&2
    fi
    echo "$RUNTIME_INSTALL_NOTE"
    record_image_source "$dir" runtime
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
# How long to wait for that handshake, and the question that decides it:
# is this start going to INSTALL something? Not "which image is it" --
# that used to be the same question and no longer is. The image carries
# apt and nothing else now, so a folder whose toolchain cache is empty
# installs Orca, Claude Code and the rest on this start whether the image
# was pulled or not; a folder whose cache is full serves in seconds either
# way. Waiting 120 s on an install kills a folder that is working fine (a
# real Mac run on 2026-09-06 died at 2m12s mid-install).
#
# There are TWO halves that can be missing, and either one costs minutes:
#
#   the toolchain  <project>/.claude-dev/toolchain, filled on first start.
#                  Its Orca binary is the flag -- the last phase to land,
#                  so its absence means this start installs.
#   the apt half   baked into a prebuilt image. A folder on the runtime
#                  path (plain ubuntu:24.04, where a token without
#                  read:packages lands) reinstalls it on EVERY recreate,
#                  because dpkg state cannot live in a bind mount.
#
# So the short timeout needs both to be in hand. Measured the hard way on
# a Mac (2026-09-07): with only the toolchain checked, a runtime-path
# recreate got 120 s for a job that needs ~5 minutes of apt, and the
# launcher gave up on a container that was working fine.
toolchain_cached() {
    [ -x "$1/.claude-dev/toolchain/opt-Orca/orca-ide" ]
}

start_installs_nothing() {
    toolchain_cached "$1" && [ "$(image_source "$1")" != "runtime" ]
}

weburl_timeout() {
    local dir="$1"
    if [ -n "${CLAUDE_ORCA_WEBURL_TIMEOUT:-}" ]; then
        printf '%s\n' "$CLAUDE_ORCA_WEBURL_TIMEOUT"
    elif start_installs_nothing "$dir"; then
        printf '%s\n' "120"
    else
        printf '%s\n' "${CLAUDE_ORCA_WEBURL_TIMEOUT_RUNTIME:-1800}"
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
    if ! start_installs_nothing "$dir"; then runtime=1; fi
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

open_url() {
    local url="$1"
    if [ "${CLAUDE_ORCA_OPEN:-1}" = "0" ]; then
        return 0
    fi
    open "$url" || echo "Could not run 'open' -- paste this into a browser: $url" >&2
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

# --- the folder's toolchain cache ---------------------------------------
#
# The image carries the apt half of the install and nothing else (see
# setup.sh's IMAGE_PHASES). The other half -- Orca, Claude Code, opencode,
# bd, dolt, bats: ~1.2 GB of pinned payload -- is installed by the
# entrypoint on a folder's first start, into <project>/.claude-dev/
# toolchain, mounted here over the three paths those tools live at. So the
# container's filesystem after setup.sh is the same as when the image
# baked them, and `setup.sh --check` says so.
#
# In the folder rather than a docker volume because that is the half a
# person has to be able to look at: on a Mac it is `ls`, `du` and `rm -rf`
# away, and it goes when the folder goes. Measured on a real Mac
# (2026-09-07, Docker Desktop 29, 529 MB / 3620 files): copying the
# payload in costs 1.6 s against 0.5 s on the container filesystem, a
# metadata walk 172 ms against 5 ms, and launching the Orca binary about
# 70 ms more. Virtiofs is slower in ratio and irrelevant in seconds --
# against ~5 minutes of reinstalling the toolchain on every recreate.
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
    local dir="$1" name="$2" port="$3" ref src token cpus memory mount theme orkey dns
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
    mkdir -p "$dir/.claude-dev/run" "$dir/.claude-dev/home"
    # Never open a stale pairing URL from a previous container.
    rm -f "$dir/.claude-dev/run/orca-web-url.txt"

    # The toolchain cache, made before the run so docker mounts real
    # directories rather than creating root-owned ones of its own.
    for mount in $TOOLCHAIN_MOUNTS; do
        mkdir -p "$dir/.claude-dev/toolchain/${mount%%:*}"
    done

    set -- run -d --name "$name" \
        --volume "$dir:$dir" \
        --volume "$dir/.claude-dev/home:/home/agent" \
        --volume "$(state_volume "$name"):/home/agent/.config/orca" \
        -p "127.0.0.1:$port:$port" \
        -e "PROJECT_DIR=$dir" \
        -e "ORCA_PORT=$port" \
        -e "HOST_UID=$(id -u)" \
        -e "GH_TOKEN=$token" \
        -e "CLAUDE_ORCA_THEME=$theme" \
        -e "CLAUDE_ORCA_PROJECT_NAME=$(derive_project_name "$dir")" \
        -e "CLAUDE_ORCA_GIT_NAME=$(git_identity_name)" \
        -e "CLAUDE_ORCA_GIT_EMAIL=$(git_identity_email)"

    for mount in $TOOLCHAIN_MOUNTS; do
        set -- "$@" --volume \
            "$dir/.claude-dev/toolchain/${mount%%:*}:${mount#*:}"
    done

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
        set -- "$@" bash "$dir/.claude-dev/template/scripts/container/entrypoint.sh"
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

cmd_open_v3() {
    local dir="${1:-$PROJECT_SELF}" name port state url rc=0
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

    url="$(wait_for_web_url "$dir" "$name")" || rc=$?
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

    open_url "$url"
    print_run_it_block_v3 "$dir" "$url"
}

cmd_register_v3() {
    local dir="${1:-$PROJECT_SELF}" name port
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
        ctr exec -it --workdir "$dir" "$name" zsh -l
    else
        ctr exec --workdir "$dir" "$name" zsh -l
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
    local dir="$PROJECT_SELF" rc=0 ref name state port url_file src vol
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
            doctor_row missing "image" "$ref (pull it: ./claude-dev --update)"
            rc=2
        fi
    fi

    # pulled or runtime -- which one it is says whether this folder is
    # running the prebuilt image or installing its toolchain in the VM.
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

    return "$rc"
}

cmd_update_v3() {
    local dir="${1:-$PROJECT_SELF}" tmpl before after ref name state
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

    # The same decision as registration: an update whose pull works moves
    # the folder onto the fresh prebuilt image, and one whose pull cannot
    # moves it onto the base image and its runtime install.
    acquire_image "$dir" "$(image_ref)" || return 1

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

    rm -rf "$dir/.claude-dev"
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
  claude-dev logs               Follow the container's output
  claude-dev key openrouter     Store this folder's OpenRouter key (not
                                echoed) for the delegate routes
  claude-dev --how-to-run       Print the URL and the two commands
  claude-dev --doctor           CLI, service, image, container, port, web url
  claude-dev --update           Pull the template and the image, recreate
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
    logs)          shift; cmd_logs_v3 "${1:-$PROJECT_SELF}" || exit $?; exit 0 ;;
    key)           shift; cmd_key_v3 "$@" || exit $?; exit 0 ;;
    --how-to-run)  print_run_it_block_v3 "$PROJECT_SELF"; exit 0 ;;
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
