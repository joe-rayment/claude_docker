#!/usr/bin/env python3
"""route-prompt.py -- UserPromptSubmit hook: one cheap model call says where the
bulk of this prompt's work should go (claude-orca-f6o.2, slice R2 of the router).

Reads the hook JSON on stdin (session_id, transcript_path, cwd, prompt), classifies
the prompt into answer | lookup | build | design, and prints ONE line the session
sees as context:

    [route] build (0.82) -> lane standard; bulk: one executor (sonnet) -- <reason>

    route-prompt.py < hook.json

Exit 0 always; stderr silent; a prompt is never blocked. When anything fails
(timeout, guard down, HTTP error, unparsable reply) it prints nothing and the
lane reminder stands. Silent and unlogged when: the session is a headless worker
(CLAUDE_CODE_ENTRYPOINT sdk*, or CLAUDE_CODE_SESSION_ATTENDED=0), "router": false
in <root>/.claude-dev/claude-orca.json, config/route/{classifier.txt,router.json}
missing, or no guard token.

Before any call: a thank-you alone ("thanks!", "great, thank you") is an
answer with no call, and leaves the saved route alone; a slash command or a short follow-up (<= 4 words, no verb of
work, no "?") keeps the last route (line "... (kept from the last prompt)", or
nothing when there is none); the words plan / thorough(ly) / audit / security /
migrate / migration route to design with no call. Level -> lane: answer,lookup
= express; build = standard; design = deep. A reply below confidence_floor
moves one level up (design stays).

State: <run>/route/<session_id>.json {level, confidence, at}. Log:
<run>/route/calls.log, one line per prompt -- time, outcome (answer|lookup|
build|design|floor|kept|skip|fallback), level, confidence, model, ms, tokens,
cost, reason code -- never prompt text, never the token. Three fallbacks in a
row pause the calls for 300 s (<run>/route/backoff.json).

Where things come from (read as data, never executed):
    folder   CLAUDE_ORCA_ROOT, else PROJECT_DIR, else the nearest parent of the
             hook's cwd holding .claude-dev; run dir = <folder>/.claude-dev/run
    token    OPENROUTER_API_KEY (the GUARD token), else <run>/openrouter-guard.token
    URL      OPENROUTER_BASE_URL, else http://127.0.0.1:4141/api/v1 -- loopback only
    config   CLAUDE_ORCA_ROUTE_CONFIG_DIR, else <template>/config/route
    model    "routerModel" in claude-orca.json, else router.json "model"
Other env seam: CLAUDE_ORCA_ROUTE_BACKOFF_S (default 300).
"""
import http.client
import json
import os
import re
import signal
import sys
import tempfile
import time
import urllib.parse
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
TEMPLATE_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_URL = "http://127.0.0.1:4141/api/v1"
LOOPBACK = ("127.0.0.1", "localhost", "::1")
LEVELS = ("answer", "lookup", "build", "design")
LANE = {"answer": "express", "lookup": "express", "build": "standard", "design": "deep"}
TAIL_BYTES = 2 * 1024 * 1024
LOG_MAX = 256 * 1024
FAIL_LIMIT = 3

FLOOR_WORDS = re.compile(r"\b(plan|thorough(?:ly)?|audit|security|migrate|migration)\b", re.IGNORECASE)
WORK_VERBS = frozenset((
    "fix add build make create write implement change update remove delete rename refactor "
    "run test check find show explain why how what where when who which list debug install "
    "deploy commit merge push pull review investigate look read search move copy edit patch "
    "set get open close start stop restart revert undo redo split combine replace try "
    "figure diagnose analyze analyse compare verify document design"
).split())
# A thank-you alone is an answer, not more of the last route's work; it
# leaves the saved route alone, so a later "go on" still keeps it.
ACK_WORDS = frozenset((
    "thanks thank you thx ty cool nice great perfect awesome lovely cheers brilliant much"
).split())
SECRET_PATTERNS = (
    re.compile(r"sk-or-[A-Za-z0-9_-]+"),
    re.compile(r"sk-ant-[A-Za-z0-9_-]+"),
    re.compile(r"\b(?:ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]+"),
    re.compile(r"github_pat_[A-Za-z0-9_]+"),
    re.compile(r"\bBearer\s+\S+", re.IGNORECASE),
)
ASSIGN_SECRET = re.compile(r"\b([A-Za-z][A-Za-z0-9_]*(?:API_KEY|TOKEN|SECRET|PASSWORD))=\S+")


class Deadline(BaseException):
    """The whole call ran past router.json timeout_s."""


class Fail(Exception):
    """A classification that produced no route; .code is the log's reason word."""

    def __init__(self, code):
        Exception.__init__(self, code)
        self.code = code


def on_alarm(signum, frame):
    raise Deadline()


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def atomic_write(path, text):
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def resolve_root(cwd):
    for cand in (os.environ.get("CLAUDE_ORCA_ROOT"), os.environ.get("PROJECT_DIR")):
        if cand:
            return os.path.abspath(cand)
    here = os.path.abspath(cwd) if isinstance(cwd, str) and cwd else os.getcwd()
    while True:
        if os.path.isdir(os.path.join(here, ".claude-dev")):
            return here
        parent = os.path.dirname(here)
        if parent == here:
            return None
        here = parent


def pick_token(rundir):
    tok = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if tok:
        return tok
    try:
        with open(os.path.join(rundir, "openrouter-guard.token"), encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def redact(text, token):
    if token:
        text = text.replace(token, "[redacted]")
    for pat in SECRET_PATTERNS:
        text = pat.sub("[redacted]", text)
    return ASSIGN_SECRET.sub(r"\1=[redacted]", text)


def is_worker():
    entry = os.environ.get("CLAUDE_CODE_ENTRYPOINT", "")
    return entry.startswith("sdk") or os.environ.get("CLAUDE_CODE_SESSION_ATTENDED") == "0"


def num(value, default):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    return value


def last_assistant_text(path, limit=1500):
    """The newest assistant text in the transcript's last 2 MB ('' if none)."""
    if not isinstance(path, str) or not path:
        return ""
    try:
        with open(path, "rb") as fh:
            size = fh.seek(0, os.SEEK_END)
            start = max(0, size - TAIL_BYTES)
            fh.seek(start)
            blob = fh.read()
    except OSError:
        return ""
    lines = blob.split(b"\n")
    if start > 0:
        lines = lines[1:]  # the first line is cut mid-record
    for raw in reversed(lines):
        if b'"assistant"' not in raw:
            continue
        try:
            rec = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(rec, dict) or rec.get("type") != "assistant" or rec.get("isSidechain"):
            continue
        msg = rec.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        if isinstance(content, str):
            parts = [content]
        elif isinstance(content, list):
            parts = [b.get("text", "") for b in content
                     if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)]
        else:
            parts = []
        text = "".join(parts).strip()
        if text:
            return text[-limit:]
    return ""


def tier_model(rundir, role):
    tier = read_json(os.path.join(rundir, "tier.json")) or {}
    roles = tier.get("roles") if isinstance(tier.get("roles"), dict) else {}
    entry = roles.get(role) if isinstance(roles.get(role), dict) else {}
    for cand in (entry.get("model"), tier.get(role)):
        if isinstance(cand, str) and cand.strip():
            return re.sub(r"[^A-Za-z0-9._/:-]", "", cand.strip())[:40]
    return ""


def bulk_for(level, rundir):
    def named(label, role):
        model = tier_model(rundir, role)
        return label % (" (%s)" % model if model else "")
    if level == "answer":
        return "you, inline"
    if level == "lookup":
        return named("one scout%s", "recon")
    if level == "build":
        return named("one executor%s", "worker")
    return named("you plan; executors%s take slices", "worker")


def one_line(text, limit=120):
    return re.sub(r"\s+", " ", text).strip()[:limit]


def parse_reply(content):
    """(level, confidence, reason) from the first {...} in the content."""
    text = content.replace("```json", "```")
    pos = text.find("{")
    if pos < 0:
        raise Fail("unparsable")
    try:
        obj, _ = json.JSONDecoder().raw_decode(text[pos:])
    except ValueError:
        raise Fail("unparsable")
    if not isinstance(obj, dict):
        raise Fail("unparsable")
    level = obj.get("level")
    if not isinstance(level, str) or level.strip().lower() not in LEVELS:
        raise Fail("bad_level")
    conf = float(min(1.0, max(0.0, num(obj.get("confidence"), 0.0))))
    reason = obj.get("reason") if isinstance(obj.get("reason"), str) else ""
    return level.strip().lower(), conf, reason


def call_guard(base, token, router, system, user):
    """One chat completion. Returns (content, usage dict, ms); raises Fail."""
    payload = {"model": router["model"], "temperature": 0, "max_tokens": router["max_tokens"],
               "messages": [{"role": "system", "content": system},
                            {"role": "user", "content": user}]}
    if router["reasoning_off"]:
        payload["reasoning"] = {"enabled": False}
    if router.get("usage"):
        payload["usage"] = {"include": True}
    body = json.dumps(payload).encode("utf-8").replace(token.encode("utf-8"), b"[redacted]")
    parts = urllib.parse.urlparse(base)
    start = time.monotonic()
    conn = http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=router["timeout_s"] + 0.5)
    try:
        conn.request("POST", parts.path.rstrip("/") + "/chat/completions", body=body,
                     headers={"Content-Type": "application/json", "Authorization": "Bearer " + token})
        resp = conn.getresponse()
        raw = resp.read(1 << 20)
    except OSError as exc:
        raise Fail("timeout" if "timed out" in str(exc) else "refused")
    except http.client.HTTPException:
        raise Fail("refused")
    finally:
        conn.close()
    ms = int((time.monotonic() - start) * 1000)
    if resp.status != 200:
        raise Fail("http_%d" % resp.status)
    try:
        data = json.loads(raw.decode("utf-8", "replace"))
        content = data["choices"][0]["message"]["content"]
        if isinstance(content, list):
            content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
        if not isinstance(content, str):
            raise ValueError("content")
    except (ValueError, KeyError, IndexError, TypeError, AttributeError):
        raise Fail("unparsable")
    usage = data.get("usage") if isinstance(data.get("usage"), dict) else {}
    return content, usage, ms


def safe_word(value):
    return re.sub(r"[^A-Za-z0-9._/:=-]", "_", str(value)) or "-"


def log_line(routedir, outcome, level="-", conf=None, model="-", ms=0, usage=None, reason="-"):
    usage = usage or {}

    def val(key):
        return str(usage[key]) if isinstance(usage.get(key), (int, float)) and not isinstance(usage.get(key), bool) else "-"
    line = "%s %s level=%s conf=%s model=%s ms=%d ptok=%s ctok=%s cost=%s reason=%s\n" % (
        now_iso(), outcome, level, "-" if conf is None else "%.2f" % conf, safe_word(model), ms,
        val("prompt_tokens"), val("completion_tokens"), val("cost"), safe_word(reason))
    path = os.path.join(routedir, "calls.log")
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line)
        if os.path.getsize(path) > LOG_MAX:
            with open(path, encoding="utf-8") as fh:
                tail = fh.readlines()[-1000:]
            atomic_write(path, "".join(tail))
    except OSError:
        pass


def save_state(routedir, sid, level, conf):
    try:
        atomic_write(os.path.join(routedir, sid + ".json"),
                     json.dumps({"level": level, "confidence": round(conf, 2), "at": now_iso()}) + "\n")
    except OSError:
        pass


def load_state(routedir, sid):
    data = read_json(os.path.join(routedir, sid + ".json"))
    return data if data and data.get("level") in LEVELS else None


def in_backoff(routedir):
    until = num((read_json(os.path.join(routedir, "backoff.json")) or {}).get("until"), 0)
    return until > time.time()


def record_outcome(routedir, ok):
    path = os.path.join(routedir, "backoff.json")
    try:
        if ok:
            if os.path.exists(path):
                os.unlink(path)
            return
        fails = int(num((read_json(path) or {}).get("fails"), 0)) + 1
        try:
            window = float(os.environ.get("CLAUDE_ORCA_ROUTE_BACKOFF_S", "300"))
        except ValueError:
            window = 300.0
        until = time.time() + window if fails >= FAIL_LIMIT else 0
        atomic_write(path, json.dumps({"fails": fails, "until": until}) + "\n")
    except OSError:
        pass


def emit(level, conf, bulk, reason):
    sys.stdout.write("[route] %s (%.2f) -> lane %s; bulk: %s -- %s\n" % (level, conf, LANE[level], bulk, reason))
    sys.stdout.flush()


def classify(prompt, hook, token, base, router, system):
    user = json.dumps({"prompt": redact(prompt[:2000], token),
                       "previous_reply": redact(last_assistant_text(hook.get("transcript_path")), token)})
    content, usage, ms = call_guard(base, token, router, system, user)
    level, conf, reason = parse_reply(content)
    return level, conf, reason, usage, ms


def load_router(config):
    """The validated router.json dict (model overridden by routerModel), or None."""
    cdir = os.environ.get("CLAUDE_ORCA_ROUTE_CONFIG_DIR") or os.path.join(TEMPLATE_DIR, "config", "route")
    raw = read_json(os.path.join(cdir, "router.json"))
    try:
        with open(os.path.join(cdir, "classifier.txt"), encoding="utf-8") as fh:
            system = fh.read()
    except OSError:
        return None, None
    over = config.get("routerModel")
    model = over.strip() if isinstance(over, str) and over.strip() else (raw or {}).get("model")
    if not raw or not system.strip() or not isinstance(model, str) or not model.strip():
        return None, None
    timeout = num(raw.get("timeout_s"), 2.5)
    router = {"model": model.strip(), "reasoning_off": raw.get("reasoning_off") is True,
              "timeout_s": timeout if timeout > 0 else 2.5,
              "confidence_floor": num(raw.get("confidence_floor"), 0.6),
              "max_tokens": int(num(raw.get("max_tokens"), 60)),
              "usage": os.environ.get("CLAUDE_ORCA_ROUTE_USAGE") == "1"}
    return router, system


def keep_last(prompt):
    stripped = prompt.strip()
    if stripped.startswith("/"):
        return True
    words = re.findall(r"[a-z']+", stripped.lower())
    return len(stripped.split()) <= 4 and "?" not in stripped and not (set(words) & WORK_VERBS)


def run(hook):
    prompt = hook.get("prompt")
    sid = re.sub(r"[^A-Za-z0-9_-]", "_", str(hook.get("session_id") or ""))[:100] or "unknown"
    if not isinstance(prompt, str) or not prompt.strip() or is_worker():
        return
    root = resolve_root(hook.get("cwd"))
    if not root:
        return
    config = read_json(os.path.join(root, ".claude-dev", "claude-orca.json")) or {}
    if config.get("router") is False:
        return
    rundir = os.path.join(root, ".claude-dev", "run")
    router, system = load_router(config)
    token = pick_token(rundir)
    if not router or not token:
        return
    routedir = os.path.join(rundir, "route")
    try:
        os.makedirs(routedir, exist_ok=True)
    except OSError:
        return
    model = router["model"]
    words = re.findall(r"[a-z']+", prompt.lower())
    if words and len(words) <= 4 and set(words) <= ACK_WORDS:
        emit("answer", 1.0, bulk_for("answer", rundir), "an acknowledgement, nothing to do")
        log_line(routedir, "ack", "answer", 1.0, model)
        return
    if prompt.lstrip().startswith("/") or (not FLOOR_WORDS.search(prompt) and keep_last(prompt)):
        last = load_state(routedir, sid)
        if last:
            level = last["level"]
            sys.stdout.write("[route] %s -> lane %s (kept from the last prompt)\n" % (level, LANE[level]))
            log_line(routedir, "kept", level, num(last.get("confidence"), None), model)
        else:
            log_line(routedir, "skip", model=model, reason="no_state")
        return
    hit = FLOOR_WORDS.search(prompt)
    if hit:
        word = hit.group(1).lower()
        emit("design", 1.0, bulk_for("design", rundir), "the prompt asks for " + word)
        save_state(routedir, sid, "design", 1.0)
        log_line(routedir, "floor", "design", 1.0, model, reason=word)
        return
    if in_backoff(routedir):
        log_line(routedir, "skip", model=model, reason="backoff")
        return
    base = os.environ.get("OPENROUTER_BASE_URL") or DEFAULT_URL
    if urllib.parse.urlparse(base).hostname not in LOOPBACK:
        log_line(routedir, "fallback", model=model, reason="non_loopback")
        return
    fail = None
    got = None
    signal.signal(signal.SIGALRM, on_alarm)
    signal.setitimer(signal.ITIMER_REAL, router["timeout_s"])
    try:
        got = classify(prompt, hook, token, base, router, system)
    except Fail as exc:
        fail = exc.code
    except Deadline:
        fail = "timeout"
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    if fail:
        record_outcome(routedir, False)
        log_line(routedir, "fallback", model=model, reason=fail)
        return
    level, conf, reason, usage, ms = got
    record_outcome(routedir, True)
    said = level
    if conf < router["confidence_floor"]:
        level = LEVELS[min(LEVELS.index(level) + 1, len(LEVELS) - 1)]
    text = one_line(redact(reason, token)) or "no reason given"
    if level != said:
        text += " (raised from %s: low confidence)" % said
    emit(level, conf, bulk_for(level, rundir), text)
    save_state(routedir, sid, level, conf)
    log_line(routedir, level, level, conf, model, ms, usage, "raised" if level != said else "-")


def main():
    try:
        hook = json.loads(sys.stdin.read())
        if isinstance(hook, dict):
            run(hook)
    except BaseException:
        pass  # a prompt is never blocked, and a hook that fails says nothing
    try:
        sys.stdout.flush()
    except BaseException:
        pass
    os._exit(0)


if __name__ == "__main__":
    main()
