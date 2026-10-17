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
| `headless` | a detached `worker-run` process started by `dispatch <bead>`, in its own git worktree | `claude:<alias\|id>` · `openrouter:<vendor/model>` (through `opencode`) · `codex:<id>` · `gemini:<id>` | worker (executor) slices |
| `subagent` | the in-process Claude Code Agent tool        | Anthropic ids only                                                       | recon, checkers, and the worker fallback |

(Until 2026-10 the first row was `orca`, a supervised Orca worker terminal;
a `tier.json` that still says `orca` is read as `subagent` for a Claude
agent and `headless` for any other, and is never written back.)

Defaults: nothing probes for a runtime any more — a role is `headless` when
bound so by name (`/tier worker openrouter:…`, `claude:…`, `headless`) or,
for the worker, when the folder holds an OpenRouter key; the **worker
vendor** is decided by that key — with one present (the
file `claude-dev key openrouter` writes) the derived worker is `opencode` on
`openrouter/~z-ai/glm-latest`, the default GLM executor; without one it is
`claude:<derived worker rung>`. **Recon = `subagent` haiku** and **checker = `subagent`
at the derived checker rung** (the top capped at opus), both in-process on
purpose — recon is cheap and read-only, and a checker never grades a claim
from below the worker that made it. A **headless recon** (the hybrid
presets' `luna@high`, or `/tier recon openrouter:<model>`) is asked with
`recon "<question>"` instead of a spawn — a headless, read-only
`opencode run` on the recon model in the project's working tree: no bead,
no worktree, the answer on stdout, the cost in the delegate ledger.
`tier-gate` denies a model-less `scout` spawn there with
`recon "<question>"` as the reason; an explicit `model` on the spawn is
the in-process fallback. `/tier worker openrouter:qwen/qwen3-coder`,
`/tier worker claude:sonnet` or `/tier worker subagent` rebinds the worker
seat, and **`/tier recon openrouter` puts recon on the flash-class rung**
(`openrouter/~z-ai/glm-flash-latest` run by `opencode` on the headless backend) —
the bare `openrouter` spec takes the role's own OpenRouter default, so the
same word means the full-size GLM for the worker and the flash sibling for
recon. The matching delegate routes are `glm-flash` and `deepseek-flash`,
both `grade: scout` (`config/delegate-routes.json`); see *tier.json* below for the file all of this is read from. Every
OpenRouter call from the VM goes through the residency guard — GLM is fine,
a China-hosted GLM is not, and the rule (served only in the US, Canada or
Europe) plus the default Fable + GLM stack are in
`knowledge-base/DATA_RESIDENCY.md`.

### OpenAI subscription (ChatGPT sign-in) (2026-10-02)

A second opencode provider beside OpenRouter: the user's own ChatGPT
subscription, signed in with opencode's own login. There is no guard and no
key file on this path — the credential lives in opencode's auth store
(`${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json`), opencode
refreshes its own tokens, and requests go straight to OpenAI (the residency
story is in [DATA_RESIDENCY.md](DATA_RESIDENCY.md)).

**Grammar.** `/tier worker openai:<family|id>` (or `recon …`) binds the
subscription: backend headless, agent opencode, model `openai/...`. A bare
`openai` binds the role's default — the newest balanced **GPT Terra**
executes (`openai/~gpt-terra-latest`), the newest efficient **GPT Luna**
recons (`openai/~gpt-luna-latest`). The distinction rule: **no `openai:`
prefix means OpenRouter** — `luna` and `openai/gpt-5.6-luna` (slash) both
name OpenRouter's copy of the model, while `openai:gpt-5.6-luna` (colon)
names the subscription's. An `@<effort>` suffix rides along as everywhere
else and reaches opencode as its own `reasoningEffort` key for provider
openai (OpenRouter's `reasoning.effort` does not apply). Launches go through
the same one writer (scripts/lib/opencode-launch.sh) OpenRouter dispatches
use; an `openai/` launch carries no guard env at all — opencode's own login
supplies the credential, so the env file holds only the config path.

**Family aliases resolve at launch.** `openai:luna` binds the alias
`openai/~gpt-luna-latest`; when a worker actually starts,
`tier_openai_resolve` (scripts/lib/tier-roles.sh) resolves it to the newest
id of that family the subscription serves — highest `release_date`, then the
shortest id (`gpt-5.6-luna` beats `gpt-5.6-luna-fast`). Like OpenRouter's
`~-latest` aliases these name a family, not a version, so a release needs no
re-bind — but OpenAI publishes no redirect of its own, so the resolution
happens at launch against the live catalogue rather than server-side per
request. `openai:gpt-5.6-luna` pins one exact id.

**Sign-in and readiness.** `/tier auth openai` prints the one line that runs
`scripts/openai-auth.sh` — run it in a pane of its own (sign-in is
interactive, so it cannot run inside the tool call): opencode's headless device login
(`opencode auth login --provider openai --method "ChatGPT Pro/Plus
(headless)"`); opencode prints a one-time code that is entered in a browser.
The helper reports success only when the auth store actually reads as signed
in, then lists what the subscription serves. Readiness (`tier_openai_ready`)
is that auth store carrying an `openai` entry with a non-empty refresh token
(or an API key). An unsigned folder still *saves* an `openai:`/`openai/`
binding; what refuses to run is the launch — `dispatch` dies with
"run /tier auth openai" (exit 2), and `recon` takes the same exit-3 "spawn a
scout" fallback it takes when the OpenRouter guard is down.

**What the subscription serves.** `/tier models openai` lists the families
with each one's newest-resolved pin and every bindable id (from
`opencode models openai` when signed in, opencode's own cache when not).
One filter to know: opencode's model list drops `gpt-6-luna` and
`gpt-6-sol` today even though models.dev lists them, so the catalogue
`/tier` binds against is what the subscription actually serves, not
models.dev.

**Known race.** Two opencode processes that find the access token expired
at the same instant both spend the same refresh token; OpenAI rotates
refresh tokens, so one of the two can fail its refresh and needs
`/tier auth openai` again.

### The dispatch loop

One bead, one worker, one receipt. Until 2026-10 this ran through Orca
(`orca-dispatch`, `orca-wait`, `orca-reply`, worker terminals); it is now a
plain detached process plus files under `.claude-dev/run/`:

```
dispatch <bead-id> [--worker|--checker] [--agent claude|opencode] [--model <id>]
         [--worktree new|main|path:<dir>]   # spec from the bead + WORKER RULES, worker started
workers wait [--until <s>]         # reader: print+consume orchestration/inbox.jsonl;
                                   #   --until blocks <=s s (exit 4 on silence)
workers reply <job> "<answer>"     # resumes a worker that asked instead of guessing
workers list                       # one row per job: bead, agent:model, state, elapsed
workers tail <job> | workers stop <job>
verifier                           # fresh context, against the bead's own contract
```

- **`dispatch`** reads the bead (`bd show`), composes the spec (title,
  description, acceptance contract, the `WORKER RULES` block), fills agent,
  model and effort from the role's binding in `tier.json` unless a flag names
  them, makes the worktree (`new` = `~/worktrees/<bead>` on branch
  `work/<bead>` cut from main; an existing one is reused), writes
  `run/workers/<job>/{spec.md,job.json}`, starts `worker-run` on it detached
  and prints one JSON receipt line on stdout. It returns at once.
- **`worker-run`** runs ONE turn: it waits for a free slot (at most
  `maxWorkers` turns at once, default 3), runs `claude -p` or `opencode run`
  in the worktree, writes `receipt.json` (session, tokens, usd, changed
  files, final message), sets `job.json` to `done`, `question` (the final
  message ends with a `QUESTION:` line) or `failed`, notes `WORKER_DONE` on the
  bead and appends one line to `run/orchestration/inbox.jsonl`.
- **`workers wait`** keeps the poll loop out of the orchestrator's turns:
  bare, it prints and consumes the unread inbox lines (cursor in
  `inbox.cursor`); `--until <s>` blocks at most `s` seconds — run it in the
  background so a worker message wakes you through a task notification. A
  running job whose log has not grown for 600 s gets one `stalled` line.
  A `question` lands in the inbox for you to answer with `workers reply`.
- **A `worker_done` is a claim, not a verdict.** The bead closes after a
  `verifier` run against the pre-registered contract, never on the worker's
  own say-so.

### WORKER RULES — what every dispatched worker is told

`dispatch` appends the same block to every spec, which is why a worker on a
foreign vendor's model still behaves like one of ours: do not delegate or
start further workers; work only in the given worktree; do not close the bead
and never write a `VERIFIED` line; verify by running the real thing and
report the command and output; on a contract, commit the test RED first
(`RED-AT`) then the implementation (`GREEN-AT`) and never edit a FROZEN file;
report once, in the final message; when blocked on a decision that is not
the worker's, end that message with one `QUESTION:` line.

### Parallel by default

The bias is "everything independent runs at once", not "one slice at a time".

- **Waves.** `dispatch --epic <id> [--agent …] [--model …]` (the runner is
  `scripts/dispatch-epic.sh`) takes an epic's open children from bd and
  dispatches every ready one in one wave: a child is ready when each of its
  `blocks` blockers has settled done in this run (or is closed in bd). A
  failed blocker never clears its dependents (`EPIC BLOCKED`). Children
  that name the same file in their text are serialised. It polls each job's
  `job.json`, prints one event line per change and ends with `EPIC READY
  <epic> <branch>`, `EPIC BLOCKED` or `EPIC STALLED`.
- **One worktree per epic.** All slices of an epic share one worktree
  (`~/worktrees/<epic>` on `work/<epic>`), so epics run side by side in
  separate checkouts. The merge stays with the orchestrator, after the
  verifier.
- **Recon fans out freely** — several `scout` spawns in one message
  (subagent backend) or several `recon "<question>"` calls with
  run_in_background (headless backend); no worktree either way.

The pieces are exercised by `tests/workers-dispatch.bats`,
`tests/workers-run.bats`, `tests/workers-cli.bats` and
`tests/dispatch-epic.bats`, with a stand-in for the agent binary.

### Fallback — when the headless backend cannot run, and the explicit-model rule

`recon` exits **3** with "spawn a scout" when the recon role is not
headless+opencode or the guard token is missing, and `dispatch` dies with a
message (exit 2) when a binding cannot run (an unsigned OpenAI binding, say);
nothing is started and the orchestrator falls back to the in-process
`executor` or `scout` knowingly, never silently.

That fallback spawn must carry **an explicit `model`**. `tier-gate` never
blocks a spawn; what it injects depends on the worker's binding. Under a
`subagent` backend, or a `headless` backend whose agent is `claude`, it injects
the bound model (or the rung derived from the top when that model cannot be
ranked) and adds a "prefer `dispatch <bead>`" note. Under a **non-Claude worker
backend** — `opencode` on OpenRouter, `codex`, `gemini` — there is no model
the Agent tool would accept, so the hook only *notes* the backend and injects
nothing: the spawn would run on the orchestrator's own expensive model. So
the orchestrator passes `model=<derived rung>` itself — the second id
`tier-derive <top>` prints, as its family alias (`model: "sonnet"`; the
Agent tool's `model` parameter rejects concrete ids). The same rule keeps the
invariant "expensive tiers never take the worker seat" true on the fallback
path.

### A mixed Run, worked

Two slices of one epic, two vendors:

```
/tier fable                                  # top fable; worker derives per the key (GLM) or rung
/tier worker claude:sonnet                   # rebind the worker seat: Claude Code on the sonnet rung
dispatch epic-42.a --worktree path:~/worktrees/epic-42    # worker 1: claude:sonnet
/tier worker openrouter:qwen/qwen3-coder     # rebind again: opencode on OpenRouter
dispatch epic-42.b --worktree path:~/worktrees/epic-42    # worker 2: opencode
workers list                                 # both rows, both agents
workers wait                                 # (reader) worker_done from b; a question from a
workers reply epic-42.a "yes — keep the old flag name"
workers wait                                 # (reader) worker_done from a
```

Both workers were given the same `WORKER RULES` and the same contract text,
report through the same inbox, and are checked by the same
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

**Billing mode.** `COST_MIRROR_BILLING=api|sub` forces it; otherwise
`detect_billing_mode()` checks, in order: an `ANTHROPIC_API_KEY`/
`ANTHROPIC_AUTH_TOKEN` in the environment -> `api`; `claudeAiOauth.subscriptionType`
in `~/.claude/.credentials.json` (override `COST_MIRROR_CREDENTIALS_PATH`,
tests only) -> `sub`; neither signal -> `api`. Computed at render time only,
never persisted. In `sub` mode the actual-cost figure gets ` API-equiv`
appended and `--report`'s three money-column headers get a trailing `*`;
the savings clause is unchanged (it was already a counterfactual either
way).

**`tier-cost` (alias for `cost-mirror --report`).** Read-only, and NOT
fail-silent: a missing/unreadable/ambiguous transcript exits nonzero. Bare
`--report`/`tier-cost` aggregates by default (2026-07-30) across every
`~/.claude/projects/*/*.jsonl` on disk (plus each one's `subagents/*.jsonl`),
independent of any live session, with its own incremental cache
(`all-sessions.json` in the state dir, keyed by file path) so a warm run
only reads bytes appended since last time; `--since <N>d` narrows the file
set to that window. Output is a per-session table (project dir, short
session id, last-modified date, tokens, actual $) followed by the usual
per-side|model breakdown and grand total. Three flags select a single
session instead of the aggregate: `--report <transcript.jsonl>` (direct
path), `--report --session <prefix>` (matches `sessionId`/filename, fails
loud if ambiguous or no match), `--report --this` (the transcript named in
the newest cost-mirror hook state file). All single-session forms are
read-only with respect to `lifetime.json` below.

**`lifetime.json`.** Deleting a transcript used to silently erase its spend
from every future aggregate. Both the hook and the aggregate report path
now write each session's rows into a durable, schema-versioned row ledger
in the state dir, keyed `sessionId|side|model|bucket`, each row carrying the
five USD/MTok rates that priced it — frozen the first time the row is
written, so a later price change reprices only new rows, never history.
Writes are REPLACE per session, never increment, so rescanning a transcript
any number of times cannot inflate the durable total (the load-bearing
property; tested for byte-identical output across repeated aggregate runs).
The aggregate unions live-scanned transcripts with lifetime rows whose
transcript no longer exists on disk, so a deleted session's spend still
counts toward the grand total; a footnote names how many sessions were
pulled from history. `disk-cleanup.sh`'s three sweep targets never overlap
the cost-mirror state dir, so nothing there needs to survive a sweep by
special-casing it.

**"Saved", precisely — delegation-only, via tier epochs.** Dollars saved
count only work moved to a cheap worker, never the orchestrator itself
dropping tiers mid-session. Each session's main-loop rows are ordered by
transcript `timestamp` and split into **tier epochs** — maximal runs of
consecutive main-loop rows sharing the same `message.model`
(`_epochs_from_main_buckets` in `scripts/cost-mirror.py`, working in
5-minute buckets for state-size reasons). A worker row reprices only
against the epoch its own timestamp falls into; main-loop rows always price
at their own actual rate and can never appear in "saved"
(`session_epoch_pricing` enforces this unconditionally). The first and last
epochs are clamped to the session's edges, so a worker row outside the
main-loop's own timestamp range still reprices against the nearest
orchestrator tier rather than costing zero; the only rows that price at
zero are worker rows with no parseable timestamp in an otherwise-timestamped
session. Epochs are computed and summed strictly per session; an aggregate
`--report` never lets one session's tier reprice another's spend. This is
still always an estimate even within one epoch — a different model would
not have emitted identical token counts — so "saved" means "what these
worker tokens would have cost at the orchestrator's tier at the time," not
a guarantee of what would actually have happened.

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

`scripts/delegation-gate.py` (PreToolUse) counts consecutive
Read/Grep/Glob/Edit/Write/NotebookEdit + non-exempt-Bash calls made by the
**main loop only**, never a subagent — discriminated via `agent_id` (absent
pre-first-spawn, present-but-`null` on main-loop calls after any spawn,
populated only on subagent calls; the more obvious `transcript_path` signal
is a red herring, byte-identical for both). Housekeeping Bash (`bd`,
read/commit-ish `git`, `bats`, `dev-log`, `cost-mirror`, `tier-*`,
`run-tests`, `take-screenshot`) is exempt from counting; `Agent`/`Workflow`
resets the streak to 0. Fails open. Built because instructions alone didn't
move behavior: with the full delegation protocol already live in context, a
headless matrix still ran two of three task shapes 100% inline, and a DENY's
`permissionDecisionReason` was found to reach the model reliably while an
ALLOW's `additionalContext` is harness-dependent (model-visible in
interactive sessions, absent from headless `claude -p` children) — see
`tests/delegation-gate.bats` for the regression cases that finding produced.

**Tuning decision.** Ship the observed defaults — warn at streak 4,
enforce's deny at streak 8. Warn targets interactive sessions, where its
channel demonstrably lands; `enforce` is the user's escalation endpoint and
the only reliable lever for headless children — one env flip away
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
- **`lane --prompt` is the UserPromptSubmit hook**: one process that runs
  `--reset` and then `--prime --short`, so a stale `express` from the
  previous prompt can never leak into the next one. Reset writes `lane: "unset"`
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
<x>`** — "last-turn", not "current", because the lane hook's reset runs in
the same UserPromptSubmit round, so the state file may already read `unset`
when the cost line renders and the log is the only honest source.
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
re-run needed. To roll back live state without a rebuild: revert the file
under `config/` in the folder's own template clone
(`<project>/.claude-dev/template/config/...`, or the repo itself) and
either restart the container or force just that step with `provision run
20-config-sync` — `config-sync` is checksum-gated, so either path picks up
the reverted file on the next boot (see CONFIG_SYNC.md). Note the repo
agent templates carry alias placeholders (`model: sonnet` / `model:
haiku`); the reconciler replaces them with concrete ids on first run.

Revision log (each reversible via git on the listed files):

- **2026-09-02** — advisor pin removed by default: `config/claude-settings.json` drops `advisorModel`; `tests/smoke.bats` asserts the key is absent.
- **2026-08-26** — lane rubric gains "declare standard when unsure" and "recon breadth isn't implementation depth" (`scripts/lane.sh`, `CLAUDE.md`, `config/claude-user-memory.md`), plus a verifier-batch-by-evidence-surface line (also this doc's lane table and "Trust, but verify").
- **2026-08-11** — complexity router (lanes) added: `scripts/lane.sh` + `tests/lane.bats`, lane-aware `scripts/delegation-gate.py`, settings wiring (`lane --reset`/`tier-prime` rubric), lane tracking in `scripts/cost-mirror.py`, doctrine edits in `CLAUDE.md`/`config/claude-user-memory.md`/`config/agents/*.md`, this doc's Complexity Router chapter.
- **2026-08-10** — `advisorModel` flipped `fable` -> `opus` to match the default `.model` (`config/claude-settings.json`, `tests/smoke.bats`).
- **2026-07-29** — delegation gate added: `scripts/delegation-gate.py` + `tests/delegation-gate.bats`, settings PreToolUse entry, dispatch-table wording in `config/claude-user-memory.md`, this doc's Delegation gate section.
- **2026-07-17** — mechanism v2, frontmatter binding (bead dsu): `scripts/tier-set.sh`/`tier-reconcile.sh`/`tier-derive.sh` rewritten, env-slot remap retired and purged, this doc rewritten.
- **2026-07-10 rev 2** — `/tier` slash command: engine moved into `scripts/tier-set.sh`, exposed via `config/claude-commands/tier.md`; `config/.zshrc` thinned to wrappers.
- **2026-07-10 rev 1** — Fable-is-back review: `config/.zshrc`, `config/agents/{verifier,oracle}.md` (`model: inherit`), `config/agents/{executor,scout}.md`, `config/claude-settings.json` (`advisorModel: "fable"`), `CLAUDE.md`.
- **Original introduction** — `config/agents/executor.md`/`verifier.md` added; `scout.md`, `config/claude-settings.json`, `config/.zshrc`, `CLAUDE.md` extended. Base commit `bc5cb028`.

## Consults: native advisor vs oracle (decision 2026-08-30)

Claude Code's native advisor tool (`/advisor`, `advisorModel`, ≥2.1.170, Fable-capable) covers the oracle's mid-task consult role — but it is Anthropic-API-only, so on this sandbox's OAuth/subscription sessions it is unavailable. Decision: **oracle remains the consult path here** (fresh-context, user-invoked, panel-capable); revisit if the install moves to API auth. `advisorModel`, where used, must stay ≥ the session's top tier.

## Hook-trigger migration (beads_claude_docker-v4p)

`tier-reconcile` used to run on every UserPromptSubmit because Claude Code 2.1.247 had no model-change event. Claude Code 2.1.251 added `PostModelSwitch` (fires after `/model`, `/fast`, `--model` at startup, or an automatic switch; stdin carries `from_model`/`to_model`/`triggered_by`) and `ConfigChange` (fires on a config-file change; stdin carries `config_source`/`changed_keys`) hooks; `tier-reconcile` is now registered on both instead of the per-prompt run, with SessionStart kept as the floor case. ConfigChange is matched to `user_settings` only. **Residual risk:** an install still running Claude Code < 2.1.251 reconciles only at SessionStart — a `/model` change mid-session won't refresh the executor/scout bindings until the next session starts.
