#!/usr/bin/env bash
# context-detect — inject project-type-specific instructions at session start.
#
# Maps cheap filesystem markers in the workspace to context rule files
# (<name>.md) and prints whichever match to stdout. Wired as a SessionStart
# hook in claude-settings.json, so matched rules land in Claude's context;
# sessions in projects with no matching marker emit nothing and pay zero
# tokens. Deterministic on purpose: hard constraints ("never touch my
# database") must not depend on the model choosing to load a skill.
#
# Per-project override manifest: $WORKSPACE/.claude-dev/contexts
#   One context name per line ('#' comments and blank lines ignored).
#     snowflake     force-inject even when no marker matches
#     !snowflake    suppress even when a marker matches
#   Useful when detection can't work (project talks to Snowflake but nothing
#   in the tree says so) or when a marker misfires.
#
# Adding a context = drop <name>.md into the contexts dir and (optionally)
# add a detect_<name>() function below. A context with no detector is
# manifest-only.
#
# Env knobs (mainly for tests):
#   WORKSPACE      project root to scan             (default: claude_orca_root(), else $PWD)
#   CONTEXTS_DIR   directory holding <name>.md files (default: template_dir()/config/contexts)

set -u

# Resolve through a symlink chain (e.g. bin/context-detect -> ../scripts/
# context-detect.sh) to this script's real directory, so lib/paths.sh
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

WORKSPACE="${WORKSPACE:-$(claude_orca_root 2>/dev/null || pwd)}"
CONTEXTS_DIR="${CONTEXTS_DIR:-$(template_dir 2>/dev/null)/config/contexts}"
MANIFEST="$WORKSPACE/.claude-dev/contexts"

[ -d "$CONTEXTS_DIR" ] || exit 0

# --- detectors: detect_<name> returns 0 when the workspace matches ---------

detect_snowflake() {
    [ -f "$WORKSPACE/snowflake.yml" ] && return 0
    [ -f "$WORKSPACE/snowflake.yaml" ] && return 0
    # Dependency manifests naming snowflake/snowpark libs
    grep -qsil 'snowflake\|snowpark' \
        "$WORKSPACE"/requirements*.txt \
        "$WORKSPACE/pyproject.toml" \
        "$WORKSPACE/environment.yml" \
        "$WORKSPACE/Pipfile" \
        "$WORKSPACE/setup.py" \
        "$WORKSPACE/package.json" 2>/dev/null && return 0
    return 1
}

# --- driver -----------------------------------------------------------------

manifest_has() {
    # $1 = literal line to look for (e.g. "snowflake" or "!snowflake")
    [ -f "$MANIFEST" ] || return 1
    grep -qx "$1" "$MANIFEST" 2>/dev/null
}

emitted=0
for f in "$CONTEXTS_DIR"/*.md; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .md)

    if manifest_has "!$name"; then
        continue
    fi

    matched=1
    if manifest_has "$name"; then
        matched=0
    elif command -v "detect_$name" >/dev/null 2>&1 || type "detect_$name" >/dev/null 2>&1; then
        "detect_$name" && matched=0
    fi

    if [ "$matched" -eq 0 ]; then
        [ "$emitted" -eq 1 ] && echo ""
        cat "$f"
        emitted=1
    fi
done

# Manifest entries with no rules file are a config error worth surfacing,
# but only as a hook-log line — never injected into context.
if [ -f "$MANIFEST" ]; then
    grep -v '^[[:space:]]*#' "$MANIFEST" 2>/dev/null | grep -v '^[[:space:]]*$' | \
    sed 's/^!//' | while IFS= read -r want; do
        [ -f "$CONTEXTS_DIR/$want.md" ] || \
            echo "context-detect: no rules file for manifest entry '$want' in $CONTEXTS_DIR" >&2
    done
fi

exit 0
