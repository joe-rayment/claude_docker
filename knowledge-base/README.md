# Knowledge Base Index

Playbooks that were expensive to learn once. Check here **before**
re-deriving a procedure, debugging infrastructure, or escalating to the
oracle — the answer may already be paid for.

In-container path: `/opt/claude-dev/knowledge-base/` (this repo directory
is the source; the `/opt` copy refreshes on image rebuild).

| Doc | Keywords | One-liner |
|-----|----------|-----------|
| ACCEPTANCE_CONTRACTS.md | acceptance contract, CHECK, PASS-IF, FROZEN, CLASS, freeze window, RED-AT, GREEN-AT, red-commit-first, verifier, C1-C5, goalposts, tampered, PASS, FAIL, TAMPERED, NO-CONTRACT, no-contract, contract-gate, bd history, acceptance_criteria | Pre-registered CHECK/PASS-IF/FROZEN contract on a bead before dispatch; red-commit-first loop pins RED-AT so the verifier's five mechanical checks (C1-C5) replace open-ended re-derivation; four verdicts PASS/FAIL/TAMPERED/NO-CONTRACT; the freeze window is per-bead, not forever; contract-gate's off/warn/enforce ladder nudges `bd close`. |
| BEADS_TROUBLESHOOTING.md | beads, bd, dolt, embedded, corrupt, doctor, jsonl, sync, import, rebuild, resume, reinit, init, prefix, issue_prefix | Fix a broken bd database: `bd init --prefix <p> --quiet --non-interactive && bd import` (doctor --fix is unsupported/no-op in embedded mode), JSONL rebuild, no-server model. |
| CONFIG_SYNC.md | config, sync, checksum, zshrc, settings.local.json, overwritten, merge, layers, baked, stale, run-tests, CLAUDE_DEV_TESTS, diverged, image-drift, rebuild, uptime -s, ps lstart, PID 1, rebuild confirmation, Dockerfile COPY rename, self-modification, live settings.json hooks | The four config layers, the baked-tests verification trap, live-divergence gotchas, local overrides, the image-drift SessionStart check that flags a stale /usr/local/bin, confirming a rebuild with PID 1's start time (not uptime -s), the Dockerfile COPY line a script rename must also update, and why live hook edits to settings.json self-block. |
| DISK_SPACE.md | disk, space, full, no space left on device, df, du, docker, prune, overlay, vm, build cache, bats-run, recursion, runaway | "Container full" is the host Docker VM, not the container: du -x vs df trap; fix is host-side docker prune. |
| GUARD_VERIFICATION.md | guard, mutation, mutation testing, vacuous, vacuous test, setup-vacuous, outcome-vacuous, shadowed assertion, fixture, self-healing fixture, fake binary, PATH shim, heredoc, quoting, word-splitting, zsh, set -e, or-true fallback, positive control, flock, mktemp, lock path, contention, capture gate, rm -rf, destructive path, auto-export throttle, dolt sql, bd-guard, bypass, real tracker | Mutation-test guards and destructive paths (build a fixture, mutate the one mechanism, confirm red); fake-binary-on-PATH settles shell/quoting questions; the setup/outcome/shadowed vacuity taxonomy; gate destructive steps on demonstrably-succeeded captures; never prove a bypass against the real tracker. |
| HOOK_AUTHORING.md | hook, PreToolUse, SessionStart, jq shorthand, null-fill, has(), absent key, fixture, matcher, updatedInput, contention, bd-guard, delegation-gate, awk, mawk, quoting, single quote, quadratic, lexer, workflow-lint | Four hook-writing traps: jq's `{a,b,c}` shorthand null-fills absent keys (check with `has()`, validate fixtures against real traffic); PreToolUse matcher scope determines `updatedInput` contention risk; a literal `'` inside an awk program embedded in single-quoted shell closes the shell's quoting, not awk's (use `\047`, and keep apostrophes out of comments in the block too); and char-by-char string building in awk (`out = out c`) is quadratic in a single line's length under mawk. |
| LIVE_TESTING.md | verify, screenshot, take-screenshot, playwright, curl, httpie, live test, xvfb, bats, set -e, && masking, BATS_TEST_TMPDIR, mktemp, regression test | Behavioral verification patterns for web apps, APIs, CLIs, GUIs, and DBs, plus bats regression-test authoring rules (one assertion per line, never mktemp your own scratch dir). |
| SNOWFLAKE_DEPLOY.md | snowflake, snow cli, notebook, --replace, imports, external access, stage | Notebook deploys: --replace clears imports; ALTER NOTEBOOK to restore. |
| TEARDOWN_RECOVERY.md | teardown, resume, nested git, subdirectory, embedded repo, restore | Remove/restore the template inside a larger repo without breaking git. |
| TIERED_ORCHESTRATION.md | orchestrator, executor, scout, verifier, tier, /tier, tier-set, tier-reconcile, tier-derive, roles, frontmatter model binding, model picker, pin, ANTHROPIC_DEFAULT purge, nested subagents, delegation, escalation, trust but verify, fallback, rollback, cost-mirror, tier-cost, pricing, dollars, savings, counterfactual, PRICING_TABLE, delegation-gate, inline grinding, off/warn-only/guard/enforce, guard default, watermark, repeating warn, plan carve-out, memory carve-out, agent_id discriminator, PreToolUse gate, tier-prime, PreCompact | Role-based 3-tier orchestration (v2): `/tier` binds top in `.model` + worker/recon in agent frontmatter (env-slot remap retired/purged), nest ≤3 levels, verify worker output independently; cost-mirror/tier-cost show per-model dollars, estimated tier savings, and delegation-gate drift; `delegation-gate` counts inline main-loop grinding via a streak counter across four modes (off/warn-only/guard/enforce, `guard` default) with a repeating warn and a plan/memory edit carve-out; `tier-prime` re-injects the protocol at PreCompact so compaction can't drop it. |
| TRANSCRIPT_FORENSICS.md | transcript, jsonl, message.id, output_tokens, cache_read_input_tokens, cumulative, dedup, cost-mirror, agentType, customAgentType, role attribution, isSidechain, workflows subagents, model verification, PreAgentSpawn, SubagentStart, family alias | Reading Claude Code's own session transcripts: never cat a .jsonl, the workflows/ one-level-deeper glob trap, ground-truth model via `.message.model`, role attribution via `(.customAgentType // .agentType)`, and the message.id token-dedup rules (input/cache identical per row, output cumulative — take the max). |

## Contributing a playbook

Add one whenever a solution cost more than ~30 minutes of work or an
oracle consult:

1. Name it `SCREAMING_SNAKE_TOPIC.md` and open with one line:
   "When to use: …".
2. Make it step-shaped and self-contained — written so a Haiku-class
   model can follow it without any other context.
3. Add a row to the table above: doc, grep-able keywords, one-liner.
4. Every empirical claim carries the one-line command that re-verifies it
   in this container, the output observed at write time, and the date.
   Pin a version only where the claim is genuinely version-specific, and
   name the version. **Never cite an absolute line number** — anchor on a
   grep pattern instead, because line numbers drift silently and send the
   next reader to the wrong place. A fact that can't be reduced to a
   runnable check is a war story: it belongs in a commit message or a bead
   close reason, not the knowledge base.

Update an existing doc rather than creating a near-duplicate. Changes land
in `/opt/claude-dev/knowledge-base/` on the next image rebuild; until
then, read the repo copy at `knowledge-base/`.
