# Tiered Orchestration & Trust-but-Verify

**When to use:** you want a session to decompose a task across model tiers
(strong model plans + synthesizes, cheaper models do the volume) and have
worker output *independently verified* before it counts as done — and you
want to pick which concrete model backs each tier per session without
editing any agent file.

The design is **role-based, never model-based**: agents name roles; the
model behind each role is bound at session start. Nothing breaks when
models rotate.

## The roles (three tiers, ≤3 levels deep)

| Role | Agent file | Model binding | Delegates to | Job |
|------|-----------|------|--------------|-----|
| **orchestrator** | (the main session — no agent file) | `--model opus` at `tier` launch; settings `model` otherwise | executor, verifier, scout | decompose, delegate, synthesize, decide |
| **executor** | `config/agents/executor.md` | `sonnet` slot | `scout` only | one implementation slice, end to end |
| **scout** (leaf) | `config/agents/scout.md` | `haiku` slot | — | fan-out recon: find/usages/summaries |
| **verifier** (leaf) | `config/agents/verifier.md` | `inherit` (= orchestrator) | — | independent check of one worker claim |
| **oracle** | `config/agents/oracle.md` | `inherit` (= orchestrator) | — | user-invoked checkpoint consult |

**Invariant: the orchestrator is the most capable model of the three.** The
checkers (verifier, oracle) use `model: inherit`, so they always run exactly
the orchestrator's model — never a tier below the claims they check — no
matter how the session was launched (`tier`, plain `claude`, or a `/model`
override).

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

## Setting the tier per session — one top model, the rest derived (no file edits)

The default model and the trio are a **single linked thing**: you pick ONE top
model and worker/recon are **derived** as the next two consecutive rungs down
the ladder (`fable > opus > sonnet > haiku`), clamped at the haiku floor. No
independent 3-model input — that could drift from the default and is gone.

```
/model opus                         # PRIMARY in-session lever: moves the orchestrator AND
                                     #   re-derives the trio (via the reconciler) on your next prompt
/tier fable                         # explicit set: .model=fable + derived slots (fable/opus/sonnet)
/tier claude-opus-4-8               # a full id works (dated/variant kept as-is on top)
/tier opus sonnet                   # extra args IGNORED with a notice (trio is auto-derived)
/tier                               # no args: print the current binding + derived trio (writes nothing)
/tier show                          # same as bare /tier
```

Derivation table (`tier-derive`, the single source of truth):

| top | worker (executor) | recon (scout) |
|-----|-------------------|---------------|
| fable  | opus   | sonnet |
| opus   | sonnet | haiku  |
| sonnet | haiku  | haiku  |
| haiku  | haiku  | haiku  |

Three small POSIX scripts (all in `/usr/local/bin`, repo `scripts/`):
- **`tier-derive`** — `tier-derive <top>` → `<top> <worker> <recon>` (concrete
  ids); exit 3 for an off-ladder/custom top (prints nothing, so callers leave
  slots alone). The ONLY place the ladder lives.
- **`tier-set`** — the `/tier` engine: probes the top with downward fallback,
  then derives the trio from the top that bound, and writes settings.
- **`tier-reconcile`** — the hook that links `/model` → trio (see below).

Optional shell sugar in `.zshrc` drives the same engine: `tier <top>`
(= `tier-set` + launch) and `tier-show` (= `tier-set show`). `TIER_NO_PROBE=1`
skips availability probing; `TIER_SETTINGS=<path>` retargets the settings file
(used by the test suite).

**The reconciler (`tier-reconcile`) is what keeps `.model` and the trio in
sync.** Wired as a `SessionStart` + `UserPromptSubmit` hook, it reads `.model`,
derives the trio, and rewrites the `ANTHROPIC_DEFAULT_*` slots **only if they
differ** — idempotent, silent on stdout (a UserPromptSubmit hook's stdout would
be injected into the prompt), fast. An off-ladder `.model` is a no-op (never
clobber a custom top). Because it runs on the prompt *before* any subagent
spawns that turn, a `/model` change is reflected in executor/scout on the very
next turn.

**Why the `/tier` command frontmatter pins `model: haiku` + `effort: low`.**
A custom command/skill is a *prompt*: after `!`tier-set …`` runs, its whole
body is processed by a model turn. On a high-/max-effort session that turn
burns a big thinking budget on a trivial passthrough (the "improvising… still
thinking with max effort" cycle). The frontmatter runs *that turn only* on
Haiku at low effort (auto-reverting afterward), and the body is a minimal
"print the tool output verbatim; don't analyze, use tools, spawn subagents, or
run a workflow" — the last clause matters because an ultracode session injects
a "use Workflow on every task" directive into that turn too. `tier-set`'s own
stdout is already the complete, user-facing message, so the command adds no
prose of its own. Don't "simplify" these keys away — they are the fix for the
expensive-cycle bug.

Alias map: `fable→claude-fable-5`, `opus→claude-opus-4-8`,
`sonnet→claude-sonnet-5`, `haiku→claude-haiku-4-5-20251001`; a full family id
(incl. dated/variant) maps to its rung, anything else is off-ladder. Aliases
are mapped **before** writing — never an alias string into the env var that
defines that alias. The orchestrator-is-strongest invariant is now *structural*
(worker/recon are consecutive rungs below the top), so no rank warning is
needed — you can't invert the trio.

It writes into `~/.claude/settings.json`:

| Settings key | Slot | Roles that ride it |
|--------------|------|--------------------|
| `.model`                               | orchestrator | any plain `claude` launch |
| `.env.ANTHROPIC_DEFAULT_OPUS_MODEL`    | reasoning    | anything on the `opus` alias |
| `.env.ANTHROPIC_DEFAULT_SONNET_MODEL`  | worker       | executor |
| `.env.ANTHROPIC_DEFAULT_HAIKU_MODEL`   | recon        | scout |

The **worker and recon slots take effect in the current session**, not only
new ones: Claude Code re-reads `settings.json` `env` when it spawns a
subagent, so an executor (sonnet slot) or scout (haiku slot) spawned *after*
`/tier` runs uses the new model immediately — no relaunch needed. (Verified
empirically on Claude Code 2.1.206 by injecting a distinctive id into a slot
mid-session and reading the spawned subagent's recorded `model`; the public
docs imply a launch-time snapshot, but the observed behaviour is a per-spawn
re-read.) What a file write **cannot** move is the **orchestrator** — the
running session's own model: only `/model <reasoning-id>` moves a running
orchestrator (it also persists as the new-session default). `tier-set` prints
the exact `/model …` line so you can switch this session's orchestrator in one
paste. **Verifier and oracle don't ride a slot** — their frontmatter is
`model: inherit`, so they track the orchestrator's own model; because the
orchestrator doesn't move in a running session, neither do they until `/model`
is used. All three slots apply to any newly launched session.
**An image rebuild resets `settings.json` to the template** — re-run
`/tier` afterwards.

**Never set `CLAUDE_CODE_SUBAGENT_MODEL`.** It overrides *every* subagent's
model and would collapse all three tiers onto one. `tier-set` removes it on
every write.

**The slot vars in settings `env` are owned by `tier-set`.** Don't hand-edit
them, and don't export them in the shell: settings `env` overrides shell
exports at launch, so a shell export silently does nothing once `tier-set`
has written the slots — always go through `/tier` / `tier-set`.

**`/advisor` coupling:** `advisorModel` (settings) must be **≥ the session's
main model** or `/advisor` is rejected. It is pinned to `fable` — the one
static value valid above every trio this setup uses. If Fable is ever
unavailable on the plan, `/advisor` fails visibly; swap the value then.

## Graceful degradation (fallback order)

Only the **top** degrades now — worker/recon are derived from whatever top
actually bound, so they never need their own fallback. The top falls through a
candidate list to the first available model, **without editing any file**:

- top: `<requested>` → `claude-opus-4-8` → `claude-sonnet-5` → `claude-haiku-4-5-20251001`

The requested model is tried first, then the floor list — so `/tier fable`
tries Fable, then degrades downward, and the trio is derived from the rung that
bound. Fallback never escalates cost. `tier-set` probes each candidate with a
tiny `claude -p` ping (skip with `TIER_NO_PROBE=1`; the probe is best-effort —
a safeguard-rerouted model can still probe green). The SessionStart hook also
echoes the live binding each session, so you always see what you actually got.

**Demo — requested top unavailable (e.g. gated on the current plan):**

```
/tier fable                        # if claude-fable-5 is gated here…
tier[top] claude-fable-5 unavailable, trying next...
tier[top] falling back -> claude-opus-4-8
tier bound  top=claude-opus-4-8  →  worker=claude-sonnet-5  recon=claude-haiku-4-5-20251001  (worker/recon derived from the top)
· LIVE in this session: executor=claude-sonnet-5 and scout=claude-haiku-4-5-20251001 — subagents spawned from now on use them
  (Claude Code re-reads settings.json env on each subagent spawn).
· NOT moved in this session: the orchestrator (=claude-opus-4-8) and inherit agents (verifier/oracle) —
  a running session's own model changes only via /model. To move it now, run:  /model claude-opus-4-8
· NEW sessions get all three; a plain launch uses orchestrator=claude-opus-4-8.
```

(Fable 5 is an active model — do not assume it is unavailable; the probe
decides per session. This section once claimed Fable retired on 2026-07-08;
that was wrong as of 2026-07-10 and the ban on Fable references was
removed.)

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

All changes are repo files (layer 1), reversible via git. The setup is
additive — no existing agent was removed. To revert everything:

```bash
# base before this change:
git revert --no-commit bc5cb028..HEAD   # or: git checkout bc5cb028 -- <file>
```

Files introduced/changed: `config/agents/executor.md`,
`config/agents/verifier.md` (new); `config/agents/scout.md`,
`config/claude-settings.json`, `config/.zshrc`, `CLAUDE.md` (edited,
additive). A pre-change copy is also saved under
`~/.claude/backups/tiered-orchestration-<sha>/`. New config reaches a live
dev container on the next host `./claude-dev --rebuild` (or live-patch
layer 3: `cp config/agents/*.md ~/.claude/agents/`).

**2026-07-10 revision (Fable-is-back review):** `config/.zshrc` (tier-bind
split, alias map, rank warning, tier-show settings-model line),
`config/agents/{verifier,oracle}.md` (`model: inherit`),
`config/agents/{executor,scout}.md` (prose), `config/claude-settings.json`
(`advisorModel: "fable"`, honest SessionStart echo), `CLAUDE.md`, this file,
`tests/smoke.bats`. Pre-change live copies:
`~/.claude/backups/tier-review-20260710/`. Same rollback mechanics as above.

**2026-07-10 revision 2 (/tier slash command):** engine moved out of the
shell into `scripts/tier-set.sh` (staged to `/usr/local/bin/tier-set`),
exposed as `/tier` via `config/claude-commands/tier.md` (entrypoint deploys
`configs/commands/*.md` → `~/.claude/commands/`); binding mechanism changed
from env exports to a settings.json write (see above); `config/.zshrc` tier
block reduced to thin wrappers; `Dockerfile` + `scripts/entrypoint.sh` gained
the staging lines; `tests/smoke.bats` tier tests retargeted to the script.
