#!/usr/bin/env python3
"""cost-mirror — UserPromptSubmit hook: one-line, by-model token spend for the
current session, injected as context each prompt.

Why: the orchestrator is asked to keep spend on the cheap tiers but has no
in-session view of what anything costs — an unobservable optimisation target
(bead j09). This prints one compact line ("main: ... | workers: ...") derived
from the live transcript, so the cost of working inline vs delegating is
visible at the moment the choice is made. It constrains nothing.

Mechanics: UserPromptSubmit stdout on exit 0 is added to the model's context.
The main transcript and each subagents/*.jsonl are scanned INCREMENTALLY — a
per-session state file under ~/.claude/cache/cost-mirror/ keeps a byte offset
and running totals per file, so each prompt parses only appended lines (a
shrunk/rotated file rescans from zero). Assistant rows are aggregated by
message.model: rows with isSidechain or living under subagents/ count as
worker spend, the rest as main. Output tokens and cache-read tokens are
tracked; "<synthetic>" rows are skipped.

Failure posture: fail SILENT AND OPEN — any error prints nothing and exits 0.
Env: COST_MIRROR_DISABLE=1 bypasses; COST_MIRROR_STATE_DIR overrides the
state directory (tests).
"""

import glob
import hashlib
import json
import os
import sys


def fmt(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)


def scan_file(path, assume_worker, fstate):
    """Add tokens from lines appended since the recorded offset."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return
    if size < fstate.get("off", 0):  # rotated/truncated: recount from zero
        fstate.clear()
    off = fstate.get("off", 0)
    agg = fstate.setdefault("agg", {})  # "side|model" -> [out, cache_read]
    if size == off:
        return
    with open(path, "rb") as fh:
        fh.seek(off)
        chunk = fh.read()
    # only complete lines; a partially-written tail is re-read next time
    end = chunk.rfind(b"\n")
    if end < 0:
        return
    for raw in chunk[: end + 1].splitlines():
        try:
            row = json.loads(raw)
        except Exception:
            continue
        msg = row.get("message") or {}
        model = msg.get("model")
        usage = msg.get("usage") or {}
        if not model or model == "<synthetic>" or not isinstance(usage, dict):
            continue
        side = "worker" if (assume_worker or row.get("isSidechain")) else "main"
        cur = agg.setdefault(f"{side}|{model}", [0, 0])
        cur[0] += usage.get("output_tokens", 0) or 0
        cur[1] += usage.get("cache_read_input_tokens", 0) or 0
    fstate["off"] = off + end + 1


def summarise(files_state):
    total = {}  # "side|model" -> [out, cread]
    for fstate in files_state.values():
        for key, (out, cread) in fstate.get("agg", {}).items():
            cur = total.setdefault(key, [0, 0])
            cur[0] += out
            cur[1] += cread
    parts = []
    for side in ("main", "workers"):
        skey = "main" if side == "main" else "worker"
        rows = [(k.split("|", 1)[1], v) for k, v in total.items() if k.startswith(skey + "|")]
        if not rows:
            continue
        rows.sort(key=lambda r: -(r[1][0] + r[1][1]))
        out = sum(v[0] for _, v in rows)
        cread = sum(v[1] for _, v in rows)
        models = ", ".join(m.replace("claude-", "") for m, _ in rows[:3])
        parts.append(f"{side}: {fmt(out)} out · {fmt(cread)} cache-read ({models})")
    return " | ".join(parts)


def main():
    if os.environ.get("COST_MIRROR_DISABLE") == "1":
        return
    event = json.load(sys.stdin)
    tp = event.get("transcript_path") or ""
    if not tp or not os.path.isfile(tp):
        return
    state_dir = os.environ.get("COST_MIRROR_STATE_DIR") or os.path.expanduser(
        "~/.claude/cache/cost-mirror"
    )
    os.makedirs(state_dir, exist_ok=True)
    state_path = os.path.join(
        state_dir, hashlib.sha256(tp.encode()).hexdigest()[:16] + ".json"
    )
    try:
        with open(state_path) as fh:
            state = json.load(fh)
    except Exception:
        state = {}
    files_state = state.setdefault("files", {})

    scan_file(tp, False, files_state.setdefault(tp, {}))
    subdir = os.path.join(os.path.splitext(tp)[0], "subagents")
    for sub in sorted(glob.glob(os.path.join(subdir, "*.jsonl"))):
        scan_file(sub, True, files_state.setdefault(sub, {}))

    line = summarise(files_state)
    tmp = state_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, state_path)
    if line:
        print(f"[cost-mirror] this session — {line}")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # fail silent and open: a broken mirror must never break a prompt
    sys.exit(0)
