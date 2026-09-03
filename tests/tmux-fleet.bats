#!/usr/bin/env bats

# tmux-fleet.bats — scripts/fleet-menu.sh, installed as fleet-menu, plus
# config/tmux.conf's status bar / MouseDown3Pane extension / prefix
# keybindings for the worktree-session fleet: New worktree session / Hide
# / Restore… / Jump… / Review… / Remove merged… / Sidebar. See
# .claude/plans/worktree-sessions.md, beads_claude_docker-f5i6 and
# beads_claude_docker-blrl (F4b, the Sidebar item + prefix S + fleet-menu
# sidebar subcommand). Depends on F1 (beads_claude_docker-nmnb, cs-new).
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
# FROZEN again per blrl's own acceptance contract from blrl's RED commit
# onward: the MouseDown3Pane label test and the pane_id-passing test's
# subcommand loop were extended to cover the new Sidebar item/binding
# (both honest additions, not replacements, per blrl's own authorization
# to update this file), and one new test was added exercising `fleet-menu
# sidebar`'s delegation to `fleet toggle` end to end.
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

@test "fleet-menu: MouseDown3Pane binding contains the six new item labels plus Sidebar" {
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
    [[ "$output" == *"Sidebar"* ]]
}

@test "fleet-menu: list-keys shows prefix bindings for N H R J V M S mapped to fleet-menu commands" {
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
    run grep -E '(^| )S( |$).*fleet-menu sidebar' "$BATS_TEST_TMPDIR/prefix-keys.txt"
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
    for sub in new hide restore jump review remove-merged sidebar; do
        run grep -F "fleet-menu $sub #{pane_id}" "$BATS_TEST_TMPDIR/prefix-keys-paneid.txt"
        [ "$status" -eq 0 ]
    done
    run tmux -L "$TMUX_SOCK" list-keys -T root
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/root-keys-paneid.txt"
    for sub in new hide restore jump review remove-merged sidebar; do
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

# ── sidebar ──────────────────────────────────────────────────────────────

@test "fleet-menu: sidebar delegates to fleet toggle, opening then closing a 34-column pane" {
    start_scratch_tmux
    fake_tmux="$(fake_tmux_env "$TMUX_SOCK")"

    local before
    before="$(tmux -L "$TMUX_SOCK" list-panes -t base | wc -l)"
    [ "$before" -eq 1 ]

    run env -u TMUX TMUX="$fake_tmux" "$FLEET_MENU" sidebar
    [ "$status" -eq 0 ]

    run bash -c "tmux -L '$TMUX_SOCK' list-panes -t base -F '#{pane_id} #{pane_width} #{@fleet_sidebar}' | awk '\$3==\"1\"'"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "$(printf '%s\n' "$output" | awk '{print $2}')" -eq 34 ]

    run env -u TMUX TMUX="$fake_tmux" "$FLEET_MENU" sidebar
    [ "$status" -eq 0 ]

    run bash -c "tmux -L '$TMUX_SOCK' list-panes -t base | wc -l"
    [ "$output" -eq 1 ]
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

    # Precompute both captures' TEXT to files first -- a single tmux -F
    # call for the status listing, fleet-menu jump --print for the jump
    # menu -- then screenshot a trivial `cat <file>` for each, with an
    # explicit distinct -o path per capture. Two things this avoids:
    # (1) take-screenshot's default filename is term-<UTC second>.png
    # (scripts/take-screenshot.sh ts()/cmd_term()), so two captures
    # landing in the same wall-clock second silently overwrite one
    # another and the second path returned equals the first; (2) termshot
    # captures the pty on an idle-timeout heuristic that can fire before
    # a forked subprocess's output lands -- reproduced directly outside
    # this test: a chained `echo x; tmux ...` or fleet-menu jump's
    # per-window git subprocess loop, piped straight through
    # `take-screenshot term`, was truncated to its first line even though
    # the underlying command's own output was complete. `cat` never
    # forks, so it can't race either way.
    status_txt="$BATS_TEST_TMPDIR/status-bar.txt"
    tmux -L "$TMUX_SOCK" list-windows -F ' #{window_index}:#{window_name}#{?window_active, [active],}' > "$status_txt"
    for w in win-one win-two win-three; do
        run grep -F "$w" "$status_txt"
        [ "$status" -eq 0 ]
    done

    jump_txt="$BATS_TEST_TMPDIR/jump-print.txt"
    env -u TMUX TMUX="$fake_tmux" "$FLEET_MENU" jump --print > "$jump_txt"
    for w in win-one win-two win-three; do
        run grep -F "$w" "$jump_txt"
        [ "$status" -eq 0 ]
    done

    status_png="/workspace/attachments/fleet-f5i6-status-bar-$$.png"
    jump_png="/workspace/attachments/fleet-f5i6-jump-print-$$.png"
    rm -f "$status_png" "$jump_png"

    run take-screenshot term -o "$status_png" "cat $status_txt"
    [ "$status" -eq 0 ]
    [ -f "$status_png" ]

    run take-screenshot term -o "$jump_png" "cat $jump_txt"
    [ "$status" -eq 0 ]
    [ -f "$jump_png" ]

    [ "$status_png" != "$jump_png" ]
    status_size="$(wc -c < "$status_png")"
    jump_size="$(wc -c < "$jump_png")"
    [ "$status_size" -gt 5000 ]
    [ "$jump_size" -gt 5000 ]

    echo "fleet-menu screenshots: status_bar=$status_png jump_menu=$jump_png"
}
