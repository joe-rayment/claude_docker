# Tiered Orchestration & Trust-but-Verify

**When to use:** you want a session to decompose a task across model tiers
(strong model plans + synthesizes, cheaper models do the volume) and have
worker output *independently verified* before it counts as done — and you
want to pick which concrete model backs each tier per session with one
command (`/tier`), never by hand-editing anything.

The design is **role-based, never model-based**: agents name roles; the
model behind each role is bound by the tier scripts. Nothing breaks when
models rotate.

**Mechanism version: v2 (2026-07-17) — per-agent frontmatter binding.**
The v1 env-slot remap (`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` +
`_NAME`) is **retired and actively purged**; see the post-mortem below for
why it must never come back.

## Fast diagnosis (start here when model selection looks wrong)

| Symptom | Cause → fix |
|---------|-------------|
| `/model` picker shows odd rows, or picking a row lands on a different model | Legacy `ANTHROPIC_DEFAULT_*` vars survived in settings `env` (v1 residue). `tier-set show` warns if present; any `/tier` bind — or the reconciler on the next prompt — purges them. Never re-add them. |
| Executor/scout ran the wrong model | (1) Check the binding: `grep '^model:' ~/.claude/agents/{executor,scout}.md`. (2) Remember **agent files are snapshotted at session start** — a mid-session rebind affects the *next* session, not this one. (3) Check for an active pin (`tier-set show`). (4) An off-ladder `.model` stops auto-derivation (never clobbers). |
| All subagents run the same model | `CLAUDE_CODE_SUBAGENT_MODEL` is set somewhere — it overrides *every* subagent. tier-set/tier-reconcile purge it from settings `env`; also check shell exports. |
| Agent spawn fails model-not-found | The frontmatter id is gated/retired on this account. Re-run `/tier` with `TIER_PROBE=1 tier-set …` (or name an available model explicitly) — the probe degrades downward and binds what actually works. |
| Need a different tier for ONE spawn right now | Pass an explicit `model` on that Agent call — the only per-spawn override in a running session. |
| `/tier` ran but this session's own model didn't change | Expected: a file write cannot move a running orchestrator. Run the `/model …` line tier-set prints. |
| After an image rebuild the trio looks like the template defaults | Expected: rebuild resets agent files + settings from templates; the SessionStart reconciler re-derives from `.model` on the first session — no manual re-run needed. |

The SessionStart status echo prints the live binding every session
(`tier → orchestrator(settings model)=… executor=… scout=… | verifier+oracle inherit …`)
— read it before debugging anything else.

## The roles (three tiers, ≤3 levels deep)

| Role | Agent file | Model binding (v2) | Delegates to | Job |
|------|-----------|------|--------------|-----|
| **orchestrator** | (the main session — no agent file) | settings `.model` (written by `/tier`; moved live only by `/model`) | executor, verifier, scout | decompose, delegate, synthesize, decide |
| **executor** | `config/agents/executor.md` | frontmatter `model:` = **concrete id** (worker rung, written by tier-set/tier-reconcile) | `scout` only | one implementation slice, end to end |
| **scout** (leaf) | `config/agents/scout.md` | frontmatter `model:` = **concrete id** (recon rung, written by tier-set/tier-reconcile) | — | fan-out recon: find/usages/summaries |
| **verifier** (leaf) | `config/agents/verifier.md` | `model: inherit` (= orchestrator) | — | independent check of one worker claim |
| **oracle** | `config/agents/oracle.md` | `model: inherit` (= orchestrator) | — | user-invoked checkpoint consult |

**Invariant: the orchestrator is the most capable model of the three, and
the expensive tiers (opus/fable) never take the worker seat** — enforced on
the **derived (1-arg) path**, where the worker is one rung down capped at
sonnet-class and recon is one rung below the worker. An explicit 2/3-arg pin accepts **any**
combination by design, including inverted ones (user decision, bead uhs) —
that is the operator's call, not blocked. The checkers (verifier, oracle)
use `model: inherit`, so they always run exactly the orchestrator's model —
never a tier below the claims they check.

The tree tops out at **orchestrator → executor → scout**. What's structural
and what's convention:

- **scout** and **verifier** have no `Agent` tool in their frontmatter →
  they physically cannot spawn children (structural; they are leaves).
- **executor**'s grant is written `Agent(scout)`, but Claude Code honors the
  parenthesized type restriction only for **main-thread** agents — for
  subagent-spawned agents it grants an unrestricted Agent tool. The
  scout-only limit is therefore a **prompt contract** in executor.md, backed
  by Claude Code's hard depth-5 ceiling, not a harness guarantee.
  (Confirmed empirically 2026-07-10: a live executor's Agent schema had no
  type restriction and the full agent catalog was visible to it — yet when
  probed, the executor *declined* the off-contract spawn. The contract
  holds in practice; just don't call it structural.)

Confirm nesting actually happened via the **subagent panel** below the
prompt input: each row shows a `(+N)` descendant count. A flat call means
the "delegation" collapsed to a single agent.

## Delegation-down vs. escalation

- **Delegation-down (default).** Orchestrator decomposes, hands executors
  independent slices, synthesizes their compressed returns. Default depth
  **2** (orchestrator + executor); add the 3rd level only when volume or an
  independent check earns it. Ceiling is **3**.
- **Upward escalation (for debugging / uncertain work).** Leaf attempts the
  task, calls a stronger tier only when stuck — you pay the higher tier
  only on real failures. Use when you can't cleanly decompose up front.
- **Shallow beats deep.** Before delegating, expect the child to do real
  work and return a *compressed* result. If you could produce it in a
  couple of tool calls, don't delegate.

## The v2 binding mechanism — where each tier lives

```
top    -> settings .model                         (plain-launch orchestrator default)
worker -> ~/.claude/agents/executor.md  `model:`  (CONCRETE id in frontmatter)
recon  -> ~/.claude/agents/scout.md     `model:`  (CONCRETE id in frontmatter)
verifier / oracle -> `model: inherit`             (track the orchestrator; unchanged)
```

No tier code writes any `ANTHROPIC_DEFAULT_*` var, ever. The `/model`
picker is **fully native and honest**: a bare alias (`opus`, `sonnet`,
`haiku`, optionally with a `[1m]` suffix) always means its native family,
because nothing remaps it. The tier binding lives where only subagent
definitions read it — the frontmatter — so the picker and the tiers can no
longer interfere.

**Purge policy (both tier-set and tier-reconcile).** The six
`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL(_NAME)` vars and
`CLAUDE_CODE_SUBAGENT_MODEL` are standing footguns — the first six corrupt
the picker, the last collapses every subagent onto one model. Both scripts
actively **delete them from settings `env` wherever found**: tier-set on
every bind, tier-reconcile as its first step on every run — even when a
pin, an empty `.model`, or an off-ladder `.model` skips derivation.
`tier-set show` warns if any are present. Don't hand-restore them for any
reason.

### Empirically verified facts (2026-07-17, this container, Claude Code 2.1.x)

1. **Frontmatter accepts a full concrete model id** (e.g.
   `model: claude-opus-4-8`) and it is honored end-to-end — verified by
   reading `message.model` in the spawned agent's transcript jsonl.
2. **Agent definitions are SNAPSHOTTED at session start.** A mid-session
   frontmatter edit does NOT change spawns in the running session; a fresh
   session honors it — verified by editing scout.md mid-session vs in a
   fresh session and reading `message.model` in the spawned agents'
   transcript jsonl files. (This replaces the v1-era observation that
   settings `env` was re-read per spawn — true for env vars, irrelevant
   now; frontmatter is snapshot-per-session.)
3. The `/model` picker's custom-slot rows persist **bare aliases** into
   `.model`; native rows persist concrete ids (possibly with `[1m]`). With
   v2 there are no custom rows anymore, so whatever it persists means what
   it says.
4. `tier-derive` strips a trailing `[...]` **for ranking only**
   (`claude-fable-5[1m]` and `opus[1m]` rank by family; the exact original
   value is preserved in the top slot). Safe because aliases are native
   again.

### Liveness — when a binding takes effect

- **Worker/recon bindings apply to NEW sessions** (fact 2 above). The
  **SessionStart tier-reconcile hook** is what guarantees every session's
  executor/scout are consistent with `.model` from that session's *first*
  spawn — the files are synced before anything spawns.
- The **UserPromptSubmit** run of the same hook keeps the files (and the
  purge) current on disk mid-session after a `/model` change, but because
  of the snapshot its effect on spawns lands in the next session.
- **The running orchestrator** (settings `.model` is only its default) and
  the `model: inherit` agents (verifier/oracle) that track it move **only
  via `/model`** — a file write cannot move a running session's own model.
  `/model` also persists as the new-session default, which the reconciler
  then derives from: `/model` is the primary in-session lever.
- **One-off override, current session:** pass an explicit `model` on the
  Agent call for that single spawn.

## Setting the tier — one top model, the rest derived

```
/model opus                         # PRIMARY in-session lever: moves the orchestrator now AND
                                     #   (via the reconciler) re-derives worker/recon for new sessions
/tier fable                         # explicit set: .model=claude-fable-5 + frontmatter sonnet/haiku
/tier claude-opus-4-8               # a full id works (dated/variant kept as-is on top)
/tier opus sonnet                   # 2-arg explicit PIN: recon shares the worker model
/tier opus sonnet haiku             # 3-arg explicit PIN: fully independent, any combo
/tier                               # no args: print the current binding (writes nothing)
/tier show                          # same as bare /tier
```

A 2- or 3-arg `/tier` is an **explicit pin**, not a shorthand for the
derived trio: it sets `.env.TIER_EXPLICIT_PIN="1"`, and `tier-reconcile`
treats that as a standing opt-out — it will not rewrite the pinned
worker/recon bindings even as `.model` drifts underneath them (e.g. via
`/model`). It still purges legacy vars while pinned. A plain 1-arg
`/tier <top>` clears the pin and resumes auto-derivation. `tier-set show`
reports whether a pin is active.

Derivation table (`tier-derive`, the single source of truth for the ladder
`fable > opus > sonnet > haiku`; the worker is one rung down **capped at
sonnet-class** — opus/fable never take the worker seat, the orchestrator
plans/delegates/reviews — and recon is one rung below the worker, floored
at haiku):

| top | worker (executor) | recon (scout) |
|-----|-------------------|---------------|
| fable  | sonnet | haiku  |
| opus   | sonnet | haiku  |
| sonnet | haiku  | haiku  |
| haiku  | haiku  | haiku  |

Alias map: `fable→claude-fable-5`, `opus→claude-opus-5`,
`sonnet→claude-sonnet-5`, `haiku→claude-haiku-4-5-20251001`. Aliases are
resolved to **concrete ids before writing**, so a binding never drifts with
alias defaults. A full family id (incl. dated/variant) maps to its rung and
keeps its exact value on top; anything else is off-ladder.

**Off-ladder tops.** `tier-derive` prints nothing and exits 3 for a top it
can't place (`best`, a custom id). The two callers react differently, both
deliberately: `tier-reconcile` **leaves the agent files untouched** (never
clobber); a 1-arg `tier-set <custom-id>` can't derive, so it **binds all
three slots to that same model** and says so — you asked for that top,
you get it everywhere. `tier-set show` flags an off-ladder top as
custom/unmanaged.

### Spawn-time enforcement (added 2026-07-28)

Frontmatter bindings alone did not move spend: generic (`general-purpose`)
and workflow-internal spawns carry no binding, inherit the orchestrator's
model, and accounted for the bulk of measured top-tier tokens (beads c2r,
mi9). Three hooks close that gap — all fail OPEN, all tested in
`tests/tier-hooks.bats`:

- **`tier-gate`** (PreToolUse, matcher `Agent`) — a generic spawn with no
  `model` gets the ladder's WORKER tier injected via `updatedInput`, with a
  `systemMessage` announcing it. Explicit `model` always wins, on any type;
  named roles and `model: inherit` checkers are never touched. The tier is
  read from `tier-derive` at runtime and injected as the FAMILY ALIAS —
  the Agent tool's `model` param rejects concrete ids (verified live:
  `claude-sonnet-5` failed validation, `sonnet` routed correctly).
- **`workflow-lint`** (PreToolUse, matcher `Workflow`) — denies a workflow
  script whose `agent()` calls omit `model:` (best-effort line scan, 5-line
  lookahead; `/* workflow-lint: model-ok */` suppresses). Enforcement sits
  at the script boundary because workflow-internal spawns are not reliably
  hook-reachable.
- **`cost-mirror`** (UserPromptSubmit, python3) — injects one line of
  by-model main-vs-workers token spend per prompt, computed incrementally
  from the transcript (byte-offset state under `~/.claude/cache/cost-mirror/`,
  ~10 ms warm). Visibility, not constraint.

The operational dispatch rules (which role gets what work, standing
delegation authorization) live in CLAUDE.md → *Delegation protocol*.

Three small POSIX scripts (installed in `/usr/local/bin`, repo `scripts/`):

- **`tier-derive`** — `tier-derive <top>` → `<top> <worker> <recon>`
  (concrete ids); exit 3 off-ladder. Aux modes: `--name <id>` (display
  name, e.g. "Opus 5"), `--rank <id>` (0 = off-ladder). The ONLY place
  the ladder lives — tier-set and tier-reconcile both call it, so they can
  never disagree.
- **`tier-set`** — the `/tier` engine: resolves aliases, writes `.model` +
  the two frontmatter `model:` lines atomically (preserving file mode),
  sets/clears the pin, purges legacy vars. Known ladder ids bind instantly
  without probing; off-ladder/custom ids are probed with downward fallback
  (see *Graceful degradation* below). If an agent file is missing or has no
  `model:` line it says so ("slot NOT bound") and continues with the rest.
- **`tier-reconcile`** — the SessionStart + UserPromptSubmit hook. Contract:
  purge legacy vars first (always); then stop if pinned, `.model` empty, or
  off-ladder; else derive the trio from `.model` and rewrite
  executor.md/scout.md `model:` lines **only on diff**. Never touches
  `.model`. Silent on stdout (a UserPromptSubmit hook's stdout would be
  injected into the prompt). Idempotent and fast.

Shell sugar in `.zshrc` drives the same engine: `tier <top>` (= `tier-set`
+ launch) and `tier-show` (= `tier-set show`).

**Test/override env vars:** `TIER_SETTINGS=<path>` retargets the settings
file and `TIER_AGENTS_DIR=<dir>` the agents directory (both used by the
test suite so tests never touch the live binding); `TIER_NO_PROBE=1` skips
all availability probing, even off-ladder ids (bind blind); `TIER_PROBE=1`
forces probing of every candidate (downward degradation).

**Why the `/tier` command frontmatter pins `model: haiku` + `effort: low`.**
A custom command/skill is a *prompt*: after `!`tier-set …`` runs, its whole
body is processed by a model turn. On a high-/max-effort session that turn
burns a big thinking budget on a trivial passthrough. The frontmatter runs
*that turn only* on Haiku at low effort (auto-reverting afterward), and the
body is a minimal "print the tool output verbatim; don't analyze, use
tools, spawn subagents, or run a workflow" — the last clause matters
because an ultracode session injects a "use Workflow on every task"
directive into that turn too. Don't "simplify" these keys away.

**`/advisor` coupling:** `advisorModel` (settings) must be **≥ the
session's main model** or `/advisor` is rejected. It is pinned to `fable` —
the one static value valid above every trio this setup uses. If Fable is
ever unavailable on the plan, `/advisor` fails visibly; swap the value then.

## Cost monitor (cost-mirror / tier-cost, added 2026-07-28)

The `cost-mirror` hook line (one per prompt) shows, per `side|model`, token
counts **and** dollars: `main: 42k in · 113 out · 38k cache-w (opus-5) |
workers: ... | ~$52 · ~$60 at fable-5 → saved ~$8.58`. The token summary
covers all four counters — in, out, cache-r, cache-w — but **omits any
component that's zero**, so a quiet side (e.g. a worker that never wrote to
cache) stays short instead of padding the line with `0 cache-r`. The dollar
clause is suppressed when it would round to $0.00 or only one model appears
in the session (nothing to save against). Unknown/off-ladder models still
show their tokens but contribute $0 and mark the clause with a trailing `?`.

**Billing mode: API vs subscription (2026-07-29).** The same container runs
under either a raw API key or a Claude subscription; under a subscription
the dollar figure isn't a bill, it's what the session *would* cost on the
API — same math, `API-equiv` label instead. `COST_MIRROR_BILLING=api|sub`
forces the mode; otherwise `detect_billing_mode()` auto-detects, in order:
(1) `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN` in the environment → `api`
(an explicit key means per-token billing regardless of any OAuth creds also
present); (2) `claudeAiOauth.subscriptionType` present in
`~/.claude/.credentials.json` (override: `COST_MIRROR_CREDENTIALS_PATH`,
tests only) → `sub`; (3) neither signal found → defaults to `api` rather
than guessing. In `api` mode the hook line is byte-identical to before this
feature; in `sub` mode the actual-cost figure gets ` API-equiv` appended,
e.g. `~$0.45 API-equiv · ~$1.20 at opus-5 → saved ~$0.75` — the savings
clause is unchanged since it was already a counterfactual either way.
`--report` gains a `billing: <mode> (<how determined>)` line up top (plus
`— dollars are API-equivalent` in sub mode) and marks the three money
column headers with a trailing `*` in sub mode; the table's columns/widths
and data rows are otherwise untouched. Billing mode is computed at render
time only — it is never written into the persisted per-session state.

Run `tier-cost` (alias for `cost-mirror --report`) for the full per-model
breakdown: one row per `side|model` with input/output/cache-read/cache-
write tokens plus actual/at-top/saved dollars, and a TOTAL row.
`--report` is read-only (never advances the incremental byte-offset state)
and is NOT fail-silent — a missing/unreadable/ambiguous transcript prints
to stderr and exits nonzero, since it's run directly from a terminal
rather than from the hook.

**Bare `--report` aggregates by default (changed 2026-07-30).** A user
saw `tier-cost` report ~$12 saved, started and killed a second parallel
session for a small task, then re-ran `tier-cost` and saw a nearly-blank
~$0.70 session — no data was lost, but bare `--report` used to call
`_default_transcript()`, which returns the `tp` from the **newest state
file by mtime**; the parallel session's hook had written a fresher state
file, so the default silently pointed there instead. Bare `--report` (and
`tier-cost`) is now exactly what `--all` did before this change — see
"Cross-session" below — with `--all` kept as an accepted no-op alias so
old habits/docs still work. Three flags select a single session instead:
  - `--report <transcript.jsonl>` — a specific transcript, given directly.
  - `--report --session <prefix>` — the transcript whose `sessionId` (or
    filename UUID) starts with `<prefix>`; ambiguous or no-match prefixes
    fail loud, listing candidates.
  - `--report --this` — the *old* bare-default behaviour verbatim: the
    transcript recorded in the newest cost-mirror hook state file. Spelling
    out "whichever session's hook most recently fired, which may not be
    the one you're sitting in" as an opt-in flag is the actual fix — the
    bug was that this was silent and implicit.
All three single-session forms are read-only, including with respect to
`lifetime.json` (below) — they never write any state.

**Cross-session aggregate: `[--since <N>d]` (added 2026-07-29, now the
default).** Reads every `~/.claude/projects/*/*.jsonl` on disk (plus each
one's beside-it `subagents/*.jsonl`), independent of any live session — no
positional transcript argument in this mode. Output is a per-session table
(project dir, short session id, last-modified date, total tokens, actual
$, newest first) followed by the same per-side|model breakdown and grand
total `--report` produces for one session, computed over everything
scanned. The header states the scope plainly: session count, project-dir
count, and the `--since` window when given — never again silently blank.
`--since 7d` / `--since 30d` (any `<N>d`) narrows the file set to
transcripts modified in that window — without it, everything is included.
The billing-mode label and the counterfactual/top-model math apply to the
aggregate exactly as in single-session mode.

Scanning hundreds of transcripts on every invocation would be slow, so the
aggregate keeps its own persisted incremental cache — `all-sessions.json`
in the cost-mirror state dir, keyed by file path with the same `{off,
agg}` shape as the hook's per-session state — so a warm run only reads
bytes appended since the last run. This cache is a **dedicated file**,
never one of the hook's per-session `<sha256>.json` state files: the
single-session forms above still write zero state. Measured on this
container's own `~/.claude/projects/` (47 top-level transcripts, ~110
files with subagents, ~21 MB): cold run 0.055s, warm run 0.014s. A corpus
with nothing to report (no live transcripts on disk AND no lifetime
history in scope, see below) prints a message to stderr and exits nonzero
rather than crashing; the aggregate is otherwise NOT fail-silent, like
every `--report` mode. Test-only override: `COST_MIRROR_PROJECTS_DIR`
replaces `~/.claude/projects` as the root the aggregate scans.

**Durable lifetime rollup (added 2026-07-30).** Transcripts get deleted
(disk-cleanup, manual pruning), which used to silently erase their spend
from every future aggregate report. Both the hook (for the live session)
and the aggregate report path now write each session's final
`sessionId|side|model` counters into `lifetime.json` in the state dir —
schema-versioned like the other state files. Writes are **REPLACE, never
increment**: every existing row for a session_id is dropped before the
freshly (re)scanned totals are written back in, so rescanning the same
transcript any number of times cannot inflate the durable total — this is
the single load-bearing property and is tested explicitly (three
successive aggregate runs must produce byte-identical output and an
unchanged `lifetime.json` after the second). The aggregate report unions
live-scanned transcripts with lifetime rows whose transcript no longer
exists on disk, so a deleted session's spend still counts toward the
grand total and the per-session table; a footnote names how many sessions
were pulled from history rather than disk. Single-session views
(`--session`/`--this`/a direct positional transcript) never touch
`lifetime.json`, preserving their read-only-with-respect-to-state
guarantee — checked in tests by checksumming the whole state directory,
not just listing filenames, since a same-name rewrite-in-place wouldn't
show up in `ls`. `disk-cleanup.sh` was audited and confirmed to never
touch the cost-mirror state dir (`~/.claude/cache/cost-mirror`, under
`$HOME` — none of its three sweep targets, `$TMP_SCAN_DIR` default `/tmp`,
`$WORKSPACE/attachments`, or `$WORKSPACE/.claude/logs`, overlap it), so no
changes were needed there for `lifetime.json` to survive a sweep.

**The counterfactual, precisely — delegation-only savings via tier epochs
(fixed 2026-07-30, replacing the "reprice everything at one top model"
method below).** The original method picked the single most EXPENSIVE
model seen among main-loop rows all session (`pick_top_model`, main rows
ranked by output rate, falling back to the most expensive model overall if
there were no main rows) and repriced **every** row — main-loop included —
at that model's rate; `saved = at_top − actual`. That conflated two very
different things: delegating work to a cheap worker (real savings) and the
orchestrator itself dropping to a cheaper tier mid-session via `/tier`
(not savings — just a smaller bill for the *same* seat). A session that
ran Opus for an hour then `/tier sonnet` kept "top" pinned at Opus for the
rest of the session, so every post-downgrade main-loop token was misreported
as "saved," inflating the headline figure.

The fix: each session's main-loop rows are ordered by their transcript
`timestamp` and split into **tier epochs** — maximal runs of consecutive
main-loop rows sharing the same `message.model` (`_epochs_from_main_buckets`
in `scripts/cost-mirror.py`). A worker row reprices only against the epoch
its *own* timestamp falls into; a main-loop row's tier *is* the epoch it's
in by construction, so main-loop spend can no longer appear in "saved" at
all — `session_epoch_pricing` enforces this unconditionally (main rows
always get `at_epoch == actual`), not merely as a side effect of bucket
math. The first and last epochs are then CLAMPED to cover the whole session
timeline (start pulled back, end pushed to infinity), so a worker row
before the session's first main-loop row or after its last still reprices
against the nearest orchestrator tier instead of costing zero — the only
case that still costs zero toward "saved" is a worker row with no
parseable `timestamp` of its own, in a session whose main rows DO have
usable timestamps (there's genuinely no bucket to place it in); a session
with no main-loop rows at all also produces zero everywhere, since it has
no epochs to reprice against. Epochs are computed and summed **strictly per session**; an aggregate
`--report` (multi-session) never lets one session's tier reprice another's
spend (`_add_pricing` sums each session's own `session_epoch_pricing`
output — it never merges bucket data across sessions before pricing).

For state-size reasons (the incremental scan must stay bounded across a
long session, not grow with row count — see "Mechanics" above), rows are
grouped into 5-minute buckets (`BUCKET_SECONDS`) before epochs are computed,
not compared row-by-row; a bucket containing more than one main model (a
genuine tier change inside one 5-minute window, or — far more commonly — a
whole session with no `timestamp` field on any row, which all collapse into
one shared `NA_BUCKET`) resolves via `pick_top_model`'s own price-ranked
pick restricted to just that bucket. Reusing that exact tie-break (price,
not volume) is what makes a session with **no timestamps at all** collapse
to a single epoch. Where that session also used only ONE main-loop model it
reduces EXACTLY to the old whole-session method; where it used two, the
main-row pin correctly suppresses the old method's fake "saving" on
main-loop spend, so the figures deliberately differ. Combined with the
outward clamp described above, the exact-reduction case also covers a
session with real timestamps and only ONE main-loop model: its single epoch
is clamped to span the whole timeline.

This is the compatibility guarantee, stated precisely: **a session that
never changed its main-loop model, and whose worker rows all carry parseable
timestamps, produces the identical figure this always did.** Both conditions
are load-bearing — an untimestamped worker inside an otherwise-timestamped
session has no bucket to place it in and contributes zero, which does differ
from the old figure. Asserted directly in `tests/tier-hooks.bats`, both with
and without real timestamps present.
`pick_top_model` itself wasn't removed — it's reused per-bucket internally,
and still names the "top model (counterfactual)"/hook-line "at `<model>`"
label — but it no longer drives any dollar figure on its own.

This is still always an estimate even within an epoch: a cheaper/pricier
model would not have emitted the identical token counts (different
verbosity, different cache behavior), so "saved" is "what these same
worker tokens would have cost run on the orchestrator's own tier at the
time," not a guarantee of what actually would have happened.

Housekeeping riding along with the epoch fix: (1) `STATE_VERSION` bumped to
3 (the persisted per-file `agg` gained a bucketed sibling, `bagg`, so an
old v2 state is rescanned clean rather than silently missing epoch history
for bytes already consumed) — but `lifetime.json`'s schema didn't change,
so it now has its own `LIFETIME_VERSION` (still 2) rather than riding the
same bump and being wiped for no reason. (2) `run_report_all`'s title line
now reads `len(session_rows)` (live + lifetime-only) instead of
`len(transcripts)` (live only), so it can't read "0 transcripts" directly
above a table headed "2 session(s)" when sessions were pulled from
lifetime history. (3) the comment above `_update_lifetime`'s call in the
hook's `main()` now says what actually happens: that call isn't wrapped in
its own try/except, so a failure there is caught only by the outer
fail-silent guard, silently skipping that prompt's hook line too — not
just the lifetime write, as the old comment implied — which is still
judged acceptable since the overall fail-open contract (never crash the
prompt) holds either way.

**Maintenance: refresh `PRICING_TABLE` from the claude-api skill whenever
models or prices change.** Current table (`scripts/cost-mirror.py`), USD
per MTok in/out, prefix-matched in order (first match wins):

| prefix | in | out |
|---|---|---|
| `claude-fable-` / `claude-mythos-` | 10.00 | 50.00 |
| `claude-opus-` | 5.00 | 25.00 |
| `claude-sonnet-5` (intro, until 2026-09-01) | 2.00 | 10.00 |
| `claude-sonnet-5` (standard, from 2026-09-01) | 3.00 | 15.00 |
| `claude-sonnet-` (other sonnet ids) | 3.00 | 15.00 |
| `claude-haiku-` | 1.00 | 5.00 |

Derived per-model rates: cache-read = 0.1× input, cache-write-5m = 1.25×
input, cache-write-1h = 2.0× input. The sonnet-5 intro cutoff is
`SONNET5_INTRO_CUTOFF` in the script; `_sonnet5_rates(today=...)` takes an
optional date for testing (see `tests/tier-hooks.bats`).

## Delegation gate (2026-07-29)

**Why instructions alone failed.** The protocol above is text, and text
didn't bind behavior: the motivating session logged 1 demonstration scout
against ~20 inline main-loop calls with the full protocol already live. A
headless matrix confirmed it wasn't a one-off — with the global protocol
and the per-prompt `[tier]` line both present, two of three task shapes
(B, C below) ran **100% inline** in their control children. Guidance alone
doesn't move spend; only a mechanical gate does.

**Mechanism.** `scripts/delegation-gate.py` (PreToolUse) counts
consecutive Read/Grep/Glob/Edit/Write/NotebookEdit + non-exempt-Bash calls
made by the **main loop only**, never a subagent. Mode (env
`DELEGATION_GATE_MODE` / `~/.claude/delegation-gate.mode`, default
`warn`): `warn` fires a one-shot `additionalContext` nudge at streak 4;
`enforce` always denies Edit/Write/NotebookEdit (naming executor) and
denies other counted tools past streak 8 (naming scout). Housekeeping
Bash (`bd`, read/commit-ish `git`, `bats`, `dev-log`, `cost-mirror`,
`tier-*`, `run-tests`, `take-screenshot`) is exempt from counting
entirely. `Agent`/`Workflow` resets the streak to 0 — the "I delegated"
signal. Fails open.

**Discriminator, and the dead-gate lesson.** The obvious signal — a
subagent `transcript_path` containing `/subagents/` — is a red herring:
byte-identical for main-loop and subagent calls. The real signal,
`agent_id`, changes shape mid-session: absent pre-first-spawn, present-
but-`null` on main-loop calls after any spawn, populated only on subagent
calls. An earlier version assumed `agent_id: null` was the only main-loop
shape and was tested only against it — 12/12 green — while real
early-session traffic (key **absent**) fell through as "subagent, skip":
the gate silently never fired, caught only by zero state files in real
sessions, not by its own test suite. A worker's report and the synthetic
fixtures encoded the same wrong assumption, so the tests validated the
bug. Lesson: check empirical claims against raw evidence, not a report or
a test suite built on the same unverified premise. Current tests lock in
both main-loop shapes plus a regression guard against the transcript_path
hypothesis (`tests/delegation-gate.bats`).

**2-round headless matrix (12 children): dead-gate control vs live gate.**
**A** (recon): regression guard passes clean — 3 scouts, 0 inline reads.
**B**: flips under warn at both sonnet and fable top tiers (streak-4 note
recorded, executor spawn on the very next move) — but see the channel
caveat below before reading that ordering as causal in headless runs;
enforce's deny paths are unambiguously live — an Edit-deny redirected a
fable session into its executor, and a `DENY_AT=1` child went deny →
scout → correct answer. **C** (audit): the honest negative — bursts stay
~4 calls, never reaching `DENY_AT=8`, so enforce never trips, and its one
warn-mode delegation spawned subagent_type-less `general-purpose` instead
of `scout` (functionally delegated, wrong tier, recon pricing forfeited —
why the protocol now spells out `subagent_type: "scout"` explicitly).
Every variant's final answer stayed correct, independently re-verified.

**Warn-channel matrix (v2.1.220, probed).** A DENY's
`permissionDecisionReason` reaches the model **always** — it arrives as
an `is_error` tool_result and is followed as a literal instruction (both
probes confirmed unprompted compliance). An ALLOW's `additionalContext`
(and `systemMessage`) is **harness-dependent**: in an interactive/agent
session it lands in model context (observed live — the shipping session
read its own streak-4 warn and delegated), but in headless `claude -p`
children a full content-scan of every user/assistant message found the
probe strings **only in sidecar attachment records, never model-visible**.
Two implications: headless B-warn "flips" may be spontaneous delegation
rather than warn-caused (n=1, channel inert there), and in headless
pipelines only `enforce` actually steers.

**Tuning decision.** Ship the observed defaults — warn at streak 4,
enforce's deny at streak 8. Warn targets interactive sessions, where its
channel demonstrably lands; `enforce` is the user's escalation endpoint
and the only reliable lever for headless children — one env flip away
(`DELEGATION_GATE_MODE=enforce` or `~/.claude/delegation-gate.mode`), no
code change required.

## Delegation gate hardening (2026-07-30)

**(a) The one-shot-warn defect.** The original gate warned once, at
streak 4, then fell permanently silent for the rest of the session — the
one mechanism that fires *mid-turn*, on the exact behavior it exists to
interrupt, shut itself up after a single use. A session that read the
streak-4 note and kept grinding anyway got no second nudge at streak 12,
20, or 200; the gate degraded to a no-op for the remainder of any session
that didn't correct on the first try. Fixed with a watermark, not a
boolean: `warned_at` records the streak at which the last warn fired, and
the gate warns again whenever `streak - warned_at >= DELEGATION_GATE_WARN_EVERY`
(default 8) — so 4, 12, 20 … — with wording that escalates at 2× and 6×
`warn_at` (standing-authorization reminder, then the token re-billing
economics). `Agent`/`Workflow` use clears both `streak` and `warned_at`,
so a session that actually delegates gets tier-1 wording again on its next
drift rather than staying primed at the escalated tier. Legacy
`{"warned": true}` state (no watermark) migrates to `warned_at = streak`
on load, so an upgraded session doesn't immediately re-warn on the same
streak that already warned it once under the old boolean.

**(b) Two-axis modes, and why `guard` is now the default.** Mode used to
be a single warn/enforce switch; it's now `off` · `warn-only` (alias
`warn`) · `guard` · `enforce`, each a strict superset of the last:
`guard` denies Edit/Write/NotebookEdit in the main loop unconditionally
(reads/Bash still only warned), `enforce` adds a read/Bash streak-deny on
top of `guard`. The default moved from `warn` to `guard` because of the
**warn-channel finding** above this section: a DENY's
`permissionDecisionReason` reaches the model *always* (arrives as an
`is_error` tool_result, followed as a literal instruction — both probes
confirmed unprompted compliance), but an ALLOW's `additionalContext` is
**harness-dependent** — it lands in model context in an interactive
session but was found only in sidecar attachment records, never
model-visible, in headless `claude -p` children. A warn-only default is
therefore silently inert in exactly the automation contexts most likely
to grind unsupervised; a denial is the only channel that cannot be
silently dropped by the harness. `guard` picks the smallest denial
surface that is still unconditionally effective — implementation edits
are the executor's seat regardless of streak — while leaving recon
(Read/Grep/Glob/Bash) on the repeating-warn cadence rather than a hard
deny, since recon volume is legitimately spiky in ways edit volume isn't.
An unrecognized `DELEGATION_GATE_MODE` value (typo, stale env) falls back
to `guard`, never to a weaker mode — the gate must not silently degrade
on a misspelling.

**(c) The plan/memory carve-out.** Under `guard`/`enforce`, Edit/Write to
`~/.claude/plans/**` (or any path containing `/.claude/plans/`, covering a
git-root-relative plan dir too) or the harness auto-memory dir
(`~/.claude/projects/*/memory/`) is allowed even mid-streak. Without this,
`guard`'s "always deny an edit in the main loop" rule would deny the
orchestrator's *own* plan file and its own memory writes — both of which
are explicitly the orchestrator's seat per CLAUDE.md's "Plan Before Code"
and the harness's own auto-memory mechanics, never the executor's. The
carve-out must be **proven** from an explicit, resolvable path in
`tool_input`; a call with no determinable path is NOT carved out (denied)
— the exception is never the default. `/tmp` and the scratchpad are
deliberately excluded from the carve-out: either would be a smuggling
hole for real implementation edits routed around the gate.

**Drift metrics now surfaced.** `max_streak`/`warns`/`denies` persist for
the life of the session (only `streak`/`warned_at` reset on
`Agent`/`Workflow` use) and are read directly by `cost-mirror` (not
imported — the state-dir path constant is duplicated locally in
`scripts/cost-mirror.py` with a comment naming `delegation-gate.py` as the
owner) to append a short `| inline: max streak N · W warn(s) · D deny/denies`
clause (e.g. `max streak 12 · 3 warns · 1 deny`, singularised at 1) to the
per-prompt spend line, omitted entirely when there's nothing to report.
See "Cost monitor" above for the rest of that line's
anatomy.

**Compaction can no longer launder the protocol out of context.**
`scripts/tier-prime.sh` is now the single owner of the tier-reminder
wording, called from both `SessionStart` (bare) and `PreCompact`
(`--full`, adding the dispatch table and the standing-authorization
sentence) — before this, `PreCompact` ran only `bd prime` and a
compaction could silently drop the delegation protocol from context for
the rest of the session. `config/claude-user-memory.md`'s invariants now
say explicitly that a compaction, a long turn, or a context summary does
not revoke the standing authorization.

## Graceful degradation (probe + fallback)

A probe is a real `claude -p` round trip (~5–10 s per candidate), so
probing is **selective**: the four known ladder ids are trusted and bind
instantly with no probe; only off-ladder/custom ids are probed by default
(typo guard, one retry per candidate), and `TIER_PROBE=1` forces probing
of every candidate. This is deliberate — probing all slots made `/tier`
take 15–25 s inside its `!`-preprocessing, and a single transient API blip
on the recon floor (haiku has no candidate below it) exited non-zero and
hard-failed the entire slash command (observed 2026-07-22). The trade-off:
a gated/off-plan ladder model now surfaces at spawn or `/model` time
instead of bind time; use `TIER_PROBE=1` when that matters.

When probing runs, each slot degrades **downward** past candidates that
fail (best-effort — a safeguard-rerouted model can still probe green):

- top: `<requested>` → `claude-opus-5` → `claude-sonnet-5` → `claude-haiku-4-5-20251001`
- worker (explicit form): `<requested>` → `claude-sonnet-5` → `claude-haiku-4-5-20251001`
- recon (explicit form): `<requested>` → `claude-haiku-4-5-20251001`

**A probe failure is never fatal.** If every candidate for a slot fails,
the requested id is bound anyway with a `WARNING … bound '<id>' UNVERIFIED`
line and exit 0 — the settings write always happens and the slash command
cannot brick on a flaky probe. On the 1-arg path the trio is derived from
**whichever top actually bound**, so worker/recon never need their own
fallback there. Fallback never escalates cost. The SessionStart hook echoes
the live binding each session, so you always see what you actually got.

**Demo — off-ladder id that fails its probe:**

```
/tier my-custom-model              # off-ladder ids are probed…
tier[top] my-custom-model unavailable, trying next...
tier[top] falling back -> claude-opus-5
tier bound  top=claude-opus-5  →  worker=claude-sonnet-5  recon=claude-haiku-4-5-20251001  (worker/recon derived from the top)
→ run  /model claude-opus-5  to move THIS session's model now — new sessions pick everything up automatically.
```

(Fable 5 is an active model — do not assume it is unavailable.)

## Post-mortem: why v1 (env-slot remap) was retired — never reintroduce it

v1 bound worker/recon by rewriting
`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` (+ `_NAME` labels) in
settings `env`, and executor/scout rode the `sonnet`/`haiku` aliases. It
failed structurally, not cosmetically:

1. **The picker reads the same vars.** Claude Code's native `/model` picker
   builds its Opus/Sonnet/Haiku rows from those exact env vars, so any
   remap redefined what the picker's rows *are* (the `_NAME` labels only
   patched what they *said*).
2. **Selection persists bare aliases.** Picking a custom-slot row writes
   the bare alias (`"opus"`, `"sonnet"`, optionally `[1m]`) into `.model` —
   so with slots remapped, an alias meant one thing at selection time and
   another after any slot rewrite.
3. **The reconciler re-derived from the alias name, not the slot content**
   — deriving a trio from `"opus"` after `opus` had been remapped walked
   the whole trio down the ladder, one rung per cycle.

Observed live 2026-07-17 (bead dsu): the picker offered only
Fable/Sonnet-1M/Haiku, `/model opus` landed on Fable, and later sessions
drifted down to Haiku. v2 removes the collision at the root: aliases and
the picker are native again, and the tier binding lives in agent
frontmatter, which nothing else reads. This is why the legacy vars are
**purged on sight** — any partial resurrection (even "just one slot, just
temporarily") re-creates the alias ambiguity.

## Trust, but verify

A worker's summary is an **input to check, not a fact.** Non-trivial worker
output is verified *independently* by a `verifier` with fresh context and
no stake — never by the worker grading itself.

- **Mandatory** before declaring a task done, after file-writes + test
  output exist, and on any result folded into the final answer. Unverified
  worker claims are not "done".
- Research claims → checked against **primary sources**; code → against
  **tests/build/an independent read**.
- Spawn **one verifier per finding** so intermediate checks stay out of the
  orchestrator's context; the verifier returns a verdict
  (`CONFIRMED`/`REFUTED`/`INCONCLUSIVE`), not a transcript.
- **Proportionate:** skip only on trivial/self-evident results; require it
  wherever a wrong-but-plausible result would propagate.

## Rollback

All changes are repo files, reversible via git; and the live state is
self-healing: **an image rebuild resets the agent files and
`settings.json` from the templates, and the SessionStart reconciler
re-derives worker/recon from `.model` on the first session** — no manual
re-run needed. To roll back live state without a rebuild:
`cp /etc/claude-dev/configs/agents/*.md ~/.claude/agents/` (or from the
repo: `config/agents/`) and start a fresh session. Note the repo agent
templates carry alias placeholders (`model: sonnet` / `model: haiku`); the
reconciler replaces them with concrete ids on first run.

Revision log (each reversible via git on the listed files):

- **2026-07-29 — delegation gate (beads arr/0xi/p1r):**
  `scripts/delegation-gate.py` + `tests/delegation-gate.bats` added;
  `config/claude-settings.json` gains the PreToolUse entry;
  `config/claude-user-memory.md` dispatch-table wording tightened
  (whole-task trivial rule, explicit `subagent_type: "scout"`); this doc
  gains the Delegation gate section. Rollback = revert those files and
  remove the settings entry; the gate fails open if the binary is absent.
- **2026-07-17 — mechanism v2 (frontmatter binding; bead dsu):**
  `scripts/tier-set.sh`, `scripts/tier-reconcile.sh`, `scripts/tier-derive.sh`
  rewritten (env-slot remap retired, purge policy added, `TIER_AGENTS_DIR`
  override added); `config/claude-settings.json` SessionStart echo now
  reads settings `.model` + executor/scout frontmatter; this doc rewritten.
  The runtime binding now lives in `~/.claude/agents/{executor,scout}.md`
  frontmatter, maintained by the scripts.
- **2026-07-10 rev 2 (/tier slash command):** engine moved from the shell
  into `scripts/tier-set.sh` (installed as `/usr/local/bin/tier-set`),
  exposed as `/tier` via `config/claude-commands/tier.md`; `config/.zshrc`
  reduced to thin wrappers; `Dockerfile` + `scripts/entrypoint.sh` staging;
  `tests/smoke.bats` retargeted.
- **2026-07-10 rev 1 (Fable-is-back review):** `config/.zshrc`,
  `config/agents/{verifier,oracle}.md` (`model: inherit`),
  `config/agents/{executor,scout}.md` (prose),
  `config/claude-settings.json` (`advisorModel: "fable"`), `CLAUDE.md`,
  `tests/smoke.bats`. Pre-change copies:
  `~/.claude/backups/tier-review-20260710/`.
- **Original introduction:** `config/agents/executor.md`, `verifier.md`
  (new); `scout.md`, `config/claude-settings.json`, `config/.zshrc`,
  `CLAUDE.md` (additive edits). Base commit `bc5cb028`; pre-change copy
  under `~/.claude/backups/tiered-orchestration-<sha>/`.
