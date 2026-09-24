#!/usr/bin/env bash
# rules-effective.sh — prints what a fresh user project actually loads:
# config/claude-user-memory.md (the file that ships, verbatim) plus the
# stdout of every SessionStart hook in config/claude-settings.json, run
# against a throwaway project (git init; bd init --skip-agents). Repo-local
# dev tool, not part of the shipped template. Integration probe for the
# "one rulebook" plan (no longer in the repo): green
# means a fix landed where a real project loads it, not just in this
# repo's own CLAUDE.md.
#
# Usage: rules-effective.sh [--project <dir>]
#   no args        fresh temp project, removed after
#   --project DIR  use (and keep) DIR, so a caller can plant fixtures (e.g.
#                  a drifted CLAUDE.md) before preparation runs
#
# MUST fail open (missing bd/jq/awk -> a smaller probe, never a failure;
# always exit 0).

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_MEMORY="$REPO_ROOT/config/claude-user-memory.md"
SETTINGS_JSON="$REPO_ROOT/config/claude-settings.json"
SCRIPTS_DIR="$REPO_ROOT/scripts"

PROJECT_DIR=""
OWN_PROJECT=1
while [ $# -gt 0 ]; do
    case "$1" in
        --project) PROJECT_DIR="${2:-}"; OWN_PROJECT=0; shift; [ $# -gt 0 ] && shift ;;
        *) shift ;;
    esac
done

BIN_DIR=""
cleanup() {
    [ -n "$BIN_DIR" ] && rm -rf "$BIN_DIR" 2>/dev/null
    [ "$OWN_PROJECT" = 1 ] && [ -n "$PROJECT_DIR" ] && rm -rf "$PROJECT_DIR" 2>/dev/null
    return 0
}
trap cleanup EXIT

if [ -z "$PROJECT_DIR" ]; then
    PROJECT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rules-effective.XXXXXX" 2>/dev/null) || exit 0
fi
mkdir -p "$PROJECT_DIR" 2>/dev/null

# 1. project preparation: git init, bd init --skip-agents. Fail-open at
# every step.
git -C "$PROJECT_DIR" init -q 2>/dev/null || true
git -C "$PROJECT_DIR" config user.email rules-effective@example.com 2>/dev/null || true
git -C "$PROJECT_DIR" config user.name rules-effective 2>/dev/null || true
if command -v bd >/dev/null 2>&1; then
    ( cd "$PROJECT_DIR" && bd init --prefix rex --quiet --non-interactive --skip-agents ) >/dev/null 2>&1 || true
fi

# 2. the rulebook, verbatim — config sync copies this file byte for byte to
# every project's config dir as CLAUDE.md.
cat "$USER_MEMORY" 2>/dev/null
echo

# 3. a PATH-prefix dir of symlinks, installed-name -> repo script, so every
# hook command below runs THIS working tree, never a stale installed copy.
BIN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rules-effective-bin.XXXXXX" 2>/dev/null) || BIN_DIR=""
if [ -n "$BIN_DIR" ]; then
    for pair in \
        tier-set:tier-set.sh tier-derive:tier-derive.sh tier-reconcile:tier-reconcile.sh \
        tier-gate:tier-gate.sh tier-prime:tier-prime.sh prime-memories:prime-memories.sh \
        lane:lane.sh workflow-lint:workflow-lint.sh cost-mirror:../python/cost-mirror.py \
        disk-cleanup:disk-cleanup.sh session-end-audit:session-end-audit.sh \
        bd-guard:bd-guard.sh outbound-guard:outbound-guard.sh context-detect:context-detect.sh \
        delegation-gate:../python/delegation-gate.py contract-gate:../python/contract-gate.py \
        code-map-prime:code-map-prime.sh code-map:code-map.sh csearch:csearch.sh dev-log:dev-log.sh
    do
        name="${pair%%:*}"; script="${pair#*:}"
        [ -f "$SCRIPTS_DIR/$script" ] && ln -sf "$SCRIPTS_DIR/$script" "$BIN_DIR/$name" 2>/dev/null
    done
fi

# 4. every SessionStart hook command, cwd = the temp project, state/side
# effects isolated from the real project (same pattern tests/tier-
# hooks.bats uses): CLAUDE_ORCA_ROOT/CLAUDE_CONFIG_DIR point every
# claude_orca_root()/claude_config_dir() consumer (lane, cost-mirror,
# tier-*, context-detect, disk-cleanup, ...) at the temp project instead of
# the real one — no real agents rewrite, no real pricing fetch, no real
# disk-cleanup sweep.
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS_JSON" ]; then
    while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        ( cd "$PROJECT_DIR" && \
          PATH="$BIN_DIR:$PATH" \
          CLAUDE_ORCA_ROOT="$PROJECT_DIR" \
          CLAUDE_CONFIG_DIR="$PROJECT_DIR/.claude" \
          WORKSPACE="$PROJECT_DIR" \
          COST_MIRROR_DISABLE=1 \
          timeout 10 bash -c "$cmd" )
    done < <(jq -r '.hooks.SessionStart[]?.hooks[]?.command // empty' "$SETTINGS_JSON" 2>/dev/null)
fi

# 5. whatever the preparation left in the project's own CLAUDE.md (bd's
# generated one, or — the drift class this bead exists to catch — a
# pre-existing one bd's push-mandatory block got injected into) is part of
# what that project actually loads too.
if [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
    echo
    echo "---- project CLAUDE.md ----"
    cat "$PROJECT_DIR/CLAUDE.md"
fi

exit 0
