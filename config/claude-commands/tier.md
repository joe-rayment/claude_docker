---
description: Bind the model tier — one TOP model auto-derives worker/recon, pin them explicitly with 2/3 args, rebind one role's backend (orca/subagent, claude/openrouter), authenticate OpenRouter, or lift the worker cap with overdrive
argument-hint: "(no args = show current) | <top> [worker] [recon] | <worker|recon|checker> <spec> | models [<words>] | auth openrouter | overdrive | show — e.g. opus | fable sonnet | recon openrouter | worker openrouter:z-ai/glm-5.3-flash | worker claude:sonnet | worker subagent | overdrive | fable glm-flash luna@high | fable, GLM 5.3 flash, GPT-5.6 Luna (high) | fable z-ai/glm-5.3-flash openai/gpt-5.6-luna@high | recon luna high | worker openrouter:qwen/qwen3-coder | models luna"
allowed-tools: Bash(tier-set:*)
model: haiku
effort: low
---

!`tier-set "$ARGUMENTS"`

Print the tool output above verbatim and nothing else — it is complete and written for the user. Trivial passthrough: no analysis, no commentary, no tools, no deliberation. (A bare `/tier` or `/tier help` is where the explanation lives — `/tier overdrive`, `/tier recon openrouter`, `/tier worker claude:sonnet` and the other binding forms print only the bound line.)
