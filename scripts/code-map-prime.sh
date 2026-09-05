#!/usr/bin/env bash
# code-map-prime — staged as bin/code-map-prime, wired as a SessionStart
# hook in claude-settings.json.
#
# Two jobs, in order: keep this repo's code graph current, then print the block
# that makes the map first-source — counts, the commit it was built at, and the
# three queries worth reaching for before grepping. Stdout goes straight into
# Claude's context, so the ONLY things written there are those two lines; the
# shim's own build/refresh chatter is logged, never injected.
#
# Fail open, always. A SessionStart hook that errors, hangs or spews breaks
# session start for a feature nobody asked for at that moment, so every case
# that isn't "this repo has a code graph to talk about" is a silent exit 0:
# not a git repo, no code files, no `code-map` on PATH, CODE_MAP_DISABLE set,
# unreadable status. The one slow step (refresh) runs under `timeout`, and on
# expiry it is detached and the block still prints from the existing graph.
#
# Env knobs (production defaults; the tests inject all four):
#   CODE_MAP_DISABLE          any non-empty, non-zero value → say nothing
#   CODE_MAP_BIN              the shim to drive (default: `code-map` on PATH)
#   CODE_MAP_LOG              default: the config dir's logs/code-map.log
#   CODE_MAP_REFRESH_TIMEOUT  seconds a session-start refresh may take (10)

set -u

# Resolve through a symlink chain (e.g. bin/code-map-prime -> ../scripts/
# code-map-prime.sh) to this script's real directory, so lib/paths.sh
# resolves whether this is invoked via the repo copy or the
# .claude-dev/template/bin/ symlink.
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

LOG=${CODE_MAP_LOG:-$(claude_config_dir 2>/dev/null)/logs/code-map.log}
REFRESH_TIMEOUT=${CODE_MAP_REFRESH_TIMEOUT:-10}

# --- applicability: every failure below is silent -----------------------------

case "${CODE_MAP_DISABLE:-}" in
    ''|0) ;;
    *) exit 0 ;;
esac

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$root" ] || exit 0
cd "$root" 2>/dev/null || exit 0

# The shim, never the engine: `code-map` owns root/out-dir resolution and the
# built_at_commit stamp, and re-deriving any of that here would fork the
# feature's single source of truth. A path (injected or configured) must be
# executable; a bare name must be on PATH.
resolve_shim() {
    _c=${CODE_MAP_BIN:-code-map}
    case "$_c" in
        */*) [ -x "$_c" ] && printf '%s\n' "$_c" ;;
        *)   command -v "$_c" 2>/dev/null ;;
    esac
}
CODE_MAP=$(resolve_shim) || CODE_MAP=""
[ -n "$CODE_MAP" ] || exit 0

# Is there code here at all? `grep -q` short-circuits on the first match, so
# this reads a few lines of an index git already has — no tree walk, no stat
# storm, and a docs-only repo never gets a graph built behind its back.
git ls-files 2>/dev/null |
    grep -qiE '\.(py|js|jsx|ts|tsx|go|rs|java|c|cc|cpp|h|hpp|rb|php|swift|scala|kt|sh|lua|zig|ex|exs)$' ||
    exit 0

# Mirrors the shim's resolve_out_dir: GRAPHIFY_OUT is read by the engine at
# import time and may be a bare name or an absolute path.
out=${GRAPHIFY_OUT:-graphify-out}
case "$out" in
    /*) ;;
    *)  out="$root/$out" ;;
esac
graph="$out/graph.json"

# --- work ---------------------------------------------------------------------

# Detached and fully redirected: an inherited stdout would keep whatever is
# reading this hook waiting on a build that takes minutes. An unwritable log
# directory is not a reason to skip the build.
background() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG=/dev/null
    nohup "$CODE_MAP" "$1" >>"$LOG" 2>&1 </dev/null &
}

if [ ! -f "$graph" ]; then
    background build
    # the log path is quoted relative to the repo when it lives inside it,
    # which is the case this message is written for
    case "$LOG" in
        "$root"/*) log_display=${LOG#"$root"/} ;;
        *)         log_display=$LOG ;;
    esac
    echo "[code-map] no graph yet — building in background (log: $log_display); code-map status when done"
    exit 0
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG=/dev/null
if command -v timeout >/dev/null 2>&1; then
    timeout "$REFRESH_TIMEOUT" "$CODE_MAP" refresh >>"$LOG" 2>&1
    rc=$?
else
    "$CODE_MAP" refresh >>"$LOG" 2>&1
    rc=$?
fi
# 124 = too slow for a session start. Hand it to a detached refresh and report
# the graph we already have — STALE and printed beats fresh and blocking. Any
# other failure is the shim's to report in the log; the block still prints.
[ "$rc" -eq 124 ] && background refresh

# `code-map status` is the single source of truth for counts and freshness —
# parsed here rather than re-implemented over graph.json.
status_out=$("$CODE_MAP" status 2>/dev/null) || exit 0

field() {
    printf '%s\n' "$status_out" | sed -n "s/^$1: //p" | head -1
}
nodes=$(field nodes)
edges=$(field links)
built=$(field built_at_commit)
state=$(field state)

# Nothing truthful to say → say nothing.
[ -n "$nodes" ] || exit 0
[ -n "$edges" ] || exit 0

case "$built" in
    ''|'(none)') sha8=unknown ;;
    *)           sha8=$(printf '%s' "$built" | cut -c1-8) ;;
esac
[ -n "$state" ] || state=unknown

printf '[code-map] %s nodes · %s edges · built at %s (%s) — structure first: code-map explain <sym> · affected <file> · path A B · report\n' \
    "$nodes" "$edges" "$sha8" "$state"
printf '[code-map] INFERRED edges are hints — verify before acting\n'
exit 0
