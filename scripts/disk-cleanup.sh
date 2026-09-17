#!/usr/bin/env bash
# disk-cleanup — bound the disk footprint of a long-lived project sandbox.
#
# Best-effort, age-gated, size-capped. Safe to run repeatedly and safe to run
# while work is in progress: it only ever touches known-ephemeral artifacts
# (stray test temp dirs, aged screenshots, oversized append-only logs) and
# never git-tracked source, the harness transcript store (the config dir's
# projects/), or anything younger than its age gate.
#
# Wired to run automatically at each Claude session start (SessionStart hook
# in claude-settings.json, backgrounded). Also runnable by hand:
#
#   disk-cleanup            # sweep now
#   disk-cleanup --dry-run  # show what would be removed, change nothing
#
# Retention knobs (override via env):
#   TMP_AGE_MIN      stray /tmp test artifacts older than N minutes (default 1440 = 1 day)
#   ATTACH_AGE_DAYS  attachments/ files older than N days           (default 7)
#   LOG_MAX_LINES    cap each config-dir logs/*.log to its last N lines (default 5000)
#   WORKSPACE        project root to clean                          (default: claude_orca_root(), else $PWD)
#   TMP_SCAN_DIR     directory to sweep for stray test artifacts    (default /tmp)
#   CLAUDE_ORCA_CLEANUP_TRANSCRIPT_DAYS  config-dir projects/ files older
#                     than N days (default 30)
#   CLAUDE_ORCA_CLEANUP_NPM_DAYS          ~/.npm/_cacache files older than N
#                     days (default 14)
#
# Also swept (beads claude-orca-3fp): dated graphify-out/<YYYY-MM-DD>/
# snapshot dirs the engine used to leave next to the canonical set, and the
# npm cache. ~/.cache/ms-playwright is deliberately NOT swept — it is only
# ever reported (it is the single biggest home consumer and re-downloading
# browsers is far costlier than the disk it sits on).
#
#   disk-cleanup --report    print the top 10 consumers under $HOME by size
#                            plus graphify-out's size; deletes nothing

set -u

# Resolve through a symlink chain (e.g. bin/disk-cleanup -> ../scripts/
# disk-cleanup.sh) to this script's real directory, so lib/paths.sh resolves
# whether this is invoked via the repo copy or the .claude-dev/template/
# bin/ symlink.
_resolve_script_path() {
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
SCRIPT_DIR="$(cd "$(dirname "$(_resolve_script_path)")" && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"

DRY=0
case "${1:-}" in
    --dry-run) DRY=1 ;;
    --report)  REPORT=1 ;;
esac
REPORT="${REPORT:-0}"

TMP_AGE_MIN="${TMP_AGE_MIN:-1440}"
ATTACH_AGE_DAYS="${ATTACH_AGE_DAYS:-7}"
LOG_MAX_LINES="${LOG_MAX_LINES:-5000}"
TRANSCRIPT_DAYS="${CLAUDE_ORCA_CLEANUP_TRANSCRIPT_DAYS:-30}"
NPM_DAYS="${CLAUDE_ORCA_CLEANUP_NPM_DAYS:-14}"
WORKSPACE="${WORKSPACE:-$(claude_orca_root 2>/dev/null || pwd)}"
TMP_SCAN_DIR="${TMP_SCAN_DIR:-/tmp}"

note() { echo "disk-cleanup: $*"; }

# graphify-out/, honoring GRAPHIFY_OUT the way code-map resolves it: an
# absolute path stands, a relative one hangs off the workspace root.
graphify_out_dir() {
    _out="${GRAPHIFY_OUT:-$WORKSPACE/graphify-out}"
    case "$_out" in
        /*) printf '%s\n' "$_out" ;;
        *)  printf '%s/%s\n' "$WORKSPACE" "$_out" ;;
    esac
}

# --- 0. --report: show the biggest consumers, touch nothing -------------------
# Top 10 directories under $HOME by size (du -sh, biggest first) plus the
# graphify-out line, since it is workspace-sized and hides outside $HOME.
# ms-playwright shows up here when it earns its place — reported, never swept.
if [ "$REPORT" = 1 ]; then
    note "top consumers under ${HOME}:"
    du -sh "$HOME"/.[!.]* "$HOME"/* 2>/dev/null | sort -rh | head -10 \
        | sed 's|^|disk-cleanup:   |'
    gout="$(graphify_out_dir)"
    if [ -d "$gout" ]; then
        note "graphify-out: $(du -sh "$gout" 2>/dev/null | cut -f1)  ($gout)"
    else
        note "graphify-out: none ($gout)"
    fi
    exit 0
fi

# --- 4. dated graphify-out/<YYYY-MM-DD>/ snapshot dirs ------------------------
# The engine used to write dated copies next to the canonical root set; the
# root set (graph.json, graph.html, GRAPH_REPORT.md, manifest.json, cache/)
# is the only graph anyone reads, so dated dirs are pure duplication. Depth-1
# directory names matching YYYY-MM-DD exactly; nothing else is touched.
gout="$(graphify_out_dir)"
if [ -d "$gout" ]; then
    dated_count=0
    for d in "$gout"/*/; do
        [ -d "$d" ] || continue
        base="$(basename "$d")"
        case "$base" in
            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
                if [ "$DRY" = 1 ]; then
                    note "[dry-run] would remove dated graph snapshot $base"
                else
                    rm -rf "$d" && dated_count=$((dated_count + 1))
                fi
                ;;
        esac
    done
    [ "$dated_count" -gt 0 ] && note "removed $dated_count dated graphify-out snapshot dir(s)"
fi

# --- 5. aged session transcripts (config dir's projects/) ---------------------
# The harness transcript store grows without bound; anything not modified in
# the last TRANSCRIPT_DAYS is dead history. Files only — live session dirs
# keep their recent transcripts, and ms-playwright is never touched here.
PROJ="$(claude_config_dir 2>/dev/null)/projects"
if [ -d "$PROJ" ] && [ "$TRANSCRIPT_DAYS" -ge 0 ]; then
    if [ "$DRY" = 1 ]; then
        find "$PROJ" -type f -mtime +"$TRANSCRIPT_DAYS" 2>/dev/null \
            | sed 's|^|disk-cleanup: [dry-run] would remove transcript |'
    else
        tr_swept=$(find "$PROJ" -type f -mtime +"$TRANSCRIPT_DAYS" 2>/dev/null | wc -l | tr -d ' ')
        find "$PROJ" -type f -mtime +"$TRANSCRIPT_DAYS" -exec rm -f {} + 2>/dev/null
        [ "${tr_swept:-0}" -gt 0 ] && note "removed $tr_swept transcript(s) older than ${TRANSCRIPT_DAYS}d"
    fi
fi

# --- 6. aged npm cache (_cacache) ---------------------------------------------
# npm's content-addressed cache is safe to prune by age; npm re-fetches on
# demand. Files older than NPM_DAYS go, then the empty dirs they leave behind.
NPM="${HOME}/.npm/_cacache"
if [ -d "$NPM" ] && [ "$NPM_DAYS" -ge 0 ]; then
    if [ "$DRY" = 1 ]; then
        find "$NPM" -type f -mtime +"$NPM_DAYS" 2>/dev/null \
            | sed 's|^|disk-cleanup: [dry-run] would remove npm cache file |'
    else
        npm_swept=$(find "$NPM" -type f -mtime +"$NPM_DAYS" 2>/dev/null | wc -l | tr -d ' ')
        find "$NPM" -type f -mtime +"$NPM_DAYS" -exec rm -f {} + 2>/dev/null
        find "$NPM" -mindepth 1 -type d -empty -delete 2>/dev/null
        [ "${npm_swept:-0}" -gt 0 ] && note "removed $npm_swept npm cache file(s) older than ${NPM_DAYS}d"
    fi
fi

# --- 1. stray test temp dirs/files in /tmp -----------------------------------
# bats normally cleans its own run dirs, but a killed run — or any tool that
# leaves mktemp scratch behind — can strand these. Age-gated so nothing a live
# test is currently using gets pulled out from under it. Patterns are the ones
# this template's tests and tools actually create; the harness scratchpad
# (/tmp/claude-*) is deliberately NOT matched.
# Quoted -name patterns (via a helper) so the shell never glob-expands them
# against the cwd, and find -exec (not `for p in $(find ...)`) so paths with
# spaces are handled correctly. wc -l over find's output gives the count.
find_tmp() {  # find_tmp <extra find args...>
    # -mindepth 1: never match the scan dir itself — a non-default TMP_SCAN_DIR
    # whose basename matches a pattern (e.g. .../tmp.foo) would otherwise be
    # swept whole at depth 0.
    find "$TMP_SCAN_DIR" -mindepth 1 -maxdepth 1 -mmin +"$TMP_AGE_MIN" \
        \( -name 'tmp.*' -o -name 'bats-run-*' -o -name '*.bats' \
           -o -name 'claude-test-*' -o -name 'csearch-test-*' -o -name 'leaktest.*' \) \
        "$@" 2>/dev/null
}
if [ "$DRY" = 1 ]; then
    find_tmp | sed 's|^|disk-cleanup: [dry-run] would remove |'
else
    tmp_swept=$(find_tmp | wc -l | tr -d ' ')
    find_tmp -exec rm -rf {} +
    [ "${tmp_swept:-0}" -gt 0 ] && note "removed $tmp_swept stray /tmp test artifact(s)"
fi

# --- 2. aged attachments (screenshots, dropped files) ------------------------
ATT="$WORKSPACE/attachments"
if [ -d "$ATT" ]; then
    if [ "$DRY" = 1 ]; then
        find "$ATT" -maxdepth 1 -type f -mtime +"$ATTACH_AGE_DAYS" 2>/dev/null \
            | sed 's|^|disk-cleanup: [dry-run] would remove attachment |'
    else
        att_swept=$(find "$ATT" -maxdepth 1 -type f -mtime +"$ATTACH_AGE_DAYS" 2>/dev/null | wc -l | tr -d ' ')
        find "$ATT" -maxdepth 1 -type f -mtime +"$ATTACH_AGE_DAYS" -exec rm -f {} + 2>/dev/null
        [ "${att_swept:-0}" -gt 0 ] && note "removed $att_swept attachment(s) older than ${ATTACH_AGE_DAYS}d"
    fi
fi

# --- 3. cap the append-only dev-log files ------------------------------------
# These are monolithic (changes/decisions/errors/runs.log), appended forever,
# so their mtime is always "now" — age-based rotation can't bound them. Cap
# each to its last N lines, preserving recent history, when it grows past cap.
LOGS="$(claude_config_dir 2>/dev/null)/logs"
if [ -d "$LOGS" ]; then
    for f in "$LOGS"/*.log; do
        [ -f "$f" ] || continue
        lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
        [ -n "$lines" ] || continue
        if [ "$lines" -gt "$LOG_MAX_LINES" ]; then
            if [ "$DRY" = 1 ]; then
                note "[dry-run] would trim $(basename "$f") from $lines to $LOG_MAX_LINES lines"
            else
                # Rewrite in place (capture then truncate-write) instead of
                # tmp+mv: keeps the inode, mode, and owner. An append landing
                # between the tail read and the write is still lost — accepted:
                # log-only data, and the sweep runs at (session) start, not
                # during heavy logging.
                if kept=$(tail -n "$LOG_MAX_LINES" "$f" 2>/dev/null) && [ -n "$kept" ]; then
                    printf '%s\n' "$kept" > "$f" && note "trimmed $(basename "$f") from $lines to $LOG_MAX_LINES lines"
                fi
            fi
        fi
    done
fi

exit 0
