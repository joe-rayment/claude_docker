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

| Role | Agent file | Slot | Delegates to | Job |
|------|-----------|------|--------------|-----|
| **orchestrator** | (the main session — no agent file) | `--model opus` | executor, verifier, scout | decompose, delegate, synthesize, decide |
| **executor** | `config/agents/executor.md` | `sonnet` | `scout` only | one implementation slice, end to end |
| **scout** (leaf) | `config/agents/scout.md` | `haiku` | — | fan-out recon: find/usages/summaries |
| **verifier** (leaf) | `config/agents/verifier.md` | `opus` | — | independent check of one worker claim |
| **oracle** | `config/agents/oracle.md` | `opus` | — | user-invoked checkpoint consult |

The tree tops out at **orchestrator → executor → scout**. It's enforced
structurally, not by convention:

- **scout** and **verifier** have no `Agent` tool in their frontmatter →
  they physically cannot spawn children (they are leaves).
- **executor**'s only grant is `Agent(scout)` → it can spawn nothing
  deeper than a leaf.
- Claude Code's own hard ceiling is depth 5; ours is tighter on purpose.

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

Roles are pinned to the `opus`/`sonnet`/`haiku` alias slots. The `tier`
launcher (in `.zshrc`) points those slots at concrete models and launches:

```
tier                                # defaults: Opus 4.8 / Sonnet 5 / Haiku 4.5
tier <reasoning> <worker> <recon>   # explicit trio (aliases or full model ids)
tier-show                           # print the current binding
TIER_NO_PROBE=1 tier ...            # skip availability probing (bind blind)
```

It exports:

| Env var | Slot | Roles that ride it |
|---------|------|--------------------|
| `ANTHROPIC_DEFAULT_OPUS_MODEL`   | reasoning | orchestrator, verifier, oracle |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | worker    | executor |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL`  | recon     | scout |

then launches `claude --dangerously-skip-permissions --model opus` (the
main session = orchestrator = reasoning slot).

**Never set `CLAUDE_CODE_SUBAGENT_MODEL`.** It overrides *every* subagent's
model and would collapse all three tiers onto one. `tier` unsets it. Every
role is explicitly slot-pinned, so no tier silently runs at the most
expensive available model.

## Graceful degradation (fallback order)

Each slot falls through a candidate list to the first available model,
**without editing any file**, and prints what it bound:

- reasoning: `claude-opus-4-8` → `claude-sonnet-5` → `claude-haiku-4-5-20251001`
- worker:    `claude-sonnet-5` → `claude-haiku-4-5-20251001`
- recon:     `claude-haiku-4-5-20251001` → `claude-sonnet-5`

`tier` probes each candidate with a tiny `claude -p` ping (skip with
`TIER_NO_PROBE=1`). The SessionStart hook also echoes the live trio each
session, so you always see what you actually got.

**Demo — Fable is gone (it retired 2026-07-08):**

```
$ tier claude-fable-5 claude-sonnet-5 claude-haiku-4-5-20251001
tier[reasoning] claude-fable-5 unavailable, trying next…
tier[reasoning] falling back → claude-opus-4-8
tier bound  reasoning=claude-opus-4-8  worker=claude-sonnet-5  recon=claude-haiku-4-5-20251001
```

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
