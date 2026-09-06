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
# startup v4 (claude-orca-qa2.10) gives it a second job: the same script,
# run on the PUBLIC base image with this checkout mounted, is the only
# proof of the runtime-install path a folder takes when it cannot pull the
# prebuilt image --
#
#   docker run --rm -v "$PWD:/opt/claude-orca-mount" -e CLAUDE_ORCA_SMOKE=1 \
#       docker.io/library/ubuntu:24.04 \
#       bash /opt/claude-orca-mount/scripts/container/smoke.sh
#
# (see .github/workflows/image.yml for both invocations)
#
# So nothing here may assume /opt/claude-orca exists or that the toolchain
# is installed yet: it creates its own throwaway git project, puts the
# checkout it was run from at <project>/.claude-dev/template (which is
# exactly where the entrypoint looks when /opt/claude-orca is absent), runs
# the real entrypoint against it -- setup.sh and all -- and only then
# asserts that the pinned toolchain is on PATH and that Orca comes up
# headless and serves Orca Web. Any failure prints the serve log and exits
# non-zero, so a broken image never reaches the registry.
#
# bash 3.2 clean (scripts/lint-bash32.sh scans all of scripts/).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ENTRYPOINT="$SCRIPT_DIR/entrypoint.sh"
SETUP="$SCRIPT_DIR/setup.sh"
# The root of the copy this script was read from -- /opt/claude-orca on the
# prebuilt image, the mount on a base image.
TEMPLATE_SRC="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

PREBUILT=0
if [ -d /opt/claude-orca ]; then
    PREBUILT=1
fi

PROJECT_DIR="${CLAUDE_ORCA_SMOKE_PROJECT:-/tmp/claude-orca-smoke}"
ORCA_PORT="${ORCA_PORT:-6768}"
# On the prebuilt image the entrypoint's setup is a no-op and Orca serves in
# seconds; on a base image the same wait covers a whole toolchain install.
if [ "$PREBUILT" = "1" ]; then
    TIMEOUT="${CLAUDE_ORCA_WEBURL_TIMEOUT:-120}"
else
    TIMEOUT="${CLAUDE_ORCA_WEBURL_TIMEOUT:-1800}"
fi

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

# The toolchain checks themselves run AFTER the entrypoint, because on a
# base image nothing is installed until setup.sh has run inside it.

# --- enough of a system to build the fixture ----------------------------
#
# git is what makes the throwaway project a repo, and curl is what fetches
# the served page at the end; the base image has neither. setup.sh's base
# phase installs both (and zsh, which the user phase's useradd needs), so
# run those two phases here rather than inventing a second install path.
# On the prebuilt image both are already there and this is skipped.

if ! command -v git >/dev/null 2>&1; then
    printf 'no git yet: running setup.sh --phase base and --phase user first\n'
    if [ ! -x "$SETUP" ]; then
        fail "no setup script at $SETUP"
        exit 1
    fi
    "$SETUP" --phase base || { fail "setup.sh --phase base failed"; exit 1; }
    "$SETUP" --phase user || { fail "setup.sh --phase user failed"; exit 1; }
fi

# --- a throwaway project ------------------------------------------------

rm -rf "$PROJECT_DIR"
mkdir -p "$RUN_DIR" "$PROJECT_DIR/.claude-dev/home"

# Where the entrypoint looks for the template when /opt/claude-orca is not
# there (claude-orca-qa2.9): the folder's own clone, inside the project.
# `container run` bind-mounts that for real; here a symlink to the checkout
# this script came from does the same job.
if [ "$PREBUILT" != "1" ]; then
    ln -sfn "$TEMPLATE_SRC" "$PROJECT_DIR/.claude-dev/template"
    printf 'template for this run: %s -> %s\n' \
        "$PROJECT_DIR/.claude-dev/template" "$TEMPLATE_SRC"
fi

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

# --- the toolchain the image promises -----------------------------------
#
# Installed by the Dockerfile on the prebuilt image and by the entrypoint's
# own setup.sh run on a base image -- either way it has to be here by the
# time Orca is serving.

check_version "claude" claude --version
check_version "bd" bd --version
check_version "orca cli" "${ORCA_CLI:-/opt/orca/resources/bin/orca-ide}" --version

# Orca serve refuses to start with no usable display server, and spawns a
# virtual one of its own when the binary is installed -- so what matters
# here is only that an X server exists. Reported by glob rather than by
# name so a bare image says so up front instead of at the serve timeout.
x_servers=""
for x in /usr/bin/X?*; do
    if [ -x "$x" ] && [ ! -d "$x" ]; then
        x_servers="$x_servers $x"
    fi
done
if [ -n "$x_servers" ]; then
    pass "display server(s):$x_servers"
else
    printf 'WARN -- no X display server under /usr/bin\n' >&2
fi

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

# The entrypoint seeds Orca's own state before serve starts (v3 S4,
# claude-orca-qa2.5): the per-repo worktree base path inside the folder,
# the theme, the agent env. Orca keeps it per profile, so glob the profile
# dir rather than naming `local-default` here.
# The entrypoint drops to `agent` when it can, so look where IT put the
# user-data dir, not where root's HOME points.
agent_home=""
if [ -n "${ORCA_USER_DATA_DIR:-}" ]; then
    user_data_dir="$ORCA_USER_DATA_DIR"
else
    agent_home="$(getent passwd "${CLAUDE_ORCA_AGENT_USER:-agent}" 2>/dev/null | cut -d: -f6)"
    [ -n "$agent_home" ] || agent_home="$HOME"
    user_data_dir="$agent_home/.config/orca"
fi

seed_file=""
for f in "$user_data_dir"/profiles/*/orca-data.json; do
    if [ -f "$f" ]; then
        seed_file="$f"
        break
    fi
done
if [ -n "$seed_file" ]; then
    pass "orca state seeded: $seed_file"
    if grep -q "$PROJECT_DIR/.orca-worktrees" "$seed_file"; then
        pass "seeded worktree base path is inside the project"
    else
        fail "no $PROJECT_DIR/.orca-worktrees in $seed_file"
    fi
else
    fail "no orca-data.json under $user_data_dir/profiles/"
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
