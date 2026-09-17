---
description: "Bind the model tier: /tier <top> <worker> <recon> — Claude aliases or OpenRouter models by name, effort as @high. Bare /tier prints the guide"
argument-hint: "fable glm-flash luna@high | fable, GLM 5.3 flash, GPT-5.6 Luna (high) | recon luna high | models <words> | opus | help"
allowed-tools: Bash(tier-set:*)
model: haiku
effort: low
---

!`tier-set "$ARGUMENTS"`

Print the tool output above verbatim and nothing else — it is complete and written for the user. Trivial passthrough: no analysis, no commentary, no tools, no deliberation. (A bare `/tier` or `/tier help` is where the explanation lives — `/tier overdrive`, `/tier recon openrouter`, `/tier worker claude:sonnet` and the other binding forms print only the bound line.)
