#!/usr/bin/env bats

# peers.bats — scripts/peers.sh (installed as peers, SessionStart hook)
# and scripts/session-title.sh (installed as session-title, UserPromptSubmit
# hook): peers prints one line naming the other live Claude sessions on
# this tmux server; session-title renames a worktree session's tmux window
# to a short slug of its first prompt. See .claude/plans/worktree-sessions.md
# and beads_claude_docker-7bam. Depends on F1 (beads_claude_docker-nmnb,
# cs-new).
#
# FROZEN per 7bam's acceptance contract: this file must not be edited
# after its RED commit. If a test here turns out to be wrong, stop and
# report -- do not edit it.
#
# Every tmux test runs on a scratch `tmux -L peers-test-<pid>-<rand>`
# server, never the live server this session is attached to. $TMUX (and,
# ambiently, $TMUX_PANE) are already set in the environment these tests
# run in (a real tmux session), so every invocation below explicitly
# overrides them to target the scratch server -- fake_tmux_env is the same
# technique tests/worktree-sessions.bats and tests/tmux-fleet.bats already
# use for cs-new/fleet-menu.

PEERS=/workspace/scripts/peers.sh
SESSION_TITLE=/workspace/scripts/session-title.sh

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    TMUX_SOCK=""
}

teardown() {
    if [ -n "$TMUX_SOCK" ]; then
        tmux -L "$TMUX_SOCK" kill-server 2>/dev/null || true
        # kill-server terminates the server process but does not always
        # unlink its socket file (same fix tests/tmux-fleet.bats already
        # applies) -- remove it explicitly so repeated runs don't
        # accumulate stale scratch sockets alongside the real, live one.
        rm -f "/tmp/tmux-1000/$TMUX_SOCK"
    fi
}

# start_scratch_tmux — a fresh tmux server on its own socket, never the
# live one this session is attached to. Sets $TMUX_SOCK. The initial
# session is named "base" with one window, also named "base", cwd
# $BATS_TEST_TMPDIR.
start_scratch_tmux() {
    TMUX_SOCK="peers-test-$$-${RANDOM}"
    tmux -L "$TMUX_SOCK" new-session -d -s base -n base -c "$BATS_TEST_TMPDIR"
}

# fake_tmux_env <socket-name> — echoes a $TMUX value shaped like the real
# one tmux sets inside a pane (socket_path,pid,session_index), so a plain
# (unattached) process can still target that server via bare `tmux <cmd>`.
fake_tmux_env() {
    local sockpath
    sockpath="$(tmux -L "$1" display-message -p '#{socket_path}')"
    printf '%s,%s,0\n' "$sockpath" "$$"
}

# new_scratch_repo <name> — creates $BATS_TEST_TMPDIR/<name> as a git repo
# with one commit, echoes its canonical (symlink-resolved) absolute path.
new_scratch_repo() {
    local dir="$BATS_TEST_TMPDIR/$1"
    mkdir -p "$dir"
    dir="$(cd "$dir" && pwd -P)"
    git -C "$dir" init -q
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name "Test"
    printf 'hello\n' > "$dir/f.txt"
    git -C "$dir" add f.txt
    git -C "$dir" commit -q -m init
    printf '%s\n' "$dir"
}

# wait_for <max_tries> <cmd...> — polls every 0.2s (up to max_tries times)
# until <cmd...> exits 0.
wait_for() {
    local max_tries="$1"
    shift
    local i=0
    while [ "$i" -lt "$max_tries" ]; do
        if "$@"; then
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# stub_claude_bin — a real ELF executable named "claude" under
# $BATS_TEST_TMPDIR/bin, so a tmux pane exec'd into it shows
# pane_current_command "claude" without a real Claude Code install. A
# shebang script won't do here: the kernel sets a process's comm (what
# tmux's pane_current_command reads) from the basename of the LAST path
# actually execve()'d, and a `#!/usr/bin/env bash` script gets rewritten
# by the kernel into execve(bash), so comm reads "bash" no matter what the
# script's own filename is (confirmed empirically while writing this
# test). Copying the real python3 binary to a file named "claude" sidesteps
# that: python3 is a standalone ELF (no shebang indirection) and does not
# itself execve() again to run a -c script, so comm stays "claude" for as
# long as the process sleeps. Echoes the executable's absolute path.
stub_claude_bin() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    local bin="$BATS_TEST_TMPDIR/bin/claude"
    cp "$(command -v python3)" "$bin"
    printf '%s\n' "$bin"
}

# pane_id_of <window> — the (single) pane id of <window> on $TMUX_SOCK.
pane_id_of() {
    tmux -L "$TMUX_SOCK" list-panes -t "$1" -F '#{pane_id}' 2>/dev/null | head -1
}

# json_payload <session_id> <prompt> — a compact JSON object with those
# two string fields, built with jq so quoting is always safe.
json_payload() {
    jq -cn --arg sid "$1" --arg prompt "$2" '{session_id: $sid, prompt: $prompt}'
}

# run_session_title <payload> <TMUX> <TMUX_PANE> <FLEET_STATE_DIR> — runs
# session-title with <payload> on stdin and the given env, via the
# positional-arg idiom (tests/hook-staging.bats's session-end-audit tests
# use the same trick) so payload content never has to survive a second
# layer of shell quoting.
run_session_title() {
    run bash -c 'printf "%s" "$1" | TMUX="$2" TMUX_PANE="$3" FLEET_STATE_DIR="$4" "$5"' \
        _ "$1" "$2" "$3" "$4" "$SESSION_TITLE"
}

# ── peers: outside tmux / no pane ───────────────────────────────────────

@test "peers: outside tmux, prints nothing and exits 0" {
    run env -u TMUX -u TMUX_PANE "$PEERS"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "peers: TMUX set but TMUX_PANE unset, prints nothing and exits 0" {
    start_scratch_tmux
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    run env -u TMUX_PANE TMUX="$fake_tmux" "$PEERS"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── peers: no-other-live-sessions form ──────────────────────────────────

@test "peers: no other panes prints the no-other-live-sessions form" {
    start_scratch_tmux
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    my_pane="$(pane_id_of base)"
    run env TMUX="$fake_tmux" TMUX_PANE="$my_pane" "$PEERS"
    [ "$status" -eq 0 ]
    [ "$output" = "[peers] you: -@base · no other live sessions" ]
}

# ── peers: live sessions listed, own pane excluded ──────────────────────

@test "peers: two other panes running claude in scratch worktrees are both listed, own pane excluded" {
    REPO="$(new_scratch_repo main-repo)"
    claude_bin="$(stub_claude_bin)"
    git -C "$REPO" worktree add "$REPO/.claude/worktrees/wt-one" -b feature-one -q
    git -C "$REPO" worktree add "$REPO/.claude/worktrees/wt-two" -b feature-two -q
    start_scratch_tmux
    tmux -L "$TMUX_SOCK" new-window -t base: -n wt-one -c "$REPO/.claude/worktrees/wt-one" -- "$claude_bin" -c "import time; time.sleep(300)"
    tmux -L "$TMUX_SOCK" new-window -t base: -n wt-two -c "$REPO/.claude/worktrees/wt-two" -- "$claude_bin" -c "import time; time.sleep(300)"
    wait_for 50 bash -c "[ \"\$(tmux -L '$TMUX_SOCK' list-panes -a -F '#{pane_current_command}' | grep -cx claude)\" -eq 2 ]"
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    my_pane="$(pane_id_of base)"
    run env TMUX="$fake_tmux" TMUX_PANE="$my_pane" "$PEERS"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    [[ "$output" == "[peers] you: -@base · live: "*" · coordinate with SendMessage, not by editing their files" ]]
    [[ "$output" == *"wt-one (feature-one)"* ]]
    [[ "$output" == *"wt-two (feature-two)"* ]]
    [[ "$output" != *"base ("* ]]
}

@test "peers: a pane neither running claude nor under .claude/worktrees/ is excluded" {
    start_scratch_tmux
    tmux -L "$TMUX_SOCK" new-window -t base: -n other -c "$BATS_TEST_TMPDIR" -- sleep 300
    wait_for 50 bash -c "tmux -L '$TMUX_SOCK' list-windows -F '#{window_name}' | grep -qx other"
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    my_pane="$(pane_id_of base)"
    run env TMUX="$fake_tmux" TMUX_PANE="$my_pane" "$PEERS"
    [ "$status" -eq 0 ]
    [ "$output" = "[peers] you: -@base · no other live sessions" ]
}

# ── session-title: first-prompt slug rename ─────────────────────────────

@test "session-title: first prompt from a worktree pane renames the window to a slug" {
    REPO="$(new_scratch_repo st-repo1)"
    git -C "$REPO" worktree add "$REPO/.claude/worktrees/wt-title" -b title-branch -q
    start_scratch_tmux
    tmux -L "$TMUX_SOCK" new-window -t base: -n wt-title -c "$REPO/.claude/worktrees/wt-title" -- sleep 300
    wait_for 50 bash -c "tmux -L '$TMUX_SOCK' list-windows -F '#{window_name}' | grep -qx wt-title"
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    pane="$(pane_id_of wt-title)"
    payload="$(json_payload "sess-title-1" "Fix the login redirect bug please")"
    run_session_title "$payload" "$fake_tmux" "$pane" "$BATS_TEST_TMPDIR/fleet-state"
    [ "$status" -eq 0 ]
    run tmux -L "$TMUX_SOCK" display -p -t "$pane" '#{window_name}'
    [ "$output" = "fix-login-redirect-bug" ]
}

@test "session-title: a second prompt for the same session_id leaves the window name unchanged" {
    REPO="$(new_scratch_repo st-repo2)"
    git -C "$REPO" worktree add "$REPO/.claude/worktrees/wt-title2" -b title-branch2 -q
    start_scratch_tmux
    tmux -L "$TMUX_SOCK" new-window -t base: -n wt-title2 -c "$REPO/.claude/worktrees/wt-title2" -- sleep 300
    wait_for 50 bash -c "tmux -L '$TMUX_SOCK' list-windows -F '#{window_name}' | grep -qx wt-title2"
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    pane="$(pane_id_of wt-title2)"
    STATE_DIR="$BATS_TEST_TMPDIR/fleet-state"
    payload1="$(json_payload "sess-title-2" "Fix the login redirect bug please")"
    run_session_title "$payload1" "$fake_tmux" "$pane" "$STATE_DIR"
    [ "$status" -eq 0 ]
    payload2="$(json_payload "sess-title-2" "Totally different words entirely now")"
    run_session_title "$payload2" "$fake_tmux" "$pane" "$STATE_DIR"
    [ "$status" -eq 0 ]
    run tmux -L "$TMUX_SOCK" display -p -t "$pane" '#{window_name}'
    [ "$output" = "fix-login-redirect-bug" ]
}

@test "session-title: a pane outside .claude/worktrees/ is never renamed" {
    start_scratch_tmux
    tmux -L "$TMUX_SOCK" new-window -t base: -n plainwin -c "$BATS_TEST_TMPDIR" -- sleep 300
    wait_for 50 bash -c "tmux -L '$TMUX_SOCK' list-windows -F '#{window_name}' | grep -qx plainwin"
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    pane="$(pane_id_of plainwin)"
    payload="$(json_payload "sess-title-3" "Fix the login redirect bug please")"
    run_session_title "$payload" "$fake_tmux" "$pane" "$BATS_TEST_TMPDIR/fleet-state"
    [ "$status" -eq 0 ]
    run tmux -L "$TMUX_SOCK" display -p -t "$pane" '#{window_name}'
    [ "$output" = "plainwin" ]
}

@test "session-title: malformed stdin exits 0 without renaming" {
    REPO="$(new_scratch_repo st-repo4)"
    git -C "$REPO" worktree add "$REPO/.claude/worktrees/wt-title4" -b title-branch4 -q
    start_scratch_tmux
    tmux -L "$TMUX_SOCK" new-window -t base: -n wt-title4 -c "$REPO/.claude/worktrees/wt-title4" -- sleep 300
    wait_for 50 bash -c "tmux -L '$TMUX_SOCK' list-windows -F '#{window_name}' | grep -qx wt-title4"
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    pane="$(pane_id_of wt-title4)"
    run_session_title "not valid json at all {{{" "$fake_tmux" "$pane" "$BATS_TEST_TMPDIR/fleet-state"
    [ "$status" -eq 0 ]
    run tmux -L "$TMUX_SOCK" display -p -t "$pane" '#{window_name}'
    [ "$output" = "wt-title4" ]
}

@test "session-title: missing TMUX_PANE exits 0 without crashing" {
    payload="$(json_payload "sess-title-5" "Fix the login redirect bug please")"
    run bash -c 'printf "%s" "$1" | env -u TMUX_PANE "$2"' _ "$payload" "$SESSION_TITLE"
    [ "$status" -eq 0 ]
}

# ── settings + staging (Dockerfile + plugin) ────────────────────────────

@test "peers/session-title: config/claude-settings.json wires peers on SessionStart with the guarded command -v idiom" {
    run python3 -c "
import json
with open('/workspace/config/claude-settings.json') as fh:
    s = json.load(fh)
ok = False
for entry in s.get('hooks', {}).get('SessionStart', []):
    for h in entry.get('hooks', []):
        cmd = h.get('command', '')
        if 'command -v peers' in cmd and 'exec peers' in cmd:
            ok = True
raise SystemExit(0 if ok else 1)
"
    [ "$status" -eq 0 ]
}

@test "peers/session-title: config/claude-settings.json wires session-title on UserPromptSubmit with the guarded command -v idiom" {
    run python3 -c "
import json
with open('/workspace/config/claude-settings.json') as fh:
    s = json.load(fh)
ok = False
for entry in s.get('hooks', {}).get('UserPromptSubmit', []):
    for h in entry.get('hooks', []):
        cmd = h.get('command', '')
        if 'command -v session-title' in cmd and 'exec session-title' in cmd:
            ok = True
raise SystemExit(0 if ok else 1)
"
    [ "$status" -eq 0 ]
}

@test "peers/session-title: Dockerfile stages scripts/peers.sh as peers" {
    run grep -E '^COPY( +--\S+)* +scripts/peers\.sh +/usr/local/bin/peers *$' /workspace/Dockerfile
    [ "$status" -eq 0 ]
}

@test "peers/session-title: Dockerfile stages scripts/session-title.sh as session-title" {
    run grep -E '^COPY( +--\S+)* +scripts/session-title\.sh +/usr/local/bin/session-title *$' /workspace/Dockerfile
    [ "$status" -eq 0 ]
}

@test "peers/session-title: plugin/bin/peers is byte-identical to scripts/peers.sh" {
    [ -f /workspace/plugin/bin/peers ]
    diff -q /workspace/plugin/bin/peers /workspace/scripts/peers.sh
}

@test "peers/session-title: plugin/bin/session-title is byte-identical to scripts/session-title.sh" {
    [ -f /workspace/plugin/bin/session-title ]
    diff -q /workspace/plugin/bin/session-title /workspace/scripts/session-title.sh
}
