#!/usr/bin/env bats
#
# output-cap.bats -- acceptance contract for claude-orca-8a0.3 (slice C of
# the "three wins" epic). FROZEN from RED-AT onward.
#
# scripts/output-cap.sh is a PreToolUse hook on Bash that keeps a long
# command's output out of the ORCHESTRATOR's context: the main loop's Bash
# calls are rewritten (hookSpecificOutput.updatedInput, the tier-gate.sh
# precedent) to spill stdout+stderr into a file and print only the first
# CLAUDE_ORCA_OUTPUT_CAP bytes plus one line naming the file. Subagents are
# never touched -- a worker's whole job is to read the full output and
# return a summary.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAP="$REPO_ROOT/scripts/output-cap.sh"
SETTINGS="$REPO_ROOT/config/claude-settings.json"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    OUTDIR="$BATS_TEST_TMPDIR/outcap"
    export OUTDIR
    CAPBYTES=6000
}

# The hook, with the slice's two env knobs. Payload arrives on stdin.
cap_hook() {
    env CLAUDE_ORCA_OUTPUT_DIR="$OUTDIR" \
        CLAUDE_ORCA_OUTPUT_CAP="$CAPBYTES" bash "$CAP"
}

# A main-loop Bash payload (no agent_id key at all -- the real v2.1.220
# shape, see delegation-gate.bats).
main_payload() {
    jq -cn --arg c "$1" '{tool_name:"Bash",session_id:"sess-1",tool_input:{command:$c}}'
}

new_command() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.updatedInput.command'
}

@test "the output cap rewrites a main-loop Bash command to spill output past the cap into a file" {
    local orig new line path
    CAPBYTES=200
    orig='seq 1 500'
    run cap_hook <<<"$(main_payload "$orig")"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"'
    echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | type == "string"'
    new="$(new_command "$output")"
    [ "$new" != "$orig" ]
    [[ "$new" == *"$OUTDIR"* ]]

    run bash -c "$new"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[output capped at 200 bytes of "* ]]
    [[ "$output" == *"full output: $OUTDIR"* ]]
    # what the model sees is the cap plus one notice line, not all 500 lines
    [ "$(printf '%s\n' "$output" | wc -l)" -lt 120 ]
    [ "${output:0:4}" = "1
2
" ]

    line="$(printf '%s\n' "$output" | grep -o '\[output capped at .*\]')"
    path="${line##*full output: }"
    path="${path%]}"
    [ -f "$path" ]
    [ "$(wc -c < "$path")" -gt 200 ]
    [ "$(tail -n 1 "$path")" = "500" ]

    # Single quotes, a heredoc and an && chain all survive: the original
    # command is run FROM A FILE, never interpolated into the wrapper.
    orig="cat <<'HEREDOC' && echo \"it's fine\"
don't interpolate \$HOME
HEREDOC"
    run cap_hook <<<"$(main_payload "$orig")"
    [ "$status" -eq 0 ]
    new="$(new_command "$output")"
    run bash -c "$new"
    [ "$status" -eq 0 ]
    [[ "$output" == *"don't interpolate \$HOME"* ]]
    [[ "$output" == *"it's fine"* ]]
}

@test "the output cap leaves subagent, background and already-capped commands alone" {
    local c
    CAPBYTES=100

    # A subagent's Bash call: never rewritten, at any size.
    run cap_hook <<<"$(jq -cn '{tool_name:"Bash",session_id:"sess-2",agent_id:"a1",agent_type:"scout",tool_input:{command:"seq 1 500"}}')"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # Backgrounded: its output is collected elsewhere, and a wrapper would
    # make the tool watch the wrapper instead of the command.
    run cap_hook <<<"$(jq -cn '{tool_name:"Bash",session_id:"sess-2",tool_input:{command:"seq 1 500",run_in_background:true}}')"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # Already bounded by the caller: capping a cap only hides the tail the
    # caller deliberately asked for.
    for c in "seq 1 500 | head -50" "ls -la /usr | tail -n 5" "grep -rn x . | wc -l"; do
        run cap_hook <<<"$(main_payload "$c")"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done

    # Opted out for this session.
    CAPBYTES=0
    run cap_hook <<<"$(main_payload "seq 1 500")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # Not a Bash call at all.
    CAPBYTES=100
    run cap_hook <<<"$(jq -cn '{tool_name:"Read",session_id:"sess-2",tool_input:{file_path:"/x"}}')"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # Malformed stdin fails open: a broken hook must never block a call.
    run cap_hook <<<'not json at all'
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # Nothing was spilled for any of them.
    [ ! -d "$OUTDIR" ]
}

@test "the output cap preserves the command exit code" {
    local new
    CAPBYTES=6000

    run cap_hook <<<"$(main_payload 'printf "boom\n" >&2; exit 7')"
    [ "$status" -eq 0 ]
    new="$(new_command "$output")"
    run bash -c "$new"
    [ "$status" -eq 7 ]
    [[ "$output" == *"boom"* ]]           # stderr is captured too
    [[ "$output" != *"output capped"* ]]  # under the cap: no notice line

    run cap_hook <<<"$(main_payload 'echo ok')"
    [ "$status" -eq 0 ]
    new="$(new_command "$output")"
    run bash -c "$new"
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

@test "claude settings register the output cap hook on Bash and set subagentPromptCacheTtl to 1h" {
    local cmd
    [ -f "$SETTINGS" ]
    run jq -e . "$SETTINGS"
    [ "$status" -eq 0 ]

    run jq -e '.subagentPromptCacheTtl == "1h"' "$SETTINGS"
    [ "$status" -eq 0 ]

    # On the Bash matcher, and AFTER the guards that were already there --
    # a denied call must never leave a spill file behind.
    run jq -e '
        (.hooks.PreToolUse[] | select(.matcher == "Bash") | [.hooks[].command]) as $c
        | ($c | map(test("output-cap")) | index(true)) as $i
        | ($c | map(test("contract-gate")) | index(true)) as $g
        | ($i != null) and ($g != null) and ($i > $g)' "$SETTINGS"
    [ "$status" -eq 0 ]

    # The command the settings name is a real, executable entry point.
    cmd="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash")
        | .hooks[].command | select(test("output-cap"))' "$SETTINGS")"
    [[ "$cmd" == *"bin/output-cap"* ]]
    [ -x "$REPO_ROOT/bin/output-cap" ]
    [ -x "$REPO_ROOT/scripts/output-cap.sh" ]
}
