#!/usr/bin/env bats

# session-end-audit.bats — SessionEnd hook: scripts/session-end-audit.sh
# dev-logs a note when the session ends with a dirty git tree. New file
# for the S7 port (claude-orca-3sk.7): the old template covered this
# script from inside tests/hook-staging.bats, which is otherwise entirely
# about Dockerfile COPY/chmod hook-staging -- a mechanism this template
# has no equivalent of (bin/<name> symlinks + config-sync replace it, see
# .claude/plans/orca-port.md S7). The two behavioural cases that don't
# depend on that mechanism are re-homed here; hook-staging.bats itself is
# not ported.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/session-end-audit.sh"
SETTINGS="$REPO_ROOT/config/claude-settings.json"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

@test "session-end-audit: scripts/session-end-audit.sh is executable and staged as bin/session-end-audit" {
    [ -x "$SCRIPT" ]
    [ -L "$REPO_ROOT/bin/session-end-audit" ]
    [ "$(readlink "$REPO_ROOT/bin/session-end-audit")" = "../scripts/session-end-audit.sh" ]
}

@test "session-end-audit: config/claude-settings.json registers a SessionEnd hook invoking session-end-audit" {
    run jq -e '[.hooks.SessionEnd[]?.hooks[]? | select(.command | contains("session-end-audit"))] | length > 0' "$SETTINGS"
    [ "$status" -eq 0 ]
}

@test "session-end-audit: logs the dirty file count via dev-log when the tree is dirty" {
    REPO="$BATS_TEST_TMPDIR/dirty-repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email test@example.com
    git -C "$REPO" config user.name test
    echo one > "$REPO/a.txt"
    git -C "$REPO" add a.txt
    git -C "$REPO" commit -q -m init
    echo two >> "$REPO/a.txt"
    echo untracked > "$REPO/b.txt"
    FAKEBIN="$BATS_TEST_TMPDIR/fakebin-dirty"
    mkdir -p "$FAKEBIN"
    CAPTURE="$BATS_TEST_TMPDIR/devlog-dirty.log"
    printf '#!/usr/bin/env bash\necho "$@" >> "%s"\n' "$CAPTURE" > "$FAKEBIN/dev-log"
    chmod +x "$FAKEBIN/dev-log"
    export PATH="$FAKEBIN:$PATH"
    payload="{\"cwd\":\"$REPO\"}"
    run bash -c 'printf "%s" "$1" | "$0"' "$SCRIPT" "$payload"
    [ "$status" -eq 0 ]
    [ -f "$CAPTURE" ]
    grep -q "2 file" "$CAPTURE"
}

@test "session-end-audit: a clean tree logs nothing" {
    REPO="$BATS_TEST_TMPDIR/clean-repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email test@example.com
    git -C "$REPO" config user.name test
    echo one > "$REPO/a.txt"
    git -C "$REPO" add a.txt
    git -C "$REPO" commit -q -m init
    FAKEBIN="$BATS_TEST_TMPDIR/fakebin-clean"
    mkdir -p "$FAKEBIN"
    CAPTURE="$BATS_TEST_TMPDIR/devlog-clean.log"
    printf '#!/usr/bin/env bash\necho "$@" >> "%s"\n' "$CAPTURE" > "$FAKEBIN/dev-log"
    chmod +x "$FAKEBIN/dev-log"
    export PATH="$FAKEBIN:$PATH"
    payload="{\"cwd\":\"$REPO\"}"
    run bash -c 'printf "%s" "$1" | "$0"' "$SCRIPT" "$payload"
    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE" ]
}

@test "session-end-audit: malformed/empty stdin fails open, exit 0" {
    run bash -c 'printf "not json" | "$0"' "$SCRIPT"
    [ "$status" -eq 0 ]
    run bash -c 'printf "" | "$0"' "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "session-end-audit: a cwd outside any git repo fails open, exit 0" {
    run bash -c 'printf "%s" "{\"cwd\":\"$1\"}" | "$0"' "$SCRIPT" "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
}
