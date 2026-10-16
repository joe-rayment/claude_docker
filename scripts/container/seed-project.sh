#!/usr/bin/env bash
#
# seed-project.sh -- everything a project folder needs seeding, in one
# idempotent script: the .gitignore block, attachments/, the beads
# snapshot restore and `bd init`.
#
# WHY IT IS ITS OWN SCRIPT. This work used to live inside the entrypoint,
# which is PID 1 of the container. Anything in there is on the critical
# path of the boot, and a folder whose seeding misbehaves is a folder that
# will not start. It is also invisible -- it happens before there is a
# terminal to watch it in, and the only trace is a line in a log nobody
# reads until something is wrong.
#
# So it is a provision step now: provision.d/50-seed-project runs this
# script on every start, with its own run/provision log and status row,
# off the boot's critical path. It can also be run by hand from inside the
# project. A folder must never depend on a hook having fired to have a
# tracker in it, and nothing here waits on one.
#
# Everything here is idempotent and safe to run from any directory, as any
# user, any number of times. It never exits non-zero for a step it merely
# could not do: the caller is either a terminal a person is watching or a
# provision step, and neither should die over a seeding step.
#
# bash 3.2 clean.

set -uo pipefail

PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_ORCA_ROOT:-}}"
if [ -z "$PROJECT_DIR" ]; then
    # Run by hand from inside the project: walk up for the folder that
    # carries .claude-dev.
    d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -d "$d/.claude-dev" ]; then PROJECT_DIR="$d"; break; fi
        d="$(dirname "$d")"
    done
fi

log() { printf '[seed-project] %s\n' "$*"; }

if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
    log "no project directory (set PROJECT_DIR, or run this from inside one)"
    exit 0
fi

log "seeding $PROJECT_DIR"

# --- .gitignore ---------------------------------------------------------
#
# Only the missing lines, under one marker; nothing existing is touched.
seed_gitignore() {
    gitignore="$PROJECT_DIR/.gitignore"
    touch "$gitignore" 2>/dev/null || return 0
    if ! grep -qF "# claude_orca" "$gitignore" 2>/dev/null; then
        {
            echo ""
            echo "# claude_orca"
        } >> "$gitignore"
    fi
    # The last three are the skills artefacts an earlier template's
    # `skills install --local` step left in the project root -- ignored
    # exactly, so a folder that still carries them stays clean while a
    # user's own skills under .claude/skills/ stay visible to git.
    #
    # Nothing here names the Orca desktop app's files (Orca.app/, .orca/,
    # .orca-worktrees/, orca.yaml): this template no longer ships or runs
    # Orca, so it stops ADDING those lines. Lines already in a user's
    # .gitignore are never stripped.
    for pattern in '.claude-dev/' '.claude-dev-snapshots/' '/claude-dev' \
                   '.mcp.json' 'attachments/' '.claude/logs/' \
                   'graphify-out/' '__pycache__/' \
                   '.agents/skills/orchestration/' \
                   '.claude/skills/orchestration' 'skills-lock.json'; do
        grep -qxF "$pattern" "$gitignore" 2>/dev/null || echo "$pattern" >> "$gitignore"
    done
}

# --- where take-screenshot puts images ---------------------------------
seed_attachments() {
    mkdir -p "$PROJECT_DIR/attachments" 2>/dev/null || true
}

# --- beads --------------------------------------------------------------
#
# The snapshot restore first, because `bd init` must not clobber what a
# teardown put aside. Only ever when the project has no issues.jsonl of
# its own, so there is nothing here to lose.
restore_beads_snapshot() {
    snap_root="$PROJECT_DIR/.claude-dev-snapshots"
    [ -d "$snap_root" ] || return 0
    [ -f "$PROJECT_DIR/.beads/issues.jsonl" ] && return 0
    latest="$(ls -1 "$snap_root" 2>/dev/null | sort -r | head -1)"
    [ -n "$latest" ] || return 0
    [ -f "$snap_root/$latest/issues.jsonl" ] || return 0

    mkdir -p "$PROJECT_DIR/.beads" 2>/dev/null || return 0
    cp "$snap_root/$latest/issues.jsonl" "$PROJECT_DIR/.beads/issues.jsonl" 2>/dev/null || return 0
    if [ -f "$snap_root/$latest/metadata.json" ]; then
        cp "$snap_root/$latest/metadata.json" "$PROJECT_DIR/.beads/metadata.json" 2>/dev/null || true
    fi
    log "restored the beads snapshot $latest (the Dolt database rebuilds from the JSONL)"
}

init_beads() {
    # Honoured HERE, because this is where the tracker is created now.
    if [ "${CLAUDE_ORCA_SKIP_BEADS:-0}" = "1" ]; then
        log "CLAUDE_ORCA_SKIP_BEADS=1; not creating a tracker"
        return 0
    fi
    if ! command -v bd >/dev/null 2>&1; then
        log "bd is not on PATH; skipping the tracker"
        return 0
    fi
    if [ -e "$PROJECT_DIR/.beads" ]; then
        log "beads already initialized"
        return 0
    fi
    prefix="${CLAUDE_ORCA_PROJECT_NAME:-}"
    [ -n "$prefix" ] || prefix="$(basename "$PROJECT_DIR")"
    if ( cd "$PROJECT_DIR" && bd init --prefix "$prefix" ) >/dev/null 2>&1; then
        log "beads initialized (prefix $prefix)"
    else
        log "bd init did not succeed; run 'bd init' here when you want a tracker"
    fi
}

# The metrics banner is printed once per config and is the first thing a
# person sees from bd. Off by default in a folder this template made.
quiet_bd_metrics() {
    command -v bd >/dev/null 2>&1 || return 0
    bd metrics off >/dev/null 2>&1 || true
}

seed_gitignore
seed_attachments
restore_beads_snapshot
init_beads
quiet_bd_metrics

log "done"
exit 0
