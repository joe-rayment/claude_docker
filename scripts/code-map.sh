#!/usr/bin/env bash
# code-map — staged as bin/code-map, the code graph's ONLY documented entry
# point.
#
# The engine (graphify) is deliberately hard to reach directly: the guard at
# bin/graphify (scripts/code-map-guard.sh) is the only `graphify` on PATH
# and denies everything that rewrites assistant config. This script is
# the other half — the repo-shaped workflow the guard's error messages point
# at: build/refresh/status, the query passthroughs, report/html, upgrade and
# doctor.
#
# Engine resolution is IDENTICAL to the guard's, and for the same reason:
#   CODE_MAP_ENGINE, else <host_dir()>/code-map/bin/graphify -- a single
#   host-owned, optional install (see lib/paths.sh's host_dir()). There is
#   no per-container pin to shadow any more: `code-map upgrade` installs
#   straight into that host location, so every project sharing the same
#   host sees the upgrade. CODE_MAP_ENGINE exists so tests can redirect it.
# Never through PATH — `graphify` on PATH is the guard, so that would bounce
# every call through the allowlist for no reason (and hide upgrades).
#
# Exit: 0 ok · 1 usage/missing artifact · 3 no engine found

set -eu

# Resolve through a symlink chain (e.g. bin/code-map -> ../scripts/
# code-map.sh) to this script's real directory, so lib/paths.sh resolves
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

_engine_default=""
_host="$(host_dir 2>/dev/null)" && _engine_default="$_host/code-map/bin/graphify"
ENGINE_PATH="${CODE_MAP_ENGINE:-$_engine_default}"

die() {
    printf 'code-map: %s\n' "$1" >&2
    exit "${2:-1}"
}

# The engine, or nothing (doctor wants to report the absence, not die on it).
resolve_engine_quiet() {
    [ -n "$ENGINE_PATH" ] && [ -x "$ENGINE_PATH" ] && printf '%s\n' "$ENGINE_PATH"
    return 0
}

resolve_engine() {
    engine=$(resolve_engine_quiet)
    if [ -z "$engine" ]; then
        cat >&2 <<EOF
code-map: graphify engine not found. Looked for:
  ${ENGINE_PATH:-(no host dir resolvable)}

Run \`code-map doctor\` to diagnose (the engine is an optional host-level
install; a missing one usually means it was never installed on this host).
EOF
        exit 3
    fi
    printf '%s\n' "$engine"
}

# The repo this invocation is about: the git toplevel when we are inside one,
# else the working directory. Everything (graph, report, exclude) hangs off it.
resolve_root() {
    if root=$(git rev-parse --show-toplevel 2>/dev/null); then
        printf '%s\n' "$root"
    else
        pwd
    fi
}

# The engine reads GRAPHIFY_OUT at import time and accepts either a relative
# name or an absolute path (graphify/paths.py). We pass the environment
# through untouched and mirror that resolution so status/report/html look
# where the engine actually wrote.
resolve_out_dir() {
    _out=${GRAPHIFY_OUT:-graphify-out}
    case "$_out" in
        /*) printf '%s\n' "$_out" ;;
        *)  printf '%s/%s\n' "$1" "$_out" ;;
    esac
}

require_jq() {
    command -v jq >/dev/null 2>&1 || die "jq is required for this command"
}

# The engine only stamps built_at_commit when it rewrites the graph: `update`
# on a commit that changed no code prints "No code-graph topology changes
# detected" and leaves the previous SHA in place (also with --force), so a
# graph that IS current would keep reporting STALE. After a successful build
# or refresh the graph reflects the tree at HEAD by construction, so record
# that — this is bookkeeping the engine skips, not a status fudge.
stamp_commit() {
    _graph=$1
    [ -f "$_graph" ] || return 0
    _head=$(git rev-parse HEAD 2>/dev/null) || return 0
    command -v jq >/dev/null 2>&1 || return 0

    # graphify writes through symlinked outputs on purpose (shared-output and
    # worktree setups), so resolve before replacing or we'd clobber the link.
    _real=$(realpath "$_graph")
    _tmp="$(dirname "$_real")/.graph.json.code-map.$$"
    if jq --arg c "$_head" '.built_at_commit = $c' "$_real" > "$_tmp"; then
        mv "$_tmp" "$_real"
    else
        rm -f "$_tmp"
        die "could not stamp built_at_commit into $_real"
    fi
}

# graphify-out/ is generated, per-clone and often large: it belongs in
# .git/info/exclude (local, untracked) and NEVER in the project's .gitignore,
# which is the project's file to own. Idempotent: a line that is already there
# is left exactly as it is.
exclude_hygiene() {
    _out=$1
    if ! _top=$(git rev-parse --show-toplevel 2>/dev/null); then
        echo "exclude: skipped — not inside a git repo"
        return 0
    fi

    case "$_out" in
        "$_top"/*) _entry="${_out#"$_top"/}/" ;;
        *)
            echo "exclude: skipped — $_out is outside the repo"
            return 0
            ;;
    esac

    _excl="$(git rev-parse --absolute-git-dir)/info/exclude"
    mkdir -p "$(dirname "$_excl")"

    if [ -f "$_excl" ] && grep -qxF "$_entry" "$_excl"; then
        echo "exclude: $_entry already in .git/info/exclude"
        return 0
    fi

    # don't glue onto a file whose last line has no newline
    if [ -s "$_excl" ] && [ "$(tail -c 1 "$_excl" | wc -l)" -eq 0 ]; then
        printf '\n' >> "$_excl"
    fi
    printf '%s\n' "$_entry" >> "$_excl"
    echo "exclude: added $_entry to .git/info/exclude"
}

# Only one graph set may live under graphify-out/: the root set (graph.json,
# graph.html, GRAPH_REPORT.md, manifest.json, cache/). The engine has been
# seen to also write a dated snapshot directory (YYYY-MM-DD) next to it on
# build/update — a full duplicate nobody reads. Sweep those after every
# engine call that writes, so build/refresh can never leave one behind.
# (disk-cleanup.sh removes any that predate this fix.) Depth-1 directory
# names matching YYYY-MM-DD exactly; nothing else is touched.
prune_dated_out() {
    _out=$1
    [ -d "$_out" ] || return 0
    for _d in "$_out"/*/; do
        [ -d "$_d" ] || continue
        _base=$(basename "$_d")
        case "$_base" in
            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
                rm -rf "$_d"
                echo "code-map: removed dated snapshot dir $_base"
                ;;
        esac
    done
}

cmd_build() {
    engine=$(resolve_engine)
    root=$(resolve_root)
    out=$(resolve_out_dir "$root")

    echo "code-map build: $root"
    "$engine" extract "$root" --code-only "$@"

    # `extract` stops at graph.json: GRAPH_REPORT.md and graph.html come from
    # the clustering pass, and `refresh` only regenerates them when the code
    # graph actually changed — so without this step `code-map report` errors
    # right after a first build. --no-label keeps community naming off the
    # LLM, so this stays local and offline. Non-fatal: the graph is the
    # artifact that matters, and a clustering failure must not lose it.
    if ! "$engine" cluster-only "$root" --no-label; then
        echo "code-map: clustering failed — graph.json is built, but GRAPH_REPORT.md and graph.html may be missing or stale" >&2
    fi

    stamp_commit "$out/graph.json"
    prune_dated_out "$out"
    exclude_hygiene "$out"
}

cmd_refresh() {
    engine=$(resolve_engine)
    root=$(resolve_root)
    out=$(resolve_out_dir "$root")

    if [ ! -f "$out/graph.json" ]; then
        echo "code-map: no graph yet — building one first"
        cmd_build "$@"
        return 0
    fi

    echo "code-map refresh: $root"
    "$engine" update "$root" "$@"
    stamp_commit "$out/graph.json"
    prune_dated_out "$out"
}

cmd_status() {
    require_jq
    root=$(resolve_root)
    out=$(resolve_out_dir "$root")
    graph="$out/graph.json"

    [ -f "$graph" ] || die "no graph at $graph — run \`code-map build\`"

    nodes=$(jq '.nodes|length' "$graph")
    links=$(jq '.links|length' "$graph")
    built=$(jq -r '.built_at_commit // ""' "$graph")

    if head=$(git rev-parse HEAD 2>/dev/null); then
        if [ -n "$built" ] && [ "$built" = "$head" ]; then
            state=fresh
        else
            state=STALE
        fi
    else
        head="(not a git repo)"
        state=unknown
    fi

    echo "root: $root"
    echo "graph: $graph"
    echo "nodes: $nodes"
    echo "links: $links"
    echo "built_at_commit: ${built:-(none)}"
    echo "HEAD: $head"
    echo "state: $state"
    if [ "$state" = STALE ]; then
        echo "hint: the graph predates HEAD — run \`code-map refresh\`"
    fi
}

# The engine resolves its --graph default against the CURRENT directory, so a
# query run from a subdirectory looks for ./graphify-out/graph.json and finds
# nothing. Point it at the repo's graph instead. The caller's own arguments are
# forwarded verbatim and in order — the default is APPENDED, never inserted —
# and an explicit --graph (either spelling) wins, because we then add none.
cmd_passthrough() {
    _sub=$1
    shift
    engine=$(resolve_engine)

    for _arg in "$@"; do
        case "$_arg" in
            --graph|--graph=*)
                exec "$engine" "$_sub" "$@"
                ;;
        esac
    done

    root=$(resolve_root)
    out=$(resolve_out_dir "$root")
    exec "$engine" "$_sub" "$@" --graph "$out/graph.json"
}

cmd_report() {
    root=$(resolve_root)
    out=$(resolve_out_dir "$root")
    report="$out/GRAPH_REPORT.md"

    # The report is written by the engine's clustering pass, which runs when a
    # refresh actually rebuilds the graph — `extract --code-only` alone leaves
    # none, and a refresh that finds no topology change leaves the outputs
    # untouched. So say where it comes from, not just that it is missing.
    [ -f "$report" ] ||
        die "no GRAPH_REPORT.md at $report — the report comes from the clustering pass: \`code-map refresh\` writes one when the code graph has changed"
    cat "$report"
}

cmd_html() {
    root=$(resolve_root)
    out=$(resolve_out_dir "$root")
    html="$out/graph.html"

    [ -f "$html" ] ||
        die "no graph.html at $html — run \`code-map refresh\` first"
    realpath "$html"
}

engine_version() {
    if [ -n "$1" ] && [ -x "$1" ]; then
        "$1" version 2>&1 | head -1
    else
        echo "absent"
    fi
}

cmd_upgrade() {
    version=${1-}

    if ! command -v uv >/dev/null 2>&1; then
        die "uv is not on PATH — \`code-map upgrade\` installs the engine with \`uv tool install\`"
    fi

    if [ -n "$version" ]; then
        spec="graphifyy==$version"
    else
        spec="graphifyy"
    fi

    _host="$(host_dir)" || die "could not resolve the host install dir (host_dir(), see lib/paths.sh)"
    target="$_host/code-map"

    # Installs under the host's own code-map/ only -- one install shared by
    # every project on this host, nothing project-writable involved (the
    # guard exists to block engine installers writing assistant config).
    echo "code-map upgrade: installing $spec into $target"
    UV_TOOL_DIR="$target/tools" \
    UV_TOOL_BIN_DIR="$target/bin" \
        uv tool install --force "$spec"

    ENGINE_PATH="$target/bin/graphify"
    engine=$(resolve_engine)
    echo "smoke: $engine"
    "$engine" version

    root=$(resolve_root)
    out=$(resolve_out_dir "$root")
    if [ -f "$out/graph.json" ]; then
        cmd_refresh
    fi
}

cmd_doctor() {
    engine=$(resolve_engine_quiet)
    root=$(resolve_root)
    out=$(resolve_out_dir "$root")
    graph="$out/graph.json"

    if [ -n "$engine" ]; then
        echo "engine: $engine"
        echo "engine version: $(engine_version "$engine")"
    else
        echo "engine: none found (looked for ${ENGINE_PATH:-no host dir resolvable})"
        echo "engine version: unavailable"
        echo "note: the engine is an optional host-level install — \`code-map upgrade\` installs one"
    fi

    echo "root: $root"
    if [ -f "$graph" ] && command -v jq >/dev/null 2>&1; then
        built=$(jq -r '.built_at_commit // ""' "$graph")
        if head=$(git rev-parse HEAD 2>/dev/null); then
            if [ -n "$built" ] && [ "$built" = "$head" ]; then
                echo "graph: $graph (state: fresh)"
            else
                echo "graph: $graph (state: STALE — run \`code-map refresh\`)"
            fi
        else
            echo "graph: $graph (state: unknown — not a git repo)"
        fi
    else
        echo "graph: absent at $graph — run \`code-map build\`"
    fi

    if top=$(git rev-parse --show-toplevel 2>/dev/null); then
        excl="$(git rev-parse --absolute-git-dir)/info/exclude"
        case "$out" in
            "$top"/*) entry="${out#"$top"/}/" ;;
            *)        entry="" ;;
        esac
        if [ -z "$entry" ]; then
            echo "exclude: n/a — $out is outside the repo"
        elif [ -f "$excl" ] && grep -qxF "$entry" "$excl"; then
            echo "exclude: $entry present in .git/info/exclude"
        else
            echo "exclude: $entry missing from .git/info/exclude — the next \`code-map build\` adds it"
        fi
    else
        echo "exclude: n/a — not inside a git repo"
    fi
}

usage() {
    cat <<'EOF'
usage: code-map <command> [args]

  build              extract the code graph for this repo (AST only, no API key)
  refresh            update an existing graph (builds one if there is none)
  status             node/link counts + whether the graph matches HEAD

  explain "X"        what a symbol is and what it touches
  path "A" "B"       shortest path between two nodes
  query "Q"          traversal answering a question
  affected "X"       what breaks if X changes
  tree               collapsible-tree HTML of the graph
  god-nodes          the most connected nodes

  report             print graphify-out/GRAPH_REPORT.md
  html               print the path to graphify-out/graph.html

  upgrade [version]  install a newer engine at the host level (see `code-map doctor`)
  doctor             engine, version, graph state, exclude entry
  help               this message

The graph lands in graphify-out/ (override with GRAPHIFY_OUT) and is excluded
via .git/info/exclude, never the project's .gitignore.
EOF
}

cmd=${1-}
[ $# -gt 0 ] && shift || true

case "$cmd" in
    build)   cmd_build "$@" ;;
    refresh) cmd_refresh "$@" ;;
    status)  cmd_status "$@" ;;
    explain|path|query|affected|tree|god-nodes)
        cmd_passthrough "$cmd" "$@"
        ;;
    report)  cmd_report "$@" ;;
    html)    cmd_html "$@" ;;
    upgrade) cmd_upgrade "$@" ;;
    doctor)  cmd_doctor "$@" ;;
    ''|help|-h|--help)
        usage
        ;;
    *)
        printf 'code-map: unknown command: %s\n\n' "$cmd" >&2
        usage >&2
        exit 1
        ;;
esac
