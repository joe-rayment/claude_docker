#!/usr/bin/env bats
# Guards: the main session takes an off-ramp at 40% context and stops (full notice once, then a one-line reminder, tool calls refused from 45% except bd/git/offramp) or compacts-and-continues by mode (refused from 60% only if it never compacts); a recorded handoff is pointed at the next session start.
# Fails if: the main loop past 40% gets no notice or the full notice twice, a sub-agent payload is metered, output_tokens inflate the count, the refusal blocks a bd/git/offramp command, or the CLI prints a changed text or writes the wrong mode file.
# Run: bats tests/offramp.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/offramp.sh"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    ROOT="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$ROOT/.claude-dev/run"
    printf '{}\n' > "$ROOT/.claude-dev/claude-orca.json"
    S="$BATS_TEST_TMPDIR/s"
    mkdir -p "$S"
    : > "$S/sess.jsonl"
    TRANS="$S/sess.jsonl"
    MODE_FILE="$ROOT/.claude-dev/run/offramp.json"
    PAYLOAD="$(main_payload)"
}

# usage_row input cache_read cache_creation output [model] -- one assistant
# transcript row carrying a usage object, appended to the main transcript.
usage_row() {
    local input="$1" cache_read="$2" cache_creation="$3" output="$4" model="${5:-claude-haiku-4-5}"
    jq -cn --argjson input "$input" --argjson cr "$cache_read" --argjson cc "$cache_creation" \
        --argjson output "$output" --arg model "$model" \
        '{type:"assistant", message:{model:$model, usage:{input_tokens:$input, cache_read_input_tokens:$cr, cache_creation_input_tokens:$cc, output_tokens:$output}}}' >> "$TRANS"
}

main_payload() {
    jq -cn --arg s "$TRANS" '{tool_name:"Bash", transcript_path:$s}'
}

# pre_payload <tool_name> [command] -- a hook payload, with a Bash command
# when one is given.
pre_payload() {
    if [ $# -ge 2 ]; then
        jq -cn --arg s "$TRANS" --arg t "$1" --arg c "$2" \
            '{tool_name:$t, tool_input:{command:$c}, transcript_path:$s}'
    else
        jq -cn --arg s "$TRANS" --arg t "$1" '{tool_name:$t, transcript_path:$s}'
    fi
}

set_mode() {
    printf '{"mode":"%s"}\n' "$1" > "$MODE_FILE"
}

# offramp <--post|--pre> [ENVVAR=val ...] -- runs the pinned script exactly
# as the WORKER RULES require: env -i, an isolated HOME and TMPDIR,
# CLAUDE_ORCA_ROOT pointing at the temp project, stdin carrying $PAYLOAD.
offramp() {
    local mode="$1"; shift
    run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR/h" TMPDIR="$BATS_TEST_TMPDIR" \
        CLAUDE_ORCA_ROOT="$ROOT" "$@" bash "$SCRIPT" "$mode" <<<"$PAYLOAD"
}

# offramp_cli <CLI args...> -- same environment for the CLI surface.
offramp_cli() {
    run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR/h" TMPDIR="$BATS_TEST_TMPDIR" \
        CLAUDE_ORCA_ROOT="$ROOT" bash "$SCRIPT" "$@"
}

post_ctx() {
    echo "$output" | jq -r '.hookSpecificOutput.additionalContext'
}

pre_reason() {
    echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason'
}

# --- the exact contract texts, at the values the tests use ------------------

NO_COMPACT="(mode is continue, but this session has no auto-compaction -- it started before that setting -- so it stops instead; a new session compacts.)"

full_stop_text() { # $1 = pct; $2 = "fallback" inserts the NO-COMPACT line as line 2
    local pct="$1" nc="" nl='
'
    [ "${2:-}" = "fallback" ] && nc="$NO_COMPACT$nl"
    cat <<EOF
[off-ramp] this session's context is at ${pct}% of its window -- past the 40% off-ramp (mode: stop). Take the off-ramp now; start nothing new:
${nc}1. Finish only the step in hand and commit it.
2. Save a HANDOFF to the bead you are working on (bd create one if the work has none): bd update <id> --notes "HANDOFF / done: ... / left: ... / facts: ... / next: ..."
3. Run: offramp handoff <id>
4. End your turn with one message to the user that starts "Off-ramp: context is at ${pct}%, so I stopped." -- then what is finished, what is left, the bead id, and: "Type /clear, then resume to carry on -- or /offramp continue to let the session compact itself and keep going."
From 45% every tool call except bd, git and offramp is refused.
EOF
}

reminder_text() { # $1 = pct
    printf '[off-ramp] context at %s%% (off-ramp 40%%): save the HANDOFF, run offramp handoff <id>, and end your turn telling the user why you stopped.' "$1"
}

full_continue_text() { # $1 = pct (continue mode, AT=40, compact=50)
    cat <<EOF
[off-ramp] this session's context is at ${1}% of its window -- past the 40% off-ramp (mode: continue). Save your place now, then keep working:
1. Finish the step in hand and commit it.
2. Save a HANDOFF to the bead you are working on (bd create one if the work has none): bd update <id> --notes "HANDOFF / done: ... / left: ... / facts: ... / next: ..."
3. Run: offramp handoff <id>
4. Carry on with the work. The session compacts itself at about 50% and resumes from that bead; keep the HANDOFF current as you go.
EOF
}

refusal_stop_text() { # $1 = pct; $2 = "fallback" appends the NO-COMPACT line
    local pct="$1" nc=""
    [ "${2:-}" = "fallback" ] && nc="
$NO_COMPACT"
    cat <<EOF
[off-ramp] context is at ${pct}% -- past the 45% stop line (mode: stop): only bd, git and offramp commands run now. Save the HANDOFF (bd update <id> --notes "HANDOFF ..."; offramp handoff <id>), then end your turn with a message to the user that starts "Off-ramp: context is at ${pct}%, so I stopped." and tells them to type /clear, then resume.${nc}
EOF
}

refusal_continue_text() { # $1 = pct
    cat <<EOF
[off-ramp] context is at ${1}% -- past the 60% backstop and the session has not compacted (mode: continue): only bd, git and offramp commands run now. Save the HANDOFF (bd update <id> --notes "HANDOFF ..."; offramp handoff <id>), then end your turn with a message to the user that starts "Off-ramp: context is at ${1}%, so I stopped." and tells them to type /compact or /clear, then resume.
EOF
}

switch_stop_text() {
    printf 'off-ramp mode: stop -- at 40%% context the session saves a HANDOFF to its bead and stops, saying why; /clear, then resume to carry on.'
}

switch_continue_text() { # $1 = "" when compaction is on, "off" when off
    local text
    text='off-ramp mode: continue -- at 40% context the session saves a HANDOFF to its bead and keeps going; it compacts itself at about 50% and resumes from the bead.'
    [ "${1:-}" = "off" ] && text="$text This session has no auto-compaction (it started before that setting), so it will still stop; new sessions compact."
    printf '%s' "$text"
}

resume_text() { # $1 = bead, $2 = mode
    printf '[off-ramp] the previous context ended at the off-ramp; its HANDOFF is in bead %s. Run bd show %s and continue from its "left:" line -- do not redo "done:". (mode: %s)' "$1" "$1" "$2"
}

@test "1 sub-agent payload (agent_id set) at 90%: --post and --pre are silent" {
    usage_row 180000 0 0 0
    PAYLOAD="$(jq -cn --arg s "$TRANS" '{tool_name:"Bash", agent_id:"a1", transcript_path:$s}')"
    offramp --post
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    offramp --pre
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "2 main loop at 39% (78000 tokens): --post and --pre are silent" {
    usage_row 78000 0 0 0
    offramp --post
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    offramp --pre
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# Guards:   the full stop notice appears once per session; after it, the
#           same --post only reminds -- until the context drops back below
#           the off-ramp, which clears the marker and arms the full text
#           again.
# Fails if: the reminder repeats the whole text, the marker survives a drop
#           below the threshold, or the drop itself prints.
# Run:      bats -f 'full stop notice' tests/offramp.bats
@test "3 stop mode at 41%: --post prints the FULL stop text once, then the REMINDER; a drop to 30% re-arms it" {
    usage_row 82000 0 0 0
    offramp --post
    [ "$status" -eq 0 ]
    [ "$(post_ctx)" = "$(full_stop_text 41)" ]
    case "$(post_ctx)" in *"mode: stop"*) ;; *) false ;; esac
    case "$(post_ctx)" in *"Off-ramp: context is at 41%, so I stopped."*) ;; *) false ;; esac

    offramp --post
    [ "$status" -eq 0 ]
    [ "$(post_ctx)" = "$(reminder_text 41)" ]

    usage_row 60000 0 0 0
    offramp --post
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    usage_row 82000 0 0 0
    offramp --post
    [ "$status" -eq 0 ]
    [ "$(post_ctx)" = "$(full_stop_text 41)" ]
}

@test "4 stop mode --pre: 44% silent; 45% denies a Read and Bash ls, allows bd/git/offramp first words" {
    usage_row 88000 0 0 0
    PAYLOAD="$(pre_payload Bash 'ls')"
    offramp --pre
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    usage_row 90000 0 0 0

    PAYLOAD="$(pre_payload Read)"
    offramp --pre
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
    [ "$(pre_reason)" = "$(refusal_stop_text 45)" ]

    for cmd in 'bd update x --notes y' 'git commit -m z' '  offramp handoff x'; do
        PAYLOAD="$(pre_payload Bash "$cmd")"
        offramp --pre
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done

    PAYLOAD="$(pre_payload Bash 'ls')"
    offramp --pre
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
    case "$(pre_reason)" in *"past the 45% stop line (mode: stop)"*) ;; *) false ;; esac
}

@test "5 continue mode with compaction env: FULL continue text once ('about 50%'), 2nd --post silent; --pre backstops at 60%" {
    set_mode continue
    usage_row 82000 0 0 0
    offramp --post CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50
    [ "$status" -eq 0 ]
    [ "$(post_ctx)" = "$(full_continue_text 41)" ]
    case "$(post_ctx)" in *"about 50%"*) ;; *) false ;; esac

    offramp --post CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    usage_row 118000 0 0 0
    PAYLOAD="$(pre_payload Bash 'ls')"
    offramp --pre CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    usage_row 120000 0 0 0
    offramp --pre CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
    [ "$(pre_reason)" = "$(refusal_continue_text 60)" ]
}

@test "6 continue mode without compaction: --post prints the FULL stop text with the NO-COMPACT line as line 2; --pre denies at 45%" {
    set_mode continue
    usage_row 82000 0 0 0
    offramp --post
    [ "$status" -eq 0 ]
    [ "$(post_ctx)" = "$(full_stop_text 41 fallback)" ]
    [ "$(sed -n '2p' <<<"$(post_ctx)")" = "$NO_COMPACT" ]

    usage_row 90000 0 0 0
    PAYLOAD="$(pre_payload Bash 'ls')"
    offramp --pre
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
    [ "$(pre_reason)" = "$(refusal_stop_text 45 fallback)" ]
}

@test "7 claude-opus-5-5 has a native 1M window: 400000 tokens is 40% (notice), 390000 is 39% (silent)" {
    usage_row 400000 0 0 0 claude-opus-5-5
    offramp --post
    [ "$status" -eq 0 ]
    [ "$(post_ctx)" = "$(full_stop_text 40)" ]

    usage_row 390000 0 0 0 claude-opus-5-5
    offramp --post
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "8 claude-haiku-4-5 stays on 200k: 80000 tokens is 40% (notice)" {
    usage_row 80000 0 0 0 claude-haiku-4-5
    offramp --post
    [ "$status" -eq 0 ]
    [ "$(post_ctx)" = "$(full_stop_text 40)" ]
}

@test "9 CLAUDE_CODE_DISABLE_1M_CONTEXT=1 clamps opus to 200k: 80000 tokens is 40% (notice)" {
    usage_row 80000 0 0 0 claude-opus-5-5
    offramp --post CLAUDE_CODE_DISABLE_1M_CONTEXT=1
    [ "$status" -eq 0 ]
    [ "$(post_ctx)" = "$(full_stop_text 40)" ]
}

@test "10 CLAUDE_ORCA_OFFRAMP_WINDOW overrides the lookup: 40000/100000 is 40% (notice)" {
    usage_row 40000 0 0 0
    offramp --post CLAUDE_ORCA_OFFRAMP_WINDOW=100000
    [ "$status" -eq 0 ]
    [ "$(post_ctx)" = "$(full_stop_text 40)" ]
}

@test "11 output_tokens are excluded: 10000 input with 500000 output stays silent" {
    usage_row 10000 0 0 500000
    offramp --post
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "12 a [1m] model suffix widens the window: claude-sonnet-4-6[1m] at 400000 is 40% (notice)" {
    usage_row 400000 0 0 0 'claude-sonnet-4-6[1m]'
    offramp --post
    [ "$status" -eq 0 ]
    [ "$(post_ctx)" = "$(full_stop_text 40)" ]
}

@test "13 CLAUDE_ORCA_OFFRAMP_AT=0 turns the hook modes off: silent at 99%" {
    usage_row 198000 0 0 0
    offramp --post CLAUDE_ORCA_OFFRAMP_AT=0
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    offramp --pre CLAUDE_ORCA_OFFRAMP_AT=0
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "14 fails open: garbage stdin exits 0 silently" {
    PAYLOAD="not json at all"
    offramp --post
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    offramp --pre
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "15 fails open: missing transcript is silent" {
    rm -f "$TRANS"
    offramp --post
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    offramp --pre
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "16 CLI: offramp continue writes the mode file and prints the continue SWITCH text" {
    offramp_cli continue CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50
    [ "$status" -eq 0 ]
    [ "$(jq -r '.mode' "$MODE_FILE")" = "continue" ]
    [ "$output" = "$(switch_continue_text)" ]
}

@test "17 CLI: offramp status shows the mode, the compaction line and a pending handoff" {
    offramp_cli continue CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50
    offramp_cli handoff abc-1
    [ "$status" -eq 0 ]
    [ "$(jq -r '.pending.bead' "$MODE_FILE")" = "abc-1" ]

    offramp_cli status CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' <<<"$output")" = "off-ramp: mode continue -- at 40% context the session saves a HANDOFF to its bead and keeps going; tool calls are refused from 60% if it has not compacted." ]
    [ "$(sed -n '2p' <<<"$output")" = "compaction: at 50% of the window." ]
    case "$(sed -n '3p' <<<"$output")" in "pending handoff: abc-1 (since "*) ;; *) false ;; esac
    [ "$(sed -n '4p' <<<"$output")" = "switch: /offramp stop | /offramp continue" ]
}

# Guards:   a pending handoff recorded before /clear or a compaction is
#           announced exactly once, on the first SessionStart, and then
#           consumed -- the mode itself stays.
# Fails if: the RESUME repeats on a second start, the pending entry survives
#           it, or the mode is lost.
# Run:      bats -f 'RESUME once' tests/offramp.bats
@test "18 CLI: --session-start prints the RESUME naming the bead once, removes pending, keeps mode" {
    offramp_cli continue
    offramp_cli handoff abc-1

    offramp --session-start
    [ "$status" -eq 0 ]
    [ "$output" = "$(resume_text abc-1 continue)" ]

    offramp --session-start
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    [ "$(jq -r '.mode' "$MODE_FILE")" = "continue" ]
    [ "$(jq -r '.pending // empty' "$MODE_FILE")" = "" ]
}

@test "19 CLI: offramp stop prints the stop SWITCH text; status without compaction shows the off line" {
    offramp_cli stop
    [ "$status" -eq 0 ]
    [ "$output" = "$(switch_stop_text)" ]
    [ "$(jq -r '.mode' "$MODE_FILE")" = "stop" ]

    offramp_cli status
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' <<<"$output")" = "off-ramp: mode stop -- at 40% context the session saves a HANDOFF to its bead and stops, saying why; tool calls are refused from 45%." ]
    [ "$(sed -n '2p' <<<"$output")" = "compaction: off in this session -- one started after the settings change compacts at the configured percent." ]
    [ "$(sed -n '3p' <<<"$output")" = "switch: /offramp stop | /offramp continue" ]
}

@test "20 CLI rejects: offramp handoff 'a b' and offramp bogus exit 2 with usage on stderr" {
    offramp_cli handoff 'a b'
    [ "$status" -eq 2 ]

    offramp_cli bogus
    [ "$status" -eq 2 ]

    offramp_cli handoff
    [ "$status" -eq 2 ]
}

@test "21 bin/offramp is a relative symlink resolving to scripts/offramp.sh, executable" {
    link="$(readlink "$REPO_ROOT/bin/offramp")"
    [ "$link" = "../scripts/offramp.sh" ]
    [ -x "$REPO_ROOT/scripts/offramp.sh" ]
}
