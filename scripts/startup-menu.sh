#!/usr/bin/env bash
#
# startup-menu -- the first-pane menu for a brand-new folder (claude-orca-bg9).
#
#   startup-menu          run the menu now (re-runnable by hand any time)
#   startup-menu --pane   what config/.zshrc calls in an interactive pane: the
#                         menu when the folder is NEW, else one identity line
#   startup-menu --due    exit 0 if the folder is NEW, 1 if not; prints nothing
#
# NEW = no .beads and no run/startup-menu.done. Input is stdin: an empty line
# takes the default, EOF skips everything left (never a yes), `q` skips the
# remaining setup steps. Runs only inside the container; always exits 0 except
# --due.

if [ -z "${PROJECT_DIR:-}" ]; then
    _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -r "$_here/lib/paths.sh" ]; then
        # shellcheck source=scripts/lib/paths.sh
        . "$_here/lib/paths.sh"
        PROJECT_DIR="$(claude_orca_root 2>/dev/null)" || PROJECT_DIR=""
    fi
    PROJECT_DIR="${PROJECT_DIR:-$PWD}"
fi
name="${CLAUDE_ORCA_PROJECT_NAME:-$(basename "$PROJECT_DIR")}"
run="$PROJECT_DIR/.claude-dev/run"
done_file="$run/startup-menu.done"
log="$run/startup-menu.log"
lock="$run/startup-menu.lock"

is_new() { [ ! -e "$PROJECT_DIR/.beads" ] && [ ! -e "$done_file" ]; }

identity() {
    printf '● %s · claude-dev sandbox (Linux container, %s) · cs starts Claude Code · startup-menu sets up beads/GitHub\n' "$name" "$PROJECT_DIR"
}

mode="${1:-}"
case "$mode" in
--due) is_new; exit $? ;;
--pane) if ! is_new; then identity; exit 0; fi ;;
esac

mkdir -p "$run" 2>/dev/null || true

# One pane at a time (--pane only): a live pid in the lock keeps the others out.
have_lock=0
if [ "$mode" = "--pane" ]; then
    if ! mkdir "$lock" 2>/dev/null; then
        pid="$(cat "$lock/pid" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            identity
            exit 0
        fi
        rm -rf "$lock"
        mkdir "$lock" 2>/dev/null || { identity; exit 0; }
    fi
    printf '%s\n' "$$" >"$lock/pid"
    have_lock=1
fi

beads_ans="-"
gh_ans="-"
written=0
write_done() {
    [ "$written" = 1 ] && return 0
    written=1
    {
        date -u +%Y-%m-%dT%H:%M:%SZ
        printf 'beads=%s\ngithub=%s\n' "$beads_ans" "$gh_ans"
    } >"$done_file" 2>/dev/null || true
}
cleanup() {
    write_done
    [ "$have_lock" = 1 ] && rm -rf "$lock"
    return 0
}
trap cleanup EXIT
trap 'exit 0' INT TERM

EOF_SEEN=0
QUIT=0
ANS=""
# ask <prompt> <default>: sets ANS to the lower-cased answer (an empty line is
# the default); returns 1 and sets EOF_SEEN / QUIT when input ends or says q.
ask() {
    ANS=""
    printf '%s' "$1"
    if ! IFS= read -r ANS; then
        EOF_SEEN=1
        printf '\n'
        return 1
    fi
    ANS="$(printf '%s' "$ANS" | tr '[:upper:]' '[:lower:]')"
    case "$ANS" in
    q | quit) QUIT=1; return 1 ;;
    "") ANS="$2" ;;
    esac
    return 0
}
is_yes() { case "$1" in y | yes) return 0 ;; *) return 1 ;; esac; }

printf 'claude-dev · %s\n' "$name"
printf 'This tab is a shell inside %s'\''s sandbox -- a Linux container, not the Mac.\n' "$name"
if [ -n "${CLAUDE_ORCA_HOST_PROJECT_DIR:-}" ]; then
    printf 'The folder is %s here (%s on your Mac).\n' "$PROJECT_DIR" "$CLAUDE_ORCA_HOST_PROJECT_DIR"
else
    printf 'The folder is %s here.\n' "$PROJECT_DIR"
fi

# Wait for this boot's provisioning (provision-run.sh keeps run/provision/running
# as "<pid> <step>" while it works): a first pane opens seconds after sshd, and
# asking before 55-git-init's commit would record "no commits yet" forever.
pid_alive() {
    [ -d "/proc/$1" ] && return 0
    kill -0 "$1" 2>/dev/null && return 0
    # kill -0 on a root-owned / other-user pid fails with EPERM but it is alive
    ps -p "$1" >/dev/null 2>&1
}
wait_for_provision() {
    local rf="$run/provision/running" pid step last="" waited=0 limit="${CLAUDE_ORCA_STARTUP_WAIT:-600}" any=0
    while [ -e "$rf" ]; do
        read -r pid step 2>/dev/null <"$rf" || true
        case "$pid" in "" | *[!0-9]*) break ;; esac
        pid_alive "$pid" || break
        any=1
        if [ "$step" != "$last" ]; then
            printf "Finishing this sandbox's setup: %s (Ctrl-C for the shell now)\n" "$step"
            last="$step"
        fi
        if [ "$waited" -ge "$limit" ]; then
            printf 'Setup is still running (provision status shows it); asking anyway.\n'
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    [ "$any" = 1 ] && printf '✓ setup finished\n'
    return 0
}
wait_for_provision

# Step 1/2: beads
printf '\n[1/2] Beads\n'
if [ -e "$PROJECT_DIR/.beads" ]; then
    printf '✓ beads: already set up\n'
    beads_ans="already"
elif ! command -v bd >/dev/null 2>&1; then
    printf 'beads: bd is not installed here, skipping\n'
    beads_ans="no-bd"
elif ask "Initialize beads, the task tracker, in this folder (prefix '$name')? [Y/n] " y; then
    if is_yes "$ANS"; then
        beads_ans="yes"
        printf 'Setting up beads (takes a few seconds)...\n'
        # </dev/null: on a terminal bd init asks "Contributing to someone else's
        # repo? [y/N]" into the log, where nobody sees it, and eats the next answer.
        if (cd "$PROJECT_DIR" && env -u BEADS_DIR bd init --prefix "$name") </dev/null >>"$log" 2>&1; then
            printf '✓ beads initialized (prefix %s)\n' "$name"
        else
            printf "beads: bd init failed -- see %s; run 'bd init' here later\n" "$log"
            beads_ans="failed"
        fi
    else
        beads_ans="no"
    fi
else
    beads_ans="skipped"
fi

# Step 2/2: GitHub
printf '\n[2/2] GitHub\n'
github_step() {
    if [ "$EOF_SEEN" = 1 ] || [ "$QUIT" = 1 ]; then gh_ans="skipped"; return; fi
    if ! git -C "$PROJECT_DIR" rev-parse --verify -q HEAD >/dev/null 2>&1; then
        printf 'GitHub: no commits yet, skipping\n'; gh_ans="no-commits"; return
    fi
    local url
    if url="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null)" && [ -n "$url" ]; then
        printf '✓ GitHub: origin is %s\n' "$url"; gh_ans="already"; return
    fi
    if ! command -v gh >/dev/null 2>&1; then
        printf 'GitHub: gh is not installed here, skipping\n'; gh_ans="no-gh"; return
    fi
    if ! gh auth status >/dev/null 2>&1; then
        ask "GitHub: gh is not signed in. Sign in now? [Y/n] " y || { gh_ans="skipped"; return; }
        if ! is_yes "$ANS"; then gh_ans="no"; return; fi
        gh auth login --web --git-protocol https
        if ! gh auth status >/dev/null 2>&1; then
            printf 'GitHub: still not signed in, skipping\n'; gh_ans="not-signed-in"; return
        fi
    fi
    local owner who
    owner="$(gh api user --jq .login 2>/dev/null || true)"
    who="$name"
    [ -n "$owner" ] && who="$owner/$name"
    ask "Create a private GitHub repo $who for this folder and upload main? [y/N] " n || { gh_ans="skipped"; return; }
    if ! is_yes "$ANS"; then gh_ans="no"; return; fi
    if gh repo create "$name" --private --source "$PROJECT_DIR" --remote origin --push >>"$log" 2>&1; then
        printf '✓ GitHub: %s\n' "$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null)"
        gh_ans="yes"
    else
        tail -n 3 "$log"
        printf 'GitHub: create failed; retry by hand: gh repo create %s --private --source %s --remote origin --push\n' "$name" "$PROJECT_DIR"
        gh_ans="failed"
    fi
}
github_step

write_done
printf '\nRun startup-menu any time to see this again.\n'

if [ "$EOF_SEEN" = 0 ] && [ "$QUIT" = 0 ]; then
    if ask "What next?  [1] Claude Code (default)  [2] this shell " 1; then
        case "$ANS" in
        1) claude --dangerously-skip-permissions || true ;;
        esac
    fi
fi
exit 0
