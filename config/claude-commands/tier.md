---
description: Bind the session model trio (orchestrator/worker/recon) for new sessions
argument-hint: "[reasoning [worker [recon]] | show] — aliases: fable, opus, sonnet, haiku"
allowed-tools: Bash(tier-set:*)
---

Binding result:

!`tier-set $ARGUMENTS`

Relay the result above to the user faithfully. If a `falling back` or `tier warning` line appeared, surface it prominently — it means they did not get exactly what they asked for, or their trio inverts the orchestrator-is-most-capable rule. Remind them the trio applies to sessions started from now on: the current session keeps the slot bindings it launched with, and only `/model` can move the running orchestrator. Do not edit any settings files yourself — `tier-set` already did the write (or refused, if its output says so).
