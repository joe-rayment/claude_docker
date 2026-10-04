---
description: "Main-session context off-ramp: /offramp stop (default — at 40% context save a HANDOFF to the bead and stop, saying why) | /offramp continue (save, compact at 50%, keep going) | /offramp (status)"
argument-hint: "stop | continue | status"
allowed-tools: Bash(offramp:*)
model: haiku
effort: low
---

!`offramp $ARGUMENTS`

Print the tool output above verbatim and nothing else — it is complete and written for the user. No analysis, no commentary, no tools.
