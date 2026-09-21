#!/usr/bin/env bash
#
# seed-orca-state.sh -- give a fresh project folder an Orca that already
# knows about it (v3 S4, claude-orca-qa2.5; .claude/plans/container-v3.md
# S3). Run by the entrypoint as the `agent` user, once, BEFORE serve
# starts.
#
# What it writes and why:
#   repos[0].worktreeBasePath  the agent home's worktrees volume when the
#                              launcher mounted one
#                              ($AGENT_HOME/worktrees, named in
#                              CLAUDE_ORCA_VOLUME_DIRS), else
#                              <project>/.orca-worktrees. This key is
#                              PER-REPO, not a global setting, and
#                              `orca repo add` has no flag for it --
#                              pre-seeding the record is the only way in.
#                              Worktrees moved OFF the macOS share
#                              (claude-orca-1eh): file-creating work there
#                              costs 15x the wall time and 185x the VM
#                              interrupts of a docker volume
#                              (claude-orca-19o), and git worktrees are
#                              nothing but file creation. Worktrees
#                              already under .orca-worktrees keep working
#                              -- git tracks them by path, and
#                              worktree-gc is path-agnostic -- so an
#                              existing orca-data.json is rewritten only
#                              entry by entry, and only the ones still
#                              naming the old default.
#                              projects[] stays empty on purpose: Orca
#                              derives the project row from repos[] on
#                              load, and `orca repo add` later finds the
#                              seeded record by path instead of adding a
#                              second one.
#   settings.theme             dark by default (claude-orca.json `theme`
#                              rides in as CLAUDE_ORCA_THEME). This steers
#                              only the Electron DESKTOP client; it does
#                              nothing for Orca Web, which keeps its theme
#                              in browser localStorage and is seeded from
#                              web-index.html inside app.asar instead
#                              (claude-orca-qa2.18).
#   settings.agentDefaultEnv   CLAUDE_ORCA_ROOT=<project>, so an agent Orca
#                              launches can find the folder root. This map
#                              is keyed BY AGENT ID first
#                              (agentDefaultEnv.claude.CLAUDE_ORCA_ROOT); a
#                              flat KEY:value map is silently dropped by
#                              normalizeTuiAgentEnvRecord. Orca merges its
#                              own defaults (goose) back in on load.
#                              agentDefaultEnv.opencode.OPENCODE_CONFIG is
#                              the file config-sync.sh writes into the
#                              agent home, named by its path INSIDE the VM
#                              (.claude-dev/home is mounted /home/agent);
#                              opencode reads its OpenRouter provider from
#                              there rather than from argv.
#                              OPENROUTER_API_KEY / OPENROUTER_BASE_URL on
#                              the `opencode` and `codex` ids are the in-VM
#                              guard's token and loopback URL, passed in by
#                              the entrypoint (claude-orca-qa2.21). The real
#                              OpenRouter key never appears here: the guard
#                              holds it alone and forces the provider
#                              allowlist, which is what keeps the user's
#                              data on US/Canadian/European hosts. Absent
#                              entirely when the folder has no key.
#   settings.agentDefaultArgs  how Orca launches each agent id
#                              (claude-orca-qa2.11): `claude
#                              --dangerously-skip-permissions` and
#                              `opencode --auto`. The VM is the boundary,
#                              so a worker terminal that stops for
#                              permission prompts is just a hung worker.
#   settings.nestedWorkerMaxDepth
#                              2 -- an orchestrator may dispatch an "epic
#                              coordinator" worker that runs orca-run over
#                              its own executors (claude-orca-qa2.16,
#                              plan "Parallel by default"); those
#                              executors do not delegate further.
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
TERM_THEME=""
OR_TOKEN=""
OR_BASE_URL=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --user-data-dir) USER_DATA_DIR="${2:-}"; shift 2 ;;
        --project)       PROJECT_DIR="${2:-}"; shift 2 ;;
        --theme)         THEME="${2:-}"; shift 2 ;;
        --terminal-theme) TERM_THEME="${2:-}"; shift 2 ;;
        --openrouter-token)    OR_TOKEN="${2:-}"; shift 2 ;;
        --openrouter-base-url) OR_BASE_URL="${2:-}"; shift 2 ;;
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

# The terminal PALETTE, by name. "Homebrew" is Orca's own builtin
# green-on-black -- the old phosphor monitor -- and is what this template
# ships. An unknown name is Orca's to reject (it falls back to its own
# default); a name carrying a quote would break the JSON, so refuse that here.
[ -n "$TERM_THEME" ] || TERM_THEME="${CLAUDE_ORCA_TERMINAL_THEME:-}"
[ -n "$TERM_THEME" ] || TERM_THEME="Homebrew"
case "$TERM_THEME" in
    *[!A-Za-z0-9\ ._-]*)
        warn "unusable terminal theme '$TERM_THEME'; using Homebrew"
        TERM_THEME="Homebrew" ;;
esac

# --- the worktree base (claude-orca-1eh) ----------------------------------
#
# On the worktrees volume when the launcher mounted one, else the old
# in-folder default. HOME is the agent home: the entrypoint runs this
# through run_as_agent, which pins it.

. "$(dirname "$0")/volume-dirs.sh"

agent_home="${CLAUDE_ORCA_AGENT_HOME:-${HOME:-}}"
volume_worktree_base="$agent_home/worktrees"
worktree_base="$PROJECT_DIR/.orca-worktrees"
using_volume_base=0
if [ -n "$agent_home" ]; then
    while IFS= read -r d; do
        [ "$d" = "$volume_worktree_base" ] && using_volume_base=1
    done < <(volume_dirs "$agent_home")
fi
if [ "$using_volume_base" = "1" ]; then
    worktree_base="$volume_worktree_base"
fi

# --- where Orca's global state lives -------------------------------------

PROFILE_INDEX="$USER_DATA_DIR/orca-profile-index.json"
PROFILE_ID="local-default"
if [ -f "$PROFILE_INDEX" ] && command -v jq >/dev/null 2>&1; then
    found="$(jq -r '.activeProfileId // empty' "$PROFILE_INDEX" 2>/dev/null)"
    [ -n "$found" ] && PROFILE_ID="$found"
fi
DATA_FILE="$USER_DATA_DIR/profiles/$PROFILE_ID/orca-data.json"

# An existing orca-data.json keeps whatever the user changed, forever --
# except the one key this script owns the DEFAULT of: when the volume base
# applies, records still naming the old in-folder default are rewritten to
# the volume, so a folder that predates the volumes gets its worktrees
# moved too. jq through a tmp file in the same directory and an mv, so a
# failure mid-write cannot lose the file; jq missing or failing leaves the
# file byte-identical and still exits 0 -- a base path left on the share is
# a performance loss, not a broken folder. Safe because the entrypoint runs
# this before `orca-ide --serve` starts: Orca is not holding the file.
rewrite_worktree_base_to_volume() {
    if ! command -v jq >/dev/null 2>&1; then
        warn "no jq; could not rewrite worktreeBasePath to $volume_worktree_base"
        return 0
    fi
    local tmp="$DATA_FILE.claude-orca.tmp"
    if ! jq --arg p "$PROJECT_DIR" \
            --arg old "$PROJECT_DIR/.orca-worktrees" \
            --arg new "$volume_worktree_base" '
            .repos = ((.repos // []) |
                      map(if .path == $p and .worktreeBasePath == $old
                          then .worktreeBasePath = $new
                          else . end))' \
            "$DATA_FILE" > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        warn "could not rewrite worktreeBasePath in $DATA_FILE; leaving the file as it is"
        return 0
    fi
    if ! mv "$tmp" "$DATA_FILE"; then
        rm -f "$tmp"
        warn "could not install the rewritten $DATA_FILE"
        return 0
    fi
    log "rewrote worktreeBasePath to $volume_worktree_base for $PROJECT_DIR in $DATA_FILE"
}

if [ -e "$DATA_FILE" ]; then
    if [ "$using_volume_base" = "1" ]; then
        rewrite_worktree_base_to_volume
    fi
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

e_project="$(json_escape "$PROJECT_DIR")"
e_worktree="$(json_escape "$worktree_base")"
e_display="$(json_escape "$display_name")"
e_repo_id="$(json_escape "$repo_id")"
e_term_theme="$(json_escape "$TERM_THEME")"

# The guard's credentials, on the two agent ids that talk to OpenRouter.
# Both or neither: half of a base URL is worse than none.
if [ -n "$OR_TOKEN" ] && [ -n "$OR_BASE_URL" ]; then
    e_or_token="$(json_escape "$OR_TOKEN")"
    e_or_base="$(json_escape "$OR_BASE_URL")"
    agent_env="$(cat <<ENV
      "claude": {
        "CLAUDE_ORCA_ROOT": "$e_project"
      },
      "opencode": {
        "OPENCODE_CONFIG": "/home/agent/.config/opencode/opencode.json",
        "OPENROUTER_API_KEY": "$e_or_token",
        "OPENROUTER_BASE_URL": "$e_or_base"
      },
      "codex": {
        "OPENROUTER_API_KEY": "$e_or_token",
        "OPENROUTER_BASE_URL": "$e_or_base"
      }
ENV
)"
else
    agent_env="$(cat <<ENV
      "claude": {
        "CLAUDE_ORCA_ROOT": "$e_project"
      },
      "opencode": {
        "OPENCODE_CONFIG": "/home/agent/.config/opencode/opencode.json"
      }
ENV
)"
fi

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
    "terminalThemeDark": "$e_term_theme",
    "terminalThemeLight": "$e_term_theme",
    "agentDefaultEnv": {
$agent_env
    },
    "agentDefaultArgs": {
      "claude": "--dangerously-skip-permissions",
      "opencode": "--auto"
    },
    "nestedWorkerMaxDepth": 2
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
or_note="no OpenRouter guard env"
[ -n "$OR_TOKEN" ] && [ -n "$OR_BASE_URL" ] \
    && or_note="OpenRouter guard env on opencode+codex -> $OR_BASE_URL"
log "seeded $DATA_FILE (theme $THEME, terminal $TERM_THEME, worktree base $worktree_base, $or_note)"
exit 0
