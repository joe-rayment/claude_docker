#!/usr/bin/env bash
#
# offramp.sh -- the MAIN session's context off-ramp hook and CLI
# (claude-orca-ngq.1). The main Claude Code loop -- a hook payload with no
# agent_id -- meters its own transcript (input + cache_read +
# cache_creation tokens of the LAST assistant usage row; output_tokens are
# excluded, matching Claude Code's own "% context used") and takes an
# off-ramp from CLAUDE_ORCA_OFFRAMP_AT (default 40%) of its window on:
#
#   --post  injects the FULL text for the effective mode once per session
#           (a marker file keyed by the transcript path), then a one-line
#           REMINDER in stop mode; a drop back below the threshold deletes
#           the marker and re-arms the FULL text.
#   --pre   refuses every tool call past the mode's refusal line
#           (CLAUDE_ORCA_OFFRAMP_STOP_AT, default 45, in stop mode;
#           CLAUDE_ORCA_OFFRAMP_BACKSTOP_AT, default 60, in continue mode)
#           except Bash commands whose first word is bd, git or offramp.
#
# bin/offramp is the user-facing CLI: status, stop, continue, handoff
# <bead>. The mode lives in "$(run_dir)/offramp.json".
#
# Modes: stop (default) ends the turn with a HANDOFF in a bead; continue
# keeps working through the session's own auto-compaction (on iff
# CLAUDE_CODE_AUTO_COMPACT_WINDOW is a positive integer AND
# CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is an integer 1..100) -- a continue
# session without compaction configured falls back to stop and says so
# (the NO-COMPACT line). Sub-agents are context-meter's business: a
# payload carrying an agent_id exits 0 silently here. AT=0 turns every
# hook mode off.
#
# Fails open everywhere: no jq, unparsable stdin, a missing transcript or a
# bad setting all exit 0 with no output.

set -u

# Resolve through a symlink chain (bin/offramp -> ../scripts/offramp.sh) to
# this script's real directory, so lib/paths.sh resolves whether this is
# invoked via the repo copy or the .claude-dev/template/bin symlink.
_resolve_script_path() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        local link dir
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(case "$src" in (*/*) cd "${src%/*}/" ;; esac && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}
SCRIPT_DIR="$(_s="$(_resolve_script_path)"; case "$_s" in (*/*) cd "${_s%/*}/" ;; esac && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"

MODE="${1:-}"
case "$MODE" in
    --post|--pre|--session-start) ;;
    ''|status|stop|continue|handoff) ;;
    *)
        printf "usage: offramp [status] | offramp stop | offramp continue | offramp handoff <bead-id>\n" >&2
        exit 2
        ;;
esac

case "$MODE" in
    --*)
        command -v jq >/dev/null 2>&1 || exit 0
        ;;
    *)
        command -v jq >/dev/null 2>&1 || { printf 'off-ramp: jq is required\n' >&2; exit 1; }
        ;;
esac

# Settings, read from the environment (claude-orca-ngq's shared contract):
# a value that is not a non-negative integer falls back to its default.
is_nonneg_int() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

AT="${CLAUDE_ORCA_OFFRAMP_AT:-40}"
is_nonneg_int "$AT" || AT=40
STOP_AT="${CLAUDE_ORCA_OFFRAMP_STOP_AT:-45}"
is_nonneg_int "$STOP_AT" || STOP_AT=45
BACKSTOP_AT="${CLAUDE_ORCA_OFFRAMP_BACKSTOP_AT:-60}"
is_nonneg_int "$BACKSTOP_AT" || BACKSTOP_AT=60

# Compaction is ON iff CLAUDE_CODE_AUTO_COMPACT_WINDOW is a positive integer
# AND CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is an integer 1..100; prints that pct.
compaction_pct() {
    case "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${CLAUDE_CODE_AUTO_COMPACT_WINDOW}" -ge 1 ] || return 1
    case "${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE}" -ge 1 ] || return 1
    [ "${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE}" -le 100 ] || return 1
    printf '%s\n' "${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE}"
}

mode_file() {
    local rd
    rd="$(run_dir)" || return 1
    printf '%s\n' "$rd/offramp.json"
}

# Mode = file .mode if valid, else env CLAUDE_ORCA_OFFRAMP_MODE if
# "stop"/"continue", else "stop". Total: always prints a mode.
resolve_mode() {
    local f m
    f="$(mode_file 2>/dev/null)" || f=""
    if [ -n "$f" ] && [ -f "$f" ]; then
        m="$(jq -r '.mode // empty' "$f" 2>/dev/null)"
        case "$m" in
            stop|continue) printf '%s\n' "$m"; return 0 ;;
        esac
    fi
    m="${CLAUDE_ORCA_OFFRAMP_MODE:-}"
    case "$m" in
        stop|continue) printf '%s\n' "$m"; return 0 ;;
    esac
    printf 'stop\n'
}

# update_mode_file <jq args...> -- rewrites "$(run_dir)/offramp.json" by
# piping its current content ({} when absent or unparsable) through
# `jq "$@"`.
update_mode_file() {
    local rd f tmp base
    rd="$(run_dir 2>/dev/null)" || return 1
    f="$rd/offramp.json"
    mkdir -p "$rd" 2>/dev/null || return 1
    tmp="$f.tmp.$$"
    base="{}"
    [ -f "$f" ] && base="$(cat "$f" 2>/dev/null)"
    [ -n "$base" ] || base="{}"
    if printf '%s' "$base" | jq -c "$@" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv -f "$tmp" "$f" && return 0
    fi
    rm -f "$tmp" 2>/dev/null
    return 1
}

# The shared contract's EXACT TEXTS (claude-orca-ngq), byte for byte; ${1}
# is the context percentage. E/FALLBACK/COMPACT are set by resolve_e:
# FALLBACK=1 means mode=continue but compaction is OFF, so E=stop and the
# NO-COMPACT line rides along.
NO_COMPACT="(mode is continue, but this session has no auto-compaction -- it started before that setting -- so it stops instead; a new session compacts.)"
# Display fallback for {compact} when compaction is off: only the SWITCH
# continue text can show it (FULL/REFUSAL continue require compaction ON).
DEFAULT_COMPACT_DISPLAY=50

E=""
FALLBACK=0
COMPACT=""
resolve_e() {
    E="$(resolve_mode)"
    FALLBACK=0
    COMPACT="$(compaction_pct 2>/dev/null)" || COMPACT=""
    if [ "$E" = "continue" ] && [ -z "$COMPACT" ]; then
        E="stop"
        FALLBACK=1
    fi
}

full_for_e() {
    if [ "$E" = "continue" ]; then
        full_continue_text "$1"
    else
        full_stop_text "$1"
    fi
}

full_stop_text() {
    local pct="$1" nc=""
    [ "$FALLBACK" -eq 1 ] && nc="$NO_COMPACT
"
    cat <<EOF
[off-ramp] this session's context is at ${pct}% of its window -- past the ${AT}% off-ramp (mode: stop). Take the off-ramp now; start nothing new:
${nc}1. Finish only the step in hand and commit it.
2. Save a HANDOFF to the bead you are working on (bd create one if the work has none): bd update <id> --notes "HANDOFF / done: ... / left: ... / facts: ... / next: ..."
3. Run: offramp handoff <id>
4. End your turn with one message to the user that starts "Off-ramp: context is at ${pct}%, so I stopped." -- then what is finished, what is left, the bead id, and: "Type /clear, then resume to carry on -- or /offramp continue to let the session compact itself and keep going."
From ${STOP_AT}% every tool call except bd, git and offramp is refused.
EOF
}

full_continue_text() {
    local pct="$1"
    cat <<EOF
[off-ramp] this session's context is at ${pct}% of its window -- past the ${AT}% off-ramp (mode: continue). Save your place now, then keep working:
1. Finish the step in hand and commit it.
2. Save a HANDOFF to the bead you are working on (bd create one if the work has none): bd update <id> --notes "HANDOFF / done: ... / left: ... / facts: ... / next: ..."
3. Run: offramp handoff <id>
4. Carry on with the work. The session compacts itself at about ${COMPACT}% and resumes from that bead; keep the HANDOFF current as you go.
EOF
}

reminder_text() {
    printf '[off-ramp] context at %s%% (off-ramp %s%%): save the HANDOFF, run offramp handoff <id>, and end your turn telling the user why you stopped.' "$1" "$AT"
}

refusal_for_e() {
    if [ "$E" = "continue" ]; then
        refusal_continue_text "$1"
    else
        refusal_stop_text "$1"
    fi
}

refusal_stop_text() {
    local pct="$1" nc=""
    [ "$FALLBACK" -eq 1 ] && nc="
$NO_COMPACT"
    cat <<EOF
[off-ramp] context is at ${pct}% -- past the ${STOP_AT}% stop line (mode: stop): only bd, git and offramp commands run now. Save the HANDOFF (bd update <id> --notes "HANDOFF ..."; offramp handoff <id>), then end your turn with a message to the user that starts "Off-ramp: context is at ${pct}%, so I stopped." and tells them to type /clear, then resume.${nc}
EOF
}

refusal_continue_text() {
    local pct="$1"
    cat <<EOF
[off-ramp] context is at ${pct}% -- past the ${BACKSTOP_AT}% backstop and the session has not compacted (mode: continue): only bd, git and offramp commands run now. Save the HANDOFF (bd update <id> --notes "HANDOFF ..."; offramp handoff <id>), then end your turn with a message to the user that starts "Off-ramp: context is at ${pct}%, so I stopped." and tells them to type /compact or /clear, then resume.
EOF
}

resume_text() {
    printf '[off-ramp] the previous context ended at the off-ramp; its HANDOFF is in bead %s. Run bd show %s and continue from its "left:" line -- do not redo "done:". (mode: %s)' "$1" "$1" "$2"
}

emit_post() {
    jq -n --arg t "$1" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$t}}' 2>/dev/null || exit 0
}

emit_pre_deny() {
    jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null || exit 0
}

# hook_context -- reads the hook payload and the main transcript, sets PCT.
# Any gap (bad stdin, sub-agent payload, missing transcript, no usage row)
# exits 0 silently: fail open.
IN=""
TRANSCRIPT_PATH=""
PCT=0
hook_context() {
    IN="$(cat 2>/dev/null)" || exit 0
    [ -n "$IN" ] || exit 0

    # Main loop only -- a populated agent_id is a sub-agent (context-meter's);
    # absence -- or an empty string -- means the main loop.
    AGENT_ID="$(printf '%s' "$IN" | jq -r '.agent_id // empty' 2>/dev/null)" || exit 0
    [ -z "$AGENT_ID" ] || exit 0

    TRANSCRIPT_PATH="$(printf '%s' "$IN" | jq -r '.transcript_path // empty' 2>/dev/null)" || exit 0
    [ -n "$TRANSCRIPT_PATH" ] || exit 0

    # The LAST row with .type=="assistant" and a .message.usage object. Only
    # the tail is read -- this must stay cheap on a long-running transcript.
    ROW="$(tail -n 400 "$TRANSCRIPT_PATH" 2>/dev/null | jq -c 'select(.type=="assistant" and (.message.usage? != null))' 2>/dev/null | tail -n 1)" || exit 0
    [ -n "$ROW" ] || exit 0

    TOKENS="$(printf '%s' "$ROW" | jq -r '
        (.message.usage.input_tokens // 0) +
        (.message.usage.cache_read_input_tokens // 0) +
        (.message.usage.cache_creation_input_tokens // 0)
    ' 2>/dev/null)" || exit 0
    is_nonneg_int "$TOKENS" || exit 0

    MODEL="$(printf '%s' "$ROW" | jq -r '.message.model // empty' 2>/dev/null)" || MODEL=""

    WINDOW="${CLAUDE_ORCA_OFFRAMP_WINDOW:-0}"
    is_nonneg_int "$WINDOW" || WINDOW=0
    if [ "$WINDOW" -le 0 ]; then
        WINDOW=200000
        case "${CLAUDE_CODE_DISABLE_1M_CONTEXT:-}" in
            ''|0|false)
                case "$MODEL" in
                    *'[1m]'*|claude-opus-4-7*|claude-opus-4-8*|claude-opus-5*|claude-sonnet-5*|claude-fable-5*) WINDOW=1000000 ;;
                esac
                ;;
        esac
    fi
    PCT=$(( TOKENS * 100 / WINDOW ))
}

do_post() {
    [ "$AT" -eq 0 ] && exit 0
    hook_context
    resolve_e
    local marker_dir marker
    marker_dir="${TMPDIR:-/tmp}/claude-orca-offramp"
    marker="$marker_dir/${TRANSCRIPT_PATH//\//_}"
    if [ "$PCT" -lt "$AT" ]; then
        rm -f "$marker" 2>/dev/null
        exit 0
    fi
    if [ ! -e "$marker" ]; then
        mkdir -p "$marker_dir" 2>/dev/null && : > "$marker" 2>/dev/null
        emit_post "$(full_for_e "$PCT")"
    elif [ "$E" = "stop" ]; then
        emit_post "$(reminder_text "$PCT")"
    fi
    exit 0
}

do_pre() {
    [ "$AT" -eq 0 ] && exit 0
    hook_context
    resolve_e
    local line
    if [ "$E" = "stop" ]; then line="$STOP_AT"; else line="$BACKSTOP_AT"; fi
    [ "$PCT" -lt "$line" ] && exit 0

    local tool cmd first rest
    tool="$(printf '%s' "$IN" | jq -r '.tool_name // empty' 2>/dev/null)" || tool=""
    if [ "$tool" = "Bash" ]; then
        cmd="$(printf '%s' "$IN" | jq -r '.tool_input.command // empty' 2>/dev/null)" || cmd=""
        first=""
        if [ -n "$cmd" ]; then
            read -r first rest <<<"$cmd" || :
        fi
        case "$first" in
            bd|git|offramp) exit 0 ;;
        esac
    fi
    emit_pre_deny "$(refusal_for_e "$PCT")"
    exit 0
}

do_session_start() {
    [ "$AT" -eq 0 ] && exit 0
    cat >/dev/null 2>&1 || :
    local f bead m
    f="$(mode_file 2>/dev/null)" || exit 0
    [ -n "$f" ] && [ -f "$f" ] || exit 0
    bead="$(jq -r '.pending.bead // empty' "$f" 2>/dev/null)" || exit 0
    [ -n "$bead" ] || exit 0
    m="$(resolve_mode)"
    # Remove .pending, keep the mode.
    update_mode_file 'del(.pending)' || exit 0
    printf '%s\n' "$(resume_text "$bead" "$m")"
    exit 0
}

usage() {
    printf 'usage: offramp [status]\n       offramp stop | offramp continue\n       offramp handoff <bead-id>\n' >&2
}

cli_status() {
    local m f bead ts
    m="$(resolve_mode)"
    if [ "$m" = "stop" ]; then
        printf 'off-ramp: mode stop -- at %s%% context the session saves a HANDOFF to its bead and stops, saying why; tool calls are refused from %s%%.\n' "$AT" "$STOP_AT"
    else
        printf 'off-ramp: mode continue -- at %s%% context the session saves a HANDOFF to its bead and keeps going; tool calls are refused from %s%% if it has not compacted.\n' "$AT" "$BACKSTOP_AT"
    fi
    if COMPACT="$(compaction_pct 2>/dev/null)"; then
        printf 'compaction: at %s%% of the window.\n' "$COMPACT"
    else
        printf 'compaction: off in this session -- one started after the settings change compacts at the configured percent.\n'
    fi
    f="$(mode_file 2>/dev/null)" || f=""
    if [ -n "$f" ] && [ -f "$f" ]; then
        bead="$(jq -r '.pending.bead // empty' "$f" 2>/dev/null)" || bead=""
        if [ -n "$bead" ]; then
            ts="$(jq -r '.pending.at // empty' "$f" 2>/dev/null)" || ts=""
            printf 'pending handoff: %s (since %s)\n' "$bead" "$ts"
        fi
    fi
    printf 'switch: /offramp stop | /offramp continue\n'
    exit 0
}

cli_switch() { # $1 = stop|continue
    # jq filter: $m is a jq variable, not a shell one
    # shellcheck disable=SC2016
    update_mode_file --arg m "$1" '.mode = $m' \
        || { printf 'off-ramp: could not write the mode file\n' >&2; exit 1; }
    if [ "$1" = "stop" ]; then
        printf 'off-ramp mode: stop -- at %s%% context the session saves a HANDOFF to its bead and stops, saying why; /clear, then resume to carry on.\n' "$AT"
    else
        local compact append=""
        if ! compact="$(compaction_pct 2>/dev/null)"; then
            compact="$DEFAULT_COMPACT_DISPLAY"
            append=" This session has no auto-compaction (it started before that setting), so it will still stop; new sessions compact."
        fi
        printf 'off-ramp mode: continue -- at %s%% context the session saves a HANDOFF to its bead and keeps going; it compacts itself at about %s%% and resumes from the bead.%s\n' "$AT" "$compact" "$append"
    fi
    exit 0
}

cli_handoff() { # $1 = bead id
    [ $# -eq 1 ] || { usage; exit 2; }
    printf '%s' "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$' || { usage; exit 2; }
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # jq filter: $b/$t are jq variables, not shell ones. The mode is left
    # as it is -- a handoff never pins an env-derived mode into the file.
    # shellcheck disable=SC2016
    update_mode_file --arg b "$1" --arg t "$ts" \
        '.pending = {bead:$b, at:$t}' \
        || { printf 'off-ramp: could not write the mode file\n' >&2; exit 1; }
    printf 'off-ramp: handoff recorded -- the next session (after /clear or a compaction) is pointed at bead %s.\n' "$1"
    exit 0
}

case "$MODE" in
    --post) do_post ;;
    --pre) do_pre ;;
    --session-start) do_session_start ;;
    ''|status) cli_status ;;
    stop|continue) cli_switch "$MODE" ;;
    handoff) shift; cli_handoff "$@" ;;
esac
exit 0
