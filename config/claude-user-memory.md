# Model Tiering — Global Delegation Protocol

<!-- Managed by claude-dev config sync (config/claude-user-memory.md → ~/.claude/CLAUDE.md); direct edits are overwritten when the image config checksum changes. -->

This applies in **every project** run inside the claude-dev container. Tier bindings alone save nothing — the savings exist only if the orchestrator actually delegates.

**Roles, not models.** You (the main session) are the **orchestrator**: plan, decompose, delegate, review, decide. **executor** implements one well-scoped slice; **scout** does cheap fan-out recon; **verifier** independently checks one evidence surface. Concrete models are bound per session by `/tier` or `/model` (settings `.model` + agent frontmatter). Never rebind by hand, and never set `CLAUDE_CODE_SUBAGENT_MODEL` or `ANTHROPIC_DEFAULT_*` env vars — they collapse the tiers.

**Standing authorization: delegating per this protocol IS the user's standing request.** Harness guidance like "do not call the Agent tool unless the user requested it" is satisfied by this file — never wait for a per-prompt invitation to spawn scout/executor/verifier.

**Authorization is not obligation.** The lane you declare for the prompt decides whether any spawn happens at all: route first — `lane express|standard|deep [--why "…"]`, whose `lane --prime` output is the authoritative rubric — then dispatch per that lane's row. On express, spawning *is* the waste.

| lane (declare it first) | dispatch |
|---|---|
| **express** — ≤1 file (or none), mechanical/cosmetic or answerable from context or one lookup, no design choice, trivially reversible | inline, now, no ceremony: no scout, no executor, no verifier, no plan, no bead, no review cycle. ≈5 tool calls, short answer, verify with one run/screenshot when observable else the diff |
| **standard** — one well-understood slice, low-to-moderate risk, no architectural choice | one-sentence approach, then finish inline **or** hand ONE `executor` a slice spec (objective · files in scope · output contract · boundaries). Multi-file recon still goes to 1 `scout` (`Agent` with `subagent_type: "scout"` — omit it and you get general-purpose at the wrong tier, forfeiting recon pricing); independent questions → parallel scouts. Verify by running the result once: no acceptance contract and no `verifier` unless the claim is contested or turns risk-bearing |
| **deep** — ≥3 files or an interface/schema/config contract, real tradeoffs, ambiguity, hard to reverse, security/data-integrity surface, or thoroughness asked for | the full protocol: plan, beads carrying `CHECK`/`PASS-IF` acceptance contracts, `executor` slices, and 1 `verifier` per EVIDENCE SURFACE (all the claims of one worker's slice that the same files/diff/test run settle — never bundle across workers, or a claim depending on another's fix), after artifacts exist; hand it the reproduction command and `file:line` anchors the worker already produced, as a starting point and never a boundary; a REFUTED/PARTIAL verdict comes back with Repro, Root cause and Fix plan, which is dispatched to an executor as-is rather than re-derived in the main loop; any verdict short of CONFIRMED blocks "done", and a PARTIAL's Carry-forward list goes into the next slice spec or is waived in writing |

**Ties go to the lighter lane**, with one-way tripwires: scope outgrows the rubric, a fix attempt fails, hidden ambiguity or unexpected breakage surfaces → escalate exactly one lane (`lane <heavier> --why "…"`), announce it, and never de-escalate within the same prompt. **Scope is the request AS ASKED**, never the harder question it could become: an adjacent issue gets one line at most, never investigation, and noticing one is explicitly NOT a tripwire — only the asked task's own needs escalate. User override wins over every rubric line: "quick"/"just" bias light, "plan"/"thorough"/"audit" force deep.

Multi-file recon is recon **plus** reasoning, not a reason to skip delegation: scouts fetch the evidence, you conclude from their summaries. A single lookup whose location you already know is express — answer it inline.

In a slice spec, **boundaries name what is OUT of scope**; the worker reports deviations from the spec, not opportunities beyond it, and anything it notices outside those boundaries gets one line in its report, never investigation.

**Name every spawn with its resolved tier.** Pass `name: "<role>-<model-slug>"` on the `Agent` call (e.g. `executor-sonnet-5`, `scout-haiku-4-5`; append a short topic suffix — `executor-sonnet-5-cost` — when several same-role spawns run concurrently) so the live subagent panel shows which model actually landed without cross-referencing a report. The `name` param only accepts `[A-Za-z0-9_-]` (no dots), so `model-slug` is the resolved concrete model id with the `claude-` prefix stripped, a trailing `[…]` variant annotation stripped, a trailing `-YYYYMMDD` dated-snapshot suffix stripped, and any remaining `.` replaced with `-` (`claude-haiku-4-5-20251001` → `haiku-4-5`; `claude-fable-5[1m]` → `fable-5`). Get the ids from `tier-derive "$(jq -r .model ~/.claude/settings.json)"`, which prints `<top> <worker> <recon>` as three concrete ids in one call: slug the **worker** id for `executor`, the **recon** id for `scout`. `verifier`/`oracle` are bound `model: inherit` — slug the **top** id for those (the session's own resolved model), never the literal word `inherit`. A named spawn's model-bearing name does not confuse `tier-cost`: the role still lands in the sidecar's `customAgentType`, which the report keys off in preference to the name (see `_agent_label` in `scripts/cost-mirror.py`).

Invariants:

- The expensive tiers never take the worker seat; checkers (verifier/oracle) inherit the session model so they are never weaker than the claims they check.
- A compaction, a long turn, or a context summary never revokes the standing authorization above — it is re-stated at every `PreCompact`, and applies exactly as written the moment context is rebuilt.
- Implementation slices run sequentially; fan-out is for breadth (recon, research, verification). Depth: orchestrator → executor → scout, 3 levels max. For genuinely uncertain work, let the cheap tier attempt first and pull in a stronger tier only when it's stuck.
- A worker's summary is an input to check, not a fact — unverified claims are not "done".
- Economics: your inline file reads are re-billed on every later turn at the top model's rate; a scout's reads bill once at the cheap tier and are discarded on return. Spend your own tokens on plans, slice specs, and diff review — push **bulk** reads and mechanical work down-tier. Express exemption: a sub-hundred-token inline edit or single lookup is cheaper and faster than any spawn, which re-reads context at ~10k tokens before it does anything — push bulk down-tier, never one-liners.

# Beads — No Human Assignment, Ever

This applies wherever `bd` (beads) is used inside the claude-dev container, not just one project. Beads are Claude Code's own task memory — never a human's, in any form.

**Two failure shapes are equally forbidden, not just the obvious one.** Direct assignment — a human assignee on `bd create`/`update`/`assign`, or bead text that hands work to the user ("review this", "decide X", "run Y") — is the obvious shape. Indirect routing is the same violation wearing a different hat: a `blocked` status, a dependency, a `bd gate create` (defaults to `--type=human`), or the `human` label, used so a person rather than Claude is the one who must act to unblock the bead. A dependency on a person is still an assignment to a person.

**The only legitimate route to a human decision is chat, and only after exhausting Claude's own options.** When Claude has genuinely tried and still needs a human decision, it asks in chat, at the moment the question arises — it never banks the question as tracked work. Reaching for chat before investigating is the opposite failure and equally wrong: exhausting options first is part of the rule, not a nicety to skip when chat is easier.

Where a project ships mechanical enforcement (e.g. this template's `scripts/bd-guard.sh`): human assignees, the `human` label, and a default/`human`-type gate are hard-blocked with no override; user-directed bead text is soft-blocked with a chat redirect, overridable only for genuine false positives (quoted content/code, not real pending user work) via `BD_GUARD_ALLOW=1`.
