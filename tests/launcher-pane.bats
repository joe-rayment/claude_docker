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

@test "open without a terminal says how to get a pane and never claims Orca is up" {
    mkdir -p "$PROJECT_DIR"
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qx 'ready: run ./claude-dev pane in a terminal'
    printf '%s\n' "$output" | grep -q 'sshd is up'
    ! printf '%s\n' "$output" | grep -qi 'orca is up'

    # A second open, still no terminal: the same line, and no web URL talk.
    unset CLAUDE_ORCA_PANE_FORCE_TTY
    run bash -c "cd '$PROJECT_DIR' && ./claude-dev open"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qx 'ready: run ./claude-dev pane in a terminal'
    ! printf '%s\n' "$output" | grep -qi 'orca is up'
    ! printf '%s\n' "$output" | grep -qi 'web url'
}

@test "open in a terminal ends in the pane: one ssh -tt call to the folder's alias" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    export CLAUDE_ORCA_PANE_FORCE_TTY=1 TERM=xterm-256color
    unset TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q 'sshd is up'
    ! printf '%s\n' "$output" | grep -q 'ready: run'
    # Typed at the project root: no CDEV_CWD to send, so just -F config -tt alias.
    [ "$(grep -c '^--- ssh$' "$SSH_STUB_LOG")" = "1" ]
    [ "$(ssh_call 1)" = "$(printf '%s\n' -F "$sd/config" -tt "$alias")" ]
    grep -Eq ' slow $' "$primary/.claude-dev/run/pane.log"
}

@test "open: a container whose sshd never comes up is a failure block that names run/sshd.log" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    export CLAUDE_ORCA_PANE_FORCE_TTY=1
    rm -f "$primary/.claude-dev/run/sshd.ready"
    printf 'sshd: fixture line one\nsshd: fixture line two\n' > "$primary/.claude-dev/run/sshd.log"
    export CLAUDE_ORCA_TEST_NO_SSHD=1 CLAUDE_ORCA_WEBURL_TIMEOUT=2
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 1 ]
    printf '%s\n' "$output" | grep -q 'sshd did not come up within 2s'
    printf '%s\n' "$output" | grep -q "$primary/.claude-dev/run/sshd.log"
    printf '%s\n' "$output" | grep -q 'sshd: fixture line two'
    ! printf '%s\n' "$output" | grep -qi 'web url'
    # No pane was started.
    [ ! -s "$SSH_STUB_LOG" ]
}

# SHELL becomes a script that records its argv (one per line) to
# $SHELL_STUB_LOG, so a fallback to the Mac shell can be read back.
write_stub_shell() {
    export SHELL_STUB_LOG="$BATS_TEST_TMPDIR/shell.log"
    : > "$SHELL_STUB_LOG"
    export SHELL="$BATS_TEST_TMPDIR/shell-stub"
    cat > "$SHELL" <<'STUB'
#!/usr/bin/env bash
printf 'argv:%s\n' "$@" >> "$SHELL_STUB_LOG"
printf 'ran\n' >> "$SHELL_STUB_LOG"
STUB
    chmod +x "$SHELL"
}

@test "pane fast path: the master answers, so it is one exec ssh and not a single docker call" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    export CLAUDE_ORCA_PANE_FORCE_TTY=1 SSH_STUB_CHECK_RC=0
    unset TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM
    : > "$CONTAINER_STUB_LOG"
    rm -f "$primary/.claude-dev/run/pane.log"
    run bash -c "cd '$primary' && ./claude-dev pane"
    [ "$status" -eq 0 ]
    [ ! -s "$CONTAINER_STUB_LOG" ]
    # Call 1 asks the master; call 2 is the pane itself.
    [ "$(ssh_call 1)" = "$(printf '%s\n' -F "$sd/config" -O check "$alias")" ]
    [ "$(ssh_call 2)" = "$(printf '%s\n' -F "$sd/config" -tt "$alias")" ]
    [ "$(grep -c '^--- ssh$' "$SSH_STUB_LOG")" = "2" ]
    grep -Eq '^[0-9T:Z-]+ fast $' "$primary/.claude-dev/run/pane.log"
}

@test "pane from a subdirectory sends it as CDEV_CWD, relative to the project" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    mkdir -p "$primary/pkg/deep"
    export CLAUDE_ORCA_PANE_FORCE_TTY=1 SSH_STUB_CHECK_RC=0
    unset TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM
    run bash -c "cd '$primary/pkg/deep' && '$primary/.claude-dev/bin/claude-dev' pane"
    [ "$status" -eq 0 ]
    [ "$(ssh_call 2 | grep '^SetEnv=')" = 'SetEnv=CDEV_CWD=pkg/deep' ]
    grep -Eq ' fast pkg/deep$' "$primary/.claude-dev/run/pane.log"
}

@test "pane slow path: no master yet, so it runs open (docker is called) and then the pane" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    mkdir -p "$primary/pkg"
    export CLAUDE_ORCA_PANE_FORCE_TTY=1 TERM=xterm-256color
    unset TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM
    : > "$CONTAINER_STUB_LOG"
    rm -f "$primary/.claude-dev/run/pane.log"
    run bash -c "cd '$primary/pkg' && '$primary/.claude-dev/bin/claude-dev' pane"
    [ "$status" -eq 0 ]
    [ -s "$CONTAINER_STUB_LOG" ]
    # SSH_STUB_CHECK_RC defaults to 1: call 1 is the failed check, the last is the pane.
    [ "$(ssh_call 1)" = "$(printf '%s\n' -F "$sd/config" -O check "$alias")" ]
    n="$(grep -c '^--- ssh$' "$SSH_STUB_LOG")"
    ssh_call "$n" | grep -qx -- '-tt'
    [ "$(ssh_call "$n" | grep '^SetEnv=')" = 'SetEnv=CDEV_CWD=pkg' ]
    grep -Eq ' slow pkg$' "$primary/.claude-dev/run/pane.log"
}

@test "pane outside any claude-dev folder becomes a Mac login shell under a NOT sandboxed banner" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    write_stub_shell
    mkdir -p "$BATS_TEST_TMPDIR/nowhere"
    export CLAUDE_ORCA_PANE_FORCE_TTY=1
    run bash -c "cd '$BATS_TEST_TMPDIR/nowhere' && '$primary/.claude-dev/bin/claude-dev' pane"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q 'is not inside a claude-dev folder'
    printf '%s\n' "$output" | grep -q '== Mac shell -- NOT sandboxed =='
    [ "$(cat "$SHELL_STUB_LOG")" = "$(printf 'argv:-l\nran')" ]
    # No ssh, no docker: there was no folder to ask.
    [ ! -s "$SSH_STUB_LOG" ]
}

@test "pane whose sandbox will not come up prints why, then drops to the labelled Mac shell" {
    open_folder "$PROJECT_DIR"
    write_stub_ssh
    write_stub_shell
    export CLAUDE_ORCA_PANE_FORCE_TTY=1
    rm -f "$primary/.claude-dev/run/sshd.ready"
    export CLAUDE_ORCA_TEST_NO_SSHD=1 CLAUDE_ORCA_WEBURL_TIMEOUT=2
    run bash -c "cd '$primary' && ./claude-dev pane"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q 'sshd did not come up within 2s'
    printf '%s\n' "$output" | grep -q 'claude-dev pane: the sandbox for'
    printf '%s\n' "$output" | grep -q '== Mac shell -- NOT sandboxed =='
    [ "$(cat "$SHELL_STUB_LOG")" = "$(printf 'argv:-l\nran')" ]
    # Only the master check was ever asked; no pane (-tt) was started.
    ! grep -qx -- '-tt' "$SSH_STUB_LOG"
}

@test "claude-dev --help lists the pane command" {
    open_folder "$PROJECT_DIR"
    run bash -c "cd '$primary' && ./claude-dev --help"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q 'claude-dev pane \[dir\]'
}

# --- doctor / verify ssh rows, and teardown -------------------------------

# The doctor/verify line for one check, e.g. `row_of "$output" "sshd"`:
#   "  [ok     ] sshd              port 5 answers SSH-2.0-stub"
row_of() {
    printf '%s\n' "$1" | grep -E "^  \[[a-zA-Z/ ]+\] $2 +" | head -1
}

# A TCP port nothing listens on: bind a free one and close it again.
closed_port() {
    python3 -I -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# An opened folder whose sshd "answers" (stub_sshd_up: a listener greeting
# SSH-2.0-stub, run/sshd.ready pointing at it) and whose ssh client is the
# argv-logging stub, so SSH_STUB_CHECK_RC / SSH_STUB_RC choose the answers.
# Order matters: write_stub_ssh replaces the accept-all client stub_sshd_up set.
healthy_folder() {
    open_folder "$PROJECT_DIR"
    stub_sshd_up "$primary"
    write_stub_ssh
}

# Guards:   the three ssh rows read ok / n/a / ok on a healthy folder with no
#           master yet, and the doctor still exits 0 (n/a is never a finding).
# Fails if: a missing master turns into a finding, or the sshd row stops
#           reading the banner and reports ok on a bare port.
# Run:      bats -f 'doctor: sshd ok' tests/launcher-pane.bats
@test "doctor: sshd ok on a listener that greets SSH-2.0, ssh master n/a when no master runs, key auth ok when ssh accepts" {
    healthy_folder
    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    row_of "$output" "sshd" | grep -q '^  \[ok     \] sshd .*answers SSH-2.0-stub'
    row_of "$output" "ssh master" | grep -q '^  \[n/a    \] ssh master .*not running'
    row_of "$output" "ssh key auth" | grep -q '^  \[ok     \] ssh key auth .*accepts this folder'
    # The master was asked with -O check before the key-auth probe ran.
    [ "$(ssh_call 1)" = "$(printf '%s\n' -F "$sd/config" -O check "$alias")" ]
    ssh_call 2 | grep -qx 'BatchMode=yes'
}

# Guards:   a live ControlMaster shows as an ok row ("panes reuse one connection").
# Fails if: the row is n/a (or missing) even though `ssh -O check` exits 0.
# Run:      bats -f 'ssh master reads ok' tests/launcher-pane.bats
@test "doctor: ssh master reads ok when ssh -O check answers" {
    healthy_folder
    export SSH_STUB_CHECK_RC=0
    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    row_of "$output" "ssh master" | grep -q '^  \[ok     \] ssh master .*panes reuse one connection'
}

# Guards:   a container that rejects this folder's key is a finding: a FAIL row
#           with the ssh exit code and the --update hint, exit 2.
# Fails if: a refused key still reads ok, or exits 0, or the exit code is lost.
# Run:      bats -f 'key is refused' tests/launcher-pane.bats
@test "doctor: ssh key auth FAILs and the doctor exits 2 when the key is refused" {
    healthy_folder
    export SSH_STUB_RC=255
    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 2 ]
    row_of "$output" "sshd" | grep -q '^  \[ok     \] sshd '
    row_of "$output" "ssh key auth" | grep -q '^  \[FAIL   \] ssh key auth .*exited 255'
    row_of "$output" "ssh key auth" | grep -q -- '--update'
}

# Guards:   a port that does not answer an SSH banner is a finding: FAIL "gave no
#           SSH banner", exit 2, and the key-auth row is skipped (n/a), not run.
# Fails if: a dead port still reads ok, the exit is 0, or the doctor runs the
#           key-auth ssh anyway (it could only repeat the finding, slowly).
# Run:      bats -f 'gave no SSH banner' tests/launcher-pane.bats
@test "doctor: a port nobody listens on is a FAIL 'gave no SSH banner' (exit 2) and key auth is skipped" {
    healthy_folder
    dead="$(closed_port)"
    sed -i "s/^port=.*/port=$dead/" "$primary/.claude-dev/run/sshd.ready"
    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 2 ]
    row_of "$output" "sshd" | grep -q "^  \[FAIL   \] sshd .*port $dead gave no SSH banner"
    row_of "$output" "ssh key auth" | grep -q '^  \[n/a    \] ssh key auth .*sshd is not answering'
    # Only the master check (-O check) ran; BatchMode (the key probe) never did.
    [ "$(grep -c '^--- ssh$' "$SSH_STUB_LOG")" = "1" ]
    ! grep -qx 'BatchMode=yes' "$SSH_STUB_LOG"
}

# Guards:   with no run/sshd.ready at all (sshd never started) the sshd row says
#           "missing ... not ready" and the doctor exits 2.
# Fails if: a folder that never published sshd's port reads healthy.
# Run:      bats -f 'no run/sshd.ready' tests/launcher-pane.bats
@test "doctor: no run/sshd.ready is a missing sshd row (exit 2)" {
    healthy_folder
    rm -f "$primary/.claude-dev/run/sshd.ready"
    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 2 ]
    row_of "$output" "sshd" | grep -q '^  \[missing\] sshd .*not ready'
    row_of "$output" "ssh key auth" | grep -q '^  \[n/a    \] ssh key auth'
}

# Guards:   `verify` shows the same three ssh rows as the doctor (it is the Mac
#           half of the same check) and passes when they are ok.
# Fails if: verify drops a row, or a healthy folder fails it.
# Run:      bats -f 'verify shows the same' tests/launcher-pane.bats
@test "verify shows the same sshd / ssh master / ssh key auth rows as the doctor, exit 0 when ok" {
    healthy_folder
    export SSH_STUB_CHECK_RC=0
    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 0 ]
    row_of "$output" "sshd" | grep -q '^  \[ok     \] sshd .*answers SSH-2.0-stub'
    row_of "$output" "ssh master" | grep -q '^  \[ok     \] ssh master '
    row_of "$output" "ssh key auth" | grep -q '^  \[ok     \] ssh key auth '
    # ... and a refused key is the same FAIL / exit 2 as in the doctor.
    export SSH_STUB_RC=255
    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 2 ]
    row_of "$output" "ssh key auth" | grep -q '^  \[FAIL   \] ssh key auth .*exited 255'
}

# Guards:   neither the doctor nor verify mentions the old `web url` row -- the
#           Mac no longer talks to Orca, so that row is gone for good.
# Fails if: a "web url" row (ok or missing) comes back in either command.
# Run:      bats -f 'web url' tests/launcher-pane.bats
@test "neither doctor nor verify prints a 'web url' row, healthy or not" {
    healthy_folder
    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" != *"web url"* ]]
    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 0 ]
    [[ "$output" != *"web url"* ]]
    # A failing folder (no sshd.ready) is no different: no web url is ever asked after.
    rm -f "$primary/.claude-dev/run/sshd.ready"
    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 2 ]
    [[ "$output" != *"web url"* ]]
    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 2 ]
    [[ "$output" != *"web url"* ]]
}

# Guards:   teardown ends the folder's ssh ControlMaster (`ssh -O exit`) before
#           it deletes state/ssh, so no master process outlives its folder.
# Fails if: teardown skips the -O exit call, passes the wrong config/alias, or
#           calls ssh for a folder that never had ssh state.
# Run:      bats -f 'teardown' tests/launcher-pane.bats
@test "teardown logs an ssh -O exit call for the folder's master, then removes state/ssh" {
    healthy_folder
    [ -f "$sd/config" ]
    : > "$SSH_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --teardown"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^--- ssh$' "$SSH_STUB_LOG")" = "1" ]
    [ "$(ssh_call 1)" = "$(printf '%s\n' -F "$sd/config" -O exit "$alias")" ]
    [ ! -e "$sd" ]
}
