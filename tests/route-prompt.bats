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
  route "rename the helper foo to bar in $(printf 'p%.0s' $(seq 1 2600))"
  user="$(head -n1 "$G/requests.jsonl" | jq -r '.body.messages[1].content')"
  [ "$(jq -r '.prompt | length' <<<"$user")" = 2000 ]
  [ "$(jq -r '.prompt[0:12]' <<<"$user")" = "rename the h" ]
  [ "$(jq -r .previous_reply <<<"$user")" = "$(printf 'T%.0s' $(seq 1 1500))" ]
}

@test "route-prompt: the user's claude-orca.json routerModel replaces the router.json model" {
  start_guard; reply build 0.9
  printf '{"routerModel":"vendor/other-model"}\n' > "$ROOT/.claude-dev/claude-orca.json"
  route "rename the helper foo to bar in scripts/x.sh"
  [ "$(head -n1 "$G/requests.jsonl" | jq -r .body.model)" = "vendor/other-model" ]
}

# ── the line each level prints ───────────────────────────────────────────────

@test "route-prompt: answer prints lane express with the session answering inline" {
  start_guard; reply answer 0.95 "a plain question"
  route "what does the lane hook do when I send a prompt"
  [ "$status" -eq 0 ]
  [[ "$output" == "[route] answer (0.95) -> lane express; bulk: you, inline -- a plain question" ]]
}

@test "route-prompt: lookup prints lane express with one scout on the recon tier model" {
  start_guard; reply lookup 0.9
  route "where is the sshd supervisor retry loop defined"
  [[ "$output" == "[route] lookup (0.90) -> lane express; bulk: one scout (haiku) -- because it is so" ]]
}

@test "route-prompt: build prints lane standard with one executor on the worker tier model" {
  start_guard; reply build 0.9
  route "rename the helper foo to bar in scripts/x.sh"
  [[ "$output" == "[route] build (0.90) -> lane standard; bulk: one executor (sonnet) -- because it is so" ]]
}

@test "route-prompt: design prints lane deep with the session planning and executors taking slices" {
  start_guard; reply design 0.9
  route "we keep losing data on restart, figure out why and propose a fix"
  [[ "$output" == "[route] design (0.90) -> lane deep; bulk: you plan; executors (sonnet) take slices -- because it is so" ]]
}

@test "route-prompt: without tier.json the line still prints, just without model names" {
  start_guard; reply build 0.9
  rm -f "$RUN/tier.json"
  route "rename the helper foo to bar in scripts/x.sh"
  [[ "$output" == "[route] build (0.90) -> lane standard; bulk: one executor -- because it is so" ]]
}

# ── the confidence floor ─────────────────────────────────────────────────────

@test "route-prompt: a build below the confidence floor is raised to design and says so" {
  start_guard; reply build 0.40
  route "rename the helper foo to bar in scripts/x.sh"
  [[ "$output" == "[route] design (0.40) -> lane deep;"* ]]
  [[ "$output" == *"raised from build"* ]]
  [[ "$(calls_log)" == *" design level=design conf=0.40 "*"reason=raised"* ]]
}

@test "route-prompt: an answer below the floor is raised one step to lookup" {
  start_guard; reply answer 0.3
  route "what does the lane hook do when I send a prompt"
  [[ "$output" == "[route] lookup (0.30) -> lane express;"* ]]
  [[ "$output" == *"raised from answer"* ]]
}

@test "route-prompt: a design below the floor stays design and is not called raised" {
  start_guard; reply design 0.2
  route "we keep losing data on restart, figure out why and propose a fix"
  [[ "$output" == "[route] design (0.20) -> lane deep;"* ]]
  [[ "$output" != *"raised"* ]]
}

@test "route-prompt: a reply exactly at the floor is not raised" {
  start_guard; reply build 0.6
  route "rename the helper foo to bar in scripts/x.sh"
  [[ "$output" == "[route] build (0.60) -> lane standard;"* ]]
}

# ── no call needed ───────────────────────────────────────────────────────────

@test "route-prompt: a floor word routes to design with no call and logs floor" {
  start_guard; reply answer 0.99
  route "please audit the settings"
  [[ "$output" == "[route] design (1.00) -> lane deep;"* ]]
  [ "$(n_requests)" = 0 ]
  [[ "$(calls_log)" == *" floor level=design "*"reason=audit"* ]]
}

@test "route-prompt: a short follow-up keeps the last route without a new call" {
  start_guard; reply build 0.9
  route "rename the helper foo to bar in scripts/x.sh"
  [ "$(n_requests)" = 1 ]
  route "thanks"
  [ "$output" = "[route] build -> lane standard (kept from the last prompt)" ]
  [ "$(n_requests)" = 1 ]
  [[ "$(calls_log)" == *" kept level=build "* ]]
}

@test "route-prompt: a short prompt with no earlier route in the session is silent" {
  start_guard; reply build 0.9
  route "thanks"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(n_requests)" = 0 ]
  [[ "$(calls_log)" == *" skip "*"reason=no_state"* ]]
}

@test "route-prompt: a slash command keeps the last route and never calls" {
  start_guard; reply design 0.9
  route "we keep losing data on restart, figure out why and propose a fix"
  route "/plan the migration"
  [ "$output" = "[route] design -> lane deep (kept from the last prompt)" ]
  [ "$(n_requests)" = 1 ]
}

@test "route-prompt: a short question still gets classified" {
  start_guard; reply lookup 0.9
  route "where is it?"
  [ "$(n_requests)" = 1 ]
  [[ "$output" == "[route] lookup"* ]]
}

# ── when to stay out of the way ──────────────────────────────────────────────

@test "route-prompt: a headless worker (sdk-cli entrypoint) is silent, makes no call and logs nothing" {
  start_guard; reply build 0.9
  CLAUDE_CODE_ENTRYPOINT=sdk-cli route "rename the helper foo to bar in scripts/x.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(n_requests)" = 0 ]
  [ ! -e "$RUN/route/calls.log" ]
}

@test "route-prompt: an unattended session (CLAUDE_CODE_SESSION_ATTENDED=0) is silent and makes no call" {
  start_guard; reply build 0.9
  CLAUDE_CODE_SESSION_ATTENDED=0 route "rename the helper foo to bar in scripts/x.sh"
  [ -z "$output" ]
  [ "$(n_requests)" = 0 ]
  [ ! -e "$RUN/route/calls.log" ]
}

@test "route-prompt: \"router\": false in claude-orca.json turns the hook off" {
  start_guard; reply build 0.9
  printf '{"router":false}\n' > "$ROOT/.claude-dev/claude-orca.json"
  route "rename the helper foo to bar in scripts/x.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(n_requests)" = 0 ]
  [ ! -e "$RUN/route/calls.log" ]
}

@test "route-prompt: a missing classifier.txt is silent and makes no call" {
  start_guard; reply build 0.9
  rm "$CFG/classifier.txt"
  route "rename the helper foo to bar in scripts/x.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(n_requests)" = 0 ]
}

@test "route-prompt: a missing router.json is silent and makes no call" {
  start_guard; reply build 0.9
  rm "$CFG/router.json"
  route "rename the helper foo to bar in scripts/x.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(n_requests)" = 0 ]
}

@test "route-prompt: no guard token anywhere is silent and makes no call" {
  start_guard; reply build 0.9
  unset OPENROUTER_API_KEY
  route "rename the helper foo to bar in scripts/x.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(n_requests)" = 0 ]
}

@test "route-prompt: with no OPENROUTER_API_KEY the token comes from the run dir's openrouter-guard.token" {
  start_guard; reply build 0.9
  unset OPENROUTER_API_KEY
  printf '%s\n' "$FAKE_TOKEN" > "$RUN/openrouter-guard.token"
  route "rename the helper foo to bar in scripts/x.sh"
  [[ "$output" == "[route] build"* ]]
  [ "$(head -n1 "$G/requests.jsonl" | jq -r .authorization)" = "Bearer $FAKE_TOKEN" ]
}

@test "route-prompt: an empty or non-JSON stdin exits 0 with no output" {
  run --separate-stderr "$ROUTE" < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'this is not json' > "$BATS_TEST_TMPDIR/junk"
  run --separate-stderr "$ROUTE" < "$BATS_TEST_TMPDIR/junk"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "route-prompt: a non-loopback OPENROUTER_BASE_URL is never called, silent, logged non_loopback" {
  OPENROUTER_BASE_URL="http://192.0.2.1/api/v1" route "rename the helper foo to bar in scripts/x.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$(calls_log)" == *" fallback "*"reason=non_loopback"* ]]
}

# ── when the guard misbehaves ────────────────────────────────────────────────

@test "route-prompt: a guard slower than timeout_s is cut off in about timeout_s, silently, logged timeout" {
  start_guard
  write_router 1
  guard_config '{"delay_s":5,"reply":"{\"level\":\"build\",\"confidence\":0.9,\"reason\":\"slow\"}"}'
  start=$(date +%s)
  route "rename the helper foo to bar in scripts/x.sh"
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$elapsed" -le 2 ]
  [[ "$(calls_log)" == *" fallback "*"reason=timeout"* ]]
}

@test "route-prompt: an HTTP 500 is silent and logged http_500" {
  start_guard; guard_config '{"status":500}'
  route "rename the helper foo to bar in scripts/x.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$(calls_log)" == *" fallback "*"reason=http_500"* ]]
}

@test "route-prompt: a reply that is not JSON is silent and logged unparsable" {
  start_guard; guard_config '{"reply":"sorry"}'
  route "rename the helper foo to bar in scripts/x.sh"
  [ -z "$output" ]
  [[ "$(calls_log)" == *" fallback "*"reason=unparsable"* ]]
}

@test "route-prompt: an unknown level is silent and logged bad_level" {
  start_guard; reply nonsense 0.9
  route "rename the helper foo to bar in scripts/x.sh"
  [ -z "$output" ]
  [[ "$(calls_log)" == *" fallback "*"reason=bad_level"* ]]
}

@test "route-prompt: a JSON reply wrapped in a code fence is accepted" {
  start_guard
  guard_config "$(jq -nc --arg r $'```json\n{"level":"build","confidence":0.8,"reason":"fenced"}\n```' '{reply:$r}')"
  route "rename the helper foo to bar in scripts/x.sh"
  [[ "$output" == "[route] build (0.80) -> lane standard;"*"-- fenced" ]]
}

# ── backoff after repeated failures ──────────────────────────────────────────

@test "route-prompt: three failures in a row pause the calls; the fourth prompt makes no request and logs skip backoff" {
  start_guard; guard_config '{"status":500}'
  route "rename the helper foo to bar in scripts/x.sh"
  route "rename the helper foo to baz in scripts/x.sh"
  route "rename the helper foo to qux in scripts/x.sh"
  [ "$(n_requests)" = 3 ]
  route "rename the helper foo to quux in scripts/x.sh"
  [ -z "$output" ]
  [ "$(n_requests)" = 3 ]
  [[ "$(calls_log)" == *" skip "*"reason=backoff"* ]]
}

@test "route-prompt: a success between failures resets the count, so two more failures still do not pause" {
  start_guard; guard_config '{"status":500}'
  route "rename the helper foo to bar in scripts/x.sh"
  route "rename the helper foo to baz in scripts/x.sh"
  reply build 0.9
  route "rename the helper foo to qux in scripts/x.sh"
  [[ "$output" == "[route] build"* ]]
  guard_config '{"status":500}'
  route "rename the helper foo to quux in scripts/x.sh"
  route "rename the helper foo to corge in scripts/x.sh"
  reply build 0.9
  route "rename the helper foo to grault in scripts/x.sh"
  [[ "$output" == "[route] build"* ]]
  [ "$(n_requests)" = 6 ]
}

@test "route-prompt: after the backoff window the calls resume" {
  start_guard; guard_config '{"status":500}'
  export CLAUDE_ORCA_ROUTE_BACKOFF_S=1
  route "rename the helper foo to bar in scripts/x.sh"
  route "rename the helper foo to baz in scripts/x.sh"
  route "rename the helper foo to qux in scripts/x.sh"
  reply build 0.9
  sleep 1.2
  route "rename the helper foo to quux in scripts/x.sh"
  [[ "$output" == "[route] build"* ]]
  [ "$(n_requests)" = 4 ]
}

# ── nothing secret leaves ────────────────────────────────────────────────────

@test "route-prompt: the guard token never reaches stdout, stderr, the log or the route dir, even if the model repeats it" {
  start_guard; reply build 0.9 "the key is $FAKE_TOKEN ok"
  route "rename the helper foo to bar in scripts/x.sh"
  [[ "$output" == "[route] build"* ]]
  [[ "$output" != *"$FAKE_TOKEN"* ]]
  [[ "$stderr" != *"$FAKE_TOKEN"* ]]
  ! grep -rqF "$FAKE_TOKEN" "$RUN/route"
}

@test "route-prompt: a token typed into the prompt does not go out in the request body" {
  start_guard; reply build 0.9
  route "rename foo to bar and use $FAKE_TOKEN in scripts/x.sh"
  [ "$(n_requests)" = 1 ]
  ! grep -qF "$FAKE_TOKEN" <(jq -c .body "$G/requests.jsonl")
}

@test "route-prompt: the guard token is also absent from the log after a failed call" {
  start_guard; guard_config "$(jq -nc --arg t "$FAKE_TOKEN" '{status:500, raw:("error " + $t)}')"
  route "rename the helper foo to bar in scripts/x.sh"
  [ -z "$output" ]
  [[ "$stderr" != *"$FAKE_TOKEN"* ]]
  ! grep -rqF "$FAKE_TOKEN" "$RUN/route"
}

@test "route-prompt: calls.log holds outcome, level, model and timing but never the prompt text" {
  start_guard; reply build 0.9
  route "rename the helper foo to bar in scripts/x.sh"
  log="$(calls_log)"
  [ "$(printf '%s\n' "$log" | wc -l | tr -d ' ')" = 1 ]
  [[ "$log" == *" build level=build conf=0.90 model=fixture/router-model ms="*" ptok=210 ctok=19 cost=4e-05 "* ]]
  [[ "$log" != *"rename"* ]]
  [[ "$log" != *"scripts/x.sh"* ]]
}

# ── per-session memory and wiring ────────────────────────────────────────────

@test "route-prompt: the session's last route is saved with level, confidence and a timestamp" {
  start_guard; reply design 0.85
  route "we keep losing data on restart, figure out why and propose a fix" sess-9
  [ "$(jq -r .level "$RUN/route/sess-9.json")" = design ]
  [ "$(jq -r .confidence "$RUN/route/sess-9.json")" = 0.85 ]
  [[ "$(jq -r .at "$RUN/route/sess-9.json")" == 20* ]]
}

@test "route-prompt: two sessions keep separate last routes" {
  start_guard; reply design 0.9
  route "we keep losing data on restart, figure out why and propose a fix" sess-a
  reply answer 0.9
  route "what does the lane hook do when I send a prompt" sess-b
  route "ok" sess-a
  [[ "$output" == "[route] design -> lane deep (kept"* ]]
  route "ok" sess-b
  [[ "$output" == "[route] answer -> lane express (kept"* ]]
}

@test "route-prompt: it is wired as the UserPromptSubmit entry right after lane, as a no-op when the link is missing" {
  names="$(jq -r '.hooks.UserPromptSubmit[0].hooks[].command' "$SETTINGS")"
  lane_at="$(printf '%s\n' "$names" | grep -n '/bin/lane"' | head -n1 | cut -d: -f1)"
  route_at="$(printf '%s\n' "$names" | grep -n 'route-prompt' | head -n1 | cut -d: -f1)"
  [ -n "$lane_at" ] && [ -n "$route_at" ]
  [ "$route_at" -eq $((lane_at + 1)) ]
  cmd="$(printf '%s\n' "$names" | sed -n "${route_at}p")"
  re='^\[ -x "[^"]*/bin/route-prompt" \] && exec "[^"]*/bin/route-prompt"; exit 0$'
  [[ "$cmd" =~ $re ]]
}

@test "route-prompt: bin/route-prompt is a symlink to the script" {
  [ -L "$BATS_TEST_DIRNAME/../bin/route-prompt" ]
  [ "$(readlink "$BATS_TEST_DIRNAME/../bin/route-prompt")" = "../scripts/route-prompt.py" ]
  [ -x "$BATS_TEST_DIRNAME/../scripts/route-prompt.py" ]
}
