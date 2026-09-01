# Plan: one rulebook, no contradictions — fixing the five template misbehaviours

Filed 2026-09-01. Lane: deep. Beads: B1 jhkj · B2 y2qe · B3 bw66 · B4 4pvn · B5 jqmd (prefix beads_claude_docker-). Status: plan only — nothing implemented yet.

## Root cause (one finding explains most of it)

**The rules that would prevent these behaviours live in a file that never ships.** A user project gets:
`~/.claude/CLAUDE.md` (= `config/claude-user-memory.md`, 2,040 words) · `bd prime` output (twice: from the image settings *and* from the `.claude/settings.json` that `bd init` writes into every fresh project) · the `lane`/`tier-prime` hook text · a marker-gated context (`config/contexts/snowflake.md`) · skills. Nothing copies this repo's `CLAUDE.md` (3,264 words) anywhere (`scripts/entrypoint.sh:143` is the only provisioning line, and it copies the user-memory file). So Verification ("run code, don't guess"), Ownership, Answer Style, Session Completion (push opt-in), lane-scoped bead filing, and "verifiers per evidence surface" are all absent in the projects where the problems show up — while the *bad* text is present everywhere.

## Per-issue diagnosis

| # | Behaviour | What the shipped text actually says | Where |
|---|---|---|---|
| 1 | Tries to push/deploy to Snowflake | The only "never" rule is marker-gated (`snowflake.yml`, or `snowflake`/`snowpark` in a dependency file) — SQL, dbt, and notebook projects don't match. The always-visible surfaces are the `snowpark-deploy` skill blurb and `knowledge-base/SNOWFLAKE_DEPLOY.md`, an imperative how-to ("You must restore them with ALTER NOTEBOOK…"). The permission deny is prefix-only (`Bash(snow *)`); `pip install snowflake-cli && snow …` slips through. When the context *is* injected it also says "ask the user in chat to run it and paste the output … keep the task blocked on their reply" — the opposite of the no-human-blocking rule. | `scripts/context-detect.sh:36-48`, `config/contexts/snowflake.md:13-16`, `config/skills/snowpark-deploy/SKILL.md` handoff step 3, `config/claude-settings.json` deny list |
| 2 | Pushes to GitHub with no connection | `bd prime` injects at SessionStart *and* PreCompact: "🚨 SESSION CLOSE PROTOCOL 🚨 … 4. git push … **NEVER skip this.** Work is not done until pushed", "run `git push` at session end", and a "Completing work" example ending in `git push`. The counter-rule exists only at `CLAUDE.md:200-205` of this repo. In a user project nothing contradicts it. | `bd prime --export` lines 80-99, 171 |
| 3 | Riddles; "Two issues need clarification" with no question | Global "Opus Answer Protocol" (≈330 words: "physically painful", "bias toward silence", "under-answer", "no offers of next steps") fights the harness ("close with a recap … what's next"; "state your assumption or ask your question") and the deep-lane tripwire ("hidden ambiguity … announce it"). Result: the model announces that something is unresolved, then the brevity rule strips the actual question and the connective words — a riddle. No rule anywhere defines what a finished message may end with. | `config/claude-user-memory.md:49-60` |
| 5 | Bead explosion, checks too early, verification as separate beads | `bd prime`: "Create beads issue BEFORE writing code", the "Write tests for X" separate-bead example, "use parallel subagents" to create issues. `tier-prime` (every SessionStart/PreCompact): "register a CHECK/PASS-IF contract on the bead before dispatch; the executor commits the failing test red first" — no lane qualifier. Global deep row: "1 verifier per bead" vs this repo's "per evidence surface, never per bead". Lane rubric: "≥3 files → deep" (greenfield work is always ≥3 files), and `delegation-gate guard` denies Edit/Write in deep → every edit needs an executor → every executor needs a bead with a contract. `contract-gate` nags on every close without a contract regardless of lane. No greenfield clause anywhere. | `bd prime --export:96,119,178`; `scripts/tier-prime.sh:73`; `config/claude-user-memory.md:17`; `scripts/lane.sh` rubric; `scripts/delegation-gate.py:487`; `scripts/contract-gate.py:472` |
| 6 | "Can't run its own code" | The sandbox is fully capable (firewall off by default; pip/npm/apt work; Playwright + Chromium + `take-screenshot` baked), but the only shipped sentences about running things in a Snowflake project are the negative ones ("no access … never will … the user runs it … blocked on their reply"). "Run the actual application / install whatever is missing" is in this repo's `CLAUDE.md:124-128` only. Nowhere does the shipped text distinguish *the sandbox* (run everything) from *the user's systems* (never touch). | same as #1 |

## Design principles for the fix

1. **One rulebook that ships**: `config/claude-user-memory.md` becomes the complete, short rulebook for every project (target ≤ 1,000 words, from 2,040). This repo's `CLAUDE.md` keeps only repo-specific facts (tools, config sync, tests, cleanup).
2. **Every rule stated once.** Delete both "overrides, by name" paragraphs; nothing in one file argues with another file.
3. **Fix contradictions at the source, not with counter-prose.** `bd prime --memories-only` drops the session-close protocol and the bead-before-code lines (verified: 0 hits for push/BEFORE-writing/Write-tests/parallel-subagents; memories intact).
4. **Mechanical where the prior is strong.** A tiny PreToolUse guard blocks `snow`/`snowsql` always and `git push`/`gh pr create`/`bd dolt push` unless the current prompt asked — the same pattern as `bd-guard`. One sentence of prose instead of a paragraph.
5. **Route by consequence, not file count**, with an explicit greenfield clause, and make the ceremony hooks lane-aware.

## Slices (beads)

Sequence: B1 → B3 → B4 → B2 → B5. Verifier runs: {B1, B2} share the hook-wiring surface; {B3, B5} share the prose surface; B4 alone.

### B1 (beads_claude_docker-jhkj) — prime: memories only; stop `bd init` writing Claude hooks; delete the override paragraphs
- `config/claude-settings.json`: both `bd prime` hook commands → `bd prime --memories-only`.
- `scripts/entrypoint.sh:402`: `bd init … --skip-agents`; idempotently rewrite any `"bd prime"` command in `/workspace/.claude/settings.json` to `bd prime --memories-only` (covers existing projects; also normalises this repo's currently-modified `.claude/settings.json`).
- `config/claude-user-memory.md`: add the 5-line bd essentials block (commands; `bd update` flags never `bd edit`).
- `CLAUDE.md`: delete the override sentence at :165 and the paragraph at :204-205; Session Completion shrinks to "commit locally; push is opt-in".
- New `tests/prime-hook.bats`.

### B2 (beads_claude_docker-y2qe) — `outbound-guard` hook
- New `scripts/outbound-guard.sh` (PreToolUse, matcher Bash; fail-open like every other hook): deny any command containing a `snow`/`snowsql` invocation; deny `git push`, `gh pr create`, `gh repo create`, `bd dolt push` unless a per-session marker exists. UserPromptSubmit mode (`outbound-guard --prompt`) sets the marker when the prompt contains push/publish/PR wording, clears it otherwise (state dir pattern from `lane.sh`). Deny reason: "push/deploy is opt-in — the prompt has to ask for it; commit locally instead."
- Wire in `config/claude-settings.json`; `Dockerfile` COPY; `scripts/build-plugin.sh` regen; drop the now-redundant `Bash(snow *)` deny entries or keep as belt-and-braces (keep).
- New `tests/outbound-guard.bats`; one index row in `knowledge-base/README.md`.

### B3 (beads_claude_docker-bw66) — one global rulebook; strip `CLAUDE.md` to repo-specifics
- Replace `config/claude-user-memory.md` with the draft in Appendix A (Sandbox vs. your systems · Push and deploy · Ownership · Finishing a message · Beads · Lanes · Delegation).
- `CLAUDE.md`: remove Answer Style, Ownership, User Constraints, Verification (generic parts), Noticed Flaws, Session Completion narrative, Model-tiering prose that now lives globally; keep Environment, csearch, Code Map, Config Customization, Delegation Routes, acceptance-contract mechanics pointer, Logging, Cleanup, Tests, Quick Reference, beads storage mechanics. Target ≤ 1,700 words.
- `AGENTS.md`: pointer only.
- New `tests/rulebook.bats`: word budgets; banned phrases absent from both files (`overrides, by name`, `physically painful`, `Work is not done until pushed`, `1 \`verifier\` per bead`, `≥3 files`, `environment limitation`); required headings present exactly once across both files.

### B4 (beads_claude_docker-4pvn) — lane rubric by consequence + greenfield clause; `contract-gate` and `tier-prime` lane-aware
- `scripts/lane.sh` prime text → Appendix B (no file-count trigger; greenfield clause; "verification is never its own bead"; "one verifier run per evidence surface").
- `scripts/tier-prime.sh:73`: dispatch line gains "(deep lane only)".
- `scripts/contract-gate.py`: read the session's lane state (`~/.claude/cache/lane/<session_id>.json`); silent on express/standard; unchanged on deep/unset.
- Tests: `tests/lane.bats`, `tests/contract-gate.bats`, `tests/tier-hooks.bats` (append-only); `knowledge-base/TIERED_ORCHESTRATION.md` + `ACCEPTANCE_CONTRACTS.md` one line each; plugin regen.

### B5 (beads_claude_docker-jqmd) — Snowflake surfaces
- `config/contexts/snowflake.md` → ≤ 90 words: Snowflake-specific residue only (validate SQL locally by parsing; fixtures; the skill prepares deploy packages on request). No "paste the output", no "blocked on their reply".
- `config/skills/snowpark-deploy/SKILL.md` handoff step 3: hand off in chat with commands + expected output; local checks are the verification; the task is done. Remove the blocked-on-reply sentence.
- `knowledge-base/SNOWFLAKE_DEPLOY.md`: one banner line — playbook for the user's machine; Claude prepares files and commands and never runs `snow`.
- `tests/context-detect.bats` append: banned phrases absent; word budget; banner present.

## Explicitly out of scope (noticed, not investigated)
- `csearch`/`dev-log`/attachments are documented only in this repo's `CLAUDE.md`, so user projects never learn about them (the code-map skill does ship via the plugin). One follow-up bead at most.
- `delegation-gate`'s 4-call nudge and its edit-deny in the *unset* lane are untouched; B4's routing change removes most of their pressure.

## Appendix A — draft `config/claude-user-memory.md` (≈ 850 words)

# Rules for every project in this container

## Sandbox vs. your systems
This container is a sandbox that runs anything: install packages, run the app, open it in the browser, `take-screenshot url|term|display` (images land in `/workspace/attachments/`; look at them with Read). Verification *is* running it — never inspection, never "would need". If a tool is missing, install it and go on.
The user's external systems — Snowflake, cloud accounts, production databases, SaaS — are the opposite: you have no credentials and never will. Never connect, deploy, or ask for logins; never install a CLI to try. Stub them with fixtures and run everything else locally. "No access to X" means "mock X and run", never "can't run".

## Push and deploy are the user's actions
Commit locally at the end of every session. `git push`, `gh pr create`, `bd dolt push`, and every deploy run only when the current prompt asks for them; a hook blocks them otherwise. A blocked push is normal: say so in one line and stop.

## Ownership
You own the work end to end. Never hand the user a task, a check, or a to-do; ask in chat only after exhausting your own options, and only for a decision that is genuinely theirs. Explicit user choices — tool, library, approach, naming — are fixed: disagree once out loud, then comply; never substitute silently, never remove a constraint to make a fix work.

## Finishing a message
Outcome first, in plain complete sentences. Short means fewer topics, not clipped wording. End in exactly one of three shapes:
- **Done** — what changed, and how you saw it work.
- **One question** — only when the choice is genuinely the user's; ask it as a question, with the options.
- **Blocked** — what is missing and what you tried.
Anything else you noticed is either fixed before you finish or dropped. No trailing caveats, no "issues to flag" without a question, no offers of next steps.

## Beads
`bd` is the only task tracker: `bd ready` · `bd show <id>` · `bd create --title … --description …` · `bd update <id> --claim` · `bd close <id>`; `bd update` flags, never `bd edit`. Beads are Claude's memory, never a human's: no human assignee, no bead text that hands work to the user, no blocking on a person — a needed decision goes to chat.
Filing is lane-scoped: express files none; standard files one only when follow-up remains; deep files one per slice. A bead's check belongs to the bead that did the work — verification is never its own bead. `bd remember` holds project knowledge; `bd prime` re-injects it after compaction.

## Lanes
Declare first — `lane express|standard|deep [--why "…"]`; `lane --prime` is the authoritative rubric.
- **express** — reversible, ≤~5 tool calls, no design choice → inline, nothing else.
- **standard** — the default for building things, greenfield included: one approach sentence, do it (inline or one executor), run it once to verify.
- **deep** — only when hard to reverse, a security or data-integrity surface, a shared contract other code depends on, real ambiguity, or the user says plan/thorough/audit → plan, a bead per slice with an acceptance contract, one verifier run per evidence surface.
Ties go lighter. While a project has no test suite or nothing runs yet, checks are "run it and look" — no contracts. Scope is the request as asked; an adjacent issue gets one line.

## Delegation — roles, not models
You are the orchestrator: plan, decompose, delegate, review, decide. `executor` implements one slice; `scout` (`subagent_type: "scout"`) does cheap recon; `verifier` checks one evidence surface. `/tier` binds the models — never by hand, never via `CLAUDE_CODE_SUBAGENT_MODEL` or `ANTHROPIC_DEFAULT_*`.
Delegating per this file is the user's standing request — no per-prompt invitation needed — but express spawns nothing. A slice spec is objective · files in scope · output contract · boundaries (what is out of scope); the worker reports deviations, not opportunities.
Deep-lane contract: before dispatch, register `CHECK`/`PASS-IF`/`FROZEN`/`CLASS` on the bead; the executor commits the test red (`RED-AT`) then green (`GREEN-AT`); the verifier's five checks return `PASS`/`FAIL`/`TAMPERED`/`NO-CONTRACT`, and anything short of `PASS` goes back to an executor. Beads and contracts are yours to author, never a worker's. Anything a person looks at closes on a viewed screenshot, never on a description.
Name spawns `<role>-<model-slug>` from `tier-derive`; named spawns deliver by SendMessage to "main". Invariants: expensive tiers never take the worker seat; checkers inherit the session model; slices run sequentially, fan-out is for recon; a worker's summary is a claim to check.

## Appendix B — draft `lane --prime` text

[lane] Route first: declare `lane express|standard|deep [--why "…"]` before any other action.
  express  — reversible, ≤1 file, ≤~5 tool calls, no design choice → inline now: no plan, bead, executor, or verifier; verify with one run/screenshot when observable, else the diff.
  standard — the default for building things, greenfield included: one-sentence approach, then inline or ONE executor slice; verify by running it once; no contract, no verifier unless the claim is contested.
  deep     — ANY of: hard to reverse (migration, deletion, push, publish); security or data-integrity surface; a shared contract other code depends on (schema, API, hook wiring); real ambiguity or tradeoffs the user must weigh; the user said plan/thorough/audit. → plan first, a bead per slice with an acceptance contract, one verifier run per evidence surface.
  File count is not a trigger: many files with no design choice is standard. While the project has no test suite or nothing runs yet, checks are "run it and look" — no contracts. Verification is never its own bead.
  Ties go LIGHTER; tripwires (scope outgrows the rubric, a fix fails, hidden ambiguity, unexpected breakage) escalate exactly one lane, announced, never de-escalated in the same prompt.
  Scope: the request AS ASKED — adjacent issues get one line, never investigation, and are not tripwires. "quick"/"just" biases light; explicit user constraints beat every rubric line.
