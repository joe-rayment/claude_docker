#!/usr/bin/env python3
"""route-eval.py -- measure prompt-router classifiers against a labeled set
(claude-orca-f6o.1, slice R1 of the prompt router).

Runs a JSONL set ({"prompt","previous_reply","gold","why"} per line, gold one
of answer|lookup|build|design) against one or more models through the
OpenRouter guard, with exactly the call the hook makes (see
.claude/plans/prompt-router.md): system = config/route/classifier.txt, user =
json.dumps({"prompt": first 2000 chars, "previous_reply": last 1500 chars}),
temperature 0, usage.include, and "reasoning": {"enabled": false} by default.
Then prints one table per model: n, accuracy, under-routes (listed),
over-routes, failures, p50/p95 ms, mean tokens, $/call, and the best
confidence floor (the lowest floor with zero hard under-routes).

    route-eval.py [--set FILE] --models a,b,c [--floor X] [--runs N]
                  [--classifier FILE] [--base-url URL] [--root DIR]
                  [--reasoning off|default] [--max-tokens N] [--timeout S]
                  [--budget-ms MS] [--list-wrong] [--out FILE]

Scoring: a level below the gold level (after the confidence rule: confidence
< floor moves one level up) is an under-route; a HARD under-route is one on a
gold build or design prompt. A call that fails or answers badly is a failure
(the hook would print nothing), counted apart from the scores. --out FILE
writes one JSON line per call (never the token, the prompt cut to 80 chars).
Token: OPENROUTER_API_KEY, else <root>/.claude-dev/run/openrouter-guard.token.
Exit: 0 ran, 2 bad arguments or an unreadable set.
"""
import argparse
import json
import math
import os
import sys
import threading
import time
import urllib.error
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
TEMPLATE_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_URL = "http://127.0.0.1:4141/api/v1"
LEVELS = ("answer", "lookup", "build", "design")
RANK = dict((lv, i) for i, lv in enumerate(LEVELS))


def note(msg):
    sys.stderr.write("route-eval: %s\n" % msg)


def die(msg, code=2):
    note(msg)
    sys.exit(code)


def pick_token(rundir):
    tok = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if tok:
        return tok
    try:
        with open(os.path.join(rundir, "openrouter-guard.token"), encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def load_set(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as fh:
            for ln, line in enumerate(fh, 1):
                if not line.strip():
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    die("%s:%d is not JSON" % (path, ln))
                if not isinstance(row, dict) or not isinstance(row.get("prompt"), str):
                    die("%s:%d has no string \"prompt\"" % (path, ln))
                if row.get("gold") not in LEVELS:
                    die("%s:%d gold %r is not one of %s" % (path, ln, row.get("gold"), "|".join(LEVELS)))
                prev = row.get("previous_reply")
                row["previous_reply"] = prev if isinstance(prev, str) else ""
                rows.append(row)
    except OSError as exc:
        die("cannot read %s: %s" % (path, exc.strerror or exc))
    if not rows:
        die("%s holds no rows" % path)
    return rows


def user_json(row):
    return json.dumps({"prompt": row["prompt"][:2000], "previous_reply": row["previous_reply"][-1500:]})


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def call_model(base_url, token, model, system, user, args):
    """One chat completion, as the interface specifies. Returns {status, text, usage,
    ms, error}; error is None or refused | timeout | http | empty (never content)."""
    payload = {"model": model, "temperature": 0, "max_tokens": args.max_tokens,
               "usage": {"include": True},
               "messages": [{"role": "system", "content": system},
                            {"role": "user", "content": user}]}
    if args.reasoning == "off":
        payload["reasoning"] = {"enabled": False}
    req = urllib.request.Request(
        base_url.rstrip("/") + "/chat/completions", data=json.dumps(payload).encode("utf-8"),
        method="POST", headers={"Content-Type": "application/json", "Authorization": "Bearer " + token})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    res = {"status": None, "text": "", "usage": None, "ms": 0, "error": None}
    start = time.monotonic()
    raw = b""
    try:
        with opener.open(req, timeout=args.timeout) as resp:
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
            res["usage"] = data.get("usage") if isinstance(data.get("usage"), dict) else None
        except (ValueError, KeyError, IndexError, TypeError, AttributeError):
            pass
        if not res["text"].strip():
            res["error"] = "empty"
    return res


def parse_reply(text):
    """(level, confidence, reason) from the first {...} in text; level None if unusable."""
    start = text.find("{")
    if start < 0:
        return None, 0.0, ""
    try:
        obj, _ = json.JSONDecoder().raw_decode(text[start:])
    except ValueError:
        return None, 0.0, ""
    if not isinstance(obj, dict):
        return None, 0.0, ""
    level = obj.get("level")
    level = level.strip().lower() if isinstance(level, str) else None
    conf = obj.get("confidence")
    conf = float(conf) if isinstance(conf, (int, float)) and not isinstance(conf, bool) else 0.0
    reason = obj.get("reason") if isinstance(obj.get("reason"), str) else ""
    return (level if level in RANK else None), max(0.0, min(1.0, conf)), reason


def apply_floor(level, conf, floor):
    """The router rule: confidence below the floor moves one level up (design stays)."""
    if conf < floor and RANK[level] < len(LEVELS) - 1:
        return LEVELS[RANK[level] + 1]
    return level


def run_model(model, rows, args, token, system, base_url, sink, lock):
    """Every row, args.runs times, one call at a time (so latency is not self-inflicted)."""
    for run in range(args.runs):
        for idx, row in enumerate(rows):
            res = call_model(base_url, token, model, system, user_json(row), args)
            level, conf, reason = parse_reply(res["text"]) if res["error"] is None else (None, 0.0, "")
            usage = res["usage"] or {}
            num = lambda k: usage[k] if isinstance(usage.get(k), (int, float)) else None
            rec = {"model": model, "run": run, "row": idx, "gold": row["gold"], "level": level,
                   "confidence": conf, "reason": reason, "ms": res["ms"],
                   "error": ("http%s" % res["status"] if res["error"] == "http" else res["error"])
                   or (None if level else "badreply"),
                   "prompt_tokens": num("prompt_tokens"), "completion_tokens": num("completion_tokens"),
                   "cost": num("cost"), "prompt": row["prompt"][:80].replace("\n", " ")}
            with lock:
                sink.append(rec)


def pct(values, p):
    if not values:
        return 0
    ordered = sorted(values)
    return ordered[max(0, int(math.ceil(p * len(ordered))) - 1)]


def score(recs, floor):
    """Counts for the scored calls at one floor: (under, hard_under, over, correct)."""
    under = hard = over = ok = 0
    for r in recs:
        pred = apply_floor(r["level"], r["confidence"], floor)
        if pred == r["gold"]:
            ok += 1
        elif RANK[pred] < RANK[r["gold"]]:
            under += 1
            hard += 1 if r["gold"] in ("build", "design") else 0
        else:
            over += 1
    return under, hard, over, ok


def mean(values):
    return sum(values) / float(len(values)) if values else None


def report(model, recs, rows, args):
    scored = [r for r in recs if not r["error"]]
    fails = {}
    for r in recs:
        if r["error"]:
            fails[r["error"]] = fails.get(r["error"], 0) + 1
    under, hard, over, ok = score(scored, args.floor)
    ms = [r["ms"] for r in recs]
    slow = len([m for m in ms if m > args.budget_ms])
    cost = [r["cost"] for r in recs if r["cost"] is not None]
    pt = mean([r["prompt_tokens"] for r in recs if r["prompt_tokens"] is not None])
    ct = mean([r["completion_tokens"] for r in recs if r["completion_tokens"] is not None])
    print("== %s  (%s: %d rows x %d runs, floor %.2f, reasoning %s)" % (
        model, os.path.basename(args.set), len(rows), args.runs, args.floor, args.reasoning))
    print("n %d scored, %d failed %s, %d slower than %d ms" % (
        len(scored), len(recs) - len(scored), dict(fails) if fails else "", slow, args.budget_ms))
    print("accuracy %s  under-routes %d (hard %d)  over-routes %d" % (
        ("%.1f%% (%d/%d)" % (100.0 * ok / len(scored), ok, len(scored))) if scored else "-", under, hard, over))
    print("latency ms p50 %d  p95 %d  max %d | mean tokens in/out %s/%s | $/call %s" % (
        pct(ms, 0.5), pct(ms, 0.95), max(ms) if ms else 0,
        "%.0f" % pt if pt is not None else "-", "%.0f" % ct if ct is not None else "-",
        "%.6f" % mean(cost) if cost else "-"))
    seen = {}
    for r in scored:
        pred = apply_floor(r["level"], r["confidence"], args.floor)
        wrong = pred != r["gold"] and (args.list_wrong or RANK[pred] < RANK[r["gold"]])
        if wrong:
            key = (r["row"], pred)
            seen.setdefault(key, []).append(r)
    for (idx, pred), group in sorted(seen.items()):
        r = group[0]
        kind = "under" if RANK[pred] < RANK[r["gold"]] else "over "
        print("  %s row %d  gold %s -> %s (raw %s, conf %.2f) x%d  %s" % (
            kind, idx + 1, r["gold"], pred, r["level"], r["confidence"], len(group), r["prompt"]))
    sweep, last, best = [], None, None
    for step in range(0, 22):
        floor = 1.01 if step == 21 else step / 20.0
        u, h, o, _ = score(scored, floor)
        if best is None and h == 0 and scored:
            best = (floor, u, o)
        if (u, h, o) != last:
            sweep.append("%.2f:%d/%d/%d" % (floor, u, h, o))
            last = (u, h, o)
    print("floor sweep (floor:under/hard/over): " + " ".join(sweep))
    print("best floor (lowest with zero hard under-routes): " + (
        "%.2f (under %d, over %d)%s" % (best[0], best[1], best[2], " = always one level up" if best[0] > 1 else "")
        if best else "none"))
    print()


def main():
    ap = argparse.ArgumentParser(description="Measure prompt-router classifiers against a labeled set.")
    ap.add_argument("--set", default=os.path.join(TEMPLATE_DIR, "tests", "fixtures", "route", "eval.jsonl"))
    ap.add_argument("--models", required=True, help="comma-separated OpenRouter model ids")
    ap.add_argument("--floor", type=float, default=0.0, help="confidence floor to score at (default 0 = none)")
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--classifier", default=os.path.join(TEMPLATE_DIR, "config", "route", "classifier.txt"))
    ap.add_argument("--base-url", default=None)
    ap.add_argument("--root", default=None, help="project dir holding .claude-dev/run (default $PROJECT_DIR)")
    ap.add_argument("--reasoning", choices=("off", "default"), default="off")
    ap.add_argument("--max-tokens", type=int, default=100)
    ap.add_argument("--timeout", type=float, default=15.0)
    ap.add_argument("--budget-ms", type=int, default=2500, help="count calls slower than this")
    ap.add_argument("--list-wrong", action="store_true", help="list over-routes too, not only under-routes")
    ap.add_argument("--out", default=None, help="write one JSON line per call here")
    args = ap.parse_args()
    models = [m.strip() for m in args.models.split(",") if m.strip()]
    if not models or args.runs < 1:
        die("need at least one model and --runs >= 1")
    rows = load_set(args.set)
    try:
        with open(args.classifier, encoding="utf-8") as fh:
            system = fh.read()
    except OSError as exc:
        die("cannot read %s: %s" % (args.classifier, exc.strerror or exc))
    root = args.root or os.environ.get("PROJECT_DIR") or os.getcwd()
    token = pick_token(os.path.join(root, ".claude-dev", "run"))
    if not token:
        die("no guard token (OPENROUTER_API_KEY, or %s/.claude-dev/run/openrouter-guard.token)" % root)
    base_url = args.base_url or os.environ.get("OPENROUTER_BASE_URL") or DEFAULT_URL
    sink, lock = [], threading.Lock()
    threads = [threading.Thread(target=run_model, args=(m, rows, args, token, system, base_url, sink, lock))
               for m in models]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for model in models:
        report(model, [r for r in sink if r["model"] == model], rows, args)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            for rec in sink:
                fh.write(json.dumps(rec) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
