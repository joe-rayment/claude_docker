#!/usr/bin/env python3
"""activity-summarize.py -- turn the activity digest into a one-page, plain-English
status panel (claude-orca-7rk.2, slice P2 of the activity panel).

Reads the digest (scripts/activity-digest.py --json, or --digest FILE), asks a
cheap model through the OpenRouter guard to write the page, and writes it
atomically to <run>/activity/page.md with <run>/activity/meta.json beside it.
The viewer (bin/activity) only reads those two files.

    activity-summarize.py [--rows R] [--cols C] [--root DIR] [--digest FILE] [--force]

Prints exactly one status word on stdout:
    updated    a model wrote a new page
    unchanged  the digest's fingerprint matches meta.json; nothing was called
    busy       another summarizer holds <run>/activity/summarize.lock
    fallback   no model page: the deterministic digest text was written, and
               meta.json says why in plain words (reason)
Exit 0 for all four; 2 on bad arguments or an unreadable --digest FILE.

The page is at most R-2 lines of at most C characters (default R=24, C=80),
plain text only. A failed call (guard down, refused, timeout, empty reply)
writes the fallback page and pauses model calls for 300 s (meta.backoff_until).
Every call adds one line to <run>/activity/calls.log: time, model, http
status, tokens, cost, duration -- never the content, never the token.

Where things come from (read as data, never executed):
    folder      --root, else CLAUDE_ORCA_ROOT, else PROJECT_DIR, else the git
                top level of the cwd; run dir = <folder>/.claude-dev/run
    token       OPENROUTER_API_KEY (the GUARD token), else <run>/openrouter-guard.token
    base URL    CLAUDE_ORCA_ACTIVITY_URL, else OPENROUTER_BASE_URL, else
                http://127.0.0.1:4141/api/v1 -- must be a loopback address:
                the token is never sent anywhere else
    model       CLAUDE_ORCA_ACTIVITY_MODEL, else "activityModel" in
                <folder>/.claude-dev/claude-orca.json, else the glm-flash route in
                <template>/config/delegate-routes.json (leading "openrouter/" dropped)
    switch      "activity": false in claude-orca.json = never call a model
Other env seams: CLAUDE_ORCA_ACTIVITY_DIGEST (path of the digest script),
CLAUDE_ORCA_ACTIVITY_BACKOFF_S (default 300), CLAUDE_ORCA_ACTIVITY_TIMEOUT_S (45).
"""
import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
TEMPLATE_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_URL = "http://127.0.0.1:4141/api/v1"
DEFAULT_ROUTE = "glm-flash"
MAX_TOKENS = 600
TEMPERATURE = 0.2
LOOPBACK = ("127.0.0.1", "localhost", "::1")
CALLS_LOG_MAX = 256 * 1024

SECRET_PATTERNS = (
    re.compile(r"sk-or-[A-Za-z0-9_-]+"),
    re.compile(r"sk-ant-[A-Za-z0-9_-]+"),
    re.compile(r"\b(?:ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]+"),
    re.compile(r"github_pat_[A-Za-z0-9_]+"),
    re.compile(r"\bBearer\s+\S+", re.IGNORECASE),
)
LONG_RUN = re.compile(r"[A-Za-z0-9+/=_-]{40,}")


def note(msg):
    sys.stderr.write("activity-summarize: %s\n" % msg)


def die(msg, code=2):
    note(msg)
    sys.exit(code)


def now_utc():
    return datetime.now(timezone.utc)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(text):
    if not isinstance(text, str):
        return None
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        pass
    try:  # fractional seconds or an explicit offset, as another script may write them
        dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def redact_text(text, extra=()):
    """Second line of defence: P1 redacts already, this does not trust it."""
    for secret in extra:
        if secret:
            text = text.replace(secret, "[redacted]")
    for pat in SECRET_PATTERNS:
        text = pat.sub("[redacted]", text)

    def long_run(m):
        run = m.group(0)
        if "/" in run and not re.search(r"[+=]", run):
            return run  # a path (dir/dir/agent-abc123...), not base64: keep it readable
        mixed = re.search(r"\d", run) and re.search(r"[A-Za-z]", run)
        return "[redacted]" if mixed else run
    return LONG_RUN.sub(long_run, text)


def redact_obj(obj, extra=()):
    if isinstance(obj, str):
        return redact_text(obj, extra)
    if isinstance(obj, list):
        return [redact_obj(x, extra) for x in obj]
    if isinstance(obj, dict):
        return {k: redact_obj(v, extra) for k, v in obj.items()}
    return obj


def resolve_root(arg):
    for cand in (arg, os.environ.get("CLAUDE_ORCA_ROOT"), os.environ.get("PROJECT_DIR")):
        if cand:
            return os.path.abspath(cand)
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True,
                             text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        out = ""
    return out or None


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def atomic_write(path, text):
    """Write beside the target and rename over it: a reader sees the old file
    or the whole new one, never half of either."""
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def pick_model(config, root):
    env = os.environ.get("CLAUDE_ORCA_ACTIVITY_MODEL", "").strip()
    if env:
        return env
    mod = config.get("activityModel")
    if isinstance(mod, str) and mod.strip():
        return mod.strip()
    routes = read_json(os.path.join(TEMPLATE_DIR, "config", "delegate-routes.json")) or {}
    route = (routes.get("routes") or {}).get(DEFAULT_ROUTE) or {}
    model = route.get("model") if isinstance(route, dict) else None
    if isinstance(model, str) and model.strip():
        return re.sub(r"^openrouter/", "", model.strip())
    return None


def pick_token(rundir):
    tok = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if tok:
        return tok
    try:
        with open(os.path.join(rundir, "openrouter-guard.token"), encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def load_digest(path, root):
    """(digest dict | None, came_from_p1, why-not)."""
    if path:
        data = read_json(path)
        if data is None:
            die("--digest %s is not a readable JSON object" % path)
        return data, False, None
    script = os.environ.get("CLAUDE_ORCA_ACTIVITY_DIGEST") or os.path.join(SCRIPT_DIR, "activity-digest.py")
    try:
        out = subprocess.run([sys.executable, script, "--json", "--root", root],
                             capture_output=True, text=True, timeout=60)
        data = json.loads(out.stdout) if out.returncode == 0 else None
    except (OSError, ValueError, subprocess.SubprocessError):
        data = None
    if not isinstance(data, dict):
        return None, True, "the activity digest could not be read"
    return data, True, None


# --- the page: plain text, inside the budget ---------------------------------

LABEL = re.compile(r"^(Done|Now|Next|Finished):")


def clean_line(line):
    """No control characters (a stray escape must never reach a terminal), no
    markdown syntax. Returns one plain line."""
    line = re.sub(r"[\x00-\x08\x0b-\x1f\x7f\x80-\x9f]", "", line.replace("\t", " "))
    line = re.sub(r"^\s*(?:`{3,}.*|-{3,}|\*{3,}|_{3,})\s*$", "", line)
    line = re.sub(r"^\s*#{1,6}\s*", "", line)
    line = re.sub(r"^\s*>+\s?", "", line)
    line = re.sub(r"^(\s*)(?:[-*+•]|\d{1,2}[.)])\s+", r"\1", line)
    line = re.sub(r"(\*\*|__|~~|`)", "", line)
    line = re.sub(r"(?<![\w*])\*(?=\S)|(?<=\S)\*(?![\w*])", "", line)
    return line.strip()


def shape_page(text, rows, cols):
    """Clean, wrap to cols, collapse blank runs, cut whole trailing lines to rows-2."""
    limit = max(1, rows - 2)
    out = []
    for raw in (text or "").splitlines():
        line = clean_line(raw)
        if not line:
            if out and out[-1] != "":
                out.append("")
            continue
        indent = "  " if LABEL.match(line) else ""
        out.extend(textwrap.wrap(line, width=cols, subsequent_indent=indent,
                                 break_long_words=True, break_on_hyphens=False) or [""])
    while out and out[-1] == "":
        out.pop()
    out = out[:limit]
    while out and out[-1] == "":
        out.pop()
    return "\n".join(out) + "\n" if out else ""


def elapsed_words(seconds):
    if seconds < 90:
        return "%d s" % max(0, int(seconds))
    if seconds < 90 * 60:
        return "%d min" % int(round(seconds / 60.0))
    return "%.1f h" % (seconds / 3600.0)


def render_text(digest):
    """The deterministic page: one headline per source (title, state, how long, last event)."""
    gen = parse_iso(digest.get("generated")) or now_utc()
    lines = []
    req = digest.get("request")
    if isinstance(req, dict) and req.get("text"):
        lines.append("Asked: " + str(req["text"])[:150])
    sources = [s for s in (digest.get("sources") or []) if isinstance(s, dict)]
    for src in sources:
        started = parse_iso(src.get("started"))
        span = " %s" % elapsed_words((gen - started).total_seconds()) if started else ""
        head = "%s (%s%s)" % (src.get("title") or src.get("id") or "work", src.get("state") or "?", span)
        events = src.get("events") or []
        last = events[-1] if events else (src.get("final") or "")
        lines.append(head + (": " + str(last) if last else ""))
    if not sources:
        lines.append("Nothing is running right now.")
    return "\n".join(lines)


# --- the model call -------------------------------------------------------------

def system_prompt(rows, cols):
    n = max(1, rows - 2)
    return (
        "You write the status panel a person glances at while Claude Code works in the next "
        "window. The person is not reading the code. In a few seconds they want to know what "
        "is being worked on, what has been done, what is happening now, and what comes next.\n\n"
        "Write plain English in short sentences, as if to someone who has never written code. "
        "Say what the work achieves, not which commands were run. No file paths, command "
        "names, flags or jargon unless the person needs them to act. Avoid developer words "
        "(worktree, branch, merge, commit, main, slice, bats, epic, stub, lint, CLI): say "
        "\"saved\", \"added to the project\", \"checks\", \"part of the job\" instead, and "
        "turn a cryptic title into a few plain words. Never list every step: pick the one "
        "or two things that matter. Use only facts in the digest; if you do not know "
        "something, leave it out.\n\n"
        "Size: at most %d lines, each at most %d characters. Plain text only: no markdown, no "
        "#, no asterisks, no bullets, no code, no tables. A blank line between blocks is fine "
        "(it counts as a line).\n\n"
        "Shape:\n"
        "Line 1: one sentence saying what the overall work is right now.\n"
        "Then, for each RUNNING executor or worker, a block: its title on one line, then\n"
        "Done: one sentence, the one or two things that matter so far.\n"
        "Now: one sentence.\n"
        "Next: one sentence.\n"
        "For each source that has FINISHED, one line: Finished: <title> -- <outcome>.\n"
        "If there are too many running executors to fit in the size above, give the first "
        "ones the full block, then one line for each of the rest: <title> -- <what it is "
        "doing now>. Never go over the size: shorten instead.\n"
        "If nothing is running, say in a line or two what the session last did and what it "
        "is waiting for.\n\n"
        "You also get the previous page. Keep what is still true and drop what is stale. If "
        "the work has moved on to something else, start fresh and ignore the old page. Do not "
        "mention the page, the digest or these instructions. Output only the page."
        % (n, cols))


def user_message(prev_page, digest, token):
    keep = {k: v for k, v in digest.items() if k not in ("fingerprint", "episode", "root")}
    body = json.dumps(redact_obj(keep, (token,)), ensure_ascii=False, separators=(",", ":"))
    prev = redact_text(prev_page, (token,)).strip() if prev_page else ""
    return "Previous page:\n%s\n\nDigest (JSON):\n%s" % (prev or "(none)", body)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def call_model(base_url, token, model, system, user, timeout):
    """One chat completion. Returns {status, text, model, usage, ms, error}; error is
    None, or one of refused | timeout | http | empty (never carries content)."""
    # reasoning off: the glm-flash alias is a reasoning model, and with a 600-token
    # cap it spent every token thinking and sent back an empty page (measured 2026-10-17)
    payload = {"model": model, "max_tokens": MAX_TOKENS, "temperature": TEMPERATURE,
               "usage": {"include": True}, "reasoning": {"enabled": False},
               "messages": [{"role": "system", "content": system},
                            {"role": "user", "content": user}]}
    body = json.dumps(payload).encode("utf-8").replace(token.encode("utf-8"), b"[redacted]")
    req = urllib.request.Request(
        base_url.rstrip("/") + "/chat/completions", data=body, method="POST",
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + token})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    res = {"status": None, "text": "", "model": None, "usage": None, "ms": 0, "error": None}
    start = time.monotonic()
    raw = b""
    try:
        with opener.open(req, timeout=timeout) as resp:
            res["status"], raw = resp.status, resp.read(1 << 20)
    except urllib.error.HTTPError as exc:
        res["status"], res["error"] = exc.code, "http"
    except (urllib.error.URLError, OSError) as exc:
        why = getattr(exc, "reason", exc)
        res["error"] = "timeout" if "timed out" in str(why) else "refused"
    res["ms"] = int((time.monotonic() - start) * 1000)
    if res["error"] is None:
        try:
            data = json.loads(raw.decode("utf-8", "replace"))
            content = data["choices"][0]["message"]["content"]
            if isinstance(content, list):
                content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
            res["text"] = content if isinstance(content, str) else ""
            res["model"] = data.get("model") if isinstance(data.get("model"), str) else None
            res["usage"] = data.get("usage") if isinstance(data.get("usage"), dict) else None
        except (ValueError, KeyError, IndexError, TypeError, AttributeError):
            pass
        if not res["text"].strip():
            res["error"] = "empty"
    return res


def log_call(actdir, model, res):
    usage = res.get("usage") or {}

    def val(key):
        return str(usage[key]) if isinstance(usage.get(key), (int, float)) else "-"
    line = "%s model=%s status=%s prompt_tokens=%s completion_tokens=%s cost=%s duration_ms=%d%s\n" % (
        iso(now_utc()), model, res["status"] if res["status"] is not None else "-",
        val("prompt_tokens"), val("completion_tokens"), val("cost"), res["ms"],
        " error=%s" % res["error"] if res["error"] else "")
    path = os.path.join(actdir, "calls.log")
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line)
        if os.path.getsize(path) > CALLS_LOG_MAX:
            with open(path, encoding="utf-8") as fh:
                tail = fh.readlines()[-1000:]
            atomic_write(path, "".join(tail))
    except OSError:
        pass


def failure_reason(res, timeout):
    if res["error"] == "refused":
        return "the summary service (guard) is not answering"
    if res["error"] == "timeout":
        return "the summary service did not answer within %d s" % timeout
    if res["error"] == "http":
        return "the summary service refused the request (HTTP %s)" % res["status"]
    return "the summary model sent back nothing usable"


# --- one run ----------------------------------------------------------------------

def env_int(name, default):
    try:
        return max(1, int(os.environ.get(name, "")))
    except ValueError:
        return default


def fallback_page(digest, from_p1, why, root, rows, cols, token):
    """The deterministic page: P1's own --text when the digest came from P1, else
    rendered here from the digest we were given."""
    text = ""
    if digest is None:
        text = "Could not read what Claude Code is doing right now.\n(%s)" % why
    elif from_p1:
        script = os.environ.get("CLAUDE_ORCA_ACTIVITY_DIGEST") or os.path.join(SCRIPT_DIR, "activity-digest.py")
        try:
            out = subprocess.run([sys.executable, script, "--text", "--root", root],
                                 capture_output=True, text=True, timeout=60)
            text = out.stdout if out.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            text = ""
    if digest is not None and not text.strip():
        text = render_text(digest)
    page = shape_page(redact_text(text, (token,)), rows, cols)
    return page or "Nothing to show yet.\n"


def decide(args, root, actdir, config, digest, why, meta, in_backoff, token):
    """(kind, page, fields): kind is updated|fallback; fields feed meta.json."""
    from_p1 = not args.digest
    fields = {"model": None, "reason": None, "usage": None, "backoff_until": None}
    reason = None
    model = pick_model(config, root)
    base = (os.environ.get("CLAUDE_ORCA_ACTIVITY_URL") or os.environ.get("OPENROUTER_BASE_URL")
            or DEFAULT_URL)
    host = urllib.parse.urlparse(base).hostname
    sources = (digest or {}).get("sources")
    if config.get("activity") is False:
        reason = "turned off in claude-orca.json"
    elif digest is None:
        reason = why
    elif not sources and not digest.get("request"):
        reason = "nothing to summarize yet"
    elif in_backoff and not args.force:
        reason = meta.get("reason") or "the summary service failed a moment ago; trying again soon"
        fields["backoff_until"] = meta.get("backoff_until")
    elif not model:
        reason = "no summary model is configured"
    elif not token:
        reason = "no guard token is available for the summary model"
    elif host not in LOOPBACK:
        reason = "the summary service address is not a local guard; the token is not sent elsewhere"
    if reason is None:
        timeout = env_int("CLAUDE_ORCA_ACTIVITY_TIMEOUT_S", 45)
        prev = ""
        if meta.get("source") == "model" and meta.get("episode") == digest.get("episode"):
            try:
                with open(os.path.join(actdir, "page.md"), encoding="utf-8") as fh:
                    prev = fh.read()
            except OSError:
                prev = ""
        res = call_model(base, token, model, system_prompt(args.rows, args.cols),
                         user_message(prev, digest, token), timeout)
        log_call(actdir, model, res)
        page = shape_page(redact_text(res["text"], (token,)), args.rows, args.cols) if not res["error"] else ""
        if page:
            fields.update(model=res["model"] or model, usage=res["usage"])
            return "updated", page, fields
        reason = failure_reason(res, timeout) if res["error"] else failure_reason({"error": "empty"}, timeout)
        wait = env_int("CLAUDE_ORCA_ACTIVITY_BACKOFF_S", 300)
        fields["backoff_until"] = iso(now_utc() + timedelta(seconds=wait))
    fields["reason"] = reason
    return "fallback", fallback_page(digest, from_p1, why, root, args.rows, args.cols, token), fields


def run(args, root, actdir):
    rundir = os.path.join(root, ".claude-dev", "run")
    config = read_json(os.path.join(root, ".claude-dev", "claude-orca.json")) or {}
    digest, from_p1, why = load_digest(args.digest, root)
    meta = read_json(os.path.join(actdir, "meta.json")) or {}
    until = parse_iso(meta.get("backoff_until"))
    in_backoff = bool(until and now_utc() < until)
    fp = digest.get("fingerprint") if digest else None
    same = (fp is not None and fp == meta.get("fingerprint")
            and meta.get("rows") == args.rows and meta.get("cols") == args.cols
            and os.path.exists(os.path.join(actdir, "page.md")))
    if same and not args.force and (meta.get("source") == "model" or in_backoff):
        return "unchanged"
    token = pick_token(rundir)
    kind, page, fields = decide(args, root, actdir, config, digest, why, meta, in_backoff, token)
    out = {"updated": iso(now_utc()), "episode": digest.get("episode") if digest else None,
           "fingerprint": fp, "model": fields["model"],
           "source": "model" if kind == "updated" else "fallback",
           "reason": fields["reason"], "usage": fields["usage"],
           "rows": args.rows, "cols": args.cols, "backoff_until": fields["backoff_until"]}
    atomic_write(os.path.join(actdir, "page.md"), page)
    atomic_write(os.path.join(actdir, "meta.json"), json.dumps(out, indent=2) + "\n")
    return kind


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="activity-summarize.py",
        description="Write the activity panel's one-page status (page.md + meta.json).")
    ap.add_argument("--rows", type=int, default=24, help="terminal rows; the page is at most rows-2 lines")
    ap.add_argument("--cols", type=int, default=80, help="terminal columns; lines are at most this long")
    ap.add_argument("--root", help="project folder (default: CLAUDE_ORCA_ROOT, PROJECT_DIR, git top level)")
    ap.add_argument("--digest", metavar="FILE", help="read this digest JSON instead of running the digest script")
    ap.add_argument("--force", action="store_true", help="summarize even if nothing changed")
    args = ap.parse_args(argv)
    if args.rows < 4 or args.cols < 20:
        die("--rows must be at least 4 and --cols at least 20")
    root = resolve_root(args.root)
    if not root:
        die("cannot tell which folder to read: pass --root, or set CLAUDE_ORCA_ROOT / PROJECT_DIR")
    actdir = os.path.join(root, ".claude-dev", "run", "activity")
    try:
        os.makedirs(actdir, exist_ok=True)
        lock = open(os.path.join(actdir, "summarize.lock"), "a")
    except OSError as exc:
        die("cannot use %s: %s" % (actdir, exc.strerror), 1)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("busy")
        return 0
    try:
        word = run(args, root, actdir)
    except OSError as exc:
        die("cannot write under %s: %s" % (actdir, exc.strerror), 1)
    print(word)
    return 0


if __name__ == "__main__":
    sys.exit(main())
