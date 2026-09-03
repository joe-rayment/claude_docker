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

usage() {
    cat <<'EOF'
Usage: fleet --once | --watch | toggle [pane_id]

--once     Print one row per worktree of the repo containing cwd (main
           tree first): window, branch, dirty count, ahead/behind main,
           lane, live agents, last-activity age. Outside a git repo:
           prints a one-line notice and exits 0.
--watch    Like --once, clearing and redrawing every 3s until killed.
toggle [pane_id]
           If a pane in the target window (pane_id's window, or the
           ambient current window) is already running the fleet sidebar,
           kill it. Otherwise split a 34-column pane to the left running
           'fleet --watch', keeping focus on the original pane. pane_id
           defaults to the ambient current pane ($TMUX).

Env:
  CLAUDE_PROJECTS_DIR   overrides ~/.claude/projects (session transcripts)
  LANE_STATE_DIR        overrides ~/.claude/cache/lane (lane state)
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

# print_table — the --once/--watch body: the one-line notice outside a
# git repo, else a header row followed by one row per
# list_worktrees_with_branch entry. Row shape: <marker> <window> <branch>
# <dirty> <ahead/behind> <lane-letter> <agents> <age> -- marker is '*'
# when that row's live-agent count is > 0, else ' '; window/branch are
# pad_trunc()'d to WINDOW_MAX/BRANCH_MAX (fixed width, so branch always
# starts at the same offset); dirty is right-aligned in a 2-char field.
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
    while IFS="$TAB" read -r path branch; do
        [ -n "$path" ] || continue
        local window dirty ab ctx pdir sid mtime lane agents age marker
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
        printf "$ROW_FMT" \
            "$marker" \
            "$(pad_trunc "$window" "$WINDOW_MAX")" \
            "$(pad_trunc "$branch" "$BRANCH_MAX")" \
            "$dirty" "$ab" "$(lane_letter "$lane")" "$agents" "$age"
    done < <(list_worktrees_with_branch "$root")
}

cmd_once() {
    print_table
}

cmd_watch() {
    while :; do
        clear
        print_table
        sleep "$REFRESH_INTERVAL_S"
    done
}

# cmd_toggle [pane_id] — see usage(). Tags the sidebar pane it creates
# with the pane-scoped user option @fleet_sidebar=1 so a later toggle can
# find and kill it unambiguously, independent of what process name tmux
# reports for a running script (a shebang script's #{pane_current_command}
# is not reliably "fleet").
cmd_toggle() {
    local pane_id="${1:-}" target_pane cur_window existing_pane new_pane target_path
    if [ -n "$pane_id" ]; then
        target_pane="$pane_id"
    else
        target_pane="$(tmux display -p '#{pane_id}' 2>/dev/null)" || die "not inside a tmux session"
    fi
    cur_window="$(tmux display -p -t "$target_pane" '#{window_id}' 2>/dev/null)" || die "no such pane: $target_pane"
    existing_pane="$(tmux list-panes -t "$cur_window" -F "#{pane_id}${TAB}#{@fleet_sidebar}" 2>/dev/null | awk -F'\t' '$2=="1"{print $1; exit}')"
    if [ -n "$existing_pane" ]; then
        tmux kill-pane -t "$existing_pane" 2>/dev/null || die "failed to close fleet sidebar pane: $existing_pane"
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
