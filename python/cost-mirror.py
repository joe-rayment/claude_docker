#!/usr/bin/env python3
"""cost-mirror -- UserPromptSubmit hook: one-line, by-model token spend for
the current session, injected as context each prompt.

Why: the orchestrator is asked to keep spend on the cheap tiers but has no
in-session view of what anything costs. This prints one compact line
("main: ... | workers: ...") derived from the live transcript, so the cost
of working inline vs delegating is visible at the moment the choice is
made. It constrains nothing.

Mechanics: UserPromptSubmit stdout on exit 0 is added to the model's
context. The main transcript and every subagents/**/*.jsonl beneath it
(recursive, so workflow-spawned agents one directory deeper are included
too) are scanned INCREMENTALLY -- a per-session state file under
$CLAUDE_CONFIG_DIR/cache/cost-mirror/ keeps a byte offset and running
totals per file, so each prompt parses only appended lines (a
shrunk/rotated file rescans from zero). Assistant rows are aggregated by
message.model: rows with isSidechain or living under subagents/ count as
worker spend, split by role (see "Per-role attribution"); the rest as
main. Input, output, cache-read, and cache-write (5m/1h split when the row
breaks it out) tokens are all tracked, de-duplicated first (see
"Per-response de-duplication"). A static per-model USD/MTok pricing table
(prefix-matched, see PRICING_TABLE) turns those into an actual dollar
figure, plus a counterfactual "saved" figure (see "Delegation-only
savings"). Unknown/off-ladder models still show their tokens but cost $0
and mark the line with a trailing '?'. "<synthetic>" rows are skipped.

Per-response de-duplication: a single API response is written to the
transcript as SEVERAL assistant rows sharing one message.id -- one row per
content block (thinking/text/tool_use) -- and each row repeats the parent
response's usage in full EXCEPT output_tokens, which is CUMULATIVE across
the group. Counting every row as a full response overstated spend by
~2.17x machine-wide. scan_file counts in/cache-r/cache-w ONCE per
message.id (on the group's first row) and takes the running max for
output, via a small per-session dedup ring (fstate["dd"], capped at
DEDUP_RING entries) so a group split across an incremental scan boundary
still dedupes. Once >= DEDUP_RING other ids arrive, the ring evicts the
oldest entry; evicted ids move into a larger, separately-bounded set
(fstate["dd_evicted"], capped at DEDUP_EVICTED_RING) that still suppresses
re-adding in/cache-r/cache-w on that mid's later rows, at the cost of no
longer knowing its running-max output -- a bounded imprecision confined to
output alone (see _dedup_seen/_dedup_note). The ring is SESSION-scoped,
not per-file (homed in the main transcript's own fstate entry, shared by
every file scan_session scans for that session): a message.id can appear
in two files of one session (e.g. an isSidechain row inline in the main
transcript and a full row in a co-located subagent transcript), and both
must dedupe against each other. A row with no message.id (e.g. a
hand-crafted test fixture) is never deduped, counted in full. A
truncated/rotated file's fstate.clear() (see scan_file) wipes that file's
own off/agg/bagg; if it's the main transcript this also wipes the shared
ring, degrading the session to pre-dedup behaviour until it repopulates --
an accepted, bounded corner.

Per-role attribution: each subagent transcript is labelled "worker:<role>"
from its co-located sidecar agent-<ID>.meta.json (see _agent_label) -- the
role is meta["customAgentType"] if present, else meta["agentType"]. NAMED
spawns put the spawn's *name* in agentType and the true role in
customAgentType (e.g. {"agentType": "benchbase", "customAgentType":
"executor"}, or a model-bearing name like "executor-sonnet-5"), so
agentType alone would misfile or undercount roles; customAgentType is
read first so a model-bearing name still folds into the right
"worker:<role>" without duplicating the model into the label (the "model"
column already carries it, from message.model -- the actual resolved
model, never the literal "inherit" a subagent's frontmatter may specify).
A missing/unreadable sidecar, or one with neither key, falls back to bare
"worker". Every consumer that used to compare a side to the literal string
"worker" (summarise_tokens, session_delegation_savings, render_report) now
treats "not main" as the worker test, so a per-role row is never silently
dropped.

Cost-sorted rows: render_report's per-side rows sort by the row's own real
dollar cost (the same figure the "actual $" column shows), descending,
tiebroken by model id ascending for byte-identical output across repeated
runs on the same input. Side grouping ("main" first, then each
worker/worker:<role> alphabetically) is unchanged and is a different axis
from the within-side cost order -- it's kept so a cheap "main" row doesn't
get buried under pricier worker rows.

Delegation-only savings: "saved" means spend that would not have happened
without delegating to a cheaper WORKER model -- never spend saved by
running the orchestrator itself on a cheaper tier (an early version priced
every row, main-loop included, against the single most expensive model
seen anywhere in the session, which conflated a /tier downgrade of the
orchestrator with real delegation). Fixed via per-session TIER EPOCHS:
main-loop rows are ordered by timestamp and split into maximal runs
sharing the same message.model (_epochs_from_main_buckets); each worker
row reprices only against the epoch its own timestamp falls into, and a
main-loop row's tier IS its own epoch, so main-loop spend can never show
up as "saved". Rows are bucketed into BUCKET_SECONDS (5-minute) windows
rather than compared row-by-row, so persisted state grows with wall-clock
session length, not row count. The first epoch's start and the last
epoch's end are CLAMPED to cover the WHOLE session timeline (not just the
span between the first and last main-loop row), so a worker row is always
attributed to the tier in effect at its timestamp rather than contributing
zero just for falling outside the recorded main-loop span. An interior gap
between two epochs belongs to the EARLIER one ("in effect at", not
"nearest in time"). The one case that still contributes zero: a worker row
with no parseable timestamp of its own in a session whose main rows DO
have usable timestamps. A session where NO row has a usable timestamp
collapses to one NA_BUCKET epoch spanning the whole session -- the
pre-epoch whole-session behaviour. Epochs are always computed and summed
PER SESSION, never merged across sessions, so one session's tier change
can never reprice another's spend.

Overdrive: `tier-set overdrive` lifts the worker cap and parks
.env.TIER_OVERDRIVE="1" in the settings file (TIER_SETTINGS_PATH,
overridable via COST_MIRROR_SETTINGS_PATH for tests; only the literal "1"
counts, matching tier-gate/tier-reconcile). While set, workers run the TOP
model, so there is no cheaper tier for "saved" to be counterfactual
against -- the hook line prints a flat "tier savings n/a (OVERDRIVE)" in
place of the "· ~$X at <top> → saved ~$Y" clause. This covers the HOOK
line only; `--report`'s at-top/saved COLUMNS still compute the same
counterfactual per row.

Billing mode: this template runs under both a raw API key and a Claude
subscription. Under a subscription the dollar figure isn't a bill, it's
what the session would have cost on the API ("API-equiv"). Billing mode is
a render-time label only, never part of persisted state (see
detect_billing_mode).

Pricing snapshot: PRICING_TABLE is a hand-kept guess (cache rates derived
from the input rate at x0.1/x1.25/x2.0). `cost-mirror.py --refresh-pricing`
fetches litellm's model_prices_and_context_window.json, which publishes
all five rate classes per model, and writes a snapshot to <state dir>/
pricing/snapshot.json. rates_for() resolves the snapshot first
(longest-prefix per model), then the baked table, and returns provenance
("source", "fetched_at", "pricing_id") alongside the rates. The refresh is
TTL-gated, silent on success, and exits 0 on every failure with the
previous snapshot untouched -- an unreachable network is normal here.
sonnet-5 is the one place the two sources can disagree on purpose:
_sonnet5_rates() reverts to 3/15 at SONNET5_INTRO_CUTOFF while a stale
snapshot may still quote the intro 2/10 -- the date-aware baked value wins
over a stale/disagreeing snapshot (see rates_for's exposure notes).

Failure posture: fail SILENT AND OPEN -- any error prints nothing and
exits 0. Env: COST_MIRROR_DISABLE=1 bypasses (the pricing refresh too);
COST_MIRROR_STATE_DIR overrides the state directory (tests);
COST_MIRROR_CREDENTIALS_PATH overrides the credentials file consulted for
billing-mode auto-detection (tests); COST_MIRROR_SETTINGS_PATH overrides
the settings file the overdrive flag is read from (tests);
COST_MIRROR_PROJECTS_DIR overrides the $CLAUDE_CONFIG_DIR/projects root
that --all scans (tests); COST_MIRROR_PRICING_PATH, _URL, _TTL (seconds,
0 = always stale) and _TIMEOUT override the pricing snapshot's file,
source, refresh interval and fetch timeout (tests).

Delegation-gate drift segment: scripts/delegation-gate.py persists
{"max_streak", "warns", "denies"} per session as a record of main-loop
grinding, independent of anything reported here. The hook line appends a
" | inline: max streak N · W warn(s) · D deny/denies" clause read from
that session's state file ($CLAUDE_CONFIG_DIR/cache/delegation-gate/
<session_id>.json). This module does NOT import delegation-gate.py -- its
state-dir path is duplicated locally (DELEGATION_GATE_STATE_DIR) to keep
the two scripts decoupled. Omitted when there's nothing to report
(max_streak 0, no warns/denies) or the state file is missing/unreadable/
malformed.

Complexity-router lanes: scripts/lane.sh classifies each prompt into an
express/standard/deep lane and appends every declaration to
${LANE_STATE_DIR:-$CLAUDE_CONFIG_DIR/cache/lane}/log.jsonl. This module
joins that log on two surfaces: (1) the hook line gains a trailing
" | lane last-turn: <x>" segment -- "last-turn" because `lane --reset` runs
as a UserPromptSubmit hook BEFORE cost-mirror, so the state file already
reads "unset" by render time; the log is the only honest source and can
only report the PREVIOUS turn's lane. (2) `--report` grows a "lanes"
section with per-lane declaration counts (session + all-time) and the
escalation rate, annotated with its 5-15% target band. Both fail open -- a
missing/unreadable log omits the lane surface entirely; neither surface
ever creates the lane directory, since a report must stay read-only with
respect to state.

CLI (`cost-mirror --report`, aliased `tier-cost`): bare or `--all`
aggregates every transcript on disk into one report; `--session <prefix>`,
`--this` (the transcript the most recent hook run used) or a direct
transcript path narrow to one session, read-only with respect to all
state. `--since <N>d` scopes the aggregate view to transcripts modified in
that window. `--csv <path>` additionally exports the ledger rows behind
whichever view ran (see write_rows_csv) -- full precision, one row per
(session, side, model, time bucket). Unlike hook mode this path is NOT
fail-silent: a missing/unreadable/ambiguous transcript, or an unrecognised
flag, prints to stderr and exits nonzero. See run_report() for exact
dispatch order and write_rows_csv/render_report for the two output shapes.

Durable lifetime rollup: transcripts get deleted (disk-cleanup, manual
pruning), which would otherwise erase their spend from future aggregate
reports. Both the hook and the aggregate report path write this session's
rows into `lifetime.json` in the state dir, keyed
`sessionId|side|model|bucket`, each carrying the RATES that priced it,
frozen the first time the row is written -- a later rescan re-derives
tokens but never re-prices history, so a report after a price change
prices new rows only. Rows are REPLACED per session every time (never
incremented), so rescanning cannot inflate the durable total. A v3 file
(older schema, no buckets, no rates) is migrated in place to legacy rows
marked `pricing_source: unknown`, still priced live at report time. The
aggregate report unions live-scanned transcripts with lifetime rows whose
transcript is gone from disk, so a deleted session's spend still counts;
single-session views never touch lifetime.json.
"""

import csv
import glob
import hashlib
import json
import os
import sys
import time
from datetime import date, datetime, timezone


def _claude_config_dir():
    """Resolves the Claude config dir: $CLAUDE_CONFIG_DIR if set, else the
    default under the user's home directory (kept out of a single literal
    here on purpose -- see scripts/lib/paths.sh's header and the grep gate
    in tests/config-sync.bats)."""
    override = os.environ.get("CLAUDE_CONFIG_DIR")
    if override:
        return override
    return os.path.join(os.path.expanduser("~"), ".claude")


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


STATE_VERSION = 4  # bump forces a one-time clean rescan of persisted scan
# state: v3 counted each content-block row of one API response as if it
# were a full response (see "Per-response de-duplication" above), and also
# predates per-role "worker:<role>" labels, so an old state must not be
# trusted forward.
LIFETIME_VERSION = 4  # separate from STATE_VERSION on purpose: this ledger
# schema (rows keyed per (session, side, model, bucket), each carrying the
# rates that priced it -- see the row ledger below) can change independently
# of the scan-state schema, and a future scan-state-only bump should not
# force-wipe durable lifetime history that has nothing wrong with it. A v3
# lifetime file is migrated in place (_migrate_v3_rows), not wiped -- its
# counters are sound, only per-bucket granularity and rate provenance are
# missing.
COUNTER_KEYS = ("in", "out", "cr", "w5", "w1")

# msg_segment's finishing-message word cap, overridable via
# CLAUDE_ORCA_MSG_CAP -- kept as one module constant so config/claude-user-
# memory.md's "≤ 100 words" rule and this readout can never drift apart
# (see tests/message-cap.bats's lockstep case).
MSG_CAP_DEFAULT = 100

# De-dup ring size for scan_file's per-message.id state (see _dedup_seen/
# _dedup_note below): duplicate rows for one message.id are contiguous in
# the OVERWHELMING common case, so a short ring survives an incremental
# scan boundary without growing state unboundedly.
DEDUP_RING = 8

# Once a mid falls off DEDUP_RING (its group still open), it moves into
# this larger, separately-bounded set (fstate["dd_evicted"]; see
# _dedup_note) so a later row for it still suppresses re-adding
# in/cache-r/cache-w rather than being double-counted as an untracked id's
# first row. Bare ids only (no per-id counters), so it's cheap to keep much
# larger than DEDUP_RING -- see tests/tier-hooks.bats for the reproduction.
DEDUP_EVICTED_RING = 512

# _dedup_seen's sentinel for "mid was seen before, but its live-ring entry
# was evicted" (see DEDUP_EVICTED_RING above) -- distinct from None (never
# seen at all) and from a real running-max output value, which is never
# negative.
_DEDUP_EVICTED = -1

# Tier-epoch bucketing (see "Delegation-only savings" above): rows are
# grouped into BUCKET_SECONDS-wide time buckets, keyed like "agg" already
# is ("side|model|bucket"). 5 minutes keeps a long session's bucket count
# small (state grows with wall-clock time, not row count) while still
# resolving a real /tier change to the epoch it happened in.
BUCKET_SECONDS = 300
NA_BUCKET = -1  # sentinel for a row with no usable timestamp; see _parse_ts

# sonnet-5 intro pricing (2.00/10.00 per MTok in/out) holds while today is
# strictly before this date; from then on it reverts to the standard 3/15.
SONNET5_INTRO_CUTOFF = date(2026, 9, 1)

# scripts/delegation-gate.py OWNS this path; duplicated here (not imported)
# to keep the two scripts decoupled -- see "Delegation-gate drift segment"
# above. Keep in sync by hand if delegation-gate.py ever moves its state.
DELEGATION_GATE_STATE_DIR = os.path.join(_claude_config_dir(), "cache", "delegation-gate")

# scripts/tier-set.sh OWNS this flag ("tier-set overdrive" parks
# .env.TIER_OVERDRIVE="1" here to lift the worker cap); read, not imported,
# for the same decoupling reason -- see "Overdrive" above. Matched against
# the literal "1", same as tier-gate/tier-reconcile. COST_MIRROR_SETTINGS_PATH
# overrides the path (tests).
TIER_SETTINGS_PATH = os.path.join(_claude_config_dir(), "settings.json")

# scripts/lane.sh OWNS these; duplicated here (not imported) for the same
# decoupling reason -- see "Complexity-router lanes" above.
LANE_STATE_DIR = os.path.join(_claude_config_dir(), "cache", "lane")
LANE_NAMES = ("express", "standard", "deep")
# The hook only needs THIS session's newest declaration: the byte window is
# read first and the last complete LANE_TAIL_LINES lines taken from it (a
# log row is ~150 bytes, so 64KiB comfortably covers 200), never the whole
# log.
LANE_TAIL_LINES = 200
LANE_TAIL_BYTES = 65536
# Target band from knowledge-base/TIERED_ORCHESTRATION.md: 5-15% is healthy,
# persistently under 5% means the classifier routes too heavy, over 20%
# means express is greedy.
LANE_RATE_TARGET_LOW = 5.0
LANE_RATE_TARGET_HIGH = 15.0
LANE_RATE_GREEDY = 20.0


def _sonnet5_rates(today=None):
    if (today or date.today()) < SONNET5_INTRO_CUTOFF:
        return (2.00, 10.00)
    return (3.00, 15.00)


# Static USD-per-MTok pricing, prefix-matched against message.model,
# first match wins (so "claude-sonnet-5" must precede "claude-sonnet-").
# (in, out) pairs, or a zero-arg callable for a price that varies (e.g. an
# intro-period discount). More specific prefixes precede generic fallbacks
# throughout, especially within the Opus family.
PRICING_TABLE = (
    ("claude-fable-", (10.00, 50.00)),
    ("claude-mythos-", (10.00, 50.00)),
    ("claude-opus-4-1", (15.00, 75.00)),  # Opus 4.1 (also matches 4-10+, 4-15+, ...)
    ("claude-opus-4-202", (15.00, 75.00)),  # Opus 4, date-based ids
    ("claude-opus-", (5.00, 25.00)),  # fallback: Opus 5, 4.5, 4.6+
    ("claude-sonnet-5", _sonnet5_rates),
    ("claude-sonnet-", (3.00, 15.00)),
    ("claude-haiku-", (1.00, 5.00)),
    # Claude 3 family (historical, pricing from litellm snapshot)
    ("claude-3-opus-", (15.00, 75.00)),
    ("claude-3-7-sonnet-", (3.00, 15.00)),
    ("claude-3-5-sonnet-", (3.00, 15.00)),
    ("claude-3-sonnet-", (3.00, 15.00)),
    ("claude-3-haiku-", (1.00, 5.00)),
)


# Fetched pricing snapshot: PRICING_TABLE above is a hand-kept guess (in/out
# only, cache rates derived); the snapshot replaces the guess with a
# citation from litellm's model_prices_and_context_window.json (all five
# rate classes, first-party Anthropic included) without replacing the
# table -- an install that never fetched, whose fetch failed, or whose
# model isn't listed resolves exactly the baked figures.
PRICING_SCHEMA = 1
PRICING_SOURCE = "litellm"
PRICING_URL = (
    "https://raw.githubusercontent.com/BerriAI/litellm/main/"
    "model_prices_and_context_window.json"
)
# Upstream publishes USD *per token*; cost() works in USD/MTok, so every rate
# is scaled by 1e6 on the way in and rounded to PRICING_ROUND decimals --
# 2e-07 * 1e6 is 0.19999999999999998 in raw float, one ULP off the 0.2 the
# baked table produces, which would make an otherwise-identical rate compare
# unequal.
PRICING_PER_MTOK = 1_000_000
PRICING_ROUND = 10
# The same litellm file also carries this model under bedrock/vertex tags at
# different prices (a different litellm_provider and a "/"-qualified key);
# both are excluded -- this hook prices first-party API usage only.
PRICING_PROVIDER = "anthropic"
# litellm field -> cost-mirror counter key. An entry missing ANY of these is
# skipped entirely rather than back-filled from the multipliers -- cost()
# indexes all five, and a half-cited rate is exactly the guess this replaces.
PRICING_FIELDS = (
    ("in", "input_cost_per_token"),
    ("out", "output_cost_per_token"),
    ("cr", "cache_read_input_token_cost"),
    ("w5", "cache_creation_input_token_cost"),
    ("w1", "cache_creation_input_token_cost_above_1hr"),
)
PRICING_TTL_SECONDS = 24 * 3600  # published rates change on the order of months
PRICING_TIMEOUT = 20.0  # the live list is ~1.8MB; measured ~1.4s in-container
PRICING_MAX_BYTES = 32 * 1024 * 1024
PRICING_MAX_AGE_SECONDS = 72 * 3600  # read-side max-age, independent of fetch TTL
# Past this age, a snapshot entry loses to the baked table per model.


def _pricing_path():
    """The snapshot file. A SUBDIRECTORY of the state dir on purpose: the
    hook's per-session state files are found by globbing "<state dir>/*.json",
    so a sibling snapshot would show up as a phantom session."""
    return os.environ.get("COST_MIRROR_PRICING_PATH") or os.path.join(
        _state_dir(), "pricing", "snapshot.json"
    )


# (stat-key, parsed snapshot or None). rates_for is called once per row per
# render, so the file is parsed once and re-validated only when its
# path/mtime/size changes — a stat per call, never a re-parse.
_PRICING_CACHE = (None, None)


def _load_pricing_snapshot():
    """The current pricing snapshot, or None if there isn't a usable one.

    "Usable" is checked, not assumed: a missing, unreadable, malformed,
    or FUTURE-schema file all yield None and send rates_for to the baked
    table. Guessing at a shape this version doesn't know would be worse than
    the guess the snapshot exists to remove."""
    global _PRICING_CACHE
    path = _pricing_path()
    try:
        st = os.stat(path)
        key = (path, st.st_mtime_ns, st.st_size)
    except OSError:
        _PRICING_CACHE = ((path, None, None), None)
        return None
    if _PRICING_CACHE[0] == key:
        return _PRICING_CACHE[1]
    snap = None
    try:
        with open(path) as fh:
            raw = json.load(fh)
        if (
            isinstance(raw, dict)
            and raw.get("schema") == PRICING_SCHEMA
            and isinstance(raw.get("rates"), dict)
            and isinstance(raw.get("source"), str)
            and raw["source"]
            and isinstance(raw.get("fetched_at"), str)
        ):
            snap = raw
    except Exception:
        snap = None
    _PRICING_CACHE = (key, snap)
    return snap


def _snapshot_rates(model, snap):
    """(matched key, {in,out,cr,w5,w1}) for `model` in a loaded snapshot, or
    None if it carries no usable entry for it.

    Matching is longest-prefix, which subsumes an exact match (a model id is
    its own longest prefix) and is what makes real transcript ids resolve:
    upstream keys the flat "claude-opus-4-6" while a transcript row says
    "claude-opus-4-6-20260205" or "claude-fable-5-1[1m]". Longest wins so a
    dated opus-4-6 id can never be captured by a shorter, cheaper key."""
    rates = snap["rates"]
    best_key = None
    for key, entry in rates.items():
        if not isinstance(entry, dict) or not model.startswith(key):
            continue
        if best_key is None or len(key) > len(best_key):
            best_key = key
    if best_key is None:
        return None
    try:
        return best_key, {k: float(rates[best_key][k]) for k in COUNTER_KEYS}
    except (KeyError, TypeError, ValueError):
        return None


def rates_for(model):
    """USD/MTok rates for a model id: {in, out, cr, w5, w1}, or None if it
    matches neither the fetched snapshot nor any baked pricing prefix
    (off-ladder/unknown).

    Also carries provenance: "source" ("litellm" or "baked"), "fetched_at",
    and "pricing_id" ("<source>:<matched key or prefix>"). cost() and every
    other consumer index only COUNTER_KEYS and ignore the extra fields.

    Resolution is snapshot-first, PER MODEL (a model the snapshot doesn't
    carry falls through to the table on its own), with two exceptions:
    (a) a snapshot older than PRICING_MAX_AGE_SECONDS loses to the baked
    table regardless of fetch TTL; (b) when a callable PRICING_TABLE entry
    (e.g. the date-aware _sonnet5_rates) disagrees with the snapshot, the
    date-aware baked value wins."""
    if not model:
        return None
    snap = _load_pricing_snapshot()
    if snap:
        # Exposure (a): Check if snapshot is too old (read-side max-age).
        # Past that age, it loses to the baked table per model.
        snap_age_seconds = None
        snap_ts = _parse_ts(snap.get("fetched_at"))
        if snap_ts is not None:
            snap_age_seconds = time.time() - snap_ts
            if snap_age_seconds > PRICING_MAX_AGE_SECONDS:
                # Snapshot is too old; skip it and use baked table
                snap = None

    if snap:
        hit = _snapshot_rates(model, snap)
        if hit:
            key, vals = hit

            # Exposure (b): Check for disagreement with callable PRICING_TABLE entries.
            # If a callable entry exists and disagrees with the snapshot,
            # the date-aware local value wins.
            baked_vals = None
            for prefix, spec in PRICING_TABLE:
                if model.startswith(prefix) and callable(spec):
                    # This is a callable entry (e.g., _sonnet5_rates)
                    baked_rin, baked_rout = spec()
                    baked_vals = {
                        "in": baked_rin, "out": baked_rout,
                        "cr": baked_rin * 0.1, "w5": baked_rin * 1.25, "w1": baked_rin * 2.0,
                    }
                    # Check if they disagree (in or out differs)
                    if vals.get("in") != baked_rin or vals.get("out") != baked_rout:
                        # They disagree; use the baked (date-aware) value
                        return {
                            "in": baked_rin, "out": baked_rout,
                            "cr": baked_rin * 0.1, "w5": baked_rin * 1.25, "w1": baked_rin * 2.0,
                            "source": "baked", "fetched_at": None, "pricing_id": f"baked:{prefix}",
                        }
                    break

            # No disagreement; snapshot wins
            source = snap["source"]
            vals["source"] = source
            vals["fetched_at"] = snap["fetched_at"]
            vals["pricing_id"] = f"{source}:{key}"
            return vals

    for prefix, spec in PRICING_TABLE:
        if model.startswith(prefix):
            rin, rout = spec() if callable(spec) else spec
            return {
                "in": rin, "out": rout, "cr": rin * 0.1, "w5": rin * 1.25, "w1": rin * 2.0,
                "source": "baked", "fetched_at": None, "pricing_id": f"baked:{prefix}",
            }
    return None


def _pricing_env_float(name, default, floor=0.0):
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return max(floor, float(raw))
    except ValueError:
        return default


def pricing_rates_from_payload(raw):
    """{model: {in,out,cr,w5,w1}} in USD/MTok from a litellm
    model_prices_and_context_window.json payload.

    Keeps first-party Anthropic entries with a complete set of five rates
    and a flat (unqualified) key; drops everything else -- other providers,
    bedrock/vertex resale variants, litellm's own schema placeholder, and
    entries missing a cache rate."""
    if not isinstance(raw, dict):
        return {}
    out = {}
    for model, entry in raw.items():
        if not isinstance(entry, dict) or entry.get("litellm_provider") != PRICING_PROVIDER:
            continue
        if "/" in model:
            continue
        vals = {}
        for key, field in PRICING_FIELDS:
            v = entry.get(field)
            if not isinstance(v, (int, float)) or isinstance(v, bool):
                break
            vals[key] = round(float(v) * PRICING_PER_MTOK, PRICING_ROUND)
        else:
            out[model] = vals
    return out


def _write_pricing_snapshot(path, url, rates):
    """Replace the snapshot atomically: a torn write would be read as a
    malformed snapshot on the next prompt, and a refresh must never make the
    pricing WORSE than not running at all."""
    snap = {
        "schema": PRICING_SCHEMA,
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "source": PRICING_SOURCE,
        "url": url,
        "rates": rates,
    }
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as fh:
        json.dump(snap, fh)
    os.replace(tmp, path)


def refresh_pricing():
    """--refresh-pricing entry point: bring the snapshot up to date, quietly.

    TTL-gated (a snapshot fetched inside PRICING_TTL_SECONDS is left alone,
    costing one stat on a warm start), silent on success, and exit 0 on
    EVERY failure with the previous snapshot left byte-identical -- an
    unreachable network is normal here, and the fallback is the baked
    table. Always returns 0."""
    if os.environ.get("COST_MIRROR_DISABLE") == "1":
        return 0
    path = _pricing_path()
    ttl = _pricing_env_float("COST_MIRROR_PRICING_TTL", PRICING_TTL_SECONDS)
    if ttl > 0:
        snap = _load_pricing_snapshot()
        if snap:
            ts = _parse_ts(snap.get("fetched_at"))
            if ts is not None and 0 <= time.time() - ts < ttl:
                return 0
    url = os.environ.get("COST_MIRROR_PRICING_URL") or PRICING_URL
    timeout = _pricing_env_float("COST_MIRROR_PRICING_TIMEOUT", PRICING_TIMEOUT, 0.1)
    try:
        import urllib.request

        req = urllib.request.Request(url, headers={"User-Agent": "cost-mirror"})
        # urlopen's timeout is per socket OPERATION, not total elapsed time,
        # so a peer trickling a byte per window stays alive indefinitely.
        # read1 (not read, which blocks for the full count) returns whatever
        # has arrived, so the deadline is checked per arrival, not just
        # between whole reads -- measured: a 1-byte/s server held a
        # read(256k) open for a minute against a 3s timeout.
        deadline = time.monotonic() + timeout
        chunks, total = [], 0
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            while True:
                chunk = resp.read1(262144)
                if not chunk:
                    break
                total += len(chunk)
                if total > PRICING_MAX_BYTES or time.monotonic() > deadline:
                    return 0
                chunks.append(chunk)
        rates = pricing_rates_from_payload(json.loads(b"".join(chunks).decode("utf-8")))
        if not rates:
            return 0  # an empty result means the payload changed shape, not that pricing vanished
        _write_pricing_snapshot(path, url, rates)
    except Exception:
        pass
    return 0


def cost(counters, rates):
    """Dollar cost of a {in,out,cr,w5,w1} counter dict at the given rates
    (USD/MTok). Unknown rates (None) cost nothing — caller marks that fact."""
    if not rates:
        return 0.0
    return sum(counters.get(k, 0) * rates[k] for k in COUNTER_KEYS) / 1_000_000


def _empty_counters():
    return {k: 0 for k in COUNTER_KEYS}


def _parse_ts(raw):
    """Epoch seconds (float) for a transcript row's "timestamp" field
    (ISO-8601, e.g. "2026-07-29T02:00:50.115Z"), or None if raw is
    missing/not a string/unparseable. A naive (no offset/'Z') string is
    parsed as-is and its .timestamp() is taken in the local timezone --
    real transcript rows always carry the 'Z' suffix, so this only matters
    for hand-crafted/malformed input, which is exactly the case this
    returns None for anyway on any other parse failure."""
    if not raw or not isinstance(raw, str):
        return None
    try:
        s = raw[:-1] + "+00:00" if raw.endswith("Z") else raw
        return datetime.fromisoformat(s).timestamp()
    except (ValueError, TypeError):
        return None


def _state_dir():
    return os.environ.get("COST_MIRROR_STATE_DIR") or os.path.join(
        _claude_config_dir(), "cache", "cost-mirror"
    )


def detect_billing_mode():
    """(mode, detail): mode is "api" or "sub", detail is a short
    human-readable string naming the signal used, for the --report line.

    Precedence: COST_MIRROR_BILLING=api|sub forces it. Otherwise: an API
    key/token in the environment wins first (billed per-token regardless of
    any OAuth credentials also present). Failing that,
    $CLAUDE_CONFIG_DIR/.credentials.json is inspected for
    claudeAiOauth.subscriptionType -- its presence means this session
    authenticates via a Claude subscription, not an API key. If neither
    signal is found, default to "api" rather than guess."""
    forced = os.environ.get("COST_MIRROR_BILLING")
    if forced in ("api", "sub"):
        return forced, "forced via COST_MIRROR_BILLING"
    if os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"):
        return "api", "auto: API key/token in env"
    cred_path = os.environ.get("COST_MIRROR_CREDENTIALS_PATH") or os.path.join(
        _claude_config_dir(), ".credentials.json"
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


def overdrive_active():
    """True when the settings file carries tier-set's sticky worker-cap lift
    (.env.TIER_OVERDRIVE == "1", see TIER_SETTINGS_PATH and "Overdrive"
    above). Only the literal "1" counts, matching tier-gate/tier-reconcile;
    any missing/unreadable/malformed settings file is False, never a
    crash."""
    path = os.environ.get("COST_MIRROR_SETTINGS_PATH") or os.path.expanduser(
        TIER_SETTINGS_PATH
    )
    try:
        with open(path) as fh:
            settings = json.load(fh)
        env = settings.get("env")
        return isinstance(env, dict) and env.get("TIER_OVERDRIVE") == "1"
    except Exception:
        return False


def _dedup_seen(fstate, mid):
    """The highest output_tokens recorded so far for message.id `mid` in
    this file's persisted dedup ring; _DEDUP_EVICTED if `mid` WAS seen but
    its ring entry has since been evicted (see _dedup_note), so its prior
    running-max output is no longer known; or None if `mid` hasn't been
    seen at all -- i.e. this is the first row of a new content-block
    group."""
    for entry in fstate.get("dd", ()):
        if entry[0] == mid:
            return entry[1]
    if mid in fstate.get("dd_evicted", ()):
        return _DEDUP_EVICTED
    return None


def _dedup_note(fstate, mid, out):
    """Record/update the running-max output_tokens seen for message.id
    `mid`, in a ring capped at DEDUP_RING entries (oldest dropped first --
    see DEDUP_RING). Persisted as plain lists (not tuples) so it survives a
    JSON round-trip through the state file.

    An entry falling off the ring moves into fstate["dd_evicted"] (a set of
    bare ids) instead of vanishing -- see DEDUP_EVICTED_RING."""
    dd = fstate.setdefault("dd", [])
    for entry in dd:
        if entry[0] == mid:
            entry[1] = max(entry[1], out)
            return
    dd.append([mid, out])
    overflow = dd[:-DEDUP_RING]  # entries about to fall off the live ring
    if overflow:
        evicted = fstate.setdefault("dd_evicted", [])
        for entry in overflow:
            if entry[0] not in evicted:
                evicted.append(entry[0])
        del evicted[:-DEDUP_EVICTED_RING]
    del dd[:-DEDUP_RING]


def scan_file(path, assume_worker, fstate, worker_label="worker", dedup_state=None):
    """Add tokens from lines appended since the recorded offset.

    worker_label is the "side" for a row that IS a worker row
    (assume_worker=True, or row["isSidechain"]) -- bare "worker" by default,
    or "worker:<role>" for a per-role-labelled subagent transcript (see
    _agent_label / scan_session). Never affects "main" rows.

    dedup_state is the dict _dedup_seen/_dedup_note read and write --
    SESSION-scoped (the main transcript's own fstate, shared across every
    file scan_session scans for that session), so a message.id landing in
    two different files of the same session still dedupes. Defaults to
    `fstate` for a hypothetical single-file caller; scan_session always
    passes one explicitly."""
    dedup_state = fstate if dedup_state is None else dedup_state
    try:
        size = os.path.getsize(path)
    except OSError:
        return
    if size < fstate.get("off", 0):  # rotated/truncated: recount from zero
        fstate.clear()
    off = fstate.get("off", 0)
    agg = fstate.setdefault("agg", {})  # "side|model" -> {in, out, cr, w5, w1}
    bagg = fstate.setdefault("bagg", {})  # "side|model|bucket" -> counters,
    # bucket = int(ts // BUCKET_SECONDS) or NA_BUCKET (see _parse_ts) --
    # this is the ONLY extra state tier epochs need; it is intentionally
    # never used for the token/dollar totals above, only for epoch/savings
    # attribution (session_epoch_pricing).
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
        side = worker_label if (assume_worker or row.get("isSidechain")) else "main"
        delta_in = usage.get("input_tokens", 0) or 0
        delta_out = usage.get("output_tokens", 0) or 0
        delta_cr = usage.get("cache_read_input_tokens", 0) or 0
        cc = usage.get("cache_creation")
        if isinstance(cc, dict):
            delta_w5 = cc.get("ephemeral_5m_input_tokens", 0) or 0
            delta_w1 = cc.get("ephemeral_1h_input_tokens", 0) or 0
        else:
            delta_w5 = usage.get("cache_creation_input_tokens", 0) or 0
            delta_w1 = 0
        # De-dup (see "Per-response de-duplication" in the module
        # docstring): count in/cr/w5/w1 only on the group's first row; for
        # later rows, count only the marginal increase in out and zero the
        # rest. A row with no message.id is never deduped, counted in full.
        # _DEDUP_EVICTED means mid was seen but its ring entry already fell
        # off (DEDUP_EVICTED_RING) -- in/cache-r/cache-w still must NOT be
        # re-added, but its prior running-max output is gone, so this row's
        # own output is counted in full rather than marginally: a small,
        # bounded overcount confined to output alone. mid is NOT re-armed in
        # the live ring here, so a third row of the same group is still
        # treated as evicted rather than as a fresh first row.
        mid = msg.get("id")
        if mid:
            seen = _dedup_seen(dedup_state, mid)
            if seen is None:
                _dedup_note(dedup_state, mid, delta_out)
            elif seen == _DEDUP_EVICTED:
                delta_in = delta_cr = delta_w5 = delta_w1 = 0
            else:
                _dedup_note(dedup_state, mid, max(seen, delta_out))
                delta_out = max(0, delta_out - seen)
                delta_in = delta_cr = delta_w5 = delta_w1 = 0
        ts = _parse_ts(row.get("timestamp"))
        bucket = int(ts // BUCKET_SECONDS) if ts is not None else NA_BUCKET
        cur = agg.setdefault(f"{side}|{model}", _empty_counters())
        bcur = bagg.setdefault(f"{side}|{model}|{bucket}", _empty_counters())
        for target in (cur, bcur):
            target["in"] += delta_in
            target["out"] += delta_out
            target["cr"] += delta_cr
            target["w5"] += delta_w5
            target["w1"] += delta_w1
    fstate["off"] = off + end + 1


def _agent_label(path):
    """"worker:<role>" for a subagent transcript at `path`, read from its
    co-located sidecar <same-stem>.meta.json. Role is customAgentType when
    present, else bare agentType -- a NAMED spawn puts the spawn's *name* in
    agentType and the true role in customAgentType, so agentType alone
    would mislabel/fragment those rows. A missing/unreadable sidecar, or
    one with neither key, falls back to bare "worker"."""
    meta_path = os.path.splitext(path)[0] + ".meta.json"
    try:
        with open(meta_path) as fh:
            meta = json.load(fh)
        role = meta.get("customAgentType") or meta.get("agentType")
        if role:
            return f"worker:{role}"
    except Exception:
        pass
    return "worker"


def scan_session(tp, files_state):
    """Scan the main transcript plus every beside-it subagents/**/*.jsonl
    (recursive, so nested subagents/workflows/<wf_id>/agent-*.jsonl are
    included too) into files_state (a "path" -> {off, agg} dict), mutating
    it in place. Shared by hook mode (incremental, persisted) and --report
    (one-shot, throwaway).

    Each subagent transcript gets its own per-role "side" label from
    _agent_label. Every file scanned here shares ONE de-dup ring, homed in
    the main transcript's own files_state[tp] entry (tp uniquely keys this
    session even in --report --all's flat, cross-session files_state), so a
    message.id appearing in more than one file is only ever counted once."""
    main_fstate = files_state.setdefault(tp, {})
    scan_file(tp, False, main_fstate, dedup_state=main_fstate)
    subdir = os.path.join(os.path.splitext(tp)[0], "subagents")
    pattern = os.path.join(subdir, "**", "*.jsonl")
    for sub in sorted(glob.glob(pattern, recursive=True)):
        scan_file(sub, True, files_state.setdefault(sub, {}), _agent_label(sub), dedup_state=main_fstate)


def aggregate_total(files_state):
    """Merge every scanned file's agg into one "side|model" -> counters dict."""
    total = {}
    for fstate in files_state.values():
        for key, counters in fstate.get("agg", {}).items():
            cur = total.setdefault(key, _empty_counters())
            for k in COUNTER_KEYS:
                cur[k] += counters.get(k, 0)
    return total


def aggregate_bucket_total(files_state):
    """Merge every scanned file's "bagg" into one "side|model|bucket" ->
    counters dict -- the bucketed sibling of aggregate_total(), scoped to
    exactly the same files_state (so callers that pass a single session's
    files_state get a single session's bucket data, never mixed with
    another session's -- see session_epoch_pricing)."""
    total = {}
    for fstate in files_state.values():
        for key, counters in fstate.get("bagg", {}).items():
            cur = total.setdefault(key, _empty_counters())
            for k in COUNTER_KEYS:
                cur[k] += counters.get(k, 0)
    return total


def summarise_tokens(total):
    """One compact clause per side: in/out/cache-read/cache-write token
    counts, each omitted when zero. Order is in, out, cache-r, cache-w.

    "workers" means every row whose side is NOT literally "main" (plain
    "worker" and per-role "worker:<role>" rows alike) folded into one
    clause; per-role detail lives in render_report's table."""
    parts = []
    for side in ("main", "workers"):
        rows = [
            (k.split("|", 1)[1], v)
            for k, v in total.items()
            if (k.split("|", 1)[0] == "main") == (side == "main")
        ]
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
    """The most EXPENSIVE model among main rows in `total`, ranked by output
    rate from rates_for (unknown-rate models rank last), tiebroken by
    (out+cr) volume descending -- price, not volume, since a bucket that ran
    mostly cheap and briefly pricier must still pick the pricier one, or the
    pricier tokens would reprice DOWN and "saved" would read as a large,
    misleading negative. Falls back to the most expensive model observed
    overall when there are no main rows.

    Two callers today, both informational/selection only -- no longer a
    dollar driver, see session_epoch_pricing for that: (1) once per BUCKET
    inside _epochs_from_main_buckets, to pick a bucket's representative
    model when more than one main model appears in the same window; (2)
    once per session/report for the "top model (counterfactual)" display
    line and the hook line's "at <model>" label."""
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


def _epochs_from_main_buckets(bucket_total):
    """This session's tier epochs, built from its bucketed MAIN-loop rows.

    bucket_total is one session's aggregate_bucket_total() output -- never a
    multi-session merge, or a session's tier would leak into another's.

    A tier epoch is a maximal run of main-loop buckets sharing the same
    representative model, in ASCENDING bucket order (not scan/file order,
    so an out-of-order row self-corrects). A bucket with more than one main
    model is resolved by pick_top_model()'s own price-ranked pick restricted
    to that bucket.

    Returns an ascending list of (model, start_bucket, end_bucket), end
    EXCLUSIVE. Every epoch but the last has its end pulled forward to the
    next epoch's start, so an idle gap between two different models still
    belongs to the EARLIER one -- "in effect at", not "nearest in time" (see
    session_epoch_pricing). The FIRST and LAST epochs are then clamped
    outward (start pulled back, end pushed to infinity) so the union of
    epochs covers the ENTIRE session timeline, not just the span between the
    first and last main-loop row -- this is what makes a session with only
    one epoch reduce EXACTLY to the old whole-session pricing method, and
    gives every worker row a defensible epoch instead of "no evidence,
    contributes zero".

    The backward clamp uses NA_BUCKET + 1 (0), not float("-inf"): real
    bucket numbers are huge positive ints (epoch-seconds // BUCKET_SECONDS),
    so 0 absorbs any real early timestamp while not swallowing NA_BUCKET
    (-1) itself -- a worker row with no timestamp of its own must still fall
    outside a real epoch built from properly timestamped main rows. When
    every main row shares NA_BUCKET, the lone epoch's start is already
    NA_BUCKET, so the clamp is a no-op and it correctly spans to infinity --
    collapsing to "reprice everything at the session's one main-loop model".
    A session with no main rows at all returns []."""
    by_bucket = {}  # bucket -> {"main|model": counters}, main rows only
    for key, counters in bucket_total.items():
        side, model, bucket_s = key.split("|", 2)
        if side != "main":
            continue
        by_bucket.setdefault(int(bucket_s), {})[f"main|{model}"] = counters
    if not by_bucket:
        return []
    epochs = []  # [model, start_bucket, end_bucket], mutated in place below
    for bucket in sorted(by_bucket):
        model = pick_top_model(by_bucket[bucket])
        if epochs and epochs[-1][0] == model:
            epochs[-1][2] = bucket + 1
        else:
            epochs.append([model, bucket, bucket + 1])
    for i in range(len(epochs) - 1):
        epochs[i][2] = epochs[i + 1][1]  # bridge the gap to the next epoch
    epochs[0][1] = min(epochs[0][1], NA_BUCKET + 1)  # extend backward
    epochs[-1][2] = float("inf")  # extend forward
    return [tuple(e) for e in epochs]


def _epoch_model_for_bucket(epochs, bucket):
    """The tier-epoch model whose [start, end) contains `bucket`, or None
    if it falls outside every epoch — which, since _epochs_from_main_buckets
    clamps its first/last epoch to cover the whole timeline, now only
    happens for a no-main-rows session (epochs is [])."""
    for model, start, end in epochs:
        if start <= bucket < end:
            return model
    return None


# ── The row ledger ────────────────────────────────────────────────────────
# lifetime.json is a ledger of IMMUTABLE ROWS -- one per (session, side,
# model, bucket) -- and every row carries the RATES that priced it, not
# just its token counts, frozen the first time the row is written and
# carried forward verbatim by every later rescan (see build_session_rows).
# This fixes two defects an earlier schema had: collapsing the bucket
# dimension (so a deleted transcript's tier-epoch structure was lost) and
# pricing at REPORT time (so re-running after a price change silently
# re-priced history -- not theoretical, see SONNET5_INTRO_CUTOFF).


def _row_key(session_id, side, model, bucket):
    """Ledger key for one row: "session|side|model|bucket". Every field is
    ALSO stored on the row itself, so no reader has to parse it back out --
    a "worker:<role>" side (free text) and a dated model id both make
    string surgery fragile. A migrated v3 legacy row keeps its old
    three-part key, having no bucket to name (see _migrate_v3_rows)."""
    return f"{session_id}|{side}|{model}|{bucket}"


def _rates_from_row(row, prefix):
    """The five USD/MTok rates a persisted row froze under `prefix`
    ("rate_" or "rate_epoch_"), or None if it carries none -- a migrated v3
    legacy row, or a row whose model had no known rates when it was written.
    For "rate_" the row's pricing provenance rides along in the same shape
    rates_for() returns it, so a frozen rate can still cite what set it."""
    if not row:
        return None
    vals = {}
    for k in COUNTER_KEYS:
        v = row.get(f"{prefix}{k}")
        if v is None:
            return None
        vals[k] = float(v)
    if prefix == "rate_":
        vals["source"] = row.get("pricing_source") or "unknown"
        vals["fetched_at"] = row.get("pricing_fetched_at")
        vals["pricing_id"] = row.get("pricing_id")
    return vals


def _ledger_row(meta, counters, rates, epoch_model, epoch_rates):
    """One ledger row: its tokens, the rates that priced them, the dollars
    those multiply out to, and the same for its tier-epoch counterfactual
    (cost_X == tokens_X * rate_X / 1e6, cost_total their sum).

    Unpriced (rates None -- off-ladder model, or a legacy row) leaves every
    rate and cost null rather than a 0.0 that would read as "genuinely free";
    _row_pricing prices such a row live at report time instead."""
    row = dict(meta)
    row["epoch_model"] = epoch_model
    row["pricing_source"] = rates.get("source", "unknown") if rates else "unknown"
    row["pricing_fetched_at"] = rates.get("fetched_at") if rates else None
    row["pricing_id"] = rates.get("pricing_id") if rates else None
    for k in COUNTER_KEYS:
        tokens = counters.get(k, 0)
        row[f"tokens_{k}"] = tokens
        row[f"rate_{k}"] = rates[k] if rates else None
        row[f"rate_epoch_{k}"] = epoch_rates[k] if epoch_rates else None
        row[f"cost_{k}"] = tokens * rates[k] / 1_000_000 if rates else None
    row["cost_total"] = sum(row[f"cost_{k}"] for k in COUNTER_KEYS) if rates else None
    if epoch_rates:
        row["cost_at_epoch"] = sum(
            row[f"tokens_{k}"] * epoch_rates[k] / 1_000_000 for k in COUNTER_KEYS
        )
    else:
        row["cost_at_epoch"] = row["cost_total"]
    return row


def build_session_rows(session_id, tp, project, mtime, bucket_total, prior=None):
    """This session's ledger rows, keyed by _row_key, built from its bucketed
    counters (aggregate_bucket_total's output for THIS session only).

    `prior` is the ledger rows already on file: a key that's already there
    keeps the rates it was FIRST written with (a rescan re-derives tokens but
    never re-prices them); only a new key is priced at today's rates_for().
    That's what makes REPLACE-per-session write semantics compatible with
    immutable rows.

    Tokens come from `bucket_total` (scan_file's already-de-duped counters),
    never re-derived from transcript rows here.

    A MAIN row's counterfactual is itself, unconditionally -- mirroring
    session_epoch_pricing, a bucket that mixed two main-loop models resolves
    to one representative, and the loser's rows must net to zero rather than
    reprice at the winner. So a main row names its OWN model as epoch_model.
    A worker row outside every epoch (no main rows at all) keeps epoch_model
    None and prices its counterfactual at its own rates -- no savings
    claimed."""
    epochs = _epochs_from_main_buckets(bucket_total)
    prior = prior or {}
    rows = {}
    for key, counters in bucket_total.items():
        side, model, bucket_s = key.split("|", 2)
        bucket = int(bucket_s)
        rkey = _row_key(session_id, side, model, bucket)
        old = prior.get(rkey)
        rates = _rates_from_row(old, "rate_") or rates_for(model)
        if side == "main":
            epoch_model = model
            epoch_rates = rates
        else:
            epoch_model = _epoch_model_for_bucket(epochs, bucket)
            epoch_rates = None
            if epoch_model:
                # the frozen counterfactual is only reusable while it is the
                # SAME counterfactual: more main-loop rows can move an epoch
                # boundary, and repricing a worker row at a tier it now
                # provably ran under is new evidence, not rewritten history
                if old and old.get("epoch_model") == epoch_model:
                    epoch_rates = _rates_from_row(old, "rate_epoch_")
                epoch_rates = epoch_rates or rates_for(epoch_model)
            if not epoch_rates:
                epoch_rates = rates
        rows[rkey] = _ledger_row(
            {
                "sessionId": session_id, "side": side, "model": model,
                "bucket": bucket, "project": project, "mtime": mtime, "tp": tp,
            },
            counters, rates, epoch_model, epoch_rates,
        )
    return rows


def _row_pricing(row):
    """(actual $, at_epoch $) for one ledger row: the frozen dollars the row
    carries, or a live rates_for() pricing when it carries none -- a migrated
    v3 legacy row (never back-filled with rates it was not priced at) or a
    row whose model is off-ladder ($0, marked '?' in the table, as today)."""
    if row.get("cost_total") is not None:
        actual = float(row["cost_total"])
        at_epoch = row.get("cost_at_epoch")
        return actual, actual if at_epoch is None else float(at_epoch)
    counters = {k: row.get(f"tokens_{k}", 0) for k in COUNTER_KEYS}
    actual = cost(counters, rates_for(row.get("model") or ""))
    return actual, actual


def pricing_from_rows(rows):
    """Ledger rows -> the "side|model" -> {"actual", "at_epoch"} dict that
    render_report takes as `pricing` (see session_epoch_pricing). Rows from
    several sessions may be folded together here safely: each row was priced
    against its OWN session's epochs when it was written, so summing them
    cannot let one session's tier reprice another's spend."""
    out = {}
    for row in rows:
        actual, at_epoch = _row_pricing(row)
        d = out.setdefault(
            f"{row.get('side')}|{row.get('model')}", {"actual": 0.0, "at_epoch": 0.0}
        )
        d["actual"] += actual
        d["at_epoch"] += at_epoch
    return out


def session_epoch_pricing(bucket_total, rows=None):
    """Per "side|model" -> {"actual": $, "at_epoch": $}, this session's
    tier-epoch-aware counterfactual (see "Delegation-only savings" in the
    module docstring).

    MAIN rows always get at_epoch == actual, enforced unconditionally here
    (not by relying on the bucket lookup landing on the row's own model,
    since a mixed bucket resolves to one representative model and the
    non-winner's rows must still net to zero). WORKER rows reprice at the
    epoch containing their bucket; a worker outside every epoch, or with no
    parseable timestamp in an otherwise-timestamped session, keeps
    at_epoch == actual (contributes zero to savings).

    `rows` are this session's ledger rows when the caller has them (each
    already priced at the rates it was written with); without them,
    throwaway rows are built from bucket_total at today's rates."""
    if rows is None:
        rows = build_session_rows("", "", "", 0, bucket_total).values()
    return pricing_from_rows(rows)


def _add_pricing(dst, src):
    """Accumulate one session's session_epoch_pricing() output into a
    running multi-session dict, summing per "side|model" row — used by
    run_report_all to build an aggregate breakdown WITHOUT ever merging
    two sessions' bucket data (each session's epochs are computed, and
    its pricing summed, in isolation first; see run_report_all)."""
    for key, d in src.items():
        cur = dst.setdefault(key, {"actual": 0.0, "at_epoch": 0.0})
        cur["actual"] += d["actual"]
        cur["at_epoch"] += d["at_epoch"]


def session_delegation_savings(bucket_total, rows=None):
    """This session's total delegation savings: sum over WORKER "side|model"
    rows of (at_epoch - actual) from session_epoch_pricing. "worker" means
    any side that ISN'T "main" -- filtering on `not key.startswith("main|")`
    rather than `key.startswith("worker|")` so per-role "worker:<role>" rows
    are included too (an equality filter would silently drop them and
    return 0.0 "saved" for any session with role-labelled subagents).

    `rows` is this session's ledger rows when the caller has them, passed
    straight through to session_epoch_pricing so the savings figure can
    never drift from the persisted ledger."""
    pricing = session_epoch_pricing(bucket_total, rows)
    return sum(d["at_epoch"] - d["actual"] for key, d in pricing.items() if not key.startswith("main|"))


def summarise_dollars(total, bucket_total, billing_mode="api", overdrive=False, rows=None):
    """Actual dollar cost, plus an "at <model>" counterfactual and the
    resulting savings, as a compact clause (or "" if there's nothing to
    show). Unknown-priced models still contribute tokens to the token
    summary but cost $0 here and mark the clause with a trailing '?'.

    The savings figure comes from session_delegation_savings(bucket_total)
    -- summed across this session's tier epochs, worker rows only -- not
    from repricing the whole session at one top model (see the module
    docstring). The "at <model>" label is pick_top_model(total) (the single
    most expensive model touched), a human-readable name only -- it doesn't
    drive the dollar figures when a session crossed more than one epoch.

    billing_mode "sub": math is identical, but the leading figure isn't a
    bill, it's what the session would have cost on the API ("API-equiv").

    overdrive=True replaces the whole counterfactual clause with a flat
    "tier savings n/a (OVERDRIVE)" marker, printed UNCONDITIONALLY whenever
    there's a dollar clause at all (not gated on savings rounding nonzero) --
    an expensive binding must never be silently invisible.

    `rows` is this session's ledger rows when the caller has them: the
    leading figure is then the sum of what those rows RECORD having cost,
    not a fresh repricing, so the hook line agrees with the ledger and the
    report even across a price change."""
    if not total:
        return ""
    models_seen = {key.split("|", 1)[1] for key in total}
    unknown = any(rates_for(m) is None for m in models_seen)
    if rows is None:
        actual = sum(cost(counters, rates_for(key.split("|", 1)[1])) for key, counters in total.items())
    else:
        rows = list(rows)
        actual = sum(_row_pricing(row)[0] for row in rows)

    clause = f"~{fmt_usd(actual)}"
    if unknown:
        clause += "?"
    if billing_mode == "sub":
        clause += " API-equiv"

    if overdrive:
        return clause + " · tier savings n/a (OVERDRIVE)"

    top = pick_top_model(total)
    saved = session_delegation_savings(bucket_total, rows)
    if top and round(saved, 2) != 0:
        at_top = actual + saved
        top_short = top.replace("claude-", "")
        clause += f" · ~{fmt_usd(at_top)} at {top_short} → saved ~{fmt_usd(saved)}"
    return clause


def msg_segment(transcript_path):
    """"msg: last <N>w (cap <cap>) · over <over>/<total>" for this
    transcript's top-level assistant text messages, or "" when there's no
    assistant text yet (or anything about the read goes wrong).

    Streams the file line by line, never loads it whole, never prints
    transcript content. A "message" is every row sharing one message.id;
    rows with isSidechain true, or type != "assistant", are skipped
    entirely. Word count sums len(text.split()) across each row's
    .type == "text" content blocks for that message.id, so a response
    split across several jsonl lines is counted once. "last" is the most
    recently STARTED message.id in file order; "over" counts how many
    messages so far exceed the cap.

    Fails open: any exception, or a missing transcript_path, returns ""
    rather than raising."""
    if not transcript_path:
        return ""
    try:
        cap = int(os.environ.get("CLAUDE_ORCA_MSG_CAP", str(MSG_CAP_DEFAULT)))
        order = []  # message.id (or a per-row placeholder) in first-seen order
        words_by_id = {}
        with open(transcript_path) as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                row = json.loads(raw)
                if row.get("type") != "assistant" or row.get("isSidechain"):
                    continue
                msg = row.get("message") or {}
                content = msg.get("content")
                if not isinstance(content, list):
                    continue
                text = " ".join(
                    b.get("text", "") for b in content
                    if isinstance(b, dict) and b.get("type") == "text"
                )
                if not text:
                    continue
                key = msg.get("id") or object()  # no id: never grouped with another row
                if key not in words_by_id:
                    order.append(key)
                    words_by_id[key] = 0
                words_by_id[key] += len(text.split())
        if not order:
            return ""
        last_words = words_by_id[order[-1]]
        over = sum(1 for k in order if words_by_id[k] > cap)
        return f"msg: last {last_words}w (cap {cap}) · over {over}/{len(order)}"
    except Exception:
        return ""


def delegation_drift_segment(session_id):
    """"inline: max streak N · W warn(s) · D deny/denies" clause for this
    session's delegation-gate drift, or "" when there's nothing to report or
    the state can't be read -- see "Delegation-gate drift segment" above.
    Reads delegation-gate.py's own state file directly (path duplicated,
    not imported)."""
    if not session_id:
        return ""
    path = os.path.join(
        os.path.expanduser(DELEGATION_GATE_STATE_DIR), f"{session_id}.json"
    )
    try:
        with open(path) as fh:
            state = json.load(fh)
        if not isinstance(state, dict):
            return ""
        max_streak = int(state.get("max_streak", 0) or 0)
        warns = int(state.get("warns", 0) or 0)
        denies = int(state.get("denies", 0) or 0)
    except Exception:
        return ""
    if not max_streak and not warns and not denies:
        return ""
    parts = [f"max streak {max_streak}"]
    if warns:
        parts.append(f"{warns} warn" if warns == 1 else f"{warns} warns")
    if denies:
        parts.append(f"{denies} deny" if denies == 1 else f"{denies} denies")
    return "inline: " + " · ".join(parts)


def _lane_log_path():
    """scripts/lane.sh's append-only declaration log. LANE_STATE_DIR is
    lane's own env override (same variable name, same default), so pointing
    one at a scratch dir points both."""
    base = os.environ.get("LANE_STATE_DIR") or os.path.expanduser(LANE_STATE_DIR)
    return os.path.join(base, "log.jsonl")


def _lane_log_rows(tail_lines=None):
    """Parsed rows from lane's log.jsonl -- {"lane","prev","why","ts",
    "escalated","session_id"} each -- or None when the log cannot be read
    at all, which every caller treats as "omit the lane surface entirely"
    rather than as an empty log.

    tail_lines caps the result to the newest N rows and, above
    LANE_TAIL_BYTES, seeks instead of reading the file whole (dropping the
    first, possibly partial, line). None reads everything, for the
    report's all-time counts. Unparseable lines are skipped, never fatal --
    lane.sh builds rows with printf, so a half-written tail row is
    normal."""
    path = _lane_log_path()
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if tail_lines is not None and size > LANE_TAIL_BYTES:
                fh.seek(size - LANE_TAIL_BYTES)
                fh.readline()  # drop the partial line the seek landed inside
            raw_lines = fh.read().splitlines()
    except OSError:
        return None
    if tail_lines is not None:
        raw_lines = raw_lines[-tail_lines:]
    rows = []
    for raw in raw_lines:
        try:
            row = json.loads(raw)
        except Exception:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def lane_segment(session_id):
    """"lane last-turn: <lane>" for this session's newest declaration, or ""
    when there's no log to read / no session id.

    "last-turn", not "current": `lane --reset` runs as a UserPromptSubmit
    hook BEFORE this one, so by render time the session's state file
    already says "unset" -- the log is the only honest source, and it can
    only report the PREVIOUS turn's lane.

    A readable log with no row for this session yields "unset"; an
    unreadable/missing one yields ""."""
    if not session_id:
        return ""
    try:
        rows = _lane_log_rows(LANE_TAIL_LINES)
        if rows is None:
            return ""
        for row in reversed(rows):
            if row.get("session_id") == session_id and row.get("lane"):
                return f"lane last-turn: {row['lane']}"
    except Exception:
        return ""
    return "lane last-turn: unset"


def _lane_report_session_id(tp=None):
    """Which session the report's "session" column counts declarations for.

    A single-session view uses the transcript directly (_session_id_for).
    The aggregate report has no one transcript, so it resolves the
    CALLER's session the way lane.sh's own resolve_sid does --
    CLAUDE_CODE_SESSION_ID, else the last-session file `lane --reset`
    writes -- so `tier-cost` run from a live session still shows its own
    lane counts."""
    if tp:
        return _session_id_for(tp)
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if sid:
        return sid
    base = os.environ.get("LANE_STATE_DIR") or os.path.expanduser(LANE_STATE_DIR)
    try:
        with open(os.path.join(base, "last-session")) as fh:
            return fh.readline().strip()
    except OSError:
        return ""


def render_lanes(session_id=""):
    """The report's "lanes" section: per-lane declaration counts for
    session_id and all-time, plus the escalation count and rate the
    knowledge base names as the router's primary health metric.

    Returns "" when there's no log or no parseable rows -- a machine that
    never ran the router should not grow an empty table. Read-only: never
    creates the lane dir. Callers wrap this in try/except (see print_lanes)
    since --report must exit nonzero on a real error rather than silently
    swallowing one."""
    rows = _lane_log_rows()
    if not rows:
        return ""
    lanes = [r.get("lane") for r in rows if r.get("lane")]
    mine = [r for r in rows if session_id and r.get("session_id") == session_id]
    names = list(LANE_NAMES) + sorted(set(lanes) - set(LANE_NAMES))

    def esc(subset):
        return sum(1 for r in subset if r.get("escalated") is True)

    cols = ("lane", "session", "all-time")
    widths = (18, 12, 12)

    def fmt_row(values):
        return "".join(
            v.ljust(w) if i < 1 else v.rjust(w) for i, (v, w) in enumerate(zip(values, widths))
        )

    header = fmt_row(cols)
    scope = f" — session {session_id[:8]}" if session_id else " — no session resolved"
    lines = ["", f"lanes (complexity router — declaration log){scope}", "", header, "-" * len(header)]
    for name in names:
        lines.append(fmt_row((
            name,
            str(sum(1 for r in mine if r.get("lane") == name)),
            str(sum(1 for lane in lanes if lane == name)),
        )))
    lines.append("-" * len(header))
    lines.append(fmt_row(("declarations", str(len(mine)), str(len(rows)))))
    lines.append(fmt_row(("escalations", str(esc(mine)), str(esc(rows)))))

    def rate(subset):
        return f"{100.0 * esc(subset) / len(subset):.1f}%" if subset else "n/a"

    lines.append(fmt_row(("escalation rate", rate(mine), rate(rows))))
    lines.append(
        f"target {LANE_RATE_TARGET_LOW:.0f}–{LANE_RATE_TARGET_HIGH:.0f}% "
        f"(<{LANE_RATE_TARGET_LOW:.0f}% classifying heavy? · "
        f">{LANE_RATE_GREEDY:.0f}% express too greedy?)"
    )
    return "\n".join(lines)


def print_lanes(tp=None):
    """Emit render_lanes() beneath a report, swallowing anything it throws --
    the lane join is an extra, never a reason for `tier-cost` to fail."""
    try:
        section = render_lanes(_lane_report_session_id(tp))
    except Exception:
        return
    if section:
        print(section)


def _default_transcript():
    """Best-effort transcript for a bare `--report`: the tp the hook itself
    recorded, from the newest cost-mirror state file -- the session the
    last hook line was computed from. Falls back to the newest transcript
    under $CLAUDE_CONFIG_DIR/projects/*/ if no state carries a still-existing
    tp (e.g. an old-schema state, or a fresh install)."""
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
    return os.environ.get("COST_MIRROR_PROJECTS_DIR") or os.path.join(
        _claude_config_dir(), "projects"
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
    """[tp] plus its beside-it subagents/**/*.jsonl -- the same file set
    scan_session() scans for one session, recomputed here (read-only glob)
    so --all can group the flat cross-session cache back into per-session
    rows."""
    subdir = os.path.join(os.path.splitext(tp)[0], "subagents")
    return [tp] + sorted(glob.glob(os.path.join(subdir, "**", "*.jsonl"), recursive=True))


def _all_state_path():
    """Path to the --all incremental cache: a single dedicated file,
    separate from the hook's per-session state files (named by a sha256
    hash of their transcript path) in the same directory -- plain
    `--report` must keep writing no state at all; only --report --all
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


def _session_id_for(tp):
    """Best-effort session id for a transcript: the sessionId/session_id
    field from its first parseable row (rows carry both keys), falling back
    to the filename stem — transcripts are conventionally named
    <sessionId>.jsonl, so this is the right answer even for a transcript
    with no readable rows yet."""
    try:
        with open(tp, "rb") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    row = json.loads(raw)
                except Exception:
                    continue
                sid = row.get("sessionId") or row.get("session_id")
                if sid:
                    return sid
                break
    except OSError:
        pass
    return os.path.splitext(os.path.basename(tp))[0]


def _find_transcripts_by_session(prefix):
    """Every transcript under _list_transcripts() whose session id (see
    _session_id_for) or filename-stem UUID starts with prefix, used by
    --session to resolve a prefix to exactly one transcript."""
    matches = []
    for tp in _list_transcripts():
        sid = _session_id_for(tp)
        stem = os.path.splitext(os.path.basename(tp))[0]
        if sid.startswith(prefix) or stem.startswith(prefix):
            matches.append(tp)
    return matches


def _lifetime_path():
    return os.path.join(_state_dir(), "lifetime.json")


def _migrate_v3_rows(rows):
    """v3 rows ("<session>|<side>|<model>" -> {in,out,cr,w5,w1,...}) as v4
    LEGACY ledger rows: one per (session, side, model), no bucket, no
    rates, under their original three-part key.

    A v3 row records what was spent but not what it was priced at, so
    rates stay null and pricing_source reads "unknown" rather than
    back-filling today's rates onto old tokens. Still priced live at
    report time (see _row_pricing) -- exactly the v3 behaviour."""
    out = {}
    for key, entry in rows.items():
        if not isinstance(entry, dict):
            continue
        session_id = entry.get("sessionId") or key.rsplit("|", 2)[0]
        side, _, model = key[len(session_id) + 1:].partition("|")
        if not side or not model:
            continue
        row = {
            "sessionId": session_id, "side": side, "model": model, "bucket": None,
            "project": entry.get("project", ""), "mtime": entry.get("mtime", 0),
            "tp": entry.get("tp", ""), "epoch_model": None,
            "pricing_source": "unknown", "pricing_fetched_at": None, "pricing_id": None,
        }
        for k in COUNTER_KEYS:
            row[f"tokens_{k}"] = entry.get(k, 0)
            row[f"rate_{k}"] = None
            row[f"rate_epoch_{k}"] = None
            row[f"cost_{k}"] = None
        row["cost_total"] = None
        row["cost_at_epoch"] = None
        out[key] = row
    return out


def _load_lifetime():
    path = _lifetime_path()
    try:
        with open(path) as fh:
            data = json.load(fh)
    except Exception:
        data = {}
    # LIFETIME_VERSION deliberately isn't STATE_VERSION -- see the row
    # ledger note above. v3 is MIGRATED rather than wiped (its counters are
    # sound, only bucket granularity and provenance are missing); any older
    # version starts clean, since a v2 row's counters are actually wrong.
    if data.get("v") == 3:
        data = {"sessions": _migrate_v3_rows(data.get("sessions", {}))}
    elif data.get("v") != LIFETIME_VERSION:  # old/missing schema: start clean
        data = {}
    data["v"] = LIFETIME_VERSION
    data.setdefault("sessions", {})
    return data


def _save_lifetime(data):
    path = _lifetime_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh)
    os.replace(tmp, path)


def _update_lifetime(session_id, tp, project, mtime, bucket_total):
    """Durably record this session's ledger rows -- one per (side, model,
    bucket), each carrying the rates that priced it (see
    build_session_rows) -- and return them, so the caller prices the report
    off exactly the rows that were persisted.

    REPLACE, never increment: every existing row for this session_id is
    dropped first, then the freshly scanned rows are written whole, so
    calling this any number of times on a fully rescanned session is
    idempotent. Called from both the hook path (for the live session) and
    the aggregate report path -- never from a single-session view, which
    must stay read-only with respect to state."""
    data = _load_lifetime()
    rows = data["sessions"]
    prefix = f"{session_id}|"
    prior = {k: rows[k] for k in list(rows) if k.startswith(prefix)}
    for key in prior:
        del rows[key]
    fresh = build_session_rows(session_id, tp, project, mtime, bucket_total, prior)
    rows.update(fresh)
    _save_lifetime(data)
    return fresh


def _ingest_delegate_receipt(path):
    """--ingest-delegate-receipt <path>: fold one delegate.sh job receipt
    (see its cmd_run) into the durable ledger as a single row (side
    "delegate"), so `tier-cost` can show delegated spend alongside native
    session spend (see render_delegate_segment). Returns a process exit
    code -- 0 on success, 1 on a missing/unreadable/malformed receipt, with
    nothing written -- since this is a direct CLI entry point, not the
    hook's fail-silent path.

    Row key: _row_key(job, "delegate", model, bucket). session_id is the
    job id itself (route-epoch-hex, see cmd_run): unique per run, so a
    re-ingest of the SAME job's receipt lands on the SAME key (REPLACE,
    idempotent) while a different job always lands on its own row. bucket
    is the epoch parsed back out of that job id, falling back to 0 for an
    id that doesn't match the "<route>-<epoch>-<hex>" shape.

    Dollars are the receipt's own "usd" field verbatim -- a real external
    bill, never re-priced against PRICING_TABLE: cost_total is set
    directly and every rate_* left None. A null "usd" still writes a row
    at $0.00 rather than dropping it."""
    try:
        with open(path) as fh:
            receipt = json.load(fh)
        if not isinstance(receipt, dict):
            raise ValueError("receipt is not a JSON object")
        job = receipt["job"]
        model = receipt["model"]
        if not job or not isinstance(job, str) or not model or not isinstance(model, str):
            raise ValueError("receipt missing non-empty job/model")
        usd = receipt.get("usd")
        cost_total = float(usd) if usd is not None else 0.0
        tokens_in = receipt.get("tokens_in")
        tokens_out = receipt.get("tokens_out")
        tokens_in = int(tokens_in) if tokens_in is not None else 0
        tokens_out = int(tokens_out) if tokens_out is not None else 0
        mtime = _parse_ts(receipt.get("finished_at")) or time.time()
    except Exception as exc:
        print(f"cost-mirror --ingest-delegate-receipt: {path}: {exc}", file=sys.stderr)
        return 1

    parts = job.rsplit("-", 2)
    bucket = int(parts[1]) if len(parts) == 3 and parts[1].isdigit() else 0

    row = {
        "sessionId": job, "side": "delegate", "model": model, "bucket": bucket,
        "project": "delegate", "mtime": mtime, "tp": "", "epoch_model": None,
        "pricing_source": "delegate-receipt", "pricing_fetched_at": None,
        "pricing_id": None,
    }
    counter_tokens = {"in": tokens_in, "out": tokens_out}
    for k in COUNTER_KEYS:
        row[f"tokens_{k}"] = counter_tokens.get(k, 0)
        row[f"rate_{k}"] = None
        row[f"rate_epoch_{k}"] = None
        row[f"cost_{k}"] = None
    row["cost_total"] = cost_total
    row["cost_at_epoch"] = cost_total

    data = _load_lifetime()
    data["sessions"][_row_key(job, "delegate", model, bucket)] = row
    _save_lifetime(data)
    return 0


def _delegate_rows(lifetime_data=None):
    """Every lifetime.json row with side == "delegate" — i.e. everything
    written by _ingest_delegate_receipt. Takes an already-loaded
    lifetime_data when the caller has one in hand (run_report_all loads it
    once for the durability union) rather than reading the file twice."""
    data = lifetime_data if lifetime_data is not None else _load_lifetime()
    return [
        row for row in data.get("sessions", {}).values()
        if isinstance(row, dict) and row.get("side") == "delegate"
    ]


def render_delegate_segment(lifetime_data=None):
    """"delegated: <model> $X.XX (N job(s)) · ... · total $Z.ZZ" -- one
    entry per model ingested via --ingest-delegate-receipt, dollars-
    descending then model name. "" when there are no delegate rows.

    Deliberately its OWN segment, never folded into render_report's
    side|model table: a delegate job's dollars are a real external bill,
    not tokens priced by this file, so there's no at-top/saved
    counterfactual for money already spent outside this session."""
    rows = _delegate_rows(lifetime_data)
    if not rows:
        return ""
    by_model = {}
    for row in rows:
        d = by_model.setdefault(row.get("model") or "unknown", {"usd": 0.0, "jobs": 0})
        cost_total = row.get("cost_total")
        d["usd"] += float(cost_total) if cost_total is not None else 0.0
        d["jobs"] += 1
    ordered = sorted(by_model.items(), key=lambda kv: (-kv[1]["usd"], kv[0]))
    parts = [
        f"{model} {fmt_usd(d['usd'])} ({d['jobs']} job{'' if d['jobs'] == 1 else 's'})"
        for model, d in ordered
    ]
    line = "delegated: " + " · ".join(parts)
    if len(by_model) > 1:
        line += f" · total {fmt_usd(sum(d['usd'] for d in by_model.values()))}"
    return line


def print_delegate_segment(lifetime_data=None):
    """Emit render_delegate_segment() beneath a report, swallowing anything
    it throws — mirrors print_lanes(): an extra, never a reason for
    `tier-cost` to fail."""
    try:
        section = render_delegate_segment(lifetime_data)
    except Exception:
        return
    if section:
        print(section)


def _lifetime_sessions_by_id(lifetime_data):
    """Group the ledger's flat rows back into per-session dicts: session_id
    -> {"rows": [...], "totals": {side|model: counters}, "project", "mtime",
    "tp"} -- what run_report_all's durability union needs to add missing
    (deleted-from-disk) sessions back into the report.

    "rows" prices the session (each at its own frozen rates); "totals" is
    the token rollup, summed ACROSS a session's buckets. Delegate rows are
    skipped: a delegate job has no transcript and isn't a "session" for the
    durability union -- see render_delegate_segment."""
    grouped = {}
    for key, entry in lifetime_data.get("sessions", {}).items():
        if not isinstance(entry, dict):
            continue
        if entry.get("side") == "delegate":
            continue
        session_id = entry.get("sessionId") or key.split("|", 1)[0]
        side_model = f"{entry.get('side', '')}|{entry.get('model', '')}"
        g = grouped.setdefault(
            session_id,
            {"rows": [], "totals": {}, "project": entry.get("project", ""), "mtime": 0,
             "tp": entry.get("tp", "")},
        )
        g["rows"].append(entry)
        cur = g["totals"].setdefault(side_model, _empty_counters())
        for k in COUNTER_KEYS:
            cur[k] += entry.get(f"tokens_{k}", 0)
        if entry.get("mtime", 0) >= g["mtime"]:
            g["project"] = entry.get("project", g["project"])
            g["mtime"] = entry.get("mtime", g["mtime"])
            g["tp"] = entry.get("tp", g["tp"])
    return grouped


CSV_COLUMNS = (
    ("session_id", "side", "model", "bucket", "epoch_model", "project", "mtime", "tp")
    + tuple(f"tokens_{k}" for k in COUNTER_KEYS)
    + tuple(f"rate_{k}" for k in COUNTER_KEYS)
    + tuple(f"rate_epoch_{k}" for k in COUNTER_KEYS)
    + tuple(f"cost_{k}" for k in COUNTER_KEYS)
    + ("cost_total", "cost_at_epoch", "pricing_source", "pricing_fetched_at", "pricing_id")
)
# The ledger row's own fields, one CSV column each (only "session_id" is
# renamed from the row's "sessionId"). Deliberately WIDER than the rendered
# table: cache-write stays split w5/w1, and every rate/provenance field
# ships, so a reader can recompute each dollar without today's price list.


def _csv_sort_key(row):
    """Newest session first (matching the rendered table's order), then a
    total order within it. A legacy row's bucket is None, which won't compare
    against an int — sort those to the end of their session rather than
    crashing on the comparison."""
    bucket = row.get("bucket")
    return (
        -(row.get("mtime") or 0),
        row.get("sessionId") or "",
        row.get("side") or "",
        row.get("model") or "",
        bucket is None,
        bucket or 0,
    )


def write_rows_csv(rows, path):
    """Write `rows` (ledger rows, see _ledger_row) to `path` as CSV, one
    line per row plus a header. Returns 0, or 1 after a stderr message if
    the path can't be written.

    Values go out exactly as the ledger holds them: a None (unpriced
    legacy row's rates/costs) becomes an EMPTY cell rather than a 0.0 that
    would read as "genuinely free" -- such a row is still priced live in
    the report (_row_pricing), so its rendered dollar is the one figure the
    CSV alone cannot reproduce.

    CSV formula injection: identifier columns starting with '-', '=', '+'
    or '@' are prefixed with a quote to block Excel/Sheets formula
    interpretation; numeric columns are never modified.

    lineterminator="\\n": the csv default is CRLF, and a stray CR would
    corrupt the last field for shell consumers."""
    # Identifier columns that need formula-injection protection
    IDENTIFIER_COLUMNS = {
        "session_id", "side", "model", "bucket", "epoch_model", "project", "mtime", "tp"
    }

    def _neutralise_formula(col_name, value):
        """Neutralise leading formula characters in identifier columns only."""
        if col_name not in IDENTIFIER_COLUMNS or not isinstance(value, str):
            return value
        if value and value[0] in ("-", "=", "+", "@"):
            return "'" + value
        return value

    try:
        with open(path, "w", newline="") as fh:
            writer = csv.writer(fh, lineterminator="\n")
            writer.writerow(CSV_COLUMNS)
            for row in sorted(rows, key=_csv_sort_key):
                col_values = []
                for col in CSV_COLUMNS:
                    col_key = "sessionId" if col == "session_id" else col
                    value = row.get(col_key)
                    value = _neutralise_formula(col, value)
                    col_values.append(value)
                writer.writerow(col_values)
    except OSError as exc:
        print(f"cost-mirror --report --csv: cannot write {path}: {exc}", file=sys.stderr)
        return 1
    return 0


def render_all_sessions_table(session_rows, since_days=None, n_projects=None):
    """One row per transcript -- project dir, short session id,
    last-modified date, total tokens, actual $ -- sorted newest first.
    Header states the scope plainly: session count, project-dir count, and
    the --since window when given, so a blank-looking default report is
    never mistaken for "everything"."""
    scope = f" (modified in the last {since_days}d)" if since_days is not None else ""
    if n_projects is None:
        n_projects = len({row["project"] for row in session_rows})
    lines = [
        f"cost-mirror report --all{scope} — {len(session_rows)} session(s) "
        f"across {n_projects} project dir(s)",
        "",
    ]
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

        # Mark multi-epoch sessions with a trailing dagger, truncating the
        # id rather than the marker if both don't fit in the column width.
        session_label = row["session"]
        epoch_models = row.get("epoch_models", set())
        if len(epoch_models) > 1:
            marker = "†"
            session_width = 10  # column width for the session field
            if len(session_label) + len(marker) <= session_width:
                session_label = session_label + marker
            else:
                session_label = session_label[:session_width - len(marker)] + marker

        lines.append(fmt_row((
            project, session_label, modified, fmt(row["tokens"]), fmt_usd(row["actual"]),
        )))
    return "\n".join(lines)


def run_report_all(since_days, csv_path=None):
    """The aggregate report: every transcript under
    $CLAUDE_CONFIG_DIR/projects/*/*.jsonl (plus each one's beside-it
    subagents/*.jsonl), optionally scoped to --since. This is what bare
    `--report` does now (the `tier-cost` alias); `--all` is an accepted
    no-op alias. NOT fail-silent -- a corpus with nothing to report prints
    a message and exits nonzero.

    Durability: every session scanned here has its final counters written
    into lifetime.json (REPLACE, see _update_lifetime), and the grand total
    additionally unions in any lifetime session whose transcript no longer
    exists on disk, so its spend is never silently lost. Sessions still on
    disk are always read live, never from lifetime.

    csv_path also writes every ledger row this report priced to that path
    (see write_rows_csv) -- the SAME objects the dollars are summed from,
    so the export can't drift from the table it sits beneath."""
    transcripts = _list_transcripts(since_days)

    cache = _load_all_cache()
    files_state = cache["files"]  # persisted across runs: path -> {off, agg}

    session_rows = []
    csv_rows = []  # every ledger row in scope, for --csv (see write_rows_csv)
    selected_state = {}  # this run's scope only (cache may hold more history)
    scanned_session_ids = set()
    pricing = {}  # "side|model" -> {actual, at_epoch}, summed per-session (see below)
    for tp in transcripts:
        session_id = _session_id_for(tp)
        scanned_session_ids.add(session_id)
        scan_session(tp, files_state)
        paths = [p for p in _session_file_paths(tp) if p in files_state]
        session_state = {p: files_state[p] for p in paths}
        selected_state.update(session_state)
        session_total = aggregate_total(session_state)
        project = os.path.basename(os.path.dirname(tp))
        mtime = os.path.getmtime(tp)
        # Epochs computed and priced PER SESSION, then folded in via
        # _add_pricing -- never a bucket_total merged across sessions, which
        # would let one session's tier reprice another's spend.
        ledger_rows = _update_lifetime(
            session_id, tp, project, mtime, aggregate_bucket_total(session_state)
        )
        _add_pricing(pricing, pricing_from_rows(ledger_rows.values()))
        csv_rows.extend(ledger_rows.values())
        tokens = sum(sum(c.values()) for c in session_total.values())
        actual = sum(_row_pricing(row)[0] for row in ledger_rows.values())
        # Collect unique epoch_model values for this session to detect multi-epoch
        epoch_models = set(r.get("epoch_model") for r in ledger_rows.values() if r.get("epoch_model"))
        session_rows.append({
            "project": project,
            "session": os.path.splitext(os.path.basename(tp))[0][:8],
            "mtime": mtime,
            "tokens": tokens,
            "actual": actual,
            "epoch_models": epoch_models,
        })

    _save_all_cache(cache)

    grand_total = aggregate_total(selected_state)

    # Durability union: lifetime sessions whose transcript is gone from
    # disk still count, subject to the same --since window (by their last
    # recorded mtime) as everything else in scope.
    lifetime_data = _load_lifetime()
    grouped = _lifetime_sessions_by_id(lifetime_data)
    cutoff = time.time() - since_days * 86400 if since_days is not None else None
    missing_count = 0
    for session_id, info in grouped.items():
        if session_id in scanned_session_ids:
            continue
        dead_tp = info.get("tp") or ""
        if dead_tp and os.path.isfile(dead_tp):
            continue  # still on disk, just outside this run's --since window
        if cutoff is not None and info["mtime"] < cutoff:
            continue
        missing_count += 1
        for side_model, counters in info["totals"].items():
            cur = grand_total.setdefault(side_model, _empty_counters())
            for k in COUNTER_KEYS:
                cur[k] += counters.get(k, 0)
        # a dead session's rows price the same way a live one's do — from
        # what the row itself records, or live for a migrated v3 legacy row
        # that never recorded any rates (see _row_pricing)
        _add_pricing(pricing, pricing_from_rows(info["rows"]))
        csv_rows.extend(info["rows"])
        tokens = sum(sum(c.values()) for c in info["totals"].values())
        actual = sum(_row_pricing(row)[0] for row in info["rows"])
        # Collect unique epoch_model values for this session
        epoch_models = set(r.get("epoch_model") for r in info["rows"] if r.get("epoch_model"))
        session_rows.append({
            "project": info["project"],
            "session": session_id[:8],
            "mtime": info["mtime"],
            "tokens": tokens,
            "actual": actual,
            "epoch_models": epoch_models,
        })

    if not session_rows:
        # A delegate-only ledger (no native transcripts, but real delegate
        # spend on record) is not "nothing to report": render just the
        # delegated segment and exit 0. An asked-for CSV still gets written
        # (header only) either way.
        delegate_rows = _delegate_rows(lifetime_data)
        if csv_path:
            write_rows_csv([], csv_path)
        if delegate_rows:
            print_delegate_segment(lifetime_data)
            return 0
        scope = f" modified in the last {since_days}d" if since_days is not None else ""
        print(
            f"cost-mirror --report --all: no transcript files found under "
            f"{os.path.join(_projects_dir(), '*', '*.jsonl')}{scope}",
            file=sys.stderr,
        )
        return 1

    n_projects = len({row["project"] for row in session_rows})
    billing_mode, billing_detail = detect_billing_mode()
    since_label = f", since {since_days}d" if since_days is not None else ""
    # len(session_rows), not len(transcripts): session_rows already includes
    # the durability union's dead sessions, so this matches the table's own
    # "N session(s)" header; len(transcripts) alone would undercount.
    label = f"ALL sessions ({len(session_rows)} transcripts{since_label})"

    # Build a mapping of side|model -> set of epoch_model values for render_report
    epoch_models_by_side_model = {}
    for row in csv_rows:
        side_model = f"{row.get('side', '')}|{row.get('model', '')}"
        epoch_model = row.get("epoch_model")
        if epoch_model:
            if side_model not in epoch_models_by_side_model:
                epoch_models_by_side_model[side_model] = set()
            epoch_models_by_side_model[side_model].add(epoch_model)

    print(render_all_sessions_table(session_rows, since_days, n_projects))
    if missing_count:
        print()
        print(
            f"({missing_count} session(s) no longer on disk — counted from "
            "lifetime history)"
        )
    print()
    print(render_report(label, grand_total, billing_mode, billing_detail, pricing, epoch_models_by_side_model))
    print_lanes()
    print_delegate_segment(lifetime_data)
    # a CSV that was asked for and not written is a failed run, even though
    # the table above it rendered fine
    return write_rows_csv(csv_rows, csv_path) if csv_path else 0


def render_report(tp, total, billing_mode="api", billing_detail="", pricing=None, epoch_models_by_side_model=None):
    """Human-readable per-side|model table: token counts plus actual/at-top/
    saved dollars, with a totals row. cache-write shown as one combined
    column (w5+w1).

    `pricing` is a "side|model" -> {"actual": $, "at_epoch": $} dict (see
    session_epoch_pricing) driving the at-top/saved columns -- the caller
    builds it rather than render_report computing it, because a
    multi-session caller (run_report_all) must compute and sum each
    session's epochs SEPARATELY (never merge several sessions' bucket data
    into one epoch set, which would let one session's tier reprice
    another's). A row missing from `pricing` falls back to
    at_epoch == actual. None behaves as if `pricing` were empty -- "saved"
    reads 0 everywhere.

    A "billing: ..." line is always emitted; billing_mode "sub" additionally
    marks the money columns as API-equivalent."""
    pricing = pricing or {}
    is_overdrive = overdrive_active()
    top = pick_top_model(total)  # informational only -- not what at-top/saved
    # compute against, see `pricing` above

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
    if is_overdrive:
        cols = (
            "side", "model", "in", "out", "cache-r", "cache-w",
            f"actual ${money_suffix}", f"at-top $ (n/a)", f"saved $ (n/a)",
        )
    else:
        cols = (
            "side", "model", "in", "out", "cache-r", "cache-w",
            f"actual ${money_suffix}", f"at-top ${money_suffix}", f"saved ${money_suffix}",
        )
    # token columns at 11 so a --all grand total (9-digit cache-r/w counts)
    # never runs two numbers together; side at 18 to fit "worker:<role>"
    # labels (e.g. "worker:verifier" is 16 chars).
    widths = (18, 28, 11, 11, 11, 11, 10, 10, 10)
    if is_overdrive:
        # "n/a (OVERDRIVE)" and the header's "at-top $ (n/a)"/"saved $
        # (n/a)" overran the plain 10-char money column (rjust() never
        # truncates, so text ran into its neighbour with no gap). Widen
        # just these two columns; header, rows, TOTAL and the separator all
        # derive their length from `widths`, so this keeps them aligned.
        widths = widths[:7] + (17, 17)

    def fmt_row(values):
        return "".join(
            v.ljust(w) if i < 2 else v.rjust(w) for i, (v, w) in enumerate(zip(values, widths))
        )

    header = fmt_row(cols)
    lines += [header, "-" * len(header)]

    grand = _empty_counters()
    tot_actual = tot_at_top = 0.0
    # "main" first, then every other side alphabetically, so row order is
    # stable run to run. A different axis from the cost sort WITHIN each
    # side below -- a flat cost-ordered table was rejected since it would
    # bury a cheap "main" row under pricier worker rows.
    sides = ["main"] + sorted({k.split("|", 1)[0] for k in total} - {"main"})
    for side in sides:
        rows = [(k.split("|", 1)[1], v) for k, v in total.items() if k.split("|", 1)[0] == side]
        # Sort by real dollar cost descending (see "Cost-sorted rows" in the
        # module docstring), tiebroken by model id ascending for
        # byte-identical output run to run (tests/tier-hooks.bats). rates_for
        # /cost() computed ONCE per row and reused for the "actual $" column.
        # Dollars come from the LEDGER when `pricing` has them (each row at
        # the rates it was written with); otherwise a live cost(), as before.
        priced = [(model, c, rates_for(model)) for model, c in rows]
        priced = [
            (model, c, rates, pricing.get(f"{side}|{model}", {}).get("actual", cost(c, rates)))
            for model, c, rates in priced
        ]
        priced.sort(key=lambda row: (-row[3], row[0]))
        for model, c, rates, actual in priced:
            pr = pricing.get(f"{side}|{model}", {"actual": actual, "at_epoch": actual})
            at_top = pr["at_epoch"]
            saved = at_top - actual
            label = model.replace("claude-", "") + ("" if rates else "?")
            in_str = str(c["in"])

            # side can be an arbitrary-length "worker:<role>" (customAgentType
            # is free text); truncate rather than let an unusually long role
            # name run into the model column with no gap between them.
            side_label = side if len(side) <= widths[0] - 1 else side[: widths[0] - 2] + "…"

            # Epoch-span note: a side|model row can group ledger rows priced
            # at more than one epoch_model (a worker whose buckets straddle a
            # /tier change -- see build_session_rows). The marker can't live
            # on the 9-field data row itself: tests/tier-hooks.bats'
            # reconcile_csv matches rows by exact field count/shape, and any
            # of the 9 fields carrying it either breaks that matching or (for
            # token columns) makes a count non-numeric. So it's a separate
            # annotation line below the row instead, prefixed with the same
            # side text -- visible to a reader but invisible to anything that
            # parses the table as fixed fields (reconcile_csv's row heuristic
            # never matches this line's shape, and `read -a` on a multi-line
            # grep capture only ever consumes the first line).
            side_model_key = f"{side}|{model}"
            epoch_note = None
            if epoch_models_by_side_model and side_model_key in epoch_models_by_side_model:
                epochs = epoch_models_by_side_model[side_model_key]
                if len(epochs) > 1:
                    epoch_list = ", ".join(sorted(e.replace("claude-", "") for e in epochs))
                    epoch_note = (
                        side_label.ljust(widths[0])
                        + f"† spans {len(epochs)} tier epochs ({epoch_list})"
                        " — see --csv for per-row rates"
                    )

            if is_overdrive:
                lines.append(fmt_row((
                    side_label, label, in_str, str(c["out"]), str(c["cr"]), str(c["w5"] + c["w1"]),
                    fmt_usd(actual), "n/a (OVERDRIVE)", "n/a (OVERDRIVE)",
                )))
            else:
                lines.append(fmt_row((
                    side_label, label, in_str, str(c["out"]), str(c["cr"]), str(c["w5"] + c["w1"]),
                    fmt_usd(actual), fmt_usd(at_top), fmt_usd(saved),
                )))
            if epoch_note:
                lines.append(epoch_note)
            for k in COUNTER_KEYS:
                grand[k] += c[k]
            tot_actual += actual
            tot_at_top += at_top

    lines.append("-" * len(header))
    if is_overdrive:
        lines.append(fmt_row((
            "TOTAL", "", str(grand["in"]), str(grand["out"]), str(grand["cr"]), str(grand["w5"] + grand["w1"]),
            fmt_usd(tot_actual), "n/a (OVERDRIVE)", "n/a (OVERDRIVE)",
        )))
    else:
        lines.append(fmt_row((
            "TOTAL", "", str(grand["in"]), str(grand["out"]), str(grand["cr"]), str(grand["w5"] + grand["w1"]),
            fmt_usd(tot_actual), fmt_usd(tot_at_top), fmt_usd(tot_at_top - tot_actual),
        )))
    return "\n".join(lines)


def _render_single(tp, csv_path=None):
    """Render one transcript's report -- the shared tail end of every
    single-session view (a direct positional path, --session, --this).
    Read-only: a throwaway scan from offset 0, state never written.

    csv_path exports THIS session's ledger rows, the same rows the table is
    priced from -- built in memory and never persisted."""
    if not os.path.isfile(tp):
        print(f"cost-mirror --report: transcript not found: {tp}", file=sys.stderr)
        return 1
    files_state = {}  # throwaway: full scan from offset 0, state never written
    scan_session(tp, files_state)
    billing_mode, billing_detail = detect_billing_mode()
    # READ the ledger (never write it): a row this session already has on
    # file keeps the rates it was priced at, so a single-session view can't
    # disagree with the aggregate report. A session with no rows yet is
    # priced live. Real mtime so a --csv export carries an honest timestamp;
    # nothing prices off mtime, so no dollar above can move.
    session_id = _session_id_for(tp)
    rows = build_session_rows(
        session_id, tp, os.path.basename(os.path.dirname(tp)),
        os.path.getmtime(tp), aggregate_bucket_total(files_state),
        _load_lifetime()["sessions"],
    )
    pricing = pricing_from_rows(rows.values())
    # Build epoch_models_by_side_model for render_report
    epoch_models_by_side_model = {}
    for row in rows.values():
        side_model = f"{row.get('side', '')}|{row.get('model', '')}"
        epoch_model = row.get("epoch_model")
        if epoch_model:
            if side_model not in epoch_models_by_side_model:
                epoch_models_by_side_model[side_model] = set()
            epoch_models_by_side_model[side_model].add(epoch_model)
    print(render_report(tp, aggregate_total(files_state), billing_mode, billing_detail, pricing, epoch_models_by_side_model))
    print_lanes(tp)
    return write_rows_csv(rows.values(), csv_path) if csv_path else 0


def run_report_session(prefix, csv_path=None):
    """--session <prefix> entry point: resolve prefix to exactly one
    transcript (by sessionId or filename-UUID prefix, see
    _find_transcripts_by_session) and render its single-session report.
    Fails loud, listing candidates, on an ambiguous or no-match prefix --
    never guesses. Read-only, like every single-session view."""
    matches = _find_transcripts_by_session(prefix)
    if not matches:
        print(
            f"cost-mirror --report --session: no session matches prefix {prefix!r}",
            file=sys.stderr,
        )
        return 1
    if len(matches) > 1:
        candidates = ", ".join(f"{_session_id_for(tp)} ({tp})" for tp in matches)
        print(
            f"cost-mirror --report --session: prefix {prefix!r} is ambiguous "
            f"({len(matches)} matches) — candidates: {candidates}",
            file=sys.stderr,
        )
        return 1
    return _render_single(matches[0], csv_path)


def run_report(argv):
    """--report entry point. NOT fail-silent: prints to stderr and returns a
    nonzero exit code on a missing/unreadable/ambiguous transcript, since
    this runs directly from a terminal rather than from the hook.

    Dispatch, in priority order:
      --session <prefix>  single session resolved by sessionId/filename
                           prefix (run_report_session) -- read-only.
      --this               single session: the transcript recorded in the
                           newest hook state file (_default_transcript) --
                           read-only.
      <transcript.jsonl>   single session: the given transcript directly --
                           read-only.
      (none of the above)  the aggregate report (run_report_all): every
                           transcript on disk -- what --all did before this
                           became the default. --all remains an accepted
                           no-op alias.

    --since <N>d (e.g. 7d, 30d) narrows the aggregate report (default or
    --all) to transcripts modified in that window; a no-op on the
    single-session forms.

    --csv <path> additionally exports the ledger rows behind whichever view
    ran (see write_rows_csv), composing with all of them rather than
    replacing any -- the table still prints, and the rows written are
    exactly the ones its dollars were summed from.

    Any OTHER leading-dash token is a hard error naming the valid options
    (this used to fall through to positional[] and be looked up as a file,
    so `--report --help` reported "transcript not found: --help")."""
    this_mode = False
    session_prefix = None
    since_days = None
    csv_path = None
    positional = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--all":
            i += 1  # accepted no-op alias: aggregate is the default now
        elif arg == "--this":
            this_mode = True
            i += 1
        elif arg == "--session" or arg.startswith("--session="):
            if arg == "--session":
                if i + 1 >= len(argv):
                    print("cost-mirror --report: --session requires a value, e.g. --session a1b2", file=sys.stderr)
                    return 1
                session_prefix, i = argv[i + 1], i + 2
            else:
                session_prefix, i = arg.split("=", 1)[1], i + 1
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
        elif arg == "--csv" or arg.startswith("--csv="):
            if arg == "--csv":
                # a following flag is a missing value, not a filename: silently
                # swallowing "--since" here would write a file called --since
                if i + 1 >= len(argv) or argv[i + 1].startswith("-"):
                    print(
                        "cost-mirror --report: --csv requires a path, e.g. --csv rows.csv",
                        file=sys.stderr,
                    )
                    return 1
                csv_path, i = argv[i + 1], i + 2
            else:
                csv_path, i = arg.split("=", 1)[1], i + 1
            if not csv_path:
                print(
                    "cost-mirror --report: --csv requires a path, e.g. --csv rows.csv",
                    file=sys.stderr,
                )
                return 1
        elif arg.startswith("-"):
            print(
                f"cost-mirror --report: unknown option {arg} — valid options are "
                "--all, --this, --session <prefix>, --since <N>d, --csv <path>, "
                "or a transcript path",
                file=sys.stderr,
            )
            return 1
        else:
            positional.append(arg)
            i += 1

    if session_prefix is not None:
        return run_report_session(session_prefix, csv_path)

    if this_mode:
        tp = _default_transcript()
        if not tp:
            print(
                "cost-mirror --report --this: no transcript given and none found under "
                + _state_dir()
                + " or the config dir projects/*/",
                file=sys.stderr,
            )
            return 1
        return _render_single(tp, csv_path)

    if positional:
        return _render_single(positional[0], csv_path)

    return run_report_all(since_days, csv_path)


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
    state["tp"] = tp  # lets --report --this find this session's transcript
    files_state = state.setdefault("files", {})

    scan_session(tp, files_state)

    total = aggregate_total(files_state)
    bucket_total = aggregate_bucket_total(files_state)
    # Durable lifetime rollup: replace (never increment) this session's rows
    # so a deleted transcript's spend still counts in future aggregate
    # reports. Not wrapped in its own try/except: a failure here propagates
    # up and is caught only by __main__'s outer fail-silent guard, so the
    # hook line for THIS prompt is silently skipped too -- acceptable, since
    # the fail-open contract (never crash the prompt) still holds either way.
    ledger_rows = _update_lifetime(
        _session_id_for(tp),
        tp,
        os.path.basename(os.path.dirname(tp)),
        os.path.getmtime(tp),
        bucket_total,
    )
    token_line = summarise_tokens(total)
    tmp = state_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, state_path)
    if token_line:
        billing_mode, _ = detect_billing_mode()
        dollar_clause = summarise_dollars(
            total, bucket_total, billing_mode, overdrive_active(), ledger_rows.values()
        )
        line = f"{token_line} | {dollar_clause}" if dollar_clause else token_line
        drift = delegation_drift_segment(event.get("session_id"))
        if drift:
            line = f"{line} | {drift}"
        lane = lane_segment(event.get("session_id"))
        if lane:
            line = f"{line} | {lane}"
        msg = msg_segment(tp)
        if msg:
            line = f"{line} | {msg}"
        print(f"[cost-mirror] this session — {line}")


if __name__ == "__main__":
    if "--refresh-pricing" in sys.argv:
        # pricing refresh: silent, and exit 0 whatever happens — it is meant to
        # be hung off a session hook, where an unreachable network must cost
        # nothing but a stale snapshot (see refresh_pricing)
        try:
            sys.exit(refresh_pricing())
        except Exception:
            sys.exit(0)
    if "--report" in sys.argv:
        # report mode is intentionally NOT wrapped in the silent-fail guard
        sys.exit(run_report([a for a in sys.argv[1:] if a != "--report"]))
    if "--ingest-delegate-receipt" in sys.argv:
        # also NOT wrapped in the silent-fail guard: a caller of this direct
        # CLI entry point (delegate.sh's cmd_run, itself already `|| true`,
        # see the module docstring) needs a real exit code for a malformed
        # receipt, same reasoning as --report above.
        idx = sys.argv.index("--ingest-delegate-receipt")
        if idx + 1 >= len(sys.argv):
            print(
                "cost-mirror --ingest-delegate-receipt: requires a receipt path",
                file=sys.stderr,
            )
            sys.exit(1)
        sys.exit(_ingest_delegate_receipt(sys.argv[idx + 1]))
    try:
        main()
    except Exception:
        pass  # fail silent and open: a broken mirror must never break a prompt
    sys.exit(0)
