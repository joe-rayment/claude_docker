---
description: Bind the model tier — one TOP model auto-derives worker/recon, or pin them explicitly with 2/3 args
argument-hint: "(no args = show current) | <top> [worker] [recon] — e.g. opus | fable sonnet | opus sonnet haiku | show"
allowed-tools: Bash(tier-set:*)
model: haiku
effort: low
---

!`tier-set $ARGUMENTS`

Reply with the tool output above **verbatim** and nothing else — it is already complete and written for the user. `/tier <top>` binds the tier from a single model: it writes the top to settings `.model` and auto-derives worker/recon as the next two rungs down (fable>opus>sonnet>haiku, floored). `/tier <top> <worker>` pins a 2-level config (recon shares the worker model). `/tier <top> <worker> <recon>` pins all three explicitly, including non-consecutive combos. An explicit bind sets a pin that the reconciler leaves alone until the next 1-arg `/tier <top>` clears it. Worker/recon are bound as concrete model ids in the executor/scout agent frontmatter and take effect in NEW sessions (agent definitions snapshot at session start). Bare `/tier` or `/tier show` prints the current binding (and whether a pin is active). `/model` stays the primary in-session lever for the orchestrator — the reconciler derives worker/recon from `.model` on the next prompt (unless pinned). This is a trivial passthrough: do NOT analyze, summarize, or add commentary; do NOT use any tool, spawn subagents, or run a workflow; do not deliberate. Just print it.
