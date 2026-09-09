---
description: Show or hide the index card — a tab of its own holding one short card (NOW / WHY / DONE / NEXT / SNAG) rewritten by a small model at the end of every turn
argument-hint: "(no args = toggle) | on | off | status"
allowed-tools: Bash(card:*)
model: haiku
effort: low
---

The card is written by Haiku, not by the model you are talking to: it is there to say in five lines what a long answer buried. It is replaced, never appended, so it never scrolls and there is only ever one card.

It lives in a tab called CARD. It used to be a vertical split beside this terminal, which meant every repaint re-flowed the text you were reading; a tab of its own cannot move anything.

The tab opens by itself when a session starts, unless you turned it off — `off` is remembered for the folder, so it stays off until you say `/card on`.

!`card $ARGUMENTS`

Print the tool output above verbatim and nothing else — it is complete and written for the user. Trivial passthrough: no analysis, no commentary, no tools, no deliberation.
