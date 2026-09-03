#!/usr/bin/env bats

# fleet.bats — scripts/fleet.sh, installed as fleet: 'fleet --once' prints
# one row per worktree of the repo containing cwd (main tree first) --
# window, branch, dirty count, ahead/behind main, lane, live agents,
# last-activity age, each row within 34 columns; 'fleet --watch' redraws
# every 3s; 'fleet toggle [pane_id]' opens/closes a 34-column left sidebar
# pane running the watch loop. See .claude/plans/worktree-sessions.md and
# beads_claude_docker-1tym (F4). Depends on F1 (beads_claude_docker-nmnb,
# cs-new) and F3 (beads_claude_docker-7bam, peers/session-title) only in
# spirit (fleet reads the same transcript layout peers/lane/cost-mirror
# already established) -- no direct code dependency on either script.
#
# FROZEN per 1tym's acceptance contract from its RED commit until 1tym's
# own verification completes.
#
# Slug rule confirmed EMPIRICALLY, not just against the plan doc's own
# example: a real `claude -p` session opened at
# /tmp/fleetprobe/aaa/.claude/worktrees/bbb produced project dir
# -tmp-fleetprobe-aaa--claude-worktrees-bbb (double dash where '/' meets
# '.' -- '.' is replaced too, not just '/'). fleet.sh's slug_for_path()
# implements this as "replace every character that is not
# [A-Za-z0-9_-] with '-'".
#
# Every tmux test runs on a scratch `tmux -L fleet-test-<pid>-<rand>`
# server loaded with config/tmux.conf, never the live server this session
# is attached to -- same technique tests/tmux-fleet.bats already
# established (start_scratch_tmux / fake_tmux_env / new_scratch_repo /
# add_worktree below are adapted from that file's own helpers of the same
# name; fleet.sh's own toggle implementation reuses fleet-menu.sh's
# conventions: ambient $TMUX resolution with an explicit optional
# leading pane_id, scratch servers in tests, socket cleanup in teardown).

FLEET=/workspace/scripts/fleet.sh
REPO_ROOT=/workspace

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    TMUX_SOCK=""
}

teardown() {
    if [ -n "$TMUX_SOCK" ]; then
        tmux -L "$TMUX_SOCK" kill-server 2>/dev/null || true
        # kill-server doesn't always unlink its socket file (confirmed
        # empirically, matching tests/tmux-fleet.bats's own comment on
        # this) -- remove it explicitly so repeated runs don't
        # accumulate stale scratch sockets alongside the live one.
        rm -f "/tmp/tmux-1000/$TMUX_SOCK"
    fi
}

# ── tmux/git scratch helpers ────────────────────────────────────────────

# start_scratch_tmux [cwd] [x] [y] — a fresh tmux server on its own
# socket, loaded with this repo's config/tmux.conf, never the live one.
# Sets $TMUX_SOCK. The initial session is "base" with one window
# "mainwin" (cwd [cwd], default $BATS_TEST_TMPDIR; size [x]x[y], default
# 120x35).
start_scratch_tmux() {
    TMUX_SOCK="fleet-test-$$-${RANDOM}"
    local cwd="${1:-$BATS_TEST_TMPDIR}" x="${2:-120}" y="${3:-35}"
    tmux -L "$TMUX_SOCK" -f "$REPO_ROOT/config/tmux.conf" new-session -d -s base -n mainwin -c "$cwd" -x "$x" -y "$y"
}

# fake_tmux_env <socket-name> — a $TMUX value shaped like the real one
# tmux sets inside a pane (socket_path,pid,session_index), so a plain
# (unattached) process can target that server via bare `tmux <cmd>`.
fake_tmux_env() {
    sockpath="$(tmux -L "$1" display-message -p '#{socket_path}')"
    printf '%s,%s,0\n' "$sockpath" "$$"
}

# new_scratch_repo <name> — $BATS_TEST_TMPDIR/<name> as a git repo on
# branch main, with one commit that includes a .gitignore for
# .claude/worktrees/ (so worktrees created under it don't themselves show
# up as untracked/dirty in the main row). Echoes its canonical
# (symlink-resolved) absolute path.
new_scratch_repo() {
    dir="$BATS_TEST_TMPDIR/$1"
    mkdir -p "$dir"
    dir="$(cd "$dir" && pwd -P)"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name "Test"
    printf 'hello\n' > "$dir/f.txt"
    printf '.claude/worktrees/\n' > "$dir/.gitignore"
    git -C "$dir" add f.txt .gitignore
    git -C "$dir" commit -q -m init
    printf '%s\n' "$dir"
}

# add_worktree <root> <name> [commits] — a worktree at
# <root>/.claude/worktrees/<name> on a new branch <name> off <root>'s
# CURRENT HEAD, with [commits] (default 0) extra commits on top. Echoes
# its canonical absolute path.
add_worktree() {
    root="$1"
    name="$2"
    n="${3:-0}"
    git -C "$root" worktree add "$root/.claude/worktrees/$name" -b "$name" -q
    wt="$(cd "$root/.claude/worktrees/$name" && pwd -P)"
    i=1
    while [ "$i" -le "$n" ]; do
        ( cd "$wt" && echo "change $i" >> extra.txt && git add extra.txt && git commit -q -m "commit $i" )
        i=$((i + 1))
    done
    printf '%s\n' "$wt"
}

# write_session_fixture <worktree-path> <session-id> <lane> [role...] —
# $CLAUDE_PROJECTS_DIR/<slug-of-worktree-path>/<session-id>.jsonl (fresh
# mtime); $LANE_STATE_DIR/<session-id>.json with {"lane": <lane>} unless
# <lane> is "-"; one LIVE agent-live<n>.meta.json + fresh sibling .jsonl
# per role passed (customAgentType set to that role). Whenever at least
# one role is passed, also writes one STALE agent (agent-stale.meta.json,
# role verifier, sibling .jsonl mtime 10 minutes old, past
# LIVE_AGENT_WINDOW_S=120) so the fixture proves the liveness cutoff
# excludes it, not just that live ones are counted. Requires
# $CLAUDE_PROJECTS_DIR and $LANE_STATE_DIR already set by the caller.
write_session_fixture() {
    local wt="$1" sid="$2" lane="$3"
    shift 3
    local slug pdir
    slug="$(printf '%s' "$wt" | sed -E 's/[^A-Za-z0-9_-]/-/g')"
    pdir="$CLAUDE_PROJECTS_DIR/$slug"
    mkdir -p "$pdir"
    printf '{}\n' > "$pdir/$sid.jsonl"
    if [ "$lane" != "-" ]; then
        mkdir -p "$LANE_STATE_DIR"
        printf '{"lane":"%s"}\n' "$lane" > "$LANE_STATE_DIR/$sid.json"
    fi
    if [ "$#" -gt 0 ]; then
        mkdir -p "$pdir/$sid/subagents"
        local i=0 role
        for role in "$@"; do
            i=$((i + 1))
            printf '{"customAgentType":"%s"}' "$role" > "$pdir/$sid/subagents/agent-live$i.meta.json"
            printf '{}\n' > "$pdir/$sid/subagents/agent-live$i.jsonl"
        done
        printf '{"customAgentType":"verifier"}' > "$pdir/$sid/subagents/agent-stale.meta.json"
        printf '{}\n' > "$pdir/$sid/subagents/agent-stale.jsonl"
        touch -d '-10 minutes' "$pdir/$sid/subagents/agent-stale.jsonl"
    fi
}

# setup_fleet_fixture — the shared --once/toggle/screenshot scenario:
# ROOT (main, clean) plus worktrees wa/wb/wc under .claude/worktrees/,
# main tree first (git worktree list --porcelain's own ordering).
# Distinct ahead/behind-main via distinct commit histories (wa: 2
# ahead/1 behind; wb: 1 ahead/0 behind; wc: 0/0), distinct dirty counts
# (main 0, wa 1, wb 2, wc 0), tmux windows for main/wa/wc (wb gets NONE,
# covering the no-pane '-' window case). Session fixtures: wa -> lane
# deep, 0 live agents; wb -> lane standard, 2 live agents (executor,
# scout) plus one stale one that must not count. main and wc get no
# session fixture at all (lane '-', agents "0", age '-'). Exports
# CLAUDE_PROJECTS_DIR/LANE_STATE_DIR (scratch dirs, BEFORE starting tmux
# so the toggle/screenshot tests' spawned sidebar pane inherits them) and
# sets ROOT/WA/WB/WC plus TMUX_SOCK/FAKE_TMUX.
setup_fleet_fixture() {
    export CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/projects"
    export LANE_STATE_DIR="$BATS_TEST_TMPDIR/lane-state"
    mkdir -p "$CLAUDE_PROJECTS_DIR" "$LANE_STATE_DIR"

    ROOT="$(new_scratch_repo repo)"
    WA="$(add_worktree "$ROOT" wa 2)"
    ( cd "$ROOT" && echo more >> f.txt && git add f.txt && git commit -q -m "main commit 2" )
    WB="$(add_worktree "$ROOT" wb 1)"
    WC="$(add_worktree "$ROOT" wc 0)"

    echo dirty1 > "$WA/scratch1.txt"
    echo dirty1 > "$WB/scratch1.txt"
    echo dirty2 > "$WB/scratch2.txt"

    write_session_fixture "$WA" "sess-wa" "deep"
    write_session_fixture "$WB" "sess-wb" "standard" executor scout

    start_scratch_tmux "$ROOT" 120 35
    tmux -L "$TMUX_SOCK" new-window -n wawin -c "$WA" -t base
    tmux -L "$TMUX_SOCK" new-window -n wcwin -c "$WC" -t base
    tmux -L "$TMUX_SOCK" select-window -t base:mainwin
    FAKE_TMUX="$(fake_tmux_env "$TMUX_SOCK")"
}

# run_fleet_once — `fleet --once` from $ROOT against the scratch tmux
# server and CLAUDE_PROJECTS_DIR/LANE_STATE_DIR fixtures, via bats' run.
run_fleet_once() {
    run env -u TMUX TMUX="$FAKE_TMUX" CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" LANE_STATE_DIR="$LANE_STATE_DIR" \
        bash -c "cd '$ROOT' && exec '$FLEET' --once"
}

# ── --once: fixture scenario ────────────────────────────────────────────

@test "fleet --once: four rows (main + three worktrees), every field correct per row" {
    setup_fleet_fixture
    run_fleet_once
    [ "$status" -eq 0 ]
    # Contract-owner fix: bats' `run` overwrites $output on every call, so the
    # chained greps below must read the table captured once here, not the
    # previous grep's own stdout.
    local table
    table="$output"

    local n
    n="$(printf '%s\n' "$table" | grep -c .)"
    [ "$n" -eq 4 ]

    run grep -Fx "mainwin main 0 - - 0 -" <<<"$table"
    [ "$status" -eq 0 ]

    run grep -E '^wawin wa 1 2/1 deep 0 [0-9]+s$' <<<"$table"
    [ "$status" -eq 0 ]

    run grep -E '^- wb 2 1/0 standard 2 e,s [0-9]+s$' <<<"$table"
    [ "$status" -eq 0 ]

    run grep -Fx "wcwin wc 0 0/0 - 0 -" <<<"$table"
    [ "$status" -eq 0 ]
}

@test "fleet --once: a worktree with no matching tmux pane shows '-' as window" {
    setup_fleet_fixture
    run_fleet_once
    [ "$status" -eq 0 ]
    run grep -E '^- wb ' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "fleet --once: no row is wider than 34 columns" {
    setup_fleet_fixture
    run_fleet_once
    [ "$status" -eq 0 ]
    run bash -c "printf '%s\n' \"\$1\" | awk '{ if (length(\$0) > 34) print NR\": \"length(\$0)\": \"\$0 }'" _ "$output"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fleet --once: exits 0 with a one-line notice outside a git repository" {
    local dir="$BATS_TEST_TMPDIR/not-a-repo"
    mkdir -p "$dir"
    run bash -c "cd '$dir' && exec '$FLEET' --once"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
    [[ "$output" == *"not inside a git repository"* ]]
}

# ── toggle ───────────────────────────────────────────────────────────────

@test "fleet toggle: opens a 34-column left pane running fleet, keeps focus, and a second toggle closes it" {
    ROOT="$(new_scratch_repo repo)"
    start_scratch_tmux "$ROOT" 120 35
    FAKE_TMUX="$(fake_tmux_env "$TMUX_SOCK")"

    local before
    before="$(tmux -L "$TMUX_SOCK" list-panes -t base | wc -l)"
    [ "$before" -eq 1 ]

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle
    [ "$status" -eq 0 ]

    run bash -c "tmux -L '$TMUX_SOCK' list-panes -t base | wc -l"
    [ "$output" -eq 2 ]

    run bash -c "tmux -L '$TMUX_SOCK' list-panes -t base -F '#{pane_id} #{pane_width} #{@fleet_sidebar}' | awk '\$3==\"1\"'"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "$(printf '%s\n' "$output" | awk '{print $2}')" -eq 34 ]

    run bash -c "tmux -L '$TMUX_SOCK' list-panes -t base -F '#{pane_active} #{@fleet_sidebar}' | awk '\$1==1 && \$2==\"1\"'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle
    [ "$status" -eq 0 ]

    run bash -c "tmux -L '$TMUX_SOCK' list-panes -t base | wc -l"
    [ "$output" -eq 1 ]
}

# ── Dockerfile / plugin ─────────────────────────────────────────────────

@test "fleet: Dockerfile has a COPY line staging scripts/fleet.sh as fleet" {
    run grep -E '^COPY( +--\S+)* +scripts/fleet\.sh +/usr/local/bin/fleet *$' /workspace/Dockerfile
    [ "$status" -eq 0 ]
}

@test "fleet: plugin/bin/fleet is byte-identical to scripts/fleet.sh" {
    [ -f /workspace/plugin/bin/fleet ]
    diff -q /workspace/plugin/bin/fleet /workspace/scripts/fleet.sh
}

# ── screenshots ──────────────────────────────────────────────────────────

# capture_with_retry <out_png> <cmd> — take-screenshot term -o <out_png>
# <cmd>, retried up to 3 times if the resulting PNG is under 20000 bytes
# (a known termshot flake: an occasional blank-frame capture around
# 10 KB, reproduced during this bead's own manual verification). The
# caller's own size assertion is what actually fails the test if every
# attempt comes back blank.
capture_with_retry() {
    local out="$1" cmd="$2" tries=0 size
    while :; do
        rm -f "$out"
        take-screenshot term -o "$out" "$cmd" >/dev/null
        size=0
        [ -f "$out" ] && size="$(wc -c < "$out")"
        tries=$((tries + 1))
        if [ "$size" -ge 20000 ] || [ "$tries" -ge 3 ]; then
            return 0
        fi
    done
}

@test "fleet sidebar: usability screenshots at 120x35 and 200x50 (take-screenshot term)" {
    setup_fleet_fixture

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle
    [ "$status" -eq 0 ]

    local sidebar_pane main_pane
    sidebar_pane="$(tmux -L "$TMUX_SOCK" list-panes -t base:mainwin -F '#{pane_id} #{@fleet_sidebar}' | awk '$2=="1"{print $1}')"
    main_pane="$(tmux -L "$TMUX_SOCK" list-panes -t base:mainwin -F '#{pane_id} #{@fleet_sidebar}' | awk '$2!="1"{print $1}')"
    [ -n "$sidebar_pane" ]
    [ -n "$main_pane" ]

    # let the first watch iteration render before capturing.
    sleep 1

    local cap1="$BATS_TEST_TMPDIR/capture-120x35.txt"
    paste -d'|' \
        <(tmux -L "$TMUX_SOCK" capture-pane -pJ -t "$sidebar_pane") \
        <(tmux -L "$TMUX_SOCK" capture-pane -p -t "$main_pane") \
        > "$cap1"

    for expect in "wa 1 2/1 deep 0" "wb 2 1/0 standard 2 e,s" "wc 0 0/0 - 0"; do
        run grep -F "$expect" "$cap1"
        [ "$status" -eq 0 ]
    done

    # resize the whole window to the second size, then re-pin the
    # sidebar to its own 34-column budget -- tmux's resize-window
    # rescales existing panes proportionally rather than holding a
    # `split -l 34` pane's absolute width (confirmed empirically), so
    # without this the sidebar would grow past 34 along with the window.
    tmux -L "$TMUX_SOCK" resize-window -t base -x 200 -y 50
    tmux -L "$TMUX_SOCK" resize-pane -t "$sidebar_pane" -x 34
    sleep 1

    local cap2="$BATS_TEST_TMPDIR/capture-200x50.txt"
    paste -d'|' \
        <(tmux -L "$TMUX_SOCK" capture-pane -pJ -t "$sidebar_pane") \
        <(tmux -L "$TMUX_SOCK" capture-pane -p -t "$main_pane") \
        > "$cap2"

    for expect in "wa 1 2/1 deep 0" "wb 2 1/0 standard 2 e,s" "wc 0 0/0 - 0"; do
        run grep -F "$expect" "$cap2"
        [ "$status" -eq 0 ]
    done

    local png1="/workspace/attachments/fleet-1tym-120x35-$$.png"
    local png2="/workspace/attachments/fleet-1tym-200x50-$$.png"
    rm -f "$png1" "$png2"

    capture_with_retry "$png1" "cat $cap1"
    capture_with_retry "$png2" "cat $cap2"

    [ -f "$png1" ]
    [ -f "$png2" ]
    [ "$(wc -c < "$png1")" -ge 20000 ]
    [ "$(wc -c < "$png2")" -ge 20000 ]

    echo "fleet sidebar screenshots: 120x35=$png1 200x50=$png2"
}
