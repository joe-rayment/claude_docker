#!/usr/bin/env bash
#
# orca-hooks-merge.sh -- S6 (claude-orca-3sk.18). Orca shows what an agent
# is doing (working/waiting/done dots, sub-agent child rows, session
# history) through hook entries it installs into the REAL (unsandboxed)
# home's .claude/settings.json. The sandboxed agent runs with its own
# CLAUDE_CONFIG_DIR and never loads that file, so the wrapper carries
# Orca's entries over on every launch -- see .claude/plans/orca-port.md
# S3.5.
#
# Usage: orca-hooks-merge --real-home <dir> --config-dir <dir>
#
# Runs HOST SIDE (before the sandbox is entered), after config-sync has
# written <config dir>/settings.json.
#
# What it does, idempotently:
#   * copies Orca's MANAGED hook entries -- identity: the hook command
#     mentions ~/.orca/agent-hooks/ (claude-hook.sh; matches Orca's own
#     createManagedCommandMatcher, which keys on the script path, not on
#     an exact command string) -- from <real home>/.claude/settings.json
#     into <config dir>/settings.json, for the 12 events Orca registers
#     (src/main/claude/hook-settings.ts CLAUDE_EVENTS): SessionStart,
#     UserPromptSubmit, Stop, StopFailure, SubagentStart, SubagentStop,
#     TeammateIdle, PreToolUse, PostToolUse, PostToolUseFailure,
#     PermissionRequest, PostCompact.
#   * drops managed entries that are no longer in Orca's settings (Orca
#     uninstalled, or its hooks toggled off) -- from every event, not just
#     those 12, so a retired event name cannot strand an entry.
#   * never touches a non-Orca entry, and never imports a host-side hook
#     the user owns (only managed entries cross the boundary).
#   * chains the statusline: Orca's claude-statusline.sh runs first, its
#     output is prefixed to ours ($HOST/template/bin/statusline, whatever
#     config-sync put in the slot). Our original command is remembered in
#     <config dir>/.orca-statusline-base so a later launch can un-chain it
#     when Orca's statusline goes away, and so re-running never nests the
#     chain.
#
# Best-effort by design: Orca integration is cosmetic, so a missing or
# unparseable file on either side is a no-op (exit 0), never a launch
# failure. Exit 2 is reserved for invalid arguments.
#
# bash 3.2 clean (macOS /bin/bash) -- see scripts/lint-bash32.sh.

set -euo pipefail

NEEDLE="/.orca/agent-hooks/"
ORCA_EVENTS_JSON='["SessionStart","UserPromptSubmit","Stop","StopFailure","SubagentStart","SubagentStop","TeammateIdle","PreToolUse","PostToolUse","PostToolUseFailure","PermissionRequest","PostCompact"]'

die() {
    echo "orca-hooks-merge: $1" >&2
    exit 2
}

warn() {
    echo "orca-hooks-merge: $1" >&2
}

REAL_HOME=""
CONFIG_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --real-home)  REAL_HOME="${2:-}"; shift 2 ;;
        --config-dir) CONFIG_DIR="${2:-}"; shift 2 ;;
        --help|-h)
            echo "Usage: orca-hooks-merge --real-home <dir> --config-dir <dir>"
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$REAL_HOME" ]  || die "--real-home is required"
[ -n "$CONFIG_DIR" ] || die "--config-dir is required"

command -v jq >/dev/null 2>&1 || { warn "jq not found -- skipping Orca hook merge"; exit 0; }

SRC="$REAL_HOME/.claude/settings.json"
DEST="$CONFIG_DIR/settings.json"
BASE_FILE="$CONFIG_DIR/.orca-statusline-base"

# Nothing to merge into: config-sync hasn't run yet, or the file is not
# ours to rewrite because it isn't valid JSON.
[ -f "$DEST" ] || exit 0
if ! jq -e . "$DEST" >/dev/null 2>&1; then
    warn "$DEST is not valid JSON -- skipping"
    exit 0
fi

# Orca gone / never installed / broken file: treat as "no managed entries",
# which is exactly what removes ours below.
SRC_JSON='{}'
if [ -f "$SRC" ] && jq -e . "$SRC" >/dev/null 2>&1; then
    SRC_JSON="$(cat "$SRC")"
fi

TMP="$DEST.orca-merge.$$"
trap 'rm -f "$TMP"' EXIT

# --- hooks ---------------------------------------------------------------

printf '%s' "$SRC_JSON" > "$TMP.src"
if ! jq \
        --arg n "$NEEDLE" \
        --argjson events "$ORCA_EVENTS_JSON" \
        --slurpfile orca "$TMP.src" '
    def is_managed($n):
        (((.hooks // []) | map(.command // "") | any(contains($n)))
         or ((.command // "") | contains($n)));
    (($orca[0] // {}).hooks // {}) as $oh
    | .hooks = (
        ((.hooks // {})
         | with_entries(.value |= (if type == "array"
                                   then map(select(is_managed($n) | not))
                                   else . end)))
        | reduce ($events[]) as $e (.;
            .[$e] = ((.[$e] // []) + (($oh[$e] // []) | map(select(is_managed($n))))))
        | with_entries(select((.value | type) != "array" or (.value | length) > 0))
      )
' "$DEST" > "$TMP" 2>/dev/null; then
    warn "merge failed -- leaving $DEST untouched"
    rm -f "$TMP.src"
    exit 0
fi
rm -f "$TMP.src"

# --- statusLine ----------------------------------------------------------

orca_statusline="$(printf '%s' "$SRC_JSON" | jq -r '.statusLine.command // ""')"
current="$(jq -r '.statusLine.command // ""' "$TMP")"

chained_now=0
case "$current" in *"$NEEDLE"*) chained_now=1 ;; esac

ours=""
if [ "$chained_now" -eq 0 ]; then
    ours="$current"
elif [ -f "$BASE_FILE" ]; then
    ours="$(cat "$BASE_FILE")"
fi

set_statusline() {
    jq --arg c "$1" \
        '.statusLine = ((.statusLine // {}) + {type: "command", command: $c})' \
        "$TMP" > "$TMP.sl" && mv "$TMP.sl" "$TMP"
}

case "$orca_statusline" in
    *"$NEEDLE"*)
        if [ -n "$ours" ]; then
            # One stdin payload, two consumers: Claude Code feeds the
            # session JSON on stdin, so it is captured once and replayed
            # to each. Orca's script is opportunistic (usage reporting),
            # so its stderr is dropped and its output only prefixes ours
            # when it produced any.
            chained="__orca_in=\$(cat); __orca_out=\$(printf '%s' \"\$__orca_in\" | { $orca_statusline ; } 2>/dev/null); if [ -n \"\$__orca_out\" ]; then printf '%s ' \"\$__orca_out\"; fi; printf '%s' \"\$__orca_in\" | { $ours ; }"
            set_statusline "$chained"
            printf '%s' "$ours" > "$BASE_FILE"
        elif [ "$chained_now" -eq 1 ]; then
            warn "statusline is already chained but $BASE_FILE is missing -- leaving it as is"
        fi
        ;;
    *)
        # Orca's statusline is gone: put ours back and forget the base.
        if [ "$chained_now" -eq 1 ] && [ -n "$ours" ]; then
            set_statusline "$ours"
        fi
        rm -f "$BASE_FILE"
        ;;
esac

# --- publish -------------------------------------------------------------

mv "$TMP" "$DEST"
trap - EXIT
exit 0
