#!/usr/bin/env bats

# fleet.bats — scripts/fleet.sh, installed as fleet: 'fleet --once' prints
# a header row ('win branch +- a/b lane ag age') followed by one row per
# worktree of the repo containing cwd (main tree first) -- a leading '*'
# marker (live agents > 0) or ' ', window, branch, dirty count,
# ahead/behind main, a single-letter lane code (same abbreviation
# convention as the agent-role letters), live agents, last-activity age,
# each row within 34 columns. window/branch are fixed-width (WINDOW_MAX /
# BRANCH_MAX): padded when shorter, truncated with a trailing '+' when
# longer, so branch always starts at the same column offset. 'fleet
# --watch' redraws every 3s; 'fleet toggle [pane_id]' opens/closes a
# 34-column left sidebar pane running the watch loop. See
# .claude/plans/worktree-sessions.md, beads_claude_docker-1tym (F4) and
# beads_claude_docker-blrl (F4b, the header/alignment/marker polish).
# Depends on F1 (beads_claude_docker-nmnb, cs-new) and F3
# (beads_claude_docker-7bam, peers/session-title) only in spirit (fleet
# reads the same transcript layout peers/lane/cost-mirror already
# established) -- no direct code dependency on either script.
#
# FROZEN per 1tym's acceptance contract from its RED commit until 1tym's
# own verification completed, and per blrl's acceptance contract from
# blrl's own RED commit onward. 1tym's own addition (bead-owner-authorized,
# after 1tym's GREEN, before blrl started): the project-dir slug rule ('.'
# and '_' both replaced, not just '/') was independently reconfirmed by
# the bead owner via their own live `claude -p` probe, who asked for a
# test pinning that exact example; the "lane resolves ... containing '.'"
# test below is that pin. blrl's own changes (this bead, made honestly in
# its own RED commit per its acceptance contract's explicit authorization
# to update this FROZEN file's exact-line assertions into field regexes
# plus alignment checks): the four-row test's per-row assertions became
# regexes matching the new marker/padded-column/lane-letter row shape; a
# header-first check was folded into that same test; a dedicated
# branch-offset-alignment test, a truncation test, and a dedicated
# agent-marker test were added; the screenshot test's substring greps
# were updated for the new row shape; a companion underscore slug case
# was added next to the existing dot one. No other test's assertions were
# touched.
#
# Slug rule confirmed EMPIRICALLY, not just against the plan doc's own
# example: a real `claude -p` session opened at
# /tmp/fleetprobe/aaa/.claude/worktrees/bbb produced project dir
# -tmp-fleetprobe-aaa--claude-worktrees-bbb (double dash where '/' meets
# '.' -- '.' is replaced too, not just '/'); a second probe with
# underscores in both path components (.../a_b/.claude/worktrees/c_d)
# produced .../a-b--claude-worktrees-c-d, confirming '_' is replaced too,
# not preserved. fleet.sh's slug_for_path() implements this as "replace
# every character that is not [A-Za-z0-9] with '-'".
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

@test "fleet --once: header row first, then four data rows (main + three worktrees), every field correct per row" {
    setup_fleet_fixture
    run_fleet_once
    [ "$status" -eq 0 ]
    # Contract-owner fix (kept from the pre-blrl test): bats' `run`
    # overwrites $output on every call, so the chained greps below must
    # read the table captured once here, not the previous grep's own
    # stdout.
    local table
    table="$output"

    # header row first, then exactly four data rows.
    local n
    n="$(printf '%s\n' "$table" | grep -c .)"
    [ "$n" -eq 5 ]
    local header
    header="$(printf '%s\n' "$table" | sed -n 1p)"
    [[ "$header" == *"win"* ]]
    [[ "$header" == *"branch"* ]]
    [[ "$header" == *"lane"* ]]
    [[ "$header" == *"ag"* ]]
    [[ "$header" == *"age"* ]]

    # per-row field regexes (not exact-line): marker, padded window,
    # padded branch, right-aligned dirty, ahead/behind, lane letter,
    # agents, age. Whitespace runs (`[ ]+`) absorb the exact pad_trunc()
    # column widths rather than hardcoding them a second time here.
    run grep -E '^ {2}mainw\+[ ]+main[ ]+0[ ]+-[ ]+-[ ]+0[ ]+-$' <<<"$table"
    [ "$status" -eq 0 ]

    run grep -E '^ {2}wawin[ ]+wa[ ]+1[ ]+2/1[ ]+d[ ]+0[ ]+[0-9]+s$' <<<"$table"
    [ "$status" -eq 0 ]

    run grep -E '^\*[ ]+-[ ]+wb[ ]+2[ ]+1/0[ ]+s[ ]+2[ ]+e,s[ ]+[0-9]+s$' <<<"$table"
    [ "$status" -eq 0 ]

    run grep -E '^ {2}wcwin[ ]+wc[ ]+0[ ]+0/0[ ]+-[ ]+0[ ]+-$' <<<"$table"
    [ "$status" -eq 0 ]
}

@test "fleet --once: a worktree with no matching tmux pane shows '-' as window" {
    setup_fleet_fixture
    run_fleet_once
    [ "$status" -eq 0 ]
    run grep -E '^\*[ ]+-[ ]+wb[ ]' <<<"$output"
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

# Derives the branch column's offset from the header row (where "branch"
# starts, 1-indexed) rather than hardcoding WINDOW_MAX's current value a
# second time, then confirms every one of the four data rows' branch
# value begins at that exact same offset -- the core alignment guarantee
# pad_trunc()'s fixed-width window/marker prefix exists to provide.
@test "fleet --once: the branch column begins at the same offset on every row" {
    setup_fleet_fixture
    run_fleet_once
    [ "$status" -eq 0 ]
    local header offset data n
    header="$(printf '%s\n' "$output" | sed -n 1p)"
    offset="$(awk -v h="$header" 'BEGIN{print index(h, "branch")}')"
    [ "$offset" -gt 0 ]
    data="$(printf '%s\n' "$output" | tail -n +2)"
    n="$(printf '%s\n' "$data" | grep -c .)"
    [ "$n" -eq 4 ]
    for want in main wa wb wc; do
        run bash -c 'printf "%s\n" "$1" | awk -v off="$2" -v w="$3" "substr(\$0, off, length(w)) == w { found=1 } END { exit !found }"' _ "$data" "$offset" "$want"
        [ "$status" -eq 0 ]
    done
}

# Confirms the row for the worktree with two live agents (wb) carries the
# leading '*' marker, and the other three (no live agents) carry a plain
# leading space instead -- the "someone is working there" signal.
@test "fleet --once: a row with live agents (count > 0) carries a leading '*' marker; others don't" {
    setup_fleet_fixture
    run_fleet_once
    [ "$status" -eq 0 ]
    # bats' `run` overwrites $output on every call (see the "Contract-owner
    # fix" note on the four-row test above) -- capture the table once so
    # each of the four greps below reads it, not the previous grep's own
    # (narrower) stdout.
    local table
    table="$output"
    run grep -E '^\*[ ]+-[ ]+wb[ ]' <<<"$table"
    [ "$status" -eq 0 ]
    run grep -E '^ {2}mainw\+' <<<"$table"
    [ "$status" -eq 0 ]
    run grep -E '^ {2}wawin' <<<"$table"
    [ "$status" -eq 0 ]
    run grep -E '^ {2}wcwin' <<<"$table"
    [ "$status" -eq 0 ]
}

# Over-long window and branch names truncate to their fixed column width
# with a trailing visible '+' marker rather than pushing later columns
# out of alignment or the row past 34 columns.
@test "fleet --once: an over-long window or branch name truncates with a visible '+' marker" {
    export CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/projects"
    export LANE_STATE_DIR="$BATS_TEST_TMPDIR/lane-state"
    mkdir -p "$CLAUDE_PROJECTS_DIR" "$LANE_STATE_DIR"

    ROOT="$(new_scratch_repo repo)"
    local longbranch="this-is-a-very-long-branch-name-indeed"
    local longwindow="this-is-a-very-long-window-name-too"
    WD="$(add_worktree "$ROOT" "$longbranch" 0)"
    start_scratch_tmux "$ROOT" 120 35
    tmux -L "$TMUX_SOCK" new-window -n "$longwindow" -c "$WD" -t base
    tmux -L "$TMUX_SOCK" select-window -t base:mainwin
    FAKE_TMUX="$(fake_tmux_env "$TMUX_SOCK")"

    run_fleet_once
    [ "$status" -eq 0 ]
    # capture once: a `run grep` immediately below would otherwise
    # overwrite $output with its own (narrower) stdout before the
    # 34-column check re-reads it (see the "Contract-owner fix" note on
    # the four-row test above).
    local table
    table="$output"

    # both fields truncate to their WINDOW_MAX/BRANCH_MAX width (6) with a
    # trailing '+': the shared first-5-chars prefix of window and branch
    # here is "this-" for both, so each truncated field reads "this-+".
    run grep -E '^ {2}this-\+[ ]+this-\+[ ]' <<<"$table"
    [ "$status" -eq 0 ]

    run bash -c "printf '%s\n' \"\$1\" | awk '{ if (length(\$0) > 34) print }'" _ "$table"
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

# Added post-GREEN, bead-owner-authorized (see the file header and
# beads_claude_docker-1tym's notes): pins the project-dir slug rule
# against a worktree whose name contains '.', the same shape as the bead
# owner's own live-session probe (…/.claude/worktrees/slug.probe ->
# project dir …-claude-worktrees-slug-probe). A live session isn't
# available inside a bats test, so this pins the rule at the boundary
# that's actually observable here: fleet.sh's own slug_for_path()
# (re-derived independently below via the exact confirmed transform, not
# imported from fleet.sh) must compute the SAME project dir fleet.sh
# itself uses internally, since only then does a lane fixture written
# under that computed dir get picked up -- if slug_for_path() disagreed
# (e.g. by leaving '.' unreplaced), fleet --once would report lane '-'
# instead of "deep" and this test would fail.
@test "fleet --once: lane resolves for a worktree path containing '.' (project-dir slug rule)" {
    export CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/projects"
    export LANE_STATE_DIR="$BATS_TEST_TMPDIR/lane-state"
    mkdir -p "$CLAUDE_PROJECTS_DIR" "$LANE_STATE_DIR"

    ROOT="$(new_scratch_repo repo)"
    WD="$(add_worktree "$ROOT" "slug.probe" 0)"

    local slug
    slug="$(printf '%s' "$WD" | sed 's/[^A-Za-z0-9]/-/g')"
    mkdir -p "$CLAUDE_PROJECTS_DIR/$slug"
    printf '{}\n' > "$CLAUDE_PROJECTS_DIR/$slug/sess-dot.jsonl"
    printf '{"lane":"deep"}\n' > "$LANE_STATE_DIR/sess-dot.json"

    run bash -c "cd '$WD' && exec '$FLEET' --once"
    [ "$status" -eq 0 ]
    # branch "slug.probe" (10 chars) exceeds BRANCH_MAX (6) and truncates
    # to its first 5 chars + '+': "slug.+".
    run grep -E '^ {2}-[ ]+slug\.\+[ ]+0[ ]+0/0[ ]+d[ ]+0[ ]+[0-9]+s$' <<<"$output"
    [ "$status" -eq 0 ]
}

# Companion to the '.' case above, added for beads_claude_docker-blrl:
# pins the SAME slug rule for '_', both independently (the exact literal
# example from the bead brief, which must never be exercised against the
# real repo since it would create an actual worktree there) and via a
# live fleet --once run against a scratch worktree whose path contains
# underscores in both the repo-root and worktree-name components, the
# same shape as the canonical example.
@test "fleet --once: lane resolves for a worktree path containing '_' (project-dir slug rule)" {
    [ "$(printf '%s' "/workspace/.claude/worktrees/a_b" | sed 's/[^A-Za-z0-9]/-/g')" = "-workspace--claude-worktrees-a-b" ]

    export CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/projects"
    export LANE_STATE_DIR="$BATS_TEST_TMPDIR/lane-state"
    mkdir -p "$CLAUDE_PROJECTS_DIR" "$LANE_STATE_DIR"

    ROOT="$(new_scratch_repo a_b)"
    WD="$(add_worktree "$ROOT" "c_d" 0)"

    local slug
    slug="$(printf '%s' "$WD" | sed 's/[^A-Za-z0-9]/-/g')"
    mkdir -p "$CLAUDE_PROJECTS_DIR/$slug"
    printf '{}\n' > "$CLAUDE_PROJECTS_DIR/$slug/sess-us.jsonl"
    printf '{"lane":"express"}\n' > "$LANE_STATE_DIR/sess-us.json"

    run bash -c "cd '$WD' && exec '$FLEET' --once"
    [ "$status" -eq 0 ]
    run grep -E '^ {2}-[ ]+c_d[ ]+0[ ]+0/0[ ]+e[ ]+0[ ]+[0-9]+s$' <<<"$output"
    [ "$status" -eq 0 ]
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

    # field-regex substrings (not exact-string): the new row shape pads
    # window/branch to a fixed width and abbreviates lane to a single
    # letter, so exact spacing/words can't be hardcoded here the way the
    # pre-blrl "deep"/"standard" full-word substrings could.
    for expect in 'wawin[ ]+wa[ ]+1[ ]+2/1[ ]+d[ ]+0' '-[ ]+wb[ ]+2[ ]+1/0[ ]+s[ ]+2[ ]+e,s' 'wcwin[ ]+wc[ ]+0[ ]+0/0[ ]+-[ ]+0'; do
        # -e disambiguates a pattern beginning with a literal '-' (the
        # "-...wb..." case below, window field '-' with no matching pane)
        # from an option flag -- this system's `grep` is ugrep, which
        # (unlike GNU grep) rejects a leading-dash pattern passed bare.
        run grep -E -e "$expect" "$cap1"
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

    for expect in 'wawin[ ]+wa[ ]+1[ ]+2/1[ ]+d[ ]+0' '-[ ]+wb[ ]+2[ ]+1/0[ ]+s[ ]+2[ ]+e,s' 'wcwin[ ]+wc[ ]+0[ ]+0/0[ ]+-[ ]+0'; do
        run grep -E -e "$expect" "$cap2"
        [ "$status" -eq 0 ]
    done

    local png1="/workspace/attachments/fleet-blrl-120x35-$$.png"
    local png2="/workspace/attachments/fleet-blrl-200x50-$$.png"
    rm -f "$png1" "$png2"

    capture_with_retry "$png1" "cat $cap1"
    capture_with_retry "$png2" "cat $cap2"

    [ -f "$png1" ]
    [ -f "$png2" ]
    [ "$(wc -c < "$png1")" -ge 20000 ]
    [ "$(wc -c < "$png2")" -ge 20000 ]

    echo "fleet sidebar screenshots: 120x35=$png1 200x50=$png2"
}

# ── fleet nav: rows / go / follow / toggle-anywhere / buffered frame ──────
# Added for beads_claude_docker-vyzk (G1 of .claude/plans/fleet-nav.md):
# 'fleet rows' (machine-readable rows behind --once/--watch, worktree rows
# then one row per tmux window not represented by a worktree row), 'fleet
# go <name|path|@window>' (moves the server-wide sidebar to the matching
# row's window/pane, or opens one via 'cs-new --open' for a worktree with
# none yet), 'fleet follow' (sidebar tracks the ambient current window),
# 'fleet toggle' made server-wide (close if here, move if elsewhere, open
# if none), and --watch's flicker-free single-printf buffered frame
# (FLEET_MAX_TICKS bounds the loop for tests). FROZEN alongside the rest
# of this file per vyzk's own acceptance contract from its RED commit
# onward. No existing assertion above was touched: every tmux window this
# file's own fixtures create already has a matching worktree path, so the
# new "one row per unrepresented window" rule adds zero rows to any
# pre-existing scenario -- confirmed by inspection of setup_fleet_fixture
# (mainwin/wawin/wcwin's cwd are each exactly ROOT/WA/WC) and re-derived
# empirically (a scratch probe against pad_trunc()/ROW_FMT, not just read
# off the source) for the exact window-row field widths asserted below.

# wait_for <max_tries> <cmd...> — polls every 0.2s (up to max_tries times)
# until <cmd...> exits 0. Independently duplicated from
# tests/worktree-sessions.bats's own helper of the same name/shape, per
# this codebase's existing convention of small per-file helpers rather
# than cross-file sharing (see e.g. new_scratch_repo/fake_tmux_env, each
# defined separately in fleet.bats, worktree-sessions.bats and
# tmux-fleet.bats already).
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

@test "fleet rows: worktree rows then one row per unrepresented tmux window; TSV shape; display matches fleet --once" {
    setup_fleet_fixture
    OTHER="$(new_scratch_repo other)"
    tmux -L "$TMUX_SOCK" new-window -n extrawin -c "$BATS_TEST_TMPDIR" -t base
    tmux -L "$TMUX_SOCK" new-window -n gitwin -c "$OTHER" -t base
    tmux -L "$TMUX_SOCK" select-window -t base:mainwin

    run env -u TMUX TMUX="$FAKE_TMUX" CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" LANE_STATE_DIR="$LANE_STATE_DIR" \
        bash -c "cd '$ROOT' && exec '$FLEET' rows"
    [ "$status" -eq 0 ]
    local rows
    rows="$output"
    [ "$(printf '%s\n' "$rows" | grep -c .)" -eq 6 ]

    # first four rows are the worktree rows, in list_worktrees_with_branch's
    # own (main-first) order -- unchanged from --once's existing contract.
    local worktree_kinds
    worktree_kinds="$(printf '%s\n' "$rows" | head -n4 | cut -f2)"
    [ "$(printf '%s\n' "$worktree_kinds" | sort -u)" = "worktree" ]

    # row 5: the "extrawin" window (cwd outside any worktree and outside
    # any git repo) -- kind/name/path/window_id/pane_id fields, plus the
    # display column's window/branch fields (branch '-': not a git repo).
    local row5
    row5="$(printf '%s\n' "$rows" | sed -n 5p)"
    [ "$(printf '%s' "$row5" | cut -f2)" = "window" ]
    [ "$(printf '%s' "$row5" | cut -f3)" = "extrawin" ]
    run bash -c "cd '$BATS_TEST_TMPDIR' && pwd -P"
    [ "$(printf '%s' "$row5" | cut -f4)" = "$output" ]
    [[ "$(printf '%s' "$row5" | cut -f5)" == @* ]]
    [[ "$(printf '%s' "$row5" | cut -f6)" == %* ]]
    run grep -E '^ {2}extra\+[ ]+-[ ]+-[ ]+-[ ]+-[ ]+-[ ]+-$' <<<"$(printf '%s' "$row5" | cut -f1)"
    [ "$status" -eq 0 ]

    # row 6: the "gitwin" window (cwd = a DIFFERENT git repo, not one of
    # ROOT's worktrees) -- branch resolves ("main"), everything else '-'.
    local row6
    row6="$(printf '%s\n' "$rows" | sed -n 6p)"
    [ "$(printf '%s' "$row6" | cut -f2)" = "window" ]
    [ "$(printf '%s' "$row6" | cut -f3)" = "gitwin" ]
    run bash -c "cd '$OTHER' && pwd -P"
    [ "$(printf '%s' "$row6" | cut -f4)" = "$output" ]
    run grep -E '^ {2}gitwin[ ]+main[ ]+-[ ]+-[ ]+-[ ]+-[ ]+-$' <<<"$(printf '%s' "$row6" | cut -f1)"
    [ "$status" -eq 0 ]

    # 'fleet --once' (header stripped) is textually identical to rows'
    # own display column, for every row including the two window rows --
    # both are built by the same underlying row generator. Contract-owner
    # fix (beads_claude_docker-bj6x, test hardening pre-authorized in its
    # own brief now that vyzk is verified): --once and rows are two
    # SEPARATE 'fleet' invocations here, and the age field ("<n>s") is
    # wall-clock-derived, so a real second ticking over between the two
    # processes could flip e.g. "3s" to "4s" and fail this comparison for
    # a reason that has nothing to do with the row-generator identity the
    # test exists to check. Normalise each row's trailing age field (the
    # last whitespace-delimited token, always the very end of the line
    # per ROW_FMT) to a fixed placeholder on both sides before comparing
    # -- this only masks a value that is EXPECTED to differ by process,
    # never any of the fields the test actually cares about (window,
    # branch, dirty, ahead/behind, lane, agents all stay byte-exact).
    run_fleet_once
    [ "$status" -eq 0 ]
    local once_data rows_display once_norm rows_norm
    once_data="$(printf '%s\n' "$output" | tail -n +2)"
    rows_display="$(printf '%s\n' "$rows" | cut -f1)"
    once_norm="$(printf '%s\n' "$once_data" | sed -E 's/[0-9]+[smhd]$/AGE/; s/-$/AGE/')"
    rows_norm="$(printf '%s\n' "$rows_display" | sed -E 's/[0-9]+[smhd]$/AGE/; s/-$/AGE/')"
    [ "$once_norm" = "$rows_norm" ]

    run bash -c "printf '%s\n' \"\$1\" | awk '{ if (length(\$0) > 34) print }'" _ "$once_data"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fleet go: moves the sidebar into an existing worktree window, selects its pane, leaves no pane in copy-mode" {
    setup_fleet_fixture

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle
    [ "$status" -eq 0 ]
    local sidebar_pane
    sidebar_pane="$(tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{@fleet_sidebar}' | awk '$2=="1"{print $1}')"
    [ -n "$sidebar_pane" ]

    local wa_pane
    wa_pane="$(tmux -L "$TMUX_SOCK" list-panes -t base:wawin -F '#{pane_id}')"
    [ -n "$wa_pane" ]

    run env -u TMUX TMUX="$FAKE_TMUX" bash -c "cd '$ROOT' && exec '$FLEET' go wa"
    [ "$status" -eq 0 ]

    run tmux -L "$TMUX_SOCK" display -p -t "$sidebar_pane" '#{window_name}'
    [ "$output" = "wawin" ]

    run tmux -L "$TMUX_SOCK" list-panes -t base:wawin -F '#{pane_active} #{pane_id}'
    [[ "$output" == *"1 $wa_pane"* ]]

    run tmux -L "$TMUX_SOCK" display -p -t "$sidebar_pane" '#{pane_width} #{pane_at_left}'
    [ "$output" = "34 1" ]

    run bash -c "tmux -L '$TMUX_SOCK' list-panes -a -F '#{pane_in_mode}' | grep -vx 0"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "fleet go: a worktree with no window opens one via cs-new --open, and the sidebar follows it" {
    setup_fleet_fixture

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle
    [ "$status" -eq 0 ]
    local sidebar_pane
    sidebar_pane="$(tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{@fleet_sidebar}' | awk '$2=="1"{print $1}')"
    [ -n "$sidebar_pane" ]

    local envfile="$BATS_TEST_TMPDIR/wb-env.txt"
    run env -u TMUX TMUX="$FAKE_TMUX" CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" LANE_STATE_DIR="$LANE_STATE_DIR" \
        bash -c "cd '$ROOT' && CS_NEW_LAUNCH=\"env > '$envfile'; sleep 47\" exec '$FLEET' go wb"
    [ "$status" -eq 0 ]

    run tmux -L "$TMUX_SOCK" list-windows -F '#{window_name} #{pane_current_path}'
    [[ "$output" == *"wb $WB"* ]]

    wait_for 50 bash -c "[ -s '$envfile' ]"
    run grep -x "BEADS_DIR=$ROOT/.beads" "$envfile"
    [ "$status" -eq 0 ]

    run tmux -L "$TMUX_SOCK" display -p -t "$sidebar_pane" '#{window_name}'
    [ "$output" = "wb" ]
}

@test "fleet follow: moves the sidebar to the window made current by 'tmux select-window'; no-op once already there" {
    ROOT="$(new_scratch_repo repo)"
    WA="$(add_worktree "$ROOT" wa 0)"
    start_scratch_tmux "$ROOT" 120 35
    tmux -L "$TMUX_SOCK" new-window -n wawin -c "$WA" -t base
    tmux -L "$TMUX_SOCK" select-window -t base:mainwin
    FAKE_TMUX="$(fake_tmux_env "$TMUX_SOCK")"

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle
    [ "$status" -eq 0 ]
    local sidebar_pane before_window
    sidebar_pane="$(tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{@fleet_sidebar}' | awk '$2=="1"{print $1}')"
    [ -n "$sidebar_pane" ]
    before_window="$(tmux -L "$TMUX_SOCK" display -p -t "$sidebar_pane" '#{window_id}')"

    tmux -L "$TMUX_SOCK" select-window -t base:wawin

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" follow
    [ "$status" -eq 0 ]

    local sidebar_pane2 sidebar_window
    sidebar_pane2="$(tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{@fleet_sidebar}' | awk '$2=="1"{print $1}')"
    [ "$sidebar_pane2" = "$sidebar_pane" ]
    sidebar_window="$(tmux -L "$TMUX_SOCK" display -p -t "$sidebar_pane" '#{window_id}')"
    [ "$sidebar_window" != "$before_window" ]
    run tmux -L "$TMUX_SOCK" display -p -t "$sidebar_pane" '#{window_name}'
    [ "$output" = "wawin" ]

    local panes_before panes_after
    panes_before="$(tmux -L "$TMUX_SOCK" list-panes -a | wc -l)"

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" follow
    [ "$status" -eq 0 ]

    local sidebar_pane3 sidebar_window2
    sidebar_pane3="$(tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{@fleet_sidebar}' | awk '$2=="1"{print $1}')"
    [ "$sidebar_pane3" = "$sidebar_pane" ]
    sidebar_window2="$(tmux -L "$TMUX_SOCK" display -p -t "$sidebar_pane" '#{window_id}')"
    [ "$sidebar_window2" = "$sidebar_window" ]
    panes_after="$(tmux -L "$TMUX_SOCK" list-panes -a | wc -l)"
    [ "$panes_after" -eq "$panes_before" ]
}

@test "fleet toggle: server-wide -- from a window without the sidebar while open elsewhere it moves (not a new pane); from the window that has it, kills it" {
    ROOT="$(new_scratch_repo repo)"
    WA="$(add_worktree "$ROOT" wa 0)"
    start_scratch_tmux "$ROOT" 120 35
    tmux -L "$TMUX_SOCK" new-window -n wawin -c "$WA" -t base
    tmux -L "$TMUX_SOCK" select-window -t base:mainwin
    FAKE_TMUX="$(fake_tmux_env "$TMUX_SOCK")"

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle
    [ "$status" -eq 0 ]
    local sidebar_pane panes_after_open
    sidebar_pane="$(tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{@fleet_sidebar}' | awk '$2=="1"{print $1}')"
    [ -n "$sidebar_pane" ]
    panes_after_open="$(tmux -L "$TMUX_SOCK" list-panes -a | wc -l)"

    local wa_pane
    wa_pane="$(tmux -L "$TMUX_SOCK" list-panes -t base:wawin -F '#{pane_id}')"

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle "$wa_pane"
    [ "$status" -eq 0 ]

    local sidebar_pane2 panes_after_move
    sidebar_pane2="$(tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{@fleet_sidebar}' | awk '$2=="1"{print $1}')"
    [ "$sidebar_pane2" = "$sidebar_pane" ]
    panes_after_move="$(tmux -L "$TMUX_SOCK" list-panes -a | wc -l)"
    [ "$panes_after_move" -eq "$panes_after_open" ]
    run tmux -L "$TMUX_SOCK" display -p -t "$sidebar_pane" '#{window_name}'
    [ "$output" = "wawin" ]

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle "$wa_pane"
    [ "$status" -eq 0 ]
    run bash -c "tmux -L '$TMUX_SOCK' list-panes -a -F '#{@fleet_sidebar}' | grep -c '^1\$'"
    [ "$output" -eq 0 ]
}

@test "fleet --watch: FLEET_MAX_TICKS bounds the loop; frames are single buffered writes with no clear/2J/3J" {
    ROOT="$(new_scratch_repo repo)"
    local out="$BATS_TEST_TMPDIR/watch-out.bin"
    # 'timeout 20' guards against a --watch that doesn't honor
    # FLEET_MAX_TICKS looping forever and hanging the whole suite -- a
    # correct implementation exits well inside this (~3s: one
    # REFRESH_INTERVAL_S sleep between 2 ticks).
    run timeout 20 bash -c "cd '$ROOT' && env -u TMUX FLEET_MAX_TICKS=2 '$FLEET' --watch > '$out'"
    [ "$status" -eq 0 ]

    run python3 - "$out" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read().decode()
ESC = '\x1b'
assert ESC + '[2J' not in data, "found ESC[2J (a clear sequence)"
assert ESC + '[3J' not in data, "found ESC[3J (a clear sequence)"
frames = data.split(ESC + '[H')
assert frames[0] == '', "unexpected data before the first ESC[H: %r" % frames[0]
frames = frames[1:]
assert len(frames) == 2, "expected exactly 2 frames, got %d" % len(frames)
for f in frames:
    assert f.endswith(ESC + '[J'), "frame doesn't end with ESC[J: %r" % f
    body = f[:-len(ESC + '[J')]
    lines = body.split('\n')
    assert lines[-1] == '', "frame body doesn't end with a newline before ESC[J: %r" % lines[-1]
    for line in lines[:-1]:
        assert line.endswith(ESC + '[K'), "line missing trailing ESC[K: %r" % line
print("watch-frames-ok")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"watch-frames-ok"* ]]
}

@test "fleet nav screenshots: sidebar table with a window row, and the post-go pane layout (take-screenshot term)" {
    setup_fleet_fixture
    tmux -L "$TMUX_SOCK" new-window -n extrawin -c "$BATS_TEST_TMPDIR" -t base
    tmux -L "$TMUX_SOCK" select-window -t base:mainwin

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle
    [ "$status" -eq 0 ]
    sleep 1

    local sidebar_pane
    sidebar_pane="$(tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{@fleet_sidebar}' | awk '$2=="1"{print $1}')"
    [ -n "$sidebar_pane" ]

    local cap1="$BATS_TEST_TMPDIR/nav-rows-capture.txt"
    tmux -L "$TMUX_SOCK" capture-pane -pJ -t "$sidebar_pane" > "$cap1"
    run grep -F 'extra' "$cap1"
    [ "$status" -eq 0 ]

    local png1="/workspace/attachments/fleet-vyzk-rows-$$.png"
    rm -f "$png1"
    capture_with_retry "$png1" "cat $cap1"
    [ -f "$png1" ]
    [ "$(wc -c < "$png1")" -ge 20000 ]

    run env -u TMUX TMUX="$FAKE_TMUX" bash -c "cd '$ROOT' && exec '$FLEET' go wa"
    [ "$status" -eq 0 ]

    local cap2="$BATS_TEST_TMPDIR/nav-post-go-panes.txt"
    tmux -L "$TMUX_SOCK" list-panes -a -F '#{window_name} #{pane_id} #{pane_active} #{pane_width} #{@fleet_sidebar}' > "$cap2"

    local png2="/workspace/attachments/fleet-vyzk-postgo-$$.png"
    rm -f "$png2"
    capture_with_retry "$png2" "cat $cap2"
    [ -f "$png2" ]
    [ "$(wc -c < "$png2")" -ge 20000 ]

    echo "fleet nav screenshots: rows=$png1 post-go=$png2"
}

# ── fleet rows: window_claimed_by_worktree (beads_claude_docker-bj6x) ─────
# Added alongside the sidebar-interaction slice below: emit_rows() used to
# decide "is this tmux window already covered by a worktree row" via
# window_is_represented() -- ANY pane in the window matching a worktree's
# path, checked across every pane of that window. That swallowed a SECOND
# window sharing a worktree's path (a Hide-parked pane, a plain shell
# window opened at the main tree) into the first window's own row, making
# the second one unreachable from the sidebar once the status bar (which
# used to list windows) is gone. Fixed by narrowing the test to "is this
# window pane_for_path()'s own CHOSEN representative for that worktree
# row" (window_claimed_by_worktree()) -- a second window at the same path
# now gets its own window row instead of vanishing. Existing fixture
# counts elsewhere in this file are untouched: none of them puts a SECOND
# window at a path a worktree row already claims (setup_fleet_fixture's
# mainwin/wawin/wcwin, and the rows test's extrawin/gitwin, are each at a
# distinct path), so this narrowing changes zero pre-existing row counts.
@test "fleet rows: a second window sharing a worktree's path gets its own window row instead of vanishing" {
    setup_fleet_fixture
    # mainwin (created by start_scratch_tmux) is already pane_for_path()'s
    # chosen representative for ROOT's own worktree row. A second window
    # at the SAME path (ROOT) must not be absorbed into that row.
    tmux -L "$TMUX_SOCK" new-window -n mainwin2 -c "$ROOT" -t base
    tmux -L "$TMUX_SOCK" select-window -t base:mainwin

    run env -u TMUX TMUX="$FAKE_TMUX" CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" LANE_STATE_DIR="$LANE_STATE_DIR" \
        bash -c "cd '$ROOT' && exec '$FLEET' rows"
    [ "$status" -eq 0 ]
    local rows
    rows="$output"
    [ "$(printf '%s\n' "$rows" | grep -c .)" -eq 5 ]

    local row5
    row5="$(printf '%s\n' "$rows" | sed -n 5p)"
    [ "$(printf '%s' "$row5" | cut -f2)" = "window" ]
    [ "$(printf '%s' "$row5" | cut -f3)" = "mainwin2" ]
    run bash -c "cd '$ROOT' && pwd -P"
    [ "$(printf '%s' "$row5" | cut -f4)" = "$output" ]
}

# ── fleet sidebar interaction: cursor, keys, mouse, footer ────────────────
# Added for beads_claude_docker-bj6x (G3 of .claude/plans/fleet-nav.md):
# on a real tty (the sidebar pane 'fleet toggle' opens IS one, attached or
# not -- tmux always allocates a pty for a pane), cmd_watch puts the
# terminal in raw mode with SGR mouse tracking on and runs an interactive
# loop: a cursor row (tracked by row identity across refreshes), keyboard
# (Up/k, Down/j, Enter, n, r, q) and mouse (wheel, left-click) navigation,
# and a footer of key hints. Off a tty (every existing --watch test above
# that redirects stdout, confirmed empirically to run with a non-tty
# stdin in this container: `bash -c '[ -t 0 ] && ... || ...'` prints "NOT
# a tty" here) the ORIGINAL dumb redraw loop still runs unchanged, with no
# terminal control sequence beyond the frame itself -- FROZEN alongside
# the rest of this file per this bead's own acceptance contract from its
# RED commit onward.
#
# Key delivery confirmed empirically (not assumed) against a real scratch
# tmux pane running a raw-mode byte reader before writing the assertions
# below: 'tmux send-keys ... Down' / 'Up' arrive as the plain CSI
# sequences ESC[B / ESC[A (not the SS3 ESC O B/A an application-cursor-mode
# terminal would use), 'Enter' arrives as a bare CR (\r), and
# 'send-keys -l' of a literal SGR mouse sequence arrives byte-for-byte
# unchanged.

# capture_sidebar <capture-file-base> <pane> — capture-pane -e (raw, for
# the eventual PNG's `cat`) into <capture-file-base>, plus a `cat -v`
# ESC-visualized twin at <capture-file-base>.vis (ESC becomes the two
# characters "^[") so the greps below never have to embed a raw control
# byte in this source file to find e.g. the reverse-video marker ESC[7m.
capture_sidebar() {
    tmux -L "$TMUX_SOCK" capture-pane -e -p -t "$2" > "$1"
    cat -v "$1" > "$1.vis"
}

# sidebar_cursor_on <capture-file-base> <pane> <needle> — true once a
# FRESH capture's lone ESC[7m-marked line contains <needle>; false (and
# leaves a fresh capture behind either way) otherwise. Used as a wait_for
# condition so the test polls for the redraw to actually land instead of
# racing a fixed sleep against the sidebar's own input-driven redraw.
sidebar_cursor_on() {
    capture_sidebar "$1" "$2"
    grep -qF '^[[7m' "$1.vis" || return 1
    grep -F '^[[7m' "$1.vis" | grep -q -- "$3"
}

# sidebar_gone <socket> — true once no @fleet_sidebar=1 pane remains
# anywhere on <socket>'s server.
sidebar_gone() {
    local n
    n="$(tmux -L "$1" list-panes -a -F '#{@fleet_sidebar}' 2>/dev/null | grep -c '^1$')"
    [ "$n" -eq 0 ]
}

@test "fleet sidebar: Down moves the cursor to the second row; capture-pane -e shows exactly one reverse-video row and the key-hint footer" {
    setup_fleet_fixture

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle
    [ "$status" -eq 0 ]
    local sidebar_pane
    sidebar_pane="$(tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{@fleet_sidebar}' | awk '$2=="1"{print $1}')"
    [ -n "$sidebar_pane" ]

    # let the first frame render (raw tty mode entered, initial redraw
    # done) before driving input.
    sleep 1

    local cap="$BATS_TEST_TMPDIR/cursor-down.txt"
    tmux -L "$TMUX_SOCK" send-keys -t "$sidebar_pane" Down
    wait_for 25 sidebar_cursor_on "$cap" "$sidebar_pane" wa

    # exactly one reverse-video row.
    local n7m
    n7m="$(grep -cF '^[[7m' "$cap.vis")"
    [ "$n7m" -eq 1 ]

    # the reverse-video row is the SECOND row (worktree wa, per
    # setup_fleet_fixture's main/wa/wb/wc ordering), not the first (main).
    local hl_line
    hl_line="$(grep -F '^[[7m' "$cap.vis")"
    [[ "$hl_line" == *"wa"* ]]
    [[ "$hl_line" != *"main"* ]]

    # footer line: key hints, contains go/new/close.
    run grep -F 'Enter:go n:new r:refresh q:close' "$cap"
    [ "$status" -eq 0 ]

    local png="/workspace/attachments/fleet-bj6x-cursor-$$.png"
    rm -f "$png"
    capture_with_retry "$png" "cat $cap"
    [ -f "$png" ]
    [ "$(wc -c < "$png")" -ge 20000 ]
    echo "fleet sidebar cursor screenshot: $png"
}

@test "fleet sidebar: Down then Enter jumps to the second row's window, sidebar alongside, its pane active" {
    setup_fleet_fixture

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle
    [ "$status" -eq 0 ]
    local sidebar_pane
    sidebar_pane="$(tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{@fleet_sidebar}' | awk '$2=="1"{print $1}')"
    [ -n "$sidebar_pane" ]
    local wa_pane
    wa_pane="$(tmux -L "$TMUX_SOCK" list-panes -t base:wawin -F '#{pane_id}')"
    [ -n "$wa_pane" ]

    sleep 1
    local cap="$BATS_TEST_TMPDIR/downenter.txt"
    tmux -L "$TMUX_SOCK" send-keys -t "$sidebar_pane" Down
    wait_for 25 sidebar_cursor_on "$cap" "$sidebar_pane" wa

    tmux -L "$TMUX_SOCK" send-keys -t "$sidebar_pane" Enter
    wait_for 25 bash -c "[ \"\$(tmux -L '$TMUX_SOCK' display -p -t '$sidebar_pane' '#{window_name}')\" = wawin ]"

    run tmux -L "$TMUX_SOCK" display -p -t "$sidebar_pane" '#{window_name}'
    [ "$output" = "wawin" ]
    run tmux -L "$TMUX_SOCK" list-panes -t base:wawin -F '#{pane_active} #{pane_id}'
    [[ "$output" == *"1 $wa_pane"* ]]
}

@test "fleet sidebar: SGR left-click on the third row's line opens/jumps to that row's window" {
    export CS_NEW_LAUNCH='sleep 47'
    setup_fleet_fixture

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle
    [ "$status" -eq 0 ]
    local sidebar_pane
    sidebar_pane="$(tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{@fleet_sidebar}' | awk '$2=="1"{print $1}')"
    [ -n "$sidebar_pane" ]

    sleep 1
    # header is line 1, first row (main) line 2, second row (wa) line 3,
    # third row (wb) line 4 -- no scroll (4 rows, well under body_height).
    # wb has NO tmux window in this fixture, so the click exercises the
    # "open a session in a worktree with none yet" branch of go_to_row().
    tmux -L "$TMUX_SOCK" send-keys -t "$sidebar_pane" -l $'\e[<0;2;4M'
    tmux -L "$TMUX_SOCK" send-keys -t "$sidebar_pane" -l $'\e[<0;2;4m'

    wait_for 50 bash -c "tmux -L '$TMUX_SOCK' list-windows -F '#{window_name}' | grep -qx wb"
    wait_for 25 bash -c "[ \"\$(tmux -L '$TMUX_SOCK' display -p -t '$sidebar_pane' '#{window_name}')\" = wb ]"

    run tmux -L "$TMUX_SOCK" list-windows -F '#{window_name} #{pane_current_path}'
    [[ "$output" == *"wb $WB"* ]]
    run tmux -L "$TMUX_SOCK" display -p -t "$sidebar_pane" '#{window_name}'
    [ "$output" = "wb" ]
}

@test "fleet sidebar: 'n' creates a new worktree session under .claude/worktrees/, with a window and the sidebar following" {
    export CS_NEW_LAUNCH="env > '$BATS_TEST_TMPDIR/new-env.txt'; sleep 47"
    setup_fleet_fixture

    local before
    before=("$ROOT"/.claude/worktrees/*)

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle
    [ "$status" -eq 0 ]
    local sidebar_pane
    sidebar_pane="$(tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{@fleet_sidebar}' | awk '$2=="1"{print $1}')"
    [ -n "$sidebar_pane" ]

    sleep 1
    tmux -L "$TMUX_SOCK" send-keys -t "$sidebar_pane" n

    wait_for 50 bash -c "[ -s '$BATS_TEST_TMPDIR/new-env.txt' ]"
    run grep -x "BEADS_DIR=$ROOT/.beads" "$BATS_TEST_TMPDIR/new-env.txt"
    [ "$status" -eq 0 ]

    local after new_name before_names after_names
    after=("$ROOT"/.claude/worktrees/*)
    [ "${#after[@]}" -eq $((${#before[@]} + 1)) ]
    before_names="$(printf '%s\n' "${before[@]##*/}" | sort)"
    after_names="$(printf '%s\n' "${after[@]##*/}" | sort)"
    new_name="$(comm -13 <(printf '%s\n' "$before_names") <(printf '%s\n' "$after_names"))"
    [ -n "$new_name" ]
    [ "$(printf '%s\n' "$new_name" | grep -c .)" -eq 1 ]

    local win_output
    win_output="$(tmux -L "$TMUX_SOCK" list-windows -F '#{window_name}')"
    run grep -qx "$new_name" <<<"$win_output"
    [ "$status" -eq 0 ]

    wait_for 25 bash -c "[ \"\$(tmux -L '$TMUX_SOCK' display -p -t '$sidebar_pane' '#{window_name}')\" = '$new_name' ]"
    run tmux -L "$TMUX_SOCK" display -p -t "$sidebar_pane" '#{window_name}'
    [ "$output" = "$new_name" ]
}

@test "fleet sidebar: 'q' restores the tty and closes the pane -- no @fleet_sidebar pane remains" {
    ROOT="$(new_scratch_repo repo)"
    start_scratch_tmux "$ROOT" 120 35
    FAKE_TMUX="$(fake_tmux_env "$TMUX_SOCK")"

    run env -u TMUX TMUX="$FAKE_TMUX" "$FLEET" toggle
    [ "$status" -eq 0 ]
    local sidebar_pane
    sidebar_pane="$(tmux -L "$TMUX_SOCK" list-panes -a -F '#{pane_id} #{@fleet_sidebar}' | awk '$2=="1"{print $1}')"
    [ -n "$sidebar_pane" ]

    sleep 1
    tmux -L "$TMUX_SOCK" send-keys -t "$sidebar_pane" q
    wait_for 25 sidebar_gone "$TMUX_SOCK"

    run bash -c "tmux -L '$TMUX_SOCK' list-panes -a -F '#{@fleet_sidebar}' | grep -c '^1\$'"
    [ "$output" -eq 0 ]
}
