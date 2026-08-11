#!/usr/bin/env bats
# lane.bats — the complexity router's per-prompt state + wording home:
#   lane express|standard|deep   declare a lane (state file + log row + echo)
#   lane                         report the current lane
#   lane --reset                 UserPromptSubmit hook (hook JSON on stdin)
#   lane --prime [--short]       the single authoritative rubric wording
# Like every hook in this repo it MUST fail open: malformed input, missing
# session id, unknown arguments — all silent-ish exit 0, never a hard failure.

LANE=/workspace/scripts/lane.sh
DOCKERFILE=/workspace/Dockerfile

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export LANE_STATE_DIR="$BATS_TEST_TMPDIR/lane-state"
    # the ambient env of a live Claude Code session carries a real session id;
    # pin it so tests never write to (or read from) the caller's own state
    export CLAUDE_CODE_SESSION_ID="test-session-1"
    STATE="$LANE_STATE_DIR/test-session-1.json"
    LOG="$LANE_STATE_DIR/log.jsonl"
}

lane() { bash "$LANE" "$@"; }

hook_json() { printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit"}' "$1"; }

# ── declaring a lane ─────────────────────────────────────────────────────────

@test "lane: declare writes state and echoes the confirmation line" {
    run lane express
    [ "$status" -eq 0 ]
    [ "$output" = "[lane] express — inline, no ceremony" ]
    [ -f "$STATE" ]
    jq -e '.lane == "express"' "$STATE"
    jq -e '.prev == "unset"' "$STATE"
    jq -e '.escalated == false' "$STATE"
    jq -e '.ts | type == "number"' "$STATE"
}

@test "lane: each lane has its own confirmation wording" {
    run lane standard
    [ "$output" = "[lane] standard — one slice, run-verify" ]
    run lane deep
    [[ "$output" == "[lane] deep — full protocol: plan + contracts + verifier"* ]]
}

@test "lane: a later declaration records the prior lane as prev" {
    lane express
    run lane standard
    [ "$status" -eq 0 ]
    jq -e '.prev == "express"' "$STATE"
    jq -e '.lane == "standard"' "$STATE"
}

# ── reading the current lane ─────────────────────────────────────────────────

@test "lane: no args prints the current lane" {
    lane deep
    run lane
    [ "$status" -eq 0 ]
    [ "$output" = "[lane] current: deep" ]
}

@test "lane: no args on a session with no state prints unset" {
    run lane
    [ "$status" -eq 0 ]
    [ "$output" = "[lane] current: unset" ]
}

@test "lane: no session id anywhere fails open with a notice, not an error" {
    run env -u CLAUDE_CODE_SESSION_ID bash "$LANE"
    [ "$status" -eq 0 ]
    [ "$output" = "[lane] no session id — lane not recorded" ]
    run env -u CLAUDE_CODE_SESSION_ID bash "$LANE" express
    [ "$status" -eq 0 ]
    [ "$output" = "[lane] no session id — lane not recorded" ]
}

# ── --reset (UserPromptSubmit) ───────────────────────────────────────────────

@test "lane --reset: hook JSON on stdin clears the lane and writes the pointer" {
    lane deep
    run bash -c 'hook_payload="{\"session_id\":\"test-session-1\"}"; printf %s "$hook_payload" | bash '"$LANE"' --reset'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.lane == "unset"' "$STATE"
    jq -e '.prev == "deep"' "$STATE"
    jq -e '.escalated == false' "$STATE"
    [ "$(cat "$LANE_STATE_DIR/last-session")" = "test-session-1" ]
}

@test "lane --reset: resets the session named in the payload, not the env one" {
    hook_json "other-session" | lane --reset
    [ -f "$LANE_STATE_DIR/other-session.json" ]
    [ "$(cat "$LANE_STATE_DIR/last-session")" = "other-session" ]
}

@test "lane: declare falls back to the --reset pointer when the env id is absent" {
    hook_json "pointer-session" | lane --reset
    run env -u CLAUDE_CODE_SESSION_ID bash "$LANE" standard
    [ "$status" -eq 0 ]
    [ "$output" = "[lane] standard — one slice, run-verify" ]
    jq -e '.lane == "standard"' "$LANE_STATE_DIR/pointer-session.json"
    run env -u CLAUDE_CODE_SESSION_ID bash "$LANE"
    [ "$output" = "[lane] current: standard" ]
}

@test "lane --reset: malformed stdin exits 0 and writes nothing" {
    printf 'not json at all' | lane --reset
    run bash -c 'printf %s "not json at all" | bash '"$LANE"' --reset'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$LANE_STATE_DIR/last-session" ]
}

@test "lane --reset: empty stdin exits 0 silently" {
    run bash -c 'printf %s "" | bash '"$LANE"' --reset'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "lane --reset: payload without a session_id exits 0 and writes nothing" {
    run bash -c 'printf %s "{\"hook_event_name\":\"UserPromptSubmit\"}" | bash '"$LANE"' --reset'
    [ "$status" -eq 0 ]
    [ ! -e "$LANE_STATE_DIR/last-session" ]
}

# ── escalation flag ──────────────────────────────────────────────────────────

@test "lane: standard → deep is an escalation" {
    lane standard
    run lane deep
    [ "$status" -eq 0 ]
    jq -e '.escalated == true' "$STATE"
    [[ "$output" == *"(escalated from standard)"* ]]
}

@test "lane: express → standard is an escalation" {
    lane express
    run lane standard
    jq -e '.escalated == true' "$STATE"
    [[ "$output" == *"(escalated from express)"* ]]
}

@test "lane: unset → express is not an escalation" {
    run lane express
    [ "$status" -eq 0 ]
    jq -e '.escalated == false' "$STATE"
    [[ "$output" != *"escalated"* ]]
}

@test "lane: a lane declared after --reset is not an escalation" {
    lane deep
    hook_json "test-session-1" | lane --reset
    run lane express
    jq -e '.escalated == false' "$STATE"
    [[ "$output" != *"escalated"* ]]
}

@test "lane: de-escalation deep → express records escalated=false" {
    lane deep
    run lane express
    [ "$status" -eq 0 ]
    jq -e '.escalated == false' "$STATE"
    jq -e '.prev == "deep"' "$STATE"
    [[ "$output" != *"escalated"* ]]
}

@test "lane: re-declaring the same lane is not an escalation" {
    lane standard
    run lane standard
    jq -e '.escalated == false' "$STATE"
}

# ── --why ────────────────────────────────────────────────────────────────────

@test "lane: --why lands in the state file and the echoed line" {
    run lane deep --why "schema migration, 4 files"
    [ "$status" -eq 0 ]
    [ "$output" = "[lane] deep — full protocol: plan + contracts + verifier — schema migration, 4 files" ]
    jq -e '.why == "schema migration, 4 files"' "$STATE"
}

@test "lane: --why with quotes and backslashes stays valid JSON and round-trips" {
    run lane express --why 'he said "fix it" \now'
    [ "$status" -eq 0 ]
    jq -e . "$STATE"
    jq -e '.lane == "express"' "$STATE"
    run jq -r '.why' "$STATE"
    [ "$output" = 'he said "fix it" \now' ]
}

@test "lane: an escalation with --why shows both suffixes in order" {
    lane express
    run lane standard --why "scope grew"
    [ "$output" = "[lane] standard — one slice, run-verify (escalated from express) — scope grew" ]
}

@test "lane: no --why leaves why empty" {
    run lane express
    jq -e '.why == ""' "$STATE"
}

# ── log.jsonl ────────────────────────────────────────────────────────────────

@test "lane: every declaration appends one row to log.jsonl" {
    lane express
    lane standard
    lane deep
    [ "$(wc -l < "$LOG")" -eq 3 ]
    run jq -r -s '.[2].lane' "$LOG"
    [ "$output" = "deep" ]
}

@test "lane: log rows carry the session id" {
    lane express
    run jq -r '.session_id' "$LOG"
    [ "$output" = "test-session-1" ]
}

@test "lane: --reset does not append a log row" {
    lane express
    hook_json "test-session-1" | lane --reset
    [ "$(wc -l < "$LOG")" -eq 1 ]
}

@test "lane: an oversized log is truncated to the newest 2500 rows" {
    mkdir -p "$LANE_STATE_DIR"
    seq 1 5200 | sed 's/.*/{"lane":"express","filler":&}/' > "$LOG"
    lane deep
    [ "$(wc -l < "$LOG")" -eq 2500 ]
    run jq -r -s '.[-1].lane' "$LOG"
    [ "$output" = "deep" ]
    # the oldest rows are the ones dropped
    run jq -r -s '.[0].filler' "$LOG"
    [ "$output" = "2702" ]
}

# ── --prime (the single wording home) ────────────────────────────────────────

@test "lane --prime: prints the route-first instruction and all three lanes" {
    run lane --prime
    [ "$status" -eq 0 ]
    [[ "$output" == *"[lane] Route first"* ]]
    [[ "$output" == *'lane express|standard|deep [--why "…"]'* ]]
    [[ "$output" == *"express  — ALL of:"* ]]
    [[ "$output" == *"standard — one well-understood slice"* ]]
    [[ "$output" == *"deep     — ANY of:"* ]]
    [[ "$output" == *"Ties go to the LIGHTER lane"* ]]
    [[ "$output" == *"never de-escalate within the same prompt"* ]]
    [[ "$output" == *"Scope: classify and answer the request AS ASKED"* ]]
    [[ "$output" == *"discovering them is NOT a tripwire"* ]]
    [[ "$output" == *"User override always wins"* ]]
}

@test "lane --prime: keeps the rubric's indentation (arrow lines are indented)" {
    run lane --prime
    [[ "$output" == *"             → do it inline now"* ]]
    [[ "$output" == *"             → full protocol: plan first"* ]]
}

@test "lane --prime --short: exact one-liner" {
    run lane --prime --short
    [ "$status" -eq 0 ]
    [ "$output" = "[lane] route first — lane express|standard|deep · express: inline, no ceremony · standard: 1 slice + run-verify · deep: plan+contracts+verifier · ties→lighter, tripwires escalate one-way · scope: the question as asked" ]
}

@test "lane --prime: needs no session id and writes no state" {
    run env -u CLAUDE_CODE_SESSION_ID bash "$LANE" --prime
    [ "$status" -eq 0 ]
    [ ! -e "$STATE" ]
}

# ── fail-open surface ────────────────────────────────────────────────────────

@test "lane: an unknown argument prints usage and exits 0" {
    run lane sideways
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage: lane express|standard|deep"* ]]
    [ ! -e "$STATE" ]
}

@test "lane: an unknown flag prints usage and exits 0" {
    run lane --turbo
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage:"* ]]
}

@test "lane: HOME unset still exits 0 (no 'unbound variable' abort)" {
    run env -u HOME -u LANE_STATE_DIR -u CLAUDE_CODE_SESSION_ID bash "$LANE" --prime
    [ "$status" -eq 0 ]
    run env -u HOME -u LANE_STATE_DIR -u CLAUDE_CODE_SESSION_ID bash "$LANE"
    [ "$status" -eq 0 ]
}

@test "lane: an unwritable state dir fails open rather than erroring" {
    export LANE_STATE_DIR=/proc/nope/lane
    run lane express
    [ "$status" -eq 0 ]
}

# ── installation ─────────────────────────────────────────────────────────────

@test "lane: the script is executable and installed to a bare name in the image" {
    [ -x "$LANE" ]
    grep -qE 'COPY .*scripts/lane\.sh .*/usr/local/bin/lane$' "$DOCKERFILE"
}
