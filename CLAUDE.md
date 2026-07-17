# CLAUDE.md — Claude Code Development Container

## Environment

You are running inside a Docker container. Your workspace is at `/workspace` (bind-mounted from the host). Your home directory `/home/agent` is a persistent Docker volume — auth, git config, and shell history survive rebuilds.

Key tools: Git, GitHub CLI (`gh`), Python 3, Node.js, Go, Helix editor (`hx`).

## Config Customization

Config files are synced from the Docker image on startup (checksum-based). To persist personal customizations across rebuilds, use `.local` override files:

| Config | Override file | Mechanism |
|--------|--------------|-----------|
| Shell | `~/.zshrc.local` | Sourced at end of `.zshrc` |
| Claude Code | `~/.claude/settings.local.json` | Deep-merged into `settings.json` on startup |

Helix (`~/.config/helix/config.toml`) and IntelliShell (`~/.config/intelli-shell/config.toml`) can be edited directly — they only get overwritten when the image config checksum changes.

Merge semantics for `settings.local.json`: objects deep-merge (local wins per key); the `permissions.allow`/`deny`/`ask` arrays are **unioned** with the base lists; any other array is replaced wholesale. If the local file contains invalid JSON, the entrypoint warns and skips the merge rather than corrupting `settings.json`.

## Core Principle

**Run code, don't guess.** Execute commands, run tests, check output. If you're unsure whether something works, run it.

## Searching Code — `csearch`

`csearch` fuses discover + grep + read + signature into one local command (ripgrep under the hood — no network, no login, no telemetry). Prefer it for code search: one call instead of separate glob → grep → read round-trips, and it caps long lines so minified files don't blow up context.

```bash
csearch "useAuth" 'src/**/*.ts'   # grep, scoped to a glob (or a literal path)
csearch -l -t py "TODO"           # files-only, restricted to a ripgrep type
csearch -i -C 2 "def main"        # case-insensitive, 2 lines of context
csearch read src/app.ts 40-80     # read just lines 40–80, line-numbered
csearch sig 'src/**/*.go'         # signatures/structure (funcs, classes, types)
```

Flags for the default search mode: `-i` ignore case, `-C N` context lines, `-l` list files only, `-t TYPE` ripgrep file type, `-m N` max matches per file. Trailing args are literal paths if they exist, otherwise globs. No matches exits 0 (not an error).

## Answer Style — Selective, Answer-First

**Shortness comes from selecting content, not compressing wording.** Decide what the reader actually needs — drop everything else — then write what remains in plain, complete sentences. Do not shorten by chopping grammar into fragments or abbreviating; terseness of style is not the goal, absence of filler is.

- **Lead with the outcome.** The first sentence answers "what happened" or "what did you find" — the thing the user would ask for if they said "just the TLDR." Supporting detail comes after, and only if it changes what the reader does next.
- **Cut, don't volunteer**: process narration (what you explored, every file touched), caveats, alternatives, background, root-cause essays, and "what I could do next" all go — unless asked. Trust the user to ask follow-ups.
- **No structural bloat.** Simple answers get prose, not headers, bullet lists, tables, or "Summary" sections. No preambles ("Great question…", "I'll now…") or postambles ("Let me know if…").
- **Match size to question.** Yes/no gets yes/no plus at most a one-line why. A finished task reports in one to three sentences: what changed, where, how it was verified.
- **Brevity never costs correctness.** Code, commands, file paths, and exact values stay complete and accurate — never abbreviate those.

## Ownership — Never Assign Work to the User

**NEVER assign the user tasks.** You own the work end to end. Do not hand the user a to-do list, "next steps you should run", "verification owed by you", checklists of commands to execute, or anything framed as theirs to complete. The user directs; Claude executes.

- If something genuinely cannot be done or verified in this environment (e.g. a host-side `./claude-dev --rebuild` that must run outside the container), state it plainly as an **environment limitation**, do the best verification available here, and carry it as your own open item — do not delegate it back to the user.
- Don't end responses by telling the user to run, close, push, or check things you could do yourself. Just do them.
- **Don't ask the user to do something you have enough information to do or figure out yourself** (e.g. "run the following to confirm", "check whether X"). Run it, read it, work it out — then report the result.
- **Never ask the user to confirm details they've already given you.** Re-read the conversation before asking; if the answer is already there, use it. Only ask when information is genuinely missing and you cannot obtain or infer it yourself.
- Offering a choice when a decision is genuinely the user's to make is fine. Handing over execution work, or re-asking for what you already know, is not.

## User Constraints Are Binding

**Explicit user choices are hard constraints, not suggestions.** If the user specified a tool, library, approach, flag, browser mode (e.g. headed vs headless), naming, or anything else, that choice is fixed. Never silently substitute an alternative you consider better — a "better" result that violates a stated constraint is a failed task.

- **Disagree once, out loud.** If a constraint seems wrong, say so once and ask. If the user confirms it — or you can't ask — implement exactly what was asked. Never encode your preference in the diff.
- **Debugging is where constraints die.** When something fails, fix it *within* the user's constraints; removing the constraint is not a fix. If the constraint itself blocks the fix, stop and report that — don't route around it.
- **A past decision stays decided.** If the user already rejected an approach in this project or conversation, do not reintroduce it later — not in a refactor, not in a fix, not "temporarily."
- **Pre-delivery check:** re-read the original request and scan the final diff/output for any place a stated constraint was quietly altered. If one was, undo it before delivering.

## Plan Before Code

For any task touching multiple files, or with more than one reasonable approach: write the intended approach down first — plan mode for big tasks, a few sentences in the reply for smaller ones — and check it against **every explicit requirement in the request** before implementing. This is cheap insurance against two failure modes: drifting away from what was asked, and noticing a problem mid-implementation and pushing past it.

## Model Tiering & Orchestration — Spend Where It Compounds

Tiering here is **role-based, never model-based.** Agents name *roles*; the concrete model behind each role is bound per session, so nothing breaks when models rotate. Worker roles are pinned to **alias slots** in their frontmatter; the checker roles (verifier, oracle) use **`model: inherit`** so they always run exactly the orchestrator's model — the checker is never weaker than the claims it checks. The invariant: **the orchestrator is the most capable model of the three** — enforced structurally now, because the lower two slots are *derived* from the top as the next two consecutive rungs down (see *Per-session model selection* below), not chosen independently.

| Tier / role | Model binding | Default | Can delegate to | Use for |
|------|------|---------------|-----------------|---------|
| **orchestrator** = you, the main session | `--model opus` at `tier` launch, else settings `model` | Opus 4.8 (settings default may differ) | executor, verifier, scout | decompose, delegate, synthesize, decide |
| **executor** (`executor` agent) | `sonnet` slot | Sonnet 5 | `scout` only | one well-scoped implementation slice, end to end |
| **scout** (`scout` agent) — **leaf** | `haiku` slot | Haiku 4.5 | — (no `Agent` tool) | fan-out recon: find/usages/summaries |
| **verifier** (`verifier` agent) — **leaf** | `inherit` | = orchestrator | — (no `Agent` tool) | independent check of one worker claim |
| **oracle** (`oracle` agent) — fresh context | `inherit` | = orchestrator | — | user-invoked consults only |

The tree tops out at **orchestrator → executor → scout = 3 role-levels**. The leaves are *structurally* enforced: scout and verifier carry no `Agent` tool, so they physically cannot spawn children. The executor's scout-only limit is a **prompt contract, not a harness guarantee** — parameterized `Agent(scout)` grants are honored for main-thread agents but the type restriction is ignored for subagent-spawned agents, so the executor relies on its own "Never" rules plus Claude Code's hard depth-5 ceiling. Confirm nesting actually happened via the **subagent panel** below the prompt — each row shows a `(+N)` descendant count; a flat call means your "delegation" collapsed.

**Delegation-down is the default; depth 2 is the default, 3 is the ceiling.** Decompose, hand executors independent slices, synthesize their compressed returns. Add the 3rd level (executor spawning scout, or a verifier fan-out) only when volume or an independent check earns it. **Shallow beats deep:** before a parent delegates, it must expect the child to do real work and return a *compressed* result — if you could produce it in a couple of tool calls, don't delegate. A bad decomposition poisons every worker under it, so keep the strongest model (you) on decomposition and synthesis and push bulk/mechanical work down; the cost leverage is in the worker tier, not in you doing the volume.

**Upward escalation** is the alternative pattern, for debugging and genuinely uncertain work: the leaf attempts the task and calls a stronger tier *only when stuck*, so you pay the higher tier only on real failures. The oracle path already encodes this (scout/you try, escalate to the oracle when a bug survives two fixes). Use escalation when you can't cleanly decompose up front; use delegation-down when you can.

**Scout first.** For searches, usage listings, and directory summaries, spawn `scout` (several in parallel for independent questions) instead of burning your own context — prefer it over the built-in Explore agent.

### Trust, but verify — the orchestrator's standing policy

A worker's summary is an **input to check, not a fact.** Any non-trivial worker output is verified *independently*, by a `verifier` with fresh context and no stake in the answer — never by the worker grading itself (a model asked to recheck its own reasoning rationalizes a plausible-but-wrong result).

- **Verification is mandatory** before you declare a task done, after file-writes + test output exist, and on any worker result you will fold into the final answer. **Unverified worker claims are not accepted as done.**
- **How:** research claims are cross-checked against **primary sources**; code changes against **tests/build/an independent read**. Spawn **one `verifier` per finding** so the intermediate checks stay out of your context — the verifier returns a verdict, not a transcript.
- **Proportionate:** skip verification only on trivial/self-evident results (the same threshold as "don't nest this"). Require it wherever a wrong-but-plausible result would propagate. When in doubt, verify — a bad worker output that reaches the final answer is the expensive failure.

The `oracle` (user-invoked, below) is the coarse checkpoint-level version of this for plans and big diffs; the `verifier` is the automatic, per-finding version the orchestrator runs itself.

### Per-session model selection (one top model → the trio derives, no file edits)

The default model and the tier trio are a **single linked thing** so they can't drift. You pick ONE top model; worker and recon are **derived** as the next two consecutive rungs down the ladder (`fable > opus > sonnet > haiku`), clamped at the haiku floor:

| top | → worker (executor) | → recon (scout) |
|-----|--------------------|-----------------|
| `fable`  | opus   | sonnet |
| `opus`   | sonnet | haiku  |
| `sonnet` | haiku  | haiku  |
| `haiku`  | haiku  | haiku  |

Two levers, kept in sync automatically:

```
/model opus                           # PRIMARY in-session lever: moves the running orchestrator AND
                                       #   (via the reconciler, on your next prompt) re-derives the trio
/tier fable                           # explicit set: writes .model=fable + derived slots (fable/opus/sonnet)
/tier claude-opus-4-8                 # a full id works too (dated/variant id kept as-is on top)
/tier opus sonnet                     # 2-arg explicit PIN: worker=sonnet, recon shares the worker slot
/tier opus sonnet haiku               # 3-arg explicit PIN: worker/recon set independently, any combo
/tier                                 # no args: print the current binding + derived trio (writes nothing)
/tier show                            # same as bare /tier
```

A 2- or 3-arg `/tier` **pins** the trio (`.env.TIER_EXPLICIT_PIN="1"`) instead of deriving it — the reconciler then leaves worker/recon alone even as `.model` drifts, until a plain 1-arg `/tier <top>` clears the pin and resumes auto-derivation.

**The reconciler is the mechanism that links them.** `tier-reconcile` (a `SessionStart` + `UserPromptSubmit` hook) reads `.model`, derives the trio via `tier-derive` (the single source of truth for the ladder), and rewrites the `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`(`_NAME`) slots **only if they differ** — idempotent, silent, fast, and skipped entirely while an explicit pin is active. So when `/model` changes the default, the very next prompt re-derives the slots *before* any subagent spawns that turn, and executor/scout always run models consecutive to the current default. This relies on Claude Code re-reading `settings.json` `env` per subagent spawn (verified empirically on 2.1.206; the docs imply a launch-time snapshot, the observed behaviour is a per-spawn re-read).

**The `_NAME` slots keep Claude Code's own `/model` picker honest.** The picker builds its "Opus"/"Sonnet"/"Haiku" menu rows from the *same* `ANTHROPIC_DEFAULT_*_MODEL` vars, and each row's label defaults to the companion `ANTHROPIC_DEFAULT_*_MODEL_NAME` var (confirmed by reading the shipped `claude` binary directly — it's a de-minified JS bundle, greppable with `grep -a`). Without the `_NAME` write the picker silently mislabeled every row (e.g. top=fable showed "Opus"→claude-fable-5, "Sonnet"→claude-opus-4-8); `tier-set`/`tier-reconcile` now also write a canonical display name per slot so the picker always shows the model a row actually is.

The engine behind `/tier` is `tier-set` (`/usr/local/bin/tier-set`, repo `scripts/tier-set.sh`); it probes the top with downward fallback, then derives the trio from the top that actually bound. `tier-derive` and `tier-reconcile` live beside it. What a file write **cannot** move is the **running orchestrator** — this session's own model — and by extension the `model: inherit` agents (verifier/oracle) that track it: only `/model` moves a running orchestrator (it also persists as the new-session default). So `/tier` switches the worker/recon tiers immediately but tells you to run `/model` if you also want to move this session's orchestrator now; `/model` does both. All slots apply to any newly launched session.

- **Off-ladder tops degrade gracefully.** If `.model` is a custom/unknown id the ladder can't place (`best`, a bare `sonnet[1m]`), the reconciler leaves the slots untouched (never clobbers) and `/tier show` flags the top as custom/unmanaged. A full *family* id (`claude-opus-4-8`, even dated) maps to its rung and derives beneath it.
- **Graceful degradation on the top.** The top falls **downward** (fable → opus → sonnet → haiku) if a model is unavailable (gated, out of credits, off-plan, safeguard-rerouted); `tier-set` binds what it actually reached and derives the trio from that. Fable 5 is a first-class candidate — never assume it is unavailable; the probe decides.
- **Footguns to avoid:** never set `CLAUDE_CODE_SUBAGENT_MODEL` — it overrides *every* subagent's model and would collapse all three tiers onto one (`tier-set` removes it). The slot vars in settings `env` are **owned by `tier-set`/`tier-reconcile`** — don't hand-edit them, and don't export them in the shell (settings env overrides shell exports).
- **After an image rebuild**, the config sync resets `settings.json` to the template (which carries the reconciler hook) — re-run `/tier` or just send a prompt (the reconciler re-syncs the slots to `.model`).
- **Residual caveat (unchanged):** a file write can't move the *running* orchestrator; only `/model` can. If you run `/tier` without `/model`, the slots follow `.model` but the running orchestrator stays put until you `/model`.

**Oracle is user-invoked only — never spawn it unprompted.** The oracle inherits your model (always exactly the driver); its leverage is a clean context, not a bigger model — no sunk assumptions, an explicit refute-first mandate, high reasoning effort, and a verdict-first output cap. When a genuine choke point is met — (1) a plan for a large or risky implementation (~5+ files, schema/API/auth, hard to reverse), (2) the same bug survived two genuinely different fix attempts, (3) a one-way-door architecture decision, (4) a significant diff about to be pushed — you may note *once* that an oracle consult is available, then proceed with your own best judgment. The user triggers it ("second opinion", "ask the oracle"); `/advisor` is backed by `advisorModel`, which is pinned to `fable` because the advisor model must be **≥ the session's main model** — if you change the top tier, keep `advisorModel` at or above it. For one-way doors the user can ask for a **panel**: two oracle consults in parallel with different lenses (correctness-first vs simplicity-first) — where they disagree is where to think hardest.

**Consult protocol (when invoked):** first check `bd` memories and the knowledge-base index — the answer may already be paid for. Then send a distilled brief: goal, constraints, what was tried and what happened, the exact question, file pointers. Never paste large code or diffs; the oracle reads the repo itself. Act on the verdict instead of re-asking.

**Model unavailable / not-found.** Because roles bind to alias slots, a retired or gated model degrades automatically via the `tier` fallback — you don't edit agent files. If an agent spawn ever fails with model-not-found anyway (e.g. a slot bound to a model this account can't use), re-run `tier` with an available model for that slot, or let the floor default win. The full playbook (roles, slots, fallback, verification, rollback) is `knowledge-base/TIERED_ORCHESTRATION.md`.

**Never pay twice (capture rule).** When a consult — or your own hard-won debugging — yields a reusable insight (root cause, gotcha, recipe, rule), distill it immediately: `bd remember` for project facts; a `knowledge-base/` doc plus an index row in its `README.md` for step-shaped playbooks. The oracle ends every consult with a `Capture:` line — store it, don't drop it.

## Verification

**Always verify changes by running the actual application** — code inspection isn't enough. Run the app, hit the endpoint, screenshot the UI. For CLI tools use `take-screenshot term "<command>"`; for web UIs use `take-screenshot url <URL>`; for APIs use `curl` or similar. Code-based tests (unit, integration) are for regression protection, not for verifying current work — run them to confirm you haven't broken other things. Before reporting a task as done, ask yourself: "Did I actually see this working?"

**The environment must be able to run the program — if it can't, fixing that is part of the task.** Install whatever is missing (`apt-get install`, `pip install`, `npm install`) and continue; never fall back to code inspection or an artificial test because a dependency wasn't there. When a runtime dependency turns out to be missing from the image, also add it to the `Dockerfile` so the gap never recurs — the container should always include everything needed to run and observe the program.

## Noticed Flaws — Fix or Surface

**If you notice a problem in your own work — a flaw, weakness, unhandled edge case, or shortcut — you must either fix it before delivering or state it explicitly in the final answer.** Silently shipping a flaw you noticed is the worst failure mode: worse than being slow, worse than a longer answer. "I'll mention it if asked" is not an option — if the user would care, it goes in the response, prominently, not buried.

Before delivering, run a self-review pass: re-read the original request, check each explicit requirement against the result, and confirm you saw it working (per [Verification](#verification)). Anything that fails the check gets fixed or flagged — never glossed over.

## Logging

Use `dev-log` to record what happens during your session. Logs live at `/workspace/.claude/logs/`.

| Command | When to use |
|---------|-------------|
| `dev-log run "cmd" pass\|fail "reason" ["detail"]` | After running a command (tests, builds, deploys) |
| `dev-log decision "description"` | When choosing between approaches |
| `dev-log error "what" ["detail"]` | When something fails unexpectedly |
| `dev-log change "what" "why"` | After modifying code or config |
| `dev-log show [category] [N]` | View recent entries |

Log every test run, build, and deploy (pass or fail), decisions that affect architecture or approach, errors with enough detail to diagnose later, and non-obvious changes. Don't log trivial reads or explorations. Run `dev-log show` at session start to see what happened before you.

## Drag-and-Drop File Access

The host user's home directory is mounted read-only at its original path inside the container. This means dragging files from the host into the terminal "just works" — the pasted path resolves to the same file inside the container.

- **macOS**: Files under `/Users/<you>/` are accessible (Desktop, Downloads, Documents, etc.)
- **Linux**: Files under `/home/<you>/` are accessible
- For files outside your home directory, copy them to `/workspace/attachments/` instead

The mount is read-only — the container cannot modify host files outside `/workspace`.

## Sharing Files with Claude

`/workspace/attachments/` is the directory for sharing files between the host and container (host path: `<project>/attachments/`, gitignored). Use the Read tool to view images (PNG, JPG, WebP, PDF).

### When the user shares a file

- If the user mentions a screenshot, image, or file to review, check `/workspace/attachments/` for recent files.
- If the user pastes a path starting with `/Users/` or `/home/`, it's a **host path** — the host home mount makes these resolve directly. For paths outside `$HOME`, look in `/workspace/attachments/`.
- Use `ls -lt /workspace/attachments/` to find the most recently added files.
- The `grab <path>` command translates host paths to container paths.

## Screenshots and Browser Tools

This container has full browser and screenshot capabilities. **Use these as your primary verification tools.**

### Quick Captures

| Command | What it captures |
|---------|-----------------|
| `take-screenshot url <URL>` | Web page via Playwright |
| `take-screenshot url --full-page <URL>` | Full scrollable page |
| `take-screenshot url --device "iPhone 11" <URL>` | Mobile emulation |
| `take-screenshot display` | X11 display (Xvfb) |
| `take-screenshot term "<command>"` | Terminal command output via termshot |

Screenshots save to `/workspace/attachments/` by default. View them with the Read tool (supports PNG, JPG, WebP).

### Verification Examples

```bash
# Verify a web app change
take-screenshot url http://localhost:3000

# Verify an API endpoint
curl -s http://localhost:8080/api/health | jq .

# Verify a CLI tool
take-screenshot term "my-tool --version"
```

## Cleanup

A `disk-cleanup` sweep runs automatically at container start (entrypoint) and at each Claude session start (SessionStart hook), so ephemeral files stay bounded without manual effort. It is best-effort, age-gated, and size-capped — it only touches known-ephemeral artifacts and never git-tracked source or the harness transcript store. It:

- sweeps stray test temp dirs in `/tmp` (`tmp.*`, `bats-run-*`, `*.bats`, `claude-test-*`, `csearch-test-*`) older than 1 day;
- deletes `/workspace/attachments/` files (screenshots, dropped files) older than 7 days;
- caps each append-only `/workspace/.claude/logs/*.log` to its last 5000 lines (these are monolithic, so they're line-capped, not age-rotated).

Run it by hand any time — `disk-cleanup` to sweep now, `disk-cleanup --dry-run` to preview. Override retention via env: `TMP_AGE_MIN`, `ATTACH_AGE_DAYS`, `LOG_MAX_LINES`. Still remove `/workspace/.claude/plans/` entries yourself when a plan is done — those aren't age-swept.

The root-cause fix that made this necessary rare: `tests/*.bats` route all scratch under bats's per-test tmpdir, which bats auto-removes on pass **or** fail, so a failing test can no longer strand its temp dir (some held multi-MB `bd init` Dolt DBs).

## Beads (Agent Memory)

This environment uses [Beads](https://github.com/gastownhall/beads) (`bd`) for persistent task tracking across sessions, in **embedded Dolt mode** (no SQL server). The full command reference and session-close protocol are auto-injected each session via the `bd prime` SessionStart hook — refer to that block, not a duplicate copy here.

**Beads are ONLY for Claude Code's own work. They CANNOT be assigned to a human.** A bead is Claude's task memory across sessions. Never create a bead that represents work for the user to do — not "review this", not "decide X", not "run Y". If work is blocked on a human decision, ask the user directly in the conversation — right when the question arises, not at session end. The only valid assignee is Claude itself, via `--claim`.

This is **mechanically enforced** by the `bd-guard` PreToolUse hook (`scripts/bd-guard.sh`): a human assignee on `bd create/update/assign` is hard-blocked (no override), and user-directed bead text ("ask the user…", "waiting for Joe…") is blocked with a redirect to chat. `BD_GUARD_ALLOW=1` overrides the text check for genuine false positives (the phrase is quoted content or code, not pending user work) — never to park user work in a bead.

- The embedded Dolt database at `/workspace/.beads/embeddeddolt/` (gitignored) is the live source of truth; `.beads/issues.jsonl` is a passive, git-tracked export used to rebuild the database (e.g. after teardown/resume or corruption). Always edit issues via `bd` commands, never by editing the JSONL.
- To repair a broken database: `cd /workspace && bd doctor --fix --yes` (self-healing also runs at entrypoint, welcome screen, and menu option 3). No server to start — bd works directly against the on-disk database.
- Use `bd update <id> --flag` to modify issues — never `bd edit` (it opens `$EDITOR` and blocks). Include issue IDs in commit messages when relevant (`Fix auth bug (bd-a3f2)`).
- **Memory precedence:** project knowledge (decisions, gotchas, environment facts) goes in `bd remember` — it syncs with the repo and is shared across machines. The Claude Code harness's own auto-memory (`MEMORY.md` under `~/.claude/projects/`) is for user-specific context only (who the user is, how they like to work) — never project knowledge. The injected "do NOT use MEMORY.md" rule means: don't create ad-hoc MEMORY.md files for project facts; it does not disable the harness's user-memory feature.

## Working Inside a Larger Repo (Teardown / Resume)

When the template is dropped into a subdirectory of a larger git repo, `bd init` creates a nested `.git/` so beads can sync. That nested repo makes the parent treat the subdir as an embedded sub-repo (blocks `git add` from the parent). Use `./claude-dev --teardown` from the host before pushing back: it backs up `.beads/issues.jsonl` to `~/.claude-dev-state/<project>/<timestamp>/` and removes the template artifacts (`.git/`, `.gitignore`, `.beads/`, `.claude-dev/`, `claude-dev`, `docker-compose.yml`, `attachments/`, `.claude/logs/`). Re-bootstrapping in the same directory detects the snapshot and offers to restore beads — the embedded Dolt DB rebuilds from JSONL on first container start.

## Knowledge Base

Curated playbooks for issues that were expensive to solve once live in `/opt/claude-dev/knowledge-base/` (repo source: `knowledge-base/`). Read `README.md` there first: it is the keyword index and the authoritative list of playbooks. Check it before debugging infrastructure, re-deriving a procedure, or escalating to the oracle — the answer may already be paid for. When you solve something that cost real effort, contribute it back following the convention in that README (see the capture rule in Model Tiering).

## Experience Testing

Run `run-tests.sh` inside the container to verify the environment works correctly. Tests cover:

- **Smoke tests**: Scripts present, binaries installed, configs valid.
- **Experience tests**: Welcome screen renders, menus navigate correctly, invalid input handled.

Run tests after making changes to container setup, entrypoint, or menu scripts.

```bash
run-tests.sh          # Run all tests
run-tests.sh smoke    # Smoke tests only
run-tests.sh experience  # Experience tests only
```

**Until the next image rebuild, do NOT invoke `run-tests.sh` at all** — the installed copy predates the `CLAUDE_DEV_TESTS` override (it silently ignores the variable) and its baked suite contains a test that re-invokes the full suite recursively, filling the disk with `/tmp/bats-run-*` dirs (root cause of the 2026-07-06 disk-full incident; fixed in repo `tests/smoke.bats`, baked copies still armed). Pre-rebuild, run the repo suite directly: `bats /workspace/tests/smoke.bats`. After a rebuild, `CLAUDE_DEV_TESTS=/workspace/tests run-tests.sh` works as documented below.

**`run-tests.sh` tests the baked image, not your working tree.** By default it runs `/opt/claude-dev/tests/` — the copy baked at the last image build — so a green run proves nothing about repo edits. To verify changes to `tests/`, `config/`, or `scripts/` before a rebuild, run `CLAUDE_DEV_TESTS=/workspace/tests run-tests.sh smoke`. Even then, assertions against staged artifacts (`/etc/claude-dev/configs/`, `/opt/claude-dev/`, `/usr/local/bin/`) stay red until the next host `./claude-dev --rebuild` — image staleness, not regression (see `knowledge-base/CONFIG_SYNC.md`).

## Session Checklist

### Start
1. Read recent logs: `dev-log show`
2. Check git status: `gs` (alias for `git status`)
3. Understand the current task before writing code.

### End
Follow the **[Session Completion](#session-completion)** workflow below — it is the single session-end protocol (file beads for follow-ups, run quality gates, update issue status, push to remote). In addition:
1. Ensure all changes are logged via `dev-log`.
2. Session logs are auto-exported on Claude exit (via hook).

## Quick Reference

| Shortcut | Command |
|----------|---------|
| `cs` | `claude --dangerously-skip-permissions` |
| `csd` | `claude --dangerously-skip-permissions --debug` |
| `menu` | Setup/options menu |
| `dlog` | `dev-log` |
| `gs` | `git status` |
| `cn` | `claude` (normal mode) |
| `hx` / `vim` | Helix editor |
| `view-logs` | Interactive Claude log viewer |
| `clog-latest` | View latest Claude debug log |
| `clog-export` | Export latest log to workspace |
| `screenshot` / `ss` | `take-screenshot` |
| `cse` | `csearch` (lean combined code search) |


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
- **Beads are ONLY for Claude Code's own work — NEVER assign a bead to a human.** No "review this", "decide X", or "run Y" beads. Ask the user directly instead.
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
