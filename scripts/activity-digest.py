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
  --claude-dir  Claude's config dir (default: CLAUDE_CONFIG_DIR, else .claude under HOME).
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


def _judge(s):
    """One piece of a long run: a key becomes [redacted], a path or a word stays."""
    if len(s) < 40:
        return s
    if "/" in s:
        # a path, unless it is std-base64: mixed case + digit, and + or =
        ok = (re.search(r"[A-Z]", s) and re.search(r"[a-z]", s) and re.search(r"[0-9]", s)
              and re.search(r"[+=]", s))
        return "[redacted]" if ok and not s.startswith("/") else s
    return "[redacted]" if re.search(r"[0-9]", s) else s


def _long_run_str(s):
    # std-base64 has "=" only as trailing padding, so an "=" before that is an
    # assignment (S=/tmp/...) or a path, never one key: judge each side alone.
    if "=" in s.rstrip("="):
        head, _, val = s.partition("=")
        return _judge(head) + "=" + _long_run_str(val)
    return _judge(s)


def _long_run(m):
    return _long_run_str(m.group(0))


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


# ---------------------------------------------------------------- workers
def pid_alive(pid):
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:  # a zombie answers kill(0) but is not working
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(")", 1)[-1].split()[0] != "Z"
    except (OSError, IndexError):
        return True


OC_TOOLS = {"bash": "Bash", "edit": "Edit", "write": "Write", "read": "Read", "grep": "Grep",
            "glob": "Glob", "list": "LS", "todowrite": "TodoWrite", "webfetch": "WebFetch",
            "task": "Task", "patch": "Edit", "multiedit": "MultiEdit"}


def _line_ts(obj):
    """A worker log line's own time: epoch ms (opencode) or ISO text, else None."""
    t = obj.get("timestamp")
    if isinstance(t, (int, float)) and t > 1e9:
        return from_epoch(t / 1000.0 if t > 1e11 else t)
    return parse_ts(t) if isinstance(t, str) else None


def _asst(ts, content, model=None):
    return {"type": "assistant", "timestamp": iso(ts) if ts else None,
            "message": {"model": model, "content": content}}


def _tool_result(ts, tid, err, text):
    return {"type": "user", "timestamp": iso(ts) if ts else None,
            "message": {"content": [{"type": "tool_result", "tool_use_id": tid,
                                     "is_error": bool(err), "content": text}]}}


def worker_records(objs, agent):
    """Worker log events -> transcript-shaped records, so analyze() reads all four
    kinds of worker the same way. objs = [(ts, event)]; also returns the result text."""
    recs, result = [], None
    for n, (ts, o) in enumerate(objs):
        t = o.get("type")
        if t in ("assistant", "user") and isinstance(o.get("message"), dict):
            r = dict(o)  # claude stream-json: already transcript-shaped
            r["timestamp"] = iso(ts) if ts else None
            if t == "user" and o.get("toolUseResult") is None and \
                    not any(b.get("type") == "tool_result" for b in blocks(o["message"])):
                continue  # the spec echoed back is not a new request
            recs.append(r)
        elif t == "result" and isinstance(o.get("result"), str):
            result = o["result"]
        elif t == "text" and isinstance(o.get("part"), dict):  # opencode
            recs.append(_asst(ts, [{"type": "text", "text": o["part"].get("text", "")}]))
        elif t == "tool_use" and isinstance(o.get("part"), dict):
            p = o["part"]
            stt = p.get("state") if isinstance(p.get("state"), dict) else {}
            inp = dict(stt.get("input") or {})
            if "filePath" in inp and "file_path" not in inp:
                inp["file_path"] = inp["filePath"]
            tid = p.get("callID") or "w%d" % n
            nm = OC_TOOLS.get(str(p.get("tool", "")).lower(), str(p.get("tool", "")) or "tool")
            recs.append(_asst(ts, [{"type": "tool_use", "id": tid, "name": nm, "input": inp}]))
            if stt.get("status") == "error":
                recs.append(_tool_result(ts, tid, True, str(stt.get("error") or stt.get("output") or "")))
            elif stt.get("status") in ("completed", "error"):
                recs.append(_tool_result(ts, tid, False, ""))
        elif t == "item.completed" and isinstance(o.get("item"), dict):  # codex
            it = o["item"]
            if it.get("type") == "agent_message":
                recs.append(_asst(ts, [{"type": "text", "text": it.get("text", "")}]))
            elif it.get("type") == "command_execution":
                tid = it.get("id") or "w%d" % n
                recs.append(_asst(ts, [{"type": "tool_use", "id": tid, "name": "Bash",
                                        "input": {"command": it.get("command", "")}}]))
                bad = it.get("exit_code") not in (0, None)
                recs.append(_tool_result(ts, tid, bad, str(it.get("aggregated_output") or "")))
    return recs, result


def _json_file(p):
    try:
        with open(p) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _mtime(p):
    try:
        return from_epoch(os.path.getmtime(p))
    except OSError:
        return None


def _worker_log(jobdir):
    for name in ("log.jsonl", "runner.log"):
        p = os.path.join(jobdir, name)
        try:
            if os.path.getsize(p) > 0:
                return p
        except OSError:
            pass
    return None


def read_worker_log(path, started, end):
    """[(ts, event)] for the log's JSON lines. Lines with no time of their own (claude
    stream-json has none) are spread from `started` to the log's mtime in line order."""
    lines = []
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > WINDOWS[2]:
                f.seek(size - WINDOWS[2])
                f.readline()
            data = f.read()
    except OSError:
        return []
    for ln in data.decode("utf-8", "replace").splitlines():
        ln = ln.strip()
        if ln.startswith("{"):
            try:
                o = json.loads(ln)
            except ValueError:
                continue
            if isinstance(o, dict):
                lines.append(o)
    out, n = [], len(lines)
    span = max(0.0, (end - started).total_seconds()) if started and end else 0.0
    for i, o in enumerate(lines):
        ts = _line_ts(o)
        if ts is None and started:
            ts = started + dt.timedelta(seconds=span * (i + 1) / max(n, 1))
        out.append((ts, o))
    return out


def load_worker(jobdir, root, now):
    """One headless worker job -> a source dict like load_subagents' (plus "state"),
    or None when it is not worth listing (no job.json, or finished past KEEP_S)."""
    job = _json_file(os.path.join(jobdir, "job.json"))
    if not job:
        return None
    jid = job.get("job") or os.path.basename(jobdir.rstrip("/"))
    receipts = sorted(f for f in os.listdir(jobdir) if re.match(r"receipt.*\.json$", f))
    rcpt = _json_file(os.path.join(jobdir, receipts[-1])) if receipts else {}
    running = job.get("state") in ("started", "queued", "running") and pid_alive(job.get("pid"))
    logp = _worker_log(jobdir)
    lmt = _mtime(logp) if logp else None
    jmt = _mtime(os.path.join(jobdir, "job.json"))
    ended = parse_ts(rcpt.get("ended"))
    if running:
        last = lmt or parse_ts(job.get("started")) or jmt
    else:
        last = ended or lmt or jmt
        if last is None or (now - last).total_seconds() > KEEP_S:
            return None
    started = parse_ts(job.get("started")) or parse_ts(job.get("created")) or jmt or last
    objs = read_worker_log(logp, started, lmt or last) if logp else []
    recs, result = worker_records(objs, job.get("agent"))
    st = analyze(recs, root, False)
    st["last"], st["inflight"] = last, running
    final = result or st["final"] or rcpt.get("summary") or None
    try:
        with open(os.path.join(jobdir, "spec.md"), errors="replace") as f:
            spec = f.read()
    except OSError:
        spec = ""
    head = re.sub(r"^[#>\s*-]+", "", first_line(spec))
    bead = job.get("bead") or rcpt.get("bead") or ""
    return {"id": "worker:" + jid, "kind": "worker",
            "title": clip(("%s %s" % (bead, head)).strip() or jid, 100),
            "model": job.get("model") or rcpt.get("model") or st["model"] or None,
            "started": started, "task": clip(spec, 600), "st": st, "final": final,
            "state": "running" if running else "finished"}


# ---------------------------------------------------------------- sessions -> sources
def project_dir(claude_dir, root):
    """<claude-dir>/projects/<root with every non-alphanumeric turned into '-'>."""
    for r in dict.fromkeys([os.path.abspath(root), os.path.realpath(root)]):
        p = os.path.join(claude_dir, "projects", re.sub("[^A-Za-z0-9]", "-", r))
        if os.path.isdir(p):
            return p
    return None


def session_mtime(path):
    """Newest write of a session: its transcript or any of its subagents' transcripts."""
    best = 0.0
    sdir = os.path.join(path[:-6], "subagents")
    for p in [path] + [os.path.join(sdir, f) for f in (os.listdir(sdir) if os.path.isdir(sdir) else [])]:
        try:
            best = max(best, os.path.getmtime(p))
        except OSError:
            pass
    return best


def to_source(s, now):
    """(source dict, started, last) for a loaded main/subagent/worker, or None if dropped."""
    st = s["st"]
    state = s.get("state") or state_of(st["last"], st["inflight"], st["final"], now)
    if state is None:
        return None
    final = s["final"] if "final" in s else st["final"]
    started = s["started"] or st["first"] or st["last"]
    src = {"id": s["id"], "kind": s["kind"], "title": s["title"], "model": s["model"] or None,
           "started": iso(started), "last": iso(st["last"]), "state": state,
           "task": s["task"], "events": st["ev"].lines(),
           "final": clip(final, 400) if state == "finished" and final else None}
    return src, started, st["last"]


def pick_session(claude_dir, root, now, live):
    """Load the most recently active main session (and its subagents)."""
    pdir = project_dir(claude_dir, root)
    if not pdir:
        return None
    paths = [os.path.join(pdir, f) for f in os.listdir(pdir) if f.endswith(".jsonl")]
    if live:
        paths = sorted(paths, key=session_mtime, reverse=True)[:6]
    live_cut = (dt.datetime.now(dt.timezone.utc).timestamp() - (max(KEEP_S, PENDING_S) + 300)) if live else None
    best = None
    for p in paths:
        try:
            recs = load_conv(p, lambda rs: any(r["type"] == "user" and human_text(r) is not None for r in rs))
        except OSError:
            continue
        st = analyze(recs, root, True)
        subs = load_subagents(os.path.join(p[:-6], "subagents"), root, live_cut)
        lasts = [x for x in [st["last"]] + [s["st"]["last"] for s in subs] if x]
        if not lasts:
            continue
        cand = (max(lasts), os.path.basename(p)[:-6], st, subs)
        if best is None or cand[0] > best[0]:
            best = cand
    return best


def collect(root, claude_dir, now, live):
    """-> (request, sources); sources ordered per the contract, internal times stripped."""
    request, run, fin, main = None, [], [], None
    best = pick_session(claude_dir, root, now, live)
    loaded = []
    if best:
        _, sid, st, subs = best
        if st["request"]:
            request = {"session": sid, "text": clip(st["request"][1], 600), "at": iso(st["request"][0])}
        task = request["text"] if request else ""
        loaded.append(({"id": sid, "kind": "main", "title": "main session", "model": st["model"],
                        "started": st["request"][0] if st["request"] else st["first"],
                        "task": task, "st": st}))
        loaded.extend(subs)
    wroot = os.path.join(root, ".claude-dev", "run", "workers")
    try:
        wdirs = sorted(os.path.join(wroot, d) for d in os.listdir(wroot))
    except OSError:
        wdirs = []
    for wd in wdirs:
        if os.path.isdir(wd):
            try:
                w = load_worker(wd, root, now)
            except OSError:
                w = None
            if w:
                loaded.append(w)
    for s in loaded:
        r = to_source(s, now)
        if r is None:
            continue
        src, started, last = r
        if s["kind"] == "main":
            main = (src, started, last)
        elif src["state"] == "running":
            run.append((src, started, last))
        else:
            fin.append((src, started, last))
    run.sort(key=lambda x: x[1])
    fin.sort(key=lambda x: x[2], reverse=True)
    ordered = run + ([main] if main else []) + fin
    return request, [x[0] for x in ordered]


# ---------------------------------------------------------------- size cap
def dumps(doc):
    return json.dumps(doc, ensure_ascii=False)


def cap(doc):
    """Keep the output under MAX_BYTES: oldest events first (down to 3 per source), then
    the oldest finished sources, then any remaining events, then trailing sources."""
    srcs = doc["sources"]

    def too_big():
        return len(dumps(doc).encode("utf-8")) > MAX_BYTES

    def trim(floor):
        c = [s for s in srcs if len(s["events"]) > floor]
        if not c:
            return False
        max(c, key=lambda s: len(s["events"]))["events"].pop(0)
        return True

    while too_big():
        if trim(3):
            continue
        fin = [s for s in srcs if s["state"] == "finished"]
        if fin:
            srcs.remove(fin[-1])
            doc["omitted"] += 1
        elif not trim(0):
            if not srcs:
                break
            srcs.pop()
            doc["omitted"] += 1


# ---------------------------------------------------------------- --text
def human_dur(sec):
    sec = max(0, int(sec))
    if sec < 60:
        return "%d s" % sec
    if sec < 3600:
        return "%d min" % (sec // 60)
    return "%d h %d min" % (sec // 3600, sec % 3600 // 60)


def render_text(doc, now):
    out = []
    req = doc["request"]
    out.append("Latest request: " + clip(req["text"], 300) if req else "No request found yet.")
    if not doc["sources"]:
        out.append("Nothing is running right now.")
    for s in doc["sources"]:
        started, last = parse_ts(s["started"]), parse_ts(s["last"])
        if s["state"] == "running":
            when = "running for " + human_dur((now - started).total_seconds())
            tail = s["events"][-1] if s["events"] else "no activity yet"
        else:
            when = "finished " + human_dur((now - last).total_seconds()) + " ago"
            tail = s["final"] or (s["events"][-1] if s["events"] else "no output")
        out.append("%s (%s): %s, last: %s" % (s["title"], s["kind"], when, tail))
    if doc["omitted"]:
        out.append("(%d more not shown)" % doc["omitted"])
    return redact("\n".join(out)) + "\n"


# ---------------------------------------------------------------- main
def default_root():
    for k in ("CLAUDE_ORCA_ROOT", "PROJECT_DIR"):
        if os.environ.get(k):
            return os.environ[k]
    try:
        r = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return os.getcwd()


def main(argv=None):
    ap = argparse.ArgumentParser(prog="activity-digest.py", description="What Claude Code is doing, as JSON or text.")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--json", action="store_true", help="one JSON object (default)")
    g.add_argument("--text", action="store_true", help="a plain page, a headline per source")
    ap.add_argument("--root", help="the folder (default: CLAUDE_ORCA_ROOT, PROJECT_DIR, git top level, cwd)")
    ap.add_argument("--claude-dir", help="Claude's config dir (default: CLAUDE_CONFIG_DIR, else .claude under HOME)")
    ap.add_argument("--now", help="pretend it is this ISO time (tests)")
    a = ap.parse_args(argv)
    now = parse_ts(a.now) if a.now else dt.datetime.now(dt.timezone.utc)
    if now is None:
        ap.error("--now: not an ISO time: %r" % a.now)
    root = os.path.abspath(a.root or default_root())
    cdir = a.claude_dir or os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    request, sources = collect(root, cdir, now, a.now is None)
    fp = hashlib.sha1(json.dumps([[s["id"], s["last"], s["state"]] for s in sources]).encode()).hexdigest()[:16]
    ep = "none"
    if request:
        ep = hashlib.sha1("|".join([request["session"], request["at"], request["text"]]).encode()).hexdigest()[:12]
    doc = {"generated": iso(now), "root": root, "episode": ep, "fingerprint": fp,
           "request": request, "sources": sources, "omitted": 0}
    cap(doc)
    if a.text:
        sys.stdout.write(render_text(doc, now))
    else:
        sys.stdout.write(dumps(doc) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
