#!/usr/bin/env bats
# Guards:   the activity panel's viewer (scripts/activity.py, bin/activity): every frame fits the window and ends in the dim footer, and the full-screen loop calls the summarizer on schedule and always puts the terminal back.
# Fails if: a long page is allowed to scroll or overflow a line, the footer is lost, the summarizer is called twice with nothing new (or never when the work changes), or quitting leaves the alternate screen / hidden cursor behind.
# Run:      bats tests/activity-viewer.bats
#
# Every case runs against fixtures under $BATS_TEST_TMPDIR (the "folder" is
# $ROOT); nothing here reads the real project. The live cases run the viewer
# on a real pseudo-terminal (tests/helpers/pty-drive.py) with stub summarizer
# and digest scripts, and the seconds knobs turned down so a case takes ~3 s.
#
# Assertions are `[ ]` and functions, never a bare `[[ ]]` (run-tests.sh).

VIEW="${BATS_TEST_DIRNAME}/../scripts/activity.py"
BIN="${BATS_TEST_DIRNAME}/../bin/activity"
DRIVE="${BATS_TEST_DIRNAME}/helpers/pty-drive.py"

setup() {
  ROOT="$BATS_TEST_TMPDIR/root"
  ACT="$ROOT/.claude-dev/run/activity"
  mkdir -p "$ACT" "$BATS_TEST_TMPDIR/home"
  export PROJECT_DIR="$ROOT" CLAUDE_ORCA_ROOT="$ROOT" HOME="$BATS_TEST_TMPDIR/home"
  export CLAUDE_CONFIG_DIR="$HOME/.claude"
  unset CLAUDE_ORCA_ACTIVITY_SUMMARIZE CLAUDE_ORCA_ACTIVITY_DIGEST
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  OUT="$BATS_TEST_TMPDIR/pty.bin"     # the live cases' terminal bytes
  : >"$CALLS"
  # A page that is much longer than any test window.
  : >"$ACT/page.md"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    printf 'Paragraph %s: the quick brown fox jumps over the lazy dog and keeps running through the long field until night falls.\n\n' \
      "$i" >>"$ACT/page.md"
  done
}

# meta.json with a model answer written $1 seconds ago.
write_meta() {
  python3 -I - "$ACT/meta.json" "$1" "${2:-model}" "${3:-}" <<'PY'
import datetime, json, sys
path, ago, source, reason = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=ago)
json.dump({"updated": t.isoformat(), "episode": "e1", "fingerprint": "f1",
           "model": None if source == "fallback" else "claude-haiku",
           "source": source, "reason": reason or None, "usage": None}, open(path, "w"))
PY
}

# frame ROWS COLS -> $BATS_TEST_TMPDIR/frame.txt (plain text, one frame)
frame() {
  python3 -I "$VIEW" --frame --rows "$1" --cols "$2" >"$BATS_TEST_TMPDIR/frame.txt"
}

# Longest line in the frame, counted in characters.
frame_width() {
  python3 -I -c 'import sys
print(max(len(l) for l in open(sys.argv[1], encoding="utf-8").read().split("\n")))' "$BATS_TEST_TMPDIR/frame.txt"
}

@test "a long page is cut to exactly the window: R lines, none wider than C, footer last" {
  write_meta 40
  frame 10 50
  [ "$(wc -l <"$BATS_TEST_TMPDIR/frame.txt")" -eq 10 ]
  [ "$(frame_width)" -le 50 ]
  tail -n 1 "$BATS_TEST_TMPDIR/frame.txt" | grep -q '^updated 40 s ago'
  tail -n 1 "$BATS_TEST_TMPDIR/frame.txt" | grep -q 'q quits$'
  head -n 1 "$BATS_TEST_TMPDIR/frame.txt" | grep -q '^Paragraph 1:'
}

@test "wrapping breaks between words, never in the middle of one" {
  write_meta 5
  frame 12 30
  # every word on the frame (but the footer and a closing ellipsis) is a whole word of the page
  python3 -I - "$BATS_TEST_TMPDIR/frame.txt" "$ACT/page.md" <<'PY'
import sys
frame = open(sys.argv[1], encoding="utf-8").read().split("\n")[:-2]   # drop footer and the final newline
page = set(open(sys.argv[2], encoding="utf-8").read().split())
words = " ".join(frame).replace("…", "").split()
assert len(words) > 20, words
bad = [w for w in words if w not in page]
assert not bad, bad
PY
}

@test "the same window sizes hold at tiny sizes and the footer is still last" {
  write_meta 5
  for size in "3 10" "6 20" "24 80" "2 80"; do
    set -- $size
    frame "$1" "$2"
    [ "$(wc -l <"$BATS_TEST_TMPDIR/frame.txt")" -eq "$1" ]
    [ "$(frame_width)" -le "$2" ]
  done
}

@test "no page yet: the Reading line, a footer, and exit 0" {
  rm -f "$ACT/page.md" "$ACT/meta.json"
  frame 8 60
  [ "$(wc -l <"$BATS_TEST_TMPDIR/frame.txt")" -eq 8 ]
  head -n 1 "$BATS_TEST_TMPDIR/frame.txt" | grep -q '^Reading what Claude Code is doing\.\.\.$'
  tail -n 1 "$BATS_TEST_TMPDIR/frame.txt" | grep -q 'q quits'
}

@test "a fallback page names its reason in the footer instead of the model" {
  write_meta 3 fallback "turned off in claude-orca.json"
  frame 6 80
  tail -n 1 "$BATS_TEST_TMPDIR/frame.txt" | grep -q 'updated 3 s ago · turned off in claude-orca.json · q quits'
  ! grep -q 'claude-haiku' "$BATS_TEST_TMPDIR/frame.txt"
}

@test "a model page names the model and how old it is, in minutes once past 90 s" {
  write_meta 200
  frame 6 80
  tail -n 1 "$BATS_TEST_TMPDIR/frame.txt" | grep -q 'updated 3 min ago · claude-haiku · q quits'
}

@test "a broken meta.json or escape bytes in the page cannot break the frame" {
  printf '{not json' >"$ACT/meta.json"
  printf 'plain \033[31mred\033[0m and a bell\007 here\n' >"$ACT/page.md"
  frame 4 60
  [ "$(wc -l <"$BATS_TEST_TMPDIR/frame.txt")" -eq 4 ]
  head -n 1 "$BATS_TEST_TMPDIR/frame.txt" | grep -q '^plain red and a bell here$'
  ! grep -q "$(printf '\033')" "$BATS_TEST_TMPDIR/frame.txt"
}

@test "bin/activity is the viewer, and a pipe (no terminal) is refused with exit 2" {
  write_meta 5
  run "$BIN" --frame --rows 4 --cols 50
  [ "$status" -eq 0 ]
  run "$BIN" </dev/null
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'needs a terminal'
}

# ---------------------------------------------------------------- live loop
# The full-screen viewer on a real pseudo-terminal, with stub scripts that
# stand in for the summarizer (activity-summarize.py) and the digest
# (activity-digest.py). Each stub only records that it ran.

# stub_summarizer [EXIT]: logs its argv; with STUB_PAGE set it writes that page.
stub_summarizer() {
  local exit_code="${1:-0}"
  cat >"$BATS_TEST_TMPDIR/stub-summarize" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$CALLS"
if [ -n "\${STUB_PAGE:-}" ]; then
  printf '%s\n' "\$STUB_PAGE" >"$ACT/page.md"
fi
exit $exit_code
STUB
  chmod +x "$BATS_TEST_TMPDIR/stub-summarize"
  export CLAUDE_ORCA_ACTIVITY_SUMMARIZE="$BATS_TEST_TMPDIR/stub-summarize"
}

# stub_digest same|changing: a digest whose episode never moves, or moves every run.
stub_digest() {
  cat >"$BATS_TEST_TMPDIR/stub-digest" <<STUB
#!/usr/bin/env bash
n=\$(cat "$BATS_TEST_TMPDIR/digest.n" 2>/dev/null || echo 0)
n=\$((n + 1)); echo "\$n" >"$BATS_TEST_TMPDIR/digest.n"
[ "$1" = same ] && n=1
printf '{"episode": "ep%s", "sources": []}\n' "\$n"
STUB
  chmod +x "$BATS_TEST_TMPDIR/stub-digest"
  export CLAUDE_ORCA_ACTIVITY_DIGEST="$BATS_TEST_TMPDIR/stub-digest"
}

# drive [pty-drive options...]: run the viewer on a 10x50 pty, bytes -> $OUT.
drive() {
  python3 -I "$DRIVE" --out "$OUT" --rows 10 --cols 50 --timeout 15 "$@" -- python3 -I "$VIEW"
}

calls() { wc -l <"$CALLS" | tr -d ' '; }

# ends_with_restore: the last bytes put the screen, wrap and cursor back.
ends_with_restore() {
  python3 -I -c 'import sys
d = open(sys.argv[1], "rb").read()
sys.exit(0 if d.endswith(b"\x1b[?7h\x1b[?1049l\x1b[?25h") and d.startswith(b"\x1b[?1049h\x1b[?25l") else 1)' "$OUT"
}

has_bytes() { grep -aqF -- "$1" "$OUT"; }

@test "live: one summarizer call at start, with the window size and folder, then none while nothing changes" {
  stub_summarizer; stub_digest same
  export CLAUDE_ORCA_ACTIVITY_EVERY_S=600 CLAUDE_ORCA_ACTIVITY_MIN_GAP_S=1 CLAUDE_ORCA_ACTIVITY_WATCH_S=1
  run drive --at 3.2:send:q
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  grep -qxF -- "--rows 10 --cols 50 --root $ROOT" "$CALLS"
  ends_with_restore
}

@test "live: a new request in the digest calls the summarizer again (after the minimum gap)" {
  stub_summarizer; stub_digest changing
  export CLAUDE_ORCA_ACTIVITY_EVERY_S=600 CLAUDE_ORCA_ACTIVITY_MIN_GAP_S=1 CLAUDE_ORCA_ACTIVITY_WATCH_S=1
  run drive --at 4.5:send:q
  [ "$status" -eq 0 ]
  [ "$(calls)" -ge 2 ]
}

@test "live: a digest that changes every second still waits out the minimum gap" {
  stub_summarizer; stub_digest changing
  export CLAUDE_ORCA_ACTIVITY_EVERY_S=600 CLAUDE_ORCA_ACTIVITY_MIN_GAP_S=100 CLAUDE_ORCA_ACTIVITY_WATCH_S=1
  run drive --at 4:send:q
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
}

@test "live: with nothing new the summarizer is asked again every EVERY_S seconds" {
  stub_summarizer; stub_digest same
  export CLAUDE_ORCA_ACTIVITY_EVERY_S=1 CLAUDE_ORCA_ACTIVITY_MIN_GAP_S=1 CLAUDE_ORCA_ACTIVITY_WATCH_S=100
  run drive --at 3.5:send:q
  [ "$status" -eq 0 ]
  [ "$(calls)" -ge 2 ]
}

@test "live: a page the summarizer writes shows up on screen without a restart" {
  stub_summarizer; stub_digest same
  rm -f "$ACT/page.md"
  export STUB_PAGE="Stub says the build is green" CLAUDE_ORCA_ACTIVITY_EVERY_S=600
  run drive --at 2.5:send:q
  [ "$status" -eq 0 ]
  has_bytes "Reading what Claude Code is doing..."
  has_bytes "Stub says the build is green"
}

@test "live: a missing summarizer is said in the footer and the viewer keeps running" {
  export CLAUDE_ORCA_ACTIVITY_SUMMARIZE="$BATS_TEST_TMPDIR/nope" CLAUDE_ORCA_ACTIVITY_DIGEST="$BATS_TEST_TMPDIR/nope"
  run drive --cols 90 --at 1.5:send:q
  [ "$status" -eq 0 ]
  has_bytes "summarizer not installed"
  ends_with_restore
}

@test "live: a summarizer that fails is said in the footer" {
  stub_summarizer 3; stub_digest same
  run drive --at 2.5:send:q
  [ "$status" -eq 0 ]
  has_bytes "summarizer failed (exit 3)"
}

@test "live: q, Q, ctrl-c, SIGTERM and SIGHUP each leave the terminal as they found it" {
  stub_summarizer; stub_digest same
  for how in "send:q" 'send:Q' 'send:\x03' "sig:TERM" "sig:HUP"; do
    run drive --at "1:$how"
    [ "$status" -eq 0 ]
    ends_with_restore
  done
}

@test "live: a resize redraws at the new size and never writes below it" {
  stub_summarizer; stub_digest same
  write_meta 5
  run drive --at 1:resize:5x30 --at 2.2:send:q
  [ "$status" -eq 0 ]
  has_bytes "$(printf '\033[10;1H')"
  python3 -I - "$OUT" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
cut = d.rfind(b"\x1b[2J")                       # the redraw the resize caused
after = d[cut:]
assert cut > 0 and b"\x1b[5;1H" in after and b"\x1b[6;1H" not in after, after[:200]
PY
}
