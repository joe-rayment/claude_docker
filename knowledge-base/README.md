# Knowledge Base Index

Playbooks that were expensive to learn once. Check here **before**
re-deriving a procedure, debugging infrastructure, or escalating to the
oracle — the answer may already be paid for.

In-container path: `/opt/claude-dev/knowledge-base/` (this repo directory
is the source; the `/opt` copy refreshes on image rebuild).

| Doc | Keywords | One-liner |
|-----|----------|-----------|
| BEADS_TROUBLESHOOTING.md | beads, bd, dolt, embedded, corrupt, doctor, jsonl, sync | Fix a broken bd database: doctor --fix, JSONL rebuild, no-server model. |
| CONFIG_SYNC.md | config, sync, checksum, zshrc, settings.local.json, overwritten, merge, layers, baked, stale, run-tests, CLAUDE_DEV_TESTS, diverged | The four config layers, the baked-tests verification trap, live-divergence gotchas, and local overrides. |
| DISK_SPACE.md | disk, space, full, no space left on device, df, du, docker, prune, overlay, vm, build cache, bats-run, recursion, runaway | "Container full" is the host Docker VM, not the container: du -x vs df trap; fix is host-side docker prune. |
| LIVE_TESTING.md | verify, screenshot, take-screenshot, playwright, curl, httpie, live test, xvfb | Behavioral verification patterns for web apps, APIs, CLIs, GUIs, and DBs. |
| SNOWFLAKE_DEPLOY.md | snowflake, snow cli, notebook, --replace, imports, external access, stage | Notebook deploys: --replace clears imports; ALTER NOTEBOOK to restore. |
| TEARDOWN_RECOVERY.md | teardown, resume, nested git, subdirectory, embedded repo, restore | Remove/restore the template inside a larger repo without breaking git. |
| TIERED_ORCHESTRATION.md | orchestrator, executor, scout, verifier, tier, /tier, tier-set, tier-reconcile, tier-derive, roles, frontmatter model binding, model picker, pin, ANTHROPIC_DEFAULT purge, nested subagents, delegation, escalation, trust but verify, fallback, rollback, cost-mirror, tier-cost, pricing, dollars, savings, counterfactual, PRICING_TABLE, delegation-gate, inline grinding, warn/enforce, agent_id discriminator, PreToolUse gate | Role-based 3-tier orchestration (v2): `/tier` binds top in `.model` + worker/recon in agent frontmatter (env-slot remap retired/purged), nest ≤3 levels, verify worker output independently; cost-mirror/tier-cost show per-model dollars and estimated tier savings; `delegation-gate` warns/denies inline main-loop grinding via a streak counter (warn/enforce). |

## Contributing a playbook

Add one whenever a solution cost more than ~30 minutes of work or an
oracle consult:

1. Name it `SCREAMING_SNAKE_TOPIC.md` and open with one line:
   "When to use: …".
2. Make it step-shaped and self-contained — written so a Haiku-class
   model can follow it without any other context.
3. Add a row to the table above: doc, grep-able keywords, one-liner.

Update an existing doc rather than creating a near-duplicate. Changes land
in `/opt/claude-dev/knowledge-base/` on the next image rebuild; until
then, read the repo copy at `knowledge-base/`.
