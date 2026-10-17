#!/usr/bin/env python3
# Guards:   tests/e2e-local.bats: `claude-dev pane` run on a REAL pty, the way a Ghostty tab runs it, gives a shell in the project
# Fails if: the pane never reaches a prompt, the shell is not in the project path, or the terminal's answers to the kitty/XTVERSION probes are not sent
# Run:      python3 -I tests/e2e-pty-pane.py <claude-dev> pane <project dir>
#
# Usage: e2e-pty-pane.py <command> [args...]
# Runs the command on a pty (40x120), answers the two probes Ghostty answers
# (kitty keyboard `CSI ? u` and XTVERSION `CSI > 0 q`), waits for the pane to
# go quiet, types `pwd; echo PANE-OK-$$; exit`, and prints what the terminal
# showed with the escape sequences stripped. Exit status: 0 when the command
# exited by itself after `exit`, 3 when it had to be killed.
# Env: E2E_PANE_LINE replaces the typed line (default the one above),
# E2E_PANE_WAIT is how many seconds to read after typing it (default 8; the
# read ends early when the pane exits).
import os, pty, sys, time, select, re, signal, fcntl, termios, struct

argv = sys.argv[1:]
if not argv:
    sys.exit("usage: e2e-pty-pane.py <command> [args...]")

pid, fd = pty.fork()
if pid == 0:
    os.execv(argv[0], argv)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))

buf = b''
probes = []
last_data = time.time()


def pump(seconds):
    """Read the pty for up to `seconds`, answering the probes; False on EOF."""
    global buf, last_data
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            d = os.read(fd, 65536)
        except OSError:
            return False
        if not d:
            return False
        buf += d
        last_data = time.time()
        if b'\x1b[?u' in d:
            probes.append('CSI?u')
            os.write(fd, b'\x1b[?1u')
        if b'\x1b[>0q' in d or b'\x1b[>q' in d:
            probes.append('XTVERSION')
            os.write(fd, b'\x1bP>|ghostty 1.3.1\x1b\\')
    return True


def clean(b):
    pat = (rb'\x1b\[[0-9;?<>=]*[A-Za-z~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)'
           rb'|\x1bP[^\x1b]*\x1b\\|\x1b[()][A-Z0-9]|\x1b[=>78]')
    return re.sub(pat, b'', b).decode('utf8', 'replace').replace('\r', '')


def wait_quiet(limit, quiet):
    """Pump until output has arrived and then been silent for `quiet` s."""
    end = time.time() + limit
    while time.time() < end:
        if not pump(0.5):
            return False
        if buf and time.time() - last_data >= quiet:
            return True
    return True


alive = wait_quiet(60, 3)
if alive:
    line = os.environ.get('E2E_PANE_LINE') or 'pwd; echo PANE-OK-$$; exit'
    os.write(fd, line.encode() + b'\r')
    pump(float(os.environ.get('E2E_PANE_WAIT') or 8))

# Let the command end on its own after `exit`, else kill it.
status = 3
for _ in range(50):
    done, st = os.waitpid(pid, os.WNOHANG)
    if done:
        status = 0 if os.WIFEXITED(st) and os.WEXITSTATUS(st) == 0 else 3
        break
    time.sleep(0.2)
else:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)

print('probes seen:', ','.join(sorted(set(probes))) or 'none')
print('---- pane output ----')
print(clean(buf))
sys.exit(status)
