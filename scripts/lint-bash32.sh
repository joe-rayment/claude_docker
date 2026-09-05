#!/usr/bin/env bash
#
# lint-bash32.sh -- greps a set of files/directories for shell constructs
# that need bash >= 4 (macOS ships bash 3.2 at /bin/bash; see
# .claude/plans/orca-port.md S3.2 and claude-orca-3sk.24 -- every script
# under scripts/ must run under bash 3.2). Reusable: called from
# tests/shell-entry.bats, but plain enough to run by hand too.
#
# Flags, one "path:lineno: reason" per violation on stdout:
#   - `+=("${` (array-append with an array/glob expansion on the right)
#     on a line with no `[@]+` guard alongside it -- the bash-3.2 bug this
#     bead exists to fix: `arr+=("${maybe_empty[@]}")` under `set -u`
#     throws "unbound variable" when maybe_empty has zero elements; the
#     fix is the `arr+=(${maybe_empty[@]+"${maybe_empty[@]}"})` idiom.
#   - `declare -A`      (associative arrays -- bash 4+)
#   - `mapfile` / `readarray`                   (bash 4+ builtins)
#   - `${var,,}` / `${var^^}`                   (bash 4+ case conversion)
#   - `&>>`                                     (bash 4+ append-both redirect)
#   - `|&`                                      (bash 4+ pipe-both shorthand)
#
# Usage: lint-bash32.sh [path ...]     (default: scripts)
# Exit 0 and silent if clean; exit 1 with the violation list otherwise.
# A directory argument is scanned recursively; this script's own path is
# always excluded (it necessarily names every pattern above).

set -euo pipefail

SELF_RESOLVED="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"

if [ "$#" -gt 0 ]; then
    targets=("$@")
else
    targets=(scripts)
fi

status=0

# $1 = file  $2 = newline-separated `grep -n` output (maybe empty)
# $3 = reason
report() {
    local file="$1" hits="$2" reason="$3" ln
    [ -z "$hits" ] && return 0
    while IFS= read -r ln; do
        [ -z "$ln" ] && continue
        echo "$file:${ln%%:*}: $reason"
        status=1
    done <<<"$hits"
}

check_file() {
    local f="$1" resolved hits

    resolved="$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")"
    [ "$resolved" = "$SELF_RESOLVED" ] && return 0

    hits="$(grep -n -F '+=("${' "$f" 2>/dev/null | grep -v -F '[@]+' || true)"
    report "$f" "$hits" 'unguarded array append -- +=("${...}") with no [@]+ guard; bash 3.2 throws "unbound variable" under set -u when the array is empty'

    hits="$(grep -n -F 'declare -A' "$f" 2>/dev/null || true)"
    report "$f" "$hits" 'declare -A (associative array) requires bash >= 4'

    hits="$(grep -n -E '(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)' "$f" 2>/dev/null || true)"
    report "$f" "$hits" 'mapfile/readarray requires bash >= 4'

    hits="$(grep -n -E '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^)[A-Za-z_]*\}' "$f" 2>/dev/null || true)"
    report "$f" "$hits" 'case-conversion expansion (,, or ^^) requires bash >= 4'

    hits="$(grep -n -F '&>>' "$f" 2>/dev/null || true)"
    report "$f" "$hits" '&>> (append-both redirection) requires bash >= 4'

    hits="$(grep -n -F '|&' "$f" 2>/dev/null || true)"
    report "$f" "$hits" '|& (pipe-both shorthand) requires bash >= 4'
}

while IFS= read -r f; do
    [ -z "$f" ] && continue
    check_file "$f"
done < <(
    for t in "${targets[@]}"; do
        if [ -d "$t" ]; then
            find "$t" -type f
        elif [ -f "$t" ]; then
            printf '%s\n' "$t"
        fi
    done
)

exit "$status"
