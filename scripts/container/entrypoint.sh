#!/usr/bin/env bash
#
# entrypoint.sh -- PID 1's payload inside the claude_orca Linux VM (v3 S1,
# claude-orca-qa2.1; see .claude/plans/container-v3.md S3-S4; Orca left it
# in claude-orca-9bh.11 -- the plan is .claude/plans/ghostty.md). Runs under
# tini as root and brings the container's sshd up as the `agent` user: the
# Mac's Ghostty reaches the folder over ssh and nothing else listens.
#
# Sequence: resolve the project -> install the toolchain (root) -> re-map
# and drop to `agent` -> start the OpenRouter guard, which takes sole
# custody of the real key -> start the sshd SUPERVISOR (sshd-lib.sh's
# restart loop, logging to <project>/.claude-dev/run/sshd.log) and publish
# run/port -> run scripts/container/provision-run.sh -> wait on the
# supervisor, which is what keeps the container alive.
#
# The supervisor RETRIES, never dies: no authorized key yet, no sshd binary,
# an unwritable runtime dir, a checkout without sshd-lib.sh -- every refusal
# is logged (the first try, then once a minute) and tried again every five
# seconds, so PID 1 stays up, `docker exec` keeps working and `provision
# status` can name the fault. The moment the missing thing appears (the Mac
# side writes the keys), sshd comes up on the next try. SIGTERM/SIGINT stop
# sshd and exit 143.
#
# Everything that is about THIS FOLDER rather than about the image is in
# that provision-run.sh step and not in here (claude-orca-dbu.4): the
# config sync, the seeds, the tracker, the guard check. They are the steps
# most likely to fail, and in front of sshd they were in front of the only
# thing that could report a failure. Each one now writes
# run/provision/<step>.log and .status, none is fatal, and the next start
# re-runs all of them.
#
# Environment:
#   PROJECT_DIR   required; the bind-mounted project, same absolute path
#                 as on the Mac.
#   CLAUDE_ORCA_SSHD_PORT     sshd's port (default 2222); mirrored to
#                 run/port.
#   HOST_UID      the Mac uid owning the bind mount; `agent` is re-mapped
#                 to it so files written inside look right outside.
#   GH_TOKEN      passed through to the agent environment untouched.
#   CLAUDE_ORCA_PROJECT_NAME  the beads prefix for `bd init` (default:
#                 the project folder's basename).
#   CLAUDE_ORCA_SKIP_BEADS=1  do not `bd init` the project folder.
#   CLAUDE_ORCA_GIT_NAME / CLAUDE_ORCA_GIT_EMAIL   the Mac's global git
#                 identity, copied into the agent's ~/.gitconfig on a
#                 folder that has none. Optional; may be empty.
#   CLAUDE_ORCA_SETUP         the install script (default:
#                 <template root>/scripts/container/setup.sh).
#   CLAUDE_ORCA_SKIP_SETUP=1  do not run it.
#   CLAUDE_ORCA_DNS_FALLBACK  resolver to prepend to resolv.conf when the
#                 VM cannot resolve names (default 1.1.1.1); an empty
#                 string disables the repair.
#   CLAUDE_ORCA_RESOLV_CONF   the file that repair edits (default
#                 /etc/resolv.conf; tests point it elsewhere).
#   CLAUDE_ORCA_DNS_PROBE_HOST  the name whose resolution decides whether
#                 DNS works (default ports.ubuntu.com).
#   OPENROUTER_API_KEY        the REAL OpenRouter key, if the folder has
#                 one. It goes to the in-VM guard and nowhere else: sshd
#                 (and so every ssh session) gets the guard's token in
#                 this variable instead, plus OPENROUTER_BASE_URL.
#   CLAUDE_ORCA_GUARD_PORT    loopback port for the guard (4141).
#   CLAUDE_ORCA_GUARD_SCRIPT  the guard (default: the one next to this
#                 script).
#   CLAUDE_ORCA_GUARD_TIMEOUT seconds to wait for it to listen (30).
#   CLAUDE_ORCA_SSHD_BIN      the sshd to run (default /usr/sbin/sshd).
#   CLAUDE_ORCA_RUNTIME_DIR   where sshd's run-time files go (default
#                 /run/cdev; tests point it at a fixture).
#   CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1   skip usermod/setpriv (tests,
#                 and any run that is already unprivileged).
#   CLAUDE_ORCA_MANAGED_SETTINGS      where Claude Code's administrator
#                 policy file lives (default /etc/claude-code/managed-
#                 settings.json). Set, it is honoured whatever the uid --
#                 which is how the unprivileged test run reaches that step.
#
# bash 3.2 clean (scripts/lint-bash32.sh scans all of scripts/), even
# though the image ships bash 5.

set -uo pipefail

# Elapsed seconds on every line: the entrypoint's own steps (setup, the
# privilege drop, config-sync, the seeds, sshd) are the other half of a
# first start's timeline (recovery plan step 0.2).
log()  { printf '[entrypoint +%ss] %s\n' "$SECONDS" "$*"; }
warn() { printf '[entrypoint +%ss] %s\n' "$SECONDS" "$*" >&2; }
die()  { printf '[entrypoint +%ss] %s\n' "$SECONDS" "$*" >&2; exit 1; }

# Recursive chown for the agent, minus the unix sockets. `chown -R` over
# the bind-mounted folder home returns EINVAL on a socket -- an agent
# socket or a leftover ssh ControlPath one -- and once it hits one the rest
# of the tree keeps the wrong owner while the error goes to /dev/null.
# Skipping sockets is what makes the chown actually complete, and -h is
# what keeps a dangling symlink (a lock or cookie link outlives the
# container that made it) from being followed to a target that is not
# there. Best effort, like every chown on this side: never
# fatal, and the sockets themselves are left alone because something may
# still be using them.
chown_agent_tree() {
    find "$1" -xdev ! -type s -print0 2>/dev/null \
        | xargs -0 -r chown -h "$AGENT_UID:$AGENT_GID" 2>/dev/null || true
}

_resolve_script_path() {
    src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  src="$(case "$src" in (*/*) cd "${src%/*}/" ;; esac && pwd)/$link" ;;
        esac
    done
    printf '%s\n' "$src"
}
SCRIPT_DIR="$(_s="$(_resolve_script_path)"; case "$_s" in (*/*) cd "${_s%/*}/" ;; esac && pwd -P)"

# The container's sshd (claude-orca-9bh.6): config, env snapshot, host link
# and the restart loop live in sshd-lib.sh, which defines functions and does
# nothing at source time. A checkout that lacks it just boots without sshd.
[ -r "$SCRIPT_DIR/sshd-lib.sh" ] && . "$SCRIPT_DIR/sshd-lib.sh"

# The launcher's scratch volumes (claude-orca-1eh): docker volumes mounted
# under the agent home and named in CLAUDE_ORCA_VOLUME_DIRS (see
# volume-dirs.sh). Docker creates a fresh volume root-owned, and the agent
# cannot write into a root-owned home directory -- so hand each one to the
# agent's uid at boot, but only when the owner differs: a volume a previous
# boot already handed over (or one the launcher pre-owned) is not walked
# again. Best effort, like every chown on this side -- chown_agent_tree
# already skips sockets and dangling links, and a failure here leaves a
# readable warning, never a dead boot.
chown_volume_dirs() {
    . "$SCRIPT_DIR/volume-dirs.sh"
    local d owner
    while IFS= read -r d; do
        owner="$(stat -c %u "$d" 2>/dev/null)"
        if [ "$owner" != "$AGENT_UID" ]; then
            log "scratch volume $d is owned by uid ${owner:-unknown}, not $AGENT_UID; chowning to $AGENT_UID:$AGENT_GID"
            chown_agent_tree "$d"
        fi
    done < <(volume_dirs "$AGENT_HOME")
}

# A command given to the container runtime (after tini's `--`) wins over
# starting sshd: that is how CI runs smoke.sh in the built image, and how
# a person gets a shell in it without a running server.
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

# --- inputs -------------------------------------------------------------

PROJECT_DIR="${PROJECT_DIR:-}"
[ -n "$PROJECT_DIR" ] || die "PROJECT_DIR is required"
[ -d "$PROJECT_DIR" ] || die "PROJECT_DIR is not a directory: $PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"

AGENT_USER="${CLAUDE_ORCA_AGENT_USER:-agent}"
HOST_DIR="${CLAUDE_ORCA_HOST_DIR:-/opt/claude-orca-host}"

RUN_DIR="$PROJECT_DIR/.claude-dev/run"
PORT_FILE="$RUN_DIR/port"
SETUP_LOG="$RUN_DIR/setup.log"
PROVISION_DIR="$RUN_DIR/provision"
SETUP_STATUS_FILE="$PROVISION_DIR/setup.status"
mkdir -p "$RUN_DIR" "$PROVISION_DIR" "$PROJECT_DIR/.claude-dev/home"

# --- where the template is (startup v4, claude-orca-qa2.9) --------------
#
# The prebuilt image carries this repo at /opt/claude-orca. On a plain base
# image there is nothing there and the only copy is the folder's own clone,
# bind-mounted with the project -- which is also the copy this very script
# was read from. Everything template-shaped (setup.sh, config/) comes from
# the same root, so the two paths never mix.
#
# The baked copy loses the tiebreak: it is frozen at image build, while the
# folder's clone is what `--update` moves forward, so a folder that has
# already pulled a scripts/container/* fix into its own clone should not
# keep running the stale one baked months earlier. config-sync already
# prefers the folder's clone for config/ (see below) for the same reason --
# this makes setup.sh and seed-project.sh follow the same root instead of
# splitting template-shaped things across two.

if [ -x "$PROJECT_DIR/.claude-dev/template/scripts/container/setup.sh" ]; then
    TEMPLATE_ROOT="$PROJECT_DIR/.claude-dev/template"
elif [ -d /opt/claude-orca ]; then
    TEMPLATE_ROOT="/opt/claude-orca"
else
    TEMPLATE_ROOT="$PROJECT_DIR/.claude-dev/template"
fi
log "template root: $TEMPLATE_ROOT"

# --- make sure the VM can resolve names --------------------------------
#
# A real Mac run on 2026-09-06 booted the base image into a VM whose
# resolv.conf pointed at nothing that answered: apt printed "Temporary
# failure resolving 'ports.ubuntu.com'" for every line and setup.sh died on
# a package name instead. Nothing here needs DNS more than that install
# does, so the check runs first, and a VM that cannot resolve gets a public
# resolver prepended. Never fatal: the worst case is the install failing
# the way it would have anyway, now with a warning that says why.

DNS_FALLBACK="${CLAUDE_ORCA_DNS_FALLBACK-1.1.1.1}"
RESOLV_CONF="${CLAUDE_ORCA_RESOLV_CONF:-/etc/resolv.conf}"
DNS_PROBE_HOST="${CLAUDE_ORCA_DNS_PROBE_HOST:-ports.ubuntu.com}"

dns_resolves() {
    getent hosts "$1" >/dev/null 2>&1
}

ensure_dns() {
    if dns_resolves "$DNS_PROBE_HOST"; then
        return 0
    fi
    if [ -z "$DNS_FALLBACK" ]; then
        warn "cannot resolve $DNS_PROBE_HOST and CLAUDE_ORCA_DNS_FALLBACK is empty; not touching $RESOLV_CONF"
        return 1
    fi
    if [ "$(id -u)" != "0" ]; then
        warn "cannot resolve $DNS_PROBE_HOST, and only root may repair $RESOLV_CONF; leaving it alone"
        return 1
    fi
    if grep -qx "nameserver $DNS_FALLBACK" "$RESOLV_CONF" 2>/dev/null; then
        warn "cannot resolve $DNS_PROBE_HOST even with nameserver $DNS_FALLBACK in $RESOLV_CONF; the toolchain install is going to fail"
        return 1
    fi
    log "cannot resolve $DNS_PROBE_HOST; prepending nameserver $DNS_FALLBACK to $RESOLV_CONF"
    # Written in place with cat, never mv: the runtime bind-mounts
    # resolv.conf, and a rename over a mount point fails with EBUSY.
    resolv_tmp="$RESOLV_CONF.claude-orca.tmp"
    {
        printf 'nameserver %s\n' "$DNS_FALLBACK"
        cat "$RESOLV_CONF" 2>/dev/null
    } > "$resolv_tmp" || { rm -f "$resolv_tmp"; warn "could not write $resolv_tmp"; return 1; }
    if ! cat "$resolv_tmp" > "$RESOLV_CONF"; then
        rm -f "$resolv_tmp"
        warn "could not write $RESOLV_CONF; the toolchain install is going to fail"
        return 1
    fi
    rm -f "$resolv_tmp"
    if dns_resolves "$DNS_PROBE_HOST"; then
        log "DNS repaired: $DNS_PROBE_HOST resolves via $DNS_FALLBACK"
        return 0
    fi
    warn "still cannot resolve $DNS_PROBE_HOST after adding nameserver $DNS_FALLBACK; the toolchain install is going to fail"
    return 1
}

ensure_dns || true

# --- install the toolchain (startup v4, claude-orca-qa2.9) --------------
#
# setup.sh is what the Dockerfile used to RUN at build time. Running it at
# every start instead is what makes a plain ubuntu:24.04 a usable VM: on
# the prebuilt image every phase is already satisfied and this costs
# seconds, on a base image the first start installs everything. It runs
# before the privilege drop because the phases need root (setup.sh checks
# per phase itself, so an unprivileged run -- the native test run -- is
# still safe).

SETUP="${CLAUDE_ORCA_SETUP:-$TEMPLATE_ROOT/scripts/container/setup.sh}"
log "setup: $SETUP"

if [ "${CLAUDE_ORCA_SKIP_SETUP:-0}" = "1" ]; then
    log "CLAUDE_ORCA_SKIP_SETUP=1; skipping setup"
elif [ ! -x "$SETUP" ]; then
    log "no setup script at $SETUP; skipping setup"
else
    # --check installs nothing and needs no root: it is only here to decide
    # whether to warn that this start is going to take minutes.
    if ! "$SETUP" --check >/dev/null 2>&1; then
        log "First start: installing the toolchain inside the VM (several minutes; progress in .claude-dev/run/setup.log)"
    fi
    "$SETUP" 2>&1 | tee -a "$SETUP_LOG"
    setup_status="${PIPESTATUS[0]}"
    # The exit code lands on disk either way, so a later reader can tell
    # "ran fine" (0) from "failed" (non-zero) from "never ran" (no file).
    printf '%s\n' "$setup_status" > "$SETUP_STATUS_FILE"
    if [ "$setup_status" = "0" ]; then
        log "setup done (log: $SETUP_LOG)"
    else
        # NOT fatal (claude-orca-dbu.6). On the prebuilt image setup.sh is
        # a verification pass -- every phase already present -- so a
        # non-zero exit says something is wrong with the IMAGE, not that
        # there is nothing to run. Dying here would take the container
        # with it and leave nobody to report the problem: no sshd, no
        # terminal, no Claude Code. Record it, say so loudly, carry on.
        warn "setup.sh failed (exit $setup_status) -- see $SETUP_LOG"
        warn "continuing anyway: the VM comes up so the failure can be"
        warn "looked at from inside (status in $SETUP_STATUS_FILE)"
    fi
fi

# --- managed settings (claude-orca-8a0.3) -------------------------------
#
# /etc/claude-code/managed-settings.json is Claude Code's administrator
# policy file, and autoContinueAtUsageLimit is the one key this container
# needs there: a dispatched worker that hits a usage-limit window should
# wait it out and carry on rather than die mid-slice, taking its worktree
# and its half-finished commit with it. Only root can write /etc, so this
# runs BEFORE the privilege drop -- and skips silently when it is not root,
# which is every unprivileged run including the native test suite.
# CLAUDE_ORCA_MANAGED_SETTINGS overrides the path (tests point it at a
# temp file). An existing file is MERGED, never replaced: it is policy, and
# anything already there -- including an explicit false -- was meant.

MANAGED_SETTINGS="${CLAUDE_ORCA_MANAGED_SETTINGS:-}"
if [ -n "$MANAGED_SETTINGS" ] || [ "$(id -u)" = "0" ]; then
    [ -n "$MANAGED_SETTINGS" ] || MANAGED_SETTINGS=/etc/claude-code/managed-settings.json
    if ! command -v jq >/dev/null 2>&1; then
        warn "no jq; leaving $MANAGED_SETTINGS alone"
    elif mkdir -p "$(dirname "$MANAGED_SETTINGS")" 2>/dev/null; then
        if [ ! -f "$MANAGED_SETTINGS" ]; then
            if printf '{"autoContinueAtUsageLimit": true}\n' > "$MANAGED_SETTINGS" 2>/dev/null; then
                chmod 644 "$MANAGED_SETTINGS" 2>/dev/null || true
                log "managed settings: wrote autoContinueAtUsageLimit to $MANAGED_SETTINGS"
            else
                warn "cannot write $MANAGED_SETTINGS; skipping managed settings"
            fi
        elif ! jq -e . "$MANAGED_SETTINGS" >/dev/null 2>&1; then
            # Not JSON: an operator put something there by hand. Never
            # clobber it -- say so and move on.
            warn "$MANAGED_SETTINGS is not JSON; leaving it exactly as found"
        elif jq -e 'has("autoContinueAtUsageLimit")' "$MANAGED_SETTINGS" >/dev/null 2>&1; then
            log "managed settings: autoContinueAtUsageLimit already set in $MANAGED_SETTINGS"
        else
            managed_tmp="$MANAGED_SETTINGS.tmp.$$"
            if jq '. + {autoContinueAtUsageLimit: true}' "$MANAGED_SETTINGS" \
                    > "$managed_tmp" 2>/dev/null && [ -s "$managed_tmp" ]; then
                mv "$managed_tmp" "$MANAGED_SETTINGS"
                chmod 644 "$MANAGED_SETTINGS" 2>/dev/null || true
                log "managed settings: merged autoContinueAtUsageLimit into $MANAGED_SETTINGS"
            else
                rm -f "$managed_tmp" 2>/dev/null || true
                warn "could not merge autoContinueAtUsageLimit into $MANAGED_SETTINGS"
            fi
        fi
    else
        warn "cannot create $(dirname "$MANAGED_SETTINGS"); skipping managed settings"
    fi
fi

# --- who we run sshd as -------------------------------------------------
#
# Under tini we start as root: re-map `agent` to the Mac uid that owns the
# bind mount (so writes from inside look right from outside), then drop.
# Anywhere unprivileged -- the native test run, a run with `--user` --
# we stay put and keep the caller's own HOME.

PRIVDROP=0
AGENT_HOME="${HOME:-/root}"
AGENT_UID=""
AGENT_GID=""

if [ "${CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP:-0}" != "1" ] && [ "$(id -u)" = "0" ]; then
    if id "$AGENT_USER" >/dev/null 2>&1; then
        if [ -n "${HOST_UID:-}" ] && [ "$HOST_UID" != "$(id -u "$AGENT_USER")" ]; then
            log "re-mapping $AGENT_USER to host uid $HOST_UID"
            usermod -u "$HOST_UID" "$AGENT_USER" \
                || warn "usermod to $HOST_UID failed (continuing)"
        fi
        AGENT_UID="$(id -u "$AGENT_USER")"
        AGENT_GID="$(id -g "$AGENT_USER")"
        AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
        [ -n "$AGENT_HOME" ] || AGENT_HOME="/home/$AGENT_USER"
        mkdir -p "$AGENT_HOME"
        chown "$AGENT_UID:$AGENT_GID" "$AGENT_HOME" 2>/dev/null || true
        chown_agent_tree "$RUN_DIR"
        # The toolchain cache, when it is the folder's rather than the
        # image's. setup.sh installs it as root, and on Linux a bind mount
        # keeps that: root-owned files in <project>/.claude-dev/toolchain
        # that the person who owns the folder cannot delete, so
        # `./claude-dev --teardown` fails on 1.3 GB it cannot remove (CI
        # run 34150776165: "rm: cannot remove '.../opt-Orca/orca-ide':
        # Permission denied"). macOS hides this -- Docker Desktop maps
        # every write to the calling user -- which is exactly why it had to
        # be caught on Linux. Handing the cache to the host uid is what
        # keeps "the state dies with the folder" true on both.
        for toolchain_mount in /usr/local; do
            if mountpoint -q "$toolchain_mount" 2>/dev/null; then
                chown_agent_tree "$toolchain_mount"
            fi
        done
        PRIVDROP=1
    else
        warn "user $AGENT_USER not found; staying root"
    fi
fi

# The sshd's runtime dir (claude-orca-9bh.6): /run/cdev, off the bind mount,
# so the host key copy, the env snapshot and sshd_config never land in the
# project folder. Made here, while we may still be root; a failure is one log
# line -- start_sshd later sees an unwritable dir and skips sshd, the boot
# goes on. The Mac project path is linked to PROJECT_DIR in the same place
# (cdev_host_link is never fatal), but only when it can work: as root, or
# when a test points CLAUDE_ORCA_HOST_LINK_ROOT at a fixture.
SSHD_RUNTIME_DIR="${CLAUDE_ORCA_RUNTIME_DIR:-/run/cdev}"
SSHD_LOOP_PID=""
if declare -F cdev_sshd_loop >/dev/null 2>&1; then
    if [ -d "$SSHD_RUNTIME_DIR/ssh" ] || mkdir -p "$SSHD_RUNTIME_DIR/ssh" 2>/dev/null; then
        chmod 700 "$SSHD_RUNTIME_DIR/ssh" 2>/dev/null || true
        if [ "$PRIVDROP" = "1" ]; then
            chown "$AGENT_UID:$AGENT_GID" "$SSHD_RUNTIME_DIR" "$SSHD_RUNTIME_DIR/ssh" 2>/dev/null || true
        fi
    else
        log "sshd runtime dir $SSHD_RUNTIME_DIR is not creatable; sshd will not start"
    fi
    if [ -n "${CLAUDE_ORCA_HOST_PROJECT_DIR:-}" ] \
        && { [ "$(id -u)" = "0" ] || [ -n "${CLAUDE_ORCA_HOST_LINK_ROOT:-}" ]; }; then
        cdev_host_link "$CLAUDE_ORCA_HOST_PROJECT_DIR" "$PROJECT_DIR"
    fi
fi

# Every child process goes through one of these: the only place that
# knows whether to drop privileges, and the only place HOME is pinned.
run_as_agent() {
    if [ "$PRIVDROP" = "1" ]; then
        setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --init-groups -- \
            env HOME="$AGENT_HOME" "$@"
    else
        env HOME="$AGENT_HOME" "$@"
    fi
}

# The backgrounded variant. `&` on a function call forks a subshell, so
# without an explicit exec $! would be that subshell rather than the real
# process -- and the TERM trap would signal a shell instead of the server.
# setpriv and env both exec too, so the pid survives the whole chain.
agent_exec() {
    if [ "$PRIVDROP" = "1" ]; then
        exec setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --init-groups -- \
            env HOME="$AGENT_HOME" "$@"
    else
        exec env HOME="$AGENT_HOME" "$@"
    fi
}

export GH_TOKEN="${GH_TOKEN:-}"

# The scratch volumes are the agent's to write into, from the first boot
# that has them (claude-orca-1eh). Root phase: the agent could not chown a
# root-owned volume itself.
if [ "$PRIVDROP" = "1" ]; then
    chown_volume_dirs
fi

# --- early config sync (claude-orca-0jn) --------------------------------
#
# (a) WHY: settings.json's statusLine key is written only by config-sync,
# and config-sync used to run exclusively from provision.d, AFTER sshd
# is up and the Mac side's terminal pane has connected. Claude Code reads
# statusLine once, at process start, and never catches up mid-session -- so
# a session opened against a first-ever boot could read a settings.json
# that did not exist yet, or existed without statusLine, and would carry
# that gap for its entire life. Running the sync once here, before sshd
# is even started, closes that window.
#
# (b) WHY NOT FATAL: provision.d/20-config-sync (checksum-gated, so this
# is a no-op on its second call within the same boot) still runs on the
# normal schedule after sshd is up, and is still the retry path. A failure
# here changes nothing about claude-orca-dbu.4's anti-silent-failure
# property -- no exit, no die, and the folder still gets a logged,
# retried attempt exactly as before this existed. It is a pure improvement
# to how soon the FIRST attempt happens, never the last one.
#
# (c) WHY TIMED: this is local file I/O against a template that is already
# on disk -- near-instant in the success case -- so it is bounded rather
# than trusted, the same way every other step here is: a hang must not
# delay sshd past a bounded window, whatever caused it.
#
# The three-way fallback is copied verbatim from provision.d/20-config-sync
# (do not let the two drift): the folder's own template clone wins when it
# carries a config/, then TEMPLATE_ROOT's parent when TEMPLATE_ROOT itself
# is named "template", then the image's baked copy under HOST_DIR.
early_sync_host=""
if [ -d "$PROJECT_DIR/.claude-dev/template/config" ]; then
    early_sync_host="$PROJECT_DIR/.claude-dev"
elif [ "$(basename "$TEMPLATE_ROOT")" = "template" ] && [ -d "$TEMPLATE_ROOT/config" ]; then
    early_sync_host="$(dirname "$TEMPLATE_ROOT")"
elif [ -d "$HOST_DIR/template/config" ]; then
    early_sync_host="$HOST_DIR"
fi

if [ -z "$early_sync_host" ]; then
    warn "early config sync: no template config found (looked in $PROJECT_DIR/.claude-dev/template, $TEMPLATE_ROOT, $HOST_DIR); skipping -- provision.d/20-config-sync will retry once sshd is up"
else
    early_sync_timeout="${CLAUDE_ORCA_EARLY_SYNC_TIMEOUT:-30}"
    if command -v timeout >/dev/null 2>&1; then
        run_as_agent timeout "$early_sync_timeout" bash "$SCRIPT_DIR/../config-sync.sh" \
            --project "$PROJECT_DIR" --host "$early_sync_host"
    else
        run_as_agent bash "$SCRIPT_DIR/../config-sync.sh" \
            --project "$PROJECT_DIR" --host "$early_sync_host"
    fi
    early_sync_rc=$?
    if [ "$early_sync_rc" = "0" ]; then
        log "early config sync from $early_sync_host/template/config: ok"
    else
        warn "early config sync from $early_sync_host/template/config failed (exit $early_sync_rc); provision.d/20-config-sync will retry once sshd is up"
    fi
fi

# --- what used to be here (claude-orca-dbu.4) ---------------------------
#
# The config sync, the git identity, the Claude Code first-run seed and the
# project seed (.gitignore, attachments/, the beads snapshot, `bd init`)
# all ran on this line, between the privilege drop and the server.
# Every one of them is about THIS FOLDER rather than about the image, and
# every one of them is a way for a folder to fail to start in silence.
# They are provision.d steps now -- see run_provision below, and
# scripts/container/provision-run.sh for why the order changed.

# --- the OpenRouter guard (claude-orca-qa2.21) --------------------------
#
# The user's rule is that a request is only ever served in the US, Canada
# or Europe -- the model may be Chinese, the host may not be -- and the only
# thing that can enforce it is a chokepoint no client can edit: the guard
# (scripts/container/openrouter-guard.py + config/provider-policy.json,
# claude-orca-qa2.20) holds the real OPENROUTER_API_KEY alone and forces
# provider.only/allow_fallbacks=false/data_collection=deny onto every
# completion request. It therefore starts HERE, before sshd, and what sshd
# -- and so every ssh session it opens -- inherits is the token and the
# guard's loopback base URL, never the key.
#
# Fail closed on the KEY, not on the boot: a guard that will not start
# leaves the VM without OpenRouter rather than with an unpoliced key in
# every terminal.

GUARD_PORT="${CLAUDE_ORCA_GUARD_PORT:-4141}"
GUARD_SCRIPT="${CLAUDE_ORCA_GUARD_SCRIPT:-$SCRIPT_DIR/openrouter-guard.py}"
GUARD_TIMEOUT="${CLAUDE_ORCA_GUARD_TIMEOUT:-30}"
GUARD_LOG="$RUN_DIR/openrouter-guard.log"
GUARD_PID_FILE="$RUN_DIR/openrouter-guard.pid"
GUARD_TOKEN_FILE="$RUN_DIR/openrouter-guard.token"
# How the real key gets to the guard, and to the guard step, without ever
# being an argument or an environment variable (claude-orca-qa2.25). Both
# readers unlink the file as soon as they have read it, so the key is on
# disk for a startup rather than in /proc/<pid>/environ for an uptime.
GUARD_KEY_FILE="$RUN_DIR/openrouter-guard.key"
PROVISION_KEY_FILE="$RUN_DIR/provision-openrouter.key"
# The folder's own durable key (claude-orca-376): $AGENT_HOME IS
# .claude-dev/home -- same device, same inode -- so the file
# `claude-dev key openrouter` writes on the Mac is already readable here.
# Unlike GUARD_KEY_FILE/PROVISION_KEY_FILE this one is never unlinked; it
# is the folder's key, not a one-shot handoff.
OPENROUTER_KEY_FILE="${CLAUDE_ORCA_OPENROUTER_KEY_FILE:-$AGENT_HOME/.openrouter.key}"
# The third and last source (claude-orca-b30): 'opencode auth login
# openrouter' already writes the real key to opencode's own auth store.
# Read fresh on every boot and never mirrored to OPENROUTER_KEY_FILE -- a
# cached copy would go stale the moment the user logs in again.
OPENCODE_AUTH_FILE="${CLAUDE_ORCA_OPENCODE_AUTH:-${XDG_DATA_HOME:-$AGENT_HOME/.local/share}/opencode/auth.json}"
GUARD_BASE_URL="http://127.0.0.1:$GUARD_PORT/api/v1"
GUARD_PID=""
GUARD_TOKEN=""

guard_port_open() {
    python3 -c "import socket,sys
s = socket.socket()
s.settimeout(0.3)
sys.exit(0 if s.connect_ex(('127.0.0.1', $GUARD_PORT)) == 0 else 1)" \
        >/dev/null 2>&1
}

# Stable across restarts: a session that outlives one start (a tmux pane, a
# long-running agent) keeps the token it was given, so a fresh random token
# on every start would leave it pointing at a credential the guard no
# longer accepts.
# Mode 600 before a byte is in it, and the agent's, because the agent is who
# reads it. Same uid as every terminal here, so the permission bits are not
# what makes this safer than an environment variable -- the unlink is.
write_key_file() {  # write_key_file <path> <key>
    rm -f "$1"
    ( umask 077; printf '%s\n' "$2" > "$1" ) || return 1
    chmod 600 "$1" 2>/dev/null
    [ "$PRIVDROP" = "1" ] && chown "$AGENT_UID:$AGENT_GID" "$1" 2>/dev/null
    return 0
}

# Read-only: nothing here writes, chmods, moves or unlinks the auth store.
# jq missing, the file absent, malformed JSON, no '.openrouter', an empty
# '.key', or a '.type' other than "api" all degrade quietly to the caller's
# existing no-key path -- none of them is an error, none aborts the boot.
opencode_auth_key() {
    local auth_type auth_key
    command -v jq >/dev/null 2>&1 || return 1
    [ -f "$OPENCODE_AUTH_FILE" ] || return 1
    auth_type="$(jq -r '.openrouter.type // empty' "$OPENCODE_AUTH_FILE" 2>/dev/null)" || return 1
    [ "$auth_type" = "api" ] || return 1
    auth_key="$(jq -r '.openrouter.key // empty' "$OPENCODE_AUTH_FILE" 2>/dev/null)" || return 1
    [ -n "$auth_key" ] || return 1
    printf '%s\n' "$auth_key"
}

guard_token() {
    if [ -s "$GUARD_TOKEN_FILE" ]; then
        head -1 "$GUARD_TOKEN_FILE" | tr -d '\r\n'
        return 0
    fi
    od -An -tx1 -N24 /dev/urandom 2>/dev/null | tr -d ' \n'
}

start_openrouter_guard() {
    if [ ! -f "$GUARD_SCRIPT" ]; then
        warn "no OpenRouter guard script at $GUARD_SCRIPT"
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        warn "python3 not found; cannot run the OpenRouter guard"
        return 1
    fi
    rm -f "$GUARD_PID_FILE"
    : > "$GUARD_LOG"
    [ "$PRIVDROP" = "1" ] && chown "$AGENT_UID:$AGENT_GID" "$GUARD_LOG" 2>/dev/null

    if ! write_key_file "$GUARD_KEY_FILE" "$OPENROUTER_REAL_KEY"; then
        warn "could not write the guard key file $GUARD_KEY_FILE"
        return 1
    fi

    # agent_exec, not run_as_agent: the exec chain keeps $! the guard's own
    # pid rather than a wrapper subshell's. The key goes over the file and
    # `env -u` is not belt and braces: the guard's own os.environ scrub
    # cannot rewrite /proc/<pid>/environ, which the kernel fixes at exec, so
    # the only way the key is not there is for it never to have been.
    agent_exec env -u OPENROUTER_API_KEY \
        OPENROUTER_GUARD_TOKEN="$GUARD_TOKEN" \
        CLAUDE_ORCA_RUN_DIR="$RUN_DIR" \
        CLAUDE_ORCA_GUARD_KEY_FILE="$GUARD_KEY_FILE" \
        python3 "$GUARD_SCRIPT" --port "$GUARD_PORT" --run-dir "$RUN_DIR" \
        >>"$GUARD_LOG" 2>&1 &
    GUARD_PID=$!

    guard_waited=0
    while [ "$guard_waited" -lt "$GUARD_TIMEOUT" ]; do
        if guard_port_open; then
            printf '%s\n' "$GUARD_PID" > "$GUARD_PID_FILE"
            if [ "$PRIVDROP" = "1" ]; then
                chown "$AGENT_UID:$AGENT_GID" "$GUARD_PID_FILE" \
                    "$GUARD_TOKEN_FILE" 2>/dev/null
            fi
            return 0
        fi
        kill -0 "$GUARD_PID" 2>/dev/null || break
        sleep 1
        guard_waited=$((guard_waited + 1))
    done
    kill -TERM "$GUARD_PID" 2>/dev/null
    GUARD_PID=""
    # It never read it, or it died before it could: the file does not
    # outlive the attempt.
    rm -f "$GUARD_KEY_FILE"
    return 1
}

OPENROUTER_REAL_KEY="${OPENROUTER_API_KEY:-}"
if [ -z "$OPENROUTER_REAL_KEY" ] && [ -s "$OPENROUTER_KEY_FILE" ]; then
    OPENROUTER_REAL_KEY="$(head -1 "$OPENROUTER_KEY_FILE" | tr -d '\r\n')"
fi
if [ -z "$OPENROUTER_REAL_KEY" ]; then
    OPENROUTER_REAL_KEY="$(opencode_auth_key || true)"
fi
if [ -n "$OPENROUTER_REAL_KEY" ]; then
    GUARD_TOKEN="$(guard_token)"
    # From this line on the real key exists only in the guard's own
    # environment: nothing downstream inherits it.
    unset OPENROUTER_API_KEY
    unset OPENROUTER_BASE_URL
    if [ -n "$GUARD_TOKEN" ] && start_openrouter_guard; then
        export OPENROUTER_API_KEY="$GUARD_TOKEN"
        export OPENROUTER_BASE_URL="$GUARD_BASE_URL"
        log "OpenRouter guard listening on $GUARD_BASE_URL (pid $GUARD_PID, log: $GUARD_LOG); agents get its token, never the key"
    else
        warn "the OpenRouter guard did not start -- the real OPENROUTER_API_KEY is NOT being passed to sshd (see $GUARD_LOG). Agents have no OpenRouter access this run; that is deliberate, because an unpoliced key in a terminal is exactly what the guard exists to prevent."
    fi
else
    log "no OPENROUTER_API_KEY; not starting the OpenRouter guard"
fi

# --- the container's sshd (claude-orca-9bh.6, .11) ----------------------
#
# sshd is the one long-running child of this script, and PID 1 never dies
# for lack of it: start_sshd forks a SUPERVISOR that tries to bring sshd up
# and, on ANY refusal, logs the reason (the first try, then once a minute)
# and tries again five seconds later. The refusals are: sshd-lib.sh absent,
# no host/authorized keys in state/ssh yet (the Mac side writes them on its
# next ./claude-dev), an unwritable runtime dir, no sshd binary, files that
# cannot be staged. The block runs after the guard block on purpose -- the
# env snapshot ssh panes inherit is taken when sshd STARTS, so it holds the
# guard's token, never the real OpenRouter key (the library also drops any
# value that looks like one). sshd.ready is the Mac side's signal; it
# exists only while sshd answers, so it is removed first on every boot.

# Stops the restart loop sshd runs under: the supervisor's own child when
# called inside the supervisor, the supervisor itself when called by the
# main shell. Waits at most 2 s, so the whole teardown stays under 5 s.
stop_sshd_loop() {
    local pid="${SSHD_LOOP_PID:-}" i
    [ -n "$pid" ] || return 0
    kill -TERM "$pid" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    SSHD_LOOP_PID=""
    return 0
}

# One attempt. Returns 0 with the restart loop running in the background
# (SSHD_LOOP_PID is its pid), or 1 with the reason in SSHD_REFUSAL.
try_start_sshd() {
    local sshlog="$RUN_DIR/sshd.log" ssh_state="$PROJECT_DIR/.claude-dev/state/ssh"
    local rt="$SSHD_RUNTIME_DIR" port="${CLAUDE_ORCA_SSHD_PORT:-2222}" bin allow fpr k
    if ! declare -F cdev_sshd_loop >/dev/null 2>&1; then
        SSHD_REFUSAL="sshd-lib.sh is not in $SCRIPT_DIR; sshd cannot start"
        return 1
    fi
    if [ ! -s "$ssh_state/host_ed25519" ] || [ ! -s "$ssh_state/host_ed25519.pub" ] \
        || [ ! -s "$ssh_state/authorized_keys" ]; then
        SSHD_REFUSAL="no ssh keys in state/ssh yet -- the Mac side creates them on the next ./claude-dev"
        return 1
    fi
    bin="${CLAUDE_ORCA_SSHD_BIN:-$(command -v sshd || echo /usr/sbin/sshd)}"
    if [ ! -d "$rt/ssh" ] || [ ! -w "$rt/ssh" ]; then
        SSHD_REFUSAL="sshd runtime dir $rt/ssh is not writable; sshd not started"
        return 1
    fi
    if [ ! -x "$bin" ]; then
        SSHD_REFUSAL="no executable sshd at $bin; sshd not started"
        return 1
    fi
    if [ "$PRIVDROP" = "1" ]; then allow="$AGENT_USER"; else allow="$(id -un)"; fi
    (
        umask 077
        cp "$ssh_state/host_ed25519" "$rt/ssh/host_ed25519" \
            && cp "$ssh_state/host_ed25519.pub" "$rt/ssh/host_ed25519.pub" \
            && cdev_env_snapshot "$rt/env" \
            && cdev_sshd_config "$rt" "$PROJECT_DIR" "$port" "$allow" \
                "$SCRIPT_DIR/pane-entry" > "$rt/sshd_config"
    ) 2>>"$sshlog" || {
        SSHD_REFUSAL="could not stage the sshd files under $rt (see $sshlog)"
        return 1
    }
    for k in ssh/host_ed25519 ssh/host_ed25519.pub env sshd_config; do
        chmod 600 "$rt/$k" 2>/dev/null
        [ "$PRIVDROP" = "1" ] && chown "$AGENT_UID:$AGENT_GID" "$rt/$k" 2>/dev/null
    done
    fpr="$(cdev_host_key_fpr "$rt/ssh/host_ed25519.pub")"
    if [ -z "$fpr" ]; then
        SSHD_REFUSAL="could not fingerprint the ssh host key; sshd not started"
        return 1
    fi
    if [ "$PRIVDROP" = "1" ]; then
        cdev_sshd_loop "$bin" "$rt/sshd_config" "$sshlog" "$RUN_DIR/sshd.ready" "$port" "$fpr" agent_exec &
    else
        cdev_sshd_loop "$bin" "$rt/sshd_config" "$sshlog" "$RUN_DIR/sshd.ready" "$port" "$fpr" &
    fi
    SSHD_LOOP_PID=$!
    return 0
}

# The supervisor body, run in a background subshell by start_sshd. TERM/INT
# stop the sleeper and the restart loop, then exit 0.
sshd_supervisor() {
    local sshlog="$RUN_DIR/sshd.log" tries=0 rc sleeper=""
    trap '[ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null; stop_sshd_loop; exit 0' TERM INT
    while :; do
        if try_start_sshd; then
            tries=0
            log "sshd restart loop started (pid $SSHD_LOOP_PID, port ${CLAUDE_ORCA_SSHD_PORT:-2222}, log: $sshlog)"
            rc=0; wait "$SSHD_LOOP_PID" || rc=$?
            SSHD_LOOP_PID=""
            rm -f "$RUN_DIR/sshd.ready"
            echo "sshd-supervisor: the restart loop exited rc=$rc; starting it again" >> "$sshlog"
        else
            # The first refusal and then one a minute (every 12th try at 5 s).
            if [ $((tries % 12)) -eq 0 ]; then
                echo "$SSHD_REFUSAL" >> "$sshlog"
                log "$SSHD_REFUSAL; trying again every 5 s"
            fi
            tries=$((tries + 1))
        fi
        sleep 5 &
        sleeper=$!
        wait "$sleeper" 2>/dev/null
        sleeper=""
    done
}

SSHD_REFUSAL=""
start_sshd() {
    local sshlog="$RUN_DIR/sshd.log"
    rm -f "$RUN_DIR/sshd.ready"
    : > "$sshlog"
    [ "$PRIVDROP" = "1" ] && chown "$AGENT_UID:$AGENT_GID" "$sshlog" 2>/dev/null
    sshd_supervisor &
    SSHD_LOOP_PID=$!
    log "sshd supervisor started (pid $SSHD_LOOP_PID)"
}

# SIGTERM (docker stop) and SIGINT: take sshd down, then the guard, and
# leave with the conventional 143. The EXIT trap covers every plain exit.
stop_all() {
    stop_sshd_loop
    [ -n "${GUARD_PID:-}" ] && kill -TERM "$GUARD_PID" 2>/dev/null
    return 0
}
trap 'stop_all; exit 143' TERM INT
trap stop_sshd_loop EXIT

start_sshd

# What the Mac side and the doctor read to know which port to dial. The
# launcher deletes run/port before every start, so it is written now, not
# when sshd happens to come up.
printf '%s\n' "${CLAUDE_ORCA_SSHD_PORT:-2222}" > "$PORT_FILE"
if [ "$PRIVDROP" = "1" ]; then
    chown "$AGENT_UID:$AGENT_GID" "$PORT_FILE" 2>/dev/null
fi

# --- provisioning this folder (claude-orca-dbu.4) -----------------------
#
# Everything project-shaped, from scripts/container/provision-run.sh: one
# numbered, idempotent step per thing a folder needs, each with its own
# log and status under run/provision, none of them fatal. It is called on
# one path -- right after the sshd supervisor is started (sshd is up or
# retrying) -- and it runs once. beads is one of those steps now
# (50-seed-project); CLAUDE_ORCA_SKIP_BEADS is still honoured, by that
# script.
#
# It runs in the FOREGROUND, and that costs nothing a person can see: the
# supervisor is already running, so a person can ssh in the moment sshd
# answers. Every step is bounded by
# CLAUDE_ORCA_PROVISION_TIMEOUT, so the `wait` below is never more than a
# few minutes away even when a step hangs.

PROVISION_RAN=0
run_provision() {
    [ "$PROVISION_RAN" = "0" ] || return 0
    PROVISION_RAN=1

    if [ "${CLAUDE_ORCA_SKIP_PROVISION:-0}" = "1" ]; then
        log "CLAUDE_ORCA_SKIP_PROVISION=1; skipping provisioning"
        return 0
    fi

    provision_runner="$TEMPLATE_ROOT/scripts/container/provision-run.sh"
    [ -f "$provision_runner" ] || provision_runner="$SCRIPT_DIR/provision-run.sh"
    if [ ! -f "$provision_runner" ]; then
        warn "no provision-run.sh in $TEMPLATE_ROOT or $SCRIPT_DIR; this folder is unprovisioned"
        return 0
    fi

    # The steps run as the agent, so what they write is already the agent's.
    # These two are what a PREVIOUS start may have left root-owned.
    if [ "$PRIVDROP" = "1" ]; then
        chown_agent_tree "$PROVISION_DIR"
        [ -d "$PROJECT_DIR/.beads" ] && chown_agent_tree "$PROJECT_DIR/.beads"
    fi

    # The real key is handed to the runner, which strips it from the
    # environment every step but the guard's inherits. It travels by file
    # rather than by variable: `run_as_agent env VAR=<key> ...` would put it
    # in the runner's argv AND its /proc/<pid>/environ, both readable by
    # every agent terminal, for as long as provisioning takes.
    provision_key_arg=""
    if [ -n "${OPENROUTER_REAL_KEY:-}" ] \
        && write_key_file "$PROVISION_KEY_FILE" "$OPENROUTER_REAL_KEY"; then
        provision_key_arg="CLAUDE_ORCA_OPENROUTER_KEY_FILE=$PROVISION_KEY_FILE"
    fi
    run_as_agent env PROJECT_DIR="$PROJECT_DIR" \
        TEMPLATE_ROOT="$TEMPLATE_ROOT" \
        ${provision_key_arg:+"$provision_key_arg"} \
        bash "$provision_runner"
    # The runner unlinks it the moment it has read it; this is the case
    # where it never ran at all.
    rm -f "$PROVISION_KEY_FILE"
    return 0
}

# --- everything about this folder, now that it can be watched -----------

run_provision

# --- the container lives as long as sshd is supervised ------------------
#
# The supervisor only ends on SIGTERM/SIGINT (the trap above exits 143
# first); if it is ever gone anyway, so is the reason to keep PID 1.

log "waiting on the sshd supervisor (pid $SSHD_LOOP_PID)"
wait "$SSHD_LOOP_PID"
status=$?
log "the sshd supervisor exited with status $status"
exit "$status"
