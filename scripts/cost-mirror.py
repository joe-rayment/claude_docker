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
worker spend, the rest as main. Input, output, cache-read, and cache-write
(5m/1h split, when the row breaks it out) tokens are all tracked. A static
per-model USD/MTok pricing table (prefix-matched, see PRICING_TABLE) turns
those into an actual dollar figure, plus a counterfactual "at the top model
seen this session" price and the savings between them — token counts are
model-dependent so this is always an estimate. Unknown/off-ladder models
still show their tokens but cost $0 and mark the line with a trailing '?'.
"<synthetic>" rows are skipped.

Failure posture: fail SILENT AND OPEN — any error prints nothing and exits 0.
Env: COST_MIRROR_DISABLE=1 bypasses; COST_MIRROR_STATE_DIR overrides the
state directory (tests).

On-demand report: `cost-mirror --report [transcript.jsonl]` prints a
human-readable per-model table (same totals as the hook line) to stdout.
This path takes an optional transcript argument since invoked outside a
hook there's no stdin event to read one from; with no argument it defaults
to the transcript recorded in the newest cost-mirror state file (falling
back to the newest *.jsonl under ~/.claude/projects/*/ if no usable state
exists). It always does a full read-only scan from offset zero into a
throwaway dict and never writes state, so it can be run any number of times
without disturbing the hook's incremental counters. Unlike hook mode it is
NOT fail-silent: a missing/unreadable transcript prints to stderr and exits
nonzero, since this path is invoked directly from a terminal to debug.
"""

import glob
import hashlib
import json
import os
import sys
from datetime import date


def fmt(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)


def fmt_usd(x):
    sign = "-" if x < 0 else ""
    x = abs(x)
    if x >= 10:
        return f"{sign}${x:.0f}"
    return f"{sign}${x:.2f}"


STATE_VERSION = 2
COUNTER_KEYS = ("in", "out", "cr", "w5", "w1")

# sonnet-5 intro pricing (2.00/10.00 per MTok in/out) holds while today is
# strictly before this date; from then on it reverts to the standard 3/15.
SONNET5_INTRO_CUTOFF = date(2026, 9, 1)


def _sonnet5_rates(today=None):
    if (today or date.today()) < SONNET5_INTRO_CUTOFF:
        return (2.00, 10.00)
    return (3.00, 15.00)


# Static USD-per-MTok pricing, prefix-matched against message.model in order —
# first match wins, so the specific "claude-sonnet-5" entry must precede the
# generic "claude-sonnet-" fallback. (in, out) pairs, or a zero-arg callable
# for entries whose price varies (e.g. an intro-period discount).
PRICING_TABLE = (
    ("claude-fable-", (10.00, 50.00)),
    ("claude-mythos-", (10.00, 50.00)),
    ("claude-opus-", (5.00, 25.00)),
    ("claude-sonnet-5", _sonnet5_rates),
    ("claude-sonnet-", (3.00, 15.00)),
    ("claude-haiku-", (1.00, 5.00)),
)


def rates_for(model):
    """USD/MTok rates for a model id: {in, out, cr, w5, w1}, or None if the
    model matches no pricing prefix (off-ladder/unknown)."""
    if not model:
        return None
    for prefix, spec in PRICING_TABLE:
        if model.startswith(prefix):
            rin, rout = spec() if callable(spec) else spec
            return {"in": rin, "out": rout, "cr": rin * 0.1, "w5": rin * 1.25, "w1": rin * 2.0}
    return None


def cost(counters, rates):
    """Dollar cost of a {in,out,cr,w5,w1} counter dict at the given rates
    (USD/MTok). Unknown rates (None) cost nothing — caller marks that fact."""
    if not rates:
        return 0.0
    return sum(counters.get(k, 0) * rates[k] for k in COUNTER_KEYS) / 1_000_000


def _empty_counters():
    return {k: 0 for k in COUNTER_KEYS}


def _state_dir():
    return os.environ.get("COST_MIRROR_STATE_DIR") or os.path.expanduser(
        "~/.claude/cache/cost-mirror"
    )


def scan_file(path, assume_worker, fstate):
    """Add tokens from lines appended since the recorded offset."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return
    if size < fstate.get("off", 0):  # rotated/truncated: recount from zero
        fstate.clear()
    off = fstate.get("off", 0)
    agg = fstate.setdefault("agg", {})  # "side|model" -> {in, out, cr, w5, w1}
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
        cur = agg.setdefault(f"{side}|{model}", _empty_counters())
        cur["in"] += usage.get("input_tokens", 0) or 0
        cur["out"] += usage.get("output_tokens", 0) or 0
        cur["cr"] += usage.get("cache_read_input_tokens", 0) or 0
        cc = usage.get("cache_creation")
        if isinstance(cc, dict):
            cur["w5"] += cc.get("ephemeral_5m_input_tokens", 0) or 0
            cur["w1"] += cc.get("ephemeral_1h_input_tokens", 0) or 0
        else:
            cur["w5"] += usage.get("cache_creation_input_tokens", 0) or 0
    fstate["off"] = off + end + 1


def scan_session(tp, files_state):
    """Scan the main transcript plus any beside-it subagents/*.jsonl into
    files_state (a "path" -> {off, agg} dict), mutating it in place. Shared
    by hook mode (incremental, persisted) and --report (one-shot, throwaway)."""
    scan_file(tp, False, files_state.setdefault(tp, {}))
    subdir = os.path.join(os.path.splitext(tp)[0], "subagents")
    for sub in sorted(glob.glob(os.path.join(subdir, "*.jsonl"))):
        scan_file(sub, True, files_state.setdefault(sub, {}))


def aggregate_total(files_state):
    """Merge every scanned file's agg into one "side|model" -> counters dict."""
    total = {}
    for fstate in files_state.values():
        for key, counters in fstate.get("agg", {}).items():
            cur = total.setdefault(key, _empty_counters())
            for k in COUNTER_KEYS:
                cur[k] += counters.get(k, 0)
    return total


def summarise_tokens(total):
    parts = []
    for side in ("main", "workers"):
        skey = "main" if side == "main" else "worker"
        rows = [(k.split("|", 1)[1], v) for k, v in total.items() if k.startswith(skey + "|")]
        if not rows:
            continue
        rows.sort(key=lambda r: -(r[1]["out"] + r[1]["cr"]))
        out = sum(v["out"] for _, v in rows)
        cread = sum(v["cr"] for _, v in rows)
        models = ", ".join(m.replace("claude-", "") for m, _ in rows[:3])
        parts.append(f"{side}: {fmt(out)} out · {fmt(cread)} cache-read ({models})")
    return " | ".join(parts)


def pick_top_model(total):
    """Counterfactual reference model: the main-side model with the largest
    (out+cr) among main rows; if there are no main rows at all, fall back to
    the most expensive model observed (ranked by output rate; unknown models
    rank last)."""
    main_rows = [(k.split("|", 1)[1], v) for k, v in total.items() if k.startswith("main|")]
    if main_rows:
        main_rows.sort(key=lambda r: -(r[1]["out"] + r[1]["cr"]))
        return main_rows[0][0]
    best, best_rate = None, -1.0
    for key in total:
        model = key.split("|", 1)[1]
        rates = rates_for(model)
        rate = rates["out"] if rates else -1.0
        if best is None or rate > best_rate:
            best, best_rate = model, rate
    return best


def summarise_dollars(total):
    """Actual dollar cost, plus an "at top model" counterfactual and the
    resulting savings, as a compact clause (or "" if there's nothing to
    show). Unknown-priced models still contribute their tokens to the token
    summary but cost $0 here and mark the clause with a trailing '?'."""
    if not total:
        return ""
    models_seen = {key.split("|", 1)[1] for key in total}
    unknown = any(rates_for(m) is None for m in models_seen)
    actual = sum(cost(counters, rates_for(key.split("|", 1)[1])) for key, counters in total.items())

    clause = f"~{fmt_usd(actual)}"
    if unknown:
        clause += "?"

    top = pick_top_model(total)
    top_rates = rates_for(top) if top else None
    if top_rates and len(models_seen) > 1:
        at_top = sum(cost(counters, top_rates) for counters in total.values())
        savings = at_top - actual
        if round(savings, 2) != 0:
            top_short = top.replace("claude-", "")
            clause += f" · ~{fmt_usd(at_top)} at {top_short} → saved ~{fmt_usd(savings)}"
    return clause


def _default_transcript():
    """Best-effort transcript for a bare `--report`. Most robust: the tp the
    hook itself recorded, from the newest cost-mirror state file — that's
    exactly the session the last hook line was computed from. Falls back to
    the newest transcript under ~/.claude/projects/*/ if no state carries a
    still-existing tp (e.g. an old-schema state, or a fresh install)."""
    state_dir = _state_dir()
    for path in sorted(
        glob.glob(os.path.join(state_dir, "*.json")),
        key=lambda p: os.path.getmtime(p),
        reverse=True,
    ):
        try:
            with open(path) as fh:
                st = json.load(fh)
        except Exception:
            continue
        tp = st.get("tp")
        if tp and os.path.isfile(tp):
            return tp
    projects = sorted(
        glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")),
        key=lambda p: os.path.getmtime(p),
        reverse=True,
    )
    return projects[0] if projects else None


def render_report(tp, total):
    """Human-readable per-side|model table: token counts plus actual/at-top/
    saved dollars, with a totals row. cache-write is shown as one combined
    column (w5+w1) for compactness."""
    top = pick_top_model(total)
    top_rates = rates_for(top) if top else None

    lines = [f"cost-mirror report — {tp}"]
    if top:
        note = ""
        if top.startswith("claude-sonnet-5") and date.today() < SONNET5_INTRO_CUTOFF:
            note = " (sonnet-5 intro pricing active)"
        lines.append(f"top model (counterfactual): {top.replace('claude-', '')}{note}")
    else:
        lines.append("top model (counterfactual): none (no rows scanned)")
    lines.append("")

    cols = ("side", "model", "in", "out", "cache-r", "cache-w", "actual $", "at-top $", "saved $")
    widths = (7, 28, 9, 9, 9, 9, 10, 10, 10)

    def fmt_row(values):
        return "".join(
            v.ljust(w) if i < 2 else v.rjust(w) for i, (v, w) in enumerate(zip(values, widths))
        )

    header = fmt_row(cols)
    lines += [header, "-" * len(header)]

    grand = _empty_counters()
    tot_actual = tot_at_top = 0.0
    for side in ("main", "worker"):
        rows = [(k.split("|", 1)[1], v) for k, v in total.items() if k.startswith(side + "|")]
        rows.sort(key=lambda r: -(r[1]["out"] + r[1]["cr"]))
        for model, c in rows:
            rates = rates_for(model)
            actual = cost(c, rates)
            at_top = cost(c, top_rates) if top_rates else 0.0
            saved = at_top - actual
            label = model.replace("claude-", "") + ("" if rates else "?")
            lines.append(fmt_row((
                side, label, str(c["in"]), str(c["out"]), str(c["cr"]), str(c["w5"] + c["w1"]),
                fmt_usd(actual), fmt_usd(at_top) if top_rates else "-", fmt_usd(saved) if top_rates else "-",
            )))
            for k in COUNTER_KEYS:
                grand[k] += c[k]
            tot_actual += actual
            tot_at_top += at_top

    lines.append("-" * len(header))
    lines.append(fmt_row((
        "TOTAL", "", str(grand["in"]), str(grand["out"]), str(grand["cr"]), str(grand["w5"] + grand["w1"]),
        fmt_usd(tot_actual), fmt_usd(tot_at_top) if top_rates else "-",
        fmt_usd(tot_at_top - tot_actual) if top_rates else "-",
    )))
    return "\n".join(lines)


def run_report(argv):
    """--report entry point. NOT fail-silent: prints to stderr and returns a
    nonzero exit code on a missing/unreadable transcript, since this is run
    directly from a terminal rather than from the hook."""
    tp = argv[0] if argv else _default_transcript()
    if not tp:
        print(
            "cost-mirror --report: no transcript given and none found under "
            + _state_dir()
            + " or ~/.claude/projects/*/",
            file=sys.stderr,
        )
        return 1
    if not os.path.isfile(tp):
        print(f"cost-mirror --report: transcript not found: {tp}", file=sys.stderr)
        return 1
    files_state = {}  # throwaway: full scan from offset 0, state never written
    scan_session(tp, files_state)
    print(render_report(tp, aggregate_total(files_state)))
    return 0


def main():
    if os.environ.get("COST_MIRROR_DISABLE") == "1":
        return
    event = json.load(sys.stdin)
    tp = event.get("transcript_path") or ""
    if not tp or not os.path.isfile(tp):
        return
    state_dir = _state_dir()
    os.makedirs(state_dir, exist_ok=True)
    state_path = os.path.join(
        state_dir, hashlib.sha256(tp.encode()).hexdigest()[:16] + ".json"
    )
    try:
        with open(state_path) as fh:
            state = json.load(fh)
    except Exception:
        state = {}
    if state.get("v") != STATE_VERSION:  # old/missing schema: rescan clean
        state = {}
    state["v"] = STATE_VERSION
    state["tp"] = tp  # lets --report find this session's transcript by default
    files_state = state.setdefault("files", {})

    scan_session(tp, files_state)

    total = aggregate_total(files_state)
    token_line = summarise_tokens(total)
    tmp = state_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, state_path)
    if token_line:
        dollar_clause = summarise_dollars(total)
        line = f"{token_line} | {dollar_clause}" if dollar_clause else token_line
        print(f"[cost-mirror] this session — {line}")


if __name__ == "__main__":
    if "--report" in sys.argv:
        # report mode is intentionally NOT wrapped in the silent-fail guard
        sys.exit(run_report([a for a in sys.argv[1:] if a != "--report"]))
    try:
        main()
    except Exception:
        pass  # fail silent and open: a broken mirror must never break a prompt
    sys.exit(0)
