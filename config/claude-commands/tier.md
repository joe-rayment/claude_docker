---
description: "Bind the model tier: /tier <preset> or /tier <top> <worker> <recon> — Claude aliases or OpenRouter models by name, effort as @high. A bare /tier offers the presets and prints the guide"
argument-hint: "hybrid | fable glm-flash luna@high | fable, GLM 5.3 flash, GPT-5.6 Luna (high) | recon luna high | models <words> | opus | help"
allowed-tools: Bash(tier-set:*), AskUserQuestion
model: haiku
effort: low
---

!`tier-set "$ARGUMENTS"`

If the tool output above ends with a [tier-picker] block, call AskUserQuestion ONCE — question "Which tier preset?", header "Tier", one option per "option:" line in the order shown (label = the preset name, with " (current)" appended on the one marked current; description = its summary) — then run `tier-set <chosen name>` (for a free-text "Other" answer: `tier-set <the text as typed>`) and print that new tool output verbatim and nothing else; if the question is dismissed, print the output above without the [tier-picker] block. Otherwise, print the tool output above verbatim and nothing else — it is complete and written for the user. Trivial passthrough: no analysis, no commentary, no tools, no deliberation. (A bare `/tier` or `/tier help` is where the explanation lives — `/tier overdrive`, `/tier recon openrouter`, `/tier worker claude:sonnet` and the other binding forms print only the bound line.)
