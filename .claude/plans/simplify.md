# Simplify — what the template should stop doing

Status: PROPOSED (2026-10-18, bead claude-orca-zz1). Nothing here is implemented.
The September slim-down (`slim-down.md`) kept every behavior and shaved time;
the Orca removal (claude-orca-9bh) was the first cut of a whole layer. This
plan asks the next question: which of the remaining layers earn their keep.

How this was found: ten parallel read-only passes (hook chain and timing,
script reference graph, config plumbing, container and launcher, prose and
tests, two external research passes, three follow-ups), plus git churn
measured in the main session. Every number below is from this box today.

## The shape of it

| What | Size |
|---|---|
| Scripts, python, config | 27,905 lines in 94 files (launcher.sh 2,814; cost_mirror.py 2,634; tier-set.sh 1,356; bd-guard.sh 982) |
| Tests | 36,575 lines, 108 bats files, 1,536 cases (ratio 1.19 : 1) |
| Prose loaded every session | rulebook 1,803 words + project CLAUDE.md 1,675 words, naming ~35 mechanisms |
| Knowledge base, plans | 2,935 lines (TIERED_ORCHESTRATION.md alone 1,360); `.claude/plans/` 193 KB tracked |
| Hooks | 34 entries, 24 binaries; 11 fire on every Bash call, 6 on every prompt, 10 at SessionStart |
| History | 998 commits in six weeks; 564 touch `tests/`; 64 of the 120 fix-flavoured commits are test fixes; launcher.sh has been rewritten 3x over (10,359 lines churned for 2,814 kept) |

Subsystems by lines: container + launcher 7,403 · observability 5,327 ·
guards + hooks 3,816 · delegation/workers 2,836 · context/memory 2,531 ·
tier 2,433 · misc 2,569 · mac 990.

## What the field says

- **Anthropic's container guidance is small.** A dev container is an image,
  the project bind-mounted, Claude Code installed, run as non-root with
  `--dangerously-skip-permissions` inside the boundary; even its firewall
  script is marked optional. Credentials in `~/.claude` are the thing to
  protect, not the host. (code.claude.com/docs/en/devcontainer,
  /sandbox-environments)
- **CLAUDE.md: prune ruthlessly.** "Bloated CLAUDE.md files cause Claude to
  ignore your actual instructions"; "the over-specified CLAUDE.md" is a
  named failure; if Claude already does it, delete the line or make it a
  hook. Hooks are for "actions that must happen every time with zero
  exceptions". (code.claude.com/docs/en/best-practices). HumanLayer's
  yardstick: under 300 lines, ideally far less; frontier models follow
  roughly 150–200 instructions and Claude Code's own prompt already spends
  ~50 of them. (humanlayer.dev/blog/writing-a-good-claude-md)
- **Multi-agent is expensive and a weak fit for coding.** Anthropic's own
  post: ~15x the tokens of chat, "most coding tasks involve fewer truly
  parallelizable tasks than research"; the one first-party tiering result
  is Opus lead + Sonnet workers. No credible source shows cheap third-party
  coding workers paying for themselves; one measurement attributes most
  subagent savings to context isolation, not per-token price.
  (anthropic.com/engineering/multi-agent-research-system,
  code.claude.com/docs/en/sub-agents)
- **The people who built it run it plain.** Boris Cherny: "surprisingly
  vanilla" — one shared CLAUDE.md, two subagents, a formatting hook, a
  permission hook.
- **Native features that now cover custom code here:** statusline JSON
  carries `cost.total_cost_usd` and `context_window.used_percentage`;
  `autoCompactWindow` is settable per subagent in frontmatter; `PreCompact`
  is a hook event; `isolation: worktree` cleans up clean worktrees itself;
  `model:` in agent frontmatter binds a model per role; plugins are the
  official bundle for hooks + agents + skills + commands. There are 33 hook
  events and none fires at a context threshold.

## What happened while this review ran

The template got in its own way five times in one session, and each is a
finding:

1. **`context-meter` stopped three of ten recon agents** (a Haiku scout,
   the research agent, the Claude Code docs agent) at 30–41% of their
   windows, each with far more room left. The reports came back partial.
2. **`delegation-gate` nagged twice** on a review where reading inline was
   the right call.
3. **`outbound-guard` denied a read-only `grep`** because the pattern
   contained Snowflake terms. It matches text, not actions.
4. **`route-prompt` is inert here:** its router on `127.0.0.1:4141` refuses
   connections (no OpenRouter key in this folder), so the `[route]` line
   the rulebook spends a paragraph on never prints.
5. **The live rulebook is stale** against `config/claude-user-memory.md`
   (five hunks): hooks run from the `.claude-dev/template` clone, which sits
   a few commits behind the repo it lives in.

## Decide this first: the headless OpenRouter worker path

**Facts.** `run/tier.json` today binds worker = `subagent:sonnet`, recon =
`subagent:haiku`, checker = `subagent:opus` — all native Claude Code
subagents. The OpenRouter guard is not running in this folder. The stack
that serves the headless path — `dispatch`, `dispatch-epic`, `delegate`,
`worker-run`, `workers`, `recon`, `lib/workers.sh`, `lib/opencode-launch.sh`
(2,836 lines), `openrouter-guard.py` (633), `openrouter-auth` + `openai-auth`
(252), the opencode image phase (352 MB), `opencode.json` + the
`context-meter.js` plugin, `provider-policy.json`, `delegate-routes.json`,
provision step 70 — is roughly 4,500 lines, one image layer and one proxy
process, with the port literal `4141` copied at ten sites. Today's
cost-mirror line ("saved ~$32") was earned entirely by native subagents on
`haiku`/`sonnet`.

**Options.**
- **(a) Drop it.** Workers become `Agent` spawns with `model:` in frontmatter
  and `isolation: worktree`; `recon` becomes a `scout` spawn. Zero custom
  code for the worker lifecycle. You lose non-Anthropic models and the
  OpenAI-subscription route.
- **(b) Keep the guard and one `dispatch` path**, drop tiers, routes and
  presets. For when a specific non-Claude model (GLM, Luna) is worth the
  machinery.

**Recommendation: (a)** unless there is a model you need that is not Claude.
The research found no evidence the cheap-worker tier saves money on coding,
and the folder is already running without it. Everything in § Consolidate
shrinks accordingly.

## Remove — high confidence

| ID | What | Lines | Hooks | Why | Replacement |
|---|---|---|---|---|---|
| A | `context-meter.sh` + `opencode/plugin/context-meter.js`, the 30/40 % budget/ceiling | ~330 | 4 (Pre+Post on every tool) | Cut off three recon agents today; subagent windows are 200k–1M | `autoCompactWindow` in the agent frontmatter |
| B | `offramp.sh` (handoff at 40 %, stop) | 466 → ~30 | 6 → 1 | Native has no threshold event, but it has `PreCompact` and auto-compaction is already on (window 1M, 50 %) | A `PreCompact` hook that writes the HANDOFF to the bead |
| C | `route-prompt.py`, `route-eval.py`, `config/route/`, the `[route]` rulebook paragraph | 803 | 1 per prompt | A classifier whose verdict the model is then told to second-guess; inert without the guard | The lane declaration the model already makes |
| D | `delegation_gate.py` | 588 | 1 on 9 tools | Delegation is a judgment, not a must-happen; Anthropic's rule for hooks is the latter | The lane rules in the rulebook |
| E | Acceptance-contract machinery: `contract_gate.py`, `lib/frozen-hook.sh`, `workflow-lint.sh`, `workflows/verify-contracts.js`, `agents/verifier.md`, `ACCEPTANCE_CONTRACTS.md` | ~1,300 | 2 | The rulebook already made contracts opt-in; 5 of 16 frozen contracts needed `bd supersede`; commit messages became paragraphs | A short `skills/acceptance-contract/SKILL.md` describing CHECK / PASS-IF / RED-AT / GREEN-AT for when you ask |
| F | `auth-guard.sh` | 132 | 0 | Listed in CLAUDE.md's hook suite, wired nowhere | Delete, or wire it if it still matters |
| — | Untracked `bd init` output under `tests/` (`.beads/` 1.3 MB, `.claude/`, `.agents/`, `.codex/`, `AGENTS.md`, `CLAUDE.md`, `.gitignore`) | — | — | A test ran `bd init` in the wrong directory | Delete; have `seed-project` refuse to init inside `tests/` |

## Consolidate

| ID | What | Now | Proposed |
|---|---|---|---|
| G | Tier system: `tier-set`, `tier-gate`, `tier-reconcile`, `tier-derive`, `tier-prime`, `lib/tier-roles.sh`, `tier-presets.json`, `TIERED_ORCHESTRATION.md` | 2,433 lines + 1,360 doc lines, 5 hook entries (3 unguarded — they exit 127 if the binary is missing) | `model:` on `executor.md`, `scout.md` and (if kept) `verifier.md`; `/tier <preset>` becomes a ~40-line script that rewrites those three lines. The gate/reconcile/derive/prime hooks go. With option (a) above, that is the whole system. |
| H | `cost_mirror.py` | 2,634 lines, a hook on every prompt | Native statusline already receives `cost.total_cost_usd` and `context_window.used_percentage`. Keep only what native lacks — the subagent spend roll-up and the "saved vs. top model" line — as a ≤200-line `session-cost` run from the statusline, not a prompt hook. OTel (`CLAUDE_CODE_ENABLE_TELEMETRY=1`) exports per-model cost if you ever want history. |
| I | Rulebook + project CLAUDE.md + AGENTS.md mirror | 1,803 + 1,675 + 2,500 words; ~35 mechanism names; a test enforces byte-identical sections | After A–H roughly half the mechanisms no longer exist. Target: rulebook ≤ 600 words, project CLAUDE.md ≤ 800 (Build & Test, Definition of done, a pointer). Move Architecture Overview to `knowledge-base/ARCHITECTURE.md`, loaded on demand. Claude Code reads `AGENTS.md` natively now, so keep one file (AGENTS.md if Codex matters) and drop `docs.bats`'s mirror check. |

## Shrink — measure first

| ID | What | Evidence | Do |
|---|---|---|---|
| J | `bd-guard.sh` | 982 lines (81 % comments), 233 test cases "each a way past the guard", churned 3x over; **no log of denials exists** | Log every denial for two weeks, then keep the rules that fired and delete the rest with their cases. The guard protects a todo list from Claude, not from an attacker. |
| K | `outbound-guard --prompt` | Denied a `grep` for its words today | Keep the Bash-side push/deploy/PR denials (they are "must happen every time"); drop the prompt-text matcher. |
| L | `code-map` (`code-map.sh`, `-guard`, `-prime`) | 689 lines, 53 cases, a graph built in the background at every SessionStart; nothing in this review queried it | Check `code-map` query logs for a month. Native Grep/Glob and the Explore agent cover code navigation. |
| M | Launcher runtime fallback (plain `ubuntu:24.04` + toolchain installed into the folder when the image build fails) | Branches at ~10 sites in launcher.sh, `setup.sh` runs on every boot (entrypoint 247–289), `10-toolchain-verify`, a toolchain cache mount; the memory notes it cost ~15 min per folder once | Fail loud instead: "image build failed, here is the log". Keep `CLAUDE_ORCA_RUNTIME=local` — `e2e-local.bats` needs it. Needs `mac-e2e.sh` once. |
| N | `prime-memories` | 45 `bd remember` entries, 37 of them over budget and unseen every session | The store outgrew the hook. Promote the durable facts to knowledge-base files; keep `bd remember` for lessons. |
| O | `activity` panel (`activity.py`, `-digest.py`, `-summarize.py`) | 1,970 lines, no hooks, needs the guard for its model | Keep if you open it; otherwise it is 2k lines serving a path that is off today. |

## Tests

The suite shrinks mechanically with A–H: roughly 5,000–6,000 lines and
~400 cases (route-prompt 44, delegation-gate 54, contract-gate 39,
tier-hooks 43, tier-presets, offramp, context-meter, cost-mirror, lane in
part). Beyond that, policy, not deletion:

- `run-tests.sh`'s `!flaky` filter excludes nothing: zero tests carry the
  tag. Remove the filter or tag the tests it was written for.
- `tests/INDEX.md` still classes 17 files as "mixed" (behavior + wording).
  Finish what the September pass started: a case that pins wording goes.
- The stubbed launcher suites (`launcher-v3`, `launcher-pane`, `bootstrap`,
  ~2,000 lines) are, by this repo's own CLAUDE.md, "not evidence" for the
  host path. Keep them, stop growing them; `e2e-local.bats` (3 cases, real
  sshd) and `mac-e2e.sh` are the evidence.
- You are new to automated tests and the suite is yours to run. 1,536 cases
  is a lot to own. After the cuts it should be under 1,000; the fast set
  should finish in a minute.

## Keep, and why

- **The container and its door.** Image, entrypoint, provision.d, sshd +
  ControlMaster, the Ghostty router, the clipboard bridge. This is the
  product and it matches the field's shape (one container per project,
  bind-mounted workspace, non-root). Nobody else uses sshd as the door —
  Anthropic attaches an editor, Docker's `sbx` offers SSH only as an editor
  integration — but it is your terminal-pane UX and nothing found argues
  against it.
- **`openrouter-guard.py`** if option (b): it is the only process holding
  the key and it enforces the residency policy. Collapse the ten `4141`
  literals into one env var.
- **`branch-guard`, `outbound-guard` (Bash side), `output-cap`.** These are
  exactly what Anthropic says hooks are for. A `permissions.deny` rule
  cannot express `BRANCH_OK=1`.
- **`worktree-gc`.** Native cleanup removes clean worktrees but has no
  merged-into-main check and no STRANDED report.
- **`bd` and the core of `bd-guard`.** The tracker is the memory.
- **`config-sync`.** 297 lines that work; a plugin cannot ship
  `settings.json` or CLAUDE.md, so the copy step stays. Not worth replacing.
- **`.claude/plans/` history.** Cited from ~25 code comments and tests;
  already out of the image.

## What it adds up to

Remove + Consolidate (A–I), without the OpenRouter decision: about **8,000 of
27,900 script lines**, **13 of 34 hook entries** (per Bash call 11 → 5, per
prompt 6 → 2, SessionStart 10 → 6), roughly half the rulebook's mechanisms,
and 5–6k lines of tests. Option (a) on OpenRouter adds ~4,500 script lines,
~3,000 test lines, one image layer and one proxy process.

What is left is the thing the README promises: a folder, a container, a
terminal pane, a tracker, and three guards.

## Order of work

1. **Decide OpenRouter.** Everything in G, O and the image follows from it.
2. **A–F, one commit each.** Each is: delete the script, its `bin/` link,
   its settings entry, its tests, and its lines in the rulebook. Measure
   hook time per Bash call before and after (median of 30, as slim-down did).
3. **G and H.** Frontmatter `model:` first (it is three lines), then the
   `/tier` rewrite, then delete the hooks.
4. **I — the prose.** One pass over rulebook, CLAUDE.md, README,
   knowledge-base; delete `TIERED_ORCHESTRATION.md` or cut it to the
   delegation rules that survive.
5. **J–O — the measurements.** Instrument, wait, then cut.
6. **M last**, with `mac-e2e.sh` on the Mac, since it touches the launcher
   and entrypoint.
