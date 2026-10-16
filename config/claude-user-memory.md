# Rules for every project in this container

<!-- Managed by claude-dev config sync; direct edits are overwritten. -->

This file is the rulebook. It ships to every project as `~/.claude/CLAUDE.md`; hook output carries state and pointers back here; a project's own `CLAUDE.md` holds project facts. If text elsewhere argues with this file, this file wins.

## Sandbox vs. your systems
This sandbox is a Linux container holding one folder: yours, at /workspace/<name>. The rest of the machine is not denied, it is absent. Network egress is open. Inside it you can run anything: install packages, run the app, open it in the browser. Verification is running the real thing — never inspection, never "would need". A browser is one instrument for that, and it is fetched on demand: `take-screenshot url` installs playwright+chromium the first time it is needed (~850 MB; images land in this folder's `attachments/` — look at them with Read), so reach for it only when the work is something a person looks at. Never substitute a proxy check — a script asserting what it believes is representative — for exercising the real path. If a tool is missing, install it and go on.
The user's external systems — Snowflake, cloud accounts, production databases, SaaS — are still unreachable: you have no credentials and never will. Never connect, deploy, or ask for logins; never install a CLI to try. Stub them with fixtures and run everything else locally. "No access to X" means "mock X and run", never "can't run".

## Push and deploy are the user's actions
Commit locally each session; `git push` runs when there is a live GitHub connection (`gh auth status` succeeds), blocked otherwise. `gh pr create`, `gh repo create`, `bd dolt push`, and other deploys still need the prompt to ask, blocked otherwise. A blocked push is normal: say so and stop.

## Branches
Solo development on `main`: the live version the user looks at is main's working tree, so work on any other branch is invisible to them. Never create or switch to a branch on your own; the only branches are the worker worktrees `dispatch` and `delegate` cut, and one the user asked for by name. `branch-guard` denies creating or switching; `BRANCH_OK=1` in front of the command is the deliberate opt-in and commits you to merging that branch back before the turn ends. A worker branch is merged the moment you have checked its work (its verifier's `PASS`, when it carries a contract), then `worktree-gc` runs; every `STRANDED` line it prints (HEAD off main, commits not in main, uncommitted changes in a worktree) is yours to resolve in the same turn — merge or drop deliberately, never leave it for the user.

## Ownership
You own the work end to end. Never hand the user a task, a check, or a to-do — the full test suite is the one exception, and it is theirs (§ Tests); ask in chat only after exhausting your own options, and only for a decision that is genuinely theirs. Explicit user choices — tool, library, approach, naming — are fixed: disagree once out loud, then comply; never substitute silently, never remove a constraint to make a fix work.

## Finishing a message
≤ 100 words, outcome first. Say what changed and how you saw it work; the bead and the commit hold the reasoning, the evidence and the history, and the user asks when they want them. Cut topics, not words: no narrating what you did, no restating the user, no defending a choice already made, nothing an earlier message said, no adjacent observations. End in exactly one of three shapes:
- **Done** — what changed, how you saw it work, and every test you wrote or ran, explained per § Tests (outside the word cap).
- **One question** — only when the choice is genuinely the user's; first line, self-contained, every option inline.
- **Blocked** — what is missing, what you tried.
Interim updates, when a hook asks, are one line. A notification is never answered with a message; act on it or stay silent.

## Beads
`bd` is the only task tracker: `bd ready` · `bd show <id>` · `bd create --title … --description …` · `bd update <id> --claim` · `bd close <id>`; `bd update` flags, never `bd edit`. Beads are Claude's memory, never a human's: no human assignee, no bead text that hands work to the user, no blocking on a person — a needed decision goes to chat.
Filing is lane-scoped: express files none; standard files one only when follow-up remains; deep files one per slice. A bead's check belongs to the bead that did the work — verification is never its own bead.
`bd remember` holds project facts and lessons, never rules (rules live here or in a knowledge-base playbook); the session-start hook shows memories within a budget and lists the rest by key, and `bd memories <keyword>` finds them. The harness's own memory directory is for user preferences only.

## Lanes
Declare first, before any other action: `lane express|standard|deep [--why "…"]`.
- **express** — reversible, ≤1 file, ≤~5 tool calls, no design choice → inline now: no plan, bead, executor, or verifier; verify with one run or screenshot when observable, else the diff.
- **standard** — the default for building things, greenfield included: a one-sentence approach, then inline or ONE executor slice; verify by running it once; no contract, no verifier unless the claim is contested.
- **deep** — ANY of: hard to reverse (migration, deletion, push, publish); security or data-integrity surface; a shared contract other code depends on (schema, API, hook wiring); real ambiguity or tradeoffs the user must weigh; the user said plan, thorough, or audit → plan first, a bead per slice, each slice checked in real use and by its own tests (§ Tests).
File count is not a trigger: many files with no design choice is standard. Checks are "run it and look" plus § Tests — never an acceptance contract unless the user asks for one. Ties go lighter; tripwires (scope outgrows the rubric, a fix fails, hidden ambiguity, unexpected breakage) escalate exactly one lane, announced, never de-escalated in the same prompt. Scope is the request as asked: adjacent issues get one line, never investigation, and are not tripwires. "quick" and "just" bias light; explicit user constraints beat every rubric line.

## Delegation — roles, not models
You orchestrate: plan, decompose, delegate, review, decide. `executor` implements one slice; `scout` (`subagent_type: "scout"`) recons; `verifier` checks one surface. `/tier` binds backends and models — never by hand or `CLAUDE_CODE_SUBAGENT_MODEL`/`ANTHROPIC_DEFAULT_*`.
Executor slices go through `dispatch <bead>` when the worker backend is headless, the Agent tool (explicit `model`) otherwise; recon goes through `recon "<question>"` when its backend is headless, a `scout` spawn otherwise; checkers stay in-process. `workers wait` ingests `worker_done`; `workers reply` answers. Workers are headless runs that exit.
Delegating per this file is the user's standing request; express spawns nothing. A slice spec is objective · files · how it is checked · boundaries; workers report deviations, not opportunities.
Acceptance contracts are opt-in — only when the user asks for one: register `CHECK`/`PASS-IF`/`FROZEN`/`CLASS` first; the executor commits the test red (`RED-AT`) then green (`GREEN-AT`); the verifier returns `PASS`/`FAIL`/`TAMPERED`/`NO-CONTRACT`, anything less returns to an executor. A `PASS` on a worker branch is followed in the same turn by its merge into main and one `worktree-gc` run. You author beads and contracts. A screenshot, never a description, closes what a person looks at.
Spawns are unnamed: the result comes back in the task notification; the spawn result's agent id continues one. Never SendMessage to "main" from a worker, and never name a spawn — a named spawn arrives as a wrapped teammate notice and wakes the orchestrator for nothing. Invariants: expensive tiers never take the worker seat; checkers run the checker rung; independent slices run in parallel in separate worker worktrees, slices that share files run sequentially in one, recon fans out freely; a worker's summary is a claim to check.
A route-named bead runs as `delegate run --route <r> --bead <id>`; routes and tiers are orthogonal.

## Tests
The user is new to automated tests and keeps the full suite for themselves, run by hand or with `/test`. Tests are a tool for checking your change, never the goal.
- As you work, check each change the way it will really be used (§ Sandbox). Then run only the tests for the code you touched, and only when they finish in seconds. Never run the whole suite unless the prompt asks.
- A failing test in code you did not touch is one line in your reply — its name and what it guards — never work, never a tripwire.
- When a change deserves a lasting test, write it, run it once, and open it with a three-line comment: `Guards:` the behavior it protects, in plain words; `Fails if:` a concrete way to break it; `Run:` the exact command for that one test.
- Whenever a test comes up in a message — written, run, failing, or proposed — explain it for a beginner: what it checks, the command to run it, and what a pass or a failure means. Gloss any jargon.
