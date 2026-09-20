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
| **verifier** (leaf) | `config/agents/verifier.md` | frontmatter `model: inherit`; the CHECKER rung in `tier.json` is what a dispatch binds (top capped at opus) | — | independent check of one evidence surface |
| **oracle** | `config/agents/oracle.md` | `model: inherit` (= orchestrator) | — | user-invoked checkpoint consult |

**Invariant: the orchestrator is the most capable model of the three, and
by default the expensive tiers (opus/fable) never take the worker seat** —
enforced on the **derived (1-arg) path**, where the worker is one rung down
capped at sonnet-class and recon is one rung below the worker. An explicit 2/3-arg pin accepts **any**
combination by design, including inverted ones (user decision, bead uhs) —
that is the operator's call, not blocked; `/tier overdrive` makes the same
latitude *sticky*, lifting the cap on the derived path itself so the
executor rides the top model until it is cleared (see **Overdrive — lifting
the worker cap** below).

**The checker rung (2026-09-12, claude-orca-8a0.2).** The verifier is no
longer a flat `inherit`. It is derived like every other rung — the top
**capped at opus** (`tier-derive --checker`) — so the ladder reads:

| top | worker | recon | checker |
|-----|--------|-------|---------|
| `fable`  | `sonnet` | `haiku` | **`opus`** |
| `opus`   | `sonnet` | `haiku` | `opus` (= the top, what `inherit` always meant here) |
| `sonnet` | `sonnet` | `haiku` | `sonnet` |
| `haiku`  | `haiku`  | `haiku` | `haiku` |

Under a fable top the checker is the one seat that is **neither the top's nor
the worker's**: independence is what the evidence pays for, and an opus
grader costs about half a fable one while still sitting a rung above the
sonnet worker it grades — never below the claims it checks. `oracle` still
uses `model: inherit` (it is a consult, not a grader), and so does a checker
whose top is off the ladder. Overdrive lifts the *worker* only; a lifted
worker never drags its grader up with it.

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

## Backends — where a role actually runs (2026-09-06)

A role binds a **backend** as well as a model. The backend decides what the
orchestrator talks to; the model decides who does the thinking.

| backend    | what runs                                    | models                                                                 | who uses it |
|------------|----------------------------------------------|------------------------------------------------------------------------|-------------|
| `orca`     | a supervised Orca worker terminal, in its own worktree | `claude:<alias\|id>` · `openrouter:<vendor/model>` (through `opencode`) · `codex:<id>` · `gemini:<id>` | worker (executor) slices |
| `subagent` | the in-process Claude Code Agent tool        | Anthropic ids only                                                       | recon, checkers, and the worker fallback |

Defaults: the **worker backend is `orca`** whenever the Orca runtime answers
`orca-ide status --json` with `.runtime.reachable`, `subagent` otherwise; the
**worker vendor** is decided by the OpenRouter key — with one present (the
file `claude-dev key openrouter` writes) the derived worker is `opencode` on
`openrouter/z-ai/glm-5.3`, the default GLM executor; without one it is
`claude:<derived worker rung>`. **Recon = `subagent` haiku** and **checker = `subagent`
at the derived checker rung** (the top capped at opus), both in-process on
purpose — recon is cheap and read-only, and a checker never grades a claim
from below the worker that made it. `/tier worker openrouter:qwen/qwen3-coder`,
`/tier worker claude:sonnet` or `/tier worker subagent` rebinds the worker
seat, and **`/tier recon openrouter` puts recon on the flash-class rung**
(`openrouter/z-ai/glm-5.3-flash` run by `opencode` on the orca backend) —
the bare `openrouter` spec takes the role's own OpenRouter default, so the
same word means the full-size GLM for the worker and the flash sibling for
recon. The matching delegate routes are `glm-flash` and `deepseek-flash`,
both `grade: scout` (`config/delegate-routes.json`); see *tier.json* below for the file all of this is read from. Every
OpenRouter call from the VM goes through the residency guard — GLM is fine,
a China-hosted GLM is not, and the rule (served only in the US, Canada or
Europe) plus the default Fable + GLM stack are in
`knowledge-base/DATA_RESIDENCY.md`.

### The dispatch loop

One bead, one worker, one receipt:

```
orca-dispatch <bead-id>            # Task from the bead + WORKER RULES, worker started,
                                   #   and its spooler for this Run if none is live
orca-wait [--until <s>]            # reader: print+consume inbox.jsonl; --until
                                   #   blocks <=s s in the background for new lines
orca-reply <msg_id> "<answer>"     # unblocks a worker that asked instead of guessing
orca-workers                       # worker-list ⋈ task-list --brief, one table
verifier                           # fresh context, against the bead's own contract
```

- **`orca-dispatch`** ensures ONE Run per coordinator session, composes the
  Task spec from `bd show` (title, description, acceptance contract, the
  `WORKER RULES` block), starts the worker for the bound agent —
  `claude`/`codex`/`gemini` via `worker-start --agent … --model …`,
  `openrouter` by creating an `opencode --model openrouter/<m>` terminal and
  adopting it with `worker-start --terminal`, `bash` as a context-only
  dispatch — records the task and dispatch ids on the bead, and prints one
  JSON receipt.
- **`orca-wait`** splits the mailbox so the orchestrator never runs the poll
  loop in its own turns (claude-orca-mg8). `orca-dispatch` starts one
  detached spooler per Run (`orca-wait --spool`, pid file
  `run/orchestration/spool.pid`): it runs the old rolling `check --wait`,
  appends every receipt to `run/orchestration/inbox.jsonl`, does the
  release/bead-note/stall work itself, and exits once no dispatch is live.
  Bare `orca-wait` prints and consumes the unread lines (cursor in
  `inbox.cursor`); `orca-wait --until <s>` blocks at most `s` seconds for
  the file to grow — run it in the background so a worker message wakes you
  through a task notification. A `worker_done` is appended to its bead and
  the worker terminal released (`worker-release`) unless `--keep` was given
  to the spooler; a `question` or `escalation` lands in the inbox for you to
  answer. The whole batch is acked only after every message is processed, so
  a crash mid-batch replays rather than loses.
- **A `worker_done` is a claim, not a verdict.** The bead closes after a
  `verifier` run against the pre-registered contract, never on the worker's
  own say-so.

### WORKER RULES — what every dispatched worker is told

`orca-dispatch` appends the same block to every Task spec, which is why a
worker on a foreign vendor's model still behaves like one of ours: do not
delegate or start further workers; do not close the bead and never write a
`VERIFIED` line; verify by running the real thing and report the command and
output; on a contract, commit the test RED first (`RED-AT`) then the
implementation (`GREEN-AT`) and never edit a FROZEN file; ask with
`orchestration ask` rather than guess; report exactly once with
`send --type worker_done … --outcome succeeded|failed`.

### Parallel by default

The bias is "everything independent runs at once", not "one slice at a time".

- **Waves.** `orca-run --epic <id> [--epic …] [--max-parallel N]` reads an
  epic's children from bd, mirrors their dependency edges into Orca Tasks
  (`task-create --deps`), dispatches every ready task in one wave through
  `orca-dispatch`, then loops `orca-wait` → release → dispatch the newly
  ready set, printing one status table per wave. Only beads that FREEZE the
  same file, or name the same files in their descriptions, are serialized.
- **One worktree per epic.** The first worker of an epic starts with
  `--worktree new-top-level --name <epic>`; later workers of the same epic
  reuse that exact worktree id. Epics therefore run side by side in separate
  checkouts, as separate worktree cards in Orca. When an epic's last task
  settles, `orca-run` sends `merge_ready` with the branch name and prints
  `EPIC READY <epic>` — the merge itself stays with the orchestrator, after
  the verifier.
- **Epic coordinators.** `seed-orca-state.sh` sets `nestedWorkerMaxDepth`
  to 2, so the orchestrator may dispatch a bead whose spec is "coordinate
  epic X with `orca-run`" and let that coordinator run its own wave loop.
  The top session then supervises coordinators, not slices. Depth stops at
  2: a coordinator's own workers are leaves.
- **Recon fans out freely** — several `scout` spawns in one message, no
  worktree, no Run.

All five live in `bin/` and are exercised by `tests/orca-run.bats` and
`tests/orca-dispatch.bats` against a real `orca-ide --serve`.

### Fallback — an unreachable runtime, and the explicit-model rule

Running outside Orca still works. With `.runtime.reachable` false (or an
explicit `--backend subagent`), `orca-dispatch` writes the equivalent
Agent-tool executor spec to stdout and **exits 3** — nothing is dispatched
and the orchestrator falls back to the in-process `executor` knowingly,
never silently.

That fallback spawn must carry **an explicit `model`**. `tier-gate` never
blocks a spawn; what it injects depends on the worker's binding. Under a
`subagent` backend, or an `orca` backend whose agent is `claude`, it injects
the bound model (or the rung derived from the top when that model cannot be
ranked) and adds a "prefer orca-dispatch" note. Under a **non-Claude worker
backend** — `opencode` on OpenRouter, `codex`, `gemini` — there is no model
the Agent tool would accept, so the hook only *notes* the backend and injects
nothing: the spawn would run on the orchestrator's own expensive model. So
the orchestrator passes `model=<derived rung>` itself — the second id
`tier-derive <top>` prints, as its family alias (`model: "sonnet"`; the
Agent tool's `model` parameter rejects concrete ids). The same rule keeps the
invariant "expensive tiers never take the worker seat" true on the fallback
path.

### A mixed Run, worked

Two slices of one epic, two vendors, one coordinator:

```
/tier fable                                  # top fable; worker derives per the key (GLM) or rung
/tier worker claude:sonnet                   # rebind the worker seat: Claude Code on the sonnet rung
orca-dispatch epic-42.a                      # worker 1: claude:sonnet in the epic worktree
/tier worker openrouter:qwen/qwen3-coder     # rebind again: opencode on OpenRouter
orca-dispatch epic-42.b                      # worker 2: same Run, same worktree family
orca-workers                                 # both rows, both agents
orca-wait                                    # (reader) worker_done from b; a question from a
orca-reply <msg_id> "yes — keep the old flag name"
orca-wait                                    # (reader) worker_done from a
```

Both workers were given the same `WORKER RULES` and the same contract text,
report through the same `worker_done` channel, and are checked by the same
`inherit`-model verifier. The vendor is a per-slice choice, not a protocol
change. Spawns are unnamed: a named spawn arrives as a wrapped teammate
notice and wakes the orchestrator for nothing; the task notification
carries the result. `/tier worker` rebinds only the seat for the *next*
dispatch; a worker already running keeps the model it was started with.

## The v2 binding mechanism — where each tier lives

```
top    -> settings .model                         (plain-launch orchestrator default)
worker -> ~/.claude/agents/executor.md  `model:`  (CONCRETE id in frontmatter)
recon  -> ~/.claude/agents/scout.md     `model:`  (CONCRETE id in frontmatter)
checker  -> tier.json `roles.checker.model`       (the top CAPPED at opus)
oracle   -> `model: inherit`                      (tracks the orchestrator)
```

No tier code writes any `ANTHROPIC_DEFAULT_*` var, ever. The `/model`
picker is **fully native and honest**: a bare alias (`opus`, `sonnet`,
`haiku`, optionally with a `[1m]` suffix) always means its native family,
because nothing remaps it. The tier binding lives where only subagent
definitions read it — the frontmatter — so the picker and the tiers can no
longer interfere.

### tier.json — the file the hooks actually read (v2, 2026-09-06)

The frontmatter arrangement sketched above is the *historical* one. Since S4
the binding lives in `.claude-dev/run/tier.json`, and since
claude-orca-qa2.12 that file carries a **backend, agent and model per role**:

```json
{ "top": "fable",
  "worker": "openrouter/qwen/qwen3-coder",     // v1 mirror of roles.worker.model
  "recon":  "haiku",                          // v1 mirror of roles.recon.model
  "roles": {
    "worker":  {"backend":"orca","agent":"opencode","model":"openrouter/qwen/qwen3-coder","pinned":true},
    "recon":   {"backend":"subagent","agent":"claude","model":"haiku","pinned":false},
    "checker": {"backend":"subagent","agent":"claude","model":"inherit","pinned":false} },
  "pinned": false, "overdrive": false, "updated": "2026-09-06T00:00:00Z" }
```

- **backend** — `orca` (a supervised Orca worker terminal, started by
  `orca-dispatch`) or `subagent` (the in-process Agent tool).
  **agent** — `claude` · `opencode` (OpenRouter models) · `codex` · `gemini`.
- **A v1 file reads as v2** with `backend: subagent`, `agent: claude` and the
  model taken from the v1 `.worker`/`.recon` key (checker: `inherit` — a v1
  file predates the derived checker rung). The
  reader is `tier_role`/`tier_role_field` in `scripts/lib/tier-roles.sh`;
  no script parses the file's shape by hand.
- **Grammar:** `/tier worker openrouter:<vendor/model>` → orca + opencode;
  `/tier worker claude:<alias>` → orca + claude; `/tier worker subagent` →
  subagent on the derived model; the same specs work for `recon` and
  `checker`. A spec that names a model sets that role's own `pinned`, which
  stops `tier-reconcile` re-deriving its model; backend and agent are always
  preserved by the reconciler. A 1-arg `/tier <top>` rebinds all three roles
  to the defaults — worker `orca`+`claude` when `orca-ide status --json`
  reports `.runtime.reachable` within 2s (probed once per bind, never
  cached), else `subagent`; recon `subagent`; checker `subagent` at the
  derived checker rung (`inherit` only when the top is off-ladder). The bare
  `/tier <role> openrouter` spec — no model named — binds that role's own
  OpenRouter default: `/tier recon openrouter` is the flash rung.
- **tier-prime** prints a second line, `[tier] backends: worker=… recon=…
  checker=…`, each formatted `backend[:agent]:model` (the agent segment
  appears only when it is not `claude`). The model line above it is
  unchanged.
- **tier-gate** is unchanged for a `subagent` role: a generic/executor spawn
  with no `model` still gets the worker tier injected as a family alias. For
  an `orca` role it does **not** inject and does **not** block — it adds one
  line saying the backend is orca and that `orca-dispatch` is preferred.

**Purge policy (both tier-set and tier-reconcile).** The six
`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL(_NAME)` vars and
`CLAUDE_CODE_SUBAGENT_MODEL` are standing footguns — the first six corrupt
the picker, the last collapses every subagent onto one model. Both scripts
actively **delete them from settings `env` wherever found**: tier-set on
every bind, tier-reconcile as its first step on every run — even when a
pin, an empty `.model`, or an off-ladder `.model` skips derivation.
`tier-set show` warns if any are present. Don't hand-restore them for any
reason.

### Empirically verified facts (2026-07-17, this sandbox, Claude Code 2.1.x)

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
   (`claude-fable-5-1[1m]` and `opus[1m]` rank by family; the exact original
   value is preserved in the top slot). Safe because aliases are native
   again.

### Liveness — when a binding takes effect

- **Worker/recon bindings apply to NEW sessions** (fact 2 above). The
  **SessionStart tier-reconcile hook** is what guarantees every session's
  executor/scout are consistent with `.model` from that session's *first*
  spawn — the files are synced before anything spawns.
- The **PostModelSwitch** and **ConfigChange** (matcher `user_settings`)
  runs of the same hook keep the files (and the purge) current on disk
  mid-session after a `/model`/`/fast`/`--model` switch or a settings-file
  edit, but because of the snapshot their effect on spawns lands in the
  next session. PostModelSwitch's stdin carries a `to_model` field, which
  `tier-reconcile` prefers over `.model` since the switch may not be
  persisted to disk yet when the hook fires.
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
/tier fable                         # explicit set: .model=fable + worker sonnet / recon haiku
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
sonnet-class** unless overdrive lifts it (below) — by default opus/fable
stay out of the worker seat, the orchestrator plans/delegates/reviews — and
recon is one rung below the worker, floored at haiku):

| top | worker (executor) | recon (scout) |
|-----|-------------------|---------------|
| fable  | sonnet | haiku  |
| opus   | sonnet | haiku  |
| sonnet | haiku  | haiku  |
| haiku  | haiku  | haiku  |

The ladder stores the FAMILY ALIAS itself -- `fable`, `opus`, `sonnet`,
`haiku` -- never a dated id. Claude Code resolves an alias to the newest
model of that family (`claude --help`: "an alias for the latest model"), so
a new release needs no change here; the day the table said `claude-fable-5`
while `/model` said `claude-fable-5-1` is why. The alias is what gets
**written**, and every consumer ranks it rather than comparing ids:
`tier-gate` injects it into the Agent tool's `model` (whose accepted values
are exactly these aliases), an orca-backed worker gets it as `claude --model
<alias>`, and `cost-mirror` prices from the concrete id the transcript
records, never from tier.json. A full family id (incl. dated/variant) maps
to its rung and keeps its exact value on top; anything else is off-ladder.

**Off-ladder tops.** `tier-derive` prints nothing and exits 3 for a top it
can't place (`best`, a custom id). The two callers react differently, both
deliberately: `tier-reconcile` **leaves the agent files untouched** (never
clobber); a 1-arg `tier-set <custom-id>` can't derive, so it **binds all
three slots to that same model** and says so — you asked for that top,
you get it everywhere. `tier-set show` flags an off-ladder top as
custom/unmanaged.

### Overdrive — lifting the worker cap (added 2026-08-23)

`/tier overdrive` (engine: `tier-set overdrive`) is the sanctioned, opt-in
exception to the cap: the **executor** binds to the top's own exact id
(dated and `[1m]` variants preserved) while **recon stays derived from the
CAPPED worker**, so lifting the executor never drags scout up with it.
`.model` is read, not rewritten or re-probed — it is the model this session
already runs, so probing could only invent a way to fail.

```
/tier overdrive        # lift the cap on the current top — sticky
/tier opus             # 1-arg: clears overdrive, restores the capped worker
/tier opus sonnet      # 2/3-arg pin: clears overdrive, literal ids win
```

`tier-set overdrive` parks `.env.TIER_OVERDRIVE="1"`; `tier-derive
--overdrive <top>` is the pure derivation behind it (`<top_id> <top_id>
<recon>`). The flag is a **derivation rule, not a frozen value**:
`tier-reconcile` re-applies it every prompt, so overdrive FOLLOWS `/model`
and survives into new sessions; `tier-gate` reads it too, so a generic
model-less spawn also gets the lifted worker.

Precedence has two halves. At **set** time the flags are mutually exclusive,
last-writer-wins (taking overdrive drops a pin; a 2/3-arg pin drops
overdrive) — one owner for the worker slot. At **reconcile** time a pin wins
outright: it skips derivation entirely, flag or not. An off-ladder top is a
no-op everywhere (`tier-derive` exits 3; `tier-set overdrive` refuses with
`top '<id>' is off-ladder — not liftable; bindings and the overdrive flag
left untouched, nothing bound`).

**It is never silent.** `tier show` prints an `overdrive: ON` line plus the
LIFTED trio; tier-prime's SessionStart trio line appends `| OVERDRIVE:
worker cap lifted — /tier <top> to clear`; cost-mirror's hook line replaces
the savings counterfactual with `tier savings n/a (OVERDRIVE)`,
unconditionally — a lifted cap leaves no cheaper tier to be counterfactual
against (`COST_MIRROR_SETTINGS_PATH` overrides the settings file it reads
the flag from, for tests). Residual: `cost-mirror --report` still renders
capped-worker `at-top`/`saved` columns — bead gu4.

**When it is worth it:** a slice hard enough that top-tier *implementation*
earns its price — subtle refactors, stubborn debugging, work a sonnet-class
executor would need several rounds for. Clear it with a 1-arg `/tier <top>`
once the hard part is done.

**Until the next host image rebuild** the baked `/usr/local/bin/tier-derive`
predates the flag and exits 3 on `--overdrive`, so every caller fails open
(nothing bound, capped derivation kept); `TIER_DERIVE=<project>/scripts/tier-derive.sh`
exercises the current engine meanwhile.

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
  script whose `agent()` calls omit `model:` (char-by-char lexer masks
  strings/templates/regex/comments, then scans each real call site from its
  opening paren to the matching close paren, bounded by
  `WORKFLOW_LINT_WINDOW` lines (default 200); `/* workflow-lint: model-ok */`
  suppresses, honoured through 2 lines past the matching close paren). Two
  fail-open caps bound the scan's own cost: `WORKFLOW_LINT_MAX_PER_LINE`
  (default 64) caps how many `agent(` call sites are examined per source
  line — beyond it, sites go unlinted rather than trigger the quadratic
  cost of tens of thousands of forward walks over one line (~48s measured
  uncapped, enough to wedge the tool call the hook guards);
  `WORKFLOW_LINT_MAX_BYTES` (default 500000) skips the lexer entirely
  above that size, because its char-by-char masking is itself quadratic in
  a single line's length under mawk (~118s for a ~3MB one-line script) —
  the script passes through unscanned. Enforcement sits at the script
  boundary because workflow-internal spawns are not reliably
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
- **`tier-reconcile`** — the SessionStart + PostModelSwitch + ConfigChange
  (matcher `user_settings`) hook. Contract: purge legacy vars first
  (always); then stop if pinned, `.model` empty, or off-ladder; else derive
  the trio from `.model` (or from stdin's `to_model`, when PostModelSwitch
  supplies one, in preference to `.model`) and rewrite executor.md/scout.md
  `model:` lines **only on diff**. Never touches `.model`. Silent on stdout
  (its stdout would otherwise be injected into whatever triggered the
  hook). Idempotent and fast. Only reads stdin when not a tty, so a manual
  run never blocks.

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

**`/advisor` coupling:** the template ships **no** `advisorModel`, which is
the CLI's "No advisor" state — the advisor resolver treats any falsy value
as off, the picker shows "No advisor" when the key is unset, and
`/advisor off` clears the key rather than writing a sentinel (there is no
`"none"` value). Turn an advisor on per session with `/advisor`. Nothing in
`scripts/` or `config/` reads or writes the key, so it stays off across
`/tier` changes. If you do pin one — `settings.local.json` is the layer
that survives a rebuild — it must be **≥ the session's main model** or
`/advisor` is rejected: a pin at `opus` under `/tier fable` fails visibly.

### Named workflows: recon-fanout, verify-contracts (added 2026-08-30)

Two plain-JS scripts under `.claude/workflows/` are the worked examples
for writing a `workflow-lint`-clean Workflow script — both `export const
meta` as a pure literal (`name`/`description`/`phases`) and set an
explicit `model:` on every `agent()` call, so a `Workflow` invocation of
either passes `workflow-lint` without needing a `/* workflow-lint:
model-ok */` annotation. Per the Workflow docs (code.claude.com/docs/en/
workflows): a script's invocation input arrives as a top-level `args`
global, not a function parameter — there is no exported entry point
besides `meta` — and `phase()`/`pipeline()`/`log()` are the other
confirmed script-scope globals alongside `agent()`; `import()` inside a
script is rejected before the run starts. Both scripts here guard their
whole body in `if (typeof args !== 'undefined')`, which does double duty:
it's how a script with no invocation args is a no-op, and it keeps a
plain Node `import()` of the file (e.g. `tests/workflows.bats`'s
meta-shape check, which loads the module to inspect the real `meta`
export rather than grep for it) side-effect free, since `args` is a
genuinely undeclared global outside the Workflow tool. `model:` on each
`agent()` call is confirmed independently of the docs page: workflow-
spawned sidecars observed under `subagents/workflows/*/agent-*.meta.json`
carry real `model` values (see *Model-selection mechanics* in
`knowledge-base/TRANSCRIPT_FORENSICS.md`) — `phase:` as a **per-call**
`agent()` option is not independently confirmed the same way (the docs
example shows `phase()` as its own call grouping subsequent agents by
title instead), so both scripts call `phase('Recon')`/`phase('Verify')`
once per the confirmed mechanism *and* keep `phase:` in each call's own
options, belt-and-suspenders.

- **`.claude/workflows/recon-fanout.js`** — args `{questions: string[],
  glob?: string}`. Fans the questions out to one **scout-grade**
  `agent()` call per question (`model: 'haiku'`, `phase: 'Recon'`), run
  in parallel via `pipeline()`, each returning a schema-typed result:
  concrete `file:line` findings, or an explicit `negative: true` when the
  honest answer is "found nowhere" rather than a guess. This is the
  scriptable form of spawning several parallel `scout` agents for
  independent recon questions (see the delegation protocol in
  CLAUDE.md) without a separate `Agent` call per question.
- **`.claude/workflows/verify-contracts.js`** — args `{beads:
  [{id, redAt, greenAt}, ...]}`. Runs one **verifier-grade** `agent()`
  call per bead (`model: 'fable'`, `phase: 'Verify'` — the explicit top
  alias, standing in for the `model: inherit` a checker agent frontmatter
  uses, since a workflow script has no frontmatter to inherit from),
  each working the bead's pre-registered contract through the five
  mechanical checks (C1-C5) plus C2b from
  `knowledge-base/ACCEPTANCE_CONTRACTS.md` and returning one of `PASS` /
  `FAIL` / `TAMPERED` / `NO-CONTRACT` with per-check evidence.

Neither script calls `Date.now()`, `Math.random()`, or `new Date()`
anywhere — a workflow script's whole point is a reproducible, reviewable
plan, and a hidden wall-clock or RNG dependency undermines that the same
way it would in a test fixture (see the two-clocks lesson: a hardcoded or
ambient-clock value that looks stable in one run is a time bomb in the
next). `tests/workflows.bats` is the acceptance suite for both files.

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

**Billing mode: API vs subscription (2026-07-29).** The same install runs
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
sandbox config dir's `~/.claude/projects/` (47 top-level transcripts, ~110
files with subagents, ~21 MB): cold run 0.055s, warm run 0.014s. A corpus
with nothing to report (no live transcripts on disk AND no lifetime
history in scope, see below) prints a message to stderr and exits nonzero
rather than crashing; the aggregate is otherwise NOT fail-silent, like
every `--report` mode. Test-only override: `COST_MIRROR_PROJECTS_DIR`
replaces `~/.claude/projects` as the root the aggregate scans.

**Durable lifetime rollup (added 2026-07-30).** Transcripts get deleted
(disk-cleanup, manual pruning), which used to silently erase their spend
from every future aggregate report. Both the hook (for the live session)
and the aggregate report path now write each session's rows into
`lifetime.json` in the state dir — schema-versioned like the other state
files. Since 2026-08-26 (`beads_claude_docker-8dg`) those rows are a
**row ledger**: keyed `sessionId|side|model|bucket`, at the same time-bucket
granularity the scan already accumulates (so a session's tier epochs outlive
its transcript instead of being re-derived from a file that may be gone),
and each row carries the five USD/MTok **rates that priced it** — frozen the
first time the row is written, with their provenance — beside its tokens and
dollars. Report-time code reads those rates rather than calling `rates_for`
again, so a price change (e.g. sonnet-5's intro rate lapsing at
`SONNET5_INTRO_CUTOFF`) prices new rows only and never re-prices history; a
`LIFETIME_VERSION` 3 file is migrated in place to legacy rows marked
`pricing_source: unknown`, never back-filled with rates they were not priced
at. Writes are **REPLACE, never
increment**: every existing row for a session_id is dropped before the
freshly (re)scanned rows are written back in, so rescanning the same
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
are explicitly the orchestrator's seat per CLAUDE.md's "Complexity Router
— Lanes" (deep-lane plan-first clause) and the harness's own auto-memory
mechanics, never the executor's. The
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

**Compaction re-reads the rulebook; no PreCompact restatement is needed
(beads_claude_docker-mcuw).** Per the official docs, `SessionStart`'s
matchers include `compact` (so `tier-prime` re-runs after every
compaction) and `/compact` re-reads `CLAUDE.md` from disk. `scripts/
tier-prime.sh` prints the same short trio-line-plus-rulebook-pointer at
SessionStart only; the PreCompact hook entries that used to restate a
dispatch table and a standing-authorization sentence are deleted — that
text now lives once, in the rulebook itself. `config/claude-user-
memory.md`'s invariants still say a compaction does not revoke the
standing authorization; it just no longer needs a hook to say so twice.

## delegation-gate operational reference

Full text moved here from CLAUDE.md's "Model Tiering & Delegation" (kept
verbatim because the `DELEGATION_GATE_WARN_AT` env var name specifically
wasn't otherwise spelled out above, even though its default behavior was):

> Spawn-time enforcement (all fail open, `tests/tier-hooks.bats`):
> `tier-gate` injects the worker tier into generic spawns that omit
> `model`; `workflow-lint` denies workflow scripts whose `agent()` calls
> omit `model:`; `cost-mirror` shows per-prompt spend, now with per-model
> dollars, estimated tier savings, and a drift clause read from
> `delegation-gate`'s own state (`tier-cost` prints the full per-model
> table). An explicit `model` always wins. `delegation-gate` (PreToolUse,
> fail-open, `tests/delegation-gate.bats`) separately counts consecutive
> main-loop inline work-tool calls — subagents are never gated. Mode is
> two-axis, default **`guard`**: `off` (silent allow) · `warn-only`/`warn`
> (nudges, never denies) · `guard` (Edit/Write/NotebookEdit denied in the
> main loop unless carved out; reads/Bash never denied) · `enforce` (guard
> plus reads/Bash denied once streak reaches `DELEGATION_GATE_DENY_AT`,
> default 8) — set via `DELEGATION_GATE_MODE` or
> `~/.claude/delegation-gate.mode`; an unrecognized value falls back to
> `guard`, never a weaker one. The warn note repeats (watermarked, not
> one-shot): first fires at streak `DELEGATION_GATE_WARN_AT` (default 4),
> then every `DELEGATION_GATE_WARN_EVERY` (default 8) — 4, 12, 20 …,
> escalating wording at 2×/6× warn_at — because a warn that fires once per
> session stops steering a session that ignores it. Edit/Write under
> guard/enforce is carved out for the orchestrator's own seat —
> `~/.claude/plans/**` and the harness auto-memory dir — proven from an
> explicit path or denied; `/tmp` and the scratchpad are deliberately not
> carved out. Session-close/verification Bash (`bd`, `git` incl.
> commit/push, `bats`, `run-tests`, `take-screenshot`, …) is exempt
> throughout. `scripts/tier-prime.sh` owns the tier-reminder wording for
> SessionStart (compaction already re-runs SessionStart and re-reads
> CLAUDE.md, so no separate PreCompact restatement is needed —
> beads_claude_docker-mcuw).

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

- top: `<requested>` → `opus` → `sonnet` → `haiku`
- worker (explicit form): `<requested>` → `sonnet` → `haiku`
- recon (explicit form): `<requested>` → `haiku`

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
tier[top] falling back -> opus
tier bound  top=opus  →  worker=sonnet  recon=haiku  (worker/recon derived from the top)
→ run  /model opus  to move THIS session's model now — new sessions pick everything up automatically.
```

(Fable 5.1 is an active model — do not assume it is unavailable.)

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
- Spawn **one verifier per evidence surface, not per finding** — every claim
  from one worker's slice that the same files, the same diff, and the same
  test run settle, bundled into one spawn. Isolation is a property of the
  spawn boundary, not the claim count: eight claims folded into one verifier
  still return exactly ONE verdict block to the orchestrator — strictly
  less context than eight separate returns. Measured here:
  $0.198/sub-claim bundled across 58 sub-claims in 8 spawns, vs. $0.32-0.55
  for a solo per-claim check — unbundling as the old wording prescribed
  would have cost 1.6-2.8x more. Never bundle claims from DIFFERENT
  workers, and never bundle a claim that depends on another claim's fix.
  The same batching applies across beads, not just across claims within
  one: one verifier run may cover several beads sharing an evidence
  surface — batch them; verifiers are per evidence surface, never per
  bead.
- The verdict set is `CONFIRMED`/`REFUTED`/`PARTIAL`/`INCONCLUSIVE` — the
  verifier returns a per-claim **Ledger** line plus the rollup verdict, not
  a transcript. `PARTIAL` (some numbered claims hold, others don't or
  couldn't be settled) is a first-class verdict, not a soft CONFIRMED:
  anything short of CONFIRMED blocks "done" until the caller either
  requeues the verdict's Carry-forward list into the next slice spec or
  waives it in writing.
- **Proportionate:** skip only on trivial/self-evident results; require it
  wherever a wrong-but-plausible result would propagate.

## Complexity Router (lanes)

**When to use:** the tier system answers *which model* does a piece of
work; the router answers *how much process the prompt gets at all* — and
whether anything is spawned in the first place. Read this when a trivial
request just cost a plan, a bead, an executor and a verifier, when the
express lane is being declared for work that clearly isn't express, or
when you need to tune the balance against the declaration log rather than
against vibes.

### The problem

Every prompt used to get the full-court press: top-tier deliberation, a
dispatch line pushing delegation, plan-before-code, an executor slice, an
acceptance contract, verifier sign-off, a review cycle. "Change the
background to blue" cost the same ceremony as "redesign the sync layer".
The tier machinery made each *unit* of that ceremony cheaper without ever
asking whether the ceremony was warranted.

A second failure mode compounds the first (user-identified 2026-08-11):
**scope inflation** — the session and its agents answer a harder question
than the one asked. They investigate adjacent code nobody asked about,
return editorial risk flags outside the slice, and that self-generated
extra surface then *justifies* the heavier route. Weight has to be
computed from the request **as asked**, and the scope clause has to bind
the subagents too (`config/agents/{executor,scout,verifier}.md` each carry
one now) — otherwise inflated worker reports simply re-inflate the
orchestrator.

### Design: route first, three lanes

The first action on every prompt is a declaration:
`lane express|standard|deep [--why "…"]`. It is a tiny Bash call, exempt
from the delegation gate (`lane` is in `EXEMPT_BASH_RE`), and it does
triple duty — it makes the route **visible** in the transcript so the user
can redirect immediately, it is the **enforcement key** delegation-gate
reads, and it is the **measurement** record.

| lane | rubric shape | process it buys |
|------|--------------|-----------------|
| **express** | ALL of: ≤1 file (or none); mechanical/cosmetic, or answerable from context or one lookup; no design choice; trivially reversible; no new dependency/interface/contract | inline now, ≈5 tool calls — no plan, no bead, no executor, no verifier; verify with one run/screenshot when observable, else the diff |
| **standard** | one well-understood slice, low-to-moderate risk, no architectural choice | one-sentence approach, then inline or ONE executor slice; verify by running the result once; no acceptance contract or verifier unless the claim is contested |
| **deep** | ANY of: ≥3 files or an interface/schema/config contract; multiple approaches with real tradeoffs; ambiguity needing interpretation; hard to reverse; security or data-integrity surface; thoroughness asked for. Recon breadth is not implementation depth: many files read with ≤2 files changed routes standard — scouts deliver deep-grade evidence in any lane. | the full protocol above: plan, beads with CHECK/PASS-IF contracts, executor slices, verifier sign-off — one verifier run may cover several beads sharing an evidence surface, batch them; verifiers are per evidence surface, never per bead |

The lanes **scope the rest of this doc's protocol** rather than sitting
beside it. "Trust, but verify" above is written as an unqualified mandate
with a proportionality escape hatch; read through the router, that mandate
is the **deep lane's** — plus any contested or risk-bearing claim in a
lighter lane. Express verifies with one observation and no verifier agent;
standard runs the result once. Same for the acceptance-contract protocol
(CHECK/PASS-IF/RED-AT/GREEN-AT): deep lane and contested claims, not every
non-trivial claim.

The table is a **summary, deliberately not the source**. Doctrine sprawl
was itself one of the bugs found: the old dispatch wording lived in four
places at once. `lane --prime` is now the single authoritative home for
the routing text (exactly as `tier-prime` owns the tier trio wording), and
every other site — the UserPromptSubmit echo, SessionStart, `CLAUDE.md`
— prints or references it instead of keeping a copy (PreCompact no
longer calls it at all: beads_claude_docker-mcuw removed that hook
entirely). Run
`lane --prime` for the binding wording; treat any divergence from it,
including this table, as the copy being stale.

Three rules do the real work of keeping the light lane both reachable and
safe:

- **Ties go to the lighter lane, with one-way tripwires.** When the lane
  is genuinely arguable, take the lighter one — but scope outgrowing the
  rubric, a first fix attempt failing, hidden ambiguity surfacing, or
  unexpected test breakage each escalate **exactly one lane**
  (`lane <heavier> --why "…"`), announced in the reply, and never
  de-escalated within the same prompt. The no-thrash rule is what makes
  the optimistic default safe: mis-routing down costs one escalation, not
  a wrong answer. When genuinely unsure between standard and deep, declare
  standard — tripwires self-correct upward mid-prompt; over-routing has no
  correction path.
- **Scope discipline is part of the rubric, not a style note.** Classify
  and answer the request as asked, never its maximal interpretation. An
  adjacent issue noticed mid-task gets one line at most, never
  investigation — and noticing one is explicitly **not** a tripwire. Only
  the asked task's own needs escalate.
- **Transparency and override.** The lane line is in the transcript;
  "quick"/"just" bias light, "plan"/"thorough"/"audit" force deep, and an
  explicit user constraint beats every rubric line.

### Mechanism

`scripts/lane.sh` → `/usr/local/bin/lane` owns the state and the wording;
`scripts/delegation-gate.py` reads the state; `scripts/tier-prime.sh`
re-injects the wording. Nothing else in the chain knows the rubric text.

- **State** lives at `$LANE_STATE_DIR` (default `~/.claude/cache/lane`),
  one `<session_id>.json` per session holding `{lane, prev, why, ts,
  escalated}`, plus `log.jsonl` and a `last-session` file. Session id
  resolution has two paths, which is why `last-session` exists: the
  `--reset` hook takes the id from the **hook JSON on stdin** and records
  it there, while a plain CLI declaration reads `CLAUDE_CODE_SESSION_ID`
  and falls back to `last-session` when the env var is absent (grep
  `resolve_sid`). With neither available, `lane` prints "no session id —
  lane not recorded" and exits 0 rather than guessing.
- **`lane --reset` is the first UserPromptSubmit hook**, ahead of
  tier-reconcile and cost-mirror, so a stale `express` from the previous
  prompt can never leak into the next one. Reset writes `lane: "unset"`
  (carrying the previous value in `prev`) and appends **nothing** to
  `log.jsonl` — the log records declarations only.
- **delegation-gate express behavior** (grep `KNOWN_LANES`, `get_lane`):
  under express, main-loop `Edit`/`Write`/`NotebookEdit` are allowed in
  every mode and the `enforce` read/Bash streak-deny is suspended —
  denying the one edit an express task consists of would cost more than
  the edit. The streak is still counted, and past `EXPRESS_WARN_AT` (6)
  a *different* warn fires, repeating every `EXPRESS_WARN_EVERY` (4):
  express tasks are small by definition, so a long grind under express is
  the mis-route signal, and the warn says "escalate or finish" rather than
  the ordinary "go delegate" nudge, which would tell the session to do the
  opposite of the lane it declared. The watermark is shared with the
  delegation nudge so escalating mid-prompt cannot double-warn. Every
  other value — `standard`, `deep`, `unset`, an unreadable file, a lane
  name the gate doesn't know — reads as `unset` and yields **exactly** the
  pre-router behavior: the same never-weaker principle as `get_mode()`'s
  fallback.
- **Re-injection.** `tier-prime.sh` calls `lane --prime` at SessionStart
  only (beads_claude_docker-mcuw: `--full` now produces byte-identical
  output to the bare form, and the PreCompact hook entries are deleted —
  SessionStart's matchers already include `compact`, and `/compact`
  re-reads `CLAUDE.md` from disk, so a compaction cannot silently launder
  the router out of context without a second injection site). The call is
  guarded by `command -v` (grep `lane_prime`): on an image built before
  `lane` existed it prints nothing and the hook still succeeds.
- **Measurement.** Each declaration appends a row to `log.jsonl` with
  `escalated: true` when it outranks the same prompt's previous lane. The
  log is self-bounding — past 5000 lines it is truncated to the newest
  2500. Everything in `lane` fails open by construction: `jq` and
  `python3` are both optional, and every branch exits 0.

### Evidence base (researched 2026-08-11)

The design is assembled from what the published routers got right, minus
the one that failed publicly:

- **RouteLLM** (LMSYS): a learned win-rate router held **95% of
  strong-model quality at 14–26% of strong-model calls**. **FrugalGPT**:
  cheapest-first cascade with a scoring judge, **up to 98% cost cut**.
  **HybridLLM**: an upfront difficulty classifier, **~40% fewer
  strong-model calls at no quality drop**. Upfront classification beats
  cascades when the difficulty signals are good, which for coding tasks
  they are.
- **Cursor's router** promotes to a pricier model only on a one-sided
  **75%-confidence uplift** bar over the cheapest capable model — the best
  anti-over-routing mechanism found, and the ancestor of "ties go to the
  lighter lane".
- **GPT-5's router** is the canonical failure: **silent under-routing** of
  hard prompts to the fast model, unrecoverable because there was no
  escalation path and no visibility into the route, which forced public
  walk-backs. Its three lessons are load-bearing here — show the route,
  allow override, make escalation cheap.
- **Aider's architect/editor split and Claude Code's `opusplan`** are
  static two-tier splits: expensive model plans, cheap model edits. That
  is the tier system this doc already describes; the router adds the lane
  *below* it, where the right amount of work is none.
- **Why the classifier is the orchestrator and not a hook.** The main
  session's model and effort are **fixed per turn** — only `/model`,
  `--model`, env or settings move them, and a UserPromptSubmit hook can
  only inject context or block. Community "Claude Code router hooks"
  (regex-classify the prompt, claim to auto-switch the session model) are
  therefore overclaiming a lever that does not exist. What a hook *can* do
  is exactly what ours does: reset state, inject the rubric, and enforce
  the declaration. Meanwhile the strongest model in the system is already
  reading the prompt, so having it classify against an **objective
  task-shape rubric** (files touched, ambiguity, reversibility,
  orchestration need) costs ~zero and is a far better signal than regex —
  and, importantly, is not LLM *self-confidence*, which the same research
  finds unreliable as a difficulty signal.

### Tuning knobs

| knob | where | what it does |
|------|-------|--------------|
| **escalation rate** | `log.jsonl` (`"escalated":true` ÷ total rows) | the primary health metric; target **5–15%** |
| `EXPRESS_WARN_AT` / `EXPRESS_WARN_EVERY` | `scripts/delegation-gate.py` (6 / 4) | how long an express grind runs before the mis-route warn, and how often it repeats |
| `LANE_STATE_DIR` | env, read by both `lane` and the gate | redirects state — the seam the bats suites use to avoid touching live state |
| the rubric thresholds themselves | `lane --prime` in `scripts/lane.sh` | e.g. the express file count; the last thing to change, and only against log data |

Read the two failure directions off that rate. **Persistently under 5%**
means the classifier is routing too heavy: express is never being tried,
so it never needs correcting — the symptom on the ground is executor
spawns for one-line edits and plans for questions. **Over 20%** means
express is too greedy: the symptom is repeated mid-prompt escalations and
express warns firing at streak 6+, and the fix is tightening a rubric
threshold, not raising the warn constants (which would only hide it).
Lazy always-express drift is the risk worth watching most, since it is the
one that trades quality for cost silently; the express warn, the lane
distribution, and `bead-auditor` on the standard/deep side are the three
independent checks against it.

Compute the rate straight off the log:

```bash
L=~/.claude/cache/lane/log.jsonl
echo "$(grep -c '"escalated":true' "$L") escalations / $(wc -l < "$L") declarations"
```

`cost-mirror` reads the same log on two surfaces, so the rate is usually
already in front of you. The per-prompt line ends with **`lane last-turn:
<x>`** — "last-turn", not "current", because `lane --reset` runs earlier in
the same UserPromptSubmit chain, so the state file already reads `unset` by
the time the cost line renders and the log is the only honest source.
`tier-cost` grows a **lanes section** beneath the table: per-lane
declaration counts for this session and all-time, the escalation count, and
the rate annotated with the target band above. Both fail open — a missing
log omits the lane surface rather than printing a zero that would read as
"the router ran and never escalated".

### What is verified, and what isn't

**Script-level chain verified 2026-08-11**, running the working-tree
copies by path with state redirected away from live:

```bash
export LANE_STATE_DIR=$(mktemp -d); SID=chain-001
echo "{\"session_id\":\"$SID\"}" | bash scripts/lane.sh --reset
CLAUDE_CODE_SESSION_ID=$SID bash scripts/lane.sh express --why "chain check"
P="{\"session_id\":\"$SID\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"<project>/src/thing.py\"}}"
printf '%s' "$P" | DELEGATION_GATE_MODE=guard python3 scripts/delegation-gate.py   # allow
CLAUDE_CODE_SESSION_ID=$SID bash scripts/lane.sh standard --why "escalate"
printf '%s' "$P" | DELEGATION_GATE_MODE=guard python3 scripts/delegation-gate.py   # deny
```

Observed: reset wrote `{"lane":"unset","prev":"unset",…}`; the express
declaration echoed `[lane] express — inline, no ceremony — chain check`
and the gate produced **no output, exit 0** (allow); after
`lane standard`, which echoed `(escalated from express)`, the identical
payload produced the `[delegation-gate guard] Implementation edits are the
executor's seat…` deny JSON. `log.jsonl` held two rows, the second with
`"escalated":true`, and the reset added none.

**Live-hook behavior is not verified and cannot be from a running
session:** hooks execute the **baked** `/usr/local/bin` binaries, so the
UserPromptSubmit reset, the SessionStart/PreCompact injection, the gate's
in-session lane awareness and cost-mirror's `lane last-turn:` tag only take
effect after a host-side image rebuild. (`tier-cost`'s lanes section is the
exception — it runs the staged binary from a terminal, not a hook, so it
lands as soon as the staged copy is refreshed.) Until then the chain above (working-tree copies, explicit
`LANE_STATE_DIR`) is the strongest available check — the same
staged-artifact staleness trap documented in `CONFIG_SYNC.md`.

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

- **2026-09-02 — advisor pin removed (advisor off by default):**
  `config/claude-settings.json` dropped `advisorModel: "opus"`. An absent
  key is the CLI's "No advisor" state (2.1.258: the picker renders
  "No advisor" when the value is unset, the resolver returns no advisor for
  any falsy value, and `/advisor off` clears the key — there is no `"none"`
  sentinel), so every config sync had been handing back an Opus advisor the
  user then cleared by hand. `tests/smoke.bats` now asserts the key is
  absent; the `/advisor` coupling paragraph above was rewritten. Layer 2
  (`/etc/claude-dev/configs/claude-settings.json`) was live-patched the same
  day so the change took effect without waiting for a host rebuild.
  Rollback = re-add the key (and it must be ≥ the session's main model).

- **2026-08-26 — lane rubric: ties-go-lighter teeth, recon-breadth
  clarifier, verifier batching (bead beads_claude_docker-epe):**
  `scripts/lane.sh`'s `--prime` rubric gains two lines — "declare standard"
  when genuinely unsure (tripwires self-correct upward; over-routing does
  not), and "recon breadth is not implementation depth" (files a scout
  reads don't count toward the deep-lane file threshold, only files
  changed do). `CLAUDE.md` and `config/claude-user-memory.md` carry the
  same two insertions in their lane rubric prose, plus a third: verifier
  runs batch by evidence surface across beads, never one per bead — this
  doc's lane table and "Trust, but verify" section gain the same batching
  line. Evidence: `log.jsonl` showed 9 of 21 routed prompts declared deep
  with zero mid-prompt escalations (the 5–15% escalation-rate target above
  implies routing sits above actual need — a lane that never escalates
  down was arguably never deep), and verifier spawns were tracked running
  roughly 1:1 against executor sessions, i.e. one verifier per bead rather
  than per evidence surface. Also fixed in passing: `config/claude-user-memory.md`'s
  deep-lane row previously read "1 `verifier` per bead", contradicting the
  "per evidence surface" model documented everywhere else in this file —
  corrected to "per evidence surface" so the new "never per bead" clause
  isn't self-contradictory in the same cell. Rollback = revert
  `scripts/lane.sh`, `CLAUDE.md`, `config/claude-user-memory.md`, and this
  doc; `lane.sh` fails open, so a partial revert degrades to the
  pre-change rubric text rather than breaking the hook.
- **2026-08-11 — complexity router (lanes):** `scripts/lane.sh` added (state,
  log, and the single home of the rubric wording) plus `tests/lane.bats`;
  `scripts/delegation-gate.py` gains lane awareness (express carves out the
  Edit/Write denial, an unknown lane falls back to guard, the express-grind
  warn) with cases in `tests/delegation-gate.bats`;
  `config/claude-settings.json` wires `lane --reset` into UserPromptSubmit
  ahead of the tier reconciler and sources the dispatch tail from `lane`;
  `scripts/tier-prime.sh` injects the short rubric at SessionStart and the
  full one at PreCompact; doctrine edits in `CLAUDE.md`,
  `config/claude-user-memory.md` and `config/agents/*.md`; this doc gains the
  Complexity Router chapter; `scripts/cost-mirror.py` joins the declaration
  log (per-prompt `lane last-turn` tag, `tier-cost` lanes section) with cases
  in `tests/tier-hooks.bats`; `Dockerfile` stages the new script. Rollback =
  revert those files and remove the settings entries; every piece fails open
  if `lane` is absent, so a partial revert degrades to the pre-router
  behaviour rather than breaking a hook.
- **2026-08-10 — advisorModel fable→opus:** `config/claude-settings.json`
  `advisorModel` flipped from `"fable"` to `"opus"` to match the default
  `.model`; `tests/smoke.bats` ("claude-settings.json pins the advisor at
  or above the top tier") retargeted to assert `== "opus"`; this doc's
  `/advisor` coupling paragraph rewritten for the new pin. Rollback =
  revert those two files; the layer-2 staged copy at
  `/etc/claude-dev/configs/claude-settings.json` needs a matching `cp` (or
  an image rebuild) to pick it up.
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

## Consults: native advisor vs oracle (decision 2026-08-30)

Claude Code's native advisor tool (`/advisor`, `advisorModel`, ≥2.1.170, Fable-capable) covers the oracle's mid-task consult role — but it is Anthropic-API-only, so on this sandbox's OAuth/subscription sessions it is unavailable. Decision: **oracle remains the consult path here** (fresh-context, user-invoked, panel-capable); revisit if the install moves to API auth. `advisorModel`, where used, must stay ≥ the session's top tier.

## Hook-trigger migration (beads_claude_docker-v4p)

`tier-reconcile` used to run on every UserPromptSubmit because Claude Code 2.1.247 had no model-change event. Claude Code 2.1.251 added `PostModelSwitch` (fires after `/model`, `/fast`, `--model` at startup, or an automatic switch; stdin carries `from_model`/`to_model`/`triggered_by`) and `ConfigChange` (fires on a config-file change; stdin carries `config_source`/`changed_keys`) hooks; `tier-reconcile` is now registered on both instead of the per-prompt run, with SessionStart kept as the floor case. ConfigChange is matched to `user_settings` only. **Residual risk:** an install still running Claude Code < 2.1.251 reconciles only at SessionStart — a `/model` change mid-session won't refresh the executor/scout bindings until the next session starts.
