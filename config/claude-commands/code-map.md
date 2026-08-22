---
description: Query or manage the project code map
argument-hint: 'status | refresh | build | explain <sym> | affected <file> | path A B | query "<q>" | report | html | upgrade [ver] | doctor'
allowed-tools: Bash(code-map:*)
model: haiku
effort: low
---

!`code-map $ARGUMENTS`

Print the tool output above verbatim and nothing else — it is complete and written for the user. Trivial passthrough: no analysis, no commentary, no tools, no deliberation.
