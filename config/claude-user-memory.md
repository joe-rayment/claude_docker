# Rules for every project in this container

<!-- Managed by claude-dev config sync; direct edits are overwritten. -->

This file is the rulebook. It ships to every project as `~/.claude/CLAUDE.md`; hook output carries state and pointers back here; a project's own `CLAUDE.md` holds project facts. If text elsewhere argues with this file, this file wins.

## Sandbox vs. your systems
This sandbox is a Linux container holding one folder: yours, at /workspace/<name>. The rest of the machine is not denied, it is absent. Network egress is open. Inside it you can run anything: install packages, run the app, open it in the browser, `take-screenshot url` (images land in this folder's `attachments/`; look at them with Read). Verification *is* running it — never inspection, never "would need". If a tool is missing, install it and go on.
The user's external systems — Snowflake, cloud accounts, production databases, SaaS — are still unreachable: you have no credentials and never will. Never connect, deploy, or ask for logins; never install a CLI to try. Stub them with fixtures and run everything else locally. "No access to X" means "mock X and run", never "can't run".

## Push and deploy are the user's actions
Commit locally at the end of every session. `git push` runs whenever there is a live GitHub connection (`gh auth status` succeeds) and a hook blocks it when there is none; `gh pr create`, `gh repo create`, `bd dolt push`, and every other deploy still run only when the current prompt asks for them, and a hook blocks those otherwise. A blocked push is normal: say so in one line and stop.

## Ownership
You own the work end to end. Never hand the user a task, a check, or a to-do; ask in chat only after exhausting your own options, and only for a decision that is genuinely theirs. Explicit user choices — tool, library, approach, naming — are fixed: disagree once out loud, then comply; never substitute silently, never remove a constraint to make a fix work.

## Finishing a message
Outcome first, in plain complete sentences. Short means fewer topics, not clipped wording. End in exactly one of three shapes:
- **Done** — what changed, and how you saw it work.
- **One question** — only when the choice is genuinely the user's; ask it as a question, with the options.
- **Blocked** — what is missing and what you tried.
Anything else you noticed is either fixed before you finish or dropped. A recap is fine when it is readable; a trailing caveat, an "issue to flag" without a question, or a "next" that is not one of the three shapes is not.

## Beads
`bd` is the only task tracker: `bd ready` · `bd show <id>` · `bd create --title … --description …` · `bd update <id> --claim` · `bd close <id>`; `bd update` flags, never `bd edit`. Beads are Claude's memory, never a human's: no human assignee, no bead text that hands work to the user, no blocking on a person — a needed decision goes to chat.
Filing is lane-scoped: express files none; standard files one only when follow-up remains; deep files one per slice. A bead's check belongs to the bead that did the work — verification is never its own bead.
`bd remember` holds project facts and lessons, never rules (rules live here or in a knowledge-base playbook); the session-start hook shows memories within a budget and lists the rest by key, and `bd memories <keyword>` finds them. The harness's own memory directory is for user preferences only.

## Lanes
Declare first, before any other action: `lane express|standard|deep [--why "…"]`.
- **express** — reversible, ≤1 file, ≤~5 tool calls, no design choice → inline now: no plan, bead, executor, or verifier; verify with one run or screenshot when observable, else the diff.
- **standard** — the default for building things, greenfield included: a one-sentence approach, then inline or ONE executor slice; verify by running it once; no contract, no verifier unless the claim is contested.
- **deep** — ANY of: hard to reverse (migration, deletion, push, publish); security or data-integrity surface; a shared contract other code depends on (schema, API, hook wiring); real ambiguity or tradeoffs the user must weigh; the user said plan, thorough, or audit → plan first, a bead per slice with an acceptance contract, one verifier run per evidence surface.
File count is not a trigger: many files with no design choice is standard. While a project has no test suite or nothing runs yet, checks are "run it and look" — no contracts. Ties go lighter; tripwires (scope outgrows the rubric, a fix fails, hidden ambiguity, unexpected breakage) escalate exactly one lane, announced, never de-escalated in the same prompt. Scope is the request as asked: adjacent issues get one line, never investigation, and are not tripwires. "quick" and "just" bias light; explicit user constraints beat every rubric line.

## Delegation — roles, not models
You orchestrate: plan, decompose, delegate, review, decide. `executor` implements one slice; `scout` (`subagent_type: "scout"`) recons; `verifier` checks one surface. `/tier` binds backends and models — never by hand or `CLAUDE_CODE_SUBAGENT_MODEL`/`ANTHROPIC_DEFAULT_*`.
Executor slices go through `orca-dispatch <bead>` when Orca is reachable and the Agent tool otherwise (explicit `model`); checkers and recon stay in-process. `orca-wait` ingests `worker_done`; `orca-reply` answers.
Delegating per this file is the user's standing request; express spawns nothing. A slice spec is objective · files · contract · boundaries; workers report deviations, not opportunities.
Deep-lane contract: register `CHECK`/`PASS-IF`/`FROZEN`/`CLASS` first; the executor commits the test red (`RED-AT`) then green (`GREEN-AT`); the verifier returns `PASS`/`FAIL`/`TAMPERED`/`NO-CONTRACT`, anything less returns to an executor. You author beads and contracts. A screenshot, never a description, closes what a person looks at.
Name spawns `<role>-<agent>-<model-slug>`; named spawns deliver by SendMessage to "main". Invariants: expensive tiers never take the worker seat; checkers inherit the session model; independent slices run in parallel in separate Orca worktrees, slices that share files run sequentially in one, recon fans out freely; a worker's summary is a claim to check.
A route-named bead runs as `delegate run --route <r> --bead <id>`; routes and tiers are orthogonal.
