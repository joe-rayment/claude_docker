---
name: tier
description: >-
  Bind or inspect the model tier used for orchestrator/executor/scout
  delegation: switch the top model, pin worker/recon models explicitly,
  lift the worker cap with overdrive, or print the tiering spend report.
  Use when the user asks to change model or tier ("switch to opus", "use
  fable", "pin worker to sonnet"), asks what tier is currently active, or
  asks how much the tiers have cost ("tier cost", "spend report").
---

# Tier management

Runs `tier-set`, the single entry point for both binding and reporting on
the model tier.

- No args — show the current tier binding.
- `<top>` — bind one top model; worker and recon auto-derive from it.
- `<top> <worker> [<recon>]` — pin a specific combination explicitly.
- `overdrive` — lift the worker cap so the executor runs the top model
  (recon stays cheap); expensive, stays lifted until a 1-arg `tier-set
  <top>` clears it.
- `cost [report flags]` — print the spend report (what the tiers actually
  cost); trailing flags pass straight through, e.g. `cost --since 7d`.

Run `tier-set` via Bash with the arguments the user's request implies, and
print its output verbatim — it is complete and written for the user; add
no analysis or commentary of your own.
