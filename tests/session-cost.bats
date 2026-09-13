#!/usr/bin/env bats
#
# session-cost.bats -- scripts/session-cost.py measures one Claude Code
# session transcript so the token diet can be compared before/after.
#
# The fixture is a hand-built 12-line transcript that exercises every
# column once: a SessionStart hook attachment (20 rendered bytes) before
# the first typed prompt, a UserPromptSubmit hook attachment (10 bytes),
# an assistant message split over two lines sharing message.id (usage must
# be counted once, tool_use words never), a tool_result user entry, a
# turn-ending message whose "?" sits in the first sentence (pass), a
# teammate-message wrapper notice that wakes the assistant, a second typed
# prompt, and a final message with a thinking block and a "?" outside the
# first sentence (fail).

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/session-cost.py"
FIXTURE="$REPO_ROOT/tests/fixtures/session-cost/tiny.jsonl"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

# Collapses a table row to single-space-separated cells.
squash() { echo $1; }

@test "session-cost: fixture is exactly 12 lines of json" {
    [ "$(wc -l < "$FIXTURE")" -eq 12 ]
    run python3 -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1])]' "$FIXTURE"
    [ "$status" -eq 0 ]
}

@test "session-cost: session table has every column with the hand-counted numbers" {
    run python3 "$SCRIPT" "$FIXTURE"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    [ "$(squash "${lines[0]}")" = "typed asst_msgs out_tok cache_read_tok wake wrappers hook_bytes asst_words q_pass q_fail" ]
    # 2 typed turns; 4 assistant messages (m1 spans two lines);
    # out 10+5+3+7; cache_read 100+200+300+400; 1 wake; 1 wrapper;
    # hook bytes 20+10; words 4+7+1+9; qfirst 1 pass / 1 fail
    [ "$(squash "${lines[2]}")" = "2 4 25 1000 1 1 30 21 1 1" ]
}

@test "session-cost: --per-turn gives one row per typed turn plus a total" {
    run python3 "$SCRIPT" --per-turn "$FIXTURE"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 5 ]
    [ "$(squash "${lines[0]}")" = "turn line typed asst_msgs out_tok cache_read_tok wake wrappers hook_bytes asst_words q_pass q_fail" ]
    # turn 1 (line 2): m1+m2+m3, the SessionStart bytes fold into it, the wake and its wrapper land here
    [ "$(squash "${lines[2]}")" = "1 2 1 3 18 600 1 1 30 12 1 0" ]
    # turn 2 (line 10): m4 only, thinking words excluded, "?" not in the first sentence
    [ "$(squash "${lines[3]}")" = "2 10 1 1 7 400 0 0 0 9 0 1" ]
    [ "$(squash "${lines[4]}")" = "total 2 4 25 1000 1 1 30 21 1 1" ]
}

@test "session-cost: never prints transcript content" {
    run python3 "$SCRIPT" --per-turn "$FIXTURE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Hello there"* ]]
    [[ "$output" != *"Second question"* ]]
    [[ "$output" != *"teammate-message"* ]]
    [[ "$output" != *"thinking words"* ]]
}

@test "session-cost: usage without a path" {
    run python3 "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"session-cost.py <transcript.jsonl>"* ]]
}
