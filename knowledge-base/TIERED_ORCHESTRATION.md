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
