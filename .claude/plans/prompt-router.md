# Prompt router: a cheap classifier says where the bulk of each prompt's work goes

Asked 2026-10-18: Jev-like routing in the template -- decide, per prompt,
what level of complexity it deserves. Quick and extremely cheap; Haiku is
fine if it measures best. The session's own model never changes (it stays
Opus); the router only decides where the bulk of the work is done, and a
complicated prompt must never land on a small model.

Jev routes each turn to a different model through the main loop. We do not:
switching the main model per turn breaks the prompt cache and is exactly the
"change the session's model" the user does not want. Here the session model
keeps orchestrating and the router picks who does the work, through the
roles `/tier` already binds (recon = Haiku scout, worker = Sonnet executor,
top = the session itself).

## Levels (the classifier's output)

| level | what it is | lane | bulk of the work |
|---|---|---|---|
| answer | chat, a status question, a one-line fact the session already knows | express | the session, inline, no spawn |
| lookup | read-only recon: find, list, summarize, "where is X" | express | one scout (recon tier, Haiku) |
| build | a clear, well-specified change: the what and the how are both given | standard | one executor (worker tier, Sonnet) |
| design | ambiguity, tradeoffs, an unknown cause, security or data surface, migrations, several slices, "plan/thorough/audit" | deep | the session plans and reviews; executors take slices |

Safety, by construction rather than by trusting the classifier:
- The small model only ever gets `lookup`, which is read-only. Anything that
  edits is `build` or higher, and `build` runs on the worker tier, never recon.
- The classifier is told to pick the higher level whenever it is unsure, and
  it returns a confidence; below the threshold the router moves one level up.
- Deterministic floors run first: plan/thorough/audit/security/migration/
  delete/push words force `design`; the session's rulebook already says so.
- The router recommends; the session declares the lane. The rulebook line:
  take the router's level unless the prompt is plainly harder than it says --
  going up needs no reason, going below the router's level needs one, and
  the bulk never goes to a smaller model than the level names.
- No answer in time (2.5 s), no guard, `"router": false` in claude-orca.json:
  the router prints nothing new and the lane reminder stands as today.

## Pieces

- `scripts/route-prompt` (UserPromptSubmit, beside `lane --prompt`): reads
  the prompt plus the last assistant message from the transcript (a "fix
  bugs" makes sense only against what came before), skips headless workers
  and trivial prompts ("yes", "go on", slash commands keep the last route),
  makes one chat completion through the OpenRouter guard (same residency
  policy as workers and the activity panel), prints one line:
  `[route] build -> lane standard; bulk: one executor (worker tier). <reason>`
  and appends one line per call to `.claude-dev/run/route/calls.log`
  (level, confidence, model, ms, tokens, cost -- never the prompt).
- Model and classifier prompt chosen by measurement: an eval set of real
  prompts labeled by hand, every candidate (glm-flash, deepseek-flash,
  Haiku 4.5 via Bedrock/Vertex, a nano model) run through the real guard.
  Pick: zero `design` prompts routed below `build`, then lowest p95 latency,
  then cost. The prompt ships as data (`config/route/classifier.txt`).
- Rulebook (§ Lanes) and knowledge-base/TIERED_ORCHESTRATION.md: one short
  paragraph each.

## Slices

- R1 eval + bake-off: labeled prompt set (synthetic paraphrases committed as
  a fixture; the real prompts stay in the scratchpad), classifier prompt,
  measured table, model choice.
- R2 the hook: route-prompt, wiring, fast paths, timeout, fallback, log;
  bats against tests/helpers/fake-guard.py.
- R3 rulebook + docs + the real check: a real Claude Code TUI with the hook,
  three prompts (answer / build / design) -- the route line in context, the
  session's lane matches, latency and cost from calls.log.
