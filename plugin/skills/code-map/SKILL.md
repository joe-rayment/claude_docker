---
name: code-map
description: >-
  Query or manage the project's code map (call graph / structure index):
  check status, refresh or build it, explain a symbol, find what a file
  change would affect, find the path between two symbols, run a free-text
  query, print the human-readable report, or upgrade the underlying
  engine. Use when the user asks what calls something, what a change
  would break or affect, how two symbols connect, or to refresh or
  inspect the code map itself.
---

# Code map queries

Runs `code-map`, the project structure index CLI: `status | refresh |
build | explain <sym> | affected <file> | path A B | query "<q>" | report
| html | upgrade [ver] | doctor`.

Run `code-map` via Bash with the arguments the user's request implies, and
print its output verbatim — it is complete and written for the user; add
no analysis or commentary of your own.
