#!/usr/bin/env python3
"""Run one command on a real pseudo-terminal, poke it on a timetable, keep its bytes.

A test helper (tests/activity-viewer.bats uses it): a full-screen program
cannot be checked from a pipe, so this gives it a real tty of a chosen
size, sends keys / signals / a resize after N seconds, and writes every
byte the program printed to a file for the test to look at.

usage: pty-drive.py --out FILE [--rows R] [--cols C] [--timeout S]
                    [--at SECONDS:ACTION]... -- COMMAND [ARGS...]
  ACTION  send:TEXT    type TEXT (Python escapes: send:q, send:\\x03)
          sig:NAME     signal the command (sig:TERM, sig:WINCH, sig:HUP)
          resize:RxC   change the terminal size, then tell the command
The command inherits this process's environment.
exit:   the command's own exit status (128+N if a signal killed it);
        124 when --timeout (default 20 s) ran out and it was killed.
"""
import argparse
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time


def set_size(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def parse_at(spec):
    when, _, action = spec.partition(":")
    kind, _, arg = action.partition(":")
    if kind not in ("send", "sig", "resize") or not when:
        raise SystemExit("pty-drive: bad --at %r" % spec)
    return float(when), kind, arg


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--rows", type=int, default=24)
    ap.add_argument("--cols", type=int, default=80)
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--at", action="append", default=[])
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    cmd = args.cmd[1:] if args.cmd[:1] == ["--"] else args.cmd
    if not cmd:
        raise SystemExit("pty-drive: no command")
    steps = sorted(parse_at(s) for s in args.at)

    pid, master = pty.fork()
    if pid == 0:
        try:
            os.execvp(cmd[0], cmd)
        finally:
            os._exit(127)
    set_size(master, args.rows, args.cols)
    t0 = time.monotonic()
    status = None
    with open(args.out, "wb") as out:
        while True:
            now = time.monotonic() - t0
            while steps and steps[0][0] <= now:
                _, kind, arg = steps.pop(0)
                if kind == "send":
                    os.write(master, arg.encode().decode("unicode_escape").encode("latin-1"))
                elif kind == "sig":
                    os.kill(pid, getattr(signal, "SIG" + arg.upper()))
                else:
                    rows, _, cols = arg.partition("x")
                    set_size(master, int(rows), int(cols))
                    os.kill(pid, signal.SIGWINCH)
            if status is None:
                done, st = os.waitpid(pid, os.WNOHANG)
                if done:
                    status = st
            if status is not None:
                wait = 0.2           # child gone: drain what is left, then stop
            elif now >= args.timeout:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
                status = -1
                continue
            else:
                wait = min(0.1, steps[0][0] - now) if steps else 0.1
                wait = max(wait, 0.0)
            ready, _, _ = select.select([master], [], [], wait)
            if ready:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    data = b""
                if data:
                    out.write(data)
                    out.flush()
                    continue
            if status is not None:
                break
    if status == -1:
        return 124
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


if __name__ == "__main__":
    sys.exit(main())
