#!/usr/bin/env bash
# cs-new — open a new Claude Code side session in its own git worktree
# under .claude/worktrees/<name>, in a new tmux window of the current
# server (or the foreground outside tmux), sharing the main tree's beads
# via BEADS_DIR. See .claude/plans/worktree-sessions.md.
set -euo pipefail

err() { printf 'cs-new: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

# SELF — this script's own absolute path, used by FLEET_BIN below to
# find its sibling fleet script regardless of cwd.
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"

# FLEET_BIN — the 'fleet' launcher cs-new calls (fleet follow, once the
# new window exists) so an open sidebar joins the fresh session right
# away. Prefers the exact sibling next to THIS copy of cs-new.sh
# (scripts/fleet.sh in a checkout, fleet alongside an installed/staged
# cs-new) over a bare PATH lookup -- same anti-staleness rationale as
# fleet.sh's own CS_NEW_BIN (see its comment): a test running the edited
# source checkout must never shell out to a stale /usr/local/bin/fleet
# left over from before the last image sync, while in a real deployment
# the sibling IS the installed/staged copy anyway (same file, same
# result either way). Falls back to PATH's fleet only if no sibling
# script is found next to SELF.
if [ -f "$(dirname "$SELF")/fleet.sh" ]; then
    FLEET_BIN="$(dirname "$SELF")/fleet.sh"
elif [ -f "$(dirname "$SELF")/fleet" ]; then
    FLEET_BIN="$(dirname "$SELF")/fleet"
else
    FLEET_BIN="fleet"
fi

# seed_trust <root> <worktree> — best-effort: if $HOME/.claude.json
# exists and <root> is already trusted there, copy that trust to
# <worktree> too (same code the user already trusted, one directory
# deeper) via jq to a temp file in the same directory, then `mv -f` over
# the original, preserving its mode. Merges into any existing object at
# <worktree> rather than clobbering it. Does nothing -- and never
# creates the file -- if $HOME, the file, jq, or the root's trust entry
# is missing, or the file doesn't parse: worst case the folder-trust
# dialog just shows once more.
#
# Best-effort only: Claude Code re-reads this file at its own startup,
# and a concurrently running Claude process can rewrite it between our
# read and our mv, silently losing the seed -- acceptable.
seed_trust() {
    local root="$1" worktree="$2" claude_json trusted tmp mode
    [ -n "${HOME:-}" ] || return 0
    claude_json="$HOME/.claude.json"
    [ -f "$claude_json" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    trusted="$(jq -r --arg root "$root" '.projects[$root].hasTrustDialogAccepted // false' "$claude_json" 2>/dev/null)" || trusted=""
    [ "$trusted" = "true" ] || return 0

    tmp="$(mktemp "$claude_json.XXXXXX" 2>/dev/null)" || return 0
    if jq --indent 2 --arg wt "$worktree" \
        '.projects[$wt] = ((.projects[$wt] // {}) + {hasTrustDialogAccepted: true})' \
        "$claude_json" > "$tmp" 2>/dev/null
    then
        mode="$(stat -c '%a' "$claude_json" 2>/dev/null)" || mode=""
        [ -n "$mode" ] && chmod "$mode" "$tmp" 2>/dev/null
        mv -f "$tmp" "$claude_json" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
    return 0
}

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

# Best-effort, both modes alike: give the worktree the same folder trust
# root already has, one directory deeper, so the new session doesn't
# land on a "Do you trust this folder?" dialog (default answer "No,
# exit", which would just close the window -- beads_claude_docker-8wy7).
seed_trust "$root" "$path"

if [ -n "${CS_NEW_LAUNCH:-}" ]; then
    launch_cmd="$CS_NEW_LAUNCH"
else
    launch_cmd="claude --dangerously-skip-permissions -n $(printf '%q' "$name")"
fi

if [ -n "${TMUX:-}" ]; then
    tmux new-window -n "$name" -c "$path" -e "BEADS_DIR=$root/.beads" -- "$launch_cmd"
    tmux select-window -t "$name" 2>/dev/null || true
    # An open sidebar should join the fresh session immediately rather
    # than waiting for the next --watch tick or a manual jump.
    "$FLEET_BIN" follow >/dev/null 2>&1 || true
else
    cd "$path"
    exec env BEADS_DIR="$root/.beads" bash -c "$launch_cmd"
fi
