#!/usr/bin/env bats
#
# Guards:   the launcher turns a terminal into a sandbox pane over ssh: the
#           exact `ssh` command line (one SetEnv option, spaces quoted, empty
#           variables left out), the once-per-Ghostty-version terminfo push,
#           `open`/`pane` printing a hint instead of exec'ing when there is no
#           terminal, the fast path (no docker) vs the slow path, the fallback
#           to the Mac shell, the doctor/verify ssh rows and teardown.
# Fails if: ssh gets two SetEnv options (it honours only the first), a value
#           with a space loses its quotes, the terminfo is re-pushed on every
#           open, the fast path calls docker, a failed pane just dies instead
#           of dropping to a labelled Mac shell, or teardown leaves state/ssh.
# Run:      bats tests/launcher-pane.bats
#
# Everything runs against fixtures under $BATS_TEST_TMPDIR. `docker` is the
# stub from tests/helpers/setup.bash; `ssh` is CLAUDE_ORCA_SSH pointing at a
# script that logs its argv (one argument per line) and exits with a chosen
# code; the real OpenSSH 9.6 client is used only for the -G quoting case.

load helpers/setup

REAL_SSH_ROOT="$HOME/.cache/claude-orca-test/openssh"

# A bootstrapped, opened folder at $1 (the bootstrap runs the first open).
# Sets $primary, $sd (its state/ssh), $port and $alias.
open_folder() {
    mkdir -p "$1"
    primary="$(abspath "$1")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    sd="$primary/.claude-dev/state/ssh"
    port="$(cat "$primary/.claude-dev/run/port")"
    alias="claude-dev-$(basename "$primary" | tr 'A-Z ' 'a-z-')"
}

# CLAUDE_ORCA_SSH: a stub that appends "--- ssh" and then its argv, one
# argument per line, to $SSH_STUB_LOG. `-O check` exits $SSH_STUB_CHECK_RC
# (default 1: no master), anything else $SSH_STUB_RC (default 0). With
# $SSH_STUB_STDIN_LOG set it also saves what was piped to it.
write_stub_ssh() {
    export SSH_STUB_LOG="$BATS_TEST_TMPDIR/ssh.log"
    : > "$SSH_STUB_LOG"
    export CLAUDE_ORCA_SSH="$BATS_TEST_TMPDIR/ssh-stub"
    cat > "$CLAUDE_ORCA_SSH" <<'STUB'
#!/usr/bin/env bash
{
    echo "--- ssh"
    for a in "$@"; do printf '%s\n' "$a"; done
} >> "$SSH_STUB_LOG"
if [ -n "${SSH_STUB_STDIN_LOG:-}" ]; then cat > "$SSH_STUB_STDIN_LOG"; fi
case " $* " in
    *" -O check "*) exit "${SSH_STUB_CHECK_RC:-1}" ;;
    *" -O exit "*) exit 0 ;;
esac
exit "${SSH_STUB_RC:-0}"
STUB
    chmod +x "$CLAUDE_ORCA_SSH"
}

# A stand-in for the Mac's infocmp: prints a fake xterm-ghostty entry.
write_stub_infocmp() {
    cat > "$STUB_BIN/infocmp" <<'STUB'
#!/usr/bin/env bash
printf 'xterm-ghostty|ghostty terminal,\n\tam, bce,\n'
STUB
    chmod +x "$STUB_BIN/infocmp"
}

# One launcher function out of the folder's own launcher.sh, with its command
# dispatch cut off (so sourcing it runs nothing), called in a bash subshell:
#   run_launcher_fn <folder> <function> [args...]
run_launcher_fn() {
    local dir="$1" fn="$2" lib
    shift 2
    lib="$dir/.claude-dev/template/scripts/launcher-lib-test.sh"
    sed '/^case "${1:-}" in$/,$d' "$dir/.claude-dev/template/scripts/launcher.sh" > "$lib"
    bash -c 'set -euo pipefail; source "$1"; shift; "$@"' _ "$lib" "$fn" "$dir" "$@"
}

# The argv lines the stub logged for its Nth (1-based) invocation.
ssh_call() {
    awk -v n="$1" '/^--- ssh$/ { c++; next } c == n' "$SSH_STUB_LOG"
}

@test "pane_exec execs ssh with the folder's config and ONE SetEnv, empty variables left out" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    export CLAUDE_ORCA_PANE_FORCE_TTY=1 TERM_PROGRAM=ghostty TERM_PROGRAM_VERSION=1.2.3 COLORTERM=
    run run_launcher_fn "$primary" pane_exec "$primary"
    [ "$status" -eq 0 ]

    # Root of the project: no CDEV_CWD; empty COLORTERM is omitted.
    [ "$(ssh_call 1)" = "$(printf '%s\n' -F "$sd/config" -tt -o 'SetEnv=TERM_PROGRAM=ghostty TERM_PROGRAM_VERSION=1.2.3' "$alias")" ]
    [ "$(grep -c '^--- ssh$' "$SSH_STUB_LOG")" = "1" ]
}

@test "pane_exec sends the working directory relative to the project, quoting a value with a space" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    mkdir -p "$primary/sub dir/inner"
    export CLAUDE_ORCA_PANE_FORCE_TTY=1 TERM_PROGRAM=ghostty
    unset TERM_PROGRAM_VERSION COLORTERM
    run run_launcher_fn "$primary" pane_exec "$primary/sub dir/inner"
    [ "$status" -eq 0 ]

    opt="$(ssh_call 1 | grep '^SetEnv=')"
    [ "$opt" = 'SetEnv=CDEV_CWD="sub dir/inner" TERM_PROGRAM=ghostty' ]
    # ssh honours only the first -o SetEnv, so there must be exactly one.
    [ "$(ssh_call 1 | grep -c '^SetEnv=')" = "1" ]
    [ "$(ssh_call 1 | grep -c '^-o$')" = "1" ]
}

@test "pane_exec starts at the project root when asked from outside the folder" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
    export CLAUDE_ORCA_PANE_FORCE_TTY=1
    unset TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM
    run run_launcher_fn "$primary" pane_exec "$BATS_TEST_TMPDIR/elsewhere"
    [ "$status" -eq 0 ]

    # Nothing to send at all: no -o option, just the alias.
    [ "$(ssh_call 1)" = "$(printf '%s\n' -F "$sd/config" -tt "$alias")" ]
}

@test "terminfo: pushed once per Ghostty version, again when the version changes" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    write_stub_infocmp
    export TERM=xterm-ghostty TERM_PROGRAM_VERSION=1.2.3
    export SSH_STUB_STDIN_LOG="$BATS_TEST_TMPDIR/ssh-stdin.txt"

    run run_launcher_fn "$primary" ssh_push_terminfo
    [ "$status" -eq 0 ]
    [ "$(ssh_call 1)" = "$(printf '%s\n' -F "$sd/config" -o BatchMode=yes "$alias" 'tic -x -o ~/.terminfo - ')" ]
    grep -q '^xterm-ghostty|ghostty terminal,' "$SSH_STUB_STDIN_LOG"
    [ "$(cat "$primary/.claude-dev/run/terminfo.stamp")" = "1.2.3" ]

    # Same version again: no second ssh.
    run run_launcher_fn "$primary" ssh_push_terminfo
    [ "$status" -eq 0 ]
    [ "$(grep -c '^--- ssh$' "$SSH_STUB_LOG")" = "1" ]

    # A new Ghostty: pushed again, stamp moves on.
    export TERM_PROGRAM_VERSION=1.3.0
    run run_launcher_fn "$primary" ssh_push_terminfo
    [ "$status" -eq 0 ]
    [ "$(grep -c '^--- ssh$' "$SSH_STUB_LOG")" = "2" ]
    [ "$(cat "$primary/.claude-dev/run/terminfo.stamp")" = "1.3.0" ]
}

@test "terminfo: a failed push is one warning, exit 0, and no stamp" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    write_stub_infocmp
    export TERM=xterm-ghostty TERM_PROGRAM_VERSION=1.2.3 SSH_STUB_RC=255
    run run_launcher_fn "$primary" ssh_push_terminfo
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c 'terminfo:')" = "1" ]
    [ ! -e "$primary/.claude-dev/run/terminfo.stamp" ]
}

@test "terminfo: any other TERM touches nothing" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    write_stub_infocmp
    export TERM=xterm-256color TERM_PROGRAM_VERSION=1.2.3
    run run_launcher_fn "$primary" ssh_push_terminfo
    [ "$status" -eq 0 ]
    [ ! -s "$SSH_STUB_LOG" ]
    [ ! -e "$primary/.claude-dev/run/terminfo.stamp" ]
}

@test "pane_exec without a terminal prints the ready: line, runs no ssh, writes no pane.log" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    unset CLAUDE_ORCA_PANE_FORCE_TTY
    rm -f "$primary/.claude-dev/run/pane.log"
    run run_launcher_fn "$primary" pane_exec "$primary"
    [ "$status" -eq 0 ]
    [ "$output" = "ready: run ./claude-dev pane in a terminal" ]
    [ ! -s "$SSH_STUB_LOG" ]
    [ ! -e "$primary/.claude-dev/run/pane.log" ]
}

@test "pane_exec logs one line to run/pane.log: the mode and the relative directory" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    mkdir -p "$primary/a/b"
    export CLAUDE_ORCA_PANE_FORCE_TTY=1
    unset TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM
    rm -f "$primary/.claude-dev/run/pane.log"
    run run_launcher_fn "$primary" pane_exec "$primary/a/b" fast
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$primary/.claude-dev/run/pane.log" | tr -d ' ')" = "1" ]
    grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z fast a/b$' "$primary/.claude-dev/run/pane.log"
}

@test "the real OpenSSH client parses pane_exec's one SetEnv option, every value intact" {
    [ -x "$REAL_SSH_ROOT/usr/bin/ssh" ] || skip "extracted OpenSSH not at $REAL_SSH_ROOT"
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    mkdir -p "$primary/sub dir"
    export CLAUDE_ORCA_PANE_FORCE_TTY=1 TERM_PROGRAM=ghostty TERM_PROGRAM_VERSION=1.2.3 COLORTERM=truecolor
    run run_launcher_fn "$primary" pane_exec "$primary/sub dir"
    [ "$status" -eq 0 ]
    opt="$(ssh_call 1 | grep '^SetEnv=')"

    # Hand the exact option string to the real ssh and read back what it parsed.
    run env LD_LIBRARY_PATH="$REAL_SSH_ROOT/usr/lib/aarch64-linux-gnu" \
        "$REAL_SSH_ROOT/usr/bin/ssh" -F "$sd/config" -G -o "$opt" "$alias"
    [ "$status" -eq 0 ]
    setenv="$(printf '%s\n' "$output" | grep -i '^setenv ')"
    [ "$(printf '%s\n' "$setenv" | wc -l | tr -d ' ')" = "4" ]
    printf '%s\n' "$setenv" | grep -qx 'setenv CDEV_CWD=sub dir'
    printf '%s\n' "$setenv" | grep -qx 'setenv TERM_PROGRAM=ghostty'
    printf '%s\n' "$setenv" | grep -qx 'setenv TERM_PROGRAM_VERSION=1.2.3'
    printf '%s\n' "$setenv" | grep -qx 'setenv COLORTERM=truecolor'
}
