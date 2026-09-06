# Orca-native orchestration — /tier principles on Orca sessions

Epic claude-orca-qa2 follow-on, 2026-09-06. User request: inside Orca, let
one session be the orchestrator and delegate slices to executors that may be
Claude Code (subscription) or other vendors' models through OpenRouter, mix
and match, and have those child sessions be first-class Orca sessions
rather than Claude Code in-process subagents.

## Ground truth this plan stands on (verified on this box, Orca 1.4.197)

- Orca ships a native orchestration layer: `orca orchestration run-create /
  task-create / worker-start / dispatch --inject / check --wait / send
  --type worker_done / ask / reply / gate-*`. Headless `--serve` runs it;
  a plain shell binds a Run with `--from <terminal handle>`, an agent
  terminal auto-resolves its identity from `ORCA_PANE_KEY`.
- `worker-start --agent <id>` creates a fresh agent terminal in a worktree
  (`current`, an existing one, `new-child`, `new-top-level`) and injects the
  task spec plus a lifecycle preamble; `--model` is honoured for `claude`,
  `codex`, `cursor`. `dispatch --inject` needs a recognized agent CLI
  already running in the target terminal (`claude`, `codex`, `opencode`,
  `gemini`, `aider`, …); on a bare shell it fails "no recognized agent".
  `worker-start --terminal <handle>` adopts such a terminal as a supervised
  worker. Group addresses include `@claude`, `@codex`, `@opencode`,
  `@gemini`.
- Settings in orca-data.json: `agentDefaultArgs` (per agent id, e.g.
  `claude: "--dangerously-skip-permissions"`), `agentDefaultEnv` (per agent
  id), `nestedWorkerMaxDepth` (1).
- OpenCode 1.x is installed by `setup.sh` (this plan adds the pin). Its TUI
  and `run` both take `--model provider/model`; config comes from
  `OPENCODE_CONFIG=<file>` or `OPENCODE_CONFIG_CONTENT=<json>`; the
  OpenRouter provider is the `provider.openrouter.options.apiKey =
  "{env:OPENROUTER_API_KEY}"` block delegate.sh already generates; `--auto`
  approves permissions.
- Claude Code as a worker is the `claude` agent launched by Orca inside the
  VM: subscription login, no API key, its hooks feed Orca status.
- OPENROUTER_API_KEY reaches the VM as env from `claude-dev key openrouter`
  (qa2.7); Orca terminals inherit the serve process's env.

## Roles and backends (the /tier principles, re-based)

Roles stay: orchestrator · worker (executor) · recon (scout) · checker
(verifier). Each role binds a **backend** and a **model**:

| backend    | what runs                                     | models                          |
|------------|-----------------------------------------------|---------------------------------|
| `orca`     | a supervised Orca worker terminal              | `claude:<alias|id>` · `openrouter:<vendor/model>` (via `opencode`) · `codex:<id>` · `gemini:<id>` |
| `subagent` | Claude Code Agent tool, in-process (today)     | Anthropic only                  |

Defaults: worker = `orca` + `claude:<derived worker alias>` when the Orca
runtime is reachable, else `subagent` (running outside Orca still works);
recon = `subagent haiku` (cheap, read-only, shows as a sub-agent row);
checker = `subagent inherit` (checkers inherit the orchestrator's model,
never a foreign vendor). `/tier worker openrouter:qwen/qwen3-coder` or
`/tier worker claude:sonnet` rebinds the worker; `/tier` alone keeps the
derivation table. Invariants kept: expensive tiers never take the worker
seat; slices run sequentially; a worker's `worker_done` is a claim to check.

tier.json v2: `{top, worker:{backend,agent,model}, recon:{…}, checker:{…},
pinned, updated}`; v1 files are read as v2 with `backend: subagent`.

## The orchestrator's tools (bin/, tested against a real Orca serve here)

- `orca-dispatch <bead-id> [--worker|--checker] [--backend orca|subagent]
  [--agent X --model Y] [--worktree current|new-child]` — ensures one Run
  per orchestrator session (`.claude-dev/run/orchestration/run.json`,
  coordinator handle from `ORCA_TERMINAL_HANDLE`/`ORCA_PANE_KEY` or
  `--from`), creates the Task from the bead (title, description, acceptance
  contract, RED/GREEN rules, the worker rules: no delegation, no bead close,
  report by `worker_done`), starts the worker per backend:
  `claude` → `worker-start --agent claude --model <id>`;
  `openrouter` → `terminal create --command "opencode --model
  openrouter/<m>"` → `terminal wait --for tui-idle` → `worker-start --task
  --terminal <handle>`; `codex`/`gemini` → `worker-start --agent … --model`.
  Records `task_id`/`dispatch_id` on the bead notes. Prints one JSON receipt.
- `orca-wait [--timeout-ms N]` — one rolling `check --wait --types
  worker_done,escalation,question`; prints each message compactly, appends
  `worker_done` outcomes to the bead, releases settled workers
  (`worker-release`) unless `--keep`, acks the delivery, and leaves
  `question`/`escalation` for the orchestrator to answer with
  `orca-reply <msg_id> <text>`.
- `orca-workers` — `worker-list` + `task-list --brief`, one table.
- Fallback: with `runtime.reachable=false`, `orca-dispatch` prints the
  equivalent Agent-tool executor spec and exits 3, so the orchestrator falls
  back to the subagent path knowingly.

## Container side

- `setup.sh`: phase `opencode` (pinned npm install, `--check` row).
- Home config: `config/opencode/opencode.json` (OpenRouter provider block,
  `"model"` left to argv) synced by config-sync to
  `~/.config/opencode/opencode.json`; `seed-orca-state.sh` sets
  `agentDefaultEnv.opencode.OPENCODE_CONFIG` to that file,
  `agentDefaultArgs.claude = "--dangerously-skip-permissions"` and
  `agentDefaultArgs.opencode = "--auto"` (the VM is the boundary),
  `nestedWorkerMaxDepth = 1`.

## Playbook

`knowledge-base/TIERED_ORCHESTRATION.md` gains the backend model and the
dispatch loop; the rulebook § Delegation says executor slices go through
`orca-dispatch` when Orca is reachable and the Agent tool otherwise;
`delegation-gate` and `tier-prime` wording follow; `config/agents/executor.md`
is kept as the subagent fallback and says so.

## Parallel by default (user, 2026-09-06)

The bias flips from "slices run sequentially" to "everything independent
runs at once":

- **Waves.** `orca-run --epic <id> [--epic …]` reads an epic's ready
  children from bd, mirrors their dependency edges into Orca Tasks
  (`task-create --deps`), dispatches every ready task in one wave through
  `orca-dispatch`, then loops `orca-wait` → release → dispatch the newly
  ready set (`task-list --ready` is the coordinator's external memory).
  Only beads that freeze the same file, or name the same files, are
  serialized.
- **One Orca worktree per epic.** The first worker of an epic starts with
  `--worktree new-top-level --name <epic>`; later workers of that epic
  reuse the exact worktree id. Epics therefore run side by side in
  separate checkouts, visible as separate worktree cards in Orca. When an
  epic's last task settles, `orca-run` sends `merge_ready` with the branch;
  merging stays with the orchestrator, after the verifier.
- **Groups per epic.** `nestedWorkerMaxDepth` = 2, so an orchestrator may
  dispatch an *epic coordinator* (a Claude worker whose spec is "coordinate
  epic X with orca-run"); that coordinator runs its own wave loop with its
  own executors. The top session then supervises coordinators, not slices.
- **Rulebook invariant rewritten (O4):** independent slices run in parallel
  in separate Orca worktrees; slices that share files run sequentially in
  one worktree; recon fans out freely.

## Default stack and data residency (user, 2026-09-06)

Default: Fable orchestrates, the most capable GLM executes (today
`z-ai/glm-5.3` on OpenRouter through OpenCode). Hard rule: **the user's
data never routes to China.** GLM is served on OpenRouter by China-based
hosts (Z.AI, Baidu, Alibaba, SiliconFlow, StreamLake) as well as US/EU
ones, so the model choice alone decides nothing; the *provider* does.

Enforcement is a chokepoint inside the VM, not a client setting:

- `config/provider-policy.json` — a default-deny allowlist of OpenRouter
  provider slugs, each with its hosting country; China-based and
  unverifiable hosts are named and denied; `data_collection: deny`,
  `allow_fallbacks: false`.
- `scripts/container/openrouter-guard.py` — a local proxy on
  127.0.0.1:4141 that alone holds the real OpenRouter key. Every
  completion request from any client (OpenCode, Codex, delegate.sh) is
  rewritten with `provider.only = allowlist`, fallbacks off, data
  collection denied, then forwarded; a client-supplied order outside the
  allowlist is dropped and logged. Agent terminals receive only a guard
  token and the guard's base URL, so no process in the VM can reach
  OpenRouter with the real key except through the policy.
- Tier default: with an OpenRouter key present the derived worker is
  `orca + opencode + openrouter/z-ai/glm-5.3`; without one, the Claude
  rung as before. `/tier worker claude:<x>` still overrides.
- Belt and braces, the user's own action on openrouter.ai: account
  settings → ignored providers and "deny data collection".

Slices: **O7** policy + guard + tier default + client configs;
**O7b** entrypoint/seed wiring (after O5 and O6, which own those files).

## Slices (deep lane; one bead + contract each)

- **O1 container** — setup.sh opencode phase; opencode config + sync;
  seed-orca-state settings. Native bats + chroot `verify-rootfs.sh`.
- **O2 tier v2** — tier.json v2, tier-set/derive/prime/gate/reconcile,
  `/tier` command text. bats (tier-hooks.bats).
- **O3 dispatch tools** — bin/orca-dispatch, orca-wait, orca-reply,
  orca-workers; integration bats that boots a real `orca-ide --serve`
  (short socket path!) and drives: a bash worker (manual `worker_done`),
  an opencode worker to the point of launch + injection, a `claude` worker.
- **O4 playbook + hooks** — docs and hook wording; agents fallback note.
- **O5 proof** — one real bead dispatched from a coordinator terminal to a
  `claude` worker on this box (credentials exist here) through
  `orca-dispatch` → worker implements → `orca-wait` ingests `worker_done`
  → verifier. The OpenRouter worker is proven to launch with the right
  model and config; its model calls need the user's key, which is not here.

- **O6 parallel waves** — `orca-run`, per-epic worktrees, DAG mirroring,
  `merge_ready`, nested depth 2; integration bats with bash workers.

O1 and O2 touch disjoint files and run in parallel; O3 after both; O6
after O3; O4 and O5 after O6.
