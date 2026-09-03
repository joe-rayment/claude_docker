#!/usr/bin/env bats

# tmux-fleet.bats — scripts/fleet-menu.sh, installed as fleet-menu, plus
# config/tmux.conf's status bar / MouseDown3Pane extension / prefix
# keybindings for the worktree-session fleet: New worktree session / Hide
# / Restore… / Jump… / Review… / Remove merged…. See
# .claude/plans/worktree-sessions.md and beads_claude_docker-f5i6. Depends
# on F1 (beads_claude_docker-nmnb, cs-new).
#
# FROZEN per f5i6's acceptance contract: this file must not be edited
# after its RED commit. If a test here turns out to be wrong, stop and
# report -- do not edit it.
#
# Every tmux test runs on a scratch `tmux -L fleet-test-<pid>-<rand>`
# server loaded with config/tmux.conf, never the live server this session
# is attached to. $TMUX is already set in the ambient environment the
# tests run in (a real tmux session), so every fleet-menu invocation below
# explicitly overrides it to point at the scratch server (see
# fake_tmux_env, matching the technique tests/worktree-sessions.bats
# already established for cs-new).

FLEET_MENU=/workspace/scripts/fleet-menu.sh
REPO_ROOT=/workspace

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    TMUX_SOCK=""
}

teardown() {
    if [ -n "$TMUX_SOCK" ]; then
        tmux -L "$TMUX_SOCK" kill-server 2>/dev/null || true
    fi
}

# start_scratch_tmux — a fresh tmux server on its own socket, loaded with
# this repo's config/tmux.conf, never the live one this session is
# attached to. Sets $TMUX_SOCK. The initial session is named "base" with
# one window ("zsh"-named by default, cwd $BATS_TEST_TMPDIR).
start_scratch_tmux() {
    TMUX_SOCK="fleet-test-$$-${RANDOM}"
    tmux -L "$TMUX_SOCK" -f "$REPO_ROOT/config/tmux.conf" new-session -d -s base -c "$BATS_TEST_TMPDIR"
}

# fake_tmux_env <socket-name> — echoes a $TMUX value shaped like the real
# one tmux sets inside a pane (socket_path,pid,session_index), so a plain
# (unattached) process can still target that server via bare `tmux <cmd>`.
fake_tmux_env() {
    sockpath="$(tmux -L "$1" display-message -p '#{socket_path}')"
    printf '%s,%s,0\n' "$sockpath" "$$"
}

# select_window_pane <window> [pane-index] — makes <window> (and
# optionally a specific pane within it) the scratch server's live
# "current" window/pane. tmux's implicit target resolution (no -t, socket
# from $TMUX) follows this server-side selection state, not any client
# attachment -- verified empirically before writing these tests: a bare
# `tmux display -p` with a constructed $TMUX and no attached client
# tracks whatever select-window/select-pane last set, exactly like
# fake_tmux_env already relies on for cs-new.
select_window_pane() {
    tmux -L "$TMUX_SOCK" select-window -t "$1"
    if [ -n "${2:-}" ]; then
        tmux -L "$TMUX_SOCK" select-pane -t "$1.$2"
    fi
}

# new_scratch_repo <name> — creates $BATS_TEST_TMPDIR/<name> as a git repo
# on branch "main" (fleet-menu.sh hardcodes "main", matching this
# project's own convention) with one commit. Echoes its canonical
# (symlink-resolved) absolute path.
new_scratch_repo() {
    dir="$BATS_TEST_TMPDIR/$1"
    mkdir -p "$dir"
    dir="$(cd "$dir" && pwd -P)"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name "Test"
    printf 'hello\n' > "$dir/f.txt"
    git -C "$dir" add f.txt
    git -C "$dir" commit -q -m init
    printf '%s\n' "$dir"
}

# add_worktree <root> <name> [ahead-commits] — a worktree at
# <root>/.claude/worktrees/<name> on a new branch <name>, with
# [ahead-commits] (default 0) extra commits on top of <root>'s HEAD.
add_worktree() {
    root="$1"
    name="$2"
    n="${3:-0}"
    git -C "$root" worktree add "$root/.claude/worktrees/$name" -b "$name" -q
    i=1
    while [ "$i" -le "$n" ]; do
        ( cd "$root/.claude/worktrees/$name" && echo "change $i" >> extra.txt && git add extra.txt && git commit -q -m "commit $i" )
        i=$((i + 1))
    done
}

# merge_worktree_branch <root> <branch> — merges <branch> into <root>'s
# own checked-out branch (main), so it shows up as merged.
merge_worktree_branch() {
    git -C "$1" merge -q -m "merge $2" "$2"
}

# ── config load / status bar ────────────────────────────────────────────

@test "fleet-menu: tmux -f config/tmux.conf loads without error on a scratch server" {
    TMUX_SOCK="fleet-test-$$-${RANDOM}"
    run tmux -L "$TMUX_SOCK" -f "$REPO_ROOT/config/tmux.conf" new-session -d -s base -c "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
}

@test "fleet-menu: status is on with status-position top" {
    start_scratch_tmux
    run tmux -L "$TMUX_SOCK" show-options -g status
    [ "$output" = "status on" ]
    run tmux -L "$TMUX_SOCK" show-options -g status-position
    [ "$output" = "status-position top" ]
}

# ── right-click menu / prefix keys ──────────────────────────────────────

@test "fleet-menu: MouseDown3Pane binding contains the six new item labels" {
    start_scratch_tmux
    run tmux -L "$TMUX_SOCK" list-keys -T root
    [ "$status" -eq 0 ]
    [[ "$output" == *"MouseDown3Pane"* ]]
    [[ "$output" == *"New worktree session"* ]]
    [[ "$output" == *"Hide"* ]]
    [[ "$output" == *"Restore"* ]]
    [[ "$output" == *"Jump"* ]]
    [[ "$output" == *"Review"* ]]
    [[ "$output" == *"Remove merged"* ]]
}

@test "fleet-menu: list-keys shows prefix bindings for N H R J V M mapped to fleet-menu commands" {
    start_scratch_tmux
    run tmux -L "$TMUX_SOCK" list-keys -T prefix
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/prefix-keys.txt"
    run grep -E '(^| )N( |$).*fleet-menu new' "$BATS_TEST_TMPDIR/prefix-keys.txt"
    [ "$status" -eq 0 ]
    run grep -E '(^| )H( |$).*fleet-menu hide' "$BATS_TEST_TMPDIR/prefix-keys.txt"
    [ "$status" -eq 0 ]
    run grep -E '(^| )R( |$).*fleet-menu restore' "$BATS_TEST_TMPDIR/prefix-keys.txt"
    [ "$status" -eq 0 ]
    run grep -E '(^| )J( |$).*fleet-menu jump' "$BATS_TEST_TMPDIR/prefix-keys.txt"
    [ "$status" -eq 0 ]
    run grep -E '(^| )V( |$).*fleet-menu review' "$BATS_TEST_TMPDIR/prefix-keys.txt"
    [ "$status" -eq 0 ]
    run grep -E '(^| )M( |$).*fleet-menu remove-merged' "$BATS_TEST_TMPDIR/prefix-keys.txt"
    [ "$status" -eq 0 ]
}

# ── hide / restore ───────────────────────────────────────────────────────

@test "fleet-menu: hide breaks the current pane into a new window keeping the window's name" {
    start_scratch_tmux
    tmux -L "$TMUX_SOCK" new-window -n alpha -c "$BATS_TEST_TMPDIR"
    tmux -L "$TMUX_SOCK" split-window -h -t alpha -c "$BATS_TEST_TMPDIR"
    alpha_id="$(tmux -L "$TMUX_SOCK" list-windows -F '#{window_id} #{window_name}' | awk '$2=="alpha"{print $1}')"
    pane0="$(tmux -L "$TMUX_SOCK" list-panes -t "$alpha_id" -F '#{pane_id}' | sed -n 1p)"
    pane1="$(tmux -L "$TMUX_SOCK" list-panes -t "$alpha_id" -F '#{pane_id}' | sed -n 2p)"
    select_window_pane "$alpha_id" 1
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    run env -u TMUX TMUX="$fake_tmux" "$FLEET_MENU" hide
    [ "$status" -eq 0 ]
    run tmux -L "$TMUX_SOCK" list-panes -t "$alpha_id" -F '#{pane_id}'
    [ "$output" = "$pane0" ]
    run tmux -L "$TMUX_SOCK" list-windows -F '#{window_name}'
    [ "$(printf '%s\n' "$output" | grep -cx alpha)" -eq 2 ]
    parked_id="$(tmux -L "$TMUX_SOCK" list-windows -F '#{window_id} #{window_name}' | awk -v a="$alpha_id" '$2=="alpha" && $1!=a{print $1}')"
    [ -n "$parked_id" ]
    run tmux -L "$TMUX_SOCK" list-panes -t "$parked_id" -F '#{pane_id}'
    [ "$output" = "$pane1" ]
}

@test "fleet-menu: restore joins a parked window's pane back into the current window" {
    start_scratch_tmux
    tmux -L "$TMUX_SOCK" new-window -n alpha -c "$BATS_TEST_TMPDIR"
    tmux -L "$TMUX_SOCK" split-window -h -t alpha -c "$BATS_TEST_TMPDIR"
    alpha_id="$(tmux -L "$TMUX_SOCK" list-windows -F '#{window_id} #{window_name}' | awk '$2=="alpha"{print $1}')"
    pane1="$(tmux -L "$TMUX_SOCK" list-panes -t "$alpha_id" -F '#{pane_id}' | sed -n 2p)"
    select_window_pane "$alpha_id" 1
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    env -u TMUX TMUX="$fake_tmux" "$FLEET_MENU" hide
    parked_id="$(tmux -L "$TMUX_SOCK" list-windows -F '#{window_id} #{window_name}' | awk -v a="$alpha_id" '$2=="alpha" && $1!=a{print $1}')"
    [ -n "$parked_id" ]
    select_window_pane "$alpha_id" 0
    run env -u TMUX TMUX="$fake_tmux" "$FLEET_MENU" restore "$parked_id"
    [ "$status" -eq 0 ]
    run tmux -L "$TMUX_SOCK" list-panes -t "$alpha_id" -F '#{pane_id}'
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
    [[ "$output" == *"$pane1"* ]]
    run tmux -L "$TMUX_SOCK" list-windows -F '#{window_id}'
    [[ "$output" != *"$parked_id"* ]]
}

@test "fleet-menu: restore --print lists windows other than the current one" {
    start_scratch_tmux
    tmux -L "$TMUX_SOCK" new-window -n win-a -c "$BATS_TEST_TMPDIR"
    tmux -L "$TMUX_SOCK" new-window -n win-b -c "$BATS_TEST_TMPDIR"
    select_window_pane win-a
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    run env -u TMUX TMUX="$fake_tmux" "$FLEET_MENU" restore --print
    [ "$status" -eq 0 ]
    [[ "$output" == *"win-b"* ]]
    [[ "$output" != *"win-a"* ]]
}

# ── jump ─────────────────────────────────────────────────────────────────

@test "fleet-menu: jump --print lists every window with its git branch" {
    start_scratch_tmux
    REPO="$(new_scratch_repo jump-repo)"
    add_worktree "$REPO" feature-x 1
    tmux -L "$TMUX_SOCK" new-window -n on-main -c "$REPO"
    tmux -L "$TMUX_SOCK" new-window -n on-feature -c "$REPO/.claude/worktrees/feature-x"
    tmux -L "$TMUX_SOCK" new-window -n non-git -c "$BATS_TEST_TMPDIR"
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    run env -u TMUX TMUX="$fake_tmux" "$FLEET_MENU" jump --print
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/jump-print.txt"
    run awk -F'\t' '$2=="on-main" && $3=="main"{f=1} END{exit !f}' "$BATS_TEST_TMPDIR/jump-print.txt"
    [ "$status" -eq 0 ]
    run awk -F'\t' '$2=="on-feature" && $3=="feature-x"{f=1} END{exit !f}' "$BATS_TEST_TMPDIR/jump-print.txt"
    [ "$status" -eq 0 ]
    run awk -F'\t' '$2=="non-git" && $3=="-"{f=1} END{exit !f}' "$BATS_TEST_TMPDIR/jump-print.txt"
    [ "$status" -eq 0 ]
}

# ── review ───────────────────────────────────────────────────────────────

@test "fleet-menu: review --print lists each worktree with its branch and ahead count against main" {
    start_scratch_tmux
    REPO="$(new_scratch_repo review-repo)"
    add_worktree "$REPO" ahead-two 2
    tmux -L "$TMUX_SOCK" new-window -n reviewer -c "$REPO"
    select_window_pane reviewer
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    run env -u TMUX TMUX="$fake_tmux" "$FLEET_MENU" review --print
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/review-print.txt"
    run awk -F'\t' '$1=="ahead-two" && $2=="ahead-two" && $3=="2"{f=1} END{exit !f}' "$BATS_TEST_TMPDIR/review-print.txt"
    [ "$status" -eq 0 ]
}

# ── remove-merged ────────────────────────────────────────────────────────

@test "fleet-menu: remove-merged --print lists only merged branches" {
    start_scratch_tmux
    REPO="$(new_scratch_repo rm-repo1)"
    add_worktree "$REPO" merged-one 1
    merge_worktree_branch "$REPO" merged-one
    add_worktree "$REPO" unmerged-one 1
    tmux -L "$TMUX_SOCK" new-window -n rmwin1 -c "$REPO"
    select_window_pane rmwin1
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    run env -u TMUX TMUX="$fake_tmux" "$FLEET_MENU" remove-merged --print
    [ "$status" -eq 0 ]
    [[ "$output" == *"merged-one"* ]]
    [[ "$output" != *"unmerged-one"* ]]
}

@test "fleet-menu: remove-merged removes exactly the named worktree and its branch" {
    start_scratch_tmux
    REPO="$(new_scratch_repo rm-repo2)"
    add_worktree "$REPO" merged-two 1
    merge_worktree_branch "$REPO" merged-two
    add_worktree "$REPO" unmerged-two 1
    tmux -L "$TMUX_SOCK" new-window -n rmwin2 -c "$REPO"
    select_window_pane rmwin2
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    run env -u TMUX TMUX="$fake_tmux" "$FLEET_MENU" remove-merged merged-two
    [ "$status" -eq 0 ]
    [ ! -d "$REPO/.claude/worktrees/merged-two" ]
    run git -C "$REPO" branch --list merged-two
    [ -z "$output" ]
    [ -d "$REPO/.claude/worktrees/unmerged-two" ]
    run git -C "$REPO" branch --list unmerged-two
    [ -n "$output" ]
}

@test "fleet-menu: remove-merged refuses an unmerged branch and leaves it untouched" {
    start_scratch_tmux
    REPO="$(new_scratch_repo rm-repo3)"
    add_worktree "$REPO" stays-unmerged 1
    tmux -L "$TMUX_SOCK" new-window -n rmwin3 -c "$REPO"
    select_window_pane rmwin3
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"
    run env -u TMUX TMUX="$fake_tmux" "$FLEET_MENU" remove-merged stays-unmerged
    [ "$status" -ne 0 ]
    [[ "$output" == *"unmerged"* ]]
    [ -d "$REPO/.claude/worktrees/stays-unmerged" ]
    run git -C "$REPO" branch --list stays-unmerged
    [ -n "$output" ]
}

# ── staging (Dockerfile + plugin) ────────────────────────────────────────

@test "fleet-menu: Dockerfile has a COPY line staging scripts/fleet-menu.sh as fleet-menu" {
    run grep -E '^COPY( +--\S+)* +scripts/fleet-menu\.sh +/usr/local/bin/fleet-menu *$' /workspace/Dockerfile
    [ "$status" -eq 0 ]
}

@test "fleet-menu: plugin/bin/fleet-menu is byte-identical to scripts/fleet-menu.sh" {
    [ -f /workspace/plugin/bin/fleet-menu ]
    diff -q /workspace/plugin/bin/fleet-menu /workspace/scripts/fleet-menu.sh
}

# ── screenshots ──────────────────────────────────────────────────────────

@test "fleet-menu: status bar and jump menu are captured as PNGs via take-screenshot term" {
    start_scratch_tmux
    tmux -L "$TMUX_SOCK" new-window -n win-one -c "$BATS_TEST_TMPDIR"
    tmux -L "$TMUX_SOCK" new-window -n win-two -c "$BATS_TEST_TMPDIR"
    tmux -L "$TMUX_SOCK" new-window -n win-three -c "$BATS_TEST_TMPDIR"
    win_two_id="$(tmux -L "$TMUX_SOCK" list-windows -F '#{window_id} #{window_name}' | awk '$2=="win-two"{print $1}')"
    tmux -L "$TMUX_SOCK" split-window -h -t "$win_two_id" -c "$BATS_TEST_TMPDIR"
    select_window_pane "$win_two_id" 1
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"

    # Hide one pane out of win-two, then restore it -- the scenario the
    # PASS-IF asks the status-bar screenshot to reflect.
    env -u TMUX TMUX="$fake_tmux" "$FLEET_MENU" hide
    parked_id="$(tmux -L "$TMUX_SOCK" list-windows -F '#{window_id} #{window_name}' | awk -v a="$win_two_id" '$2=="win-two" && $1!=a{print $1}')"
    [ -n "$parked_id" ]
    select_window_pane "$win_two_id" 0
    env -u TMUX TMUX="$fake_tmux" "$FLEET_MENU" restore "$parked_id"

    select_window_pane win-one

    run take-screenshot term "echo 'fleet status bar (top, window list):'; tmux -L $TMUX_SOCK list-windows -F ' #{window_index}:#{window_name}#{?window_active, [active],}'"
    [ "$status" -eq 0 ]
    status_png="$(printf '%s\n' "$output" | tail -n1)"
    [ -f "$status_png" ]

    run take-screenshot term "env -u TMUX TMUX=$fake_tmux $FLEET_MENU jump --print"
    [ "$status" -eq 0 ]
    jump_png="$(printf '%s\n' "$output" | tail -n1)"
    [ -f "$jump_png" ]

    echo "fleet-menu screenshots: status_bar=$status_png jump_menu=$jump_png"
}
