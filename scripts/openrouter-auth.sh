#!/usr/bin/env bash
#
# openrouter-auth -- the in-tab OpenRouter sign-in helper (S2,
# claude-orca-bbk.2, plan .claude/plans/openrouter-auth.md). Meant to run
# inside a focused Orca terminal opened by `tier-set auth openrouter` (S3),
# but works fine invoked directly.
#
# What it does, in order: prints where to get a key; reads one from stdin
# (silently, if this is a real terminal); rejects anything that is not
# shaped like an OpenRouter key WITHOUT writing anything; validates it
# against OpenRouter WITHOUT writing anything on rejection; persists it to
# the same .openrouter.key file the Mac-side `claude-dev key openrouter`
# writes (mode 600, umask 077, never through a symlink); and starts the
# OpenRouter guard on CLAUDE_ORCA_GUARD_PORT if nothing is listening there
# yet, so an OpenRouter worker can run in THIS session without a restart.
#
# The key never touches argv (readable via `ps`) or stdout/stderr: it is
# read from stdin, piped to the validator over stdin, written straight to
# the key file, and handed to the guard as an environment variable on a
# background process, never as a command-line argument.
#
# Env knobs (all optional):
#   OPENROUTER_AUTH_KEY_FILE     where the key is written
#                                 (default: $HOME/.openrouter.key)
#   OPENROUTER_AUTH_VALIDATE_CMD a command run with the key on stdin;
#                                 exit 0 accepts, non-zero rejects
#                                 (default: hit openrouter.ai/api/v1/key)
#   CLAUDE_ORCA_GUARD_PORT       the guard's loopback port (default: 4141)
#   CLAUDE_ORCA_ROOT             the folder root the guard's run dir hangs
#                                 off of (default: $PWD)
#
# Exit 0 only once the key is validated, persisted, and a guard answers on
# its port (or one already did). Exit non-zero on any rejection -- nothing
# is written to disk in that case.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SCRIPT="$SCRIPT_DIR/container/openrouter-guard.py"

OPENROUTER_AUTH_KEY_FILE="${OPENROUTER_AUTH_KEY_FILE:-$HOME/.openrouter.key}"
CLAUDE_ORCA_GUARD_PORT="${CLAUDE_ORCA_GUARD_PORT:-4141}"
RUN_DIR="${CLAUDE_ORCA_ROOT:-$PWD}/.claude-dev/run"

KEY_FORMAT_RE='^sk-or-v1-[A-Za-z0-9._-]{16,}$'

# The default validator: a real network call to OpenRouter, key on stdin,
# never on argv. Only HTTP 200 counts as accepted.
openrouter_auth_default_validate() {
    python3 -c '
import sys
import urllib.error
import urllib.request

key = sys.stdin.readline().strip()
if not key:
    sys.exit(1)
req = urllib.request.Request(
    "https://openrouter.ai/api/v1/key",
    headers={"Authorization": "Bearer " + key},
)
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        sys.exit(0 if resp.status == 200 else 1)
except urllib.error.HTTPError:
    sys.exit(1)
except Exception:
    sys.exit(1)
'
}

port_open() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1
}

echo "OpenRouter sign-in"
echo "Get a key at https://openrouter.ai/keys (needs no special scopes)."
echo

key=""
if [ -t 0 ]; then
    printf 'Paste the key and press Enter (input hidden): '
    IFS= read -rs key || true
    printf '\n'
else
    IFS= read -r key || true
fi

# Whitespace is never part of a valid key -- strip all of it rather than
# just the ends, so a pasted newline/CR or stray space never fails a key
# that would otherwise be fine.
key="$(printf '%s' "$key" | tr -d '[:space:]')"

if ! [[ "$key" =~ $KEY_FORMAT_RE ]]; then
    echo "openrouter-auth: that does not look like an OpenRouter key (expected sk-or-v1-...) -- nothing written." >&2
    exit 1
fi

# No eval: the override knob names a command to exec directly, never shell
# text to interpret -- this script handles a live credential and takes no
# chances with an environment variable as code.
if [ -n "${OPENROUTER_AUTH_VALIDATE_CMD:-}" ]; then
    validated=0
    printf '%s' "$key" | "$OPENROUTER_AUTH_VALIDATE_CMD" || validated=1
else
    validated=0
    printf '%s' "$key" | openrouter_auth_default_validate || validated=1
fi

if [ "$validated" -ne 0 ]; then
    echo "openrouter-auth: OpenRouter did not accept that key -- nothing written." >&2
    exit 1
fi

key_dir="$(dirname -- "$OPENROUTER_AUTH_KEY_FILE")"
mkdir -p -- "$key_dir"
# Unlink first, always: `>` follows a symlink, so a link planted at the key
# file's path would send the key through it into whatever it points at.
# rm -f removes the link itself (or a plain file) without ever following
# it, so the write below can only ever land on a fresh regular file --
# mirrors the same care in scripts/launcher.sh's cmd_key_v3.
rm -f -- "$OPENROUTER_AUTH_KEY_FILE"
(
    umask 077
    printf '%s\n' "$key" > "$OPENROUTER_AUTH_KEY_FILE"
)
chmod 600 -- "$OPENROUTER_AUTH_KEY_FILE"
key_file_abs="$(cd -- "$key_dir" && pwd)/$(basename -- "$OPENROUTER_AUTH_KEY_FILE")"
echo "Key saved to $key_file_abs (mode 600)."

mkdir -p -- "$RUN_DIR"

if port_open "$CLAUDE_ORCA_GUARD_PORT"; then
    echo "A guard is already listening on 127.0.0.1:$CLAUDE_ORCA_GUARD_PORT -- leaving it running."
else
    if [ ! -f "$GUARD_SCRIPT" ]; then
        echo "openrouter-auth: guard script not found at $GUARD_SCRIPT" >&2
        exit 1
    fi
    echo "Starting the OpenRouter guard on 127.0.0.1:$CLAUDE_ORCA_GUARD_PORT ..."
    OPENROUTER_API_KEY="$key" python3 "$GUARD_SCRIPT" \
        --port "$CLAUDE_ORCA_GUARD_PORT" --run-dir "$RUN_DIR" \
        >"$RUN_DIR/openrouter-guard.boot.log" 2>&1 &
    guard_pid=$!
    disown "$guard_pid" 2>/dev/null || true

    up=false
    for _ in $(seq 1 150); do
        if port_open "$CLAUDE_ORCA_GUARD_PORT"; then
            up=true
            break
        fi
        sleep 0.2
    done

    if [ "$up" != true ]; then
        echo "openrouter-auth: the guard did not come up on port $CLAUDE_ORCA_GUARD_PORT within 30s" >&2
        echo "openrouter-auth: see $RUN_DIR/openrouter-guard.boot.log" >&2
        exit 1
    fi

    printf '%s\n' "$guard_pid" > "$RUN_DIR/openrouter-guard.pid"
    echo "Guard is up (pid $guard_pid)."
fi

echo
echo "Key file: $key_file_abs"
echo "Guard port: $CLAUDE_ORCA_GUARD_PORT"
echo "Done. Run this next:"
echo "  /tier worker glm-flash"
