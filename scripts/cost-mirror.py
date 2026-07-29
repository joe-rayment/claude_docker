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

Billing mode: this template runs under both a raw API key and a Claude
subscription. Under a subscription the dollar figure isn't a bill, it's
what the session would have cost on the API — same math, different label
("API-equiv"). COST_MIRROR_BILLING=api|sub forces the mode; otherwise it's
auto-detected (see detect_billing_mode): an ANTHROPIC_API_KEY/
ANTHROPIC_AUTH_TOKEN in the environment means "api", else the presence of
claudeAiOauth.subscriptionType in ~/.claude/.credentials.json means "sub",
else it defaults to "api". Billing mode is a render-time label only, never
part of the persisted state.

Failure posture: fail SILENT AND OPEN — any error prints nothing and exits 0.
Env: COST_MIRROR_DISABLE=1 bypasses; COST_MIRROR_STATE_DIR overrides the
state directory (tests); COST_MIRROR_CREDENTIALS_PATH overrides the
credentials file consulted for billing-mode auto-detection (tests);
COST_MIRROR_PROJECTS_DIR overrides the ~/.claude/projects root that --all
scans (tests).

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

Cross-session report: `cost-mirror --report --all [--since <N>d]` scopes
the report to every transcript found on disk, independent of any live
session — every ~/.claude/projects/*/*.jsonl plus each one's beside-it
subagents/*.jsonl (no positional transcript argument in this mode).
--since 7d/30d/etc limits it to transcripts modified in that window;
without it every transcript is included. Output is a per-session table
(project, short session id, last-modified date, total tokens, actual $,
newest first) followed by the same per-side|model breakdown and grand
total render_report produces for a single session. Because this can mean
scanning hundreds of files, it keeps its own persisted incremental cache —
a dedicated `all-sessions.json` in the state dir, keyed by file path with
the same {off, agg} shape as the hook's per-session state — so repeat runs
only read appended bytes; this cache is separate from the hook's
per-session state files, and plain `--report` (no --all) still never
writes any state at all.
"""

import glob
import hashlib
import json
import os
import sys
import time
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


def detect_billing_mode():
    """(mode, detail) where mode is "api" or "sub" and detail is a short
    human-readable string naming the signal used, for the --report line.

    Precedence: COST_MIRROR_BILLING=api|sub forces it. Otherwise auto-detect:
    an API key/token in the environment means requests are billed per-token
    regardless of any OAuth credentials also present, so that wins first.
    Failing that, ~/.claude/.credentials.json (the Claude Code OAuth/login
    credential store) is inspected for claudeAiOauth.subscriptionType — its
    presence means this session authenticates via a Claude subscription, not
    an API key, which is the most reliable signal available in this
    environment (checked live: no ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN is
    set here, and the credentials file carries subscriptionType "max"). If
    neither signal is found, default to "api" (today's behaviour) rather
    than guess."""
    forced = os.environ.get("COST_MIRROR_BILLING")
    if forced in ("api", "sub"):
        return forced, "forced via COST_MIRROR_BILLING"
    if os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"):
        return "api", "auto: API key/token in env"
    cred_path = os.environ.get("COST_MIRROR_CREDENTIALS_PATH") or os.path.expanduser(
        "~/.claude/.credentials.json"
    )
    try:
        with open(cred_path) as fh:
            creds = json.load(fh)
        oauth = creds.get("claudeAiOauth")
        if isinstance(oauth, dict) and oauth.get("subscriptionType"):
            return "sub", f"auto: oauth creds (subscriptionType={oauth['subscriptionType']})"
    except Exception:
        pass
    return "api", "auto: no billing signal found, defaulting to api"


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
    """One compact clause per side: in/out/cache-read/cache-write token counts,
    each omitted when zero so a quiet session (e.g. a worker with no cache
    writes) stays short. Order is in, out, cache-r, cache-w."""
    parts = []
    for side in ("main", "workers"):
        skey = "main" if side == "main" else "worker"
        rows = [(k.split("|", 1)[1], v) for k, v in total.items() if k.startswith(skey + "|")]
        if not rows:
            continue
        rows.sort(key=lambda r: -(r[1]["out"] + r[1]["cr"]))
        n_in = sum(v["in"] for _, v in rows)
        n_out = sum(v["out"] for _, v in rows)
        n_cr = sum(v["cr"] for _, v in rows)
        n_cw = sum(v["w5"] + v["w1"] for _, v in rows)
        models = ", ".join(m.replace("claude-", "") for m, _ in rows[:3])
        comps = []
        if n_in:
            comps.append(f"{fmt(n_in)} in")
        if n_out:
            comps.append(f"{fmt(n_out)} out")
        if n_cr:
            comps.append(f"{fmt(n_cr)} cache-r")
        if n_cw:
            comps.append(f"{fmt(n_cw)} cache-w")
        if not comps:  # all-zero usage row: keep the side visible rather than blank
            comps = ["0 out"]
        parts.append(f"{side}: {' · '.join(comps)} ({models})")
    return " | ".join(parts)


def pick_top_model(total):
    """Counterfactual reference model: the most EXPENSIVE model among main
    rows, ranked by output rate from rates_for (unknown-rate models rank
    below every known-rate model), tiebroken by (out+cr) volume descending.
    Price, not volume, is what matters — a session that ran mostly on a
    cheap model and briefly on a pricier one must still reprice everything
    at the pricier tier, otherwise the pricier tokens reprice DOWN and
    "saved" reads as a large, misleading negative. If there are no main rows
    at all, fall back to the most expensive model observed overall (ranked
    by output rate; unknown models rank last)."""
    main_rows = [(k.split("|", 1)[1], v) for k, v in total.items() if k.startswith("main|")]
    if main_rows:
        def sort_key(row):
            model, counters = row
            rates = rates_for(model)
            rate = rates["out"] if rates else -1.0
            return (-rate, -(counters["out"] + counters["cr"]))

        main_rows.sort(key=sort_key)
        return main_rows[0][0]
    best, best_rate = None, -1.0
    for key in total:
        model = key.split("|", 1)[1]
        rates = rates_for(model)
        rate = rates["out"] if rates else -1.0
        if best is None or rate > best_rate:
            best, best_rate = model, rate
    return best


def summarise_dollars(total, billing_mode="api"):
    """Actual dollar cost, plus an "at top model" counterfactual and the
    resulting savings, as a compact clause (or "" if there's nothing to
    show). Unknown-priced models still contribute their tokens to the token
    summary but cost $0 here and mark the clause with a trailing '?'.

    billing_mode "sub" means this session is paid for via a Claude
    subscription rather than per-token API billing: the math is identical,
    but the leading figure isn't a bill, it's what the session would have
    cost on the API, so it is labelled "API-equiv"."""
    if not total:
        return ""
    models_seen = {key.split("|", 1)[1] for key in total}
    unknown = any(rates_for(m) is None for m in models_seen)
    actual = sum(cost(counters, rates_for(key.split("|", 1)[1])) for key, counters in total.items())

    clause = f"~{fmt_usd(actual)}"
    if unknown:
        clause += "?"
    if billing_mode == "sub":
        clause += " API-equiv"

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
        glob.glob(os.path.join(_projects_dir(), "*", "*.jsonl")),
        key=lambda p: os.path.getmtime(p),
        reverse=True,
    )
    return projects[0] if projects else None


def _parse_since(raw):
    """'7d' / '30d' -> 7 / 30 (int days). Only the '<N>d' form is accepted;
    raises ValueError with a usable message on anything else."""
    raw = raw.strip()
    if not raw.endswith("d") or not raw[:-1].isdigit():
        raise ValueError(f"--since expects e.g. 7d or 30d, got {raw!r}")
    return int(raw[:-1])


def _projects_dir():
    return os.environ.get("COST_MIRROR_PROJECTS_DIR") or os.path.expanduser(
        "~/.claude/projects"
    )


def _list_transcripts(since_days=None):
    """Every top-level session transcript under <projects_dir>/*/*.jsonl
    (NOT the beside-it subagents/*.jsonl — those are pulled in per-session by
    scan_session), newest-mtime first, optionally limited to files modified
    within the last since_days days."""
    paths = glob.glob(os.path.join(_projects_dir(), "*", "*.jsonl"))
    if since_days is not None:
        cutoff = time.time() - since_days * 86400
        paths = [p for p in paths if os.path.getmtime(p) >= cutoff]
    return sorted(paths, key=os.path.getmtime, reverse=True)


def _session_file_paths(tp):
    """[tp] plus its beside-it subagents/*.jsonl — the same file set
    scan_session() scans for one session, recomputed here (read-only glob,
    scan_session itself is untouched) so --all can group the flat cross-
    session cache back into per-session rows."""
    subdir = os.path.join(os.path.splitext(tp)[0], "subagents")
    return [tp] + sorted(glob.glob(os.path.join(subdir, "*.jsonl")))


def _all_state_path():
    """Path to the --all incremental cache. Deliberately a single dedicated
    file, separate from the hook's per-session state files (named by a
    sha256 hash of their transcript path) that live in the same directory —
    plain `--report` must keep writing no state at all; only --report --all
    ever touches this file."""
    return os.path.join(_state_dir(), "all-sessions.json")


def _load_all_cache():
    path = _all_state_path()
    try:
        with open(path) as fh:
            data = json.load(fh)
    except Exception:
        data = {}
    if data.get("v") != STATE_VERSION:  # old/missing schema: rescan clean
        data = {}
    data["v"] = STATE_VERSION
    data.setdefault("files", {})
    return data


def _save_all_cache(data):
    path = _all_state_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh)
    os.replace(tmp, path)


def render_all_sessions_table(session_rows, since_days=None):
    """One row per transcript — project dir, short session id, last-modified
    date, total tokens, actual $ — sorted by most recent first."""
    scope = f" (modified in the last {since_days}d)" if since_days is not None else ""
    lines = [f"cost-mirror report --all{scope} — {len(session_rows)} session(s)", ""]
    cols = ("project", "session", "modified", "tokens", "actual $")
    widths = (40, 10, 12, 9, 10)

    def fmt_row(values):
        return "".join(
            v.ljust(w) if i < 3 else v.rjust(w) for i, (v, w) in enumerate(zip(values, widths))
        )

    header = fmt_row(cols)
    lines += [header, "-" * len(header)]
    for row in sorted(session_rows, key=lambda r: -r["mtime"]):
        modified = date.fromtimestamp(row["mtime"]).isoformat()
        project = row["project"]
        if len(project) > widths[0] - 1:
            project = project[: widths[0] - 2] + "…"
        lines.append(fmt_row((
            project, row["session"], modified, fmt(row["tokens"]), fmt_usd(row["actual"]),
        )))
    return "\n".join(lines)


def run_report_all(since_days):
    """--report --all entry point: aggregate every transcript under
    ~/.claude/projects/*/*.jsonl (plus each one's beside-it
    subagents/*.jsonl), optionally scoped to --since. Reuses scan_session()/
    aggregate_total() unchanged per-file and per-session; only the grouping
    and cache bookkeeping here are new. NOT fail-silent, like plain
    --report — a transcript-free corpus prints a message and exits nonzero."""
    transcripts = _list_transcripts(since_days)
    if not transcripts:
        scope = f" modified in the last {since_days}d" if since_days is not None else ""
        print(
            f"cost-mirror --report --all: no transcript files found under "
            f"{os.path.join(_projects_dir(), '*', '*.jsonl')}{scope}",
            file=sys.stderr,
        )
        return 1

    cache = _load_all_cache()
    files_state = cache["files"]  # persisted across runs: path -> {off, agg}

    session_rows = []
    selected_state = {}  # this run's scope only (cache may hold more history)
    for tp in transcripts:
        scan_session(tp, files_state)
        paths = [p for p in _session_file_paths(tp) if p in files_state]
        session_state = {p: files_state[p] for p in paths}
        selected_state.update(session_state)
        session_total = aggregate_total(session_state)
        tokens = sum(sum(c.values()) for c in session_total.values())
        actual = sum(
            cost(c, rates_for(key.split("|", 1)[1])) for key, c in session_total.items()
        )
        session_rows.append({
            "project": os.path.basename(os.path.dirname(tp)),
            "session": os.path.splitext(os.path.basename(tp))[0][:8],
            "mtime": os.path.getmtime(tp),
            "tokens": tokens,
            "actual": actual,
        })

    _save_all_cache(cache)

    grand_total = aggregate_total(selected_state)
    billing_mode, billing_detail = detect_billing_mode()
    since_label = f", since {since_days}d" if since_days is not None else ""
    label = f"ALL sessions ({len(transcripts)} transcripts{since_label})"

    print(render_all_sessions_table(session_rows, since_days))
    print()
    print(render_report(label, grand_total, billing_mode, billing_detail))
    return 0


def render_report(tp, total, billing_mode="api", billing_detail=""):
    """Human-readable per-side|model table: token counts plus actual/at-top/
    saved dollars, with a totals row. cache-write is shown as one combined
    column (w5+w1) for compactness.

    A "billing: ..." line naming the mode/detection signal is always
    emitted, in both api and sub mode. billing_mode "sub" additionally
    marks the money columns as API-equivalent (subscription billing, not a
    per-token bill) without altering the table's column layout."""
    top = pick_top_model(total)
    top_rates = rates_for(top) if top else None

    lines = [f"cost-mirror report — {tp}"]
    mode_label = "subscription" if billing_mode == "sub" else "API"
    equiv_note = " — dollars are API-equivalent" if billing_mode == "sub" else ""
    lines.append(f"billing: {mode_label} ({billing_detail}){equiv_note}")
    if top:
        note = ""
        if top.startswith("claude-sonnet-5") and date.today() < SONNET5_INTRO_CUTOFF:
            note = " (sonnet-5 intro pricing active)"
        lines.append(f"top model (counterfactual): {top.replace('claude-', '')}{note}")
    else:
        lines.append("top model (counterfactual): none (no rows scanned)")
    lines.append("")

    money_suffix = "*" if billing_mode == "sub" else ""
    cols = (
        "side", "model", "in", "out", "cache-r", "cache-w",
        f"actual ${money_suffix}", f"at-top ${money_suffix}", f"saved ${money_suffix}",
    )
    # token columns at 11 (not 9) so a --all grand total (routinely 9-digit
    # cache-r/cache-w counts) never runs two numbers together with no gap
    widths = (7, 28, 11, 11, 11, 11, 10, 10, 10)

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
    directly from a terminal rather than from the hook.

    --all switches to cross-session mode (see run_report_all): every
    transcript is read directly off disk, independent of any live session,
    and no positional transcript argument is accepted. --since <N>d (e.g.
    7d, 30d) narrows --all to transcripts modified in that window; it is
    a no-op without --all, since single-transcript mode has nothing to
    filter."""
    all_mode = False
    since_days = None
    positional = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--all":
            all_mode = True
            i += 1
        elif arg == "--since" or arg.startswith("--since="):
            if arg == "--since":
                if i + 1 >= len(argv):
                    print("cost-mirror --report: --since requires a value, e.g. --since 7d", file=sys.stderr)
                    return 1
                raw, i = argv[i + 1], i + 2
            else:
                raw, i = arg.split("=", 1)[1], i + 1
            try:
                since_days = _parse_since(raw)
            except ValueError as exc:
                print(f"cost-mirror --report: {exc}", file=sys.stderr)
                return 1
        else:
            positional.append(arg)
            i += 1

    if all_mode:
        return run_report_all(since_days)

    tp = positional[0] if positional else _default_transcript()
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
    billing_mode, billing_detail = detect_billing_mode()
    print(render_report(tp, aggregate_total(files_state), billing_mode, billing_detail))
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
        billing_mode, _ = detect_billing_mode()
        dollar_clause = summarise_dollars(total, billing_mode)
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
