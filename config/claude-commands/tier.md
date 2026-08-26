---
description: Bind the model tier — one TOP model auto-derives worker/recon, pin them explicitly with 2/3 args, lift the worker cap with overdrive, or read the spend report with cost
argument-hint: "(no args = show current) | <top> [worker] [recon] | overdrive | cost [report flags] — e.g. opus | fable sonnet | opus sonnet haiku | overdrive | show | cost | cost --since 7d"
allowed-tools: Bash(tier-set:*)
model: haiku
effort: low
---

`/tier overdrive` lifts the worker cap so the executor runs the TOP model (recon stays cheap) and keeps it lifted as `/model` moves the top; it is expensive, says so on every session-start tier line, and a 1-arg `/tier <top>` clears it.

`/tier cost` prints the spend report — what the tiers actually cost — and passes any trailing flags straight through to it (`/tier cost --since 7d`, `/tier cost --session <prefix>`).

!`tier-set $ARGUMENTS`

Print the tool output above verbatim and nothing else — it is complete and written for the user. Trivial passthrough: no analysis, no commentary, no tools, no deliberation.
