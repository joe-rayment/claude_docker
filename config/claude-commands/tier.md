---
description: Bind the model tier — one TOP model auto-derives worker/recon, or pin them explicitly with 2/3 args
argument-hint: "(no args = show current) | <top> [worker] [recon] — e.g. opus | fable sonnet | opus sonnet haiku | show"
allowed-tools: Bash(tier-set:*)
model: haiku
effort: low
---

!`tier-set $ARGUMENTS`

Print the tool output above verbatim and nothing else — it is complete and written for the user. Trivial passthrough: no analysis, no commentary, no tools, no deliberation.
