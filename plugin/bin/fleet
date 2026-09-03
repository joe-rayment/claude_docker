#!/usr/bin/env bash
# fleet — live worktree/session/agent table for the worktree-session fleet.
# 'fleet --once' prints one row per worktree of the repo containing cwd
# (main tree first); 'fleet --watch' redraws it every 3s until killed;
# 'fleet toggle [pane_id]' opens a 34-column sidebar pane running the
# watch loop, or closes it if one is already open in that window. See
# .claude/plans/worktree-sessions.md and beads_claude_docker-1tym.
#
# Columns: window (the tmux pane whose current path is that worktree, '-'
# if none) · branch · dirty count (git status --porcelain line count) ·
# ahead/behind main (git rev-list --left-right --count, '-' for main
# itself) · lane · live agents · last-activity age. A dim/plain header row
# ('win branch +- a/b lane ag age') prints first so the fields are
# self-describing. Column budget: 34, matching the sidebar pane width
# `fleet toggle` opens -- enforced by giving window/branch a genuinely
# FIXED width (WINDOW_MAX / BRANCH_MAX, padded via pad_trunc() when
# shorter, truncated with a trailing '+' marker when longer) so branch
# always starts at the same offset regardless of a row's actual content;
# every other field is bounded by its own small vocabulary (lane collapses
# to a single letter in the table itself, same convention as the
# executor/scout/verifier role letters below -- the full word is still
# what LANE_STATE_DIR's json carries, only the compact table abbreviates
# it; agents: small counts, age: short units) and is left unpadded by
# design: there is not enough of a 34-column budget left, once window,
# branch, and a live-agent row's leading marker are accounted for, to also
# fix-width dirty/ahead-behind/lane/agents/age without either crushing
# window/branch to a couple of characters or dropping information
# (role letters, dirty counts) outright -- so only the two fields whose
# job IS identification (window, branch) get the fixed-width treatment
# the offset guarantee actually needs.
#
# Rows whose live-agent count is > 0 carry a leading '*' marker (a plain
# ' ' otherwise) so "someone is working there" is visible without reading
# the agents column.
#
# Lane and live-agent data come from Claude's own transcript layout, not
# this repo's: project dir = $CLAUDE_PROJECTS_DIR/<slug> (default
# ~/.claude/projects), slug = the worktree's absolute path with every
# character that is not [A-Za-z0-9] replaced by '-'. Confirmed
# empirically against live sessions (not just the plan doc's own
# example): a probe session opened at /tmp/fleetprobe/aaa/.claude/worktrees/bbb
# produced project dir -tmp-fleetprobe-aaa--claude-worktrees-bbb (note the
# DOUBLE dash where '/' meets '.', i.e. '.' is replaced too, not just
# '/'), and a second probe with underscores in both path components
# (.../a_b/.claude/worktrees/c_d) produced .../a-b--claude-worktrees-c-d,
# confirming '_' is replaced too, not preserved. The newest *.jsonl
# directly under that project dir is the worktree's
# session; its basename (sans .jsonl) is the session id and its mtime is
# the last-activity age. Lane: $LANE_STATE_DIR/<session id>.json's .lane
# field (default ~/.claude/cache/lane), '-' if absent/unreadable. Live
# agents: files under <project dir>/<session id>/subagents/agent-*.meta.json
# whose SIBLING .jsonl mtime is under LIVE_AGENT_WINDOW_S seconds old --
# role per agent is each meta.json's .customAgentType, falling back to
# .agentType (the same precedence scripts/cost-mirror.py's _agent_label
# already uses: a NAMED spawn puts the display name in agentType and the
# true role in customAgentType), mapped to a single letter: executor->e,
# scout->s, verifier->v, anything else -> its own first character.
#
# MUST fail open: a missing jq, a missing/unreadable project dir, a
# detached-HEAD worktree, or any single git/tmux failure degrades that one
# field to '-' (or "0" for agents) rather than aborting the whole table --
# deliberately NOT using `set -e` (unlike fleet-menu.sh) because a table
# row is built from ~7 small, independently-fallible lookups per
# worktree; every helper below is written to always return 0 and print a
# safe default on internal failure, so a single unexpected non-zero
# degrades one field instead of aborting mid-table.
set -uo pipefail

err() { printf 'fleet: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

TAB=$'\t'
BASE_BRANCH="main"
# WINDOW_MAX / BRANCH_MAX: fixed display width of the window/branch
# columns (see pad_trunc()) -- shrunk from the pre-header 8/10 so a padded
# (not just truncated) window+branch prefix still leaves room for the
# dirty/ahead-behind/lane/agents/age fields within SIDEBAR_WIDTH; see the
# header comment above for the full budget rationale.
WINDOW_MAX=6
BRANCH_MAX=6
SIDEBAR_WIDTH=34
REFRESH_INTERVAL_S=3
LIVE_AGENT_WINDOW_S=120

# SELF — this script's own absolute path, used by `toggle` to launch the
# watch loop by exact path rather than a bare `fleet` that may not be on
# PATH (e.g. under test, or in a container that hasn't re-synced /usr/local/bin
# since the last image build). Falls back to the raw BASH_SOURCE value if
# readlink is unavailable, which is still correct for every real
# invocation (always run by an absolute or resolvable path, never sourced).
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"

# CS_NEW_BIN — the cs-new launcher 'fleet go' delegates to for a worktree
# with no window yet: prefers the exact sibling next to THIS copy of
# fleet.sh (scripts/cs-new.sh in a checkout, cs-new alongside an
# installed/staged fleet) over a bare PATH lookup -- the same gap SELF's
# own comment documents, but inverted on purpose: a test running the
# edited source checkout must never shell out to a stale
# /usr/local/bin/cs-new left over from before the last image sync, while
# in a real deployment the sibling IS the installed/staged copy anyway
# (same file, same result either way). Falls back to PATH's cs-new only
# if no sibling script is found next to SELF.
if [ -f "$(dirname "$SELF")/cs-new.sh" ]; then
    CS_NEW_BIN="$(dirname "$SELF")/cs-new.sh"
elif [ -f "$(dirname "$SELF")/cs-new" ]; then
    CS_NEW_BIN="$(dirname "$SELF")/cs-new"
else
    CS_NEW_BIN="cs-new"
fi

usage() {
    cat <<'EOF'
Usage: fleet --once | --watch | rows | go <name|path|@window> | follow | toggle [pane_id]

--once     Print one row per worktree of the repo containing cwd (main
           tree first), then one row per tmux window not represented by
           a worktree row: window, branch, dirty count, ahead/behind
           main, lane, live agents, last-activity age. Outside a git
           repo: prints a one-line notice and exits 0.
--watch    Like --once, redrawing every 3s until killed: each frame is
           one buffered write (no flicker), and 'fleet follow' runs once
           per tick. FLEET_MAX_TICKS=<n> stops the loop after <n> frames
           (for tests).
rows       Machine-readable rows behind --once/--watch/go, one per line:
           <display><TAB><kind><TAB><name><TAB><path><TAB><window_id><TAB><pane_id>
           (kind is worktree or window; a row's own display text is
           identical to its 'fleet --once' line).
go <name|path|@window>
           Move the server-wide fleet sidebar into the row matching
           <name|path|@window> (matched against rows' name/path/window_id
           columns) and select its pane. A worktree row with no window
           yet is opened first via 'cs-new --open <name>', then followed.
follow     If the fleet sidebar exists and is not in the ambient current
           window, move it there (join-pane, detached focus). No-op
           otherwise.
toggle [pane_id]
           Server-wide: if the fleet sidebar is already in the target
           window (pane_id's window, or the ambient current window),
           close it. If it exists elsewhere on the server, move it here
           instead of opening a second one. If none exists anywhere,
           split a 34-column pane to the left running 'fleet --watch',
           keeping focus on the original pane. pane_id defaults to the
           ambient current pane ($TMUX).

Env:
  CLAUDE_PROJECTS_DIR   overrides ~/.claude/projects (session transcripts)
  LANE_STATE_DIR        overrides ~/.claude/cache/lane (lane state)
  FLEET_MAX_TICKS       stop --watch after this many frames (for tests)
EOF
}

# pad_trunc <string> <width> — <string> forced to EXACTLY <width>
# characters: left-justified and space-padded if shorter or equal,
# truncated to its first <width>-1 characters plus a trailing '+' marker
# if longer. Unlike the old trunc() (cut-if-longer, otherwise unchanged
# length), this always returns exactly <width> chars -- the guarantee
# print_table's header/branch column-offset alignment depends on.
pad_trunc() {
    local s="$1" n="$2"
    if [ "${#s}" -gt "$n" ]; then
        printf '%s+' "${s:0:$((n - 1))}"
    else
        printf '%-*s' "$n" "$s"
    fi
}

# role_letter <role> — single-letter summary of an agent role: the
# customAgentType/agentType value from its sidecar meta.json.
role_letter() {
    case "$1" in
        executor) printf 'e' ;;
        scout) printf 's' ;;
        verifier) printf 'v' ;;
        *) printf '%s' "${1:0:1}" ;;
    esac
}

# lane_letter <lane> — single-letter code for the compact table's lane
# column, the same abbreviation convention role_letter() already uses for
# agent roles: express->e, standard->s, deep->d, anything else (including
# '-', the "no session" case) -> '-'. The full lane word is still what
# lane_for_session() returns and what LANE_STATE_DIR's json carries; only
# the table display is abbreviated, to fit SIDEBAR_WIDTH (see the file
# header comment).
lane_letter() {
    case "$1" in
        express) printf 'e' ;;
        standard) printf 's' ;;
        deep) printf 'd' ;;
        *) printf -- '-' ;;
    esac
}

# slug_for_path <abs-path> — the ~/.claude/projects/<slug> directory name
# for <abs-path>: every character that is not [A-Za-z0-9] becomes '-' (see
# the header comment for the empirical confirmation that '.' and '_' are
# included, not just '/' -- an existing '-' passes through unchanged
# either way, since replacing '-' with '-' is a no-op).
slug_for_path() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

projects_root() {
    printf '%s\n' "${CLAUDE_PROJECTS_DIR:-${HOME:-}/.claude/projects}"
}

lane_state_root() {
    printf '%s\n' "${LANE_STATE_DIR:-${HOME:-}/.claude/cache/lane}"
}

# session_context <abs-path> — "<project_dir><TAB><session_id><TAB><mtime>"
# for <abs-path>'s newest top-level session transcript, or nothing (empty
# output, still exit 0) if there is no project dir or no *.jsonl in it.
session_context() {
    local path="$1" slug pdir jsonl sid mtime
    slug="$(slug_for_path "$path")"
    pdir="$(projects_root)/$slug"
    jsonl="$(ls -t "$pdir"/*.jsonl 2>/dev/null | head -n1)"
    [ -n "$jsonl" ] || return 0
    sid="$(basename "$jsonl" .jsonl)"
    mtime="$(stat -c %Y "$jsonl" 2>/dev/null)" || return 0
    [ -n "$mtime" ] || return 0
    printf '%s\t%s\t%s\n' "$pdir" "$sid" "$mtime"
}

# lane_for_session <session-id> — the .lane field of
# $LANE_STATE_DIR/<session-id>.json, or '-' if the file, jq, or the field
# itself is missing.
lane_for_session() {
    local sid="$1" lfile lane=""
    lfile="$(lane_state_root)/$sid.json"
    if [ -f "$lfile" ] && command -v jq >/dev/null 2>&1; then
        lane="$(jq -r '.lane // empty' "$lfile" 2>/dev/null)"
    fi
    [ -n "$lane" ] || lane="-"
    printf '%s' "$lane"
}

# agents_for_session <project-dir> <session-id> — "0" if no agent sidecar
# under <project-dir>/<session-id>/subagents/agent-*.meta.json has a
# sibling .jsonl newer than LIVE_AGENT_WINDOW_S seconds ago, else
# "<count> <role letters>" (one letter per live agent, comma-joined, in
# meta.json filename order).
agents_for_session() {
    local pdir="$1" sid="$2" subdir count=0 roles="" meta jsonl role letter mt now
    subdir="$pdir/$sid/subagents"
    [ -d "$subdir" ] || { printf '0'; return 0; }
    command -v jq >/dev/null 2>&1 || { printf '0'; return 0; }
    now="$(date +%s)"
    while IFS= read -r meta; do
        [ -n "$meta" ] || continue
        jsonl="${meta%.meta.json}.jsonl"
        [ -f "$jsonl" ] || continue
        mt="$(stat -c %Y "$jsonl" 2>/dev/null)" || continue
        [ -n "$mt" ] || continue
        [ $((now - mt)) -lt "$LIVE_AGENT_WINDOW_S" ] || continue
        role="$(jq -r '.customAgentType // .agentType // empty' "$meta" 2>/dev/null)"
        [ -n "$role" ] || role="?"
        letter="$(role_letter "$role")"
        count=$((count + 1))
        if [ -n "$roles" ]; then
            roles="$roles,$letter"
        else
            roles="$letter"
        fi
    done < <(find "$subdir" -maxdepth 1 -name 'agent-*.meta.json' 2>/dev/null | sort)
    if [ "$count" -eq 0 ]; then
        printf '0'
    else
        printf '%s %s' "$count" "$roles"
    fi
}

# age_for_mtime <epoch-seconds> — the age of <epoch-seconds> relative to
# now, as a short unit: "<n>s" / "<n>m" / "<n>h" / "<n>d". '-' if empty.
age_for_mtime() {
    local mtime="${1:-}" now delta
    [ -n "$mtime" ] || { printf -- '-'; return 0; }
    now="$(date +%s)"
    delta=$((now - mtime))
    [ "$delta" -ge 0 ] || delta=0
    if [ "$delta" -lt 60 ]; then
        printf '%ds' "$delta"
    elif [ "$delta" -lt 3600 ]; then
        printf '%dm' "$((delta / 60))"
    elif [ "$delta" -lt 86400 ]; then
        printf '%dh' "$((delta / 3600))"
    else
        printf '%dd' "$((delta / 86400))"
    fi
}

# dirty_count <worktree-path> — `git status --porcelain` line count, 0 on
# any git failure.
dirty_count() {
    local path="$1" n
    n="$(git -C "$path" status --porcelain 2>/dev/null | wc -l)"
    n="$(printf '%s' "$n" | tr -d '[:space:]')"
    [ -n "$n" ] || n=0
    printf '%s' "$n"
}

# ahead_behind <root> <branch> — "<ahead>/<behind>" of <branch> against
# BASE_BRANCH via `git rev-list --left-right --count`; '-' for
# BASE_BRANCH itself or on any git failure.
ahead_behind() {
    local root="$1" branch="$2" out behind ahead
    if [ "$branch" = "$BASE_BRANCH" ]; then
        printf -- '-'
        return 0
    fi
    out="$(git -C "$root" rev-list --left-right --count "$BASE_BRANCH...$branch" 2>/dev/null)"
    if [ -z "$out" ]; then
        printf -- '-'
        return 0
    fi
    behind="$(printf '%s' "$out" | awk '{print $1}')"
    ahead="$(printf '%s' "$out" | awk '{print $2}')"
    [ -n "$behind" ] && [ -n "$ahead" ] || { printf -- '-'; return 0; }
    printf '%s/%s' "$ahead" "$behind"
}

# window_for <worktree-path> — the #{window_name} of a tmux pane (on the
# ambient $TMUX server, across every session/window) whose current path
# resolves to <worktree-path>; '-' if outside tmux, tmux is unavailable,
# or no pane matches.
window_for() {
    local path="$1" resolved pane_path wname rp
    [ -n "${TMUX:-}" ] || { printf -- '-'; return 0; }
    command -v tmux >/dev/null 2>&1 || { printf -- '-'; return 0; }
    resolved="$(cd "$path" 2>/dev/null && pwd -P)" || resolved="$path"
    while IFS="$TAB" read -r pane_path wname; do
        [ -n "$pane_path" ] || continue
        rp="$(cd "$pane_path" 2>/dev/null && pwd -P)" || rp="$pane_path"
        if [ "$rp" = "$resolved" ]; then
            printf '%s' "$wname"
            return 0
        fi
    done < <(tmux list-panes -a -F "#{pane_current_path}${TAB}#{window_name}" 2>/dev/null)
    printf -- '-'
}

# find_sidebar_pane — the #{pane_id} of the single server-wide
# @fleet_sidebar=1 pane, or nothing (still exit 0) if there is none, tmux
# is unavailable, or we're outside tmux.
find_sidebar_pane() {
    [ -n "${TMUX:-}" ] || return 0
    command -v tmux >/dev/null 2>&1 || return 0
    tmux list-panes -a -F "#{pane_id}${TAB}#{@fleet_sidebar}" 2>/dev/null | awk -F"$TAB" '$2=="1"{print $1; exit}'
}

# pane_for_path <path> — "<window_id><TAB><pane_id>" of the best tmux
# pane server-wide whose current path resolves to <path> (same
# cd+pwd -P resolution as window_for()): prefers a pane with
# #{pane_current_command} == claude, else the first match in
# `list-panes -a` order; the sidebar's own pane (@fleet_sidebar=1) is
# never a candidate, since it is never the thing 'go'/toggle navigate TO.
# Empty (still exit 0) if no pane matches.
pane_for_path() {
    local path="$1" resolved pid wid pane_path cmd sidebar_flag rp
    local best_pid="" best_wid="" fb_pid="" fb_wid=""
    [ -n "${TMUX:-}" ] || return 0
    command -v tmux >/dev/null 2>&1 || return 0
    resolved="$(cd "$path" 2>/dev/null && pwd -P)" || resolved="$path"
    while IFS="$TAB" read -r pid wid pane_path cmd sidebar_flag; do
        [ -n "$pid" ] || continue
        [ "$sidebar_flag" = "1" ] && continue
        rp="$(cd "$pane_path" 2>/dev/null && pwd -P)" || rp="$pane_path"
        [ "$rp" = "$resolved" ] || continue
        if [ "$cmd" = "claude" ]; then
            best_pid="$pid"
            best_wid="$wid"
            break
        fi
        if [ -z "$fb_pid" ]; then
            fb_pid="$pid"
            fb_wid="$wid"
        fi
    done < <(tmux list-panes -a -F "#{pane_id}${TAB}#{window_id}${TAB}#{pane_current_path}${TAB}#{pane_current_command}${TAB}#{@fleet_sidebar}" 2>/dev/null)
    if [ -n "$best_pid" ]; then
        printf '%s\t%s\n' "$best_wid" "$best_pid"
    elif [ -n "$fb_pid" ]; then
        printf '%s\t%s\n' "$fb_wid" "$fb_pid"
    fi
}

# all_window_ids — "<session>\t<index>\t<window_id>" for every tmux window
# on the ambient server, sorted by session name then window index (tmux's
# own `list-windows -a` order already matches this -- confirmed
# empirically, not assumed -- the explicit sort just makes it a stated
# guarantee rather than an incidental one).
all_window_ids() {
    tmux list-windows -a -F "#{session_name}${TAB}#{window_index}${TAB}#{window_id}" 2>/dev/null | sort -t "$TAB" -k1,1 -k2,2n
}

# window_repr_pane <window_id> — "<path><TAB><pane_id>" of a representative
# pane in <window_id> for display/navigation purposes: the first
# non-sidebar pane (pane order), falling back to the sidebar pane itself
# only if that's the window's sole occupant. Empty if the window has no
# panes at all (shouldn't happen, but tmux queries fail open here too).
window_repr_pane() {
    local wid="$1" path pid sidebar_flag fb_pid="" fb_path=""
    while IFS="$TAB" read -r path pid sidebar_flag; do
        [ -n "$pid" ] || continue
        if [ "$sidebar_flag" != "1" ]; then
            printf '%s\t%s\n' "$path" "$pid"
            return 0
        fi
        [ -z "$fb_pid" ] && { fb_pid="$pid"; fb_path="$path"; }
    done < <(tmux list-panes -t "$wid" -F "#{pane_current_path}${TAB}#{pane_id}${TAB}#{@fleet_sidebar}" 2>/dev/null)
    [ -n "$fb_pid" ] && printf '%s\t%s\n' "$fb_path" "$fb_pid"
}

# window_is_represented <window_id> <resolved-worktree-paths> — 0 if ANY
# pane in <window_id> (sidebar included) resolves (cd+pwd -P) to one of
# the newline-separated, already-resolved paths in
# <resolved-worktree-paths>; 1 otherwise. Deliberately checks every pane,
# not just window_repr_pane()'s single representative one: after a 'go'
# or 'follow' joins the sidebar into a worktree's own window, that
# window's non-sidebar pane is still the worktree match regardless of
# which pane window_repr_pane() would have picked first.
window_is_represented() {
    local wid="$1" resolved_list="$2" path rp
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        rp="$(cd "$path" 2>/dev/null && pwd -P)" || rp="$path"
        if printf '%s' "$resolved_list" | grep -qxF "$rp"; then
            return 0
        fi
    done < <(tmux list-panes -t "$wid" -F '#{pane_current_path}' 2>/dev/null)
    return 1
}

# goto_pane <window_id> <pane_id> — move the server-wide fleet sidebar
# into <window_id> (join-pane, anchored on <pane_id>, detached focus) if
# it exists and is elsewhere; no-op on the move if it's already in
# <window_id>, or if there is no sidebar at all. Always finishes by
# making <window_id>/<pane_id> the active window/pane.
goto_pane() {
    local wid="$1" pid="$2" sidebar_pane sidebar_window
    sidebar_pane="$(find_sidebar_pane)"
    if [ -n "$sidebar_pane" ]; then
        sidebar_window="$(tmux display -p -t "$sidebar_pane" '#{window_id}' 2>/dev/null)" || sidebar_window=""
        if [ "$sidebar_window" != "$wid" ]; then
            tmux join-pane -d -hb -l "$SIDEBAR_WIDTH" -s "$sidebar_pane" -t "$pid" 2>/dev/null || true
            tmux set-option -p -t "$sidebar_pane" @fleet_sidebar 1 2>/dev/null || true
        fi
    fi
    tmux select-window -t "$wid" 2>/dev/null || true
    tmux select-pane -t "$pid" 2>/dev/null || true
}

# do_follow — the shared implementation behind 'fleet follow' and each
# --watch tick: if the sidebar pane exists and is not in the ambient
# current window, join it there (detached focus, anchored on a
# non-sidebar pane of that window); no-op (still exit 0) if there is no
# sidebar, we're outside tmux, or it is already in the current window.
do_follow() {
    local sidebar_pane cur_window sidebar_window anchor
    [ -n "${TMUX:-}" ] || return 0
    command -v tmux >/dev/null 2>&1 || return 0
    sidebar_pane="$(find_sidebar_pane)"
    [ -n "$sidebar_pane" ] || return 0
    cur_window="$(tmux display -p '#{window_id}' 2>/dev/null)" || return 0
    sidebar_window="$(tmux display -p -t "$sidebar_pane" '#{window_id}' 2>/dev/null)" || return 0
    [ "$sidebar_window" != "$cur_window" ] || return 0
    anchor="$(tmux list-panes -t "$cur_window" -F "#{pane_id}${TAB}#{@fleet_sidebar}" 2>/dev/null | awk -F"$TAB" '$2!="1"{print $1; exit}')"
    [ -n "$anchor" ] || return 0
    tmux join-pane -d -hb -l "$SIDEBAR_WIDTH" -s "$sidebar_pane" -t "$anchor" 2>/dev/null || return 0
    tmux set-option -p -t "$sidebar_pane" @fleet_sidebar 1 2>/dev/null || true
}

# list_worktrees_with_branch <root> — one line per `git worktree list
# --porcelain` entry (main worktree first, git's own ordering) as
# "<path><TAB><branch>"; detached-HEAD worktrees show branch "-".
list_worktrees_with_branch() {
    local root="$1" wt_path="" wt_branch=""
    flush() {
        if [ -n "$wt_path" ]; then
            printf '%s\t%s\n' "$wt_path" "${wt_branch:--}"
        fi
    }
    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                flush
                wt_path="${line#worktree }"
                wt_branch=""
                ;;
            "branch refs/heads/"*)
                wt_branch="${line#branch refs/heads/}"
                ;;
            "detached")
                wt_branch="-"
                ;;
        esac
    done < <(git -C "$root" worktree list --porcelain 2>/dev/null)
    flush
}

# ROW_FMT — shared by the header and every data row so the header's
# window/branch labels are padded through the exact same pad_trunc() call
# data rows use, guaranteeing the header's "branch" label starts at the
# identical offset every data row's branch field does.
ROW_FMT='%s %s %s %2s %s %s %s %s\n'

# emit_rows <root> — the shared row generator behind 'fleet rows' and
# print_table (--once/--watch): one TSV line per row, fields
# "<display><TAB><kind><TAB><name><TAB><path><TAB><window_id><TAB><pane_id>".
# Worktree rows first, in list_worktrees_with_branch's own (main-first)
# order -- <display> is byte-identical to the pre-nav print_table row
# (same ROW_FMT call, same per-field lookups), <name> is basename(path)
# (what 'cs-new --open <name>' expects), <window_id>/<pane_id> come from
# pane_for_path() ('-'/'-' if no pane matches). Then one row per tmux
# window NOT represented by any worktree row (window_is_represented()),
# in window-index order: <name> is the window's own #{window_name},
# <path>/<pane_id> from window_repr_pane(), <display> uses the same
# ROW_FMT with '-' in every worktree-only field and a blank marker (no
# live-agent concept for a bare window). print_table (cut -f1) is
# therefore always textually identical to this function's display
# column for every row it prints -- one row shape, two consumers, no
# second place a row's text could drift from what --once shows.
emit_rows() {
    local root="$1" resolved_paths="" path branch
    while IFS="$TAB" read -r path branch; do
        [ -n "$path" ] || continue
        local rp
        rp="$(cd "$path" 2>/dev/null && pwd -P)" || rp="$path"
        resolved_paths="$resolved_paths$rp"$'\n'

        local window dirty ab ctx pdir sid mtime lane agents age marker name display pf wid pid
        window="$(window_for "$path")"
        dirty="$(dirty_count "$path")"
        ab="$(ahead_behind "$root" "$branch")"
        ctx="$(session_context "$path")"
        if [ -n "$ctx" ]; then
            IFS="$TAB" read -r pdir sid mtime <<<"$ctx"
            lane="$(lane_for_session "$sid")"
            agents="$(agents_for_session "$pdir" "$sid")"
            age="$(age_for_mtime "$mtime")"
        else
            lane="-"
            agents="0"
            age="-"
        fi
        if [ "$agents" = "0" ]; then
            marker=" "
        else
            marker="*"
        fi
        display="$(printf "$ROW_FMT" \
            "$marker" \
            "$(pad_trunc "$window" "$WINDOW_MAX")" \
            "$(pad_trunc "$branch" "$BRANCH_MAX")" \
            "$dirty" "$ab" "$(lane_letter "$lane")" "$agents" "$age")"
        display="${display%$'\n'}"
        name="$(basename "$path")"
        pf="$(pane_for_path "$path")"
        if [ -n "$pf" ]; then
            IFS="$TAB" read -r wid pid <<<"$pf"
        else
            wid="-"
            pid="-"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$display" "worktree" "$name" "$path" "$wid" "$pid"
    done < <(list_worktrees_with_branch "$root")

    [ -n "${TMUX:-}" ] || return 0
    command -v tmux >/dev/null 2>&1 || return 0
    local sess widx winid
    while IFS="$TAB" read -r sess widx winid; do
        [ -n "$winid" ] || continue
        window_is_represented "$winid" "$resolved_paths" && continue
        local reprline wpath wpid wname wbranch wdisplay
        reprline="$(window_repr_pane "$winid")"
        wpath=""
        wpid="-"
        if [ -n "$reprline" ]; then
            IFS="$TAB" read -r wpath wpid <<<"$reprline"
        fi
        wname="$(tmux display -p -t "$winid" '#{window_name}' 2>/dev/null)" || wname="-"
        [ -n "$wname" ] || wname="-"
        if [ -n "$wpath" ] && git -C "$wpath" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            wbranch="$(git -C "$wpath" rev-parse --abbrev-ref HEAD 2>/dev/null)" || wbranch="-"
            [ -n "$wbranch" ] || wbranch="-"
        else
            wbranch="-"
        fi
        wdisplay="$(printf "$ROW_FMT" \
            " " "$(pad_trunc "$wname" "$WINDOW_MAX")" "$(pad_trunc "$wbranch" "$BRANCH_MAX")" \
            "-" "-" "-" "-" "-")"
        wdisplay="${wdisplay%$'\n'}"
        [ -n "$wpath" ] || wpath="-"
        [ -n "$wpid" ] || wpid="-"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$wdisplay" "window" "$wname" "$wpath" "$winid" "$wpid"
    done < <(all_window_ids)
}

# print_table — the --once/--watch body: the one-line notice outside a
# git repo, else a header row followed by emit_rows()'s display column
# (worktree rows, then unrepresented-window rows). Row shape: <marker>
# <window> <branch> <dirty> <ahead/behind> <lane-letter> <agents> <age>
# -- marker is '*' when that row's live-agent count is > 0, else ' ';
# window/branch are pad_trunc()'d to WINDOW_MAX/BRANCH_MAX (fixed width,
# so branch always starts at the same offset); dirty is right-aligned in
# a 2-char field.
print_table() {
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [ -z "$root" ]; then
        echo "fleet: not inside a git repository"
        return 0
    fi
    printf "$ROW_FMT" \
        " " "$(pad_trunc "win" "$WINDOW_MAX")" "$(pad_trunc "branch" "$BRANCH_MAX")" \
        "+-" "a/b" "lane" "ag" "age"
    emit_rows "$root" | cut -f1
}

cmd_once() {
    print_table
}

# cmd_rows — 'fleet rows': emit_rows()'s raw TSV output, or the same
# one-line outside-a-git-repo notice --once/--watch fall back to (no
# rows to emit there either).
cmd_rows() {
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [ -z "$root" ]; then
        echo "fleet: not inside a git repository"
        return 0
    fi
    emit_rows "$root"
}

# cmd_watch — see usage(). Each tick: 'fleet follow' first (so the
# sidebar tracks wherever the user navigated to by other means since the
# last tick), then the WHOLE frame is assembled into one string --
# ESC[H, then every print_table line with a trailing ESC[K, then a
# final ESC[J -- and written with exactly one `printf '%s'`, never
# `clear`, so there is no window between "old frame gone" and "new frame
# drawn" for the terminal to blink through. FLEET_MAX_TICKS (unset/0 =
# unbounded) stops the loop after that many frames, for tests.
cmd_watch() {
    local max="${FLEET_MAX_TICKS:-0}" n=0 frame line
    while :; do
        do_follow || true
        frame=$'\e[H'
        while IFS= read -r line; do
            frame="${frame}${line}"$'\e[K\n'
        done < <(print_table)
        frame="${frame}"$'\e[J'
        printf '%s' "$frame"
        n=$((n + 1))
        if [ "$max" -gt 0 ] && [ "$n" -ge "$max" ]; then
            return 0
        fi
        sleep "$REFRESH_INTERVAL_S"
    done
}

# cmd_go <name|path|@window> — see usage(). Resolves <arg> against
# emit_rows()'s own rows (exact match on name, path, or window_id, in row
# order -- worktree rows first, then window rows), then either opens a
# session for a windowless worktree row (cs-new --open, then follow) or
# moves/selects via goto_pane() for a row that already has one.
cmd_go() {
    local arg="${1:-}" root
    [ -n "$arg" ] || die "usage: fleet go <name|path|@window>"
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"

    local disp kind name path wid pid matched=""
    while IFS="$TAB" read -r disp kind name path wid pid; do
        [ -n "$kind" ] || continue
        if [ "$arg" = "$name" ] || [ "$arg" = "$path" ] || [ "$arg" = "$wid" ]; then
            matched=1
            break
        fi
    done < <(emit_rows "$root")
    [ -n "$matched" ] || die "no such row: $arg"

    if [ "$kind" = "worktree" ] && [ "$wid" = "-" ]; then
        "$CS_NEW_BIN" --open "$name" || die "failed to open a session for $name"
        local pf
        pf="$(pane_for_path "$path")"
        if [ -n "$pf" ]; then
            IFS="$TAB" read -r wid pid <<<"$pf"
            goto_pane "$wid" "$pid"
        else
            do_follow || true
        fi
        return 0
    fi

    [ "$wid" != "-" ] || die "no window for $arg"
    [ "$pid" != "-" ] || die "no pane for $arg"
    goto_pane "$wid" "$pid"
}

# cmd_follow — 'fleet follow': see do_follow()'s own comment.
cmd_follow() {
    do_follow
}

# cmd_toggle [pane_id] — see usage(). Server-wide: closes the
# @fleet_sidebar pane if it's already in the target window, moves it
# there (goto_pane-style join) if it exists elsewhere on the server, or
# opens a new one (today's split-window behavior) if none exists
# anywhere. Tags the sidebar pane it creates/moves with the pane-scoped
# user option @fleet_sidebar=1 so a later toggle/go/follow can find it
# unambiguously, independent of what process name tmux reports for a
# running script (a shebang script's #{pane_current_command} is not
# reliably "fleet").
cmd_toggle() {
    local pane_id="${1:-}" target_pane cur_window existing_pane existing_window new_pane target_path
    if [ -n "$pane_id" ]; then
        target_pane="$pane_id"
    else
        target_pane="$(tmux display -p '#{pane_id}' 2>/dev/null)" || die "not inside a tmux session"
    fi
    cur_window="$(tmux display -p -t "$target_pane" '#{window_id}' 2>/dev/null)" || die "no such pane: $target_pane"

    existing_pane="$(find_sidebar_pane)"
    if [ -n "$existing_pane" ]; then
        existing_window="$(tmux display -p -t "$existing_pane" '#{window_id}' 2>/dev/null)" || existing_window=""
        if [ "$existing_window" = "$cur_window" ]; then
            tmux kill-pane -t "$existing_pane" 2>/dev/null || die "failed to close fleet sidebar pane: $existing_pane"
            return 0
        fi
        tmux join-pane -d -hb -l "$SIDEBAR_WIDTH" -s "$existing_pane" -t "$target_pane" 2>/dev/null || die "failed to move fleet sidebar pane: $existing_pane"
        tmux set-option -p -t "$existing_pane" @fleet_sidebar 1 2>/dev/null || true
        return 0
    fi

    # split-window's default cwd (with no -c) is only the SPLIT-FROM
    # pane's path when the split is requested from inside an attached
    # client; run-shell/external invocations (exactly how tests, hooks,
    # and fleet-menu-style bindings call this) default to the ISSUING
    # process's own cwd instead -- confirmed empirically, not assumed.
    # Passing -c explicitly makes the sidebar's cwd (and therefore its
    # own `fleet --once` table) correct regardless of invocation context.
    target_path="$(tmux display -p -t "$target_pane" '#{pane_current_path}' 2>/dev/null)" || target_path=""
    if [ -n "$target_path" ]; then
        new_pane="$(tmux split-window -d -hb -l "$SIDEBAR_WIDTH" -t "$target_pane" -c "$target_path" -P -F '#{pane_id}' -- "$SELF" --watch 2>/dev/null)"
    else
        new_pane="$(tmux split-window -d -hb -l "$SIDEBAR_WIDTH" -t "$target_pane" -P -F '#{pane_id}' -- "$SELF" --watch 2>/dev/null)"
    fi
    [ -n "$new_pane" ] || die "failed to open fleet sidebar"
    tmux set-option -p -t "$new_pane" @fleet_sidebar 1 2>/dev/null || true
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    "")
        usage
        exit 1
        ;;
esac

case "$1" in
    --once)
        cmd_once
        ;;
    --watch)
        cmd_watch
        ;;
    rows)
        cmd_rows
        ;;
    go)
        shift
        cmd_go "$@"
        ;;
    follow)
        cmd_follow
        ;;
    toggle)
        shift
        cmd_toggle "$@"
        ;;
    *)
        err "unknown argument: $1"
        usage
        exit 1
        ;;
esac
