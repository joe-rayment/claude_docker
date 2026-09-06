#!/usr/bin/env bash
#
# seed-orca-state.sh -- give a fresh project folder an Orca that already
# knows about it (v3 S4, claude-orca-qa2.5; .claude/plans/container-v3.md
# S3). Run by the entrypoint as the `agent` user, once, BEFORE serve
# starts.
#
# What it writes and why:
#   repos[0].worktreeBasePath  <project>/.orca-worktrees -- worktrees stay
#                              inside the bind mount, so they exist on the
#                              Mac too instead of vanishing with the VM.
#                              This key is PER-REPO, not a global setting,
#                              and `orca repo add` has no flag for it --
#                              pre-seeding the record is the only way in.
#                              projects[] stays empty on purpose: Orca
#                              derives the project row from repos[] on
#                              load, and `orca repo add` later finds the
#                              seeded record by path instead of adding a
#                              second one.
#   settings.theme             dark by default (claude-orca.json `theme`
#                              rides in as CLAUDE_ORCA_THEME).
#   settings.agentDefaultEnv   CLAUDE_ORCA_ROOT=<project>, so an agent Orca
#                              launches can find the folder root. This map
#                              is keyed BY AGENT ID first
#                              (agentDefaultEnv.claude.CLAUDE_ORCA_ROOT); a
#                              flat KEY:value map is silently dropped by
#                              normalizeTuiAgentEnvRecord. Orca merges its
#                              own defaults (goose) back in on load.
#
# Where: Orca keeps its global state per profile, at
# <user-data-dir>/profiles/<activeProfileId>/orca-data.json (verified
# against 1.4.197 on 2026-09-06 -- NOT <user-data-dir>/orca-data.json,
# which is only the pre-profiles legacy location it copies forward). The
# active profile comes from <user-data-dir>/orca-profile-index.json when
# Orca has already run; on the very first run it is `local-default`.
#
# Idempotent by that file's existence: a folder that has been opened once
# keeps whatever the user changed, forever.
#
# bash 3.2 clean (scripts/lint-bash32.sh scans all of scripts/).

set -uo pipefail

log()  { printf '[seed-orca] %s\n' "$*"; }
warn() { printf '[seed-orca] %s\n' "$*" >&2; }

USER_DATA_DIR=""
PROJECT_DIR=""
THEME=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --user-data-dir) USER_DATA_DIR="${2:-}"; shift 2 ;;
        --project)       PROJECT_DIR="${2:-}"; shift 2 ;;
        --theme)         THEME="${2:-}"; shift 2 ;;
        *) warn "unknown argument: $1"; exit 2 ;;
    esac
done

[ -n "$USER_DATA_DIR" ] || { warn "--user-data-dir is required"; exit 2; }
[ -n "$PROJECT_DIR" ]   || { warn "--project is required"; exit 2; }

# claude-orca.json's `theme` arrives as CLAUDE_ORCA_THEME; anything Orca
# would not accept falls back to dark rather than writing a broken file.
[ -n "$THEME" ] || THEME="${CLAUDE_ORCA_THEME:-}"
case "$THEME" in
    dark|light|system) ;;
    "") THEME="dark" ;;
    *)  warn "unknown theme '$THEME'; using dark"; THEME="dark" ;;
esac

# --- where Orca's global state lives -------------------------------------

PROFILE_INDEX="$USER_DATA_DIR/orca-profile-index.json"
PROFILE_ID="local-default"
if [ -f "$PROFILE_INDEX" ] && command -v jq >/dev/null 2>&1; then
    found="$(jq -r '.activeProfileId // empty' "$PROFILE_INDEX" 2>/dev/null)"
    [ -n "$found" ] && PROFILE_ID="$found"
fi
DATA_FILE="$USER_DATA_DIR/profiles/$PROFILE_ID/orca-data.json"

if [ -e "$DATA_FILE" ]; then
    log "orca state present, not seeded ($DATA_FILE)"
    exit 0
fi

# --- the record ----------------------------------------------------------

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

new_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-Z' 'a-z'
    else
        # Good enough for a local record id: 32 hex from urandom.
        od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n' \
            | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
    fi
}

repo_id="$(new_uuid)"
[ -n "$repo_id" ] || repo_id="claude-orca-seed"
display_name="$(basename "$PROJECT_DIR")"
added_at="$(date +%s)000"
worktree_base="$PROJECT_DIR/.orca-worktrees"

e_project="$(json_escape "$PROJECT_DIR")"
e_worktree="$(json_escape "$worktree_base")"
e_display="$(json_escape "$display_name")"
e_repo_id="$(json_escape "$repo_id")"

mkdir -p "$(dirname "$DATA_FILE")" || { warn "cannot create $(dirname "$DATA_FILE")"; exit 1; }

tmp="$DATA_FILE.claude-orca.tmp"
cat > "$tmp" <<JSON
{
  "schemaVersion": 1,
  "repos": [
    {
      "id": "$e_repo_id",
      "path": "$e_project",
      "displayName": "$e_display",
      "kind": "git",
      "addedAt": $added_at,
      "worktreeBasePath": "$e_worktree"
    }
  ],
  "projects": [],
  "settings": {
    "theme": "$THEME",
    "agentDefaultEnv": {
      "claude": {
        "CLAUDE_ORCA_ROOT": "$e_project"
      }
    }
  }
}
JSON

if [ ! -s "$tmp" ]; then
    warn "failed to write $tmp"
    rm -f "$tmp"
    exit 1
fi
if command -v jq >/dev/null 2>&1 && ! jq -e . "$tmp" >/dev/null 2>&1; then
    warn "seeded JSON did not parse; leaving Orca to its own defaults"
    rm -f "$tmp"
    exit 1
fi

mv "$tmp" "$DATA_FILE" || { warn "cannot install $DATA_FILE"; rm -f "$tmp"; exit 1; }
log "seeded $DATA_FILE (theme $THEME, worktree base $worktree_base)"
exit 0
