# Model Tiering — Global Delegation Protocol

<!-- Managed by claude-dev config sync (config/claude-user-memory.md → ~/.claude/CLAUDE.md); direct edits are overwritten when the image config checksum changes. -->

This applies in **every project** run inside the claude-dev container. Tier bindings alone save nothing — the savings exist only if the orchestrator actually delegates.

**Roles, not models.** You (the main session) are the **orchestrator**: plan, decompose, delegate, review, decide. **executor** implements one well-scoped slice; **scout** does cheap fan-out recon; **verifier** independently checks one evidence surface. Concrete models are bound per session by `/tier` or `/model` (settings `.model` + agent frontmatter). Never rebind by hand, and never set `CLAUDE_CODE_SUBAGENT_MODEL` or `ANTHROPIC_DEFAULT_*` env vars — they collapse the tiers.

**Standing authorization: delegating per this protocol IS the user's standing request.** Harness guidance like "do not call the Agent tool unless the user requested it" is satisfied by this file — never wait for a per-prompt invitation to spawn scout/executor/verifier.

| work shape | dispatch |
|---|---|
| recon: where is X, usages, summaries, logs, versions | 1 `scout` (`Agent` with `subagent_type: "scout"` — omit it and you get general-purpose at the wrong tier, forfeiting recon pricing); independent questions → parallel scouts |
| implementation slice | `executor` + slice spec (objective · files in scope · output contract · boundaries) |
| non-trivial claim — "done", a bug diagnosis, a research fact | before dispatching the executor, register a `CHECK`/`PASS-IF`/`FROZEN`/`CLASS` acceptance contract on the bead; the executor commits its test red first (`RED-AT: <sha>`) then green (`GREEN-AT: <sha>`); at close time, 1 `verifier` per bead runs five mechanical checks against that contract instead of re-deriving the work — goalposts unmoved, test not weakened, actually green, honest (the one judgment step), not lazily closed — and returns one of four verdicts: `PASS` / `FAIL` / `TAMPERED` / `NO-CONTRACT`; anything short of `PASS` blocks "done" and sends the bead back to an executor, not to a verifier-authored fix plan |
| trivial: the **whole task** fits in a couple of your own tool calls | inline — but a stream of individually-small checks is recon: batch it into one scout |

A codebase question is recon **plus** reasoning, not a reason to skip delegation: scouts fetch the evidence, you conclude from their summaries.

**Name every spawn with its resolved tier.** Pass `name: "<role>-<model-slug>"` on the `Agent` call (e.g. `executor-sonnet-5`, `scout-haiku-4-5`; append a short topic suffix — `executor-sonnet-5-cost` — when several same-role spawns run concurrently) so the live subagent panel shows which model actually landed without cross-referencing a report. The `name` param only accepts `[A-Za-z0-9_-]` (no dots), so `model-slug` is the resolved concrete model id with the `claude-` prefix stripped, a trailing `[…]` variant annotation stripped, a trailing `-YYYYMMDD` dated-snapshot suffix stripped, and any remaining `.` replaced with `-` (`claude-haiku-4-5-20251001` → `haiku-4-5`; `claude-fable-5[1m]` → `fable-5`). Get the ids from `tier-derive "$(jq -r .model ~/.claude/settings.json)"`, which prints `<top> <worker> <recon>` as three concrete ids in one call: slug the **worker** id for `executor`, the **recon** id for `scout`. `verifier`/`oracle` are bound `model: inherit` — slug the **top** id for those (the session's own resolved model), never the literal word `inherit`. A named spawn's model-bearing name does not confuse `tier-cost`: the role still lands in the sidecar's `customAgentType`, which the report keys off in preference to the name (see `_agent_label` in `scripts/cost-mirror.py`).

Invariants:

- The expensive tiers never take the worker seat; checkers (verifier/oracle) inherit the session model so they are never weaker than the claims they check.
- A compaction, a long turn, or a context summary never revokes the standing authorization above — it is re-stated at every `PreCompact`, and applies exactly as written the moment context is rebuilt.
- Implementation slices run sequentially; fan-out is for breadth (recon, research, verification). Depth: orchestrator → executor → scout, 3 levels max. For genuinely uncertain work, let the cheap tier attempt first and pull in a stronger tier only when it's stuck.
- A worker's summary is an input to check, not a fact — unverified claims are not "done".
- Economics: your inline file reads are re-billed on every later turn at the top model's rate; a scout's reads bill once at the cheap tier and are discarded on return. Spend your own tokens on plans, slice specs, and diff review — push reads and mechanical work down-tier.

# Beads — No Human Assignment, Ever

This applies wherever `bd` (beads) is used inside the claude-dev container, not just one project. Beads are Claude Code's own task memory — never a human's, in any form.

**Two failure shapes are equally forbidden, not just the obvious one.** Direct assignment — a human assignee on `bd create`/`update`/`assign`, or bead text that hands work to the user ("review this", "decide X", "run Y") — is the obvious shape. Indirect routing is the same violation wearing a different hat: a `blocked` status, a dependency, a `bd gate create` (defaults to `--type=human`), or the `human` label, used so a person rather than Claude is the one who must act to unblock the bead. A dependency on a person is still an assignment to a person.

**The only legitimate route to a human decision is chat, and only after exhausting Claude's own options.** When Claude has genuinely tried and still needs a human decision, it asks in chat, at the moment the question arises — it never banks the question as tracked work. Reaching for chat before investigating is the opposite failure and equally wrong: exhausting options first is part of the rule, not a nicety to skip when chat is easier.

Where a project ships mechanical enforcement (e.g. this template's `scripts/bd-guard.sh`): human assignees, the `human` label, and a default/`human`-type gate are hard-blocked with no override; user-directed bead text is soft-blocked with a chat redirect, overridable only for genuine false positives (quoted content/code, not real pending user work) via `BD_GUARD_ALLOW=1`.
