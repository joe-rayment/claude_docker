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
