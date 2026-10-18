#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Guards:   the route-prompt hook asks the guard once per prompt, prints one "[route] ..." line saying where the work should go, never blocks or leaks, and goes quiet when anything fails
# Fails if: the request loses its model/system prompt/previous reply, a level maps to the wrong lane, the confidence floor stops raising a level, a floor word or short follow-up still makes a call, a worker or "router": false still routes, a slow guard stalls the prompt, or the guard token reaches output or the log
# Run:      bats tests/route-prompt.bats

# Every case runs in a throwaway folder against a fake guard (tests/helpers/fake-guard.py)
# on a free loopback port, with fixture copies of the classifier and router config
# (CLAUDE_ORCA_ROUTE_CONFIG_DIR); no real key, no network, no model.

ROUTE="$BATS_TEST_DIRNAME/../bin/route-prompt"
FAKE_GUARD="$BATS_TEST_DIRNAME/helpers/fake-guard.py"
SETTINGS="$BATS_TEST_DIRNAME/../config/claude-settings.json"
FAKE_TOKEN="fake-guard-token-not-real"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  ROOT="$BATS_TEST_TMPDIR/folder"
  RUN="$ROOT/.claude-dev/run"
  CFG="$BATS_TEST_TMPDIR/routecfg"
  G="$BATS_TEST_TMPDIR/guard"
  TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
  mkdir -p "$HOME" "$RUN" "$CFG" "$G"
  export PROJECT_DIR="$ROOT" CLAUDE_ORCA_ROOT="$ROOT" CLAUDE_ORCA_ROUTE_CONFIG_DIR="$CFG"
  unset CLAUDE_ORCA_PROJECT_NAME OPENROUTER_BASE_URL CLAUDE_ORCA_ROUTE_BACKOFF_S
  # The bats shell itself may run inside a headless worker; this suite is an attended session.
  export CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ATTENDED=1
  export OPENROUTER_API_KEY="$FAKE_TOKEN"
  printf 'You are the fixture classifier. Reply with one JSON object.\n' > "$CFG/classifier.txt"
  write_router 2.5
  printf '{"top":"opus","worker":"sonnet","recon":"haiku","roles":{"worker":{"model":"sonnet"},"recon":{"model":"haiku"}}}\n' > "$RUN/tier.json"
  write_transcript
  GPID=""
}

teardown() {
  [ -z "$GPID" ] || kill "$GPID" 2>/dev/null || true
}

# write_router TIMEOUT_S: the fixture router.json (R1's real one is not touched).
write_router() {
  printf '{"model":"fixture/router-model","reasoning_off":true,"timeout_s":%s,"confidence_floor":0.6,"max_tokens":60}\n' "$1" > "$CFG/router.json"
}

# write_transcript [REPLY]: a small session log whose last real assistant text is REPLY.
write_transcript() {
  local reply="${1:-The helper lives in scripts/x.sh. Want me to rename it?}"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"earlier question"}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"OLDER REPLY"}]}}'
    jq -nc --arg r "$reply" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$r},{type:"tool_use",name:"Read",input:{}}]}}'
    printf '%s\n' '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"SIDECHAIN TEXT"}]}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"the current prompt"}}'
  } > "$TRANSCRIPT"
}

start_guard() {
  python3 "$FAKE_GUARD" --dir "$G" >"$G/out.txt" 2>&1 3>&- &
  GPID=$!
  local i
  for i in $(seq 1 50); do [ -s "$G/port" ] && break; sleep 0.1; done
  [ -s "$G/port" ]
  export OPENROUTER_BASE_URL="http://127.0.0.1:$(cat "$G/port")/api/v1"
}

# guard_config JSON: replace the fake guard's behaviour.
guard_config() { printf '%s\n' "$1" > "$G/config.json"; }

# reply LEVEL CONF [REASON]: the fake guard answers with a classifier JSON object.
reply() {
  local reason="${3:-because it is so}"
  guard_config "$(jq -nc --arg l "$1" --argjson c "$2" --arg r "$reason" \
    '{reply: ({level:$l,confidence:$c,reason:$r}|tojson), usage:{prompt_tokens:210,completion_tokens:19,cost:0.00004}}')"
}

n_requests() { if [ -f "$G/requests.jsonl" ]; then wc -l < "$G/requests.jsonl" | tr -d ' '; else echo 0; fi; }

# route PROMPT [SESSION]: run the hook with a UserPromptSubmit payload; $output is stdout, $stderr is stderr.
route() {
  jq -n --arg p "$1" --arg s "${2:-s1}" --arg t "$TRANSCRIPT" --arg c "$ROOT" \
    '{session_id:$s,hook_event_name:"UserPromptSubmit",transcript_path:$t,cwd:$c,prompt:$p}' > "$BATS_TEST_TMPDIR/in.json"
  run --separate-stderr "$ROUTE" < "$BATS_TEST_TMPDIR/in.json"
}

calls_log() { cat "$RUN/route/calls.log" 2>/dev/null || true; }

# ── the request ──────────────────────────────────────────────────────────────

@test "route-prompt: one POST to /chat/completions with the guard token, the router model, temperature 0 and reasoning off" {
  start_guard; reply build 0.9
  route "rename the helper foo to bar in scripts/x.sh"
  [ "$status" -eq 0 ]
  [ "$(n_requests)" = 1 ]
  req="$(head -n1 "$G/requests.jsonl")"
  [ "$(jq -r .path <<<"$req")" = "/api/v1/chat/completions" ]
  [ "$(jq -r .authorization <<<"$req")" = "Bearer $FAKE_TOKEN" ]
  [ "$(jq -r .body.model <<<"$req")" = "fixture/router-model" ]
  [ "$(jq -r .body.temperature <<<"$req")" = 0 ]
  [ "$(jq -r .body.max_tokens <<<"$req")" = 60 ]
  [ "$(jq -r .body.reasoning.enabled <<<"$req")" = false ]
}

@test "route-prompt: the system message is the classifier file and the user message is JSON with the prompt and the last assistant text" {
  start_guard; reply build 0.9
  route "rename the helper foo to bar in scripts/x.sh"
  req="$(head -n1 "$G/requests.jsonl")"
  [ "$(jq -r '.body.messages[0].role' <<<"$req")" = system ]
  [ "$(jq -r '.body.messages[0].content' <<<"$req")" = "$(cat "$CFG/classifier.txt")" ]
  [ "$(jq -r '.body.messages[1].role' <<<"$req")" = user ]
  user="$(jq -r '.body.messages[1].content' <<<"$req")"
  [ "$(jq -r .prompt <<<"$user")" = "rename the helper foo to bar in scripts/x.sh" ]
  [ "$(jq -r .previous_reply <<<"$user")" = "The helper lives in scripts/x.sh. Want me to rename it?" ]
  [ "$(jq -c 'keys' <<<"$user")" = '["previous_reply","prompt"]' ]
}

@test "route-prompt: a long prompt is cut to 2000 characters and a long previous reply to its last 1500" {
  start_guard; reply build 0.9
  write_transcript "$(printf 'H%.0s' $(seq 1 1000))$(printf 'T%.0s' $(seq 1 1500))"
  route "$(printf 'p%.0s' $(seq 1 2600))"
  user="$(head -n1 "$G/requests.jsonl" | jq -r '.body.messages[1].content')"
  [ "$(jq -r '.prompt | length' <<<"$user")" = 2000 ]
  [ "$(jq -r .previous_reply <<<"$user")" = "$(printf 'T%.0s' $(seq 1 1500))" ]
}

@test "route-prompt: the user's claude-orca.json routerModel replaces the router.json model" {
  start_guard; reply build 0.9
  printf '{"routerModel":"vendor/other-model"}\n' > "$ROOT/.claude-dev/claude-orca.json"
  route "rename the helper foo to bar in scripts/x.sh"
  [ "$(head -n1 "$G/requests.jsonl" | jq -r .body.model)" = "vendor/other-model" ]
}

#@@PART2@@
