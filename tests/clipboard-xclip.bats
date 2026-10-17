#!/usr/bin/env bats
# Guards:   the container's xclip shim reads only the Mac clipboard's IMAGE through the bridge socket -- a text read makes no request at all, TARGETS and image/png become GET /targets and /png, -i becomes POST /copy, and a missing or flaky socket fails quietly
# Fails if: a text `xclip -o` reaches the socket, the PNG bytes come back altered, a 204/404 prints anything or exits 0, the 3 tries 0.1 s apart stop (or a real HTTP answer gets retried), or bin/xclip stops winning over /usr/bin/xclip on a pane's PATH
# Run:      bats tests/clipboard-xclip.bats

ROOT="$BATS_TEST_DIRNAME/.."
XCLIP="$ROOT/scripts/container/xclip"
SERVER="$ROOT/tests/helpers/clip-fake-server.py"

setup() {
  # unix socket paths must stay short, so the socket lives in its own /tmp dir
  SD=$(mktemp -d /tmp/cdev-xc.XXXXXX)
  case "$SD" in /tmp/cdev-xc.*) ;; *) echo "bad fixture dir $SD"; return 1 ;; esac
  SOCK="$SD/clip.sock"; LOG="$SD/requests.jsonl"; CFG="$SD/config.json"
  PNG="$BATS_TEST_TMPDIR/pic.png"
  # a real, tiny PNG with NUL and high bytes in it, so an altered copy cannot pass
  python3 -I -c '
import struct, sys, zlib
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
raw = b"".join(b"\x00" + bytes(range(0, 24, 8)) * 4 for _ in range(8))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 12, 8, 8, 0, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)' "$PNG"
  SERVER_PID=""
}

teardown() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  case "${SD:-}" in /tmp/cdev-xc.*) rm -rf "$SD" ;; esac
  return 0
}

# serve [config-json]: the fake bridge on $SOCK; $LOG gets one line per connection
serve() {
  local c=${1:-}; [ -n "$c" ] || c='{}'
  printf '%s' "$c" > "$CFG"
  python3 -I "$SERVER" "$SOCK" "$LOG" "$CFG" &
  SERVER_PID=$!
  local i
  for i in $(seq 1 50); do [ -S "$SOCK" ] && return 0; sleep 0.1; done
  echo "fake server did not come up"; return 1
}

# the PNG served as a route body
png_cfg() {
  printf '{"routes": {"GET /targets": [200, "image/png\\n"], "GET /png": [200, {"file": "%s"}], "POST /copy": [204, ""]}}' "$PNG"
}

# xc ARGS...: the shim in an empty environment, pointed at the fake socket
xc() {
  run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" \
    CLAUDE_ORCA_CLIP_SOCK="$SOCK" "$XCLIP" "$@"
}

# requests: how many lines the server logged
requests() { if [ -f "$LOG" ]; then wc -l < "$LOG" | tr -d ' '; else echo 0; fi; }
# field N of log line L (1-based) -- via python, the log is JSON
logfield() { python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[int(sys.argv[2])-1])[sys.argv[3]])' "$LOG" "$1" "$2"; }

@test "xclip: a plain text read exits 1 and makes NO request" {
  serve "$(png_cfg)"
  xc -selection clipboard -o
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  xc -o
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(requests)" -eq 0 ]
}

@test "xclip: a read of any non-image target is text -> exit 1, NO request" {
  serve "$(png_cfg)"
  for t in text/plain UTF8_STRING STRING text/html image/jpeg targets; do
    xc -selection clipboard -t "$t" -o
    [ "$status" -eq 1 ]
    [ -z "$output" ]
  done
  [ "$(requests)" -eq 0 ]
}

@test "xclip: -t TARGETS -o asks GET /targets and prints what the Mac said" {
  serve "$(png_cfg)"
  xc -selection clipboard -t TARGETS -o
  [ "$status" -eq 0 ]
  [ "$output" = "image/png" ]
  [ "$(requests)" -eq 1 ]
  [ "$(logfield 1 method)" = GET ]
  [ "$(logfield 1 path)" = /targets ]
}

@test "xclip: -t image/png -o asks GET /png and the bytes come back untouched" {
  serve "$(png_cfg)"
  env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" \
    CLAUDE_ORCA_CLIP_SOCK="$SOCK" "$XCLIP" -selection clipboard -t image/png -o > "$BATS_TEST_TMPDIR/got.png"
  cmp "$PNG" "$BATS_TEST_TMPDIR/got.png"
  [ "$(requests)" -eq 1 ]
  [ "$(logfield 1 path)" = /png ]
}

@test "xclip: flag spellings and order do not matter (-out -target -sel, -t before -o)" {
  serve "$(png_cfg)"
  xc -out -target TARGETS -sel clipboard
  [ "$status" -eq 0 ] && [ "$output" = "image/png" ]
  xc -quiet -display :0 -o -t TARGETS -selection clipboard -loops 1
  [ "$status" -eq 0 ] && [ "$output" = "image/png" ]
  xc -selection clipboard -t image/png -out
  [ "$status" -eq 0 ]
  [ "$(requests)" -eq 3 ]
  [ "$(logfield 3 path)" = /png ]
}

@test "xclip: -i posts the text to /copy with its length; -in and no flag at all do too" {
  serve "$(png_cfg)"
  run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" CLAUDE_ORCA_CLIP_SOCK="$SOCK" \
    bash -c "printf 'hello mac' | '$XCLIP' -selection clipboard -i"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(logfield 1 method)" = POST ]
  [ "$(logfield 1 path)" = /copy ]
  [ "$(logfield 1 length)" = 9 ]
  [ "$(logfield 1 body)" = "hello mac" ]
  run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" CLAUDE_ORCA_CLIP_SOCK="$SOCK" \
    bash -c "printf 'second' | '$XCLIP' -in; printf 'third' | '$XCLIP'"
  [ "$status" -eq 0 ]
  [ "$(requests)" -eq 3 ]
  [ "$(logfield 3 body)" = third ]
}

@test "xclip: -i of an image target, or of more than 1 MB, sends nothing and exits 1" {
  serve "$(png_cfg)"
  run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" CLAUDE_ORCA_CLIP_SOCK="$SOCK" \
    bash -c "printf 'x' | '$XCLIP' -selection clipboard -t image/png -i"
  [ "$status" -eq 1 ]
  run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" CLAUDE_ORCA_CLIP_SOCK="$SOCK" \
    bash -c "head -c 1048577 /dev/zero | tr '\\0' a | '$XCLIP' -i"
  [ "$status" -eq 1 ]
  [ "$(requests)" -eq 0 ]
}

@test "xclip: no socket at all -> exit 1, no output, no error text, no delay to speak of" {
  [ ! -e "$SOCK" ]
  local t0=$SECONDS
  xc -selection clipboard -t TARGETS -o
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  xc -selection clipboard -t image/png -o
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ $((SECONDS - t0)) -lt 2 ]
}

@test "xclip: a 204 on /targets and a 404 on /png -> exit 1 with nothing printed (stdout and stderr)" {
  serve '{"routes": {"GET /targets": [204, ""]}}'
  run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" CLAUDE_ORCA_CLIP_SOCK="$SOCK" \
    bash -c "'$XCLIP' -selection clipboard -t TARGETS -o 2>&1"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" CLAUDE_ORCA_CLIP_SOCK="$SOCK" \
    bash -c "'$XCLIP' -selection clipboard -t image/png -o 2>&1"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # a real answer is final: one connection each, never retried
  [ "$(requests)" -eq 2 ]
}

@test "xclip: a 413 (image too big) is final too -> exit 1, nothing printed, one try" {
  serve '{"routes": {"GET /png": [413, "too big"]}}'
  run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" CLAUDE_ORCA_CLIP_SOCK="$SOCK" \
    bash -c "'$XCLIP' -t image/png -o 2>&1"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(requests)" -eq 1 ]
}

@test "xclip: a connection the listener drops is retried: 3 tries, 0.1 s apart, then gives up" {
  serve '{"drop_first": 2, "routes": {"GET /targets": [200, "image/png\n"]}}'
  xc -selection clipboard -t TARGETS -o
  [ "$status" -eq 0 ]
  [ "$output" = "image/png" ]
  [ "$(requests)" -eq 3 ]
  run python3 -I -c '
import json, sys
ts = [json.loads(l)["t"] for l in open(sys.argv[1])]
gaps = [b - a for a, b in zip(ts, ts[1:])]
print(" ".join("%.3f" % g for g in gaps))
sys.exit(0 if all(0.09 <= g < 0.6 for g in gaps) else 1)' "$LOG"
  [ "$status" -eq 0 ]
  # three drops in a row: exactly three tries, then exit 1 with nothing printed
  rm -f "$LOG"
  printf '{"drop_first": 99, "routes": {}}' > "$CFG"
  xc -selection clipboard -t image/png -o
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(requests)" -eq 3 ]
}

@test "xclip: a stale socket file nobody listens on -> exit 1, nothing printed" {
  python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$SOCK"
  [ -S "$SOCK" ]
  run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" CLAUDE_ORCA_CLIP_SOCK="$SOCK" \
    bash -c "'$XCLIP' -selection clipboard -t TARGETS -o 2>&1"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "xclip: -version answers without reading stdin or touching the socket" {
  serve "$(png_cfg)"
  run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" CLAUDE_ORCA_CLIP_SOCK="$SOCK" "$XCLIP" -version < /dev/null
  [ "$status" -eq 0 ]
  [ "$(requests)" -eq 0 ]
}

@test "xclip: bin/xclip is a symlink to the shim, and a pane's interactive zsh finds it before /usr/bin/xclip" {
  # bin/xclip is the name on PATH; it must resolve to the executable script
  [ -L "$ROOT/bin/xclip" ]
  [ "$(readlink -f "$ROOT/bin/xclip")" = "$(readlink -f "$XCLIP")" ]
  [ -x "$ROOT/bin/xclip" ]
  # the folder a pane runs in, as a fixture: its own HOME, its own .zshrc copy
  # (config-sync copies config/.zshrc there) and a template clone whose bin/ is
  # this repo's bin/
  local fx="$BATS_TEST_TMPDIR/pane"
  case "$fx" in "$BATS_TEST_TMPDIR"/pane) ;; *) return 1 ;; esac
  mkdir -p "$fx/.claude-dev/home" "$fx/.claude-dev/template"
  ln -s "$ROOT/bin" "$fx/.claude-dev/template/bin"
  cp "$ROOT/config/.zshrc" "$fx/.claude-dev/home/.zshrc"
  # /usr/bin/xclip is the competitor: the image installs the real one
  [ -x /usr/bin/xclip ]
  run env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$fx/.claude-dev/home" \
    PROJECT_DIR="$fx" CLAUDE_ORCA_HOST_DIR="$fx/none" \
    /usr/bin/zsh -ic 'command -v xclip' 2>/dev/null </dev/null
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "$fx/.claude-dev/template/bin/xclip" ]
  [ "$(readlink -f "$fx/.claude-dev/template/bin/xclip")" = "$(readlink -f "$XCLIP")" ]
}
