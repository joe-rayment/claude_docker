#!/usr/bin/env bash
# fleet-menu — dynamic tmux display-menu builder for the worktree-session
# fleet: New worktree session / Hide / Restore… / Jump… / Review… / Remove
# merged…. Wired into config/tmux.conf as the MouseDown3Pane right-click
# menu (items above the existing split/kill/zoom ones) and as prefix
# keybindings N H R J V M. See .claude/plans/worktree-sessions.md and
# beads_claude_docker-f5i6.
#
# Every subcommand resolves its tmux context (current pane/window) from
# the ambient $TMUX the invoking pane already has -- no server socket flag
# needed, matching cs-new.sh's own convention (see its existing_names()).
# This is also what makes the script testable without ever touching the
# live server: point $TMUX at a scratch `tmux -L <sock>` server and every
# `tmux ...` call below resolves against that server instead.
set -euo pipefail

err() { printf 'fleet-menu: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

# tmux's own -F format strings do NOT interpret a literal "\t" as a tab --
# confirmed empirically: it comes through as the two characters
# backslash-t, unlike printf/awk's -F, which both do their own escape
# processing. Every tab-separated -F format string below interpolates
# this real tab byte instead of writing \t directly.
TAB=$'\t'

# FLEET_BIN — the 'fleet' script cmd_sidebar delegates to. Prefers PATH
# (the installed /usr/local/bin/fleet), falling back to the script
# sitting right next to this one when 'fleet' isn't on PATH -- the same
# gap fleet.sh's own SELF comment documents for its --watch
# re-invocation: a container that hasn't re-synced /usr/local/bin since
# the last image build, or this script run straight from a
# checkout/test. Resolved once at load time since it never changes for
# the life of one invocation.
if command -v fleet >/dev/null 2>&1; then
    FLEET_BIN="fleet"
else
    FLEET_BIN="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/fleet.sh"
fi

# CS_NEW_BIN — the cs-new launcher cmd_new runs. Prefers the exact
# sibling next to THIS copy of fleet-menu.sh (scripts/cs-new.sh in a
# checkout, cs-new alongside an installed/staged fleet-menu) over a bare
# PATH lookup -- inverted from FLEET_BIN's own precedence on purpose,
# the same anti-staleness rationale fleet.sh's own CS_NEW_BIN documents:
# a test running the edited source checkout must never shell out to a
# stale /usr/local/bin/cs-new left over from before the last image sync
# (confirmed to actually be stale during beads_claude_docker-8wy7's own
# implementation -- lacked --open entirely), while in a real deployment
# the sibling IS the installed/staged copy anyway (same file, same
# result either way). Falls back to PATH's cs-new only if no sibling
# script is found next to SELF.
if [ -f "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/cs-new.sh" ]; then
    CS_NEW_BIN="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/cs-new.sh"
elif [ -f "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/cs-new" ]; then
    CS_NEW_BIN="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")/cs-new"
else
    CS_NEW_BIN="cs-new"
fi

# PANE_ID / PANE_PATH / REST — set by parse_pane_args, called at the top
# of every cmd_* function. config/tmux.conf's bindings invoke fleet-menu
# via `tmux run-shell`, which spawns the script with no TMUX_PANE set --
# so a bare ambient `tmux display -p` (no -t) inside the script falls
# back to tmux's own best guess at "the current pane" (the session's
# last select-pane/select-window state) rather than the exact pane that
# fired the binding. Bindings work around this by passing tmux formats
# that expand at fire-time: `fleet-menu hide #{pane_id}`, and for the
# subcommands that also need a repo root, `fleet-menu new #{pane_id}
# #{pane_current_path}`. Both are optional leading args -- a pane id
# always looks like %N and a repo-root path always starts with / (never
# ambiguous with --print or a plain window/worktree name) -- so every
# existing direct invocation (including every test in
# tests/tmux-fleet.bats that doesn't pass them) is unaffected and keeps
# falling back to ambient `tmux display -p` resolution.
PANE_ID=""
PANE_PATH=""
REST=()
parse_pane_args() {
    PANE_ID=""
    PANE_PATH=""
    REST=()
    if [ $# -gt 0 ]; then
        case "$1" in
            %[0-9]*)
                PANE_ID="$1"
                shift
                ;;
        esac
    fi
    if [ -n "$PANE_ID" ] && [ $# -gt 0 ]; then
        case "$1" in
            /*)
                PANE_PATH="$1"
                shift
                ;;
        esac
    fi
    REST=("$@")
}

usage() {
    cat <<'EOF'
Usage: fleet-menu <subcommand> [args...]

Every subcommand takes two optional LEADING args, ahead of its own
[args...] below: a pane id (%N) and, for the subcommands that need a
repo root (new, review, remove-merged), that pane's current path.
config/tmux.conf's bindings pass these as `#{pane_id}` / `#{pane_current_path}`
(tmux expands the format at fire-time) because run-shell spawns fleet-menu
with no TMUX_PANE set, so a bare ambient `tmux display -p` inside the
script would otherwise fall back to its own best guess at "the current
pane". Omit them (as every direct/manual invocation does) to fall back
to that ambient resolution.

Subcommands:
  new                       Create a worktree session (runs cs-new
                            synchronously) in the current pane's repo
                            root.
  hide                      Break the current pane out into its own
                            (backgrounded) window, keeping the current
                            window's name so it's visible in the status
                            bar as parked.
  restore [--print|<win>]   No args: interactive menu of windows other
                            than the current one; selecting one joins it
                            back with join-pane -h. --print lists the
                            candidates (id, name) without showing the
                            menu. <win> (a window id like @3, or an
                            unambiguous window name) restores that window
                            directly.
  jump [--print|<win>]      No args: interactive menu of every window
                            with its name and the git branch of its pane's
                            path; selecting one runs select-window.
                            --print lists them (id, name, branch). <win>
                            jumps directly.
  review [--print|<name>]   No args: interactive menu of worktrees under
                            .claude/worktrees/; selecting one opens a
                            popup with `git log`, `git diff --stat`, and
                            the coloured diff against main, paged.
                            --print lists them (name, branch, ahead count
                            against main). <name> opens the popup for
                            that worktree directly.
  remove-merged [--print|<name>]
                            No args: interactive menu of worktrees under
                            .claude/worktrees/ whose branch is merged into
                            main; selecting one runs `git worktree remove`
                            + `git branch -d`. Refuses (non-zero, no
                            change) if the target branch is not merged
                            into main. --print lists the merged candidates
                            (name, branch) only.
  sidebar                   Toggle the fleet sidebar in the current
                            window: delegates straight to `fleet toggle
                            <pane_id>` (see scripts/fleet.sh).
EOF
}

# ── shared helpers ──────────────────────────────────────────────────────

# current_pane_path — PANE_PATH if the caller passed one explicitly
# (bindings do, via #{pane_current_path} -- see parse_pane_args above),
# else PANE_ID's own path via an explicit tmux -t (bindings that only
# pass a pane id), else the ambient "current" pane via a bare
# `tmux display -p` (every direct invocation with no leading args, e.g.
# every existing test in tests/tmux-fleet.bats).
current_pane_path() {
    if [ -n "$PANE_PATH" ]; then
        printf '%s\n' "$PANE_PATH"
        return 0
    fi
    if [ -n "$PANE_ID" ]; then
        tmux display -p -t "$PANE_ID" '#{pane_current_path}' 2>/dev/null || die "no such pane: $PANE_ID"
        return 0
    fi
    tmux display -p '#{pane_current_path}' 2>/dev/null || die "not inside a tmux session (or scratch server unreachable)"
}

# current_pane_id — PANE_ID if the caller passed one explicitly, else the
# ambient "current" pane id.
current_pane_id() {
    if [ -n "$PANE_ID" ]; then
        printf '%s\n' "$PANE_ID"
        return 0
    fi
    tmux display -p '#{pane_id}' 2>/dev/null || die "not inside a tmux session"
}

# current_window_id — the window id for PANE_ID if the caller passed one
# explicitly (via an explicit tmux -t), else the ambient "current" window.
current_window_id() {
    if [ -n "$PANE_ID" ]; then
        tmux display -p -t "$PANE_ID" '#{window_id}' 2>/dev/null || die "no such pane: $PANE_ID"
        return 0
    fi
    tmux display -p '#{window_id}' 2>/dev/null || die "not inside a tmux session"
}

# current_window_name — the window name for PANE_ID if the caller passed
# one explicitly, else the ambient "current" window's name.
current_window_name() {
    if [ -n "$PANE_ID" ]; then
        tmux display -p -t "$PANE_ID" '#{window_name}' 2>/dev/null || die "no such pane: $PANE_ID"
        return 0
    fi
    tmux display -p '#{window_name}' 2>/dev/null || die "not inside a tmux session"
}

# git_root <path> — <path>'s git worktree toplevel, or empty + non-zero
# if <path> isn't inside a git repository.
git_root() {
    git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

# resolve_root — the git root of the invoking pane's cwd; dies if the
# pane isn't inside a git repository (subcommands that need a repo -- new,
# review, remove-merged -- call this; hide/restore/jump don't need it).
resolve_root() {
    local pane_path
    pane_path="$(current_pane_path)"
    git_root "$pane_path" || die "current pane is not inside a git repository: $pane_path"
}

# list_worktrees <root> — one line per git-worktree entry under
# <root>/.claude/worktrees/, as "<name>\t<branch>\t<path>". Skips
# detached-HEAD worktrees (no branch to compare against main).
list_worktrees() {
    local root="$1" prefix wt_path="" wt_branch=""
    prefix="$root/.claude/worktrees/"
    flush() {
        if [ -n "$wt_path" ] && [ -n "$wt_branch" ]; then
            case "$wt_path" in
                "$prefix"*)
                    printf '%s\t%s\t%s\n' "$(basename "$wt_path")" "$wt_branch" "$wt_path"
                    ;;
            esac
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
        esac
    done < <(git -C "$root" worktree list --porcelain)
    flush
}

# merged_worktrees <root> — list_worktrees, filtered to branches merged
# into main (excludes main itself: it's never under .claude/worktrees/).
merged_worktrees() {
    local root="$1" merged
    merged="$(git -C "$root" branch --merged main --format='%(refname:short)' 2>/dev/null || true)"
    list_worktrees "$root" | while IFS=$'\t' read -r name branch path; do
        if printf '%s\n' "$merged" | grep -qFx -- "$branch"; then
            printf '%s\t%s\t%s\n' "$name" "$branch" "$path"
        fi
    done
}

# worktree_record <root> <name> — the list_worktrees line for <name>, or
# empty + non-zero if there's no such worktree.
worktree_record() {
    local root="$1" name="$2"
    list_worktrees "$root" | awk -F'\t' -v n="$name" '$1==n{print; found=1} END{exit !found}'
}

# resolve_window_target <query> — a window id (e.g. @3) or an unambiguous
# window name, resolved to a definite window id. Non-zero if there's no
# match or the name is ambiguous (fleet-menu hide can leave two windows
# sharing a name -- see its own comment).
resolve_window_target() {
    local q="$1"
    case "$q" in
        @*)
            tmux list-windows -F '#{window_id}' 2>/dev/null | grep -qx -- "$q" || return 1
            printf '%s\n' "$q"
            return 0
            ;;
    esac
    local matches count
    matches="$(tmux list-windows -F "#{window_id}${TAB}#{window_name}" 2>/dev/null | awk -F'\t' -v n="$q" '$2==n{print $1}')"
    count="$(printf '%s\n' "$matches" | grep -c . || true)"
    [ "$count" -eq 1 ] || return 1
    printf '%s\n' "$matches"
}

# window_branch <pane-path> — the git branch checked out at <pane-path>,
# or "-" if it isn't a git repository.
window_branch() {
    git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null || printf -- '-\n'
}

# show_review_popup <root> <branch> — the review popup: git log, git diff
# --stat, then the coloured diff, all against main, paged with less -R.
show_review_popup() {
    local root="$1" branch="$2" cmd
    cmd="$(printf 'git -C %q log --oneline main..%q; echo; git -C %q diff --stat main...%q; echo; git -C %q diff --color=always main...%q | less -R' \
        "$root" "$branch" "$root" "$branch" "$root" "$branch")"
    tmux display-popup -E -w 90% -h 90% -- bash -c "$cmd"
}

# menu_key <index> — a distinct single-char key (1-9, then 0) for the
# <index>-th (0-based) item of a dynamically built menu. Falls back to no
# shortcut (still selectable by cursor+enter) past 10 items.
menu_key() {
    local i="$1"
    if [ "$i" -lt 9 ]; then
        printf '%d' "$((i + 1))"
    elif [ "$i" -eq 9 ]; then
        printf '0'
    else
        printf ''
    fi
}

# ── subcommands ──────────────────────────────────────────────────────────

cmd_new() {
    parse_pane_args "$@"
    local root
    root="$(resolve_root)"
    # Run cs-new synchronously, right here in the (outer) run-shell that
    # fired this binding -- no nested run-shell, no -b. A nested
    # backgrounded run-shell has no target pane, so tmux paints its
    # captured stdout+stderr (git's "Preparing worktree.../HEAD is now
    # at..." plus cs-new's own "cs-new: <name> -> <path>") as a
    # view-mode overlay on whatever pane is current when the job
    # finishes -- which is the brand-new Claude pane, hiding its
    # folder-trust dialog underneath (beads_claude_docker-8wy7). Capturing
    # output into a variable instead means nothing reaches this script's
    # own stdout/stderr on success, so the outer run-shell has nothing to
    # display either. $TMUX is already set in this run-shell's own
    # environment (inherited from the tmux server process), so cs-new
    # takes its tmux branch and returns as soon as the new window exists
    # -- it does not block on however long the launched session runs.
    local name_args=()
    if [ -n "${FLEET_MENU_NEW_NAME:-}" ]; then
        name_args=("$FLEET_MENU_NEW_NAME")
    fi
    local out status=0
    out="$(cd "$root" && "$CS_NEW_BIN" "${name_args[@]}" 2>&1)" || status=$?
    if [ "$status" -ne 0 ]; then
        local first_line
        first_line="$(printf '%s' "$out" | grep -m1 . || true)"
        # -p (print to the calling client rather than the pane-targeted
        # status line) matters here: without it, display-message needs a
        # resolvable attached client for the target pane, which a
        # run-shell context doesn't reliably have. -p instead writes to
        # this (still-connected, since run-shell with no -b blocks the
        # issuing client until the job finishes) invocation's own
        # stdout, which is exactly the channel the outer run-shell
        # relays straight back to the client that fired the binding --
        # confirmed empirically not to reopen the pane-overlay bug this
        # fix exists for, since that only happens for BACKGROUNDED
        # (-b) jobs whose issuing client has already disconnected.
        tmux display-message -p "fleet-menu new: ${first_line:-cs-new exited $status}"
        return 1
    fi
}

cmd_hide() {
    parse_pane_args "$@"
    local cur_pane cur_win_name
    cur_pane="$(current_pane_id)"
    cur_win_name="$(current_window_name)"
    tmux break-pane -d -s "$cur_pane" -n "$cur_win_name"
}

cmd_restore() {
    parse_pane_args "$@"
    local cur
    cur="$(current_window_id)"
    case "${REST[0]:-}" in
        --print)
            tmux list-windows -F "#{window_id}${TAB}#{window_name}" 2>/dev/null | awk -F'\t' -v cur="$cur" '$1!=cur'
            ;;
        "")
            local items=() wid wname i=0
            while IFS=$'\t' read -r wid wname; do
                [ "$wid" = "$cur" ] && continue
                items+=("$wname" "$(menu_key "$i")" "join-pane -h -s $wid -t $cur")
                i=$((i + 1))
            done < <(tmux list-windows -F "#{window_id}${TAB}#{window_name}")
            if [ "${#items[@]}" -eq 0 ]; then
                tmux display-message "fleet-menu: no other windows to restore"
                return 0
            fi
            tmux display-menu -T "#[align=centre]Restore window · prefix R" -x C -y C "${items[@]}"
            ;;
        *)
            local target
            target="$(resolve_window_target "${REST[0]}")" || die "no such window (or ambiguous name): ${REST[0]}"
            [ "$target" != "$cur" ] || die "cannot restore the current window into itself"
            tmux join-pane -h -s "$target" -t "$cur"
            ;;
    esac
}

cmd_jump() {
    parse_pane_args "$@"
    case "${REST[0]:-}" in
        --print)
            tmux list-windows -F "#{window_id}${TAB}#{window_name}${TAB}#{pane_current_path}" 2>/dev/null \
                | while IFS=$'\t' read -r wid wname wpath; do
                    printf '%s\t%s\t%s\n' "$wid" "$wname" "$(window_branch "$wpath")"
                done
            ;;
        "")
            local items=() wid wname wpath branch i=0
            while IFS=$'\t' read -r wid wname wpath; do
                branch="$(window_branch "$wpath")"
                items+=("$wname ($branch)" "$(menu_key "$i")" "select-window -t $wid")
                i=$((i + 1))
            done < <(tmux list-windows -F "#{window_id}${TAB}#{window_name}${TAB}#{pane_current_path}")
            if [ "${#items[@]}" -eq 0 ]; then
                tmux display-message "fleet-menu: no windows"
                return 0
            fi
            tmux display-menu -T "#[align=centre]Jump to window · prefix J" -x C -y C "${items[@]}"
            ;;
        *)
            local target
            target="$(resolve_window_target "${REST[0]}")" || die "no such window (or ambiguous name): ${REST[0]}"
            tmux select-window -t "$target"
            ;;
    esac
}

cmd_review() {
    parse_pane_args "$@"
    local root
    root="$(resolve_root)"
    case "${REST[0]:-}" in
        --print)
            list_worktrees "$root" | while IFS=$'\t' read -r name branch path; do
                ahead="$(git -C "$root" rev-list --count "main..$branch" 2>/dev/null || echo 0)"
                printf '%s\t%s\t%s\n' "$name" "$branch" "$ahead"
            done
            ;;
        "")
            local items=() name branch path i=0
            while IFS=$'\t' read -r name branch path; do
                items+=("$name ($branch)" "$(menu_key "$i")" "run-shell \"fleet-menu review #{pane_id} #{pane_current_path} $(printf '%q' "$name")\"")
                i=$((i + 1))
            done < <(list_worktrees "$root")
            if [ "${#items[@]}" -eq 0 ]; then
                tmux display-message "fleet-menu: no worktrees under .claude/worktrees/"
                return 0
            fi
            tmux display-menu -T "#[align=centre]Review worktree · prefix V" -x C -y C "${items[@]}"
            ;;
        *)
            local rec branch
            rec="$(worktree_record "$root" "${REST[0]}")" || die "no such worktree: ${REST[0]}"
            branch="$(printf '%s' "$rec" | cut -f2)"
            show_review_popup "$root" "$branch"
            ;;
    esac
}

cmd_sidebar() {
    parse_pane_args "$@"
    local pane_id
    if [ -n "$PANE_ID" ]; then
        pane_id="$PANE_ID"
    else
        pane_id="$(current_pane_id)"
    fi
    "$FLEET_BIN" toggle "$pane_id"
}

cmd_remove_merged() {
    parse_pane_args "$@"
    local root
    root="$(resolve_root)"
    case "${REST[0]:-}" in
        --print)
            merged_worktrees "$root" | cut -f1,2
            ;;
        "")
            local items=() name branch path i=0
            while IFS=$'\t' read -r name branch path; do
                items+=("$name ($branch)" "$(menu_key "$i")" "run-shell \"fleet-menu remove-merged #{pane_id} #{pane_current_path} $(printf '%q' "$name")\"")
                i=$((i + 1))
            done < <(merged_worktrees "$root")
            if [ "${#items[@]}" -eq 0 ]; then
                tmux display-message "fleet-menu: no merged worktrees to remove"
                return 0
            fi
            tmux display-menu -T "#[align=centre]Remove merged worktree · prefix M" -x C -y C "${items[@]}"
            ;;
        *)
            local rec branch path
            rec="$(worktree_record "$root" "${REST[0]}")" || die "no such worktree: ${REST[0]}"
            branch="$(printf '%s' "$rec" | cut -f2)"
            path="$(printf '%s' "$rec" | cut -f3)"
            git -C "$root" branch --merged main --format='%(refname:short)' 2>/dev/null | grep -qFx -- "$branch" \
                || die "refusing to remove unmerged branch: $branch"
            git -C "$root" worktree remove "$path" || die "git worktree remove failed for $path"
            git -C "$root" branch -d "$branch" || die "git branch -d failed for $branch"
            echo "fleet-menu: removed worktree ${REST[0]} (branch $branch)"
            ;;
    esac
}

# ── dispatch ─────────────────────────────────────────────────────────────

case "${1:-}" in
    -h|--help|"")
        usage
        [ "${1:-}" = "" ] && exit 1
        exit 0
        ;;
esac

sub="$1"
shift
case "$sub" in
    new)           cmd_new "$@" ;;
    hide)          cmd_hide "$@" ;;
    restore)       cmd_restore "$@" ;;
    jump)          cmd_jump "$@" ;;
    review)        cmd_review "$@" ;;
    remove-merged) cmd_remove_merged "$@" ;;
    sidebar)       cmd_sidebar "$@" ;;
    *)
        err "unknown subcommand: $sub"
        usage
        exit 1
        ;;
esac
