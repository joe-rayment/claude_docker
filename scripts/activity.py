#!/usr/bin/env python3
"""activity.py -- the activity panel's viewer (bin/activity).

A full-screen page that says, in plain English, what Claude Code is doing.
It only DISPLAYS <run>/activity/page.md (written by activity-summarize.py,
which is fed by activity-digest.py) and, while it is open, keeps that page
fresh. No panel open means no model calls.

Usage:
  activity                  full-screen panel (alternate screen, cursor
                            hidden, redrawn in place, never scrolls);
                            q or ctrl-c quits and restores the terminal
  activity --frame [--rows R] [--cols C] [--root DIR] [--color]
                            print exactly one frame to stdout and exit
                            (tests). Plain text unless --color or stdout is
                            a tty; R x C defaults to the tty, else 24 x 80.

Every frame is page.md re-wrapped to C columns and hard-truncated so the
whole frame is exactly R lines (a cut page ends in "..."), the last line
being a dim footer: "updated 40 s ago . <model> . q quits" (the fallback
reason, or a note about the summarizer, replaces the model name).

Cadence (the summarizer decides "unchanged" itself): it is run once at
start, then at most once per EVERY_S; when the digest's episode or its set
of running sources changes it is run at once, but never within MIN_GAP_S
of the last run. Every run adds one line to <run>/activity/panel.log saying
why it started (first run, cadence, a new request, or which source ids joined
or left the running set). Redraws when page.md or meta.json change, every
REDRAW_S, and on SIGWINCH.

Exit codes: 0 ok / quit; 2 bad arguments, no folder, or no terminal.

Environment seams:
  CLAUDE_ORCA_ROOT, PROJECT_DIR     the folder (else git toplevel of cwd)
  CLAUDE_ORCA_ACTIVITY_SUMMARIZE    summarizer to run
                                    (default $SCRIPT_DIR/activity-summarize.py)
  CLAUDE_ORCA_ACTIVITY_DIGEST       digest to run
                                    (default $SCRIPT_DIR/activity-digest.py)
  CLAUDE_ORCA_ACTIVITY_EVERY_S      summarizer cadence, default 60
  CLAUDE_ORCA_ACTIVITY_MIN_GAP_S    floor between two runs, default 20
  CLAUDE_ORCA_ACTIVITY_WATCH_S      digest poll interval, default 10
  CLAUDE_ORCA_ACTIVITY_REDRAW_S     idle redraw interval, default 10
"""
import argparse
import datetime
import json
import os
import re
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time
import tty
import unicodedata

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
READING = "Reading what Claude Code is doing..."
ELLIPSIS = "…"
SEP = " · "
DIM, RESET = "\x1b[2m", "\x1b[0m"
MAX_PAGE_BYTES = 65536
_CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")
_ESC_TEXT = re.compile(r"\x1b\[[0-9;:?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?")
_BULLET = re.compile(r"([-*•]|\d+[.)])\s")


def die(msg, code=2):
    print("activity: %s" % msg, file=sys.stderr)
    sys.exit(code)


def env_num(name, default):
    try:
        v = float(os.environ.get(name, ""))
    except ValueError:
        return default
    return v if v > 0 else default


# ---------------------------------------------------------------- text fit

def _cw(ch):
    """Display columns of one character: 0 combining/format, 2 wide, else 1."""
    if unicodedata.category(ch) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def dwidth(s):
    return sum(_cw(ch) for ch in s)


def cut(s, cols):
    """The longest prefix of s that fits in cols display columns."""
    w = 0
    for i, ch in enumerate(s):
        w += _cw(ch)
        if w > cols:
            return s[:i]
    return s


def wrap_line(line, cols):
    """One page line -> screen lines no wider than cols; blank stays blank."""
    line = line.expandtabs(4).rstrip()
    stripped = line.lstrip(" ")
    if not stripped:
        return [""]
    indent = " " * (len(line) - len(stripped))
    if len(indent) >= cols // 2:
        indent = ""
    hang = indent + ("  " if _BULLET.match(stripped) else "")
    if len(hang) >= cols // 2:
        hang = indent
    out, cur, has = [], indent, False
    for word in stripped.split():
        while dwidth(word) > cols - len(hang):    # longer than a whole line
            if has:
                out.append(cur)
                cur, has = hang, False
            head = cut(word, cols - dwidth(cur)) or word[:1]
            out.append(cur + head)
            cur = hang
            word = word[len(head):]
        if has and dwidth(cur) + 1 + dwidth(word) > cols:
            out.append(cur)
            cur, has = hang, False
        cur = cur + (" " if has else "") + word
        has = True
    if has:
        out.append(cur)
    return out


def wrap_page(text, cols):
    """The page as screen lines: control bytes dropped, blank lines kept."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = []
    text = _ESC_TEXT.sub("", text)
    for raw in _CTRL.sub("", text).split("\n"):
        lines.extend(wrap_line(raw, cols))
    while lines and lines[-1] == "":
        lines.pop()
    while lines and lines[0] == "":
        lines.pop(0)
    return lines


def ellipsize(line, cols):
    line = line.rstrip()
    if dwidth(line) + 1 <= cols:
        return line + ELLIPSIS
    return cut(line, cols - 1) + ELLIPSIS


# ------------------------------------------------------------------ footer

def parse_iso(s):
    try:
        d = datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return d.timestamp()


def age(secs):
    n = max(0, int(secs))
    if n < 60:
        return "%d s" % n
    if n < 3600:
        return "%d min" % (n // 60)
    return "%d h" % (n // 3600)


def build_footer(meta, page_mtime, note, now, cols):
    """'updated 40 s ago . <model|reason|note> . q quits', cut to cols."""
    stamp = parse_iso(meta.get("updated")) if meta.get("updated") else None
    if stamp is None:
        stamp = page_mtime
    when = "updated %s ago" % age(now - stamp) if stamp is not None else ""
    detail = note
    if not detail and meta.get("source") == "fallback":
        detail = meta.get("reason") or "no summary"
    if not detail and meta.get("model"):
        detail = str(meta["model"])
    detail = " ".join(_CTRL.sub(" ", str(detail)).split()) if detail else ""
    tail = "q quits"
    # Narrow window: shed the age first (the reason / model says more), then
    # cut what is left with an ellipsis; "q quits" is always the last word.
    for head in (SEP.join(p for p in (when, detail) if p), detail, when):
        if head and dwidth(head + SEP + tail) <= cols:
            return head + SEP + tail
    head = detail or when
    room = cols - dwidth(SEP + tail)
    if not head or room < 2:
        return cut(tail, cols)
    return cut(head, room - 1).rstrip() + ELLIPSIS + SEP + tail


def build_frame(state, rows, cols, now, color, note=""):
    """Exactly `rows` lines, none wider than `cols`; the last is the footer."""
    body = wrap_page(state["page"] if state["page"].strip() else READING, cols)
    avail = rows - 1
    if len(body) > avail:
        body = body[:avail]
        if body:
            body[-1] = ellipsize(body[-1], cols)
    body += [""] * (avail - len(body))
    foot = build_footer(state["meta"], state["mtime"], note, now, cols)
    return body + [DIM + foot + RESET if color else foot]


# ------------------------------------------------------------------- state

def find_root(arg):
    if arg:
        return os.path.abspath(arg)
    for var in ("CLAUDE_ORCA_ROOT", "PROJECT_DIR"):
        if os.environ.get(var):
            return os.environ[var]
    try:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=5)
        if top.returncode == 0 and top.stdout.strip():
            return top.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    die("cannot find the project folder (set CLAUDE_ORCA_ROOT or --root)")


def read_state(act_dir):
    """page.md + meta.json as data; `sig` changes when either file does."""
    state = {"page": "", "meta": {}, "mtime": None, "sig": ()}
    try:
        with open(os.path.join(act_dir, "page.md"), "rb") as f:
            st = os.fstat(f.fileno())
            state["page"] = f.read(MAX_PAGE_BYTES).decode("utf-8", "replace")
        state["mtime"] = st.st_mtime
        state["sig"] = (st.st_mtime_ns, st.st_size)
    except OSError:
        pass
    try:
        with open(os.path.join(act_dir, "meta.json"), "rb") as f:
            st = os.fstat(f.fileno())
            meta = json.loads(f.read(MAX_PAGE_BYTES).decode("utf-8", "replace"))
        if isinstance(meta, dict):
            state["meta"] = meta
        state["sig"] += (st.st_mtime_ns, st.st_size)
    except (OSError, ValueError):
        pass
    return state


def term_size(fd):
    try:
        c, r = os.get_terminal_size(fd)
    except OSError:
        r, c = 24, 80
    return max(2, r or 24), max(10, c or 80)


# ----------------------------------------------------------- the children

def command(path):
    """argv that runs a script file, or None when it is not there."""
    if not path or not os.path.isfile(path):
        return None
    if os.access(path, os.X_OK):
        return [path]
    return [sys.executable, "-I", path]


class Child:
    """A background process: no stdin, stdout kept in a temp file, own group."""

    def __init__(self, argv):
        self.out = tempfile.TemporaryFile()
        self.t0 = time.monotonic()
        try:
            self.proc = subprocess.Popen(
                argv, stdin=subprocess.DEVNULL, stdout=self.out,
                stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError:
            self.out.close()
            raise

    def done(self):
        return self.proc.poll() is not None

    def result(self):
        self.out.seek(0)
        text = self.out.read(262144).decode("utf-8", "replace")
        self.out.close()
        return self.proc.returncode, text

    def kill(self):
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except OSError:
                pass
        self.out.close()


class Panel:
    """Decides when to run the summarizer and what the footer should say."""

    def __init__(self, root):
        self.root = root
        self.act_dir = os.path.join(root, ".claude-dev", "run", "activity")
        self.sum_path = (os.environ.get("CLAUDE_ORCA_ACTIVITY_SUMMARIZE")
                         or os.path.join(SCRIPT_DIR, "activity-summarize.py"))
        self.dig_path = (os.environ.get("CLAUDE_ORCA_ACTIVITY_DIGEST")
                         or os.path.join(SCRIPT_DIR, "activity-digest.py"))
        self.every = env_num("CLAUDE_ORCA_ACTIVITY_EVERY_S", 60.0)
        self.gap = env_num("CLAUDE_ORCA_ACTIVITY_MIN_GAP_S", 20.0)
        self.watch = env_num("CLAUDE_ORCA_ACTIVITY_WATCH_S", 10.0)
        self.summ = self.digest = None
        self.last_call = None      # monotonic time the summarizer last started
        self.next_watch = 0.0
        self.seen = None           # (episode, running ids) the digest last saw
        self.urgent = False
        self.why = []              # what made the digest urgent since the last run
        self.note = ""

    def tick(self, now, rows, cols):
        if self.summ is not None and self.summ.done():
            rc, _ = self.summ.result()
            self.summ = None
            self.note = "" if rc == 0 else "summarizer failed (exit %d)" % rc
        self._watch(now)
        if self.summ is not None:
            return
        since = None if self.last_call is None else now - self.last_call
        due = since is None or since >= self.every
        if self.urgent and (since is None or since >= self.gap):
            due = True
        if not due or (since is not None and since < self.gap):
            return
        self._log_run("first run" if since is None else
                      ("cadence %ds" % self.every if since >= self.every else "; ".join(self.why)),
                      since)
        self.last_call, self.urgent, self.why = now, False, []
        argv = command(self.sum_path)
        if argv is None:
            self.note = "summarizer not installed (activity-summarize.py)"
            return
        argv += ["--rows", str(rows), "--cols", str(cols), "--root", self.root]
        try:
            self.summ = Child(argv)
            self.note = ""
        except OSError as e:
            self.note = "summarizer will not start (%s)" % (e.strerror or "error")

    def _watch(self, now):
        """Run the digest now and then; a new request/source makes us urgent."""
        if self.digest is not None:
            if self.digest.done():
                rc, text = self.digest.result()
                self.digest = None
                self._seen(text if rc == 0 else "")
            elif now - self.digest.t0 > 30:
                self.digest.kill()
                self.digest = None
        if self.digest is None and now >= self.next_watch:
            self.next_watch = now + self.watch
            argv = command(self.dig_path)
            if argv is not None:
                try:
                    self.digest = Child(argv + ["--json", "--root", self.root])
                except OSError:
                    pass

    def _seen(self, text):
        try:
            d = json.loads(text)
            key = (str(d.get("episode")), tuple(sorted(
                str(s.get("id")) for s in d.get("sources", [])
                if isinstance(s, dict) and s.get("state") == "running")))
        except (ValueError, AttributeError, TypeError):
            return
        if self.seen is not None and key != self.seen:
            self.urgent = True
            if key[0] != self.seen[0]:
                self.why.append("new request (episode %s -> %s)" % (self.seen[0], key[0]))
            else:
                old, new = set(self.seen[1]), set(key[1])
                self.why.append("running set changed +%s -%s" % (
                    sorted(i[-6:] for i in new - old), sorted(i[-6:] for i in old - new)))
            del self.why[:-3]
        self.seen = key

    def _log_run(self, reason, since):
        """One line in <run>/activity/panel.log per summarizer run: why it was started."""
        path = os.path.join(self.act_dir, "panel.log")
        line = "%s run reason=%s since_last=%s\n" % (
            datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            reason, "-" if since is None else "%ds" % since)
        try:
            os.makedirs(self.act_dir, exist_ok=True)
            if os.path.exists(path) and os.path.getsize(path) > 65536:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    keep = fh.readlines()[-100:]
                with open(path, "w", encoding="utf-8") as fh:
                    fh.writelines(keep)
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(line)
        except OSError:
            pass

    def close(self):
        for c in (self.summ, self.digest):
            if c is not None:
                c.kill()


# ------------------------------------------------------------- the screen

_ESC_SEQ = re.compile(rb"\x1b\[[0-9;:?<>=]*[ -/]*[@-~]|\x1b[P\]^_X][^\x1b\x07]*(?:\x07|\x1b\\)?")
_QUIT_KEYS = (b"\x1b[99;5u", b"\x1b[113u", b"\x1b[113;1u")


def wants_quit(data):
    """q / Q, ctrl-c (also as the kitty keyboard form); replies are ignored."""
    if any(k in data for k in _QUIT_KEYS):
        return True
    plain = _ESC_SEQ.sub(b"", data)
    return b"q" in plain or b"Q" in plain or b"\x03" in plain


def put(fd, text):
    data = text.encode("utf-8")
    while data:
        data = data[os.write(fd, data):]


def run_panel(root):
    if not (os.isatty(0) and os.isatty(1)):
        die("needs a terminal (use --frame to print one frame)")
    panel = Panel(root)
    redraw_s = env_num("CLAUDE_ORCA_ACTIVITY_REDRAW_S", 10.0)
    out = sys.stdout.fileno()
    rfd, wfd = os.pipe()
    os.set_blocking(rfd, False)
    os.set_blocking(wfd, False)
    flags = {"stop": False, "full": True}

    def on_stop(signum, frame):
        flags["stop"] = True

    def on_redraw(signum, frame):
        flags["full"] = True

    for sig, handler in ((signal.SIGINT, on_stop), (signal.SIGTERM, on_stop),
                         (signal.SIGHUP, on_stop), (signal.SIGWINCH, on_redraw),
                         (signal.SIGCONT, on_redraw), (signal.SIGTSTP, signal.SIG_IGN)):
        signal.signal(sig, handler)
    signal.set_wakeup_fd(wfd, warn_on_full_buffer=False)
    saved = termios.tcgetattr(0)
    try:
        tty.setcbreak(0)
        put(out, "\x1b[?1049h\x1b[?25l\x1b[?7l")     # alt screen, no cursor, no autowrap
        last_sig, last_draw = None, 0.0
        while not flags["stop"]:
            now = time.monotonic()
            rows, cols = term_size(out)
            panel.tick(now, rows, cols)
            state = read_state(panel.act_dir)
            sig = (state["sig"], rows, cols, panel.note)
            if flags["full"] or sig != last_sig or now - last_draw >= redraw_s:
                frame = build_frame(state, rows, cols, time.time(), True, panel.note)
                buf = ["\x1b[2J"] if flags["full"] else []
                buf += ["\x1b[%d;1H%s\x1b[K" % (i + 1, ln) for i, ln in enumerate(frame)]
                put(out, "".join(buf))
                flags["full"] = False
                last_sig, last_draw = sig, now
            ready, _, _ = select.select([0, rfd], [], [], 1.0)
            if rfd in ready:
                try:
                    os.read(rfd, 512)
                except OSError:
                    pass
            if 0 in ready:
                data = os.read(0, 256)
                if not data or wants_quit(data):
                    break
    except OSError:
        pass                      # the terminal went away mid-write: just clean up
    finally:
        panel.close()
        signal.set_wakeup_fd(-1)
        try:
            termios.tcsetattr(0, termios.TCSADRAIN, saved)
            put(out, "\x1b[0m\x1b[?7h\x1b[?1049l\x1b[?25h")
        except OSError:
            pass
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="activity", add_help=True,
                                 description="Plain-English view of what Claude Code is doing.")
    ap.add_argument("--frame", action="store_true", help="print one frame and exit")
    ap.add_argument("--rows", type=int)
    ap.add_argument("--cols", type=int)
    ap.add_argument("--root", help="project folder (default: CLAUDE_ORCA_ROOT, PROJECT_DIR, git)")
    ap.add_argument("--color", action="store_true", help="--frame: keep the dim footer escape")
    args = ap.parse_args(argv)
    for name in ("rows", "cols"):
        if getattr(args, name) is not None and getattr(args, name) < 1:
            ap.error("--%s must be at least 1" % name)
    if (args.rows or args.cols or args.color) and not args.frame:
        ap.error("--rows/--cols/--color only go with --frame")
    root = find_root(args.root)
    if not args.frame:
        return run_panel(root)
    if sys.stdout.isatty():
        rows, cols = term_size(sys.stdout.fileno())
    else:
        rows, cols = 24, 80
    rows, cols = args.rows or rows, args.cols or cols
    state = read_state(os.path.join(root, ".claude-dev", "run", "activity"))
    frame = build_frame(state, rows, max(1, cols), time.time(),
                        args.color or sys.stdout.isatty())
    sys.stdout.write("\n".join(frame) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
