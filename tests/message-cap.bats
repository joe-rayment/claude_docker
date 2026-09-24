#!/usr/bin/env bats
# message-cap.bats -- claude-orca-uod: the msg-cap readout in
# python/cost-mirror.py's UserPromptSubmit line ("msg: last Nw (cap C) ·
# over X/Y"), plus the rulebook's matching cap number (lockstep). FROZEN
# once committed red (RED-AT); a case found wrong here is reported, never
# edited.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
COST_MIRROR="$REPO_ROOT/python/cost-mirror.py"
USER_MEMORY="$REPO_ROOT/config/claude-user-memory.md"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cost-mirror-state"
    FIXTURE="$BATS_TEST_TMPDIR/transcript.jsonl"
}

# N space-separated filler words.
words() { printf 'w %.0s' $(seq 1 "$1"); }

# One well-formed assistant jsonl row: message.id, word count, isSidechain.
# Always carries real usage too, so scan_session's own (unrelated) token
# counting has something to report and the [cost-mirror] line prints.
asst_line() {
    local mid="$1" n="$2" side="${3:-false}"
    jq -cn --arg id "$mid" --arg text "$(words "$n")" --argjson side "$side" \
        '{type:"assistant", isSidechain:$side,
          message:{id:$id, model:"claude-sonnet-4-5",
                    usage:{input_tokens:5, output_tokens:5},
                    content:[{type:"text", text:$text}]},
          timestamp:"2026-09-15T00:00:00Z"}'
}

run_hook() {
    jq -cn --arg tp "$1" '{transcript_path:$tp, session_id:"test"}' \
        | python3 "$COST_MIRROR"
}

@test "message-cap: cap default in cost-mirror.py matches the rulebook's number (lockstep)" {
    default="$(grep -oE 'MSG_CAP_DEFAULT = [0-9]+' "$COST_MIRROR" | grep -oE '[0-9]+')"
    [ -n "$default" ]
    run grep -F "${default} words" "$USER_MEMORY"
    [ "$status" -eq 0 ]
}

@test "message-cap: last message 300 words -> segment reports 300 over cap 100" {
    asst_line "m1" 300 > "$FIXTURE"
    run run_hook "$FIXTURE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"300"* ]]
    [[ "$output" == *"100"* ]]
    [[ "$output" == *"over 1/1"* ]]
}

@test "message-cap: last message 80 words -> within budget, over 0" {
    asst_line "m1" 80 > "$FIXTURE"
    run run_hook "$FIXTURE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"80"* ]]
    [[ "$output" == *"over 0/1"* ]]
}

@test "message-cap: a sidechain message following a top-level one is ignored" {
    { asst_line "m1" 80 false; asst_line "m2" 500 true; } > "$FIXTURE"
    run run_hook "$FIXTURE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"last 80w"* ]]
    [[ "$output" != *"500"* ]]
    [[ "$output" == *"over 0/1"* ]]
}

@test "message-cap: one message split across several jsonl lines is counted once, words summed" {
    { asst_line "m1" 30 false; asst_line "m1" 20 false; } > "$FIXTURE"
    run run_hook "$FIXTURE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"last 50w"* ]]
    [[ "$output" == *"over 0/1"* ]]
}

@test "message-cap: a malformed transcript line fails the msg segment open, the rest of the line still prints" {
    { asst_line "m1" 80 false; echo 'not valid json{{{'; } > "$FIXTURE"
    run run_hook "$FIXTURE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[cost-mirror]"* ]]
    [[ "$output" != *"msg:"* ]]
}
