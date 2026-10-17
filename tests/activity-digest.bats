#!/usr/bin/env bats
# Guards:   scripts/activity-digest.py condenses a folder's Claude sessions, executors/scouts and headless workers into one small JSON digest (who is running, what was asked, no secrets, capped size)
# Fails if: a tool result counts as the human's request, a finished source stays "running", a tool call changes the episode id, a secret key reaches the output, or the size cap is ignored
# Run:      bats tests/activity-digest.bats
#
# Every case builds its own folder from tests/fixtures/activity under
# $BATS_TEST_TMPDIR (PROJECT_DIR, CLAUDE_ORCA_ROOT and HOME all point there, so
# the real /workspace/claude-orca is never read) and pins the clock with --now,
# so a result never depends on when the test runs. Assertions are `[ ]`, never
# a bare `[[ ]]` (run-tests.sh).

NOW=2026-10-17T13:02:30Z

setup() {
  export TZ=UTC
  unset CLAUDE_CONFIG_DIR CLAUDE_ORCA_ACTIVITY_RUNNING_S CLAUDE_ORCA_ACTIVITY_KEEP_S \
    CLAUDE_ORCA_ACTIVITY_PENDING_S CLAUDE_ORCA_ACTIVITY_MAX_BYTES
  FX="$BATS_TEST_DIRNAME/fixtures/activity"
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/activity-digest.py"
  ROOT="$BATS_TEST_TMPDIR/proj"
  CDIR="$BATS_TEST_TMPDIR/claude"
  export PROJECT_DIR="$ROOT" CLAUDE_ORCA_ROOT="$ROOT" HOME="$BATS_TEST_TMPDIR/home"
  # Destructive helpers below only ever touch these; refuse anything else.
  case "$ROOT" in "$BATS_TEST_TMPDIR"/*) ;; *) return 1 ;; esac
  case "$CDIR" in "$BATS_TEST_TMPDIR"/*) ;; *) return 1 ;; esac
  SLUG=$(printf %s "$ROOT" | sed 's/[^A-Za-z0-9]/-/g')
  SDIR="$CDIR/projects/$SLUG"
  WDIR="$ROOT/.claude-dev/run/workers"
  mkdir -p "$ROOT/.claude-dev" "$CDIR/projects" "$HOME"
  cp -R "$FX/claude/projects/SLUG" "$SDIR"
  cp -R "$FX/run" "$ROOT/.claude-dev/run"
  # job-run1's recorded pid is 1; make it this test's own (certainly alive) pid.
  sed -i "s/\"pid\": *1\([,}]\)/\"pid\": $$\1/; s/\"pid\":1\([,}]\)/\"pid\":$$\1/" "$WDIR/job-run1/job.json"
  grep -q "\"pid\": *$$" "$WDIR/job-run1/job.json"
  touch -d '2026-10-17 13:02:10 UTC' "$WDIR/job-run1/log.jsonl"
  touch -d '2026-10-17 12:58:00 UTC' "$WDIR/job-done1/log.jsonl" "$WDIR/job-done1/job.json"
  J="$BATS_TEST_TMPDIR/out.json"
}

# digest_json [--now T] [extra args]: run the script, keep its stdout in $J.
digest_json() {
  local now="$NOW"
  if [ "${1:-}" = "--now" ]; then now="$2"; shift 2; fi
  run python3 -I "$SCRIPT" --json --root "$ROOT" --claude-dir "$CDIR" --now "$now" "$@"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$J"
  jq -e . "$J" >/dev/null
}

count()  { jq -r --arg id "$1" '[.sources[] | select(.id == $id)] | length' "$J"; }
ids()    { jq -r '[.sources[].id] | join(" ")' "$J"; }
field()  { jq -r --arg id "$1" ".sources[] | select(.id == \$id) | .$2" "$J"; }
append() { printf '%s\n' "$2" >>"$1"; }   # append one JSON line to a fixture copy

@test "sources come out running executors/workers first, then main, then finished newest-first" {
  digest_json
  [ "$(ids)" = "agent-aaaa1111 worker:job-run1 main-0001 agent-cccc3333 worker:job-done1 agent-bbbb2222" ]
  [ "$(field agent-aaaa1111 state)" = running ]
  [ "$(field worker:job-run1 state)" = running ]
  [ "$(field main-0001 state)" = running ]
  [ "$(field agent-cccc3333 state)" = finished ]
  [ "$(field worker:job-done1 state)" = finished ]
  [ "$(field agent-bbbb2222 state)" = finished ]
}

@test "kinds, titles, task and start times are read from the transcripts" {
  digest_json
  [ "$(field agent-aaaa1111 kind)" = executor ]
  [ "$(field agent-cccc3333 kind)" = scout ]
  [ "$(field worker:job-run1 kind)" = worker ]
  [ "$(field main-0001 kind)" = main ]
  [ "$(field agent-aaaa1111 title)" = "Implement retry in upload helper" ]
  [ "$(field agent-aaaa1111 task | cut -c1-18)" = "Add three attempts" ]
  [ "$(field worker:job-run1 started)" = 2026-10-17T13:00:30Z ]
  [ "$(field agent-aaaa1111 last)" = 2026-10-17T13:02:00Z ]
}

@test "the request is the newest human prompt: not a tool result, reminder, meta record, or older session" {
  digest_json
  [ "$(jq -r .request.session "$J")" = main-0001 ]
  [ "$(jq -r .request.at "$J")" = 2026-10-17T12:55:00Z ]
  [ "$(jq -r '.request.text | .[0:11]' "$J")" = "Add a retry" ]
  [ "$(grep -c 'Which file holds' "$J" || true)" -eq 0 ]
  [ "$(grep -c 'Say hello' "$J" || true)" -eq 0 ]
  [ "$(grep -c 'Caveat: the messages below' "$J" || true)" -eq 0 ]
  [ "$(count main-0000)" -eq 0 ]
}

@test "a finished worker's final text comes from its result line; a running one has none" {
  digest_json
  [ "$(field worker:job-done1 final | cut -c1-24)" = "Added --dry-run and thre" ]
  [ "$(field worker:job-run1 final)" = null ]
  [ "$(field agent-cccc3333 final | cut -c1-21)" = "Only scripts/upload.s" ]
  [ "$(field worker:job-done1 last)" = 2026-10-17T12:58:00Z ]
}

@test "clock: a pending command keeps an executor running; quiet finished sources age out" {
  digest_json --now 2026-10-17T13:07:00Z
  [ "$(field agent-aaaa1111 state)" = running ]
  digest_json --now 2026-10-17T13:08:00Z
  [ "$(count agent-bbbb2222)" -eq 0 ]
  [ "$(field agent-cccc3333 state)" = finished ]
  digest_json --now 2026-10-17T13:10:00Z
  [ "$(count agent-cccc3333)" -eq 0 ]
  [ "$(field agent-aaaa1111 state)" = running ]
}

@test "clock: far past every window the digest is empty, except a live worker, which stays running" {
  digest_json --now 2026-10-17T13:40:00Z
  [ "$(ids)" = "worker:job-run1" ]
  [ "$(field worker:job-run1 state)" = running ]
  sed -i 's/"state":"running"/"state":"failed"/' "$WDIR/job-run1/job.json"
  grep -q '"state":"failed"' "$WDIR/job-run1/job.json"
  digest_json --now 2026-10-17T13:40:00Z
  [ "$(jq -c .sources "$J")" = "[]" ]
  [ "$(jq -r .episode "$J")" != none ]
}

@test "a dead worker pid turns a 'running' job into a finished one" {
  sed -i "s/\"pid\": *$$/\"pid\": 999999/" "$WDIR/job-run1/job.json"
  grep -q '"pid": *999999' "$WDIR/job-run1/job.json"
  digest_json
  [ "$(field worker:job-run1 state)" = finished ]
}

@test "episode: a tool call and its result leave it unchanged" {
  digest_json
  before=$(jq -r .episode "$J")
  [ -n "$before" ]
  [ "$before" != none ]
  append "$SDIR/main-0001.jsonl" '{"type":"assistant","message":{"role":"assistant","model":"m","content":[{"type":"tool_use","id":"tx1","name":"Bash","input":{"command":"ls"}}]},"timestamp":"2026-10-17T13:02:05Z","sessionId":"main-0001"}'
  append "$SDIR/main-0001.jsonl" '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tx1","content":"a"}]},"toolUseResult":{"stdout":"a"},"timestamp":"2026-10-17T13:02:06Z","sessionId":"main-0001"}'
  digest_json
  [ "$(jq -r .episode "$J")" = "$before" ]
}

@test "episode: a new human prompt starts a new one and becomes the request" {
  digest_json
  before=$(jq -r .episode "$J")
  append "$SDIR/main-0001.jsonl" '{"type":"user","message":{"role":"user","content":"Now also add a --timeout flag."},"origin":{"kind":"human"},"timestamp":"2026-10-17T13:02:00Z","sessionId":"main-0001"}'
  digest_json
  [ "$(jq -r .episode "$J")" != "$before" ]
  [ "$(jq -r .request.text "$J")" = "Now also add a --timeout flag." ]
  [ "$(jq -r .request.at "$J")" = 2026-10-17T13:02:00Z ]
}

@test "episode is 'none' and the request null when there is no session at all" {
  rm -rf "$SDIR"
  [ ! -e "$SDIR" ]
  digest_json
  [ "$(jq -r .episode "$J")" = none ]
  [ "$(jq -r '.request | type' "$J")" = null ]
  [ "$(field worker:job-run1 state)" = running ]
}

@test "fingerprint: same facts and clock give the same value; a new line from a source changes it" {
  digest_json
  fp=$(jq -r .fingerprint "$J")
  [ -n "$fp" ]
  digest_json
  [ "$(jq -r .fingerprint "$J")" = "$fp" ]
  digest_json --now 2026-10-17T13:02:40Z
  [ "$(jq -r .fingerprint "$J")" = "$fp" ]
  append "$SDIR/main-0001/subagents/agent-aaaa1111.jsonl" '{"type":"assistant","message":{"role":"assistant","model":"m","content":[{"type":"text","text":"Still going."}]},"timestamp":"2026-10-17T13:02:20Z","isSidechain":true,"agentId":"aaaa1111"}'
  digest_json
  [ "$(jq -r .fingerprint "$J")" != "$fp" ]
}
