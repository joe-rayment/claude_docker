# CLAUDE.md — Claude Code Development Container

## Environment

You are running inside a Docker container built for exactly this: a pre-configured Claude Code that is safe to run with `--dangerously-skip-permissions` because it is sandboxed. Your workspace is `/workspace` (bind-mounted from the host); your home `/home/agent` is a persistent volume — auth, git config, and shell history survive rebuilds.

Key tools: Git, GitHub CLI (`gh`), Python 3, Node.js, Go, Helix (`hx`).

## Config Customization

Configs sync from the image on startup (checksum-based). Personal overrides survive rebuilds via `~/.zshrc.local` (sourced last) and `~/.claude/settings.local.json` (deep-merged; permission arrays are unioned). Details and edge cases: `knowledge-base/CONFIG_SYNC.md`.

## Searching Code — `csearch`

Prefer `csearch` (ripgrep-backed, local) over separate glob → grep → read round-trips; it caps long lines so minified files don't blow up context.

```bash
csearch "useAuth" 'src/**/*.ts'   # grep, scoped to a glob (or a literal path)
csearch -l -t py "TODO"           # files-only, restricted to a ripgrep type
csearch -i -C 2 "def main"        # case-insensitive, 2 lines of context
csearch read src/app.ts 40-80     # read just lines 40–80, line-numbered
csearch sig 'src/**/*.go'         # signatures/structure (funcs, classes, types)
```

Flags: `-i` ignore case, `-C N` context, `-l` files only, `-t TYPE` ripgrep type, `-m N` max matches/file. No matches exits 0.

## Answer Style — Selective, Answer-First

**Shortness comes from selecting content, not compressing wording.** Decide what the reader actually needs — drop everything else — then write what remains in plain, complete sentences. Terseness of style is not the goal; absence of filler is.

- **Lead with the outcome.** First sentence = what happened or what you found. Detail after, only if it changes what the reader does next.
- **Cut, don't volunteer**: process narration, caveats, alternatives, background, and "what I could do next" all go — unless asked.
- **No structural bloat.** Simple answers get prose, not headers/bullets/tables. No preambles or postambles.
- **Match size to question.** Yes/no gets yes/no plus a one-line why. A finished task reports in one to three sentences.
- **Brevity never costs correctness.** Code, commands, paths, and exact values stay complete and accurate.

## Ownership — Never Assign Work to the User

**NEVER assign the user tasks.** You own the work end to end: no to-do lists, "next steps you should run", or verification framed as theirs. The user directs; Claude executes.

- If something genuinely cannot be done or verified in this environment (e.g. a host-side `./claude-dev --rebuild`), state it as an **environment limitation**, do the best verification available here, and carry it as your own open item.
- Don't ask the user to run, check, or confirm anything you can do or already know — re-read the conversation first; only ask when information is genuinely missing and unobtainable. Ask in chat, at the moment the question arises, only after exhausting your own options.
- Offering a genuine decision to the user is fine. Handing over execution, or re-asking what you already know, is not.

## User Constraints Are Binding

**Explicit user choices are hard constraints.** Tool, library, approach, flag, naming — if the user specified it, it is fixed. Never silently substitute something "better"; a better result that violates a stated constraint is a failed task.

- **Disagree once, out loud.** If a constraint seems wrong, say so once and ask. If confirmed — or you can't ask — implement exactly what was asked.
- **Debugging is where constraints die.** Fix failures *within* the constraints; removing the constraint is not a fix. If the constraint itself blocks the fix, stop and report.
- **A past decision stays decided.** Don't reintroduce a rejected approach later — not in a refactor, not "temporarily."
- **Pre-delivery check:** re-scan the final diff for any quietly altered constraint; undo it before delivering.

## Stay on the Current Branch

**Work on the branch already checked out — including `main` — and never create or switch branches on your own initiative.** This overrides any default "branch first" behavior: committing directly to the current branch is expected here. If a separate branch seems unavoidable, ask in chat first. When the user has put you on a branch, name it in your replies and never switch away without saying so.

## Plan Before Code

For any task touching multiple files or with more than one reasonable approach: write the approach down first (plan mode for big tasks, a few sentences in the reply for small ones) and check it against **every explicit requirement in the request** before implementing.

## Model Tiering & Delegation

Tiering is **role-based, never model-based**: agents name roles; the concrete model behind each role is bound per session. Worker roles carry a concrete id in their frontmatter, written by `tier-set`/`tier-reconcile` (never by hand); checker roles use `model: inherit` so the checker is never weaker than the claims it checks. Invariant: **the orchestrator is the most capable of the trio, and the expensive tiers (opus/fable) never take the worker seat.** Full playbook and history: `knowledge-base/TIERED_ORCHESTRATION.md`.

| role | binding | delegates to | use for |
|------|---------|--------------|---------|
| **orchestrator** (you) | settings `model` (`/model` moves a running session) | executor, verifier, scout | decompose, delegate, review, decide |
| **executor** | frontmatter (worker tier) | `scout` only | one well-scoped implementation slice |
| **scout** — leaf, no `Agent` tool | frontmatter (recon tier) | — | fan-out recon: find/usages/summaries |
| **verifier** — leaf, no `Agent` tool | `inherit` | — | independent check of one evidence surface; verdict short of CONFIRMED blocks "done" |
| **oracle** — fresh context | `inherit` | — | user-invoked consults only |

Depth: orchestrator → executor → scout, 3 levels max. Scout/verifier leaf-ness is structural (no `Agent` tool); the executor's scout-only limit is a prompt contract. Confirm real nesting via the subagent panel's `(+N)` counts.

### Delegation protocol (operational)

The operational protocol — **standing authorization**, the work-shape dispatch table, and the invariants — ships **globally** via `config/claude-user-memory.md` → `~/.claude/CLAUDE.md` (config sync), so it binds in every project, not just this repo, and applies here with the same force. A per-prompt `[tier]` dispatch line (UserPromptSubmit hook in `config/claude-settings.json`) reinforces it against drift. Repo-specific addendum: a small odd job no role fits may go to any agent with an explicit cheap `model` — `tier-gate` injects the worker tier if `model` is omitted.

### Model selection (one lever)

`/model <top>` is the primary lever: it moves the running orchestrator and, via the `tier-reconcile` hook, re-derives worker/recon on the next prompt. `/tier <top>` does the same bind explicitly; bare `/tier` prints the trio. Derivation (ladder `fable > opus > sonnet > haiku`): worker = one rung down **capped at sonnet-class**, recon = one below the worker, floored at haiku — so `fable`/`opus` → sonnet/haiku, `sonnet`/`haiku` → haiku/haiku. `/tier <top> <worker> [<recon>]` pins any explicit combo until a 1-arg `/tier` clears it.

- Agent files are snapshotted at session start: binding changes land in **new** sessions; for a one-off in-session tier, pass `model` on the `Agent` call.
- **Never set** `CLAUDE_CODE_SUBAGENT_MODEL` or any `ANTHROPIC_DEFAULT_*_MODEL` var — they collapse the tiers and corrupt the `/model` picker; the tier scripts purge them on sight.
- Off-ladder `.model` values are left unmanaged (never clobbered). A model-not-found at spawn time: re-bind with `TIER_PROBE=1 tier-set <top>` (probes and degrades downward). Fable 5 is active — never assume it is unavailable.
- After an image rebuild, the SessionStart reconciler re-derives everything from `.model` automatically.

Spawn-time enforcement (all fail open, `tests/tier-hooks.bats`): `tier-gate` injects the worker tier into generic spawns that omit `model`; `workflow-lint` denies workflow scripts whose `agent()` calls omit `model:`; `cost-mirror` shows per-prompt spend, now with per-model dollars, estimated tier savings, and a drift clause read from `delegation-gate`'s own state (`tier-cost` prints the full per-model table). An explicit `model` always wins. `delegation-gate` (PreToolUse, fail-open, `tests/delegation-gate.bats`) separately counts consecutive main-loop inline work-tool calls — subagents are never gated. Mode is two-axis, default **`guard`**: `off` (silent allow) · `warn-only`/`warn` (nudges, never denies) · `guard` (Edit/Write/NotebookEdit denied in the main loop unless carved out; reads/Bash never denied) · `enforce` (guard plus reads/Bash denied once streak reaches `DELEGATION_GATE_DENY_AT`, default 8) — set via `DELEGATION_GATE_MODE` or `~/.claude/delegation-gate.mode`; an unrecognized value falls back to `guard`, never a weaker one. The warn note repeats (watermarked, not one-shot): first fires at streak `DELEGATION_GATE_WARN_AT` (default 4), then every `DELEGATION_GATE_WARN_EVERY` (default 8) — 4, 12, 20 …, escalating wording at 2×/6× warn_at — because a warn that fires once per session stops steering a session that ignores it. Edit/Write under guard/enforce is carved out for the orchestrator's own seat — `~/.claude/plans/**` and the harness auto-memory dir — proven from an explicit path or denied; `/tmp` and the scratchpad are deliberately not carved out. Session-close/verification Bash (`bd`, `git` incl. commit/push, `bats`, `run-tests`, `take-screenshot`, …) is exempt throughout. `scripts/tier-prime.sh` owns the tier-reminder wording for both SessionStart and PreCompact, so a compaction re-injects the trio and the dispatch/standing-authorization text rather than losing it.

**Oracle is user-invoked only — never spawn it unprompted.** Its leverage is a clean context: refute-first, verdict-first. Choke points where you may note *once* that a consult is available: a plan for a large/risky implementation, a bug surviving two different fix attempts, a one-way-door decision, a significant diff about to be pushed. Before consulting, check `bd` memories and the knowledge-base index; send a distilled brief (goal, constraints, what was tried, the exact question, file pointers — never pasted diffs), then act on the verdict. `advisorModel` must stay ≥ the session's top tier.

**Never pay twice (capture rule).** When a consult or hard-won debugging yields a reusable insight, distill it immediately: `bd remember` for project facts; a `knowledge-base/` doc + index row for step-shaped playbooks.

## Verification

**Run code, don't guess — and verify by running the actual application.** Code inspection isn't enough: run the app, hit the endpoint, screenshot the UI (`take-screenshot term "<cmd>"` for CLIs, `take-screenshot url <URL>` for web, `curl` for APIs). Code-based tests are for regression protection, not for verifying current work. Before reporting done: "Did I actually see this working?"

**The environment must be able to run the program — if it can't, fixing that is part of the task.** Install whatever is missing and continue; never fall back to inspection or an artificial test because a dependency was absent. When a runtime dependency is missing from the image, also add it to the `Dockerfile` so the gap never recurs.

## Noticed Flaws — Fix or Surface

**If you notice a problem in your own work — a flaw, unhandled edge case, shortcut — fix it before delivering or state it explicitly in the final answer.** Silently shipping a noticed flaw is the worst failure mode; "I'll mention it if asked" is not an option. Before delivering: re-read the original request, check each explicit requirement against the result, confirm you saw it working.

## Logging

`dev-log run|decision|error|change|show` records the session at `/workspace/.claude/logs/`. Log test/build/deploy runs (pass or fail), architecture-affecting decisions, unexpected errors, and non-obvious changes — not trivial reads. `dev-log show` at session start shows what happened before you.

## Files, Screenshots & Attachments

- The host home directory is mounted **read-only** at its original path, so pasted/dragged host paths under `/Users/<you>` or `/home/<you>` resolve directly; `grab <path>` translates anything else. `/workspace/attachments/` (gitignored) is the shared drop directory — check it (`ls -lt`) when the user mentions a file or screenshot; view images with the Read tool.
- `take-screenshot url <URL>` (Playwright; `--full-page`, `--device "iPhone 11"`), `take-screenshot display` (Xvfb), `take-screenshot term "<command>"` (termshot). Screenshots land in `/workspace/attachments/` — these are your primary verification tools.

## Cleanup

`disk-cleanup` sweeps ephemeral artifacts automatically at container and session start (stray `/tmp` test dirs >1d, attachments >7d, logs line-capped); run `disk-cleanup --dry-run` to preview. It never touches git-tracked source. Remove finished `/workspace/.claude/plans/` entries yourself. Details: `knowledge-base/DISK_SPACE.md`.

## Beads — Container-Specific Rules

Beads runs in **embedded Dolt mode** (no server); the full command reference and session-close protocol arrive via the `bd prime` SessionStart hook — refer to that block. Container specifics:

- **Beads are Claude Code's own task memory — never a human's, in any form.** Two failure shapes are equally forbidden, not just the obvious one: (1) **direct assignment** — a human assignee, or bead text that hands work to the user ("review this", "decide X", "run Y"); (2) **indirect routing** — a `blocked` status, a dependency, a `bd gate create` (defaults to `--type=human`), or the `human` label used so a person, rather than Claude, is the one who must act to unblock the bead. A dependency or a human-gated block is still an assignment to a person wearing a different hat.
- The chat path, with its precondition intact: when Claude has genuinely **exhausted its own options** and still needs a human decision, it asks **in chat, at the moment the question arises** — it never banks the question as tracked work. Reaching for chat before investigating is the opposite failure and equally wrong.
- `bd-guard` (PreToolUse) mechanically enforces this: human assignees, the `human` label, and a default/`human`-type gate are hard-blocked with no override; user-directed bead text is soft-blocked with a redirect to chat. `BD_GUARD_ALLOW=1` overrides the text check only, for genuine false positives (the phrase is quoted content or code, not real pending user work) — never to park user work in a bead.
- The Dolt DB at `.beads/embeddeddolt/` (gitignored) is the source of truth; `.beads/issues.jsonl` is a passive git-tracked export. `bd doctor` is unsupported in embedded Dolt mode (confirmed no-op); repair with `bd init --prefix <p> --quiet --non-interactive && bd import` instead — see `knowledge-base/BEADS_TROUBLESHOOTING.md` if `bd init` itself refuses. Use `bd update` flags, never `bd edit` (blocks on `$EDITOR`). Reference bead ids in commit messages.
- **Memory precedence:** project knowledge → `bd remember` (syncs with the repo). The harness's own auto-memory is for user-specific context only — never project facts.

## Project Contexts

Per-project-type rules (`config/contexts/<name>.md`, staged at `/etc/claude-dev/contexts/`) are injected at session start by `context-detect` only when workspace markers match; non-matching projects pay zero tokens. **Injected context rules are binding — same force as this file.** Override manifest `.claude-dev/contexts`: bare name force-injects, `!name` suppresses.

## Working Inside a Larger Repo

Dropping the template into a subdirectory of a bigger repo nests a `.git/` (for beads sync) that blocks `git add` from the parent — run `./claude-dev --teardown` from the host before pushing back; it snapshots beads and removes template artifacts. Playbook: `knowledge-base/TEARDOWN_RECOVERY.md`.

## Knowledge Base

Curated playbooks live at `/opt/claude-dev/knowledge-base/` (repo: `knowledge-base/`); its `README.md` is the keyword index. Check it before debugging infrastructure or consulting the oracle — the answer may already be paid for. Contribute solved-once problems back per that README.

## Experience Testing

`run-tests.sh [smoke|experience|multi-project|all]` verifies the environment. **It tests the baked image, not your working tree** — for repo edits run `CLAUDE_DEV_TESTS=/workspace/tests run-tests.sh smoke` (or `bats /workspace/tests/<file>.bats` directly). Assertions against staged artifacts (`/etc/claude-dev/`, `/opt/claude-dev/`, `/usr/local/bin/`) stay red until the next host rebuild — staleness, not regression (`knowledge-base/CONFIG_SYNC.md`).

## Quick Reference

| Shortcut | Command |
|----------|---------|
| `cs` / `csd` | `claude --dangerously-skip-permissions` (+ `--debug`) |
| `cn` | `claude` (normal mode) |
| `menu` | Setup/options menu |
| `gs` | `git status` |
| `dlog` | `dev-log` |
| `cse` | `csearch` |
| `ss` | `take-screenshot` |
| `hx` / `vim` | Helix editor |


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- **Beads are ONLY for Claude Code's own work — NEVER assign a bead to a human, directly or indirectly.** No human assignee, no "review this"/"decide X"/"run Y" bead text, and no parking a bead in a blocked status, dependency, or gate/label (`bd gate create` defaults to `--type=human`; the `human` label) so a person has to act instead of Claude. If a human decision is genuinely needed after Claude has exhausted its own options, ask in chat now — never bank it as a bead.
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**Commit locally, always. Push only when asked, in that moment.**

**When ending a work session**, you MUST complete the local steps below — that local commit is the terminal state of a successful session, complete on its own. Push (`git push`, `bd dolt push`, or any other sync to a remote) is never a session-close obligation: run it only when explicitly asked to push right then, and otherwise leave the remote alone. An unavailable, unauthenticated, or unreachable remote is a **normal condition** in this container — never report a skipped or failed push as an incomplete session.

**This overrides, by name, the "🚨 SESSION CLOSE PROTOCOL 🚨" checklist (and its "Git workflow" / "Common Workflows" push mentions) that the `bd prime` SessionStart hook injects every session.** That text is compiled into the `bd` binary itself — confirmed via `strings /usr/local/bin/bd` (hits at two offsets) and via `bd config list` / `bd help config`, neither of which exposes any key that governs it — so it cannot be edited at the source and is overridden here instead. Its `git push` step and "work is not done until pushed" framing do not apply in this project; this section is authoritative.

**MANDATORY WORKFLOW (local):**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Commit locally** - This is MANDATORY:
   ```bash
   git add <files>
   git commit -m "..."
   git status  # confirm a clean tree on the current branch
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed locally
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is complete once committed locally — a session is never incomplete merely because nothing was pushed.
- NEVER skip the local commit - that's what leaves work unrecorded.
- Push only when explicitly asked, in that moment. `git push` and `bd dolt push` (beads' Dolt history sync over `refs/dolt/data`, to the same git remote) follow the identical rule — both opt-in, neither a default closing step.
- If a requested push fails or the remote is unavailable, report it plainly and stop there — do not retry unprompted, and do not downgrade an otherwise-complete local session to "incomplete".
<!-- END BEADS INTEGRATION -->
