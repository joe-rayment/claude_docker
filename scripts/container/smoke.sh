#!/usr/bin/env bash
#
# smoke.sh -- proves a freshly built claude_orca image actually works, from
# inside it (v3 S1, claude-orca-qa2.1). CI runs this as the container's
# command on the linux/amd64 image it just built, before anything is
# pushed:
#
#   <runtime> run --rm -e CLAUDE_ORCA_SMOKE=1 <image> \
#       /opt/claude-orca/scripts/container/smoke.sh
#
# (see .github/workflows/image.yml for the exact invocation)
#
# It creates its own throwaway git project, runs the real entrypoint
# against it, and asserts that Orca comes up headless and serves Orca Web
# -- plus that the pinned toolchain (Claude Code, beads, the Orca CLI) is
# on PATH. Any failure prints the serve log and exits non-zero, so a
# broken image never reaches the registry.
#
# bash 3.2 clean (scripts/lint-bash32.sh scans all of scripts/).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ENTRYPOINT="$SCRIPT_DIR/entrypoint.sh"

PROJECT_DIR="${CLAUDE_ORCA_SMOKE_PROJECT:-/tmp/claude-orca-smoke}"
ORCA_PORT="${ORCA_PORT:-6768}"
TIMEOUT="${CLAUDE_ORCA_WEBURL_TIMEOUT:-120}"

RUN_DIR="$PROJECT_DIR/.claude-dev/run"
URL_FILE="$RUN_DIR/orca-web-url.txt"
SERVE_LOG="$RUN_DIR/orca-serve.log"

failures=0
pass() { printf 'ok   -- %s\n' "$*"; }
fail() { printf 'FAIL -- %s\n' "$*" >&2; failures=$((failures + 1)); }

dump_and_exit() {
    printf '\n--- orca-serve.log (tail) ---\n' >&2
    tail -60 "$SERVE_LOG" >&2 2>/dev/null || echo "(no serve log)" >&2
    exit 1
}

# --- the toolchain the image promises -----------------------------------

check_version() {
    label="$1"; shift
    if ! out="$("$@" 2>&1)"; then
        fail "$label: '$*' exited non-zero: $(printf '%s' "$out" | head -2)"
        return 1
    fi
    if [ -z "$out" ]; then
        fail "$label: '$*' printed nothing"
        return 1
    fi
    pass "$label: $(printf '%s' "$out" | head -1)"
}

check_version "claude" claude --version
check_version "bd" bd --version
check_version "orca cli" "${ORCA_CLI:-/opt/orca/resources/bin/orca-ide}" --version

# --- a throwaway project ------------------------------------------------

rm -rf "$PROJECT_DIR"
mkdir -p "$RUN_DIR" "$PROJECT_DIR/.claude-dev/home"
git init --quiet -b main "$PROJECT_DIR" >/dev/null 2>&1
git -C "$PROJECT_DIR" -c user.email=smoke@example.com -c user.name=smoke \
    commit --quiet --allow-empty -m smoke >/dev/null 2>&1
if id agent >/dev/null 2>&1; then
    chown -R agent:agent "$PROJECT_DIR" 2>/dev/null || true
fi

# --- run the real entrypoint --------------------------------------------

printf 'starting the entrypoint against %s on port %s\n' "$PROJECT_DIR" "$ORCA_PORT"
PROJECT_DIR="$PROJECT_DIR" ORCA_PORT="$ORCA_PORT" \
    CLAUDE_ORCA_WEBURL_TIMEOUT="$TIMEOUT" \
    bash "$ENTRYPOINT" &
EP_PID=$!

waited=0
while [ "$waited" -lt "$TIMEOUT" ]; do
    [ -s "$URL_FILE" ] && break
    if ! kill -0 "$EP_PID" 2>/dev/null; then
        fail "the entrypoint exited before writing $URL_FILE"
        dump_and_exit
    fi
    sleep 1
    waited=$((waited + 1))
done

if [ ! -s "$URL_FILE" ]; then
    fail "no $URL_FILE after ${TIMEOUT} s"
    kill -TERM "$EP_PID" 2>/dev/null
    dump_and_exit
fi
pass "web url file written after ${waited} s"

if grep -q 'Orca server ready' "$SERVE_LOG"; then
    pass "serve log says: Orca server ready"
else
    fail "'Orca server ready' never appeared in $SERVE_LOG"
fi

web_url="$(cat "$URL_FILE")"
case "$web_url" in
    *web-index.html*) pass "url points at web-index.html" ;;
    *) fail "url does not name web-index.html: $web_url" ;;
esac
case "$web_url" in
    *'#pairing='*) pass "url carries a pairing offer" ;;
    *) fail "url carries no pairing fragment: $web_url" ;;
esac

port="$(cat "$RUN_DIR/port" 2>/dev/null)"
if [ "$port" = "$ORCA_PORT" ]; then
    pass "run/port is $port"
else
    fail "run/port is '$port', expected '$ORCA_PORT'"
fi

origin="$(printf '%s' "$web_url" | sed -E 's#^(https?://[^/]+).*#\1#')"
code="$(curl -s -o /tmp/smoke-body.html -w '%{http_code}' --max-time 30 "$origin/")"
if [ "$code" = "200" ]; then
    pass "GET $origin/ -> 200"
else
    fail "GET $origin/ -> $code"
fi
if grep -q 'Orca Web' /tmp/smoke-body.html 2>/dev/null; then
    pass "the served page is Orca Web"
else
    fail "the served page does not contain 'Orca Web'"
fi

kill -TERM "$EP_PID" 2>/dev/null
wait "$EP_PID" 2>/dev/null

if [ "$failures" -ne 0 ]; then
    printf '\n%s check(s) failed\n' "$failures" >&2
    dump_and_exit
fi
printf '\nsmoke: all checks passed\n'
exit 0
