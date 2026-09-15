#!/usr/bin/env bash
#
# seed-project.sh -- everything a project folder needs seeding, in one
# idempotent script with TWO callers and no privileged step.
#
# WHY IT IS ITS OWN SCRIPT. This work used to live inside the entrypoint,
# which is PID 1 of the container: the same process that has to bring Orca
# up. Anything in there is on the critical path of the boot, and a folder
# whose seeding misbehaves is a folder that will not start. It is also
# invisible -- it happens before there is a terminal to watch it in, and
# the only trace is a line in a log nobody reads until something is wrong.
#
# Orca already has the right home for this: `scripts.setup` in the repo's
# own `orca.yaml`, which Orca runs in a terminal pane when a workspace is
# created (its own words: "setup script runs when a new workspace is
# created"). That is committed with the project, shared with the team,
# editable without rebuilding an image, and visible while it runs.
#
# So this script is the single body, and both callers run it:
#
#   1. Orca, through `scripts.setup` in <project>/orca.yaml.
#   2. The entrypoint, best-effort, as the FLOOR -- because a folder must
#      never depend on a hook having fired to have a tracker in it. On
#      2026-09-08 Orca's setup script could not be made to fire from the
#      CLI at all (three attempts, `--setup run`, before and after a
#      runtime restart, with orca.yaml confirmed parsed by `orca vm recipe
#      doctor`); it appears to be adopted through the app. Staking a
#      folder's beads database on a path that could not be verified would
#      be trading one point of failure for a less honest one.
#
# Everything here is idempotent and safe to run from any directory, as any
# user, any number of times. It never exits non-zero for a step it merely
# could not do: the caller is either a terminal a person is watching or
# PID 1 of the container, and neither should die over a seeding step.
#
# bash 3.2 clean.

set -uo pipefail

PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_ORCA_ROOT:-}}"
if [ -z "$PROJECT_DIR" ]; then
    # Run by hand from inside the project, most likely from an Orca
    # terminal: walk up for the folder that carries .claude-dev.
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
    for pattern in '.claude-dev/' '.claude-dev-snapshots/' '/claude-dev' \
                   'Orca.app/' '.mcp.json' 'attachments/' '.claude/logs/'; do
        grep -qxF "$pattern" "$gitignore" 2>/dev/null || echo "$pattern" >> "$gitignore"
    done
}

# --- where take-screenshot puts images ---------------------------------
seed_attachments() {
    mkdir -p "$PROJECT_DIR/attachments" 2>/dev/null || true
}

# --- orca.yaml ----------------------------------------------------------
#
# The file this project's own Orca config lives in. Seeded only when the
# project has none: a folder that already carries one belongs to whoever
# wrote it, and this must never overwrite a team's own config.
#
# claude-orca-8jb: this used to also seed a `scripts.setup` key that made
# Orca run this same script AGAIN, visibly, in a terminal on every
# workspace creation -- a second tab, for work provision.d/50-seed-project
# already does invisibly with its own log and status row. Comment-only,
# now: no scripts:, no setup:.
#
# PREVIOUSLY_SEEDED_ORCA_YAML is that old content, byte for byte, kept
# only so a folder that already carries it (seeded before this change)
# can be migrated: replaced with the new comment-only content, but ONLY
# on an exact byte match. Anything else -- a user's own setup script, our
# old content plus their edits, any differing byte -- is left completely
# alone. This is the whole safety rule: no YAML parsing, no partial edit,
# no pattern match.
PREVIOUSLY_SEEDED_ORCA_YAML="$(cat <<'EOF'
# Orca reads this file from the repo root. `scripts.setup` runs in a
# terminal when a workspace is created, so the work below is watchable and
# is not on the critical path of the container's boot.
#
# Seeded by claude_orca on this folder's first start, and yours from here
# on -- nothing rewrites it. The script it calls is idempotent.
scripts:
  setup: bash /opt/claude-orca/scripts/container/seed-project.sh 2>/dev/null || bash .claude-dev/template/scripts/container/seed-project.sh
EOF
)"

seed_orca_yaml() {
    yaml="$PROJECT_DIR/orca.yaml"
    new_content="$(cat <<'EOF'
# This is this project's own Orca config (https://orca.dev), read from
# the repo root. It is yours to edit -- nothing here rewrites it once it
# exists.
#
# A `scripts.setup` key here makes Orca open a terminal running it every
# time a workspace is created. This project's own seeding already runs,
# invisibly, during container provisioning (see run/provision/ inside the
# container) -- adding scripts.setup here to watch that work again means
# an extra terminal tab on every workspace, for no additional work done.
EOF
)"
    # $(...) strips trailing newlines on both sides of this comparison
    # (the heredoc above and the file read below), so a byte-for-byte
    # match here means a byte-for-byte match once the trailing newline is
    # restored by printf '%s\n' on write.
    # A symlink is left entirely alone, before anything reads or writes
    # it: `[ -e ]`, `cat` and `>` all resolve a link, so without this the
    # migration below would rewrite whatever the link points AT, outside
    # the project (claude-orca-bbd). A folder's tooling touches that
    # folder. Someone pointing orca.yaml at a shared config keeps it.
    if [ -L "$yaml" ]; then
        log "$yaml is a symlink; left alone"
        return 0
    fi
    if [ ! -e "$yaml" ]; then
        printf '%s\n' "$new_content" > "$yaml" 2>/dev/null || return 0
        log "seeded $yaml (comment-only; no scripts.setup)"
        return 0
    fi
    if [ "$(cat "$yaml" 2>/dev/null)" = "$PREVIOUSLY_SEEDED_ORCA_YAML" ]; then
        printf '%s\n' "$new_content" > "$yaml" 2>/dev/null || return 0
        log "migrated $yaml (dropped the scripts.setup this template used to seed)"
        return 0
    fi
    log "$yaml already exists; left alone"
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
seed_orca_yaml
restore_beads_snapshot
init_beads
quiet_bd_metrics

log "done"
exit 0
