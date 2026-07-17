---
description: Bind the model tier from one TOP model — worker/recon are derived; /model is the primary in-session lever
argument-hint: "(no args = show current) | <top> — one model, e.g. opus | fable | claude-opus-4-8 | show"
allowed-tools: Bash(tier-set:*)
model: haiku
effort: low
---

!`tier-set $ARGUMENTS`

Reply with the tool output above **verbatim** and nothing else — it is already complete and written for the user. `/tier <top>` binds the tier from a single model (worker/recon are auto-derived as the next two rungs down: fable>opus>sonnet>haiku, floored); extra args are ignored with a notice. Bare `/tier` or `/tier show` prints the current binding and the derived trio. `/model` is the primary in-session lever — the reconciler re-derives the trio from `.model` on the next prompt. This is a trivial passthrough: do NOT analyze, summarize, or add commentary; do NOT use any tool, spawn subagents, or run a workflow; do not deliberate. Just print it.
