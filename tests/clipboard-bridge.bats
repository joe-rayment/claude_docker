#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Guards:   the Mac end of the clipboard bridge: clip-serve answers only the
#           image routes (and POST /copy), never hands out clipboard text,
#           and clip-listen serves back-to-back requests over a private unix
#           socket and shuts itself down when the ssh session is gone.
# Fails if: a GET route ever returns text, an oversize image or POST gets
#           through, a temp dir is left behind, a second request after the
#           first hangs, or the watchdog leaves nc or the socket running.
# Run:      bats tests/clipboard-bridge.bats
#
# Every Mac tool (osascript, sips, pbcopy) is a stub driven by STUB_* env
# vars; the clip-listen cases use the REAL OpenBSD nc and curl.

setup() {
    ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    SERVE=$ROOT/scripts/mac/clip-serve
    LISTEN=$ROOT/scripts/mac/clip-listen
    FIX=$ROOT/tests/fixtures/clipboard/red-8x8.png
    # the real OpenBSD nc the clip-listen cases run behind (read before HOME
    # becomes a fixture); any nc on PATH when that build is absent
    NC_REAL=$HOME/.cache/claude-orca-test/netcat/bin/nc.openbsd
    [ -x "$NC_REAL" ] || NC_REAL=$(command -v nc || true)
    export PROJECT_DIR=$BATS_TEST_TMPDIR/project
    export CLAUDE_ORCA_ROOT=$BATS_TEST_TMPDIR/root
    export HOME=$BATS_TEST_TMPDIR/home
    STUBS=$BATS_TEST_TMPDIR/stubs
    STATE=$HOME/.local/state/claude-dev
    RESP=$BATS_TEST_TMPDIR/resp
    ERR=$BATS_TEST_TMPDIR/err
    BODY=$BATS_TEST_TMPDIR/body
    mkdir -p "$PROJECT_DIR" "$CLAUDE_ORCA_ROOT" "$HOME" "$STUBS"
    # every destructive path below lives under the fixture
    [[ $STATE == "$BATS_TEST_TMPDIR"/* ]]
    export STUB_LOG=$BATS_TEST_TMPDIR/stub.log
    export STUB_PBCOPY_OUT=$BATS_TEST_TMPDIR/pbcopy.out
    export STUB_SIPS_SRC=$FIX
    export CLAUDE_ORCA_OSASCRIPT=$STUBS/osascript
    export CLAUDE_ORCA_SIPS=$STUBS/sips
    export CLAUDE_ORCA_PBCOPY=$STUBS/pbcopy
    make_stubs
}

make_stubs() {
    cat >"$STUBS/osascript" <<'EOF'
#!/bin/bash
all="$*"
printf 'osascript %s\n' "$all" >>"$STUB_LOG"
case "$all" in
    *'clipboard info'*)
        printf '%s\n' "${STUB_CLIP_INFO-}"
        exit 0 ;;
    *'POSIX path of'*)
        printf '%s\n' "${STUB_FURL-}"
        exit 0 ;;
    *'open for access'*)
        dest=$(printf '%s\n' "$all" | sed -n 's/.*POSIX file "\([^"]*\)".*/\1/p')
        case "$all" in
            *'class PNGf'*) src=${STUB_PNG_SRC-} ;;
            *'class TIFF'*) src=${STUB_TIFF_SRC-} ;;
            *) src= ;;
        esac
        [ -n "$src" ] || exit 1
        cp "$src" "$dest"
        exit 0 ;;
esac
exit 1
EOF
    cat >"$STUBS/sips" <<'EOF'
#!/bin/bash
printf 'sips %s\n' "$*" >>"$STUB_LOG"
[ "$1 $2 $3 $5" = "-s format png --out" ] || exit 1
cp "$STUB_SIPS_SRC" "$6"
EOF
    cat >"$STUBS/pbcopy" <<'EOF'
#!/bin/bash
: >"$STUB_PBCOPY_OUT.called"
cat >"$STUB_PBCOPY_OUT"
EOF
    chmod +x "$STUBS/osascript" "$STUBS/sips" "$STUBS/pbcopy"
}

# get PATH -- one GET through clip-serve; response in $RESP, log line in $ERR
get() {
    printf 'GET %s HTTP/1.0\r\n\r\n' "$1" | "$SERVE" >"$RESP" 2>"$ERR"
}

# split the response: $HEAD (status line + headers), $BODY (bytes after them)
split_resp() {
    local n off
    n=$(grep -an -m1 $'^\r$' "$RESP" | cut -d: -f1)
    off=$(($(head -n "$n" "$RESP" | wc -c) + 1))
    head -n "$n" "$RESP" >"$BODY.head"
    tail -c +"$off" "$RESP" >"$BODY"
}

status() { head -n1 "$RESP" | cut -d' ' -f2; }

# a clipboard holding a PNG image
clip_png() {
    export STUB_CLIP_INFO='«class PNGf», 75, «class TIFF», 80'
    export STUB_PNG_SRC=$FIX
}

# a Finder file copy: furl_file NAME CONTENT
furl_file() {
    printf '%s' "$2" >"$BATS_TEST_TMPDIR/$1"
    export STUB_CLIP_INFO='«class furl», 30'
    export STUB_FURL=$BATS_TEST_TMPDIR/$1
}

@test "GET /targets lists image/png when the clipboard holds an image" {
    clip_png
    get /targets
    [ "$(status)" = 200 ]
    split_resp
    [ "$(cat "$BODY")" = "image/png" ]
    grep -q 'Content-Length: 10' "$BODY.head"
}

@test "GET /png serves the PNGf bytes exactly, with Content-Length" {
    clip_png
    get /png
    [ "$(status)" = 200 ]
    split_resp
    cmp "$BODY" "$FIX"
    grep -q 'Content-Type: image/png' "$BODY.head"
    grep -q 'Content-Length: 75' "$BODY.head"
}

@test "GET /png: a TIFF-only clipboard goes through sips" {
    export STUB_CLIP_INFO='«class TIFF», 80'
    printf 'II*fake-tiff' >"$BATS_TEST_TMPDIR/fake.tiff"
    export STUB_TIFF_SRC=$BATS_TEST_TMPDIR/fake.tiff
    get /targets
    [ "$(status)" = 200 ]
    get /png
    [ "$(status)" = 200 ]
    split_resp
    cmp "$BODY" "$FIX"
    grep -q 'sips -s format png .*/clip.tiff --out ' "$STUB_LOG"
}

@test "GET /png: a copied PNG file is served as is, sips never called" {
    furl_file pic.png placeholder
    cp "$FIX" "$BATS_TEST_TMPDIR/pic.png"
    get /targets
    [ "$(status)" = 200 ]
    get /png
    [ "$(status)" = 200 ]
    split_resp
    cmp "$BODY" "$FIX"
    run ! grep -q '^sips' "$STUB_LOG"
}

@test "GET /png: a copied .JPG file goes through sips" {
    furl_file Photo.JPG 'not-really-a-jpeg'
    get /png
    [ "$(status)" = 200 ]
    split_resp
    cmp "$BODY" "$FIX"
    grep -q "^sips -s format png $STUB_FURL --out " "$STUB_LOG"
}

@test "GET /png: a file named .png that is not a PNG goes through sips" {
    furl_file lie.png 'plain text pretending'
    get /png
    [ "$(status)" = 200 ]
    grep -q "^sips -s format png $STUB_FURL --out " "$STUB_LOG"
}

@test "a copied non-image file (.txt) is no image: 204 targets, 404 png" {
    furl_file notes.txt 'secret notes'
    get /targets
    [ "$(status)" = 204 ]
    get /png
    [ "$(status)" = 404 ]
    run ! grep -q 'open for access' "$STUB_LOG"
    run ! grep -q '^sips' "$STUB_LOG"
}

@test "a text-only clipboard: 204 / 404, and only 'clipboard info' ever runs" {
    export STUB_CLIP_INFO='«class utf8», 12, string, 12'
    get /targets
    [ "$(status)" = 204 ]
    get /png
    [ "$(status)" = 404 ]
    [ "$(wc -l <"$STUB_LOG" | tr -d ' ')" = 2 ]
    [ "$(grep -vc 'clipboard info' "$STUB_LOG")" = 0 ]
}

@test "GET /png over the size cap is 413 with no body" {
    clip_png
    export CLAUDE_ORCA_CLIP_MAX_BYTES=10
    get /png
    [ "$(status)" = 413 ]
    split_resp
    [ ! -s "$BODY" ]
}

@test "a copied image file over the cap is 413 before sips runs" {
    furl_file big.jpg 'a-jpeg-bigger-than-the-cap'
    export CLAUDE_ORCA_CLIP_MAX_BYTES=10
    get /png
    [ "$(status)" = 413 ]
    run ! grep -q '^sips' "$STUB_LOG"
}

@test "POST /copy hands pbcopy exactly Content-Length bytes and answers 204" {
    local text=$'h\303\251llo\nline2'
    local len
    len=$(printf '%s' "$text" | wc -c | tr -d ' ')
    printf 'POST /copy HTTP/1.0\r\ncontent-length: %s\r\n\r\n%sTRAILING-JUNK' "$len" "$text" |
        "$SERVE" >"$RESP" 2>"$ERR"
    [ "$(status)" = 204 ]
    [ "$(cat "$STUB_PBCOPY_OUT"; echo x)" = "${text}x" ]
}

@test "POST /copy over 1 MB is 413 and pbcopy is never run" {
    printf 'POST /copy HTTP/1.0\r\nContent-Length: 1048577\r\n\r\n' | "$SERVE" >"$RESP" 2>"$ERR"
    [ "$(status)" = 413 ]
    [ ! -e "$STUB_PBCOPY_OUT.called" ]
}

@test "POST /copy without a usable Content-Length is 400 and pbcopy is never run" {
    printf 'POST /copy HTTP/1.0\r\n\r\nsome body' | "$SERVE" >"$RESP" 2>"$ERR"
    [ "$(status)" = 400 ]
    printf 'POST /copy HTTP/1.0\r\nContent-Length: lots\r\n\r\nsome body' | "$SERVE" >"$RESP" 2>"$ERR"
    [ "$(status)" = 400 ]
    [ ! -e "$STUB_PBCOPY_OUT.called" ]
}

@test "unknown routes (text, copy by GET, junk) are 404 and osascript never runs" {
    clip_png
    get /text
    [ "$(status)" = 404 ]
    get /copy
    [ "$(status)" = 404 ]
    get /
    [ "$(status)" = 404 ]
    printf 'POST /png HTTP/1.0\r\nContent-Length: 0\r\n\r\n' | "$SERVE" >"$RESP" 2>"$ERR"
    [ "$(status)" = 404 ]
    printf 'DELETE /targets HTTP/1.0\r\n\r\n' | "$SERVE" >"$RESP" 2>"$ERR"
    [ "$(status)" = 404 ]
    [ ! -e "$STUB_LOG" ]
    [ ! -e "$STUB_PBCOPY_OUT.called" ]
}

@test "no clip-serve.* temp dir is left in the state dir, whatever the outcome" {
    clip_png
    get /png
    [ "$(status)" = 200 ]
    # the stub saw the private dir under the fixture state dir, so the check
    # below is looking at the right place
    grep -q "$STATE/clip-serve\." "$STUB_LOG"
    export STUB_TIFF_SRC=$FIX STUB_CLIP_INFO='«class TIFF», 80'
    get /png
    [ "$(status)" = 200 ]
    CLAUDE_ORCA_CLIP_MAX_BYTES=10 get /png
    [ "$(status)" = 413 ]
    [ -d "$STATE" ]
    [ -z "$(find "$STATE" -name 'clip-serve.*')" ]
}

@test "the request log line names route and code, never a POST body" {
    printf 'POST /copy HTTP/1.0\r\nContent-Length: 15\r\n\r\nsekrit-body-123' | "$SERVE" >"$RESP" 2>"$ERR"
    [ "$(status)" = 204 ]
    [ "$(wc -l <"$ERR" | tr -d ' ')" = 1 ]
    grep -q 'POST /copy -> 204' "$ERR"
    run ! grep -q 'sekrit' "$ERR"
}

# --- clip-listen: the REAL nc and curl, stubbed ssh -------------------------

teardown() {
    if [ -n "${LPID:-}" ] && kill -0 "$LPID" 2>/dev/null; then
        kill -TERM "$LPID" 2>/dev/null
        wait "$LPID" 2>/dev/null
    fi
    case "${SOCKDIR:-}" in
        /tmp/cdev-clip-*) rm -rf "$SOCKDIR" ;;
    esac
}

# start_listener -- clip-listen on a short socket path in a dir it must create
start_listener() {
    [ -n "${SOCKDIR:-}" ] || SOCKDIR=$(mktemp -d /tmp/cdev-clip-XXXXXX)
    SOCK=$SOCKDIR/sub/clip.sock
    LOG=$SOCKDIR/sub/clip.log
    ln -sf "$NC_REAL" "$STUBS/nc"
    cat >"$STUBS/ssh" <<'EOF'
#!/bin/bash
printf 'ssh %s\n' "$*" >>"$STUB_LOG"
[ -e "$STUB_SSH_DOWN" ] && exit 1
exit 0
EOF
    chmod +x "$STUBS/ssh"
    export STUB_SSH_DOWN=$BATS_TEST_TMPDIR/ssh-down
    export CLAUDE_ORCA_CLIP_WATCH_S=1
    PATH=$STUBS:$PATH
    "$LISTEN" "$SOCK" "$BATS_TEST_TMPDIR/ssh_config" myhost 3>&- &
    LPID=$!
    local i
    for i in $(seq 60); do
        [ -S "$SOCK" ] && return 0
        sleep 0.05
    done
    return 1
}

# fetch ROUTE OUTFILE -- one request over the socket; retries cover the short
# gap while the listener re-arms for the next connection
fetch() {
    local i
    for i in $(seq 60); do
        if curl -sS --fail --max-time 5 --unix-socket "$SOCK" "http://clip/$1" -o "$2" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# wait_gone -- the listener exits by itself within ~6 s
wait_gone() {
    local i
    for i in $(seq 120); do
        kill -0 "$LPID" 2>/dev/null || return 0
        sleep 0.05
    done
    return 1
}

# bats test_tags=size:medium
@test "clip-listen serves 20 back-to-back TARGETS+PNG pairs on a private socket" {
    clip_png
    start_listener
    run ls -ld "$SOCKDIR/sub"
    [[ ${output:0:10} == drwx------ ]]
    run ls -l "$SOCK"
    [[ ${output:0:10} == s???------ ]]
    local i
    for i in $(seq 20); do
        fetch targets "$BODY.t"
        [ "$(cat "$BODY.t")" = "image/png" ]
        fetch png "$BODY.p"
        cmp "$BODY.p" "$FIX"
    done
    [ "$(grep -c 'clip-serve: GET .* -> 200' "$LOG")" = 40 ]
}

# bats test_tags=size:medium
@test "clip-listen exits, and leaves no socket, fifo, pidfile or nc, once ssh -O check fails" {
    clip_png
    start_listener
    fetch png "$BODY.p"
    cmp "$BODY.p" "$FIX"
    [ -f "$SOCKDIR/sub/clip.pid" ]
    touch "$STUB_SSH_DOWN"
    wait_gone
    wait "$LPID"
    LPID=
    [ "$(ls -A "$SOCKDIR/sub")" = "clip.log" ]
    grep -q "^ssh -F $BATS_TEST_TMPDIR/ssh_config -O check myhost\$" "$STUB_LOG"
    run pgrep -f "$SOCKDIR"
    [ "$status" -eq 1 ]
}

# bats test_tags=size:medium
@test "a second clip-listen for a live socket is a no-op; SIGTERM cleans up" {
    start_listener
    [ "$(cat "$SOCKDIR/sub/clip.pid")" = "$LPID" ]
    run "$LISTEN" "$SOCK" "$BATS_TEST_TMPDIR/ssh_config" myhost
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$SOCKDIR/sub/clip.pid")" = "$LPID" ]
    [ -S "$SOCK" ]
    kill -TERM "$LPID"
    wait_gone
    wait "$LPID"
    LPID=
    [ "$(ls -A "$SOCKDIR/sub")" = "clip.log" ]
    run pgrep -f "$SOCKDIR"
    [ "$status" -eq 1 ]
}

# bats test_tags=size:medium
@test "a pidfile naming a live process that is not clip-listen does not block start" {
    SOCKDIR=$(mktemp -d /tmp/cdev-clip-XXXXXX)
    mkdir "$SOCKDIR/sub"
    printf '%s\n' "$$" >"$SOCKDIR/sub/clip.pid"
    start_listener
    [ "$(cat "$SOCKDIR/sub/clip.pid")" = "$LPID" ]
}
