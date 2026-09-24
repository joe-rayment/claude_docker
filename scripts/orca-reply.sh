#!/usr/bin/env bash
#
# orca-reply.sh -- answer the question or escalation orca-wait handed back
# (claude-orca-qa2.13; plan .claude/plans/orca-orchestration.md).
#
#   orca-reply <msg_id> <text…>   [--from <handle>]
#
# The message id is the one in orca-wait's receipt (.msg_id). A worker
# blocked in `orchestration ask` unblocks the moment this lands, so a
# question costs the worker a wait, never a guess.
#
# One single-line JSON receipt on stdout; human notes on stderr.
# Exit 0 sent · 2 usage · 3 no reachable runtime · 4 the runtime refused.
#
# bash 3.2 clean (scripts/lint-bash32.sh scans all of scripts/).

set -uo pipefail

_resolve_script_path() {
    local src="${BASH_SOURCE[0]}" link dir
    while [ -L "$src" ]; do
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(case "$src" in (*/*) cd "${src%/*}/" ;; esac && pwd)"; src="$dir/$link" ;;
        esac
    done
    printf '%s' "$src"
}
SCRIPT_DIR="$(_s="$(_resolve_script_path)"; case "$_s" in (*/*) cd "${_s%/*}/" ;; esac && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/orca-orch.sh
. "$SCRIPT_DIR/lib/orca-orch.sh"

note() { printf '%s\n' "$*" >&2; }
die()  { printf 'orca-reply: %s\n' "$*" >&2; exit "${2:-2}"; }

MSG_ID=""; FROM=""; BODY=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --from) FROM="${2:-}"; shift ;;
        -h|--help) sed -n '3,14p' "$(_resolve_script_path)"; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown flag: $1" ;;
        *)  if [ -z "$MSG_ID" ]; then MSG_ID="$1"
            elif [ -z "$BODY" ]; then BODY="$1"
            else BODY="$BODY $1"; fi ;;
    esac
    shift
done
while [ "$#" -gt 0 ]; do
    if [ -z "$BODY" ]; then BODY="$1"; else BODY="$BODY $1"; fi
    shift
done

[ -n "$MSG_ID" ] || die "usage: orca-reply <msg_id> <text…>"
[ -n "$BODY" ] || die "usage: orca-reply <msg_id> <text…>"
command -v jq >/dev/null 2>&1 || die "jq is required"
orca_reachable || die "no Orca runtime is reachable" 3

ROOT="$(orch_root)" || ROOT=""
HANDLE="$(orch_handle "$FROM")"
if [ -z "$HANDLE" ] && [ -n "$ROOT" ]; then
    # No handle of our own: read whoever's record is bound to this folder
    # (the keyed file for an env handle was already used above; an empty
    # handle falls through to the legacy run.json, claude-orca-fyv).
    run_file="$(orch_run_state_file "$ROOT" "")"
    if [ -f "$run_file" ]; then
        HANDLE="$(jq -r '.coordinator_handle // ""' "$run_file")"
    fi
fi
FROM_ARGS=()
[ -n "$HANDLE" ] && FROM_ARGS=(--from "$HANDLE")

out="$(orca_call orchestration reply --id "$MSG_ID" --body "$BODY" \
    ${FROM_ARGS[@]+"${FROM_ARGS[@]}"} --json)" ||
    die "reply failed: $(orca_error "$out")" 4

note "replied to $MSG_ID"
jq -n -c --arg id "$MSG_ID" --arg body "$BODY" \
    --arg rid "$(orca_field "$out" '.result.message.id')" \
    '{type: "reply", msg_id: $id, reply_id: $rid, body: $body, sent: true}'
