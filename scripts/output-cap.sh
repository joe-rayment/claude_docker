#!/usr/bin/env bash
#
# output-cap.sh -- PreToolUse hook (matcher: Bash), claude-orca-8a0.3.
#
# Keeps a long command's output out of the ORCHESTRATOR's context. A single
# `grep -rn` or a test run can drop tens of thousands of tokens into the
# main loop's transcript, where every later turn re-bills them. This hook
# rewrites the main loop's Bash command (hookSpecificOutput.updatedInput --
# the scripts/tier-gate.sh precedent) into a wrapper that:
#
#   * runs the ORIGINAL command from a file (`bash <file>`), so single
#     quotes, heredocs and && chains survive untouched -- nothing is ever
#     interpolated back into a shell string;
#   * sends stdout AND stderr to a spill file under
#     ${CLAUDE_ORCA_OUTPUT_DIR:-${TMPDIR:-/tmp}/claude-orca-output/<session>};
#   * prints the first CLAUDE_ORCA_OUTPUT_CAP bytes (default 6000) and,
#     only when it actually cut something, one line naming the spill file
#     so the next call can `grep`/`tail` the rest;
#   * exits with the original command's exit code.
#
# Never touches: a SUBAGENT's Bash call (reading the whole output and
# returning a summary is precisely a worker's job), a backgrounded call
# (the tool collects that output itself), a command the caller already
# bounded with `| head/tail/wc`, and anything at all when
# CLAUDE_ORCA_OUTPUT_CAP=0.
#
# Fails OPEN everywhere: no jq, malformed stdin, unwritable spill dir ->
# exit 0 with no output, and the command runs exactly as typed.
#
# Env:
#   CLAUDE_ORCA_OUTPUT_CAP   bytes to show (default 6000; 0 disables)
#   CLAUDE_ORCA_OUTPUT_DIR   spill directory (default under TMPDIR)

set -u

command -v jq >/dev/null 2>&1 || exit 0

CAP="${CLAUDE_ORCA_OUTPUT_CAP:-6000}"
case "$CAP" in
    ''|*[!0-9]*) exit 0 ;;   # not a number: fail open
    0) exit 0 ;;             # opted out for this session
esac

IN=$(cat 2>/dev/null) || exit 0
[ -n "$IN" ] || exit 0

TOOL=$(printf '%s' "$IN" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL" = "Bash" ] || exit 0

# Main loop only. A populated agent_id is the one positive subagent signal
# (see python/delegation-gate.py's is_main_loop() for the evidence).
AGENT=$(printf '%s' "$IN" | jq -r '.agent_id // empty' 2>/dev/null) || exit 0
[ -n "$AGENT" ] && exit 0

BG=$(printf '%s' "$IN" | jq -r '.tool_input.run_in_background // false' 2>/dev/null) || exit 0
[ "$BG" = "true" ] && exit 0

CMD=$(printf '%s' "$IN" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0

# Already bounded by the caller: capping a cap only hides the tail they
# deliberately asked for.
printf '%s' "$CMD" | grep -Eq '\|[[:space:]]*(head|tail|wc)([[:space:]][^|]*)?[[:space:]]*$' && exit 0

SESSION=$(printf '%s' "$IN" | jq -r '.session_id // "session"' 2>/dev/null) || exit 0
SESSION=$(printf '%s' "$SESSION" | tr -c 'A-Za-z0-9._-' '-')
[ -n "$SESSION" ] || SESSION=session

DIR="${CLAUDE_ORCA_OUTPUT_DIR:-${TMPDIR:-/tmp}/claude-orca-output/$SESSION}"
mkdir -p "$DIR" 2>/dev/null || exit 0

# A spill file per call. $$ plus the clock keeps two calls in the same
# second apart; the directory is per session already.
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
CMD_FILE="$DIR/cmd-$STAMP.sh"
OUT_FILE="$DIR/out-$STAMP.log"
RUN_FILE="$DIR/run-$STAMP.sh"

# The original command, byte for byte. printf '%s' (not echo, not a
# heredoc) is what keeps a trailing backslash or a leading -n intact.
printf '%s' "$CMD" > "$CMD_FILE" 2>/dev/null || exit 0

# The wrapper. It reads the command from CMD_FILE, so nothing of the
# user's text is ever re-parsed by this script or by the outer shell.
{
    printf '#!/usr/bin/env bash\n'
    printf '# claude-orca output cap (%s bytes). Full output: %s\n' "$CAP" "$OUT_FILE"
    printf 'bash %s > %s 2>&1\n' "'$CMD_FILE'" "'$OUT_FILE'"
    printf 'co_rc=$?\n'
    printf 'head -c %s %s\n' "$CAP" "'$OUT_FILE'"
    printf 'co_n=$(wc -c < %s | tr -d " ")\n' "'$OUT_FILE'"
    printf 'if [ "$co_n" -gt %s ]; then\n' "$CAP"
    printf '    printf "\\n[output capped at %%s bytes of %%s; full output: %%s]\\n" %s "$co_n" %s\n' \
        "$CAP" "'$OUT_FILE'"
    printf 'fi\n'
    printf 'exit $co_rc\n'
} > "$RUN_FILE" 2>/dev/null || exit 0
chmod +x "$RUN_FILE" 2>/dev/null

# Old spills are the session's own scrollback; a day is plenty.
find "$DIR" -maxdepth 1 -type f -mmin +1440 -delete >/dev/null 2>&1 || true

printf '%s' "$IN" | jq -c --arg c "bash '$RUN_FILE'" --arg cap "$CAP" --arg out "$OUT_FILE" '{
    systemMessage: ("output-cap: showing the first " + $cap + " bytes; full output in " + $out),
    hookSpecificOutput: {
        hookEventName: "PreToolUse",
        updatedInput: (.tool_input + {command: $c})
    }
}' 2>/dev/null || exit 0
exit 0
