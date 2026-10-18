#!/usr/bin/env bats
# Guards:   the prompt-router eval makes exactly the interface's call (model, temperature 0, classifier as system, trimmed user JSON, reasoning flag, guard token), applies the confidence floor, lists under-routes, and counts a bad reply as a failure instead of crashing; the committed eval set is well-formed
# Fails if: the request body drifts from the interface, a low-confidence reply is not bumped a level, an under-route goes unlisted, a non-JSON reply crashes the run, or a gold label in tests/fixtures/route/eval.jsonl is not answer/lookup/build/design
# Run:      bats tests/route-eval.bats

# Every case runs against a throwaway folder and a fake guard (tests/helpers/fake-guard.py)
# on a free loopback port; no real key, no network, no model.

EVAL="$BATS_TEST_DIRNAME/../scripts/route-eval.py"
FAKE_GUARD="$BATS_TEST_DIRNAME/helpers/fake-guard.py"
CLASSIFIER="$BATS_TEST_DIRNAME/../config/route/classifier.txt"
SET="$BATS_TEST_DIRNAME/fixtures/route/eval.jsonl"
FAKE_TOKEN="fake-guard-token-not-real"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  ROOT="$BATS_TEST_TMPDIR/folder"
  G="$BATS_TEST_TMPDIR/guard"
  mkdir -p "$HOME" "$ROOT/.claude-dev/run" "$G"
  export PROJECT_DIR="$ROOT" CLAUDE_ORCA_ROOT="$ROOT"
  unset OPENROUTER_BASE_URL
  export OPENROUTER_API_KEY="$FAKE_TOKEN"
  GPID=""
  python3 "$FAKE_GUARD" --dir "$G" >"$G/out.txt" 2>&1 3>&- &
  GPID=$!
  local i
  for i in $(seq 1 50); do [ -s "$G/port" ] && break; sleep 0.1; done
  [ -s "$G/port" ]
  URL="http://127.0.0.1:$(cat "$G/port")"
}

teardown() { [ -z "$GPID" ] || kill "$GPID" 2>/dev/null || true; }

guard_config() { printf '%s\n' "$1" > "$G/config.json"; }

# one_row GOLD [PROMPT] [PREV]: a one-row eval set at $BATS_TEST_TMPDIR/one.jsonl
one_row() {
  jq -nc --arg g "$1" --arg p "${2:-fix the typo in README}" --arg r "${3:-}" \
    '{prompt:$p, previous_reply:$r, gold:$g, why:"test"}' > "$BATS_TEST_TMPDIR/one.jsonl"
}

# evalrun [ARGS...]: route-eval against the fake guard on the one-row set.
evalrun() {
  run python3 -I "$EVAL" --set "$BATS_TEST_TMPDIR/one.jsonl" --models fake/model \
    --base-url "$URL" --root "$ROOT" "$@"
}

last_body() { tail -n 1 "$G/requests.jsonl" | jq -c '.body'; }

@test "the request is the interface's call: model, temperature 0, classifier as system, user JSON, reasoning off, guard token" {
  guard_config '{"reply":"{\"level\":\"build\",\"confidence\":0.9,\"reason\":\"clear fix\"}"}'
  one_row build "fix the typo in README" "Which file has the typo?"
  evalrun
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$G/requests.jsonl" | tr -d ' ')" = "1" ]
  [ "$(jq -r '.path' "$G/requests.jsonl")" = "/chat/completions" ]
  [ "$(jq -r '.authorization' "$G/requests.jsonl")" = "Bearer $FAKE_TOKEN" ]
  [ "$(last_body | jq -r '.model')" = "fake/model" ]
  [ "$(last_body | jq -r '.temperature')" = "0" ]
  [ "$(last_body | jq -r '.max_tokens')" = "100" ]
  [ "$(last_body | jq -r '.usage.include')" = "true" ]
  [ "$(last_body | jq -r '.reasoning.enabled')" = "false" ]
  [ "$(last_body | jq -r '.messages[0].role')" = "system" ]
  [ "$(last_body | jq -r '.messages[0].content')" = "$(cat "$CLASSIFIER")" ]
  [ "$(last_body | jq -r '.messages[1].role')" = "user" ]
  [ "$(last_body | jq -c '.messages[1].content | fromjson')" = '{"prompt":"fix the typo in README","previous_reply":"Which file has the typo?"}' ]
  [[ "$output" == *"accuracy 100.0% (1/1)"* ]]
  [[ "$output" != *"$FAKE_TOKEN"* ]]
}

@test "--reasoning default leaves the reasoning field out" {
  guard_config '{"reply":"{\"level\":\"build\",\"confidence\":0.9,\"reason\":\"x\"}"}'
  one_row build
  evalrun --reasoning default
  [ "$status" -eq 0 ]
  [ "$(last_body | jq 'has("reasoning")')" = "false" ]
}

@test "the user JSON carries the first 2000 chars of the prompt and the last 1500 of the previous reply" {
  guard_config '{"reply":"{\"level\":\"build\",\"confidence\":0.9,\"reason\":\"x\"}"}'
  local long prev
  long="$(head -c 2600 /dev/zero | tr '\0' 'p')"
  prev="$(head -c 1800 /dev/zero | tr '\0' 'a')$(head -c 1500 /dev/zero | tr '\0' 'z')"
  one_row build "$long" "$prev"
  evalrun
  [ "$status" -eq 0 ]
  [ "$(last_body | jq -r '.messages[1].content | fromjson | .prompt | length')" = "2000" ]
  [ "$(last_body | jq -r '.messages[1].content | fromjson | .previous_reply | length')" = "1500" ]
  [ "$(last_body | jq -r '.messages[1].content | fromjson | .previous_reply | test("^z+$")')" = "true" ]
}

@test "the confidence floor bumps a low-confidence reply one level up before scoring" {
  guard_config '{"reply":"{\"level\":\"answer\",\"confidence\":0.5,\"reason\":\"small\"}"}'
  one_row lookup
  evalrun --floor 0.6
  [ "$status" -eq 0 ]
  [[ "$output" == *"accuracy 100.0% (1/1)"* ]]
  evalrun --floor 0.4
  [ "$status" -eq 0 ]
  [[ "$output" == *"under-routes 1 (hard 0)"* ]]
}

@test "an under-route on a gold design prompt is listed, counted hard, and the best floor is named" {
  guard_config '{"reply":"{\"level\":\"build\",\"confidence\":0.9,\"reason\":\"looks small\"}"}'
  one_row design "build the whole thing"
  evalrun
  [ "$status" -eq 0 ]
  [[ "$output" == *"under-routes 1 (hard 1)"* ]]
  [[ "$output" == *"under row 1  gold design -> build"* ]]
  [[ "$output" == *"best floor (lowest with zero hard under-routes): 0.95"* ]]
}

@test "over-routes are listed only with --list-wrong" {
  guard_config '{"reply":"{\"level\":\"design\",\"confidence\":0.9,\"reason\":\"big\"}"}'
  one_row answer "what does ls -la show"
  evalrun
  [ "$status" -eq 0 ]
  [[ "$output" == *"over-routes 1"* ]]
  [[ "$output" != *"over  row 1"* ]]
  evalrun --list-wrong
  [[ "$output" == *"over  row 1  gold answer -> design"* ]]
}

@test "a reply that is not the JSON object, an HTTP 500, and an unknown level are failures, not crashes" {
  one_row build
  guard_config '{"reply":"I think it is a build"}'
  evalrun
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 scored, 1 failed"* ]]
  [[ "$output" == *"badreply"* ]]
  guard_config '{"status":500}'
  evalrun
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 scored, 1 failed"* ]]
  [[ "$output" == *"http500"* ]]
  guard_config '{"reply":"{\"level\":\"wizard\",\"confidence\":0.9,\"reason\":\"x\"}"}'
  evalrun
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 scored, 1 failed"* ]]
  [[ "$output" == *"badreply"* ]]
}

@test "a fenced reply with trailing text still parses, and usage becomes tokens and cost per call" {
  guard_config '{"reply":"```json\n{\"level\":\"build\",\"confidence\":0.9,\"reason\":\"x\"}\n```\n<|assistant|>","usage":{"prompt_tokens":100,"completion_tokens":10,"cost":0.00002}}'
  one_row build
  evalrun
  [ "$status" -eq 0 ]
  [[ "$output" == *"accuracy 100.0% (1/1)"* ]]
  [[ "$output" == *"tokens in/out 100/10"* ]]
  [[ "$output" == *'$/call 0.000020'* ]]
}

@test "--out writes one JSON line per call and never the token" {
  guard_config '{"reply":"{\"level\":\"build\",\"confidence\":0.9,\"reason\":\"x\"}"}'
  one_row build
  evalrun --runs 2 --out "$BATS_TEST_TMPDIR/calls.jsonl"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/calls.jsonl" | tr -d ' ')" = "2" ]
  [ "$(jq -r '.level' "$BATS_TEST_TMPDIR/calls.jsonl" | sort -u)" = "build" ]
  run grep -c "$FAKE_TOKEN" "$BATS_TEST_TMPDIR/calls.jsonl"
  [ "$output" = "0" ]
}

@test "the committed eval set: every row has string prompt and previous_reply and a gold in the four levels, all four present" {
  [ -s "$SET" ]
  run jq -e -s 'all(.[]; (.prompt|type)=="string" and (.previous_reply|type)=="string" and ((.gold)|IN("answer","lookup","build","design")))' "$SET"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.gold' "$SET" | sort -u | tr '\n' ' ')" = "answer build design lookup " ]
}

@test "a set with an invalid gold label, or no rows, or a missing file exits 2 without calling the guard" {
  printf '%s\n' '{"prompt":"x","previous_reply":"","gold":"wizard"}' > "$BATS_TEST_TMPDIR/bad.jsonl"
  run python3 -I "$EVAL" --set "$BATS_TEST_TMPDIR/bad.jsonl" --models fake/model --base-url "$URL" --root "$ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"gold"* ]]
  : > "$BATS_TEST_TMPDIR/empty.jsonl"
  run python3 -I "$EVAL" --set "$BATS_TEST_TMPDIR/empty.jsonl" --models fake/model --base-url "$URL" --root "$ROOT"
  [ "$status" -eq 2 ]
  run python3 -I "$EVAL" --set "$BATS_TEST_TMPDIR/nope.jsonl" --models fake/model --base-url "$URL" --root "$ROOT"
  [ "$status" -eq 2 ]
  [ ! -e "$G/requests.jsonl" ]
}

@test "the classifier names all four levels and the JSON reply shape" {
  [ -s "$CLASSIFIER" ]
  run grep -c -E 'answer|lookup|build|design' "$CLASSIFIER"
  [ "$output" -ge 4 ]
  run grep -q '"confidence"' "$CLASSIFIER"
  [ "$status" -eq 0 ]
}
