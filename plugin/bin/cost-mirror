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

Overdrive (bead 51c, added 2026-08-23): `tier-set overdrive` lifts the
worker cap and parks .env.TIER_OVERDRIVE="1" in the settings file (tier-set.sh
owns that flag; the path here is TIER_SETTINGS_PATH, overridable via
COST_MIRROR_SETTINGS_PATH for tests, and only the literal "1" counts —
matching tier-gate/tier-reconcile). While it is set, the "saved" clause above
is a lie by construction: workers run the TOP model, so there is no cheaper
tier for "what this would have cost at <top>" to be counterfactual against,
and a session that banked real savings before overdrive was taken would go on
advertising them. The hook line therefore prints a flat "tier savings n/a
(OVERDRIVE)" in place of the whole "· ~$X at <top> → saved ~$Y" clause
whenever the flag is set — unconditionally, since the entire point is that an
expensive binding must never run silently. Flag off (or absent/unreadable
settings), the line is byte-identical to what it printed before. Scope note:
this covers the HOOK line only — `--report`'s at-top/saved COLUMNS still
compute the same counterfactual per row and are untouched here.

Billing mode: this template runs under both a raw API key and a Claude
subscription. Under a subscription the dollar figure isn't a bill, it's
what the session would have cost on the API — same math, different label
("API-equiv"). COST_MIRROR_BILLING=api|sub forces the mode; otherwise it's
auto-detected (see detect_billing_mode): an ANTHROPIC_API_KEY/
ANTHROPIC_AUTH_TOKEN in the environment means "api", else the presence of
claudeAiOauth.subscriptionType in ~/.claude/.credentials.json means "sub",
else it defaults to "api". Billing mode is a render-time label only, never
part of the persisted state.

Pricing snapshot (bead cit, added 2026-08-25): PRICING_TABLE is a hand-kept
guess — in/out only, with all three cache rates DERIVED from the input rate
(x0.1 / x1.25 / x2.0) — and no rendered dollar figure said where its number
came from or how old it was. `cost-mirror.py --refresh-pricing` now fetches
litellm's model_prices_and_context_window.json, which publishes all five
rate classes per model, and writes a snapshot to <state dir>/pricing/
snapshot.json: {schema, fetched_at, source, url, rates:{model:{in,out,cr,w5,
w1}}}, USD/MTok (upstream is per-token; x1e6 on the way in). rates_for()
resolves that snapshot first — longest-prefix, per model, so a model it does
not carry falls through on its own — then the baked table, and returns the
provenance of whichever won ("source", "fetched_at", "pricing_id") alongside
the five rates, so a caller can cite what priced a row instead of asserting
a number. cost() and every other consumer index COUNTER_KEYS and are
unaffected by the extra keys. This is a citation, not a repricing: checked
against the live list on 2026-08-25, every Anthropic ladder entry matches the
derived multipliers exactly, and an install that never fetched (or whose
fetch failed, or whose model is absent upstream) resolves the same figures it
always did, marked "baked". The one place the two can drift is sonnet-5:
_sonnet5_rates() reverts to 3/15 at SONNET5_INTRO_CUTOFF while upstream may
still be quoting the intro 2/10 — snapshot-first is the specified precedence,
so a snapshot that stale wins; the TTL keeps it from being stale for long.
The refresh is built to hang off a session hook: TTL-gated, silent on
success, exit 0 on every failure with the previous snapshot untouched, since
an unreachable network is a normal condition here and the fallback is
precisely what shipped before it existed. The snapshot lives in a
SUBDIRECTORY of the state dir on purpose — per-session state files are found
by globbing "<state dir>/*.json", where a sibling would read as a phantom
session.

Failure posture: fail SILENT AND OPEN — any error prints nothing and exits 0.
Env: COST_MIRROR_DISABLE=1 bypasses (the pricing refresh too);
COST_MIRROR_STATE_DIR overrides the state directory (tests);
COST_MIRROR_CREDENTIALS_PATH overrides the credentials file consulted for
billing-mode auto-detection (tests); COST_MIRROR_SETTINGS_PATH overrides the
settings file the overdrive flag is read from (tests);
COST_MIRROR_PROJECTS_DIR overrides the ~/.claude/projects root that --all
scans (tests); COST_MIRROR_PRICING_PATH, _URL, _TTL (seconds, 0 = always
stale) and _TIMEOUT override the pricing snapshot's file, source, refresh
interval and fetch timeout (tests).

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

Complexity-router lanes (added 2026-08-11): scripts/lane.sh asks the
orchestrator to classify each prompt into an express/standard/deep lane and
appends every declaration to ${LANE_STATE_DIR:-~/.claude/cache/lane}/
log.jsonl ({"lane","prev","why","ts","escalated","session_id"}), with
<session_id>.json holding the live state. This module joins that log on two
surfaces. (1) The hook line gains a trailing " | lane last-turn: <x>"
segment — "last-turn", not "current", because `lane --reset` runs as a
UserPromptSubmit hook BEFORE cost-mirror does, so the state file already
reads "unset" by the time this renders; the log is the only honest source
and what it can report is the lane the PREVIOUS turn took. That is read from
a bounded tail of the log (LANE_TAIL_LINES/LANE_TAIL_BYTES), never the whole
file. (2) `--report` grows a "lanes" section beneath the table: per-lane
declaration counts for the report's session and all-time, plus the
escalation count and rate (escalated==true rows / total rows) that the
knowledge base names as the router's primary health metric, annotated with
its 5–15% target band. Both fail open like everything else here — a missing
or unreadable log omits the lane surface entirely rather than reporting a
zero that would read as "the router ran and never escalated"; a malformed
row is skipped. Neither surface ever creates the lane directory, since a
single-session report must stay read-only with respect to all state. The
report section is additionally wrapped in its own try/except (print_lanes),
because --report is deliberately NOT under __main__'s fail-silent guard.

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
and exits nonzero, since it's invoked directly from a terminal to debug —
as does any unrecognised leading-dash token, which names the valid options
instead of being looked up as a transcript path.

Row export: `--report --csv <path>` writes the LEDGER ROWS behind whichever
view ran to a CSV, alongside (never instead of) the rendered table — see
write_rows_csv. One line per row, header first, the ledger's own columns
verbatim, nothing rounded and nothing truncated: cache-write stays split
w5/w1 where the table collapses it, project names and session ids ship in
full where the table ellipsises them, and every rate and provenance field
travels beside the dollars it produced. That makes each figure in the table
reproducible by arithmetic over the export — Σ cost_total per (side, model)
IS that row's "actual $" cell, Σ cost_at_epoch its "at-top $" — with one
documented exception: an unpriced legacy row (see _migrate_v3_rows) exports
empty cost cells because it never recorded any, while the report prices it
live, so its rendered dollar is the one the CSV alone cannot reconstruct.

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

Durable lifetime rollup — the row ledger: transcripts get deleted
(disk-cleanup, manual pruning), which would otherwise silently erase their
spend from every future aggregate report. Both the hook (for the live
session) and the aggregate report path write this session's rows into
`lifetime.json` in the state dir, keyed `sessionId|side|model|bucket` —
the same time-bucket granularity the scan already accumulates, so a
session's tier epochs outlive its transcript instead of being re-derived
from a file that may be gone. Every row carries the RATES that priced it
(and their provenance) beside its tokens and dollars, frozen the first
time the row is written: report-time code reads those rates rather than
calling rates_for again, so re-running a report after a price change
prices NEW rows only and never re-prices history. Rows are REPLACED per
session every time (never incremented), so rescanning the same transcript
any number of times cannot inflate the durable total; the replacement rows
inherit the dropped rows' frozen rates, so only tokens are ever re-derived.
A v3 file (per-session counters, no buckets, no rates) is migrated in
place to legacy rows marked `pricing_source: unknown` — never back-filled
with rates they were not priced at, and still priced live at report time
exactly as v3 did. The
aggregate report unions live-scanned transcripts with lifetime rows whose
transcript is no longer on disk, so a deleted session's spend still counts
toward the grand total and the per-session table; a footnote names how
many sessions were pulled from history rather than disk. Single-session
views (`--session`/`--this`/a direct positional transcript) never touch
lifetime.json, preserving their read-only-with-respect-to-state guarantee.
"""

import csv
import glob
import hashlib
import json
import os
import sys
import time
from datetime import date, datetime, timezone


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
LIFETIME_VERSION = 4  # bumped from 3 for the ROW LEDGER (bd-8dg): rows are
# now keyed per (session, side, model, BUCKET) and carry the rates that
# priced them, instead of a per-(session, side, model) counter blob priced at
# whatever the table said the day you happened to run the report. A v3 file
# is migrated in place rather than wiped (see _migrate_v3_rows) -- its
# counters are sound, only its provenance is missing, so it survives as a
# legacy row marked pricing_source="unknown" with no rates back-filled onto
# it. The previous bump's reasoning, still true, follows.
# 3 (from 2): bumped alongside STATE_VERSION that time --
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

# scripts/tier-set.sh OWNS this flag: `tier-set overdrive` parks
# .env.TIER_OVERDRIVE="1" in the settings file to lift the worker cap. Read
# here (never imported -- tier-set is a shell script) for the same decoupling
# reason as DELEGATION_GATE_STATE_DIR/LANE_STATE_DIR, and matched against the
# literal "1" exactly as tier-gate/tier-reconcile do. See the module
# docstring's "Overdrive" section. COST_MIRROR_SETTINGS_PATH overrides the
# path (tests).
TIER_SETTINGS_PATH = "~/.claude/settings.json"

# scripts/lane.sh OWNS these; duplicated here (not imported -- lane is a shell
# script) for the same decoupling reason as DELEGATION_GATE_STATE_DIR above.
# See the module docstring's "Complexity-router lanes" section.
LANE_STATE_DIR = "~/.claude/cache/lane"
LANE_NAMES = ("express", "standard", "deep")
# Per-prompt tail: the hook only needs THIS session's newest declaration, so
# it never reads the whole log (bounded at 5000 lines by lane.sh, but still).
# The byte window is read first and the last complete LANE_TAIL_LINES lines
# taken from it -- a log row is ~150 bytes, so 64KiB comfortably covers 200.
LANE_TAIL_LINES = 200
LANE_TAIL_BYTES = 65536
# Escalation-rate tuning band from knowledge-base/TIERED_ORCHESTRATION.md's
# "Complexity Router (lanes)" chapter: 5-15% is healthy, persistently under
# 5% means the classifier routes too heavy, over 20% means express is greedy.
LANE_RATE_TARGET_LOW = 5.0
LANE_RATE_TARGET_HIGH = 15.0
LANE_RATE_GREEDY = 20.0


def _sonnet5_rates(today=None):
    if (today or date.today()) < SONNET5_INTRO_CUTOFF:
        return (2.00, 10.00)
    return (3.00, 15.00)


# Static USD-per-MTok pricing, prefix-matched against message.model in order —
# first match wins, so the specific "claude-sonnet-5" entry must precede the
# generic "claude-sonnet-" fallback. (in, out) pairs, or a zero-arg callable
# for entries whose price varies (e.g. an intro-period discount).
# Opus family pricing varies by version: split into specific entries with
# more specific prefixes before generic fallbacks (bd-1dm).
PRICING_TABLE = (
    ("claude-fable-", (10.00, 50.00)),
    ("claude-mythos-", (10.00, 50.00)),
    # Opus family: split by version to handle different pricing tiers.
    # Only entries that *change* the rate from the 5/25 fallback are needed.
    # More specific prefixes must come before more general ones.
    ("claude-opus-4-1", (15.00, 75.00)),  # Opus 4.1 (note: also matches hypothetical 4-10+, 4-15+, etc.)
    ("claude-opus-4-202", (15.00, 75.00)),  # Opus 4 (date-based models, e.g. claude-opus-4-20250514)
    ("claude-opus-", (5.00, 25.00)),  # Fallback: Opus 5, Opus 4.5, Opus 4.6+ (if it exists)
    ("claude-sonnet-5", _sonnet5_rates),
    ("claude-sonnet-", (3.00, 15.00)),
    ("claude-haiku-", (1.00, 5.00)),
    # Claude 3 family (historical models, pricing from litellm snapshot)
    ("claude-3-opus-", (15.00, 75.00)),  # Claude 3 Opus
    ("claude-3-7-sonnet-", (3.00, 15.00)),  # Claude 3.7 Sonnet
    ("claude-3-5-sonnet-", (3.00, 15.00)),  # Claude 3.5 Sonnet
    ("claude-3-sonnet-", (3.00, 15.00)),  # Claude 3 Sonnet
    ("claude-3-haiku-", (1.00, 5.00)),  # Claude 3 Haiku
)


# Fetched pricing snapshot (bead cit). PRICING_TABLE above is a hand-kept
# guess: it carries in/out only and DERIVES all three cache rates from the
# input rate (x0.1 / x1.25 / x2.0), and nothing in a rendered dollar figure
# says where the number came from or how old it is. The snapshot replaces the
# guess with a citation — litellm's model_prices_and_context_window.json
# publishes all five rate classes per model, first-party Anthropic included —
# without replacing the table: an install that has never fetched, or whose
# fetch failed, or whose model is not in the list, resolves exactly the
# figures it always did (verified against the live list on 2026-08-25: every
# Anthropic entry on the ladder matches the derived multipliers to the cent).
PRICING_SCHEMA = 1
PRICING_SOURCE = "litellm"
PRICING_URL = (
    "https://raw.githubusercontent.com/BerriAI/litellm/main/"
    "model_prices_and_context_window.json"
)
# Upstream publishes USD *per token*; cost() works in USD/MTok, so every rate
# is scaled by 1e6 on the way in. Rounding after that scale is not cosmetic:
# 2e-07 * 1e6 is 0.19999999999999998, one ULP off the 0.2 the baked table
# produces, which would make an otherwise-identical rate compare unequal.
# Ten decimals is far finer than any published rate and kills the noise.
PRICING_PER_MTOK = 1_000_000
PRICING_ROUND = 10
# Provider tag for Anthropic's own API. The same file also carries the model
# under bedrock/vertex tags at different prices; those ride a different
# litellm_provider AND a "/"-qualified key, and both are excluded — this hook
# prices first-party API usage.
PRICING_PROVIDER = "anthropic"
# litellm field -> cost-mirror counter key. An entry missing ANY of these is
# skipped entirely rather than back-filled from the multipliers: cost()
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
PRICING_MAX_AGE_SECONDS = 72 * 3600  # 72 hours: read-side max-age independent of fetch TTL.
# Past this age, a snapshot entry loses to the baked table per model (bead beads_claude_docker-zrx exposure a).


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
    "claude-opus-4-6-20260205" or "claude-fable-5[1m]". Longest wins so a
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
    """USD/MTok rates for a model id: {in, out, cr, w5, w1}, or None if the
    model matches neither the fetched snapshot nor any baked pricing prefix
    (off-ladder/unknown).

    The dict also carries the PROVENANCE of those five figures — "source"
    ("litellm" for a fetched snapshot, "baked" for PRICING_TABLE),
    "fetched_at" (the snapshot's ISO-8601 stamp, None for the table), and
    "pricing_id" ("<source>:<matched key or prefix>") — so a caller can cite
    what priced a row rather than asserting a number. cost() and every other
    consumer index COUNTER_KEYS and are untouched by the extra keys.

    Resolution is snapshot-first, PER MODEL: a model the snapshot does not
    carry falls through to the table on its own, rather than the snapshot
    being all-or-nothing. HOWEVER:

    Exposure (a) STALE SNAPSHOT: A snapshot older than PRICING_MAX_AGE_SECONDS
    loses to the baked table, independent of fetch TTL (bead beads_claude_docker-zrx).

    Exposure (b) UPSTREAM DISAGREEMENT: When a callable PRICING_TABLE entry
    (e.g., _sonnet5_rates with date-aware knowledge) disagrees with the snapshot,
    the date-aware local value wins (bead beads_claude_docker-zrx)."""
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

    Keeps first-party Anthropic entries with a complete set of five rates and
    a flat (unqualified) key; drops everything else — other providers, the
    "bedrock/..."-style resale variants of the same models at different
    prices, litellm's own "sample_spec" schema placeholder, and entries that
    publish in/out but no cache rates."""
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

    Built to be hung off a session hook, so it obeys the same posture as the
    rest of this script and then some — TTL-gated (a snapshot fetched inside
    PRICING_TTL_SECONDS is left alone, so it costs one stat on a warm start),
    silent on success, and exit 0 on EVERY failure with the previous snapshot
    left byte-identical. An unreachable network is a normal condition here:
    the fallback for "no fetch ever succeeded" is the baked table, which is
    exactly what shipped before this existed. Always returns 0."""
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
        # urlopen's timeout is per socket OPERATION, not total: a peer that
        # trickles a byte inside every window keeps it alive indefinitely.
        # This is meant to run from a session hook, so the wall has to be on
        # total ELAPSED time — hence a deadline checked around a chunked read,
        # which also caps the payload without buffering an unbounded one.
        # read1, not read: read() blocks until it has the full count, so the
        # deadline below would only be consulted between whole chunks and a
        # trickling peer would never reach it (measured: a 1-byte/s server
        # held a read(256k) open for a minute against a 3s timeout). read1
        # returns whatever has arrived, so the wall is checked per arrival.
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


def overdrive_active():
    """True when the settings file carries tier-set's sticky worker-cap lift
    (.env.TIER_OVERDRIVE == "1", see TIER_SETTINGS_PATH). Under overdrive the
    worker IS the top model, so the "saved" counterfactual below is no longer
    true -- see summarise_dollars and the module docstring's "Overdrive"
    section. Only the literal "1" counts (tier-gate/tier-reconcile read it the
    same way); any missing/unreadable/malformed settings file is False, i.e.
    exactly today's behaviour, never a crash."""
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


# ── The row ledger (bd-8dg) ────────────────────────────────────────────────
# lifetime.json is a ledger of IMMUTABLE ROWS -- one per (session, side,
# model, bucket), the same granularity scan_file already accumulates in
# `bagg` -- and every row carries the RATES that priced it, not just its
# token counts. Two defects that fixes:
#   * v3 persisted "<session>|<side>|<model>", collapsing the bucket
#     dimension, so this session's tier epochs survived only as long as its
#     transcript did (they were re-derived from the file on every scan, and
#     a deleted transcript's spend lost its epoch structure entirely).
#   * rates were applied at REPORT time, so re-running the report after a
#     price change silently re-priced history. Not theoretical: _sonnet5_rates
#     flips at SONNET5_INTRO_CUTOFF, so the same unchanged transcripts
#     reported either side of that date disagreed on what the past cost.
# A row's rates are frozen the first time the row is written and carried
# forward verbatim by every later rescan (see build_session_rows); rates_for()
# prices NEW rows only. Note what is NOT here: no hook-time configuration
# capture and no fingerprint scheme. A tier epoch already IS "the
# configuration changed", derived from the transcript itself
# (_epochs_from_main_buckets), and a bucket is already the row boundary.


def _row_key(session_id, side, model, bucket):
    """Ledger key for one row -- the same "|"-joined composite-string scheme
    the in-memory aggregates use, with the session id in front and the bucket
    at the back. Every field is ALSO stored on the row itself, so no reader
    has to parse this back out: a "worker:<role>" side (customAgentType is
    free text) and a dated model id both make string surgery on the key
    fragile. A migrated v3 legacy row deliberately keeps its old three-part
    key, having no bucket to name (see _migrate_v3_rows)."""
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
    those two multiply out to, and the same for its tier-epoch counterfactual.

    Every dollar on the row is that row's own tokens at that row's own rate
    (cost_X == tokens_X * rate_X / 1e6, cost_total their sum), so a reader
    never has to know today's price list to know what this row cost.
    Unpriced (rates None -- an off-ladder model, or a legacy row) leaves
    every rate and cost null rather than writing a 0.0 that would read as
    "this genuinely cost nothing"; _row_pricing prices such a row live at
    report time, exactly as every version before this one did."""
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

    `prior` is the ledger rows already on file: a row whose key is already
    there keeps the rates it was FIRST written with, so a rescan re-derives
    its tokens from the transcript but never re-prices them. Only a key the
    ledger has never held -- a new session, or a new time bucket in a session
    still being written -- is priced at today's rates_for(). That is what
    makes REPLACE-per-session write semantics compatible with immutable rows.

    Tokens come from `bucket_total`, i.e. from scan_file's already-de-duped
    counters -- never re-derived from transcript rows here, which is what
    keeps one API response's several content-block rows (sharing a message.id,
    repeating in/cache-r/cache-w verbatim with a CUMULATIVE output_tokens)
    counted once rather than ~2.17x over.

    A MAIN row's counterfactual is itself, unconditionally, mirroring
    session_epoch_pricing: a bucket that mixed two main-loop models resolves
    to one representative model, and the loser's rows must net to zero rather
    than silently reprice at the winner. So a main row names its OWN model as
    epoch_model -- the model that actually priced its counterfactual --
    rather than the bucket's representative. A worker row outside every epoch
    (a session with no main rows at all) keeps epoch_model None and prices
    its counterfactual at its own rates, i.e. claims no savings."""
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
    docstring's NA-timestamp note.

    bd-8dg: the arithmetic runs through the row ledger now. `rows` are this
    session's ledger rows when the caller has them (each already priced at
    the rates it was written with, so a report never re-prices history);
    without them — every read-only single-session view — throwaway rows are
    built from bucket_total at today's rates, which is what this did before."""
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
    invariant explicit rather than relying on it silently.

    `rows` (bd-8dg) is this session's ledger rows when the caller has them —
    passed straight through to session_epoch_pricing, so the savings figure
    and the persisted ledger can never drift apart."""
    pricing = session_epoch_pricing(bucket_total, rows)
    return sum(d["at_epoch"] - d["actual"] for key, d in pricing.items() if not key.startswith("main|"))


def summarise_dollars(total, bucket_total, billing_mode="api", overdrive=False, rows=None):
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
    cost on the API, so it is labelled "API-equiv".

    overdrive=True (see overdrive_active) replaces the whole counterfactual
    clause with a flat "tier savings n/a (OVERDRIVE)" marker: the worker cap
    is lifted, so workers run the top model and there is no cheaper tier for
    the figure to be counterfactual against. It is printed UNCONDITIONALLY
    whenever there is a dollar clause at all -- not gated on the savings
    rounding to nonzero -- because the point is that an expensive binding
    must never be silently on; a session that accrued real savings BEFORE
    overdrive was taken would otherwise keep advertising them as if
    delegation were still buying something.

    `rows` (bd-8dg) is this session's ledger rows when the caller has them.
    The leading figure is then the sum of what those rows RECORD having
    cost, not a fresh repricing of their tokens — so the hook line agrees
    with the ledger (and with the report) even across a price change."""
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


def _lane_log_path():
    """scripts/lane.sh's append-only declaration log. LANE_STATE_DIR is
    lane's own env override (same variable name, same default), so pointing
    one at a scratch dir points both."""
    base = os.environ.get("LANE_STATE_DIR") or os.path.expanduser(LANE_STATE_DIR)
    return os.path.join(base, "log.jsonl")


def _lane_log_rows(tail_lines=None):
    """Parsed rows from lane's log.jsonl -- {"lane","prev","why","ts",
    "escalated","session_id"} each -- or None when the log cannot be read at
    all (missing file, unreadable dir), which every caller treats as "omit
    the lane surface entirely" rather than as an empty log.

    tail_lines caps the result to the newest N rows and, above
    LANE_TAIL_BYTES, seeks instead of reading the file whole (the first,
    possibly partial, line of that window is dropped) -- the per-prompt hook
    path only ever needs the newest declaration. Passing None reads
    everything, for the report's all-time counts. Unparseable lines are
    skipped, never fatal: lane.sh builds its rows with printf, so a
    half-written tail row is a normal thing to find here."""
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
    when there is no log to read / no session id.

    "last-turn", not "current", on purpose: `lane --reset` runs as a
    UserPromptSubmit hook BEFORE this one (see config/claude-settings.json),
    so by the time cost-mirror renders, the session's state file already says
    "unset" for the prompt now starting. The log is therefore the only honest
    source, and what it can report is the lane the PREVIOUS turn was routed
    into -- which the label says out loud rather than passing off as the lane
    in force right now.

    A readable log with no row for this session yields "unset" (the session
    has never declared); an unreadable/missing one yields "" (no lane
    machinery here to report on)."""
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

    For a single-session view the transcript answers it directly: lane rows
    carry the UserPromptSubmit payload's session_id, which is the same id
    _session_id_for reads off the transcript. The aggregate report has no one
    transcript, so it resolves the CALLER's session the way lane.sh's own
    resolve_sid does -- CLAUDE_CODE_SESSION_ID, else the last-session file
    lane --reset writes -- so `tier-cost` run from a live session still shows
    that session's own lane counts."""
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
    session_id and all-time, plus the escalation count and rate that the
    knowledge base names as the router's primary health metric.

    Returns "" when there is no log or the log holds no parseable rows --
    there is then nothing to say, and a report on a machine that never ran
    the router should not grow an empty table. Read-only: it never creates
    the lane dir, since a single-session report must touch no state at all.

    Wrapped by its own try/except at the call sites' expense rather than
    theirs: --report is deliberately NOT under __main__'s fail-silent guard
    (it must exit nonzero on a real error), so a malformed log must not be
    allowed to turn `tier-cost` into a traceback."""
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


def _migrate_v3_rows(rows):
    """v3 rows ("<session>|<side>|<model>" -> {in,out,cr,w5,w1,...}) as v4
    LEGACY ledger rows: one per (session, side, model), carrying no bucket
    and no rates, under their original three-part key.

    A v3 row records what was spent but not what it was priced at, so its
    rates stay null and pricing_source reads "unknown". Back-filling today's
    rates onto old tokens would fabricate exactly the provenance this ledger
    exists to keep honest, and reinterpreting the row as bucket-level would
    invent a time bucket it never carried. Such a row is still priced live at
    report time (see _row_pricing) — i.e. exactly the v3 behaviour it came
    from, no better and no worse."""
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
    # LIFETIME_VERSION, deliberately NOT the scan-state STATE_VERSION —
    # this schema didn't change when STATE_VERSION was bumped for tier-epoch
    # bucketing, so tying the two together would wipe durable history on
    # every unrelated scan-state schema bump for no reason.
    #
    # v3 is MIGRATED rather than wiped (bd-8dg): its counters are sound (the
    # de-dup fix that poisoned v2 landed in v3), only its per-bucket
    # granularity and its provenance are missing, and neither can be
    # recovered by throwing the rows away. Any other old version still starts
    # clean — a v2 row's counters are actually wrong.
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
    """Durably record this session's ledger rows — one per (side, model,
    bucket), each carrying the rates that priced it (see build_session_rows)
    — and return them, so the caller prices the report off exactly the rows
    that were persisted rather than re-deriving them.

    REPLACE, never increment: every existing row for this session_id is
    dropped first, then the freshly scanned rows are written in whole — so
    calling this any number of times on the same (fully rescanned) session is
    idempotent, and a session can never be double-counted by being written
    twice. That stays compatible with immutable rows because the replacement
    rows are rebuilt from the transcript and inherit the rates the dropped
    rows froze; only tokens can change, never history's prices. This is
    deliberately called from both the hook path (main(), for the live
    session) and the aggregate report path (run_report_all) — never from a
    single-session view, which must stay read-only with respect to state."""
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
    code — 0 on success, 1 on a missing/unreadable/malformed receipt, with
    nothing written to the ledger in that case — since this is a direct CLI
    entry point (delegate.sh already wraps its own call in `|| true`), not
    the hook's fail-silent path.

    Row key: _row_key(job, "delegate", model, bucket), reusing the existing
    "sessionId|side|model|bucket" scheme as-is. session_id is the job id
    itself: a delegate job has no transcript and so no real session id, but
    a job id (route-epoch-hex, see cmd_run) is already a unique per-run
    string, so using it verbatim both satisfies the row key AND makes a
    re-ingest of the SAME job's receipt land on the SAME key — REPLACE
    (see _update_lifetime's docstring), i.e. idempotent — while a
    DIFFERENT job (a different session id) always lands on its own row.
    bucket is the epoch component parsed back out of that same job id
    (mirroring cmd_ps's own `awk -F- '{print $(NF-1)}'`), falling back to 0
    for a job id that doesn't match the "<route>-<epoch>-<hex>" shape.

    Dollars are the receipt's own "usd" field verbatim — a real bill from
    an external provider — never a token count re-priced against this
    file's own PRICING_TABLE: cost_total is set directly and every rate_*
    left None, which is exactly how _row_pricing already treats a row that
    carries a frozen cost_total (see _ledger_row's docstring: unpriced
    rates fall back to live repricing ONLY when cost_total is also absent).
    Tokens still ride along for the record, but they never drive the
    dollar figure. A null "usd" (the event stream carried no cost, see
    delegate.sh) still writes a row — at $0.00 — rather than dropping it:
    the job happened and its tokens, if any, are still worth keeping."""
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
    """"delegated: <model> $X.XX (N job(s)) · ... · total $Z.ZZ" — one entry
    per model ingested via --ingest-delegate-receipt, dollars-descending
    then model name (mirroring render_report's own per-row ordering, see
    its bd-cro note). "" when there are no delegate rows at all, so a
    caller can skip printing anything (see print_delegate_segment).

    Deliberately its OWN segment, never folded into render_report's
    side|model table (see _lifetime_sessions_by_id's exclusion): a delegate
    job's dollars are a real external bill, not tokens this file priced
    itself, so blending it into the "native sides" table would misreport
    it as directly comparable to a main/worker row's actual/at-top/saved
    columns — there is no at-top/saved counterfactual for money already
    spent outside this session entirely."""
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
    "tp"} — the shape run_report_all's durability union needs to add missing
    (deleted-from-disk) sessions back into the report.

    "rows" is what prices the session (each row at its own frozen rates, see
    _row_pricing); "totals" is the token-only rollup the grand total needs,
    summed ACROSS a session's buckets since a side|model is several rows
    now rather than one.

    Delegate rows (side == "delegate", see _ingest_delegate_receipt) are
    skipped here: a delegate job has no transcript and is not a "session"
    the durability union should fold into run_report_all's per-session
    table or "no longer on disk" footnote. They are rendered separately —
    see render_delegate_segment."""
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
# The ledger row's own fields, in a fixed order, one CSV column each. Only
# "session_id" is renamed (the row calls it "sessionId"); everything else is
# the ledger key verbatim, so a column heading is directly greppable in this
# file. Deliberately WIDER than the rendered table in two ways: cache-write
# stays split into w5/w1 (render_report collapses them into one column) and
# every rate/provenance field ships, because the point of the export is that
# a reader can recompute each dollar without knowing today's price list.


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
    """Write `rows` (ledger rows — see _ledger_row) to `path` as CSV, one line
    per row plus a header. Returns 0, or 1 after a clear stderr message if the
    path can't be written.

    Values go out exactly as the ledger holds them: csv renders a float via
    str(), i.e. the shortest representation that round-trips, so nothing is
    rounded or reformatted on the way out, and a None (an unpriced legacy
    row's rates and costs, see _migrate_v3_rows) becomes an EMPTY cell rather
    than a 0.0 that would read as "this genuinely cost nothing". An empty
    cost cell is audit output in its own right: that row's price is unknown,
    and back-filling one would fabricate the provenance this ledger exists to
    keep honest. Such a row is still priced live in the REPORT (_row_pricing),
    so its rendered dollar is the one figure in the table that the CSV alone
    cannot reproduce — by construction, not by omission.

    CSV formula injection (bead beads_claude_docker-uvf): identifier columns
    that begin with '-', '=', '+' or '@' are prefixed with a single quote to
    prevent Excel/Sheets formula interpretation. Numeric columns (tokens_*,
    rate_*, cost_*) are never modified to remain machine-parseable.

    lineterminator="\\n": the csv default is CRLF, and every consumer of this
    file (a spreadsheet, a shell pipeline, python) reads LF fine, while a
    stray CR would silently corrupt the last field of every line for the
    shell ones."""
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

        # Add epoch-span marker for multi-epoch sessions
        session_label = row["session"]
        epoch_models = row.get("epoch_models", set())
        if len(epoch_models) > 1:
            # Append marker directly without padding before it to preserve full ID
            # and avoid creating extra whitespace fields that would confuse parsers.
            # fmt_row will pad the result to the column width.
            marker = "†"
            session_width = 10  # Column width for session field
            if len(session_label) + len(marker) <= session_width:
                session_label = session_label + marker
            else:
                # Truncate to make room for marker
                session_label = session_label[:session_width - len(marker)] + marker

        lines.append(fmt_row((
            project, session_label, modified, fmt(row["tokens"]), fmt_usd(row["actual"]),
        )))
    return "\n".join(lines)


def run_report_all(since_days, csv_path=None):
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
    purely a fallback for what's gone.

    csv_path (bd-fbi): also write every ledger row this report priced to that
    path (see write_rows_csv). The rows collected here are the SAME objects
    the dollars below are summed from — both the live-scanned sessions' and
    the durability union's — so the export can't drift from the table it sits
    beneath. The CSV's scope is the report's scope: a session --since
    excluded is absent from both."""
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
        # Epochs computed and priced PER SESSION, then folded into the
        # aggregate breakdown via _add_pricing — never by handing
        # render_report a bucket_total merged across sessions, which would
        # let session A's tier reprice session B's spend. The rows the
        # ledger just persisted ARE the pricing (bd-8dg): every dollar below
        # is what a row records having cost, so a price change from here on
        # prices new rows only and leaves this history where it stands.
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
        scope = f" modified in the last {since_days}d" if since_days is not None else ""
        # an asked-for CSV is still written (header only) before failing: a
        # requested artifact that simply isn't there is worse than an empty one
        if csv_path:
            write_rows_csv([], csv_path)
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
    is_overdrive = overdrive_active()
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
    # token columns at 11 (not 9) so a --all grand total (routinely 9-digit
    # cache-r/cache-w counts) never runs two numbers together with no gap.
    # side widened from 7 to 18: "worker:<role>" rows (see _agent_label) run
    # longer than bare "main"/"worker" -- e.g. "worker:verifier" is 16 chars.
    widths = (18, 28, 11, 11, 11, 11, 10, 10, 10)
    if is_overdrive:
        # bead gu4 reopen: "n/a (OVERDRIVE)" (15 chars) and the header's
        # "at-top $ (n/a)" / "saved $ (n/a)" (14/13 chars) all overran the
        # plain 10-char money column. rjust() never truncates an oversized
        # value, so the text ran straight into its neighbour with no gap
        # at all -- "$230n/a (OVERDRIVE)n/a (OVERDRIVE)". Widen just these
        # two columns so every overdrive header/data/TOTAL cell fits with
        # room to spare; header, rows, TOTAL and the separator all derive
        # their length from this same `widths` tuple, so widening it here
        # keeps all of them mutually aligned. The non-overdrive branch
        # never reaches this line, so flag-off output is untouched.
        widths = widths[:7] + (17, 17)

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
        # bd-8dg: the row's dollars come from the LEDGER when the caller
        # priced it there — each ledger row at the rates that row was
        # written with, so a re-run after a price change reports the same
        # history rather than silently re-pricing it. A row the caller did
        # not price (`pricing` empty, or a side|model absent from it) still
        # falls back to a live cost(), which is what this always did. The
        # sort key and the "actual $" column read the SAME figure, so the
        # cost-descending order below stays the order of the printed column.
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

            # Epoch-span note (bd-q6c, corrective slice 3): a side|model row
            # can group ledger rows priced at more than one epoch_model (a
            # worker whose buckets straddle a /tier change reprices against
            # a different orchestrator epoch per bucket -- see
            # build_session_rows). This row's own 9 fields cannot carry the
            # marker: reconcile_csv (tests/tier-hooks.bats) keys off exactly
            # (side, model) and value-matches actual $/at-top $ character for
            # character, and the mid-session-/tier-change test reads saved $
            # off a fixed field index -- so gluing a marker onto ANY of the
            # 9 fields either breaks that matching or (for the token columns)
            # makes a token count non-numeric. Tried both; both regressed.
            # Instead the marker lives on its own annotation line directly
            # below the row, prefixed with the same side text so it is still
            # visible to a reader (and to a `grep '^side'` capture) but
            # invisible to anything that parses the table as fields:
            # reconcile_csv's data-row heuristic (exactly 9 whitespace
            # fields, field 6 starting with "$") never matches this line's
            # word count, and `read -a` against a multi-line grep capture
            # only ever consumes the FIRST line -- the untouched data row.
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
    """Render one transcript's report — the shared tail end of every
    single-session view (a direct positional path, --session, --this).
    Read-only: a throwaway scan from offset 0, state never written, so it
    can be run any number of times without disturbing the hook's
    incremental counters or lifetime.json.

    csv_path (bd-fbi) exports THIS session's ledger rows, the same rows the
    table below is priced from. Read-only still holds: the rows are built in
    memory and never persisted."""
    if not os.path.isfile(tp):
        print(f"cost-mirror --report: transcript not found: {tp}", file=sys.stderr)
        return 1
    files_state = {}  # throwaway: full scan from offset 0, state never written
    scan_session(tp, files_state)
    billing_mode, billing_detail = detect_billing_mode()
    # READ the ledger (never write it, see the docstring above): a row this
    # session already has on file keeps the rates it was priced at, so a
    # single-session view can't disagree with the aggregate report about what
    # the past cost. A session with no rows yet is priced live, as before.
    # The real mtime (rather than the 0 placeholder this passed before these
    # rows had anywhere to go) so a --csv export carries an honest timestamp;
    # nothing prices off mtime, so no dollar in the table above can move.
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
    return _render_single(matches[0], csv_path)


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
    single-session forms, which have nothing to filter.

    --csv <path> additionally exports the ledger rows behind whichever of
    those views ran, to that path (see write_rows_csv). It composes with all
    of them rather than replacing any: the table still prints to stdout, and
    the rows written are exactly the ones that table's dollars were summed
    from. It takes a value like --since/--session do, and says so when the
    value is missing.

    Any OTHER leading-dash token is a hard error naming the valid options.
    This used to fall through to positional[] and be looked up as a file, so
    `--report --help` reported "transcript not found: --help" — a failure
    message that named neither the real problem nor the way out."""
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
                + " or ~/.claude/projects/*/",
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
