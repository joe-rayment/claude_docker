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

## Setting the three models per session (no file edits)

Say the combination you want, in the simplest form, from inside any session —
the **`/tier` slash command** (`~/.claude/commands/tier.md`, staged from
`config/claude-commands/`):

```
/tier fable opus haiku              # Fable orchestrator + Opus executors + Haiku scouts
/tier fable                         # partial trio: lower slots keep defaults
/tier show                          # print the current binding
```

The engine is **`tier-set`** (`/usr/local/bin/tier-set`, repo
`scripts/tier-set.sh`) — a standalone POSIX script, no shell functions
required. Optional shell sugar in `.zshrc` drives the same engine:
`tier <trio>` (= `tier-set` + launch) and `tier-show` (= `tier-set show`).
`TIER_NO_PROBE=1` skips availability probing; `TIER_SETTINGS=<path>` retargets
the settings file (used by the test suite).

Alias map: `fable→claude-fable-5`, `opus→claude-opus-4-8`,
`sonnet→claude-sonnet-5`, `haiku→claude-haiku-4-5-20251001`; anything else
passes through as a full model ID. Aliases are mapped **before** writing —
never an alias string into the env var that defines that alias. `tier-set`
warns when a lower slot outranks the reasoning slot (capability order
fable > opus > sonnet > haiku; unknown IDs skip the check).

It writes into `~/.claude/settings.json`:

| Settings key | Slot | Roles that ride it |
|--------------|------|--------------------|
| `.model`                               | orchestrator | any plain `claude` launch |
| `.env.ANTHROPIC_DEFAULT_OPUS_MODEL`    | reasoning    | anything on the `opus` alias |
| `.env.ANTHROPIC_DEFAULT_SONNET_MODEL`  | worker       | executor |
| `.env.ANTHROPIC_DEFAULT_HAIKU_MODEL`   | recon        | scout |

Claude Code applies settings (model + env) at **session start**, so the trio
takes effect for **new sessions**; a running session keeps the slots it
launched with, and only `/model` can move a running orchestrator.
**Verifier and oracle don't ride a slot** — their frontmatter is
`model: inherit`, so they run the orchestrator's own model in every launch
style. **An image rebuild resets `settings.json` to the template** — re-run
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

Each slot falls through a candidate list to the first available model,
**without editing any file**, and prints what it bound:

- reasoning: `claude-opus-4-8` → `claude-sonnet-5` → `claude-haiku-4-5-20251001`
- worker:    `claude-sonnet-5` → `claude-haiku-4-5-20251001`
- recon:     `claude-haiku-4-5-20251001` → `claude-sonnet-5`

The requested model is tried first, then the floor list — so `/tier fable …`
tries Fable, then degrades downward. Fallback never escalates cost.
`tier-set` probes each candidate with a tiny `claude -p` ping (skip with
`TIER_NO_PROBE=1`; the probe is best-effort — a safeguard-rerouted model can
still probe green). The SessionStart hook also echoes the live binding each
session, so you always see what you actually got.

**Demo — requested model unavailable (e.g. gated on the current plan):**

```
/tier fable sonnet haiku           # if claude-fable-5 is gated here…
tier[reasoning] claude-fable-5 unavailable, trying next...
tier[reasoning] falling back -> claude-opus-4-8
tier bound  orchestrator=claude-opus-4-8  worker=claude-sonnet-5  recon=claude-haiku-4-5-20251001
applies to NEW sessions; the current session keeps its binding (/model moves only the running orchestrator)
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
