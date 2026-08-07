#!/usr/bin/env python3
"""cost-mirror — UserPromptSubmit hook: one-line, by-model token spend for the
current session, injected as context each prompt.

Why: the orchestrator is asked to keep spend on the cheap tiers but has no
in-session view of what anything costs — an unobservable optimisation target
(bead j09). This prints one compact line ("main: ... | workers: ...") derived
from the live transcript, so the cost of working inline vs delegating is
visible at the moment the choice is made. It constrains nothing.

Mechanics: UserPromptSubmit stdout on exit 0 is added to the model's context.
The main transcript and every subagents/**/*.jsonl beneath it (recursive —
see "Nested subagents" below) are scanned INCREMENTALLY — a per-session
state file under ~/.claude/cache/cost-mirror/ keeps a byte offset and
running totals per file, so each prompt parses only appended lines (a
shrunk/rotated file rescans from zero). Assistant rows are aggregated by
message.model: rows with isSidechain or living under subagents/ count as
worker spend (see "Per-role attribution" for how "worker" is now split),
the rest as main. Input, output, cache-read, and cache-write (5m/1h split,
when the row breaks it out) tokens are all tracked, de-duplicated first
(see "Per-response de-duplication"). A static per-model USD/MTok pricing
table (prefix-matched, see PRICING_TABLE) turns those into an actual
dollar figure, plus a counterfactual "saved" figure — see "Delegation-only
savings" below for what that's counterfactual against. Unknown/off-ladder
models still show their tokens but cost $0 and mark the line with a
trailing '?'. "<synthetic>" rows are skipped.

Per-response de-duplication (added 2026-07-31): a single API response is
written to the transcript as SEVERAL assistant rows sharing one
message.id — one row per content block (thinking/text/tool_use) — and
each row repeats the parent response's usage in full EXCEPT
output_tokens, which is CUMULATIVE across the group (e.g. 3,3,3,3,3,571
for one real six-block response). Counting every row as if it were its
own full response double- (or worse-) counted input/cache-read/cache-
write and inflated output too, overstating spend by roughly 2.17x
machine-wide. scan_file now counts in/cache-r/cache-w ONCE per
message.id (on the group's first row) and takes the MAX/last value for
output (via a small per-file dedup ring persisted in fstate — see
_dedup_seen/_dedup_note — so a group split across an incremental scan
boundary still dedupes correctly). A row with no message.id (e.g. a
hand-crafted test fixture) is never deduped, counted in full as before.
This forced the STATE_VERSION bump (v3 -> v4, see below) and a rebuild of
lifetime.json (LIFETIME_VERSION 2 -> 3): both persisted stores held
counts inflated by the bug and had no record of which message.id
contributed what, so there was no way to retroactively fix them in place.

De-dup ring eviction (bd-zjb, added 2026-08-06): the dedup ring above is
capped at DEDUP_RING (8) entries per file, on the assumption that a group's
rows are contiguous enough that 8 OTHER distinct message.ids never
intervene between two rows of the same group. Nothing enforced that
assumption: once >=8 other ids arrived, the ring silently evicted the
earlier entry, and that mid's next row was then indistinguishable from an
untracked id's genuine first row -- counted in full a second time, doubling
in/cache-r/cache-w for that response (reproduced with a synthetic fixture:
8 intervening ids inflates a session from $5.00 to $10; 7 does not — see
tests/tier-hooks.bats). Evicted mids now move into a second, larger,
separately-bounded set (fstate["dd_evicted"], capped at DEDUP_EVICTED_RING)
that _dedup_seen also checks — a hit there still suppresses re-adding
in/cache-r/cache-w, at the cost of no longer knowing that mid's prior
running-max output (a small, bounded imprecision confined to output alone;
see _DEDUP_EVICTED and scan_file). This did NOT bump STATE_VERSION: unlike
the fix above, an old fstate simply has no "dd_evicted" key yet, which
`.setdefault` treats as empty and starts populating correctly from the next
scan onward — there is no stored-but-wrongly-shaped data to invalidate, only
(unrecoverable, same as any bug before its fix) already-summed historical
totals from any eviction that already happened.

De-dup promoted to per-SESSION (bd-6vy, added 2026-08-07): the ring above
was scoped per FILE (files_state[path] in scan_session, one independent
"dd"/"dd_evicted" pair per scanned file), so a message.id appearing in TWO
files of the same session -- e.g. an isSidechain:true row inline in the
main transcript AND a full row in a co-located subagents/agent-x.jsonl,
both carrying the same response's message.id -- was invisible to each
other's ring and got counted in full in each file, doubling in/cache-r/
cache-w for that one response. scan_session now creates ONE dedup ring per
session, homed in the main transcript's own fstate entry
(files_state[tp]) -- tp already uniquely keys one session within
files_state in both hook mode (one files_state per session) and --report
--all (one flat files_state shared across every session on disk, see
run_report_all), so reusing it as the dedup home needs no new bound of its
own: same DEDUP_RING/DEDUP_EVICTED_RING caps as before, just counting
message.ids from every file in the session instead of one file at a time.
scan_file takes an explicit dedup_state argument now (defaulting to its
own fstate for any hypothetical single-file caller); scan_session passes
the SAME main-transcript fstate as dedup_state to every file it scans --
main transcript included -- so first-seen-wins regardless of which file a
mid's first row happens to land in. This did NOT bump STATE_VERSION either
by the same reasoning as bd-zjb above: a subagent file's fstate simply
stops accumulating its own "dd"/"dd_evicted" going forward (nothing reads
those keys off a non-main path), and any already-scanned "dd"/"dd_evicted"
sitting on an old subagent-path entry is just inert dead weight, never
consulted again.
Two accepted corners, both already the file's stated failure posture
(bounded imprecision over unbounded growth or a crash) rather than new
ones: (1) fstate.clear() on a truncated/rotated file (see scan_file) wipes
whichever fstate it's called on. A truncated SUBAGENT file wipes only that
file's own off/agg/bagg; the session ring (on the main transcript's
fstate) is untouched, so the subagent's re-scanned rows now look like
already-seen mids and get suppressed -- a bounded undercount, where the
old per-file design would have recounted them correctly. A truncated MAIN
transcript wipes the ring itself, so the session degrades to this same
bug's pre-fix behaviour until the ring repopulates. (2) the shared ring's
DEDUP_RING(8)/DEDUP_EVICTED_RING(512) capacity is now spent across ALL of
a session's files rather than one, so a main-transcript mid can push a
subagent group's live-ring entry out (impossible when rings were
per-file) one incremental boundary earlier than before; the failure mode
is exactly the already-accepted dd_evicted output-only imprecision above,
not a new one, so the existing bounds are left unchanged rather than
enlarged.

Nested subagents (added 2026-07-31): workflow-spawned agents land one
directory deeper than a plain subagent spawn — subagents/workflows/
<wf_id>/agent-*.jsonl — which the old single-level subagents/*.jsonl glob
never matched, silently excluding those transcripts' spend from every
report. scan_session (and the read-only mirror _session_file_paths()
that --all uses to regroup its flat cache) now glob subagents/**/*.jsonl
with recursive=True, which matches both the old flat layout and the
nested one.

Per-role attribution (added 2026-07-31): every subagent row used to share
one bare "worker" side, mixing verifier/executor/scout/everything-else
into one bucket. Each subagent transcript is now labelled "worker:<role>"
from its co-located sidecar agent-<ID>.meta.json (see _agent_label) — the
role is meta["customAgentType"] if present, else meta["agentType"];
NAMED spawns put the spawn's *name* in agentType and the true role in
customAgentType (e.g. {"agentType": "benchbase", "customAgentType":
"executor"}), so agentType alone produces junk labels ("worker:final-
check", "worker:gate-check", ...) and undercounts real roles. A missing/
unreadable sidecar, or one with neither key, falls back to bare "worker"
rather than guessing. Every consumer that used to compare a side to the
literal string "worker" (summarise_tokens, session_delegation_savings,
render_report) now treats "not main" as the worker test instead, so a
per-role row is never silently dropped from the "workers:" hook clause,
the delegation-savings sum, or the report table.

Cost-sorted rows (bd-cro, added 2026-08-06): render_report's per-side rows
used to sort by -(out + cr) -- token VOLUME, descending. Volume is a poor
stand-in for money: a large haiku row would rank above a small fable row
despite costing a fraction as much, which is backwards for a report whose
whole point is "where did the spend go". Rows within each side now sort by
the row's own REAL DOLLAR COST (the exact figure the "actual $" column
shows, via cost() computed once per row and reused for both the sort key
and the column -- never recomputed), descending, tiebroken by model id
ascending so the output is byte-identical across repeated runs on identical
input regardless of dict insertion order (proven directly in
tests/tier-hooks.bats: two --report runs on the same transcript diffed to
nothing). This was one of two candidate definitions of "most expensive":
real dollars spent (usage-dependent, changes as spend accrues) vs. unit-
PRICE rank (fable > opus > sonnet > haiku, stable regardless of usage).
Dollars spent is what this implements, because a cost report's job is to
say what actually cost money, not what a model's list price ranks as. Side
grouping ("main" first, then each worker/worker:<role> alphabetically --
see "Per-role attribution" above) is UNCHANGED, and cost sort applies only
WITHIN a side: a flat cost-ordered table was considered and rejected, since
it would bury e.g. a cheap "main" row under a pile of pricier worker rows
and lose exactly the structural "where did this happen" read the side
column exists to give. Unpriced/off-ladder models (rates_for() -> None,
cost() -> 0.0) need no special-casing: $0.00 is already the minimum any row
can sort to under descending-cost order, so they fall out at the BOTTOM of
their side on their own, already marked separately by the label's trailing
"?".

Model-in-name spawns (bd-8ty, added 2026-08-06): the live subagent panel
can now name a spawn "<role>-<model-slug>" (e.g. "executor-sonnet-5",
"scout-haiku-4-5" -- see the naming convention in
config/claude-user-memory.md) so the bound tier is visible without cross-
referencing this report. This lands the slug in the SAME place a plain
`name` always has -- the sidecar's agentType -- with the true role still in
customAgentType (e.g. {"agentType": "executor-sonnet-5", "customAgentType":
"executor"}), which _agent_label already reads in preference to agentType;
verified directly against LIVE sidecars this convention already produced in
this container ({"agentType": "verifier-opus-5-resume", "customAgentType":
"verifier", ...}) and pinned in tests/tier-hooks.bats, a model-bearing name
does NOT fragment or undercount its role -- it still folds into plain
"worker:<role>". The model itself is deliberately NOT duplicated into the
side label: column 2 ("model") already carries it per row (see scan_file's
per-"side|model" aggregation key), so repeating it in the label would be
redundant, and the side column's width (18, sized for "worker:<role>")
would truncate a role+model string like "worker:executor:sonnet-5" and lose
information the model column shows in full. Where the two surfaces
disagree, the live panel wins (per the bead) -- it does, by construction,
since the panel name is a separate string entirely and this table's column
layout is untouched by it. Separately: verifier/oracle are bound `model:
inherit` in their frontmatter, but the "model" this table shows is never
that config string -- it's message.model off the actual transcript row,
i.e. the concrete model the API resolved "inherit" to at runtime (e.g.
"claude-opus-5" when the session's orchestrator runs Opus) -- so a
worker:verifier/worker:oracle row already displays the real resolved model
and never the literal word "inherit", with no code change needed here
(verified against this container's own live worker:verifier row, and
pinned in tests/tier-hooks.bats).

Delegation-only savings: "saved" means spend that would not have happened
without delegating to a cheaper WORKER model — never spend saved by running
the orchestrator itself (main-loop) on a cheaper tier. Early versions priced
every row — main-loop included — at the single most expensive model seen
anywhere in the session (pick_top_model); that conflated "I downgraded my
own orchestrator with /tier" with "I delegated to a cheap worker", and
inflated "saved" by however much main-loop spend happened to occur before
the downgrade. Fixed via per-session TIER EPOCHS: main-loop rows are ordered
by their transcript "timestamp" and split into maximal runs sharing the same
message.model (see _epochs_from_main_buckets); each worker row reprices only
against the epoch its own timestamp falls into, and a main-loop row's tier
IS its own epoch by construction, so main-loop spend can never show up as
"saved" — the fix's entire point. Rows are bucketed into 5-minute windows
(BUCKET_SECONDS) rather than compared row-by-row, purely to keep the
incremental scan's persisted state bounded by wall-clock session length
(not row count); epoch boundaries are then computed as a cheap pass over
those buckets (session_epoch_pricing). The first epoch's start and the last
epoch's end are then CLAMPED so the union of epochs covers the WHOLE session
timeline, not just the span between the first and last main-loop row (see
_epochs_from_main_buckets) — a worker row is thus always attributed to the
orchestrator tier IN EFFECT AT ITS TIMESTAMP, rather than being told "no
evidence, contributes zero" just for falling before the session's first
main-loop row or after its last. Note "in effect at", not "nearest in time":
a gap between two epochs belongs to the EARLIER one, since that tier stayed
bound until the next main-loop row proved otherwise, so a worker landing one
minute before a tier change still prices at the outgoing tier. The one case
that DOES still
contribute zero to "saved": a worker row with no parseable timestamp of its
own (see _parse_ts) in a session whose main rows DO have usable timestamps —
there is genuinely no bucket to place it in. A session in which NO row
(main or worker) has a usable timestamp collapses entirely to NA_BUCKET,
which is exactly the pre-epoch whole-session behaviour, so that case is NOT
zero — see _epochs_from_main_buckets for why. Epochs are always computed
and summed PER SESSION and never merged across sessions (see
run_report_all/_add_pricing), so one session's tier change can never
reprice another session's spend in an aggregate report. A session that
never changed its main-loop model AND whose worker rows all carry parseable
timestamps produces the exact figure this always did (single epoch, now
clamped to span the whole session regardless of where main-loop rows
actually fall, so the fix is a no-op) — asserted directly in
tests/tier-hooks.bats. The guarantee is scoped to that second condition on
purpose: an untimestamped worker in an otherwise-timestamped session has no
bucket to place it in and so contributes zero, which does differ from the
old whole-session figure.

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

Delegation-gate drift segment (added 2026-07-30): scripts/delegation-gate.py
persists {"max_streak", "warns", "denies"} per session (see its module
docstring) as a mechanical record of how much main-loop grinding actually
happened, independent of anything reported here. The hook line appends a
short " | inline: max streak N · W warn(s) · D deny/denies" clause read
straight from that session's state file
(~/.claude/cache/delegation-gate/<session_id>.json, session_id taken from
this hook's own event payload the same way delegation-gate.py reads it from
its PreToolUse payload). This module does NOT import delegation-gate.py —
its state-dir path is duplicated locally (see DELEGATION_GATE_* below, with
a comment naming the owner) rather than coupling the two scripts. The
segment is omitted entirely when there is nothing to report (max_streak 0
and no warns/denies) and degrades exactly like the rest of this script: a
missing, unreadable, or malformed state file, or a missing session_id,
yields "" silently — never an exception, never a broken cost line.

On-demand report: `cost-mirror --report` (bare, i.e. the `tier-cost` alias)
now AGGREGATES — it scans every transcript on disk (see "Cross-session"
below) and is the same thing `--all` did before this changed; `--all`
still works too, as a no-op alias, so old habits/docs keep working. Three
narrower views select a single session instead:
  `--report <transcript.jsonl>`  a specific transcript, given directly.
  `--report --session <prefix>`  the transcript whose sessionId (or
                                  filename UUID) starts with <prefix>;
                                  ambiguous or no-match prefixes fail loud.
  `--report --this`              the old bare-default behaviour: the
                                  transcript recorded in the newest
                                  cost-mirror hook state file (see
                                  _default_transcript) — i.e. "whichever
                                  session most recently ran the hook",
                                  which is NOT necessarily the session
                                  you're sitting in if another session's
                                  hook fired more recently (this was the
                                  exact source of the bug that made bare
                                  --report silently point at a nearly-empty
                                  parallel session — seeing this line spell
                                  out the mechanism is the fix).
All three single-session forms do a full read-only scan from offset zero
into a throwaway dict and never write any state (including lifetime.json
— see below), so they can be run any number of times without disturbing
the hook's incremental counters. Unlike hook mode this path is NOT
fail-silent: a missing/unreadable/ambiguous transcript prints to stderr
and exits nonzero, since it's invoked directly from a terminal to debug.

Cross-session report: `cost-mirror --report` (bare or `--all`)
`[--since <N>d]` scopes the report to every transcript found on disk,
independent of any live session — every ~/.claude/projects/*/*.jsonl plus
each one's beside-it subagents/*.jsonl. --since 7d/30d/etc limits it to
transcripts modified in that window; without it every transcript is
included. Output is a per-session table (project, short session id,
last-modified date, total tokens, actual $, newest first) followed by the
same per-side|model breakdown and grand total render_report produces for a
single session, and a header stating the scope plainly: session count,
project-dir count, and the --since window when given. Because this can
mean scanning hundreds of files, it keeps its own persisted incremental
cache — a dedicated `all-sessions.json` in the state dir, keyed by file
path with the same {off, agg} shape as the hook's per-session state — so
repeat runs only read appended bytes; this cache is separate from the
hook's per-session state files, and the single-session forms above still
never write any state at all.

Durable lifetime rollup: transcripts get deleted (disk-cleanup, manual
pruning), which would otherwise silently erase their spend from every
future aggregate report. Both the hook (for the live session) and the
aggregate report path write each session's final `sessionId|side|model`
counters into `lifetime.json` in the state dir — REPLACING that session's
prior rows every time (never incrementing), so rescanning the same
transcript any number of times cannot inflate the durable total. The
aggregate report unions live-scanned transcripts with lifetime rows whose
transcript is no longer on disk, so a deleted session's spend still counts
toward the grand total and the per-session table; a footnote names how
many sessions were pulled from history rather than disk. Single-session
views (`--session`/`--this`/a direct positional transcript) never touch
lifetime.json, preserving their read-only-with-respect-to-state guarantee.
"""

import glob
import hashlib
import json
import os
import sys
import time
from datetime import date, datetime


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


STATE_VERSION = 4  # bumped from 3: every assistant JSONL row used to be
# counted as if it were one full API response, but ONE response is written
# as SEVERAL rows sharing one message.id (one row per content block --
# thinking/text/tool_use), each repeating the parent response's usage in
# full except output_tokens (cumulative across the group). That double-
# (or worse-) counted in/cache-r/cache-w and inflated out too -- ~2.17x
# machine-wide. A v3 state holds those inflated per-content-block counts
# with no record of which message.id contributed what, so there is no way
# to retroactively de-duplicate already-persisted totals; the version bump
# forces a one-time clean rescan rather than mixing correct and doubled
# dollars together. This bump ALSO changes what "worker" keys look like
# (see _agent_label: bare "worker" splits into "worker:<role>" for a
# labelled subagent transcript), so a clean rescan is needed for that
# reason too -- an old state's "worker|model" rows would otherwise never
# get their per-role split.
LIFETIME_VERSION = 3  # bumped from 2 alongside STATE_VERSION this time --
# unlike the earlier bagg-only STATE_VERSION bump (which left lifetime.json
# untouched on purpose, see below), THIS bug corrupted the actual counters
# _update_lifetime persists (the same double-counted in/out/cr/w5/w1 the
# scan-state bump above describes), so carrying old lifetime rows forward
# would keep reporting doubled dollars for every deleted-transcript session
# forever. Kept as its OWN constant (not folded into STATE_VERSION) purely
# so a FUTURE scan-state-only bump (e.g. another bagg-shaped change) can
# again avoid wiping durable lifetime history that has nothing wrong with
# it -- this slice needed both bumped, that doesn't mean they're coupled.
COUNTER_KEYS = ("in", "out", "cr", "w5", "w1")

# De-dup ring size for scan_file's per-message.id state (see _dedup_seen/
# _dedup_note below): duplicate rows sharing a message.id are contiguous in
# the OVERWHELMING common case, so a short ring is enough to survive an
# incremental scan boundary landing inside a group without growing state
# unboundedly.
DEDUP_RING = 8

# bd-zjb (2026-08-06): DEDUP_RING bounds the LIVE ring -- the one
# _dedup_seen can still return a numeric running-max output from -- but a
# mid can fall off that ring while its group is still open (>=DEDUP_RING
# OTHER distinct ids arriving between two rows of the same group; reproduced
# with a synthetic fixture, see tests/tier-hooks.bats). Before this fix,
# eviction was SILENT: the next row for that mid looked exactly like an
# untracked id's first row and got counted in full a second time, doubling
# in/cache-r/cache-w for that response (output too, to a lesser degree --
# see scan_file). Evicted ids now move into a second, separately-bounded set
# (fstate["dd_evicted"]) that _dedup_seen also checks -- see _dedup_note.
# DEDUP_EVICTED_RING is deliberately much larger than DEDUP_RING: it only
# holds bare ids (no per-id counters, so it's cheap), and requiring this
# many MORE distinct ids on top of DEDUP_RING's own 8 before a mid falls out
# of dd_evicted TOO makes the residual gap vanishingly unlikely in any real
# transcript, without ever growing persisted state unboundedly with session
# length (satisfies the same "bounded" constraint DEDUP_RING was chosen
# for). One bound, shared by the hook's persisted incremental state and
# --report's throwaway single-scan state alike -- see scan_file.
DEDUP_EVICTED_RING = 512

# _dedup_seen's sentinel for "mid was seen before, but its live-ring entry
# was evicted" (see DEDUP_EVICTED_RING above) -- distinct from None (never
# seen at all) and from a real running-max output value, which is never
# negative.
_DEDUP_EVICTED = -1

# Tier-epoch bucketing (see "Delegation-only savings" in the module
# docstring): main-loop and worker rows are grouped into BUCKET_SECONDS-wide
# time buckets (keyed into the same "side|model|bucket" composite-string
# scheme "agg" already uses, so no new JSON key-typing concerns). 5 minutes
# is coarse enough that even a long session's bucket count stays small
# (state grows with wall-clock session length, not row count) while still
# resolving a real /tier change to the epoch it actually happened in.
BUCKET_SECONDS = 300
NA_BUCKET = -1  # sentinel for a row with no usable timestamp; see _parse_ts

# sonnet-5 intro pricing (2.00/10.00 per MTok in/out) holds while today is
# strictly before this date; from then on it reverts to the standard 3/15.
SONNET5_INTRO_CUTOFF = date(2026, 9, 1)

# scripts/delegation-gate.py OWNS this path constant; duplicated here (not
# imported) to keep the two scripts decoupled -- see the module docstring's
# "Delegation-gate drift segment" section. Keep in sync by hand if
# delegation-gate.py ever moves its state.
DELEGATION_GATE_STATE_DIR = "~/.claude/cache/delegation-gate"


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
    duplicate rows for one message.id are contiguous in the OVERWHELMING
    common case, so a short ring survives an incremental scan boundary
    landing inside a group without growing state unboundedly). Persisted as
    plain lists (not tuples) in fstate so it survives a JSON round-trip
    through the state file.

    bd-zjb: an entry evicted here used to vanish without a trace -- its
    mid's next row then looked exactly like an untracked id's first row,
    silently double-counting in/cache-r/cache-w (see DEDUP_EVICTED_RING).
    Evicted mids are now carried forward into fstate["dd_evicted"] (a set of
    bare ids, no counters) instead, itself capped at DEDUP_EVICTED_RING for
    the same "don't grow state unboundedly" reason DEDUP_RING exists."""
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

    worker_label is the "side" bucket used for a row that IS a worker row
    (assume_worker=True, or row["isSidechain"] for a sidechain row embedded
    in the main transcript) — bare "worker" by default, or "worker:<role>"
    for a per-role-labelled subagent transcript (see _agent_label /
    scan_session). It never affects "main" rows.

    dedup_state is the dict whose "dd"/"dd_evicted" keys _dedup_seen/
    _dedup_note read and write — bd-6vy: SESSION-scoped (the main
    transcript's own fstate, shared across every file scan_session scans
    for that session) rather than necessarily `fstate` itself (this file's
    own off/agg/bagg bookkeeping), so a message.id landing in two different
    files of the same session still dedupes. Defaults to `fstate` when
    omitted, for a hypothetical single-file caller with no session to
    share a ring with; scan_session always passes one explicitly now."""
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
        # De-dup: one API response is written as several rows sharing one
        # message.id (one row per content block), each repeating the
        # parent response's in/cache-r/cache-w usage IN FULL, while
        # output_tokens is CUMULATIVE across the group. Count in/cr/w5/w1
        # only on the group's first row; for later rows in the group,
        # count only the marginal (non-cumulative) increase in out, and
        # zero the rest. A row with no message.id (e.g. hand-crafted test
        # fixtures) is never deduped -- counted in full, as before.
        #
        # bd-zjb: _dedup_seen can also report _DEDUP_EVICTED -- mid WAS
        # seen, but its live-ring entry fell off before this row arrived
        # (see _dedup_note / DEDUP_EVICTED_RING). That's still a later row
        # of an already-counted group, so in/cache-r/cache-w must NOT be
        # re-added here either -- that re-adding was the bug. Its prior
        # running-max output is gone, though, so this row's own output is
        # counted in full rather than marginally: a small, bounded overcount
        # confined to output alone (a minority of real spend -- cache-read
        # dominates, see the module docstring), traded for eliminating the
        # unbounded in/cache-r/cache-w overcount this replaces. mid is NOT
        # re-armed in the live ring here, so a third row of the same group
        # is still treated as evicted rather than as a fresh first row.
        #
        # bd-6vy: dedup_state (not necessarily this file's own fstate) is
        # SESSION-scoped -- see scan_session -- so a mid first seen in
        # ANOTHER file of this session (e.g. an isSidechain row in the main
        # transcript, deduped here against a subagent file's copy of the
        # same response) is already caught by the seen-is-not-None branches
        # below, not just a repeat within this one file.
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
    co-located sidecar <same-stem>.meta.json. The effective role is
    customAgentType when present, else bare agentType -- for a NAMED spawn
    the sidecar puts the *name* in agentType and the true role in
    customAgentType (e.g. {"agentType": "benchbase", "customAgentType":
    "executor"}), so agentType alone would mislabel/fragment those rows
    (junk like "worker:final-check", "worker:gate-check", and an
    undercounted "worker:verifier"). A missing/unreadable sidecar, or one
    with neither key, falls back to bare "worker" so nothing is ever
    dropped or mislabelled on a guess."""
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
    (recursive: workflow-spawned agents land at subagents/workflows/<wf_id>/
    agent-*.jsonl, one level deeper than a plain subagent spawn, and would
    otherwise never be scanned at all) into files_state (a "path" ->
    {off, agg} dict), mutating it in place. Shared by hook mode
    (incremental, persisted) and --report (one-shot, throwaway).

    Each subagent transcript gets its own per-role "side" label from
    _agent_label (its co-located sidecar), rather than the bare "worker"
    every subagent row used to share — see the module docstring.

    bd-6vy: every file scanned here shares ONE de-dup ring for the whole
    session, homed in the main transcript's own files_state[tp] entry (tp
    uniquely keys this session even in --report --all's flat, cross-
    session files_state — see the module docstring) — so a message.id
    appearing in more than one of this session's files (main transcript
    included) is only ever counted once, not once per file."""
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
    """One compact clause per side: in/out/cache-read/cache-write token counts,
    each omitted when zero so a quiet session (e.g. a worker with no cache
    writes) stays short. Order is in, out, cache-r, cache-w.

    "workers" here means every row whose side is NOT literally "main" —
    plain "worker" rows AND per-role "worker:<role>" rows (see
    _agent_label) are folded into the same "workers" clause; this line is
    an aggregate summary, per-role detail lives in render_report's table."""
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
    rate from rates_for (unknown-rate models rank below every known-rate
    model), tiebroken by (out+cr) volume descending. Price, not volume, is
    what matters — a bucket/session that ran mostly on a cheap model and
    briefly on a pricier one must still pick the pricier one, otherwise the
    pricier tokens would reprice DOWN and "saved" would read as a large,
    misleading negative. If there are no main rows at all, falls back to
    the most expensive model observed overall (ranked by output rate;
    unknown models rank last).

    Two roles today (both informational/selection, no longer a dollar
    driver — see session_epoch_pricing for that): (1) called once per
    BUCKET inside _epochs_from_main_buckets, to pick that bucket's
    representative main-loop model when more than one appears in the same
    5-minute window; (2) called once on a whole session's/report's `total`
    for the "top model (counterfactual)" display line and the hook line's
    "at <model>" label — a plain "most expensive model seen" fact, no
    longer what any dollar figure is repriced at (that used to be its only
    job, and conflating "the priciest model appeared somewhere this
    session" with "everything should be judged against it" was the bug;
    see session_delegation_savings)."""
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

    bucket_total is one session's aggregate_bucket_total() output ("side|
    model|bucket" -> counters) — never a multi-session merge, or a
    session's tier would leak into another's (see session_epoch_pricing).

    A tier epoch is a maximal run of main-loop buckets sharing the same
    representative model, in ascending bucket order — "ascending bucket
    order", not scan/file order, so a row arriving out of order (a system
    clock jump backwards, or two files interleaving) self-corrects here;
    buckets are sorted every time this runs, never accumulated in arrival
    order. A bucket that saw more than one main model (a genuine tier
    change inside one 5-minute window, or — far more commonly — every
    timestamp-less row in a session sharing NA_BUCKET) is resolved by
    pick_top_model()'s own price-ranked pick restricted to that bucket's
    main rows; reusing that exact tie-break (not e.g. picking by volume)
    is what makes a session with NO timestamps at all collapse to one
    bucket and reduce EXACTLY to the pre-epoch whole-session method,
    preserving the no-tier-change compatibility guarantee even then.

    Returns an ascending list of (model, start_bucket, end_bucket) with
    end_bucket EXCLUSIVE. Every epoch but the last has its end_bucket
    pulled forward to equal the next epoch's start_bucket, so an idle gap
    between two runs of DIFFERENT models still belongs to the earlier one
    (there is no such thing as an interior "no epoch" gap). The FIRST and
    LAST epochs are then clamped outward so the union of epochs covers the
    ENTIRE session timeline, not just the span between the first and last
    main-loop row: the first epoch's start_bucket is pulled back and the
    last epoch's end_bucket is pushed forward to infinity. This makes the
    module docstring's compatibility guarantee literally true (a session
    with only one epoch now spans the WHOLE session, so a worker row
    anywhere in it — before, during, or after the recorded main-loop
    activity — reduces to the old whole-session method) and gives every
    worker row a defensible epoch: the orchestrator tier in effect at its
    timestamp, rather than "no evidence, contributes zero". Note that an
    interior gap between two epochs belongs to the EARLIER one — the tier
    stayed bound until a later main-loop row proved otherwise — so this is
    "in effect at", not "nearest in time" (see session_epoch_pricing and
    the module docstring's "Delegation-only savings" section).

    The backward clamp uses NA_BUCKET + 1 (0), NOT float("-inf"): real
    bucket numbers are always huge positive ints (epoch-seconds //
    BUCKET_SECONDS, i.e. seconds since 1970), so 0 is a floor low enough to
    absorb any real early timestamp while deliberately NOT swallowing
    NA_BUCKET (-1) itself — a worker row with no parseable timestamp of its
    own must still fall outside a real epoch built from properly
    timestamped main rows (see the module docstring's NA-timestamp note).
    When every main row shares NA_BUCKET (no row in the session has a
    usable timestamp), the lone epoch's own start is already NA_BUCKET, so
    the clamp is a no-op there and NA_BUCKET correctly stays inside its own
    epoch, spanning to infinity — collapsing to "reprice everything at the
    session's one main-loop model," the pre-epoch behaviour, exactly as
    intended for that case. A session with no main rows at all returns []."""
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


def session_epoch_pricing(bucket_total):
    """Per "side|model" -> {"actual": $, "at_epoch": $}, this session's
    tier-epoch-aware counterfactual (replaces the old "reprice everything
    at one session-wide top model" approach — see module docstring).

    MAIN rows always get at_epoch == actual: a main-loop row's own tier IS
    the epoch it's in, by construction, so it can never show a nonzero
    "saved" — main-loop spend is no longer eligible to appear in "saved"
    at all, which is the fix this slice makes (a session that downgrades
    its own orchestrator no longer reports that downgrade as delegation
    savings). This is enforced unconditionally here rather than relying on
    the bucket-lookup landing on the row's own model, because a bucket
    that mixed more than one main model resolves to ONE representative
    model (see _epochs_from_main_buckets) — the non-winning model's rows
    must still net to zero, not silently reprice at the bucket's winner.

    WORKER rows reprice at the epoch containing their bucket. Since
    _epochs_from_main_buckets clamps the first/last epoch to cover the
    whole session timeline, a worker row falls outside every epoch (and
    so keeps at_epoch == actual, contributing zero to savings) only when
    there are no epochs at all — no main rows ever recorded for this
    session. A worker with no parseable timestamp of its own (NA_BUCKET)
    similarly contributes zero UNLESS every main row shares NA_BUCKET too
    (no row in the session has a usable timestamp), in which case the
    lone epoch is NA_BUCKET's own and, being clamped forward to infinity,
    captures every worker regardless of its own bucket — see the module
    docstring's NA-timestamp note."""
    epochs = _epochs_from_main_buckets(bucket_total)
    per_row = {}
    for key, counters in bucket_total.items():
        side, model, bucket_s = key.split("|", 2)
        d = per_row.setdefault(f"{side}|{model}", {"actual": 0.0, "at_epoch": 0.0})
        actual = cost(counters, rates_for(model))
        d["actual"] += actual
        if side == "main":
            d["at_epoch"] += actual
            continue
        epoch_model = _epoch_model_for_bucket(epochs, int(bucket_s))
        epoch_rates = rates_for(epoch_model) if epoch_model else None
        d["at_epoch"] += cost(counters, epoch_rates) if epoch_rates else actual
    return per_row


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


def session_delegation_savings(bucket_total):
    """This session's total delegation savings: Σ over WORKER "side|model"
    rows of (at_epoch − actual) from session_epoch_pricing. "worker" here
    means any side that ISN'T "main" — plain "worker" rows and per-role
    "worker:<role>" rows alike (see _agent_label); filtering on
    `not key.startswith("main|")` rather than `key.startswith("worker|")`
    is what makes that inclusive (the equality-style filter silently
    dropped every per-role row and returned 0.0 "saved" for any session
    with role-labelled subagents). Main-loop rows never contribute (they
    always have at_epoch == actual there), so this is equivalent to
    summing over every row, but summing worker-only here makes that
    invariant explicit rather than relying on it silently."""
    pricing = session_epoch_pricing(bucket_total)
    return sum(d["at_epoch"] - d["actual"] for key, d in pricing.items() if not key.startswith("main|"))


def summarise_dollars(total, bucket_total, billing_mode="api"):
    """Actual dollar cost, plus an "at <model>" counterfactual and the
    resulting savings, as a compact clause (or "" if there's nothing to
    show). Unknown-priced models still contribute their tokens to the token
    summary but cost $0 here and mark the clause with a trailing '?'.

    The savings figure comes from session_delegation_savings(bucket_total)
    — summed across this session's tier epochs, worker rows only — NOT
    from repricing the whole session at one top model the way this used
    to work; see the module docstring's "Delegation-only savings" section.
    The displayed "at <model>" label still uses pick_top_model(total) (the
    single most expensive model this session touched) purely as a
    human-readable name for the clause; it does not drive the dollar
    figures when a session crossed more than one tier epoch.

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
    saved = session_delegation_savings(bucket_total)
    if top and round(saved, 2) != 0:
        at_top = actual + saved
        top_short = top.replace("claude-", "")
        clause += f" · ~{fmt_usd(at_top)} at {top_short} → saved ~{fmt_usd(saved)}"
    return clause


def delegation_drift_segment(session_id):
    """" | inline: max streak N · W warn(s) · D deny/denies" clause for this
    session's delegation-gate drift, or "" when there's nothing to report or
    the state can't be read -- see the module docstring's "Delegation-gate
    drift segment" section. Reads delegation-gate.py's own per-session state
    file directly (path duplicated locally, not imported); degrades exactly
    like the rest of this script on any failure."""
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
    """[tp] plus its beside-it subagents/**/*.jsonl (recursive — same scope
    as scan_session(), including nested subagents/workflows/<wf_id>/ agents)
    — the same file set scan_session() scans for one session, recomputed
    here (read-only glob, scan_session itself is untouched) so --all can
    group the flat cross-session cache back into per-session rows."""
    subdir = os.path.join(os.path.splitext(tp)[0], "subagents")
    return [tp] + sorted(glob.glob(os.path.join(subdir, "**", "*.jsonl"), recursive=True))


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


def _load_lifetime():
    path = _lifetime_path()
    try:
        with open(path) as fh:
            data = json.load(fh)
    except Exception:
        data = {}
    # LIFETIME_VERSION, deliberately NOT the scan-state STATE_VERSION —
    # this schema (plain "sessionId|side|model" counters) didn't change
    # when STATE_VERSION was bumped for tier-epoch bucketing, so tying the
    # two together would wipe durable history on every unrelated scan-
    # state schema bump for no reason.
    if data.get("v") != LIFETIME_VERSION:  # old/missing schema: start clean
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


def _update_lifetime(session_id, tp, project, mtime, session_total):
    """Durably record this session's final counters, keyed
    "sessionId|side|model" per the row, with per-row metadata (project dir,
    last-seen mtime, transcript path) alongside the counters.

    REPLACE, never increment: every existing row for this session_id is
    dropped first, then the freshly scanned totals are written in whole —
    so calling this any number of times with the same (fully rescanned)
    session_total is idempotent, and a session can never be double-counted
    by being written twice. This is deliberately called from both the hook
    path (main(), for the live session) and the aggregate report path
    (run_report_all) — never from a single-session view, which must stay
    read-only with respect to state."""
    data = _load_lifetime()
    rows = data["sessions"]
    prefix = f"{session_id}|"
    for key in [k for k in rows if k.startswith(prefix)]:
        del rows[key]
    for side_model, counters in session_total.items():
        entry = {k: counters.get(k, 0) for k in COUNTER_KEYS}
        entry.update({"project": project, "mtime": mtime, "tp": tp, "sessionId": session_id})
        rows[f"{session_id}|{side_model}"] = entry
    _save_lifetime(data)


def _lifetime_sessions_by_id(lifetime_data):
    """Group lifetime.json's flat "sessionId|side|model" rows back into
    per-session dicts: session_id -> {"totals": {side|model: counters},
    "project", "mtime", "tp"} — the shape run_report_all's durability union
    needs to add missing (deleted-from-disk) sessions back into the report."""
    grouped = {}
    for key, entry in lifetime_data.get("sessions", {}).items():
        session_id = entry.get("sessionId") or key.rsplit("|", 2)[0]
        side_model = key[len(session_id) + 1:]
        g = grouped.setdefault(
            session_id,
            {"totals": {}, "project": entry.get("project", ""), "mtime": 0, "tp": entry.get("tp", "")},
        )
        g["totals"][side_model] = {k: entry.get(k, 0) for k in COUNTER_KEYS}
        if entry.get("mtime", 0) >= g["mtime"]:
            g["project"] = entry.get("project", g["project"])
            g["mtime"] = entry.get("mtime", g["mtime"])
            g["tp"] = entry.get("tp", g["tp"])
    return grouped


def render_all_sessions_table(session_rows, since_days=None, n_projects=None):
    """One row per transcript — project dir, short session id, last-modified
    date, total tokens, actual $ — sorted by most recent first. Header
    states the scope plainly: session count, project-dir count, and the
    --since window when given (bd requirement: a blank-looking default
    report must never again be mistaken for "everything")."""
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
        lines.append(fmt_row((
            project, row["session"], modified, fmt(row["tokens"]), fmt_usd(row["actual"]),
        )))
    return "\n".join(lines)


def run_report_all(since_days):
    """The aggregate report: every transcript under ~/.claude/projects/*/*.jsonl
    (plus each one's beside-it subagents/*.jsonl), optionally scoped to
    --since. This is now what bare `--report` does (i.e. the `tier-cost`
    alias) — `--all` remains an accepted no-op alias for the same thing.
    Reuses scan_session()/aggregate_total() unchanged per-file and
    per-session; the grouping, incremental cache, and durable-lifetime
    bookkeeping here are new. NOT fail-silent, like plain --report — a
    corpus with nothing to report (no live transcripts AND no durable
    lifetime history in scope) prints a message and exits nonzero.

    Durability: every session scanned here has its final counters written
    into lifetime.json (REPLACE semantics — see _update_lifetime), and the
    grand total additionally unions in any lifetime session whose
    transcript no longer exists on disk (deleted by disk-cleanup, manual
    pruning, etc) so its spend is never silently lost. Sessions still
    on disk are always read live, never from lifetime, so lifetime is
    purely a fallback for what's gone."""
    transcripts = _list_transcripts(since_days)

    cache = _load_all_cache()
    files_state = cache["files"]  # persisted across runs: path -> {off, agg}

    session_rows = []
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
        # Epochs computed and priced PER SESSION, then folded into the
        # aggregate breakdown via _add_pricing — never by handing
        # render_report a bucket_total merged across sessions, which would
        # let session A's tier reprice session B's spend.
        _add_pricing(pricing, session_epoch_pricing(aggregate_bucket_total(session_state)))
        project = os.path.basename(os.path.dirname(tp))
        mtime = os.path.getmtime(tp)
        _update_lifetime(session_id, tp, project, mtime, session_total)
        tokens = sum(sum(c.values()) for c in session_total.values())
        actual = sum(
            cost(c, rates_for(key.split("|", 1)[1])) for key, c in session_total.items()
        )
        session_rows.append({
            "project": project,
            "session": os.path.splitext(os.path.basename(tp))[0][:8],
            "mtime": mtime,
            "tokens": tokens,
            "actual": actual,
        })

    _save_all_cache(cache)

    grand_total = aggregate_total(selected_state)

    # Durability union: lifetime sessions whose transcript is gone from
    # disk still count, subject to the same --since window (by their last
    # recorded mtime) as everything else in scope.
    grouped = _lifetime_sessions_by_id(_load_lifetime())
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
        tokens = sum(sum(c.values()) for c in info["totals"].values())
        actual = sum(
            cost(c, rates_for(sm.split("|", 1)[1])) for sm, c in info["totals"].items()
        )
        session_rows.append({
            "project": info["project"],
            "session": session_id[:8],
            "mtime": info["mtime"],
            "tokens": tokens,
            "actual": actual,
        })

    if not session_rows:
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
    # the durability-union's dead sessions (missing_count of them), so this
    # count always matches the table's own "N session(s)" header above it —
    # len(transcripts) undercounts by missing_count whenever any session was
    # pulled from lifetime history instead of a live file (bd finding).
    label = f"ALL sessions ({len(session_rows)} transcripts{since_label})"

    print(render_all_sessions_table(session_rows, since_days, n_projects))
    if missing_count:
        print()
        print(
            f"({missing_count} session(s) no longer on disk — counted from "
            "lifetime history)"
        )
    print()
    print(render_report(label, grand_total, billing_mode, billing_detail, pricing))
    return 0


def render_report(tp, total, billing_mode="api", billing_detail="", pricing=None):
    """Human-readable per-side|model table: token counts plus actual/at-top/
    saved dollars, with a totals row. cache-write is shown as one combined
    column (w5+w1) for compactness.

    `pricing` is a "side|model" -> {"actual": $, "at_epoch": $} dict (see
    session_epoch_pricing) driving the at-top/saved columns — the caller
    builds it, rather than render_report computing it itself, because a
    multi-session caller (run_report_all) must compute and sum each
    session's epochs SEPARATELY (via _add_pricing) and must never let
    render_report merge several sessions' bucket data into one epoch set
    (that would let one session's tier reprice another's spend). A row
    missing from `pricing` (e.g. a lifetime-history row for a deleted
    transcript, which carries no bucket data at all) falls back to
    at_epoch == actual, i.e. contributes zero to "saved" rather than
    guessing. None (the default) behaves as if `pricing` were empty —
    every row at_epoch == actual, "saved" reads 0 everywhere.

    A "billing: ..." line naming the mode/detection signal is always
    emitted, in both api and sub mode. billing_mode "sub" additionally
    marks the money columns as API-equivalent (subscription billing, not a
    per-token bill) without altering the table's column layout."""
    pricing = pricing or {}
    top = pick_top_model(total)  # informational "top model" line only —
    # no longer what at-top/saved are computed against, see `pricing` above

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
    # cache-r/cache-w counts) never runs two numbers together with no gap.
    # side widened from 7 to 18: "worker:<role>" rows (see _agent_label) run
    # longer than bare "main"/"worker" -- e.g. "worker:verifier" is 16 chars.
    widths = (18, 28, 11, 11, 11, 11, 10, 10, 10)

    def fmt_row(values):
        return "".join(
            v.ljust(w) if i < 2 else v.rjust(w) for i, (v, w) in enumerate(zip(values, widths))
        )

    header = fmt_row(cols)
    lines += [header, "-" * len(header)]

    grand = _empty_counters()
    tot_actual = tot_at_top = 0.0
    # "main" first, then every other side seen (plain "worker" and each
    # "worker:<role>" — see _agent_label), alphabetical among themselves so
    # the table's row order is stable run to run rather than dict order.
    # This grouping is a different axis from cost (WHERE the spend happened
    # structurally) and is kept even though rows are now cost-sorted WITHIN
    # each side (see bd-cro below) — collapsing to one flat cost-ordered
    # table was considered and rejected, since it would bury e.g. a cheap
    # "main" row under a pile of pricier worker rows and lose exactly the
    # structural "where did this happen" read the side column exists to give.
    sides = ["main"] + sorted({k.split("|", 1)[0] for k in total} - {"main"})
    for side in sides:
        rows = [(k.split("|", 1)[1], v) for k, v in total.items() if k.split("|", 1)[0] == side]
        # bd-cro: order by the row's REAL DOLLAR COST (the exact figure the
        # "actual $" column below shows), most expensive first — not the old
        # `-(out + cr)` token-volume key. Volume is a poor stand-in for
        # money: a large haiku row would rank above a small fable row despite
        # costing a fraction as much, which is backwards for a report whose
        # whole point is "where did the spend go". Two candidate definitions
        # of "most expensive" were considered: real dollars spent (usage-
        # dependent — order can shift as spend accrues) vs. unit-PRICE rank
        # (fable > opus > sonnet > haiku — stable regardless of usage). This
        # implements dollars spent, since a cost report's job is to say what
        # actually cost money, not what a model's list price ranks as.
        # rates_for()/cost() are computed ONCE per row here and the result
        # reused below for the "actual $" column — never recomputed.
        # Unpriced/off-ladder models (rates_for() -> None, cost() -> 0.0)
        # need no special-casing: $0.00 is already the minimum any row can
        # sort to under descending-cost order, so they fall out at the
        # BOTTOM of their side on their own, already marked separately by
        # the label's trailing "?" below. Ties (unpriced rows among
        # themselves, or any genuine equal-cost rows) break on model id
        # ascending, so output is byte-identical across repeated runs on the
        # same input regardless of dict/insertion order (see
        # tests/tier-hooks.bats: two --report runs on one transcript diffed
        # to nothing).
        priced = [(model, c, rates_for(model)) for model, c in rows]
        priced = [(model, c, rates, cost(c, rates)) for model, c, rates in priced]
        priced.sort(key=lambda row: (-row[3], row[0]))
        for model, c, rates, actual in priced:
            pr = pricing.get(f"{side}|{model}", {"actual": actual, "at_epoch": actual})
            at_top = pr["at_epoch"]
            saved = at_top - actual
            label = model.replace("claude-", "") + ("" if rates else "?")
            # side can be an arbitrary-length "worker:<role>" (customAgentType
            # is free text); truncate rather than let an unusually long role
            # name run into the model column with no gap between them.
            side_label = side if len(side) <= widths[0] - 1 else side[: widths[0] - 2] + "…"
            lines.append(fmt_row((
                side_label, label, str(c["in"]), str(c["out"]), str(c["cr"]), str(c["w5"] + c["w1"]),
                fmt_usd(actual), fmt_usd(at_top), fmt_usd(saved),
            )))
            for k in COUNTER_KEYS:
                grand[k] += c[k]
            tot_actual += actual
            tot_at_top += at_top

    lines.append("-" * len(header))
    lines.append(fmt_row((
        "TOTAL", "", str(grand["in"]), str(grand["out"]), str(grand["cr"]), str(grand["w5"] + grand["w1"]),
        fmt_usd(tot_actual), fmt_usd(tot_at_top), fmt_usd(tot_at_top - tot_actual),
    )))
    return "\n".join(lines)


def _render_single(tp):
    """Render one transcript's report — the shared tail end of every
    single-session view (a direct positional path, --session, --this).
    Read-only: a throwaway scan from offset 0, state never written, so it
    can be run any number of times without disturbing the hook's
    incremental counters or lifetime.json."""
    if not os.path.isfile(tp):
        print(f"cost-mirror --report: transcript not found: {tp}", file=sys.stderr)
        return 1
    files_state = {}  # throwaway: full scan from offset 0, state never written
    scan_session(tp, files_state)
    billing_mode, billing_detail = detect_billing_mode()
    pricing = session_epoch_pricing(aggregate_bucket_total(files_state))
    print(render_report(tp, aggregate_total(files_state), billing_mode, billing_detail, pricing))
    return 0


def run_report_session(prefix):
    """--session <prefix> entry point: resolve prefix to exactly one
    transcript (by sessionId or filename-UUID prefix, see
    _find_transcripts_by_session) and render its single-session report.
    Fails loud, listing candidates, on an ambiguous or no-match prefix —
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
    return _render_single(matches[0])


def run_report(argv):
    """--report entry point. NOT fail-silent: prints to stderr and returns a
    nonzero exit code on a missing/unreadable/ambiguous transcript, since
    this is run directly from a terminal rather than from the hook.

    Dispatch, in priority order:
      --session <prefix>  single session resolved by sessionId/filename
                           prefix (run_report_session) — read-only.
      --this               single session: the old bare-default behaviour,
                           the transcript recorded in the newest hook state
                           file (_default_transcript) — read-only.
      <transcript.jsonl>   single session: the given transcript directly —
                           read-only.
      (none of the above)  the aggregate report (run_report_all): every
                           transcript on disk, i.e. what --all did before
                           this became the default. --all remains an
                           accepted no-op alias.

    --since <N>d (e.g. 7d, 30d) narrows the aggregate report (default or
    --all) to transcripts modified in that window; it is a no-op on the
    single-session forms, which have nothing to filter."""
    this_mode = False
    session_prefix = None
    since_days = None
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
        else:
            positional.append(arg)
            i += 1

    if session_prefix is not None:
        return run_report_session(session_prefix)

    if this_mode:
        tp = _default_transcript()
        if not tp:
            print(
                "cost-mirror --report --this: no transcript given and none found under "
                + _state_dir()
                + " or ~/.claude/projects/*/",
                file=sys.stderr,
            )
            return 1
        return _render_single(tp)

    if positional:
        return _render_single(positional[0])

    return run_report_all(since_days)


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
    # Durable lifetime rollup: replace (never increment) this session's
    # rows so the transcript can be deleted later without losing its spend
    # from future aggregate reports. Best-effort in INTENT, but not in
    # effect: this call is NOT wrapped in its own try/except, and it runs
    # before the hook line below is even computed, so a failure here
    # propagates up and is caught only by __main__'s outer fail-silent
    # guard — which means the hook line for THIS prompt is silently
    # skipped too, not just the lifetime write. That is the actual
    # behaviour today (unchanged by this slice) and is judged acceptable
    # because the overall fail-open contract (never crash the prompt, print
    # nothing rather than partial/wrong output) still holds either way.
    _update_lifetime(
        _session_id_for(tp),
        tp,
        os.path.basename(os.path.dirname(tp)),
        os.path.getmtime(tp),
        total,
    )
    token_line = summarise_tokens(total)
    tmp = state_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, state_path)
    if token_line:
        billing_mode, _ = detect_billing_mode()
        bucket_total = aggregate_bucket_total(files_state)
        dollar_clause = summarise_dollars(total, bucket_total, billing_mode)
        line = f"{token_line} | {dollar_clause}" if dollar_clause else token_line
        drift = delegation_drift_segment(event.get("session_id"))
        if drift:
            line = f"{line} | {drift}"
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
