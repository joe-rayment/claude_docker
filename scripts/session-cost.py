#!/usr/bin/env python3
"""session-cost.py -- measure one Claude Code session transcript.

Reads a transcript jsonl (the Claude config dir's projects/<slug>/<session-id>.jsonl)
line by line and prints one table so the template's token diet can be compared
before/after. Never loads the file whole and never prints transcript content.

    scripts/session-cost.py <transcript.jsonl> [--per-turn]

Fields keyed on (learned from a real transcript, 2026-09):
  entry.type                      "user" | "assistant" | "attachment" | ...
  entry.isSidechain               true = sub-agent sidechain; skipped
  entry.message.content           str, or list of blocks with .type in
                                  text | tool_use | tool_result | thinking
  entry.origin.kind               "human" marks a typed prompt (promptSource
                                  is "typed"/"queued"; slash commands carry
                                  origin but no promptSource); "peer" and
                                  "task-notification" mark wakes
  entry.message.id                one assistant API message is written as
                                  one line per content block, all sharing
                                  message.id and the same usage object, so
                                  usage is counted once per id
  entry.message.usage             output_tokens, cache_read_input_tokens
  entry.attachment.hookEvent      "UserPromptSubmit" | "SessionStart" | ...
  entry.rendered[].content        the system-reminder text the model sees
                                  for a hook attachment (fallback:
                                  attachment.content)
"""
import json
import re
import sys

WRAPPER_MARKERS = (
    "Another Claude session sent a message",
    "<teammate-message",
    "<agent-message",
)
HOOK_EVENTS = ("UserPromptSubmit", "SessionStart")
HOOK_TYPES = ("hook_success", "hook_additional_context", "hook_system_message")

COLUMNS = (
    ("user_turns", "typed"),
    ("asst_msgs", "asst_msgs"),
    ("out_tokens", "out_tok"),
    ("cache_read_tokens", "cache_read_tok"),
    ("wake_turns", "wake"),
    ("wrapper_notices", "wrappers"),
    ("hook_bytes", "hook_bytes"),
    ("asst_words", "asst_words"),
    ("qfirst_pass", "q_pass"),
    ("qfirst_fail", "q_fail"),
)


def new_counters():
    return {k: 0 for k, _ in COLUMNS}


def user_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text")
    return ""


def is_tool_result(content):
    return isinstance(content, list) and any(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in content)


def classify_user(entry):
    """typed | wake | tool_result | other"""
    content = (entry.get("message") or {}).get("content")
    if is_tool_result(content):
        return "tool_result", False
    text = user_text(content)
    wrapper = any(m in text for m in WRAPPER_MARKERS)
    kind = (entry.get("origin") or {}).get("kind")
    if kind == "human" and not wrapper:
        return "typed", False
    if wrapper or kind in ("peer", "task-notification") or \
            text.lstrip().startswith("<task-notification>"):
        return "wake", wrapper
    return "other", False


def first_sentence(text):
    text = text.strip()
    m = re.search(r"[.!?](?=\s|$)|\n", text)
    return text[:m.end()] if m else text


def hook_bytes(entry):
    att = entry.get("attachment") or {}
    if att.get("type") not in HOOK_TYPES or att.get("hookEvent") not in HOOK_EVENTS:
        return 0
    rendered = entry.get("rendered")
    if rendered:
        return sum(len(str(r.get("content", "")).encode("utf-8")) for r in rendered)
    return len(str(att.get("content") or "").encode("utf-8"))


class Measure:
    def __init__(self):
        self.turns = []            # list of (line_no, counters)
        self.total = new_counters()
        self.cur = None            # counters of the open turn
        self.pre = new_counters()  # attachments before the first typed turn
        self.last_user_kind = None
        self.msg = None            # open assistant message: id, text, usage, counters

    def bump(self, key, n=1):
        self.total[key] += n
        (self.cur if self.cur is not None else self.pre)[key] += n

    # -- assistant messages --------------------------------------------
    def close_msg(self):
        if not self.msg:
            return
        usage = self.msg["usage"] or {}
        self.bump("out_tokens", int(usage.get("output_tokens") or 0))
        self.bump("cache_read_tokens", int(usage.get("cache_read_input_tokens") or 0))
        self.bump("asst_words", len(self.msg["text"].split()))
        self.msg = None

    def end_turn_check(self):
        """The last assistant message ended a turn: run the question-first check."""
        last = self.last_asst
        if last and "?" in last["text"]:
            self.bump("qfirst_pass" if "?" in first_sentence(last["text"]) else "qfirst_fail")
        self.last_asst = None

    last_asst = None

    def on_assistant(self, entry):
        m = entry.get("message") or {}
        mid = m.get("id") or entry.get("requestId") or entry.get("uuid")
        if not self.msg or self.msg["id"] != mid:
            self.close_msg()
            self.msg = {"id": mid, "text": "", "usage": m.get("usage")}
            self.bump("asst_msgs")
            if self.last_user_kind == "wake":
                self.bump("wake_turns")
            self.last_user_kind = None
            self.last_asst = self.msg
        if m.get("usage"):
            self.msg["usage"] = m["usage"]
        content = m.get("content")
        if isinstance(content, list):
            for b in content:
                if isinstance(b, dict) and b.get("type") == "text":
                    self.msg["text"] += b.get("text", "") + "\n"
        elif isinstance(content, str):
            self.msg["text"] += content + "\n"

    # -- user entries -----------------------------------------------------
    def on_user(self, entry, line_no):
        self.close_msg()
        kind, wrapper = classify_user(entry)
        if kind == "tool_result":
            self.last_asst = None
        else:
            self.end_turn_check()
        if kind == "typed":
            self.cur = new_counters()
            self.turns.append((line_no, self.cur))
            self.bump("user_turns")
        if wrapper:
            self.bump("wrapper_notices")
        self.last_user_kind = kind

    def on_line(self, entry, line_no):
        if entry.get("isSidechain"):
            return
        t = entry.get("type")
        if t == "assistant":
            self.on_assistant(entry)
        elif t == "user":
            self.on_user(entry, line_no)
        elif t == "attachment":
            self.bump("hook_bytes", hook_bytes(entry))

    def finish(self):
        self.close_msg()
        self.end_turn_check()
        # attachments seen before the first typed turn belong to that turn
        if self.turns:
            for k, v in self.pre.items():
                self.turns[0][1][k] += v


def run(path):
    m = Measure()
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line_no, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict):
                m.on_line(entry, line_no)
    m.finish()
    return m


def print_table(rows, headers):
    widths = [max(len(h), *(len(r[i]) for r in rows)) for i, h in enumerate(headers)]
    fmt = "  ".join("{:>%d}" % w for w in widths)
    print(fmt.format(*headers))
    print(fmt.format(*("-" * w for w in widths)))
    for r in rows:
        print(fmt.format(*r))


def main(argv):
    per_turn = "--per-turn" in argv
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 1:
        sys.stderr.write("usage: session-cost.py <transcript.jsonl> [--per-turn]\n")
        return 2
    m = run(args[0])
    short = [s for _, s in COLUMNS]
    if per_turn:
        headers = ["turn", "line"] + short
        rows = [[str(i + 1), str(ln)] + [str(c[k]) for k, _ in COLUMNS]
                for i, (ln, c) in enumerate(m.turns)]
        rows.append(["total", ""] + [str(m.total[k]) for k, _ in COLUMNS])
    else:
        headers = short
        rows = [[str(m.total[k]) for k, _ in COLUMNS]]
    print_table(rows, headers)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
