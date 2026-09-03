#!/usr/bin/env bats

# worktree-sessions.bats — scripts/cs-new.sh, installed as cs-new: opens a
# new Claude Code side session in its own git worktree under
# .claude/worktrees/<name>, in a new tmux window of the current server (or
# the foreground outside tmux), sharing the main tree's beads via
# BEADS_DIR. See .claude/plans/worktree-sessions.md and
# beads_claude_docker-nmnb.
#
# FROZEN per nmnb's acceptance contract: this file must not be edited
# after its RED commit. If a test here turns out to be wrong, stop and
# report -- do not edit it.
#
# Every tmux test runs on a scratch `tmux -L cs-test-<pid>` server, never
# the live server this session is attached to. $TMUX is already set in
# the ambient environment the tests run in (a real tmux session), so
# "outside tmux" tests explicitly `env -u TMUX`.

CS_NEW=/workspace/scripts/cs-new.sh
REPO_ROOT=/workspace

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    CLEANUP_FILE="$BATS_TEST_TMPDIR/cleanup.tsv"
    : > "$CLEANUP_FILE"
    TMUX_SOCK=""
    CS_NEW_PID=""
}

teardown() {
    if [ -n "$TMUX_SOCK" ]; then
        tmux -L "$TMUX_SOCK" kill-server 2>/dev/null || true
    fi
    if [ -n "$CS_NEW_PID" ]; then
        kill "$CS_NEW_PID" 2>/dev/null || true
        wait "$CS_NEW_PID" 2>/dev/null || true
    fi
    # Belt-and-braces: reap any leftover marker-duration sleeps this file's
    # own tests may have started (a killed subshell can orphan its exec'd
    # child rather than take it down with it).
    pkill -f 'sleep 47' 2>/dev/null || true
    if [ -f "$CLEANUP_FILE" ]; then
        while IFS=$'\t' read -r repo wt branch; do
            [ -z "$repo" ] && continue
            git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
            [ -n "$branch" ] && git -C "$repo" branch -D "$branch" 2>/dev/null || true
        done < "$CLEANUP_FILE"
    fi
}

# register_cleanup <repo_root> <worktree_path> <branch> — always run in
# teardown, including on test failure.
register_cleanup() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$CLEANUP_FILE"
}

# new_scratch_repo <name> — creates $BATS_TEST_TMPDIR/<name> as a git repo
# with one commit, echoes its canonical (symlink-resolved) absolute path
# so string comparisons against `git rev-parse --show-toplevel` inside it
# can never be thrown off by a symlink component in $BATS_TEST_TMPDIR.
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

# start_scratch_tmux — a fresh tmux server on its own socket, never the
# live one this session is attached to. Sets $TMUX_SOCK.
start_scratch_tmux() {
    TMUX_SOCK="cs-test-$$-${RANDOM}"
    tmux -L "$TMUX_SOCK" new-session -d -s base -c "$BATS_TEST_TMPDIR"
}

# fake_tmux_env <socket-name> — echoes a $TMUX value shaped like the real
# one tmux sets inside a pane (socket_path,pid,session_index), so a plain
# (unattached) process can still target that server via bare `tmux <cmd>`.
fake_tmux_env() {
    local sockpath
    sockpath="$(tmux -L "$1" display-message -p '#{socket_path}')"
    printf '%s,%s,0\n' "$sockpath" "$$"
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

# ── worktree creation basics (no tmux) ──────────────────────────────────

@test "cs-new: no name creates exactly one worktree under .claude/worktrees/" {
    REPO="$(new_scratch_repo repo1)"
    ( cd "$REPO" && env -u TMUX CS_NEW_LAUNCH='sleep 47' "$CS_NEW" ) >"$BATS_TEST_TMPDIR/out1.log" 2>&1 &
    CS_NEW_PID=$!
    wait_for 50 bash -c "[ -d '$REPO/.claude/worktrees' ] && [ \"\$(ls '$REPO/.claude/worktrees' | wc -l)\" -ge 1 ]"
    [ -d "$REPO/.claude/worktrees" ]
    names=("$REPO"/.claude/worktrees/*)
    [ "${#names[@]}" -eq 1 ]
    name="$(basename "${names[0]}")"
    register_cleanup "$REPO" "$REPO/.claude/worktrees/$name" "$name"
}

@test "cs-new: generated name matches ^[a-z]+-[a-z]+\$" {
    REPO="$(new_scratch_repo repo1b)"
    ( cd "$REPO" && env -u TMUX CS_NEW_LAUNCH='sleep 47' "$CS_NEW" ) >"$BATS_TEST_TMPDIR/out1b.log" 2>&1 &
    CS_NEW_PID=$!
    wait_for 50 bash -c "[ -d '$REPO/.claude/worktrees' ] && [ \"\$(ls '$REPO/.claude/worktrees' | wc -l)\" -ge 1 ]"
    name="$(basename "$REPO"/.claude/worktrees/*)"
    register_cleanup "$REPO" "$REPO/.claude/worktrees/$name" "$name"
    [[ "$name" =~ ^[a-z]+-[a-z]+$ ]]
}

@test "cs-new: generated worktree's branch equals its name and starts at repo HEAD" {
    REPO="$(new_scratch_repo repo1c)"
    head_sha="$(git -C "$REPO" rev-parse HEAD)"
    ( cd "$REPO" && env -u TMUX CS_NEW_LAUNCH='sleep 47' "$CS_NEW" ) >"$BATS_TEST_TMPDIR/out1c.log" 2>&1 &
    CS_NEW_PID=$!
    wait_for 50 bash -c "[ -d '$REPO/.claude/worktrees' ] && [ \"\$(ls '$REPO/.claude/worktrees' | wc -l)\" -ge 1 ]"
    name="$(basename "$REPO"/.claude/worktrees/*)"
    register_cleanup "$REPO" "$REPO/.claude/worktrees/$name" "$name"
    run git -C "$REPO/.claude/worktrees/$name" rev-parse --abbrev-ref HEAD
    [ "$output" = "$name" ]
    run git -C "$REPO/.claude/worktrees/$name" rev-parse HEAD
    [ "$output" = "$head_sha" ]
}

@test "cs-new: two consecutive calls without a name yield different names" {
    REPO="$(new_scratch_repo repo2)"
    ( cd "$REPO" && env -u TMUX CS_NEW_LAUNCH='true' "$CS_NEW" )
    ( cd "$REPO" && env -u TMUX CS_NEW_LAUNCH='true' "$CS_NEW" )
    names=("$REPO"/.claude/worktrees/*)
    [ "${#names[@]}" -eq 2 ]
    n1="$(basename "${names[0]}")"
    n2="$(basename "${names[1]}")"
    register_cleanup "$REPO" "${names[0]}" "$n1"
    register_cleanup "$REPO" "${names[1]}" "$n2"
    [ "$n1" != "$n2" ]
}

# ── explicit names ───────────────────────────────────────────────────────

@test "cs-new: an explicit name is used verbatim" {
    REPO="$(new_scratch_repo repo3)"
    ( cd "$REPO" && env -u TMUX CS_NEW_LAUNCH='true' "$CS_NEW" my-explicit-name )
    register_cleanup "$REPO" "$REPO/.claude/worktrees/my-explicit-name" "my-explicit-name"
    [ -d "$REPO/.claude/worktrees/my-explicit-name" ]
}

@test "cs-new: second call with the same explicit name fails non-zero and creates nothing new" {
    REPO="$(new_scratch_repo repo4)"
    ( cd "$REPO" && env -u TMUX CS_NEW_LAUNCH='true' "$CS_NEW" dup-name )
    register_cleanup "$REPO" "$REPO/.claude/worktrees/dup-name" "dup-name"
    before_count=$(ls "$REPO/.claude/worktrees" | wc -l)
    run bash -c "cd '$REPO' && env -u TMUX CS_NEW_LAUNCH='true' '$CS_NEW' dup-name"
    [ "$status" -ne 0 ]
    after_count=$(ls "$REPO/.claude/worktrees" | wc -l)
    [ "$after_count" -eq "$before_count" ]
}

# ── tmux integration (scratch server only) ──────────────────────────────

@test "cs-new: inside a scratch tmux server, creates a window named after the worktree" {
    REPO="$(new_scratch_repo repo5)"
    start_scratch_tmux
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    ( cd "$REPO" && env -u TMUX TMUX="$fake_tmux" CS_NEW_LAUNCH='sleep 47' "$CS_NEW" tmux-win-name ) >"$BATS_TEST_TMPDIR/out5.log" 2>&1 &
    CS_NEW_PID=$!
    register_cleanup "$REPO" "$REPO/.claude/worktrees/tmux-win-name" "tmux-win-name"
    wait_for 50 bash -c "tmux -L '$TMUX_SOCK' list-windows -F '#{window_name}' 2>/dev/null | grep -qx tmux-win-name"
    run tmux -L "$TMUX_SOCK" list-windows -F '#{window_name}'
    [[ "$output" == *"tmux-win-name"* ]]
}

@test "cs-new: the tmux window's pane path is the worktree" {
    REPO="$(new_scratch_repo repo5b)"
    start_scratch_tmux
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    ( cd "$REPO" && env -u TMUX TMUX="$fake_tmux" CS_NEW_LAUNCH='sleep 47' "$CS_NEW" tmux-path-check ) >"$BATS_TEST_TMPDIR/out5b.log" 2>&1 &
    CS_NEW_PID=$!
    register_cleanup "$REPO" "$REPO/.claude/worktrees/tmux-path-check" "tmux-path-check"
    wait_for 50 bash -c "tmux -L '$TMUX_SOCK' list-windows -F '#{window_name}' 2>/dev/null | grep -qx tmux-path-check"
    run tmux -L "$TMUX_SOCK" list-windows -F '#{window_name} #{pane_current_path}'
    [[ "$output" == *"tmux-path-check $REPO/.claude/worktrees/tmux-path-check"* ]]
}

# ── foreground (outside tmux) ────────────────────────────────────────────

@test "cs-new: outside tmux, the launch command runs in the foreground with cwd = worktree" {
    REPO="$(new_scratch_repo repo6)"
    OUTFILE="$BATS_TEST_TMPDIR/pwd6.txt"
    ( cd "$REPO" && env -u TMUX CS_NEW_LAUNCH="pwd > '$OUTFILE'" "$CS_NEW" cwd-check )
    register_cleanup "$REPO" "$REPO/.claude/worktrees/cwd-check" "cwd-check"
    [ -f "$OUTFILE" ]
    run cat "$OUTFILE"
    [ "$output" = "$REPO/.claude/worktrees/cwd-check" ]
}

@test "cs-new: launched process environment contains BEADS_DIR=<root>/.beads" {
    REPO="$(new_scratch_repo repo7)"
    OUTFILE="$BATS_TEST_TMPDIR/env7.txt"
    ( cd "$REPO" && env -u TMUX CS_NEW_LAUNCH="env > '$OUTFILE'" "$CS_NEW" env-check )
    register_cleanup "$REPO" "$REPO/.claude/worktrees/env-check" "env-check"
    run grep -x "BEADS_DIR=$REPO/.beads" "$OUTFILE"
    [ "$status" -eq 0 ]
}

# ── shared beads with the real repo ─────────────────────────────────────

@test "cs-new: from a real worktree of this repo, bd sees the same open issues as /workspace" {
    NAME="bats-shared-beads-$$"
    ( cd "$REPO_ROOT" && env -u TMUX CS_NEW_LAUNCH='true' "$CS_NEW" "$NAME" )
    register_cleanup "$REPO_ROOT" "$REPO_ROOT/.claude/worktrees/$NAME" "$NAME"
    run bash -c "BEADS_DIR='$REPO_ROOT/.beads' bd list --status=open --json 2>/dev/null | jq -r '.[].id' | sort"
    [ "$status" -eq 0 ]
    main_ids="$output"
    run bash -c "cd '$REPO_ROOT/.claude/worktrees/$NAME' && BEADS_DIR='$REPO_ROOT/.beads' bd list --status=open --json 2>/dev/null | jq -r '.[].id' | sort"
    [ "$status" -eq 0 ]
    [ "$output" = "$main_ids" ]
    run git -C "$REPO_ROOT/.claude/worktrees/$NAME" status --porcelain
    [ -z "$output" ]
}

# ── error handling ───────────────────────────────────────────────────────

@test "cs-new: running outside a git repo exits non-zero with a message" {
    NONREPO="$BATS_TEST_TMPDIR/not-a-repo"
    mkdir -p "$NONREPO"
    run bash -c "cd '$NONREPO' && env -u TMUX '$CS_NEW'"
    [ "$status" -ne 0 ]
    [ -n "$output" ]
}

# ── shell integration ────────────────────────────────────────────────────

@test "cs-new: config/.zshrc defines a csn shortcut" {
    run grep '^alias csn=' /workspace/config/.zshrc
    [ "$status" -eq 0 ]
    [[ "$output" == *"cs-new"* ]]
}

@test "cs-new: .gitignore (tracked file, not a local exclude) ignores .claude/worktrees/" {
    # Grep the tracked .gitignore directly rather than `git check-ignore`:
    # this container's local, untracked .git/info/exclude already has
    # **/.claude/worktrees/ for unrelated reasons, which would make
    # check-ignore pass even if the tracked .gitignore were never edited.
    run grep -xF '.claude/worktrees/' /workspace/.gitignore
    [ "$status" -eq 0 ]
}

# ── staging (Dockerfile + plugin) ────────────────────────────────────────

@test "cs-new: Dockerfile has a COPY line staging scripts/cs-new.sh as cs-new" {
    run grep -E '^COPY( +--\S+)* +scripts/cs-new\.sh +/usr/local/bin/cs-new *$' /workspace/Dockerfile
    [ "$status" -eq 0 ]
}

@test "cs-new: plugin/bin/cs-new is byte-identical to scripts/cs-new.sh" {
    [ -f /workspace/plugin/bin/cs-new ]
    diff -q /workspace/plugin/bin/cs-new /workspace/scripts/cs-new.sh
}
