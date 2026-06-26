#!/bin/bash
# csearch — lean combined code search for Claude Code.
#
# One command fuses the round-trips the built-in tools take separately:
# discover (glob) + grep (ripgrep) + read (line-range slice) + signature
# summary. Fewer agent turns, less context burned. 100% local — no network,
# no login, no telemetry. Just a thin wrapper over ripgrep + awk.
#
# Modes:
#   csearch <pattern> [glob ...]      Content search (default). Line-numbered
#                                     matches across the tree, optionally
#                                     filtered to one or more globs.
#       -i            Case-insensitive
#       -C N          N lines of context around each match (default 0)
#       -l            List matching files only (no match lines)
#       -t TYPE       Restrict to a ripgrep file type (e.g. ts, py, go, rust)
#       -m N          Max matches per file (default 0 = unlimited)
#
#   csearch read <file> [START[-END]] Print a file or line range, line-numbered.
#   csearch sig  <glob ...>           Print signature/structure lines
#                                     (functions, classes, types, …).
#
# Examples:
#   csearch "useAuth" 'src/**/*.ts'        # grep, scoped to a glob
#   csearch -l -t py "TODO"                 # files only, python only
#   csearch -C 2 "def main"                 # 2 lines of context
#   csearch read src/app.ts 40-80          # slice lines 40-80
#   csearch sig 'src/**/*.go'              # all signatures in a glob
set -uo pipefail

RG=${CSEARCH_RG:-rg}
command -v "$RG" >/dev/null 2>&1 || { echo "csearch: ripgrep (rg) not found" >&2; exit 127; }

MAXCOL=${CSEARCH_MAXCOL:-300}   # truncate long lines (minified-file guard)

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }

# Classify trailing args into rg path positionals vs -g glob flags.
# Existing files/dirs are searched directly; everything else is a glob.
# Sets global arrays PATHS and GFLAGS.
classify_paths() {
    PATHS=(); GFLAGS=()
    local a
    for a in "$@"; do
        if [ -e "$a" ]; then PATHS+=( "$a" ); else GFLAGS+=( -g "$a" ); fi
    done
}

read_mode() {
    local file=${1:-}
    [ -n "$file" ] || { echo "csearch read: missing <file>" >&2; exit 2; }
    [ -f "$file" ] || { echo "csearch read: no such file: $file" >&2; exit 2; }
    local range=${2:-} start=1 end=0
    if [ -n "$range" ]; then
        start=${range%%-*}
        end=${range##*-}
        [ "$range" = "$start" ] && end=$start   # single line, no dash
    fi
    awk -v s="$start" -v e="$end" -v m="$MAXCOL" '
        (e==0 || NR>=s) && (e==0 ? NR>=s : NR<=e) {
            line=$0
            if (length(line) > m) line=substr(line,1,m) "…"
            printf "%6d\t%s\n", NR, line
        }
        e!=0 && NR>e { exit }' "$file"
}

sig_mode() {
    [ "$#" -gt 0 ] || { echo "csearch sig: missing <glob ...>" >&2; exit 2; }
    classify_paths "$@"
    # Two patterns: (1) keyword-led declarations across common languages;
    # (2) function/method openers like `name(args) {` (shell, C, JS/TS, Go).
    local kw='^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(public[[:space:]]+|private[[:space:]]+|protected[[:space:]]+|static[[:space:]]+)*(async[[:space:]]+)?(function|class|interface|type|enum|struct|trait|impl|module|namespace|def|fn|func)\b'
    local opener='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*$'
    "$RG" --line-number --no-heading --color never -M "$MAXCOL" "${GFLAGS[@]}" \
        -e "$kw" -e "$opener" "${PATHS[@]}" \
        | grep -Ev ':[[:space:]]*(if|for|while|switch|else|elif|catch|do|return)\b' || true
}

find_mode() {
    local ignore='' context='' listonly='' type='' maxcount=''
    while getopts ":iC:lt:m:" opt; do
        case "$opt" in
            i) ignore='--ignore-case' ;;
            C) context="--context=$OPTARG" ;;
            l) listonly='--files-with-matches' ;;
            t) type="--type=$OPTARG" ;;
            m) maxcount="--max-count=$OPTARG" ;;
            :) echo "csearch: -$OPTARG requires an argument" >&2; exit 2 ;;
            \?) echo "csearch: unknown flag -$OPTARG" >&2; exit 2 ;;
        esac
    done
    shift $((OPTIND - 1))
    local pattern=${1:-}
    [ -n "$pattern" ] || { usage; exit 2; }
    shift || true
    classify_paths "$@"
    [ "${maxcount:-}" = "--max-count=0" ] && maxcount=''
    "$RG" --line-number --no-heading --color never -M "$MAXCOL" \
        ${ignore:+$ignore} ${context:+$context} ${listonly:+$listonly} \
        ${type:+$type} ${maxcount:+$maxcount} \
        "${GFLAGS[@]}" -e "$pattern" "${PATHS[@]}"
    local rc=$?
    [ "$rc" -eq 1 ] && return 0   # rg: 1 = no matches, not an error here
    return "$rc"
}

case "${1:-}" in
    ''|-h|--help) usage ;;
    read) shift; read_mode "$@" ;;
    sig)  shift; sig_mode "$@" ;;
    *)    find_mode "$@" ;;
esac
