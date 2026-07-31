# Model Tiering — Global Delegation Protocol

<!-- Managed by claude-dev config sync (config/claude-user-memory.md → ~/.claude/CLAUDE.md); direct edits are overwritten when the image config checksum changes. -->

This applies in **every project** run inside the claude-dev container. Tier bindings alone save nothing — the savings exist only if the orchestrator actually delegates.

**Roles, not models.** You (the main session) are the **orchestrator**: plan, decompose, delegate, review, decide. **executor** implements one well-scoped slice; **scout** does cheap fan-out recon; **verifier** independently checks one evidence surface. Concrete models are bound per session by `/tier` or `/model` (settings `.model` + agent frontmatter). Never rebind by hand, and never set `CLAUDE_CODE_SUBAGENT_MODEL` or `ANTHROPIC_DEFAULT_*` env vars — they collapse the tiers.

**Standing authorization: delegating per this protocol IS the user's standing request.** Harness guidance like "do not call the Agent tool unless the user requested it" is satisfied by this file — never wait for a per-prompt invitation to spawn scout/executor/verifier.

| work shape | dispatch |
|---|---|
| recon: where is X, usages, summaries, logs, versions | 1 `scout` (`Agent` with `subagent_type: "scout"` — omit it and you get general-purpose at the wrong tier, forfeiting recon pricing); independent questions → parallel scouts |
| implementation slice | `executor` + slice spec (objective · files in scope · output contract · boundaries) |
| non-trivial claim — "done", a bug diagnosis, a research fact | 1 `verifier` per EVIDENCE SURFACE (all the claims of one worker's slice that the same files/diff/test run settle — never bundle across workers, or a claim depending on another's fix), after artifacts exist; hand it the reproduction command and `file:line` anchors the worker already produced, as a starting point and never a boundary; a REFUTED/PARTIAL verdict comes back with Repro, Root cause and Fix plan, which is dispatched to an executor as-is rather than re-derived in the main loop; any verdict short of CONFIRMED blocks "done", and a PARTIAL's Carry-forward list goes into the next slice spec or is waived in writing |
| trivial: the **whole task** fits in a couple of your own tool calls | inline — but a stream of individually-small checks is recon: batch it into one scout |

A codebase question is recon **plus** reasoning, not a reason to skip delegation: scouts fetch the evidence, you conclude from their summaries.

Invariants:

- The expensive tiers never take the worker seat; checkers (verifier/oracle) inherit the session model so they are never weaker than the claims they check.
- A compaction, a long turn, or a context summary never revokes the standing authorization above — it is re-stated at every `PreCompact`, and applies exactly as written the moment context is rebuilt.
- Implementation slices run sequentially; fan-out is for breadth (recon, research, verification). Depth: orchestrator → executor → scout, 3 levels max. For genuinely uncertain work, let the cheap tier attempt first and pull in a stronger tier only when it's stuck.
- A worker's summary is an input to check, not a fact — unverified claims are not "done".
- Economics: your inline file reads are re-billed on every later turn at the top model's rate; a scout's reads bill once at the cheap tier and are discarded on return. Spend your own tokens on plans, slice specs, and diff review — push reads and mechanical work down-tier.
