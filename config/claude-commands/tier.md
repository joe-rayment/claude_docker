---
description: Bind the model tier — one TOP model auto-derives worker/recon, pin them explicitly with 2/3 args, rebind one role's backend (orca/subagent, claude/openrouter), authenticate OpenRouter, or lift the worker cap with overdrive
argument-hint: "(no args = show current) | <top> [worker] [recon] | <worker|recon|checker> <spec> | auth openrouter | overdrive | show — e.g. opus | fable sonnet | recon openrouter | worker openrouter:z-ai/glm-5.3-flash | worker claude:sonnet | worker subagent | overdrive"
allowed-tools: Bash(tier-set:*)
model: haiku
effort: low
---

`/tier overdrive` lifts the worker cap so the executor runs the TOP model (recon stays cheap) and keeps it lifted as `/model` moves the top; it is expensive, says so on every session-start tier line, and a 1-arg `/tier <top>` clears it.

Each role (worker · recon · checker) also carries a **backend**: `orca` (a supervised Orca worker terminal, dispatched with `orca-dispatch`) or `subagent` (the in-process Agent tool). `/tier worker openrouter:z-ai/glm-5.3-flash` binds OpenRouter's GLM 5.3 Flash run by `opencode` on the orca backend, `/tier worker claude:sonnet` an orca-backed Claude worker, `/tier worker subagent` puts it back in-process on the derived model; recon and checker take the same specs. `/tier recon openrouter` — the bare spec, no model named — binds the role's own OpenRouter default, which for recon is the flash-class rung `openrouter/z-ai/glm-5.3-flash`.

A 1-arg `/tier <top>` resets all three to the defaults: worker orca+claude when the Orca runtime is reachable, else subagent; recon subagent haiku; **checker subagent at the derived checker rung — the top capped at opus**, so a fable top is graded from opus, a seat that is neither the orchestrator's nor the worker's. An off-ladder top leaves the checker on `inherit`.

An `openrouter:` bind still saves even with no credential in this folder — it just names `/tier auth openrouter` as the next step. That command opens a focused Orca tab that walks through getting a key, validates it, and starts the guard, all without leaving the session; if no Orca runtime is reachable it prints the same command to run by hand in any terminal instead.

!`tier-set $ARGUMENTS`

Print the tool output above verbatim and nothing else — it is complete and written for the user. Trivial passthrough: no analysis, no commentary, no tools, no deliberation.
