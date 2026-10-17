#!/usr/bin/env python3
"""activity-digest.py -- what is Claude Code doing right now, as one small JSON object.

The deterministic first half of the activity panel (epic claude-orca-7rk): it reads
what Claude Code already writes -- this folder's session transcripts, the executors
and scouts a session spawned, and the headless workers under .claude-dev/run/workers
-- and condenses it to the current request plus a few lines per source. No model, no
network, read-only. P2 (activity-summarize.py) turns the digest into prose.

    activity-digest.py [--json|--text] [--root DIR] [--claude-dir DIR] [--now ISO]

  --json   (default) one JSON object: generated, root, episode, fingerprint,
           request, sources[], omitted. See "Fields" below.
  --text   the same facts as a plain page, a headline per source.
  --root   the folder (default: CLAUDE_ORCA_ROOT, else PROJECT_DIR, else the
           git top level of the cwd, else the cwd).
  --claude-dir  Claude's config dir (default: CLAUDE_CONFIG_DIR, else ~/.claude).
  --now    pretend it is this ISO time (tests); also parses every file instead of
           skipping the ones whose mtime is long past.

Exit: 0 whenever it can print (an empty folder gives "sources": []); 2 on bad args.

Fields
  episode      sha1(session|request time|request text)[:12], "none" with no session:
               changes exactly when a new human request starts, never on a tool call.
  fingerprint  sha1 over (id, last, state) of every kept source: changes when a
               source wrote something new or changed state; not on the passing of time.
  sources      running executors/workers (oldest started first), then the main
               session, then finished ones (newest first). A source is "running"
               while written within RUNNING_S, or while its newest assistant record
               is a tool call still awaiting its result (a long command is work in
               progress) -- or the model's answer to the last tool result -- for up
               to PENDING_S. "finished" = quiet and the last record is final assistant
               text; kept KEEP_S, then dropped. The main session is a source only
               while it is the newest-active session (its subagents count toward
               that); only that session's executors/scouts are listed.

Which user records are human prompts (learned from real transcripts, 2026-10):
  origin.kind == "human" with string content. NOT: tool results (content blocks of
  type tool_result, top-level toolUseResult), isMeta, origin.kind "task-notification"
  (rendered as an event from its <summary>), strings opening <system-reminder,
  <teammate-message, <agent-message or "Another Claude session sent a message".
  A slash-command wrapper counts as its <command-args> text, or nothing if empty.
  Records with no origin (sdk runs, older versions): a user record that is not meta,
  has no toolUseResult, is text, and does not start with "<".

Env seams: CLAUDE_ORCA_ROOT, PROJECT_DIR, CLAUDE_CONFIG_DIR,
  CLAUDE_ORCA_ACTIVITY_RUNNING_S (120), _KEEP_S (600), _PENDING_S (1800),
  _MAX_BYTES (32768, the output cap). python3 stdlib only.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys


def _env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


RUNNING_S = _env_int("CLAUDE_ORCA_ACTIVITY_RUNNING_S", 120)
KEEP_S = _env_int("CLAUDE_ORCA_ACTIVITY_KEEP_S", 600)
PENDING_S = _env_int("CLAUDE_ORCA_ACTIVITY_PENDING_S", 1800)
MAX_BYTES = _env_int("CLAUDE_ORCA_ACTIVITY_MAX_BYTES", 32768)
MAX_EVENTS = 40
WINDOWS = (1 << 18, 1 << 20, 1 << 22, 1 << 24, 1 << 26)  # tail reads: 256K .. 64M
NOT_HUMAN_PREFIXES = ("<system-reminder", "<teammate-message", "<agent-message",
                      "Another Claude session sent a message", "<local-command",
                      "<task-notification")

# ---------------------------------------------------------------- redaction
_KEY_RES = [
    re.compile(r"sk-or-[A-Za-z0-9_-]+"),
    re.compile(r"sk-ant-[A-Za-z0-9_-]+"),
    re.compile(r"gh[pos]_[A-Za-z0-9]+"),
    re.compile(r"github_pat_[A-Za-z0-9_]+"),
    re.compile(r"Bearer\s+[A-Za-z0-9._~+/=-]+"),
]
_ASSIGN_RE = re.compile(r"\b([A-Za-z][A-Za-z0-9_]*(?:API_KEY|TOKEN|SECRET|PASSWORD))=\S+")
_RUN_RE = re.compile(r"(?<![A-Za-z0-9_+=/-])[A-Za-z0-9_+=/-]{40,}(?![A-Za-z0-9_+=/-])")


def _long_run(m):
    s = m.group(0)
    if "/" in s:
        # a path, unless it is std-base64: mixed case + digit, and + or =
        ok = (re.search(r"[A-Z]", s) and re.search(r"[a-z]", s) and re.search(r"[0-9]", s)
              and re.search(r"[+=]", s))
        return "[redacted]" if ok and not s.startswith("/") else s
    return "[redacted]" if re.search(r"[0-9]", s) else s


def redact(s):
    if not s:
        return s
    for rx in _KEY_RES:
        s = rx.sub("[redacted]", s)
    s = _ASSIGN_RE.sub(r"\1=[redacted]", s)
    return _RUN_RE.sub(_long_run, s)


def clip(s, n):
    """Redact first, then flatten whitespace and cut to n chars (an ellipsis counts)."""
    s = " ".join(redact(s or "").split())
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


# ---------------------------------------------------------------- time
def parse_ts(s):
    if not s:
        return None
    try:
        s = s.replace("Z", "+00:00")
        t = dt.datetime.fromisoformat(s)
    except (ValueError, AttributeError):
        return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def iso(t):
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def hhmm(t):
    return t.astimezone().strftime("%H:%M")


def from_epoch(x):
    return dt.datetime.fromtimestamp(x, dt.timezone.utc)


# ---------------------------------------------------------------- reading transcripts
def read_tail(path, size):
    """Last ~size bytes as complete lines, and whether that reached the file start."""
    with open(path, "rb") as f:
        f.seek(0, 2)
        n = f.tell()
        start = max(0, n - size)
        f.seek(start)
        data = f.read()
    if start > 0:
        i = data.find(b"\n")
        data = data[i + 1:] if i >= 0 else b""
    return data.decode("utf-8", "replace").splitlines(), start == 0


def conv_records(lines):
    """Only user/assistant records; the huge api-request/attachment lines are skipped
    on a substring test, before any json.loads (their type key comes first)."""
    out = []
    for ln in lines:
        if ln.startswith('{"type":"') and not ln.startswith(('{"type":"user"', '{"type":"assistant"')):
            continue
        if '"type":"user"' not in ln and '"type":"assistant"' not in ln:
            continue
        try:
            r = json.loads(ln)
        except ValueError:
            continue
        if isinstance(r, dict) and r.get("type") in ("user", "assistant"):
            out.append(r)
    return out


def load_conv(path, need):
    """Grow the tail window until need(records) holds or the whole file is read."""
    recs = []
    for size in WINDOWS:
        lines, whole = read_tail(path, size)
        recs = conv_records(lines)
        if whole or need(recs):
            break
    return recs


def head_record(path):
    try:
        with open(path, "rb") as f:
            return json.loads(f.readline().decode("utf-8", "replace"))
    except (OSError, ValueError):
        return {}


def blocks(msg):
    c = (msg or {}).get("content")
    if isinstance(c, str):
        return [{"type": "text", "text": c}]
    return [b for b in c if isinstance(b, dict)] if isinstance(c, list) else []


def text_of(msg):
    return "\n".join(b.get("text", "") for b in blocks(msg) if b.get("type") == "text").strip()


def human_text(r):
    """The prompt text if this user record is a human's, else None (see header)."""
    if r.get("isMeta"):
        return None
    o = r.get("origin")
    kind = o.get("kind") if isinstance(o, dict) else None
    if kind is not None and kind != "human":
        return None
    if r.get("toolUseResult") is not None:
        return None
    bs = blocks(r.get("message"))
    if not bs or any(b.get("type") != "text" for b in bs):
        return None
    s = text_of(r.get("message"))
    if not s or s.startswith(NOT_HUMAN_PREFIXES):
        return None
    if "<command-name>" in s:
        m = re.search(r"<command-args>(.*?)</command-args>", s, re.S)
        s = m.group(1).strip() if m else ""
        return s or None
    if kind is None and s.startswith("<"):
        return None
    return s


# ---------------------------------------------------------------- events
class Events:
    """Ordered one-liners; runs of the same collapsing kind merge ("read 5 files")."""
    COLLAPSE = ("read", "search", "web", "todo")

    def __init__(self):
        self.items = []

    def add(self, kind, ts, text):
        if kind in self.COLLAPSE and self.items and self.items[-1]["k"] == kind:
            self.items[-1]["n"] += 1
            self.items[-1]["ts"] = ts
        else:
            self.items.append({"k": kind, "ts": ts, "text": text, "n": 1})

    def lines(self, limit=MAX_EVENTS):
        out = []
        for e in self.items[-limit:]:
            n = e["n"]
            t = e["text"]
            if e["k"] == "read":
                t = "read %d file%s" % (n, "" if n == 1 else "s")
            elif e["k"] == "search":
                t = "searched the code" + ("" if n == 1 else " %d times" % n)
            elif e["k"] == "web":
                t = "looked something up on the web" + ("" if n == 1 else " %d times" % n)
            pre = (hhmm(e["ts"]) + " ") if e["ts"] else ""
            out.append(clip(pre + t, 160))
        return out


def rel(p, root):
    p = p or "?"
    return p[len(root) + 1:] if root and p.startswith(root.rstrip("/") + "/") else p


def tool_event(name, inp, root):
    inp = inp if isinstance(inp, dict) else {}
    if name == "Bash":
        d = (inp.get("description") or "").strip()
        if d:
            return "ran", "ran: " + clip(d, 100)
        cmd = (inp.get("command") or "").strip().splitlines()
        return "ran", "ran: " + clip(cmd[0] if cmd else "", 80)
    if name in ("Edit", "MultiEdit", "NotebookEdit"):
        return "edit", "edited " + clip(rel(inp.get("file_path") or inp.get("notebook_path"), root), 80)
    if name == "Write":
        return "write", "wrote " + clip(rel(inp.get("file_path"), root), 80)
    if name == "Read":
        return "read", ""
    if name in ("Glob", "Grep", "LS"):
        return "search", ""
    if name in ("TodoWrite", "TaskCreate", "TaskUpdate"):
        return "todo", "updated its to-do list"
    if name in ("WebFetch", "WebSearch"):
        return "web", ""
    if name in ("Agent", "Task"):
        return "agent", "started %s: %s" % (inp.get("subagent_type") or "agent",
                                             clip(inp.get("description") or inp.get("prompt") or "", 100))
    return "tool", "used " + clip(name.split("__")[-1], 40)


def result_text(b):
    c = b.get("content")
    if isinstance(c, list):
        c = "\n".join(x.get("text", "") for x in c if isinstance(x, dict))
    return c if isinstance(c, str) else ""


# ---------------------------------------------------------------- one transcript -> facts
def analyze(recs, root, reset_on_human):
    """Walk conversation records in order. With reset_on_human (the main session) a
    human prompt restarts the story: request set, events/pending cleared."""
    st = {"request": None, "ev": Events(), "open": {}, "names": {}, "last": None,
          "last_kind": None, "final": None, "model": None, "first": None}
    for r in recs:
        ts = parse_ts(r.get("timestamp"))
        if ts:
            st["first"] = st["first"] or ts
            if st["last"] is None or ts > st["last"]:
                st["last"] = ts
        msg = r.get("message") or {}
        if r["type"] == "user":
            st["last_kind"], st["final"] = "user", None
            o = r.get("origin")
            if isinstance(o, dict) and o.get("kind") == "task-notification":
                m = re.search(r"<summary>(.*?)</summary>", text_of(msg), re.S)
                st["ev"].add("note", ts, "background task: " + clip(m.group(1) if m else "finished", 120))
                continue
            ht = human_text(r)
            if ht is not None:
                if reset_on_human:
                    st["request"], st["ev"], st["open"] = (ts, ht), Events(), {}
                continue
            for b in blocks(msg):
                if b.get("type") != "tool_result":
                    continue
                tid = b.get("tool_use_id")
                st["open"].pop(tid, None)
                if b.get("is_error"):
                    first = next((x for x in result_text(b).splitlines() if x.strip()), "")
                    what = "a command failed" if st["names"].get(tid) == "Bash" else "a tool call failed"
                    st["ev"].add("fail", ts, "%s: %s" % (what, clip(first, 100)))
        else:
            st["last_kind"] = "assistant"
            m = msg.get("model")
            if m and not m.startswith("<"):
                st["model"] = m
            for b in blocks(msg):
                bt = b.get("type")
                if bt == "text" and (b.get("text") or "").strip():
                    st["ev"].add("said", ts, "said: " + clip(b["text"], 120))
                    st["final"] = b["text"].strip()
                elif bt == "tool_use":
                    st["final"] = None
                    st["open"][b.get("id")] = ts
                    st["names"][b.get("id")] = b.get("name", "")
                    k, t = tool_event(b.get("name", ""), b.get("input"), root)
                    st["ev"].add(k, ts, t)
    st["inflight"] = bool(st["open"]) or st["last_kind"] == "user"
    return st


def state_of(last, inflight, final, now):
    """running / finished / None (dropped). The rule is in the header."""
    if last is None:
        return None
    age = max(0.0, (now - last).total_seconds())
    if age <= RUNNING_S or (inflight and age <= PENDING_S):
        return "running"
    if final and not inflight and age <= KEEP_S:
        return "finished"
    return None


def first_line(s):
    return next((x for x in (s or "").splitlines() if x.strip()), "")


def load_subagents(sdir, root, live_cut):
    """Executors/scouts a session spawned: <sess>/subagents/agent-<id>.{jsonl,meta.json}."""
    out = []
    try:
        names = sorted(os.listdir(sdir))
    except OSError:
        return out
    for fn in names:
        if not (fn.startswith("agent-") and fn.endswith(".jsonl")):
            continue
        p = os.path.join(sdir, fn)
        try:
            if live_cut is not None and os.path.getmtime(p) < live_cut:
                continue
            with open(p[:-6] + ".meta.json") as mf:
                meta = json.load(mf)
        except (OSError, ValueError):
            meta = {}
        try:
            recs = load_conv(p, lambda rs: len(rs) >= 80)
        except OSError:
            continue
        st = analyze(recs, root, False)
        head = head_record(p)
        task = text_of(head.get("message")) if head.get("type") == "user" else ""
        at = meta.get("agentType")
        out.append({
            "id": fn[:-6], "kind": at if at in ("executor", "scout") else "agent",
            "title": clip(meta.get("description") or first_line(task) or fn[:-6], 100),
            "model": st["model"] or meta.get("model"), "started": parse_ts(head.get("timestamp")) or st["first"],
            "task": clip(task, 600), "st": st})
    return out
