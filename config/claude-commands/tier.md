---
description: Bind the model tier — one TOP model auto-derives worker/recon, pin them explicitly with 2/3 args, rebind one role's backend (orca/subagent, claude/openrouter), or lift the worker cap with overdrive
argument-hint: "(no args = show current) | <top> [worker] [recon] | <worker|recon|checker> <spec> | overdrive | show — e.g. opus | fable sonnet | worker openrouter:qwen/qwen3-coder | worker claude:sonnet | worker subagent | overdrive"
allowed-tools: Bash(tier-set:*)
model: haiku
effort: low
---

`/tier overdrive` lifts the worker cap so the executor runs the TOP model (recon stays cheap) and keeps it lifted as `/model` moves the top; it is expensive, says so on every session-start tier line, and a 1-arg `/tier <top>` clears it.

Each role (worker · recon · checker) also carries a **backend**: `orca` (a supervised Orca worker terminal, dispatched with `orca-dispatch`) or `subagent` (the in-process Agent tool). `/tier worker openrouter:qwen/qwen3-coder` binds an OpenRouter model run by `opencode` on the orca backend, `/tier worker claude:sonnet` an orca-backed Claude worker, `/tier worker subagent` puts it back in-process on the derived model; recon and checker take the same specs. A 1-arg `/tier <top>` resets all three to the defaults (worker orca+claude when the Orca runtime is reachable, else subagent; recon subagent; checker subagent+inherit).

!`tier-set $ARGUMENTS`

Print the tool output above verbatim and nothing else — it is complete and written for the user. Trivial passthrough: no analysis, no commentary, no tools, no deliberation.
