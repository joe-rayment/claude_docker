#!/usr/bin/env bash
# cs-new — open a new Claude Code side session in its own git worktree
# under .claude/worktrees/<name>, in a new tmux window of the current
# server (or the foreground outside tmux), sharing the main tree's beads
# via BEADS_DIR. See .claude/plans/worktree-sessions.md.
set -euo pipefail

err() { printf 'cs-new: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
    cat <<'EOF'
Usage: cs-new [name]
       cs-new --open <name>

Creates a git worktree at .claude/worktrees/<name> (branched from the
current tree's HEAD) and opens a Claude Code session there: in a new
tmux window if $TMUX is set, otherwise in the foreground. <name>
defaults to a generated <adjective>-<noun>, unique against existing
worktrees and (inside tmux) window names on the current server.

--open <name>  Skip worktree creation: launch the same session (same
               launch command, same env) in the EXISTING worktree
               .claude/worktrees/<name>. Fails non-zero, with no git
               writes at all, if that worktree does not exist.

Env:
  CS_NEW_LAUNCH   overrides the launched command (default: claude
                  --dangerously-skip-permissions -n <name>); always runs
                  with BEADS_DIR=<root>/.beads and cwd=<worktree>.
EOF
}

OPEN_MODE=0
case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --open)
        OPEN_MODE=1
        shift
        ;;
esac

# ── word lists: >=30 adjectives x >=30 nouns, short/lowercase/readable,
# no digits or hyphens (generated names must match ^[a-z]+-[a-z]+$) ──────
ADJECTIVES=(
    quiet swift bold calm eager brave crisp keen lively merry
    mild neat proud quick sharp tidy vivid witty zesty amber
    coral bright dusty early fresh golden honest jolly kind lucky
    misty nimble plain roomy sunny tame urban windy zippy young
)
NOUNS=(
    otter falcon heron badger lynx robin sparrow finch marten wren
    beaver egret hawk ibis jay kite mole newt osprey puffin
    quail raven stoat tern viper walrus yak zebra gecko hare
    crane dingo ferret gull ocelot ibex koala lemur moose nutria
)

name="${1:-}"

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"

# existing_names — one name per line: every current worktree's directory
# basename, plus (inside tmux) every window name on the current server.
# The trailing `|| true` on each stage guards set -e/pipefail against a
# transient git/tmux failure aborting the whole launcher over a query
# that's allowed to come back empty.
existing_names() {
    git -C "$root" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree /{print $2}' \
        | while IFS= read -r wt_path; do basename "$wt_path"; done || true
    if [ -n "${TMUX:-}" ]; then
        tmux list-windows -F '#{window_name}' 2>/dev/null || true
    fi
}

name_conflicts() {
    local candidate="$1"
    if existing_names | grep -x -- "$candidate" >/dev/null; then
        return 0
    fi
    [ -e "$root/.claude/worktrees/$candidate" ]
}

generate_unique_name() {
    local tries=0 candidate
    while :; do
        candidate="${ADJECTIVES[$((RANDOM % ${#ADJECTIVES[@]}))]}-${NOUNS[$((RANDOM % ${#NOUNS[@]}))]}"
        if ! name_conflicts "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        tries=$((tries + 1))
        [ "$tries" -lt 1000 ] || die "could not find a unique name after $tries tries"
    done
}

if [ "$OPEN_MODE" -eq 1 ]; then
    [ -n "$name" ] || die "--open requires a worktree name"
    case "$name" in
        */*) die "name must not contain '/': $name" ;;
    esac
    path="$root/.claude/worktrees/$name"
    [ -d "$path" ] || die "no such worktree: $name"
else
    if [ -z "$name" ]; then
        name="$(generate_unique_name)"
    else
        case "$name" in
            */*) die "name must not contain '/': $name" ;;
        esac
        name_conflicts "$name" && die "worktree/session name already in use: $name"
    fi

    path="$root/.claude/worktrees/$name"
    mkdir -p "$root/.claude/worktrees"
    git -C "$root" worktree add "$path" -b "$name" || die "failed to create worktree at $path"

    echo "cs-new: $name -> $path"
fi

if [ -n "${CS_NEW_LAUNCH:-}" ]; then
    launch_cmd="$CS_NEW_LAUNCH"
else
    launch_cmd="claude --dangerously-skip-permissions -n $(printf '%q' "$name")"
fi

if [ -n "${TMUX:-}" ]; then
    tmux new-window -n "$name" -c "$path" -e "BEADS_DIR=$root/.beads" -- "$launch_cmd"
    tmux select-window -t "$name" 2>/dev/null || true
else
    cd "$path"
    exec env BEADS_DIR="$root/.beads" bash -c "$launch_cmd"
fi
