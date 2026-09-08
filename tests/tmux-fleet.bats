#!/usr/bin/env bats

# tmux-fleet.bats — scripts/fleet-menu.sh, installed as fleet-menu, plus
# config/tmux.conf's status bar / MouseDown3Pane extension / prefix
# keybindings for the worktree-session fleet: New worktree session / Hide
# / Restore… / Jump… / Review… / Remove merged…. See
# .claude/plans/worktree-sessions.md, beads_claude_docker-f5i6. Depends
# on F1 (beads_claude_docker-nmnb, cs-new).
#
# FROZEN per f5i6's acceptance contract from its RED commit until f5i6's
# own verification completed -- that verification ran (verifier-fable-5-1-f1f2,
# 2026-09-03) and returned FAIL on the two-PNG clause only (a filename
# collision in take-screenshot's default term-<UTC second>.png naming,
# compounded by a termshot pty-capture race), so that window has elapsed
# and the fixes below were authorized by the bead owner rather than made
# unilaterally: the screenshot test's capture mechanism was rewritten
# (distinct -o paths, precompute-to-file-then-cat, both files asserted to
# differ and be non-trivial in size), a new test was added asserting the
# prefix/mouse bindings pass #{pane_id} explicitly, and teardown() gained
# explicit scratch-socket cleanup. See beads_claude_docker-f5i6's notes.
#
# FROZEN again per beads_claude_docker-8wy7's own acceptance contract
# from its RED commit onward (G2 of .claude/plans/fleet-nav.md): a new
# "── new (lands in the session) ──" section was added exercising `fleet-menu
# new`'s fix -- cmd_new now runs cs-new synchronously instead of a nested
# backgrounded run-shell, so it must be driven through a REAL `tmux
# run-shell "fleet-menu new #{pane_id} #{pane_current_path}"` (the exact
# binding shape, not a direct $FLEET_MENU invocation like every test
# above) for the pane-overlay assertions to mean anything. Since that
# relies on PATH resolving the bare `fleet-menu`/`cs-new` names tmux's
# own run-shell looks up, stage_new_shims() puts freshly-symlinked
# copies of this checkout's scripts ahead of /usr/local/bin's (possibly
# stale, confirmed stale at the time this bead landed) installed copies
# on $PATH before the scratch server starts -- a scratch tmux server's
# run-shell children inherit the OS environment (PATH included) of
# whatever process started the server, confirmed empirically before
# writing these tests.
#
# FROZEN again per beads_claude_docker-hka8's own acceptance contract
# from its RED commit onward: an interim item (later removed and never
# part of any released binding contract) is gone from the MouseDown3Pane
# menu and the prefix table, restoring the six-item/six-key set (N H R J
# V M) this file originally froze. The status bar comes back on (`set -g
# status on` in config/tmux.conf, matching its pre-off format), so
# "status is off" reverts to "status is on with status-position top" and
# the plain-text menu/dispatch tests that exercised the interim item are
# removed rather than repointed, since the item itself no longer exists
# to exercise.
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
        # kill-server terminates the server process but does not always
        # unlink its socket file (confirmed empirically: the file can
        # linger under /tmp/tmux-<uid>/ after the process is gone) --
        # remove it explicitly so repeated runs don't accumulate stale
        # scratch sockets alongside the real, live one.
        rm -f "/tmp/tmux-1000/$TMUX_SOCK"
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

# wait_for <max_tries> <cmd...> — polls every 0.2s (up to max_tries times)
# until <cmd...> exits 0. Matches tests/worktree-sessions.bats's own
# helper of the same name.
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

# stage_new_shims — creates $BATS_TEST_TMPDIR/shimbin with fleet-menu/
# cs-new symlinked to THIS checkout's scripts (bare names, matching what
# /usr/local/bin and plugin/bin both install as) and prepends it to
# $PATH. Only the "new" tests below need this: they drive fleet-menu
# through a REAL `tmux run-shell "fleet-menu ..."`, which resolves the
# bare command via PATH exactly like config/tmux.conf's own binding does
# -- so without this, a scratch server would silently exercise whatever
# is staged at /usr/local/bin/fleet-menu instead of this edited checkout.
# Must be called before start_scratch_tmux: a scratch server's run-shell
# children inherit the PATH (and every other env var) of the process
# that started the server, not of whatever invokes run-shell later.
stage_new_shims() {
    local dir="$BATS_TEST_TMPDIR/shimbin"
    mkdir -p "$dir"
    ln -sf /workspace/scripts/fleet-menu.sh "$dir/fleet-menu"
    ln -sf /workspace/scripts/cs-new.sh "$dir/cs-new"
    export PATH="$dir:$PATH"
}

# start_scratch_tmux_at <cwd> — like start_scratch_tmux, but the initial
# pane's cwd is <cwd> instead of $BATS_TEST_TMPDIR. The "new" tests below
# need the pane that fires the binding to already be inside the scratch
# repo, since #{pane_current_path} (what config/tmux.conf's real binding
# passes as fleet-menu's repo-root arg) reflects the pane's actual cwd at
# creation time. Sets $TMUX_SOCK.
start_scratch_tmux_at() {
    TMUX_SOCK="fleet-test-$$-${RANDOM}"
    tmux -L "$TMUX_SOCK" -f "$REPO_ROOT/config/tmux.conf" new-session -d -s base -c "$1" -x 120 -y 35
}

# ── config load / status bar ────────────────────────────────────────────

@test "fleet-menu: tmux -f config/tmux.conf loads without error on a scratch server" {
    TMUX_SOCK="fleet-test-$$-${RANDOM}"
    run tmux -L "$TMUX_SOCK" -f "$REPO_ROOT/config/tmux.conf" new-session -d -s base -c "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
}

@test "fleet-menu: status is on, pinned to the top, with the pre-2c8f229 format restored" {
    start_scratch_tmux
    run tmux -L "$TMUX_SOCK" show-options -gv status
    [ "$output" = "on" ]
    run tmux -L "$TMUX_SOCK" show-options -gv status-position
    [ "$output" = "top" ]
    run grep -E '^[[:space:]]*set -g status-left ' "$REPO_ROOT/config/tmux.conf"
    [ "$status" -eq 0 ]
    run grep -E '^[[:space:]]*set -g window-status-format ' "$REPO_ROOT/config/tmux.conf"
    [ "$status" -eq 0 ]
    run grep -E '^[[:space:]]*set -g window-status-current-format ' "$REPO_ROOT/config/tmux.conf"
    [ "$status" -eq 0 ]
    run grep -E '^[[:space:]]*set -g status-right ' "$REPO_ROOT/config/tmux.conf"
    [ "$status" -eq 0 ]
}

@test "fleet-menu: MouseDown3Pane and prefix N/H/R/J/V/M bindings match HEAD's tmux.conf via tmux list-keys" {
    # The bindings (right-click menu + prefix keys) must stay byte-for-byte
    # identical to whatever HEAD (i.e. before this bead's changes land)
    # shipped -- loads HEAD's config/tmux.conf on its own scratch server
    # and diffs both key tables against the working tree's.
    local head_conf="$BATS_TEST_TMPDIR/head-tmux.conf"
    git -C "$REPO_ROOT" show HEAD:config/tmux.conf > "$head_conf"

    local head_sock="fleet-test-head-$$-${RANDOM}"
    tmux -L "$head_sock" -f "$head_conf" new-session -d -s base -c "$BATS_TEST_TMPDIR"
    run tmux -L "$head_sock" list-keys -T root
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/head-root-keys.txt"
    run tmux -L "$head_sock" list-keys -T prefix
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/head-prefix-keys.txt"
    tmux -L "$head_sock" kill-server 2>/dev/null || true
    rm -f "/tmp/tmux-1000/$head_sock"

    start_scratch_tmux
    run tmux -L "$TMUX_SOCK" list-keys -T root
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/current-root-keys.txt"
    run tmux -L "$TMUX_SOCK" list-keys -T prefix
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/current-prefix-keys.txt"

    run diff "$BATS_TEST_TMPDIR/head-root-keys.txt" "$BATS_TEST_TMPDIR/current-root-keys.txt"
    [ "$status" -eq 0 ]
    run diff "$BATS_TEST_TMPDIR/head-prefix-keys.txt" "$BATS_TEST_TMPDIR/current-prefix-keys.txt"
    [ "$status" -eq 0 ]
}

# ── right-click menu / prefix keys ──────────────────────────────────────

@test "fleet-menu: MouseDown3Pane binding contains the six item labels, no other" {
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
    # "no other" in the title had no assertion behind it, so nothing proved
    # the removed Sidebar item was actually gone (beads_claude_docker-hka8).
    [[ "$output" != *"Sidebar"* ]]
    [[ "$output" != *"fleet-menu sidebar"* ]]
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

@test "fleet-menu: prefix and MouseDown3Pane bindings pass #{pane_id} explicitly" {
    start_scratch_tmux
    # run-shell (how every binding below invokes fleet-menu) gets no
    # TMUX_PANE, so a bare ambient `tmux display -p` inside the script
    # falls back to tmux's best guess at "current" rather than the pane
    # that actually fired the binding. Bindings must pass #{pane_id}
    # (a tmux format that expands at bind/run-shell time) explicitly so
    # the script can target that exact pane via -t instead of guessing.
    run tmux -L "$TMUX_SOCK" list-keys -T prefix
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/prefix-keys-paneid.txt"
    for sub in new hide restore jump review remove-merged; do
        run grep -F "fleet-menu $sub #{pane_id}" "$BATS_TEST_TMPDIR/prefix-keys-paneid.txt"
        [ "$status" -eq 0 ]
    done
    run tmux -L "$TMUX_SOCK" list-keys -T root
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/root-keys-paneid.txt"
    for sub in new hide restore jump review remove-merged; do
        run grep -F "fleet-menu $sub #{pane_id}" "$BATS_TEST_TMPDIR/root-keys-paneid.txt"
        [ "$status" -eq 0 ]
    done
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
    # Hardening for the beads_claude_docker-dd3o flake: a freshly created
    # window's pane_current_path can still read as its parent's cwd for a
    # moment before the shell finishes chdir'ing, so poll each window's
    # own pane_current_path until it matches what it was created with,
    # before asking jump --print to read git state off of it. Not
    # otherwise changed -- dd3o itself stays open.
    wait_for 25 bash -c "[ \"\$(tmux -L '$TMUX_SOCK' display -p -t on-main '#{pane_current_path}')\" = '$REPO' ]"
    wait_for 25 bash -c "[ \"\$(tmux -L '$TMUX_SOCK' display -p -t on-feature '#{pane_current_path}')\" = '$REPO/.claude/worktrees/feature-x' ]"
    wait_for 25 bash -c "[ \"\$(tmux -L '$TMUX_SOCK' display -p -t non-git '#{pane_current_path}')\" = '$BATS_TEST_TMPDIR' ]"
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

# ── new (lands in the session, beads_claude_docker-8wy7 / G2) ──────────
# cmd_new used to run cs-new via a nested backgrounded run-shell with no
# target pane; at completion tmux painted its captured stdout+stderr as a
# view-mode overlay on whatever pane was current -- the brand-new Claude
# pane, hiding its folder-trust dialog underneath (default answer "No,
# exit", which closed the window). Fix: run cs-new synchronously with its
# output captured into a variable, so on success nothing is left for the
# outer run-shell to paint anywhere.

@test "fleet-menu: the exact binding shape lands in the new window with no overlay on any pane" {
    stage_new_shims
    REPO="$(new_scratch_repo new-repo1)"
    export CS_NEW_LAUNCH='sleep 47'
    start_scratch_tmux_at "$REPO"

    run tmux -L "$TMUX_SOCK" run-shell "fleet-menu new #{pane_id} #{pane_current_path}"
    [ "$status" -eq 0 ]

    run tmux -L "$TMUX_SOCK" list-windows -F '#{window_name} #{window_active}'
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/windows1.txt"
    [ "$(wc -l < "$BATS_TEST_TMPDIR/windows1.txt")" -eq 2 ]
    run grep -F "zsh 0" "$BATS_TEST_TMPDIR/windows1.txt"
    [ "$status" -eq 0 ]

    names=("$REPO"/.claude/worktrees/*)
    [ "${#names[@]}" -eq 1 ]
    wt_name="$(basename "${names[0]}")"

    run grep -F "$wt_name 1" "$BATS_TEST_TMPDIR/windows1.txt"
    [ "$status" -eq 0 ]

    run tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{pane_current_path}'
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/panes1.txt"
    run grep -F "$REPO/.claude/worktrees/$wt_name" "$BATS_TEST_TMPDIR/panes1.txt"
    [ "$status" -eq 0 ]

    run bash -c "tmux -L '$TMUX_SOCK' list-panes -a -F '#{pane_in_mode}' | grep -vx 0"
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    for p in $(tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id}'); do
        run tmux -L "$TMUX_SOCK" capture-pane -p -t "$p"
        [[ "$output" != *"HEAD is now at"* ]]
        [[ "$output" != *"cs-new:"* ]]
    done
}

@test "fleet-menu: a forced cs-new failure leaves no new window and surfaces the error without a pane overlay" {
    stage_new_shims
    REPO="$(new_scratch_repo new-repo3)"
    git -C "$REPO" worktree add "$REPO/.claude/worktrees/dup-name" -b dup-name -q
    export CS_NEW_LAUNCH='sleep 47'
    export FLEET_MENU_NEW_NAME='dup-name'
    start_scratch_tmux_at "$REPO"

    run tmux -L "$TMUX_SOCK" run-shell "fleet-menu new #{pane_id} #{pane_current_path}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"fleet-menu new:"* ]]
    [[ "$output" == *"already in use"* ]]

    run tmux -L "$TMUX_SOCK" list-windows -F '#{window_name}'
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]

    run bash -c "tmux -L '$TMUX_SOCK' list-panes -a -F '#{pane_in_mode}' | grep -vx 0"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "fleet-menu: new session landing is captured as a PNG via take-screenshot term" {
    stage_new_shims
    REPO="$(new_scratch_repo new-repo4)"
    export CS_NEW_LAUNCH='sleep 47'
    start_scratch_tmux_at "$REPO"

    run tmux -L "$TMUX_SOCK" run-shell "fleet-menu new #{pane_id} #{pane_current_path}"
    [ "$status" -eq 0 ]

    names=("$REPO"/.claude/worktrees/*)
    wt_name="$(basename "${names[0]}")"

    state_txt="$BATS_TEST_TMPDIR/new-state.txt"
    {
        tmux -L "$TMUX_SOCK" list-windows -F '#{window_index}:#{window_name}#{?window_active, [active],}'
        echo
        tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{window_name} #{pane_current_command} #{pane_active} #{pane_in_mode}'
    } > "$state_txt"

    run grep -F "$wt_name [active]" "$state_txt"
    [ "$status" -eq 0 ]
    run grep -E "^%[0-9]+ $wt_name sleep 1 0\$" "$state_txt"
    [ "$status" -eq 0 ]

    png="/workspace/attachments/fleet-8wy7-new-state-$$.png"
    rm -f "$png"
    run take-screenshot term -o "$png" "cat $state_txt"
    [ "$status" -eq 0 ]
    [ -f "$png" ]
    size="$(wc -c < "$png")"
    [ "$size" -gt 20000 ]

    echo "fleet-menu new screenshot: $png"
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

@test "fleet-menu: the restored status bar's window row is captured as a PNG via take-screenshot term (beads_claude_docker-hka8)" {
    # Status bar restored to the job it did before 2c8f229 turned it off:
    # the evidence shot is of a capture-pane text proving every window
    # name is present in the rendered status line.
    REPO="$(new_scratch_repo statusbar-repo)"
    start_scratch_tmux_at "$REPO"
    # new-session -s base names the SESSION; window 0 is still named after
    # the shell tmux started in it, so name it explicitly -- the assertions
    # below are about the status line's window row, not window auto-naming.
    tmux -L "$TMUX_SOCK" rename-window -t base:0 base
    tmux -L "$TMUX_SOCK" new-window -n w-one -c "$REPO"
    tmux -L "$TMUX_SOCK" new-window -n w-two -c "$REPO"
    select_window_pane base

    # capture-pane -p doesn't include the status line, so poll
    # display-message against the actual status-line format instead --
    # the first render can lag session/window creation by a tick.
    status_txt="$BATS_TEST_TMPDIR/status-line.txt"
    for _ in $(seq 1 50); do
        tmux -L "$TMUX_SOCK" display-message -p -F '#{status} #{status-position} #{window_status_format}' > /dev/null
        {
            echo "status: $(tmux -L "$TMUX_SOCK" show-options -gv status)"
            echo "status-position: $(tmux -L "$TMUX_SOCK" show-options -gv status-position)"
            tmux -L "$TMUX_SOCK" list-windows -F '#I:#W'
        } > "$status_txt"
        if grep -qF "w-two" "$status_txt"; then
            break
        fi
        sleep 0.2
    done

    run grep -F "status: on" "$status_txt"
    [ "$status" -eq 0 ]
    for w in "0:base" "1:w-one" "2:w-two"; do
        run grep -F "$w" "$status_txt"
        [ "$status" -eq 0 ]
    done

    status_png="/workspace/attachments/fleet-hka8-status-$$.png"
    rm -f "$status_png"
    run take-screenshot term -o "$status_png" "cat $status_txt"
    [ "$status" -eq 0 ]
    [ -f "$status_png" ]
    size="$(wc -c < "$status_png")"
    [ "$size" -gt 20000 ]

    echo "fleet-menu status bar screenshot: $status_png"
}
