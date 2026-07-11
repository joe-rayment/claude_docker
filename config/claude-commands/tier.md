---
description: Bind the model trio — worker+recon go live this session, orchestrator moves via /model
argument-hint: "(no args = show current) | reasoning worker recon — space-separated, e.g. fable opus haiku (aliases: fable opus sonnet haiku, no commas) | show"
allowed-tools: Bash(tier-set:*)
---

Usage: `/tier reasoning worker recon` — three space-separated aliases (`fable`, `opus`, `sonnet`, `haiku`) or full model IDs, no commas. **Bare `/tier` (no args) just prints the current binding** — same as `/tier show`; it writes nothing. Partial trios keep defaults for the rest (`/tier fable`). Example: `/tier fable opus haiku`.

Result:

!`tier-set $ARGUMENTS`

**If the output above is just the current binding** (the user ran bare `/tier` or `/tier show` — it lists the orchestrator/reasoning/worker/recon slots and writes nothing), relay it plainly as the current state. There is no binding change and no `/model` step to surface.

**Otherwise the output is a binding result** — relay it faithfully, including the split the tool prints:

- The **executor (worker) and scout (recon) slots are already live in this session** — subagents spawned from now on use the new models, because Claude Code re-reads `settings.json` env on each subagent spawn. Nothing further is needed for those tiers.
- The **orchestrator and `model: inherit` agents (verifier/oracle) are NOT moved in a running session** — a file write can't move a running session's own model. If the tool printed a `/model …` line, surface it **prominently** as the single manual step to switch this session's orchestrator now (only the user can run `/model`; it also persists for new sessions).

If a `falling back` or `tier warning` line appeared, surface it prominently too — it means they did not get exactly what they asked for, or their trio inverts the orchestrator-is-most-capable rule. Do not edit any settings files yourself — `tier-set` already did the write (or refused, if its output says so).
