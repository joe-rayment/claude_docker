---
description: Bind the model trio — worker+recon go live this session, orchestrator moves via /model
argument-hint: "(no args = show current) | reasoning worker recon, e.g. fable opus haiku | show"
allowed-tools: Bash(tier-set:*)
model: haiku
effort: low
---

!`tier-set $ARGUMENTS`

Reply with the tool output above **verbatim** and nothing else — it is already complete and written for the user (bare `/tier` or `/tier show` prints the current binding; args bind the trio and print the LIVE / not-moved / `/model` split). This is a trivial passthrough: do NOT analyze, summarize, or add commentary; do NOT use any tool, spawn subagents, or run a workflow; do not deliberate. Just print it.
