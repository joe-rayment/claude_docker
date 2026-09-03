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

usage() {
    cat <<'EOF'
Usage: fleet-menu <subcommand> [args...]

Subcommands:
  new                       Create a worktree session (run-shell cs-new)
                            in the current pane's repo root.
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
EOF
}

# ── shared helpers ──────────────────────────────────────────────────────

# current_pane_path — the invoking pane's cwd, via the ambient tmux
# context (no explicit target: see the header comment on why that's safe
# and test-friendly).
current_pane_path() {
    tmux display -p '#{pane_current_path}' 2>/dev/null || die "not inside a tmux session (or scratch server unreachable)"
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
        if printf '%s\n' "$merged" | grep -qx -- "$branch"; then
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
    local root
    root="$(resolve_root)"
    tmux run-shell -b -c "$root" "cs-new"
}

cmd_hide() {
    local cur_pane cur_win_name
    cur_pane="$(tmux display -p '#{pane_id}' 2>/dev/null)" || die "not inside a tmux session"
    cur_win_name="$(tmux display -p '#{window_name}' 2>/dev/null)" || die "not inside a tmux session"
    tmux break-pane -d -s "$cur_pane" -n "$cur_win_name"
}

cmd_restore() {
    local cur
    cur="$(tmux display -p '#{window_id}' 2>/dev/null)" || die "not inside a tmux session"
    case "${1:-}" in
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
            target="$(resolve_window_target "$1")" || die "no such window (or ambiguous name): $1"
            [ "$target" != "$cur" ] || die "cannot restore the current window into itself"
            tmux join-pane -h -s "$target" -t "$cur"
            ;;
    esac
}

cmd_jump() {
    case "${1:-}" in
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
            target="$(resolve_window_target "$1")" || die "no such window (or ambiguous name): $1"
            tmux select-window -t "$target"
            ;;
    esac
}

cmd_review() {
    local root
    root="$(resolve_root)"
    case "${1:-}" in
        --print)
            list_worktrees "$root" | while IFS=$'\t' read -r name branch path; do
                ahead="$(git -C "$root" rev-list --count "main..$branch" 2>/dev/null || echo 0)"
                printf '%s\t%s\t%s\n' "$name" "$branch" "$ahead"
            done
            ;;
        "")
            local items=() name branch path i=0
            while IFS=$'\t' read -r name branch path; do
                items+=("$name ($branch)" "$(menu_key "$i")" "run-shell \"fleet-menu review $(printf '%q' "$name")\"")
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
            rec="$(worktree_record "$root" "$1")" || die "no such worktree: $1"
            branch="$(printf '%s' "$rec" | cut -f2)"
            show_review_popup "$root" "$branch"
            ;;
    esac
}

cmd_remove_merged() {
    local root
    root="$(resolve_root)"
    case "${1:-}" in
        --print)
            merged_worktrees "$root" | cut -f1,2
            ;;
        "")
            local items=() name branch path i=0
            while IFS=$'\t' read -r name branch path; do
                items+=("$name ($branch)" "$(menu_key "$i")" "run-shell \"fleet-menu remove-merged $(printf '%q' "$name")\"")
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
            rec="$(worktree_record "$root" "$1")" || die "no such worktree: $1"
            branch="$(printf '%s' "$rec" | cut -f2)"
            path="$(printf '%s' "$rec" | cut -f3)"
            git -C "$root" branch --merged main --format='%(refname:short)' 2>/dev/null | grep -qx -- "$branch" \
                || die "refusing to remove unmerged branch: $branch"
            git -C "$root" worktree remove "$path" || die "git worktree remove failed for $path"
            git -C "$root" branch -d "$branch" || die "git branch -d failed for $branch"
            echo "fleet-menu: removed worktree $1 (branch $branch)"
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
    *)
        err "unknown subcommand: $sub"
        usage
        exit 1
        ;;
esac
