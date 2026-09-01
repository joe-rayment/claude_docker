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

## Code Map — Structure Queries Before Grep

**Structure questions go to the map before they go to grep.** What calls X · what breaks if I touch Y · how do A and B connect → `code-map explain <sym>`, `code-map affected <file>`, `code-map path A B`, `code-map query "<q>"`. `csearch` stays first for content: literal strings, TODOs, config values, anything textual.

- The `[code-map]` block at session start advertises the map — node/link counts and `built at <sha8> (fresh|STALE)`. STALE means the graph predates HEAD: `code-map refresh` rebuilds it, `code-map status` re-checks any time.
- `code-map report` (GRAPH_REPORT.md) and `code-map html` are the human-readable views; `tree` and `god-nodes` show shape.
- **INFERRED edges are hints, not facts** — confirm one against the code before acting on it.
- Upgrade the engine **only** via `code-map upgrade [version]` (home-volume override) or a Dockerfile pin bump. `graphify install|uninstall|hook` are blocked in this container: they overwrite assistant config (CLAUDE.md sections, `~/.claude` hooks and skills, per-platform rules).
- Playbook: `knowledge-base/CODE_MAP.md`.

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

## Complexity Router — Lanes

**Route before you act.** The first action on every prompt is `lane express|standard|deep [--why "…"]` — an exempt Bash call declaring the route and this prompt's ceremony budget for `delegation-gate`. `lane --prime` is the **authoritative wording**, re-injected at SessionStart and PreCompact; design and tuning knobs: `knowledge-base/TIERED_ORCHESTRATION.md`.

- **express** — ALL of: ≤1 file (or none), mechanical/cosmetic or answerable from context/one lookup, no design choice, trivially reversible, no new dependency/interface/contract. → inline now; no plan, bead, executor, or verifier.
- **standard** — one well-understood slice, low-to-moderate risk, no architectural choice. → one-sentence approach, then inline or ONE executor slice; verify by running the result once.
- **deep** — ANY of: ≥3 files or an interface/schema/config contract (a multi-file *mechanical* change — a rename, a repeated edit with no design choice — is standard, not deep), real tradeoffs, ambiguity needing interpretation, hard to reverse, security/data-integrity surface, or thoroughness asked for. → write the approach down and check it against every explicit requirement first; then beads with acceptance contracts, executor slices, verifier sign-off — one verifier run may cover several beads sharing an evidence surface, so batch them; verifiers are per evidence surface, never per bead.

**Recon breadth is not implementation depth:** many files read with ≤2 files changed routes standard — scouts deliver deep-grade evidence in any lane.

**Ties go to the lighter lane**; tripwires (scope outgrows the rubric, a fix attempt fails, hidden ambiguity, unexpected breakage) escalate exactly one lane and never de-escalate within the same prompt. When genuinely unsure between standard and deep, declare standard — tripwires self-correct upward mid-prompt; over-routing has no correction path.

**Scope discipline is part of the rubric**: answer the request as asked, never its maximal interpretation — an adjacent issue noticed mid-task gets one line, never investigation, and binds subagents too (`config/agents/*.md`).

**User override always wins:** "quick"/"just" bias light, "plan"/"thorough"/"audit" force deep — visible in the transcript so the user can redirect immediately.

## Model Tiering & Delegation

Tiering is **role-based, never model-based**: `tier-set`/`tier-reconcile` write the worker tier into agent frontmatter (never by hand); checkers use `model: inherit`, never weaker than the claims they check. Invariant: **the orchestrator is the most capable of the trio, and by default the expensive tiers (opus/fable) never take the worker seat** — `/tier overdrive` is the sanctioned exception: opt-in, sticky (it follows `/model`), named on every session-start tier line, and cleared by a 1-arg `/tier <top>`. Playbook and history: `knowledge-base/TIERED_ORCHESTRATION.md`.

Bindings: **orchestrator** — settings `model`; **executor** — worker tier, delegates to `scout` only; **scout** — recon tier, leaf (no `Agent` tool); **verifier**/**oracle** — `model: inherit`, leaf. Depth: orchestrator → executor → scout, 3 levels max.

### Delegation protocol (operational)

The operational protocol (standing authorization, lane-first dispatch, invariants) ships globally via `config/claude-user-memory.md` → `~/.claude/CLAUDE.md` and binds here with the same force. Repo addendum: a small odd job no role fits may go to any agent with an explicit cheap `model`; `tier-gate` injects the worker tier if `model` is omitted.

### Model selection (one lever)

`/model <top>` moves the orchestrator and, via `tier-reconcile`, re-derives worker/recon next prompt; `/tier <top>` binds explicitly, bare `/tier` prints the trio, `/tier <top> <worker> [<recon>]` pins a combo until a 1-arg `/tier` clears it. Derivation (ladder `fable > opus > sonnet > haiku`): worker = one rung down **capped at sonnet-class** (lifted by `/tier overdrive`), recon = one below the worker, floored at haiku. Bindings snapshot at session start, landing in **new** sessions; pass `model` on the `Agent` call for a one-off, and re-bind a missing model with `TIER_PROBE=1 tier-set <top>` (Fable 5 is active — never assume otherwise).

- **Never set** `CLAUDE_CODE_SUBAGENT_MODEL` or any `ANTHROPIC_DEFAULT_*_MODEL` var — they collapse the tiers and corrupt the `/model` picker; the tier scripts purge them on sight.

Spawn-time enforcement, all fail-open (`tests/tier-hooks.bats`, `tests/delegation-gate.bats`): `tier-gate` injects the worker tier into spawns omitting `model` (explicit `model` wins), `workflow-lint` denies `agent()` calls omitting `model:`, `cost-mirror` reports spend and tier savings, `delegation-gate` (default `guard`) gates runs of inline main-loop work-tool calls — subagents never.

**Oracle is user-invoked only — never spawn it unprompted.** You may note *once* that a consult is available at a choke point (a large or risky plan, a bug surviving two fix attempts, a one-way door, a significant diff about to be pushed). Check `bd` memories and the knowledge-base index first, then send a distilled brief (goal, constraints, what was tried, the question, file pointers — never diffs) and act on the verdict. `advisorModel` must stay ≥ the session's top tier.

**Never pay twice (capture rule).** When a consult or hard-won debugging yields a reusable insight, distill it: `bd remember` for project facts, a `knowledge-base/` doc + index row for step-shaped playbooks.

## Delegation Routes

**Routes are quota relief and parallel implementation, not cost savings.** Subscription tokens are free at the margin inside this container — routing a slice to `config/delegate-routes.json` only pays off when native capacity is rationed (parallel slices in flight, a long queue) and it buys headroom, never a cheaper token. Playbook: `knowledge-base/DELEGATION_ROUTES.md`.

Grade rubric:

- **executor-grade** (`glm`) — contract-backed, token-heavy, or parallelizable implementation slices. Runs headless in an ephemeral git worktree on its own branch; that branch merges only after a native `verifier` PASS, never on the delegate's own say-so.
- **scout-grade** (`local`) — bulk recon/summarisation only, prompt-only (`--prompt`/`--prompt-file`); never `--bead`.
- **Express lane never delegates** — inline or nothing.

**Planning, acceptance contracts, verification, and merge are always native.** A route executes a slice; it never sets scope, writes its own acceptance contract, judges its own work, or merges itself in.

**User words override**, same as every other lane call.

Commands: `delegate run --route <route> (--bead <id> | --prompt <text> | --prompt-file <file>)`, `delegate check`, `delegate ps`, `delegate report` (per-route verdict rates + dollars).

## Verification

**Run code, don't guess — and verify by running the actual application.** Run the app, hit the endpoint (`curl`), screenshot the UI (`take-screenshot url|term|display`); code inspection isn't enough, and code-based tests are regression protection, not verification of current work. Before reporting done: "Did I actually see this working?"

**Verification is lane-scoped** — every lane verifies, they differ in how much: express, one run or screenshot when the change is observable (else the diff); standard, run the result once; deep, the full independent-verifier treatment against a registered acceptance contract.

**The environment must be able to run the program — if it can't, fixing that is part of the task.** Install whatever is missing and continue; never fall back to inspection or an artificial test because a dependency was absent, and add anything missing from the image to the `Dockerfile` so the gap never recurs.

**Acceptance contracts replace open-ended re-verification at close time.** Before an executor is dispatched, register a `CHECK`/`PASS-IF`/`FROZEN`/`CLASS` block on the bead's `--acceptance` field. The executor works red-commit-first — **observe RED**, commit the test alone, implement, rerun the same `CHECK` to **GREEN** — appending `RED-AT`/`GREEN-AT` shas and the real output to the bead's notes (`config/agents/executor.md`). `FROZEN` binds from `RED-AT` only until that bead's own verification completes (`knowledge-base/ACCEPTANCE_CONTRACTS.md`).

The verifier runs five mechanical checks instead of re-deriving the work: **C1** goalposts unmoved (`bd history`), **C2** frozen test not weakened (`git diff <RED-AT> HEAD` empty), **C3** actually green (`CHECK` run verbatim, tree clean), **C4** honest (implementation diff read for hardcoding/skips/env-detection — the one judgment step), **C5** not lazily closed (no human hand-off, no silently narrowed scope). Verdicts: `PASS` / `FAIL` / `TAMPERED` / `NO-CONTRACT` (`config/agents/verifier.md`). One verifier run may cover several beads sharing an evidence surface — batch them; verifiers are per evidence surface, never per bead. `CLASS: no-contract`, the escape hatch for work with no observable check, is assignable only at registration — never at close — and skips the verifier. `contract-gate` nudges a `bd close` lacking a contract or a recorded `VERIFIED: PASS` in `warn` mode (default), blocks it in `enforce`, is silent in `off`. None of this replaces running the app and looking at it.

## Noticed Flaws — Fix or Surface

**If you notice a problem in your own work — a flaw, unhandled edge case, shortcut — fix it before delivering or state it explicitly in the final answer.** Silently shipping a noticed flaw is the worst failure mode; "I'll mention it if asked" is not an option. Before delivering: re-read the original request, check each explicit requirement against the result, confirm you saw it working.

**This rule covers Claude's own delivered work product, and stops there.** A pre-existing problem in adjacent code is not a noticed flaw in your work: mention it in one line if it matters, never investigate it, never fold it into the task, and never treat it as a reason to escalate the lane.

## Logging

`dev-log run|decision|error|change|show` records the session at `/workspace/.claude/logs/`. Log test/build/deploy runs (pass or fail), architecture-affecting decisions, unexpected errors, and non-obvious changes — not trivial reads. `dev-log show` at session start shows what happened before you.

## Files, Screenshots & Attachments

- The host home directory is mounted **read-only** at its original path, so pasted/dragged host paths under `/Users/<you>` or `/home/<you>` resolve directly; `grab <path>` translates anything else. `/workspace/attachments/` (gitignored) is the shared drop directory — check it (`ls -lt`) when the user mentions a file or screenshot; view images with the Read tool.
- `take-screenshot url <URL>` (Playwright; `--full-page`, `--device "iPhone 11"`), `take-screenshot display` (Xvfb), `take-screenshot term "<command>"` (termshot). Screenshots land in `/workspace/attachments/` — these are your primary verification tools.

## Cleanup

`disk-cleanup` sweeps ephemeral artifacts automatically at container and session start (stray `/tmp` test dirs >1d, attachments >7d, logs line-capped); run `disk-cleanup --dry-run` to preview. It never touches git-tracked source. Remove finished `/workspace/.claude/plans/` entries yourself. Details: `knowledge-base/DISK_SPACE.md`.

## Beads — Container-Specific Rules

Track **all** work in `bd` (beads) — never TodoWrite, TaskCreate, or markdown TODO lists; `bd prime` (SessionStart hook) carries the full command reference and session-close protocol.

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

- **Never assign work to a human, directly or indirectly** — the authoritative rule ships via `config/claude-user-memory.md` (deployed as `~/.claude/CLAUDE.md`) and binds here; if a human decision is genuinely needed after exhausting your own options, ask in chat now. `bd-guard` (PreToolUse) enforces it mechanically; `BD_GUARD_ALLOW=1` overrides its text check only, for genuine false positives (quoted content or code, not real pending user work) — never to park user work in a bead.
- **Bead filing is lane-scoped. This overrides, by name, the `bd prime` line "**Workflow**: Create beads issue BEFORE writing code, mark in_progress when starting"** — a deep-lane rule here, not a universal one. Express files **no** bead; standard files one only when follow-up genuinely remains after the slice; deep keeps the full protocol — a bead per slice, with `CHECK`/`PASS-IF` acceptance contracts on any non-trivial claim. Beads for genuine future work are filed in any lane: the override targets ceremony before a one-line edit, never real follow-up.
- **Storage:** beads runs in **embedded Dolt mode** (no server) — the DB at `.beads/embeddeddolt/` (gitignored) is the source of truth, `.beads/issues.jsonl` a passive git-tracked export, sync riding `refs/dolt/data` ([concepts](https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md)). `bd doctor` is a confirmed no-op there; repair with `bd init --prefix <p> --quiet --non-interactive && bd import` instead — `knowledge-base/BEADS_TROUBLESHOOTING.md` covers a refusing `bd init`.
- **Mechanics:** `bd update` flags, never `bd edit` (blocks on `$EDITOR`); reference bead ids in commit messages.
- **Memory precedence:** project knowledge → `bd remember`, never MEMORY.md files; the harness's auto-memory is user-specific only.

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


## Session Completion

**Commit locally, always. Push only when asked, in that moment.** When ending a work session you MUST complete the local steps below — that commit is the terminal state of a successful session, and skipping it is what leaves work unrecorded. Push (`git push`, `bd dolt push`, any remote sync) is opt-in: run it only when explicitly asked right then. An unavailable, unauthenticated, or unreachable remote is a **normal condition** here — report a failed push plainly, don't retry it unprompted, and never downgrade an otherwise-complete session to "incomplete" over it.

**This overrides, by name, the "🚨 SESSION CLOSE PROTOCOL 🚨" checklist (and its "Git workflow" / "Common Workflows" push mentions) that the `bd prime` SessionStart hook injects every session.** That text is compiled into the `bd` binary — verifiable via `strings /usr/local/bin/bd` — so it cannot be fixed at source. Its `git push` step and "work is not done until pushed" framing do not apply here; this section is authoritative.

**MANDATORY WORKFLOW (local):**

1. **File issues** for anything needing follow-up
2. **Run quality gates** if code changed
3. **Update issue status** — close finished work
4. **Commit locally — MANDATORY:** `git add <files>` · `git commit -m "..."` · `git status` (clean tree, current branch)
5. **Clean up** stashes and pruned branches
6. **Verify** everything is committed
7. **Hand off** context for the next session

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
<!-- merged above; markers kept so bd skips re-injection -->
<!-- END BEADS INTEGRATION -->
