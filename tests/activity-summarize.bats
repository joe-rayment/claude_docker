#!/usr/bin/env bats
# Guards:   the activity panel's summarizer asks the guard for a plain page, stays inside the terminal budget, never leaks a key, and falls back quietly when the guard is down
# Fails if: the request loses its Bearer token or model, a planted key reaches the request body, a markdown-heavy reply spills past rows-2 lines, or a failed call is retried within 300 s
# Run:      bats tests/activity-summarize.bats

# Every case runs against a throwaway folder and a fake guard (tests/helpers/fake-guard.py)
# on a free loopback port; no real key, no network, no model.

SUMMARIZE="$BATS_TEST_DIRNAME/../scripts/activity-summarize.py"
FAKE_GUARD="$BATS_TEST_DIRNAME/helpers/fake-guard.py"
FAKE_TOKEN="fake-guard-token-not-real"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  ROOT="$BATS_TEST_TMPDIR/folder"
  ACT="$ROOT/.claude-dev/run/activity"
  G="$BATS_TEST_TMPDIR/guard"
  mkdir -p "$HOME" "$ROOT/.claude-dev/run" "$G"
  export PROJECT_DIR="$ROOT" CLAUDE_ORCA_ROOT="$ROOT"
  unset OPENROUTER_BASE_URL CLAUDE_ORCA_ACTIVITY_MODEL CLAUDE_ORCA_ACTIVITY_URL \
        CLAUDE_ORCA_ACTIVITY_DIGEST CLAUDE_ORCA_ACTIVITY_BACKOFF_S CLAUDE_ORCA_ACTIVITY_TIMEOUT_S
  export OPENROUTER_API_KEY="$FAKE_TOKEN"
  printf '{"activityModel":"fake/test-model"}\n' > "$ROOT/.claude-dev/claude-orca.json"
  GPID="" HPID=""
}

teardown() {
  [ -z "$GPID" ] || kill "$GPID" 2>/dev/null || true
  [ -z "$HPID" ] || kill "$HPID" 2>/dev/null || true
}

# start_guard: the fake guard on a free port; points the summarizer at it.
start_guard() {
  python3 "$FAKE_GUARD" --dir "$G" >"$G/out.txt" 2>&1 3>&- &
  GPID=$!
  local i
  for i in $(seq 1 50); do [ -s "$G/port" ] && break; sleep 0.1; done
  [ -s "$G/port" ]
  export CLAUDE_ORCA_ACTIVITY_URL="http://127.0.0.1:$(cat "$G/port")"
}

guard_config() { printf '%s\n' "$1" > "$G/config.json"; }

n_requests() { if [ -f "$G/requests.jsonl" ]; then wc -l < "$G/requests.jsonl" | tr -d ' '; else echo 0; fi; }

# write_digest FILE FINGERPRINT [EPISODE] [EXTRA-EVENT]: a small digest per the P1 contract.
write_digest() {
  python3 - "$1" "$2" "${3:-ep1}" "${4:-}" <<'PY'
import json, sys
path, fp, ep, extra = sys.argv[1:5]
events = ["10:01 read the settings file", "10:02 ran the fast tests"]
if extra:
    events.append("10:03 " + extra)
digest = {"generated": "2026-10-17T10:05:00Z", "root": "/x", "episode": ep, "fingerprint": fp,
          "request": {"session": "s1", "text": "make the panel show progress " + extra, "at": "2026-10-17T10:00:00Z"},
          "sources": [{"id": "a1", "kind": "executor", "title": "build the summarizer",
                       "model": "m", "started": "2026-10-17T10:00:30Z", "last": "2026-10-17T10:04:50Z",
                       "state": "running", "task": "write the script " + extra,
                       "events": events, "final": None}],
          "omitted": 0}
json.dump(digest, open(path, "w"))
PY
}

# json_get FILE EXPR: print a python expression of the parsed JSON file `d`.
json_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

# last_body EXPR: an expression over the last recorded request (`r`) body `b`.
last_body() {
  python3 -c '
import json,sys
r=[json.loads(l) for l in open(sys.argv[1])][-1]; b=r["body"]
print(eval(sys.argv[2]))' "$G/requests.jsonl" "$1"
}

@test "asks the guard with POST /chat/completions, the Bearer token and the model, then writes the page" {
  start_guard
  guard_config '{"reply":"Building the summarizer.\nNow: writing the script.","usage":{"prompt_tokens":120,"completion_tokens":30,"cost":0.0004}}'
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$status" -eq 0 ]
  [ "$output" = "updated" ]
  [ "$(n_requests)" = "1" ]
  [ "$(last_body 'r["method"]')" = "POST" ]
  [ "$(last_body 'r["path"]')" = "/chat/completions" ]
  [ "$(last_body 'r["authorization"]')" = "Bearer $FAKE_TOKEN" ]
  [ "$(last_body 'b["model"]')" = "fake/test-model" ]
  grep -q 'Building the summarizer.' "$ACT/page.md"
  [ "$(json_get "$ACT/meta.json" 'd["source"]')" = "model" ]
  [ "$(json_get "$ACT/meta.json" 'd["fingerprint"]')" = "fp1" ]
  [ "$(json_get "$ACT/meta.json" 'd["usage"]["completion_tokens"]')" = "30" ]
}

@test "the request carries the budget numbers and the previous page, but only within one episode" {
  start_guard
  guard_config '{"reply":"First page line."}'
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1 ep1
  run python3 -I "$SUMMARIZE" --rows 20 --cols 60 --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "updated" ]
  [ "$(last_body '"18 lines" in b["messages"][0]["content"] and "60 characters" in b["messages"][0]["content"]')" = "True" ]
  [ "$(last_body '"Previous page:\n(none)" in b["messages"][1]["content"]')" = "True" ]
  write_digest "$BATS_TEST_TMPDIR/d.json" fp2 ep1
  run python3 -I "$SUMMARIZE" --rows 20 --cols 60 --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "updated" ]
  [ "$(last_body '"First page line." in b["messages"][1]["content"]')" = "True" ]
  write_digest "$BATS_TEST_TMPDIR/d.json" fp3 ep2
  run python3 -I "$SUMMARIZE" --rows 20 --cols 60 --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "updated" ]
  [ "$(last_body '"First page line." in b["messages"][1]["content"]')" = "False" ]
}

@test "a key planted in the digest never reaches the request body, and a key echoed by the model never reaches the page" {
  start_guard
  local key="sk-or-v1-$(printf 'deadbeef%.0s' 1 2 3 4 5 6 7 8)"
  guard_config "{\"reply\":\"Working. The key $key was in the log.\"}"
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1 ep1 "used $key and Bearer abcdef1234567890"
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "updated" ]
  [ "$(n_requests)" = "1" ]
  run grep -c 'deadbeef' "$G/requests.jsonl"
  [ "$output" = "0" ]
  run grep -c 'abcdef1234567890' "$G/requests.jsonl"
  [ "$output" = "0" ]
  [ "$(last_body '"fake-guard-token" in json.dumps(b)')" = "False" ]
  [ -s "$ACT/page.md" ]
  run grep -r 'deadbeef' "$ACT"
  [ "$status" -eq 1 ]
}

# Guards:   the summarizer's second redaction pass leaves a VAR=/path assignment readable, while a 48-char key and a 44-char std-base64 run in the same digest still never reach the request
# Fails if: the request body carries "[redacted]; cat > f" in place of the S=/tmp/... path, or the key or the base64 run is sent to the guard
# Run:      bats -f 'VAR=/path assignment' tests/activity-summarize.bats
@test "a VAR=/path assignment stays readable in the request body, while a long key and a base64 run are still blanked" {
  start_guard
  guard_config '{"reply":"Working."}'
  local tok="aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hJ6kM9nP2rS5uV8"   # 48 chars
  local b64="aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hJ6kM9+n2=="       # 44 chars, "+" and "==" padding
  local path="/tmp/claude-501/-workspace-x/d185fd60-fd0e-4c58-85f0-a4b5699430eb/scratchpad"
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1 ep1 "ran: S=$path; cat > f; FOO=$tok; echo $b64"
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "updated" ]
  [ "$(n_requests)" = "1" ]
  run grep -c "S=$path; cat > f" "$G/requests.jsonl"
  [ "$output" != "0" ]
  run grep -c 'aB3dE6gH9jK2' "$G/requests.jsonl"
  [ "$output" = "0" ]
}

@test "a long markdown reply comes out plain, within rows-2 lines of cols characters" {
  start_guard
  python3 - "$G/config.json" <<'PY'
import json, sys
lines = ["# Big heading", "**Bold line** about the work", "- a bullet that goes on and on " + "word " * 40]
lines += ["Line %d %s" % (i, "x" * 150) for i in range(40)]
json.dump({"reply": "\n".join(lines)}, open(sys.argv[1], "w"))
PY
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1
  run python3 -I "$SUMMARIZE" --rows 14 --cols 50 --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "updated" ]
  run python3 - "$ACT/page.md" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
if lines and lines[-1] == "":
    lines.pop()
assert 1 <= len(lines) <= 12, len(lines)
assert all(len(l) <= 50 for l in lines), max(len(l) for l in lines)
text = "\n".join(lines)
assert "#" not in text and "**" not in text, text
assert not any(l.lstrip().startswith(("- ", "* ")) for l in lines), text
assert lines[0].startswith("Big heading"), lines[0]
PY
  [ "$status" -eq 0 ]
}

@test "an unchanged fingerprint makes no request; --force does" {
  start_guard
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "updated" ]
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
  [ "$(n_requests)" = "1" ]
  run python3 -I "$SUMMARIZE" --force --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "updated" ]
  [ "$(n_requests)" = "2" ]
}

@test "a second summarizer while one holds the lock says busy and does nothing" {
  start_guard
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1
  mkdir -p "$ACT"
  python3 -c '
import fcntl, sys, time
f = open(sys.argv[1], "a")
fcntl.flock(f, fcntl.LOCK_EX)
print("held", flush=True)
time.sleep(60)' "$ACT/summarize.lock" >"$BATS_TEST_TMPDIR/held.out" 2>&1 3>&- &
  HPID=$!
  local i
  for i in $(seq 1 50); do [ -s "$BATS_TEST_TMPDIR/held.out" ] && break; sleep 0.1; done
  [ -s "$BATS_TEST_TMPDIR/held.out" ]
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$status" -eq 0 ]
  [ "$output" = "busy" ]
  [ "$(n_requests)" = "0" ]
  [ ! -e "$ACT/page.md" ]
}

@test "a guard error (HTTP 500) writes the fallback page and the next run within the backoff makes no request" {
  start_guard
  guard_config '{"status":500}'
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$status" -eq 0 ]
  [ "$output" = "fallback" ]
  [ "$(n_requests)" = "1" ]
  [ "$(json_get "$ACT/meta.json" 'd["source"]')" = "fallback" ]
  [[ "$(json_get "$ACT/meta.json" 'd["reason"]')" == *"HTTP 500"* ]]
  [ "$(json_get "$ACT/meta.json" 'bool(d["backoff_until"])')" = "True" ]
  grep -q 'build the summarizer' "$ACT/page.md"
  write_digest "$BATS_TEST_TMPDIR/d.json" fp2
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "fallback" ]
  [ "$(n_requests)" = "1" ]
  [ "$(json_get "$ACT/meta.json" 'd["fingerprint"]')" = "fp2" ]
  [[ "$(json_get "$ACT/meta.json" 'd["reason"]')" == *"HTTP 500"* ]]
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "unchanged" ]
  guard_config '{"reply":"Back again."}'
  run python3 -I "$SUMMARIZE" --force --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "updated" ]
  [ "$(n_requests)" = "2" ]
}

@test "a refused connection writes the fallback page and backs off" {
  local port
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  export CLAUDE_ORCA_ACTIVITY_URL="http://127.0.0.1:$port"
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "fallback" ]
  [[ "$(json_get "$ACT/meta.json" 'd["reason"]')" == *"not answering"* ]]
  [ "$(wc -l < "$ACT/calls.log" | tr -d ' ')" = "1" ]
  write_digest "$BATS_TEST_TMPDIR/d.json" fp2
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "fallback" ]
  [ "$(wc -l < "$ACT/calls.log" | tr -d ' ')" = "1" ]
}

@test "\"activity\": false in claude-orca.json means no request and a fallback page" {
  start_guard
  printf '{"activity":false,"activityModel":"fake/test-model"}\n' > "$ROOT/.claude-dev/claude-orca.json"
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "fallback" ]
  [ "$(n_requests)" = "0" ]
  [ "$(json_get "$ACT/meta.json" 'd["reason"]')" = "turned off in claude-orca.json" ]
  [ -s "$ACT/page.md" ]
}

@test "the page is replaced atomically: the old file is left whole, no temp files remain" {
  start_guard
  guard_config '{"reply":"The new page."}'
  mkdir -p "$ACT"
  printf 'The old page, still whole.\n' > "$ACT/page.md"
  ln "$ACT/page.md" "$BATS_TEST_TMPDIR/old-page-link"
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "updated" ]
  [ "$(cat "$ACT/page.md")" = "The new page." ]
  [ "$(cat "$BATS_TEST_TMPDIR/old-page-link")" = "The old page, still whole." ]
  run find "$ACT" -name '.tmp-*'
  [ -z "$output" ]
}

@test "calls.log gets one line per call with model, status, tokens, cost and time -- no content, no token" {
  start_guard
  guard_config '{"reply":"Secret-looking page words here.","usage":{"prompt_tokens":111,"completion_tokens":22,"cost":0.00033}}'
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "updated" ]
  [ "$(wc -l < "$ACT/calls.log" | tr -d ' ')" = "1" ]
  grep -q 'model=fake/test-model' "$ACT/calls.log"
  grep -q 'status=200' "$ACT/calls.log"
  grep -q 'prompt_tokens=111' "$ACT/calls.log"
  grep -q 'completion_tokens=22' "$ACT/calls.log"
  grep -q 'cost=0.00033' "$ACT/calls.log"
  grep -Eq 'duration_ms=[0-9]+' "$ACT/calls.log"
  run grep -E "Secret-looking|$FAKE_TOKEN|summarizer" "$ACT/calls.log"
  [ "$status" -eq 1 ]
}

@test "with no OPENROUTER_API_KEY the token is read from the run dir's openrouter-guard.token" {
  start_guard
  unset OPENROUTER_API_KEY
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "fallback" ]
  [ "$(n_requests)" = "0" ]
  [[ "$(json_get "$ACT/meta.json" 'd["reason"]')" == *"token"* ]]
  printf 'fake-token-from-file\n' > "$ROOT/.claude-dev/run/openrouter-guard.token"
  chmod 600 "$ROOT/.claude-dev/run/openrouter-guard.token"
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "updated" ]
  [ "$(last_body 'r["authorization"]')" = "Bearer fake-token-from-file" ]
}

@test "the token is never sent to a non-loopback address" {
  export CLAUDE_ORCA_ACTIVITY_URL="http://guard.invalid:4141/api/v1"
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "fallback" ]
  [[ "$(json_get "$ACT/meta.json" 'd["reason"]')" == *"not a local guard"* ]]
  [ ! -e "$ACT/calls.log" ]
}

@test "an empty reply counts as a failure: fallback page and backoff" {
  start_guard
  guard_config '{"reply":"   "}'
  write_digest "$BATS_TEST_TMPDIR/d.json" fp1
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "fallback" ]
  [ "$(json_get "$ACT/meta.json" 'bool(d["backoff_until"])')" = "True" ]
  grep -q 'build the summarizer' "$ACT/page.md"
}

@test "a digest with no sources and no request is not sent to the model" {
  start_guard
  printf '{"generated":"2026-10-17T10:05:00Z","episode":"e","fingerprint":"f0","request":null,"sources":[],"omitted":0}\n' > "$BATS_TEST_TMPDIR/d.json"
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/d.json"
  [ "$output" = "fallback" ]
  [ "$(n_requests)" = "0" ]
  [ "$(json_get "$ACT/meta.json" 'd["reason"]')" = "nothing to summarize yet" ]
  grep -q 'Nothing is running' "$ACT/page.md"
}

@test "bad arguments and an unreadable --digest exit 2 without touching anything" {
  run python3 -I "$SUMMARIZE" --rows 2
  [ "$status" -eq 2 ]
  run python3 -I "$SUMMARIZE" --bogus
  [ "$status" -eq 2 ]
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 2 ]
  [ ! -e "$ACT/page.md" ]
}

# Guards:   the model is sent a compact digest, not the whole 32 KB one, and loses nothing a running source needs
# Fails if: user_message sends the raw digest again (message over 22000 bytes), drops a running source's title or last event, or leaves the model name / worktree path noise in
# Run:      bats -f 'compact digest' tests/activity-summarize.bats
@test "a 32 KB digest of 16 sources reaches the model as a compact digest that still holds every running title and last event" {
  start_guard
  guard_config '{"reply":"Working."}'
  python3 - "$BATS_TEST_TMPDIR/big.json" <<'PY'
import json, sys
wt = "/workspace/folder/.claude/worktrees/agent-%02dabcdef"
srcs = []
for i in range(16):
    running = i < 10
    events = ["10:%02d ran: cd %s; make step %d && tail -n 40 /var/log/long-output-%d.txt and more words to fill the line out" % (j, wt % i, j, j) for j in range(9)]
    events.append("10:59 edited .claude/worktrees/agent-%02dabcdef/scripts/last-marker-%d.py" % (i, i))
    srcs.append({"id": "agent-%02d" % i, "kind": "executor", "title": "title-marker-%d" % i, "model": "claude-secret-model-name",
                 "started": "2026-10-17T10:00:%02dZ" % i, "last": "2026-10-17T10:59:%02dZ" % i,
                 "state": "running" if running else "done", "task": "do the long job number %d. " % i + "details " * 30,
                 "events": events, "final": None if running else "finished item %d. " % i + "result words " * 20})
digest = {"generated": "2026-10-17T11:00:00Z", "root": "/x", "episode": "ep1", "fingerprint": "fpbig",
          "request": {"session": "s1", "text": "build the panel", "at": "2026-10-17T10:00:00Z"},
          "sources": srcs, "omitted": 0}
json.dump(digest, open(sys.argv[1], "w"))
print("raw digest bytes:", len(json.dumps(digest)))
PY
  [ "$(wc -c < "$BATS_TEST_TMPDIR/big.json")" -gt 30000 ] && [ "$(wc -c < "$BATS_TEST_TMPDIR/big.json")" -le 34000 ]
  run python3 -I "$SUMMARIZE" --digest "$BATS_TEST_TMPDIR/big.json"
  [ "$output" = "updated" ]
  python3 - "$G/requests.jsonl" <<'PY'
import json, sys
body = [json.loads(l) for l in open(sys.argv[1])][-1]["body"]
msg = body["messages"][1]["content"]
assert len(msg.encode("utf-8")) <= 22000, len(msg.encode("utf-8"))
for i in range(10):
    assert "title-marker-%d\"" % i in msg, ("running title missing", i)
    assert "scripts/last-marker-%d.py" % i in msg, ("running last event missing", i)
assert "claude-secret-model-name" not in msg
assert "ran: cd " not in msg
PY
}
