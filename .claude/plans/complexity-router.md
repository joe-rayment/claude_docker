# Complexity Router ("lanes") — Plan

Status: proposed, awaiting user approval. Authored 2026-08-11.

## Problem

Every prompt currently gets the full-court press: top-tier orchestrator deliberation, a
dispatch line pushing delegation, plan-before-code, executor slices, acceptance
contracts, verifier sign-off, review cycles. "Change the background to blue" costs the
same ceremony as "redesign the sync layer". The template needs a router: classify each
prompt's real complexity, then apply the right amount of process AND the right model
tier — with the full treatment reserved for work that deserves it.

## Evidence base (researched 2026-08-11)

External approaches (URLs in session transcript):

- **RouteLLM** (LMSYS): learned win-rate router, 95% of strong-model quality at 14–26%
  of strong-model calls. **FrugalGPT**: cheapest-first cascade with a scoring judge,
  up to 98% cost cut. **HybridLLM**: upfront difficulty classifier, ~40% fewer
  strong-model calls at no quality drop.
- **Cursor Router**: promotes to a pricier model only on a one-sided 75%-confidence
  uplift over the cheapest capable model — the best anti-over-routing mechanism found.
- **GPT-5 router**: the canonical failure — *silent under-routing* of hard prompts to
  the fast model, unrecoverable because there was no escalation path and no
  transparency; forced OpenAI into public walk-backs. Lesson: show the route, allow
  override, make escalation cheap.
- **Aider architect/editor & Claude Code `opusplan`**: static two-tier split (expensive
  model plans, cheap model edits) — this is our existing tier system; the router adds
  the missing lane *below* it.
- **Community Claude Code "router hooks"** (tzachbon/claude-model-router-hook,
  bmersereau/claude-router, etc.): regex-classify the prompt and claim to auto-switch
  the session model. Per current official docs this lever does not exist — hooks
  cannot change the main session's model or effort; their claims are unverified.
- **Cross-cutting**: upfront classification beats cascades when difficulty signals are
  good; LLM *self-confidence* is a poor difficulty signal, but objective task-shape
  checklists (files touched, ambiguity, reversibility, tool-orchestration need) are the
  recommended signals for coding tasks; router latency is a non-issue.

Capability surface (verified against official docs + our own probes):

- Main-session model/effort is **fixed per turn** — only `/model`, `--model`, env, or
  settings change it; UserPromptSubmit output can only inject context or block.
- Subagent model: frontmatter aliases/ids/`inherit`; Agent-tool `model` param wins over
  frontmatter; PreToolUse `updatedInput` can rewrite it deterministically (verified
  in-repo, memory `pretooluse-agent-model-override`).
- Subagent frontmatter accepts `effort:` — a cheap-lane agent can run at low effort.
- Hooks share `session_id` (+ `prompt_id`) across UserPromptSubmit and PreToolUse in
  the same turn → per-turn state files work.

Design consequence: **the router lives in the orchestrator's judgment (doctrine) with
mechanical enforcement and measurement in hooks** — not in a prompt-regex hook
pretending to switch models. Fable classifying task shape against an objective rubric
is a far stronger classifier than any regex, costs ~zero extra (it reads the prompt
anyway), and the hooks make the choice explicit, enforced, and measurable.

## Design

### Route-first: three lanes

The orchestrator's FIRST action on every prompt is to classify the task and declare a
lane via `lane <express|standard|deep> [--why "..."]` (tiny exempt Bash call). The
declaration is the transparency mechanism (visible in transcript, logged, aggregated by
cost-mirror) and the enforcement key (delegation-gate reads it).

**express** — ALL of: single file or no files touched; mechanical/cosmetic change, or a
question answerable from context or one lookup; no design choice; trivially reversible;
no new dependency/interface/contract.
→ Do it inline immediately. No plan, no bead, no executor, no verifier, no review
cycle, minimal deliberation, short answer. Verification is one run/screenshot when the
change is observable, else the diff itself. Budget ≈ 5 tool calls.

**standard** — one well-understood slice, low-to-moderate risk, no architectural
choice. → One-sentence approach in the reply (no plan mode), then either finish inline
or hand ONE executor a slice spec; verify by running the result once. No acceptance
contract, no verifier, unless the claim is contested or becomes risk-bearing.

**deep** — ANY of: ≥3 files or any interface/schema/config contract; multiple
reasonable approaches with real tradeoffs; ambiguity requiring interpretation;
hard-to-reverse effects (migration, deletion, push, publish); security or
data-integrity surface; user asked for thoroughness ("plan", "audit", "carefully").
→ The full existing protocol: plan (plan mode for big tasks), beads with
CHECK/PASS-IF acceptance contracts, executor slices, verifier sign-off, review.

Tie-break and safety net (this is where we beat the inspirations):

- **When between lanes, take the lighter lane** (doctrine already says "let the cheap
  tier attempt first") **but with one-way escalation tripwires**: scope grows past the
  rubric, a first fix attempt fails, hidden ambiguity surfaces, unexpected test
  breakage → escalate exactly one lane, announce it, never de-escalate within the
  prompt (no thrash). This converts GPT-5-style under-routing from catastrophic to
  self-healing, while keeping the express lane genuinely reachable.
- **User override always wins**: "quick/just" biases light; "plan/thorough/audit"
  forces deep; `ultrathink` raises effort as today. The lane line makes the route
  visible so the user can redirect immediately.

### Model dimension — honest economics

The main model cannot drop to Sonnet/Haiku per-turn, and for true one-liners it
shouldn't: a ~300-output-token inline fable turn is cheaper AND faster than any
executor spawn (which re-reads context at ~10k+ tokens). The router saves model cost
where the bulk is: standard/deep work flows to sonnet executors and haiku scouts as
today, and express eliminates the spawns, plans, and review cycles that were the actual
waste. For light-work days, `/model sonnet` remains the session-level lever (tiers
re-derive automatically). This split — process routed per-prompt, model routed per
sub-task and per-session — is exactly what the capability surface supports, unlike the
community hooks that claim in-place model switching.

## Contradictions found (and exact resolutions)

1. `config/claude-user-memory.md:9` "never wait for a per-prompt invitation to spawn"
   — keep as *authorization*, add one sentence: authorization is not obligation; the
   lane decides whether spawning happens at all.
2. `config/claude-user-memory.md` "A codebase question is recon plus reasoning, not a
   reason to skip delegation" — scope to multi-file recon; a single known-location
   lookup is express.
3. Dispatch-table row "trivial: whole task fits in a couple of your own tool calls" —
   replaced by the three-lane rubric (single source, see Implementation).
4. `scripts/delegation-gate.py:381-389` — guard denies main-loop Edit/Write regardless
   of task size. Becomes lane-aware (below).
5. `config/claude-settings.json:57` dispatch echo — becomes the route-first line.
6. `scripts/tier-prime.sh --full` (PreCompact) — must re-inject the lane rubric or
   compaction silently loses the router.
7. `CLAUDE.md` "Plan Before Code" ("any task touching multiple files or with more than
   one reasonable approach") — retrigger on the deep-lane rubric; a multi-file
   mechanical rename is standard, not deep.
8. `CLAUDE.md` Verification — keep "run, don't guess" in every lane but right-size it:
   express = one observation, no verifier agent.
9. bd prime's baked-in "Create beads issue BEFORE writing code" — extend the existing
   named override in CLAUDE.md: express work files no bead (nothing to track); standard
   files one only if follow-up remains.
10. Acceptance-contract protocol (CHECK/PASS-IF/RED-AT/GREEN-AT + verifier per bead) —
    scoped to deep lane and contested claims; today's text binds it to every
    "non-trivial claim".
11. Economics paragraph ("your inline reads are re-billed every turn") — add the
    express exemption so it stops guilt-tripping one-liners into spawns.

Doctrine sprawl is itself a found bug: the dispatch wording currently lives in 4 places
(user-memory, CLAUDE.md, settings echo, tier-prime). The rubric gets ONE authoritative
home (`lane --prime`, same pattern as tier-prime owning tier wording) and every other
site references or prints it.

## Implementation

Phase 1 — doctrine + mechanism (the felt fix):

1. `scripts/lane.sh` → `/usr/local/bin/lane` (+ Dockerfile COPY line — see memory
   `renaming-a-scripts-sh-file-requires-updating-its`):
   - `lane express|standard|deep [--why "…"]` writes
     `~/.claude/cache/lane/<session_id>.json` `{lane, why, ts, prompt_id?}` and echoes
     a confirmation line; appends to `~/.claude/cache/lane/log.jsonl` for measurement.
   - `lane --prime` prints the rubric + route-first instruction (single wording home).
   - `lane --reset <session_id>` clears state (called by UserPromptSubmit hook so a
     stale express never leaks into the next prompt; unset ⇒ exactly today's behavior).
   - Name chosen to avoid the `route(8)` binary collision.
2. `config/claude-settings.json`:
   - UserPromptSubmit: add `lane --reset` + swap line 57's dispatch echo for
     `lane --prime --short` (route-first one-liner).
   - SessionStart / PreCompact: `tier-prime --full` gains the rubric via `lane --prime`.
3. `scripts/delegation-gate.py` lane awareness (reads the state file by `session_id`):
   - express → main-loop Edit/Write/NotebookEdit allowed; streak still counts; past
     ~6 counted tools emit a "mis-routed? escalate or re-declare" warn (express tasks
     are small by definition — a long grind under express is the drift signal).
   - standard/deep/unset → exactly today's guard/enforce semantics. Fail-open stays.
4. `lane` added to delegation-gate's EXEMPT_BASH_RE and bd-guard-safe.
5. Doctrine edits per the contradictions list: `config/claude-user-memory.md`
   (dispatch table → lane table + tripwires + override keywords), `CLAUDE.md`
   (Plan Before Code, Verification, Tiering section gains "Router" subsection, beads
   override extension), `knowledge-base/TIERED_ORCHESTRATION.md` (new Router chapter
   with the evidence digest and tuning knobs).
6. Tests: `tests/lane.bats` (declare/reset/read/stale-session), delegation-gate lane
   cases in `tests/delegation-gate.bats` (express allows Edit, unset denies, unknown
   lane value falls back to guard — never weaker), tier-hooks regression.

Phase 2 — measurement (how we claim "optimal balance" with data, not vibes):

7. `cost-mirror.py`: join the lane log; per-prompt line gains `lane=express`; `tier-cost`
   report gains lane distribution, escalation rate, $/lane.
8. Tuning targets: escalation rate 5–15% (persistently <5% ⇒ we classify too heavy;
   >20% ⇒ express rubric too greedy — adjust rubric thresholds, e.g. the file count);
   watch express share per session type. bead-auditor continues to catch quality
   regressions on the standard/deep side.

Phase 3 — optional hardening (only if Phase 2 data shows drift):

9. PreToolUse tripwire refinements (e.g. auto-suggest deep when an express turn spawns
   an Agent); a low-effort `effort:` variant on executor for standard-lane mechanical
   slices; per-lane subagent model injection via tier-gate `updatedInput` if measurement
   shows standard-lane executor work that Haiku could carry.

## Why this outperforms the inspirations

- Works entirely within the real capability surface (community router hooks don't).
- Classifier is the strongest model in the system applying an objective task-shape
  rubric — per the research, exactly the signal set that works for coding tasks, and
  free, versus regex (crude) or self-confidence (unreliable).
- Cursor's anti-over-routing idea appears as "lighter lane on ties + articulable
  deep-IF-ANY criteria"; FrugalGPT's cascade appears as one-way escalation tripwires;
  GPT-5's failure is designed out via transparency (`lane` line) + override + cheap
  escalation.
- It's enforced (delegation-gate) and measured (cost-mirror lanes), so the balance is
  tunable against data — none of the community setups measure anything.
- Fail-safe: unset/unknown lane ⇒ today's behavior exactly; every hook stays fail-open.

## Risks

- **Lazy always-express drift**: express long-grind warn + lane stats + bead-auditor.
- **Under-routing**: deep-IF-ANY rubric, tripwires, user override.
- **Doctrine divergence**: single wording home in `lane --prime`.
- **Stale lane state**: reset every UserPromptSubmit; unset = safe default.
