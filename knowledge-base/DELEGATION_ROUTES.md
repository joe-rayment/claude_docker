# Delegation routes — headless execution on an external model

When to use: deciding whether a slice belongs on a `delegate` route instead
of a native `executor`, reading a `receipt.json`, tracing a job's files, or
debugging a `delegate check` reason. Policy summary lives in the rulebook
(`config/claude-user-memory.md`); this is the full playbook.
Implementation: `scripts/delegate.sh`.

## Routes are orthogonal to tiers

**Tiers** ([TIERED_ORCHESTRATION.md](TIERED_ORCHESTRATION.md)) answer "which
Claude model handles this" — orchestrator / executor / scout / verifier,
bound by `/tier` into `.claude-dev/state/tier.json`, all still Claude Code.
**Routes** answer a different question: "should this slice leave Claude
Code's model selection entirely and run headless under another tool, against
another provider". The two never share a name, a config file, or a selection
mechanism.

That separation is deliberate, learned the hard way: tiering's v1 tried to
redefine what `"opus"`/`"sonnet"`/`"haiku"` *meant* by rewriting
`ANTHROPIC_DEFAULT_*_MODEL` underneath Claude Code's own `/model` picker, and
collided structurally. Routes avoid it by construction — a route name is
never written to `.model`, and is invoked through its own CLI. A route and a
tier can both be true of one job (an executor-tier orchestrator dispatches a
slice onto the `glm` route) without either meaning the other.

## Commands

```bash
delegate check
    # Per-route health table (route, status live|degraded, reason).
    # Always exits 0 — informational, never a gate.

delegate run --route <route> (--bead <id> | --prompt <text> | --prompt-file <f>)
    # Dispatch one job. Exactly one of --bead/--prompt/--prompt-file.
    # --bead is refused on a scout-grade route (prompt-only there).
    # Unknown route or failed preflight -> loud error, nonzero exit,
    # never a silent fallback to another route or model.

delegate ps       # running (pid alive, no receipt) vs done (receipt present)
delegate report   # per-route jobs, PASS/FAIL/TAMPERED counts, delegated USD
```

Routes come from `config/delegate-routes.json` — name → `runner`, `model`
(`<provider>/<model-id>`), optional `pin` (provider order / fallback policy),
`grade` (`executor` or `scout`). Runners:

| `runner` | Invocation |
|---|---|
| `opencode` | `opencode run` headless, route-scoped config under the job's own `XDG_CONFIG_HOME` |
| `codex` | `codex exec` |
| `gemini` | `gemini -p` |

`$DELEGATE_ROUTES` overrides the config path (tests only); `$DELEGATE_REPO`
overrides the repository `run`/`ps` operate against — it defaults to the
primary checkout, resolved from `git rev-parse --git-common-dir`, never a
hard-coded path.

## The assumed stack: Claude Code master, OpenRouter workers

The setup this repo installs assumes Claude Code orchestrates and cheap
OpenRouter models do the bulk work, so OpenRouter is wired in by default
rather than treated as an extra provider. Shipped routes:

| Route | Model | Grade |
|---|---|---|
| `glm` | `openrouter/~z-ai/glm-latest` (provider-pinned: deepinfra, parasail, no fallbacks) | executor |
| `glm-flash` | `openrouter/~z-ai/glm-flash-latest` | scout |
| `luna` / `luna-high` | `openrouter/~openai/gpt-luna-latest` (`luna-high` adds the `high` effort) | executor |
| `deepseek` | `openrouter/~deepseek/deepseek-pro-latest` | executor |
| `deepseek-flash` | `openrouter/~deepseek/deepseek-flash-latest` | scout |
| `qwen-coder` | `openrouter/qwen/qwen3-coder` (no OpenRouter alias yet: a fixed version) | executor |
| `local` | `ollama/qwen3-coder:30b` (loopback, no egress) | scout |
| `codex` / `gemini` | first-party examples for those runners | executor |

`config/delegate-routes.json` is **user-editable configuration, not a fixed
list**: any id from [openrouter.ai/models](https://openrouter.ai/models)
works as `"model": "openrouter/<id>"`, and the provider prefix is what
`delegate.sh` maps to a key variable and an egress host. A `~<vendor>/<family>-latest`
id is OpenRouter's newest-in-family alias (its catalogue entry names the
current `alias_target`): OpenRouter resolves it per request, so a route or a
`/tier` binding written that way picks up a new release with no edit and no
re-bind — the OpenRouter twin of Claude Code's `fable`/`opus`/`sonnet`.

### Where the key goes

`./claude-dev key openrouter` on the Mac reads the key without echoing it
and stores it at `<project>/.claude-dev/home/.openrouter.key` (mode 600,
gitignored) — that path is `/home/agent/.openrouter.key` inside the
container, since `.claude-dev/home` is mounted as the agent's `$HOME`.

Nothing in the sandbox ever sees that real key. On boot,
`scripts/container/entrypoint.sh` reads it (or `OPENROUTER_API_KEY` if
already exported, or opencode's own `auth login openrouter` store) and
hands it to `openrouter-guard.py` alone, over a mode-600 file the guard
unlinks once read — never argv, never an inherited env var. The guard is
the only process in the VM that holds the real key; it pins every
completion request to US/Canada/Europe providers
(`config/provider-policy.json`) regardless of what the client asked for.
Orca and every terminal it spawns — including delegate workers — get a
random guard token and the guard's loopback base URL as
`OPENROUTER_API_KEY`/`OPENROUTER_BASE_URL` instead. No key file (and
nothing already exported) means the guard never starts and there is no
OpenRouter surface for that folder.

### Egress

There is no per-domain allowlist to keep in step: the container VM reaches
the network the way the Mac does, so a route with a key set can talk to its
provider and `delegate check` says so. A key is the only thing that gates it
— without one there is nothing to send.

## Cheap workers without losing quality

The saving comes from moving *typing* to a cheap model, never from moving
*judgement*. Split every job the same way:

| Stays on the strong model (Claude Code) | Goes to a delegate route |
|---|---|
| Deciding the lane, decomposing, sequencing slices | Implementing one already-specified slice |
| Writing the bead and its `CHECK`/`PASS-IF`/`FROZEN`/`CLASS` contract | Mechanical refactors, boilerplate, a well-fenced bug fix |
| Reviewing the diff and running the `verifier` | Bulk edits with an existing test to satisfy |
| Anything hard to reverse, security-shaped, or ambiguous | Anything whose success is a command's exit code |

Two rules keep the quality where it was:

1. **The contract is written before dispatch, by the strong model.** A
   worker that can see `PASS-IF` cannot negotiate it, and the `FROZEN` test
   is pinned at `RED-AT` before any worker touches the repo.
2. **The check is never delegated.** `verifier` runs on a native Claude
   tier ([TIERED_ORCHESTRATION.md](TIERED_ORCHESTRATION.md)) against the
   contract, and anything short of `PASS` goes back to an executor. A
   worker's summary is a claim, not evidence.

Because `delegate.sh` never merges, a bad worker run costs one throwaway
branch and the receipt's dollars — not a regression.

### A worked run

```bash
# 1. The strong model files the slice with its contract attached.
bd create --title "Extract the retry helper" \
          --description "Move the retry loop out of fetch.sh into lib/retry.sh; callers unchanged." \
          --acceptance 'CHECK:   ./run-tests.sh
PASS-IF: exit 0; zero "not ok" lines; tests/retry.bats present and passing
FROZEN:  tests/retry.bats
CLASS:   standard'

# 2. Confirm the route is live (informational, always exits 0).
delegate check

# 3. Dispatch the slice headless to a cheap OpenRouter worker.
delegate run --route deepseek --bead claude-orca-abc.1

# 4. Watch it, then read the receipt the job appended to the bead.
delegate ps
bd show claude-orca-abc.1

# 5. Verification stays here: spawn the native verifier on the bead, which
#    runs the CHECK verbatim against the RED-AT/GREEN-AT pair.
#    On PASS, merging is an ordinary orchestrator step:
git merge --no-ff delegate/deepseek-1757000000-a1b2c3

# 6. What it cost, native vs delegated.
delegate report
```

Publish main only when the prompt asks for it — the merge above is local,
like every other commit in this template.

## Receipt schema (`<job_dir>/receipt.json`)

Written after every job, success or failure:

| Field | Type | Notes |
|---|---|---|
| `job` | string | `<route>-<epoch>-<hex>`, also the job dir name and branch suffix |
| `route` / `model` | string | as configured |
| `bead` | string \| null | bead id for `--bead` dispatch |
| `branch` | string | `delegate/<job>` |
| `tokens_in` / `tokens_out` | int \| null | from the runner's event stream; `null` when absent |
| `wall_seconds` | int | measured around the runner invocation |
| `usd` | number \| null | provider-reported cost, verbatim |
| `exit_code` | int | the runner's own exit code |
| `started_at` / `finished_at` | string | UTC `%Y-%m-%dT%H:%M:%SZ` |

## Job directory (`.claude-dev/delegate/<job>/`, gitignored)

```
worktree/            ephemeral git worktree, branch delegate/<job>
config/              runner-scoped config (its own XDG_CONFIG_HOME)
home/                the job's own $HOME
pid                  the runner's pid while running (absent once done)
runner.log           raw event stream, secret-redacted after the run
worktree-add.log     `git worktree add` output
receipt.json         schema above, secret-redacted after the run
```

## Isolation

- **Scrubbed env**: `env -i` plus exactly `PATH`, `HOME` (the job's own),
  `XDG_CONFIG_HOME` (the job's own), `TERM=dumb`, and the route's provider
  key. No `ANTHROPIC_*` variable ever reaches the child — by construction,
  not by denylist.
- **Redacted keys**: key material is literal-replaced out of `<job>/env`,
  `runner.log` and `receipt.json`, so a receipt can be read and shared
  without leaking the value that produced it.
- **Preflight**: `delegate check` verifies what it can observe — the runner
  is on PATH, a loopback runtime answers, the provider key is set — and
  `delegate run` refuses on anything but `live`. No silent fallback to
  another route or model.
- **Worktree isolation**: `git worktree add <job_dir>/worktree -b
  delegate/<job> HEAD`. The real repo's branch and worktree list are
  untouched.
- **Merge-after-verify**: `delegate.sh` never merges. A `--bead` job appends
  `delegated-to:` / `branch:` / `receipt:` to the bead's notes; the branch
  waits for a native `verifier` PASS, then merging is an ordinary
  orchestrator step — in the same turn as the PASS, never later.
- **Cleanup-after-merge**: `worktree-gc` (run after every `git merge` by a
  PostToolUse hook, at session start and end, by `disk-cleanup`, and by the
  boot step `65-worktree-sweep`) removes the job's worktree once its branch
  is merged, deletes the merged branch, and then sweeps the finished job's
  `home/` and `config/` (~160 MB of runner caches per job), keeping
  `receipt.json`, `runner.log`, `branch` and `env`. A branch with commits
  not in main is reported as `STRANDED`, never deleted.

## Billing guards are separate

`auth-guard` FATALs a session when `ANTHROPIC_BASE_URL`,
`ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY` is set — in the environment or
under the `.env` block of `settings.json` / `settings.local.json` — because
any of the three silently flips **Claude Code's own** billing from
subscription to API. `CLAUDE_DEV_ALLOW_API_BILLING=1` downgrades it to a
warning. It does not gate a route's provider key: that pays an external
provider for a deliberate, accounted-for call. Different money, different
guard.

## Ledger integration

`delegate run` best-effort ingests its receipt into `cost-mirror`'s lifetime
ledger (`--ingest-delegate-receipt`), gated on the flag existing and wrapped
in `|| true` — a ledger failure never fails the job. Rows land with
`side: "delegate"`, keyed by job id (re-ingest replaces, never duplicates),
and render as their own `delegated: <model> $X.XX (N job(s))` segment after
the native table. External dollars are never blended into the native
actual/at-top/saved columns.

## Troubleshooting (`delegate check` reasons)

| Reason | Cause | Fix |
|---|---|---|
| `<runner> not found on PATH` | the runner CLI is not installed | install it; confirm `command -v <runner>` |
| `<PROVIDER>_API_KEY not set` | no key in the environment for the route's provider | for OpenRouter, run `./claude-dev key openrouter` on the Mac and restart the container; otherwise export the key before launching the session |
| `ollama unreachable` | `curl -sf -m 2 http://127.0.0.1:11434/api/version` failed | start Ollama; local binding is already allowed by the profile |

`delegate check` never blocks on a degraded route — it always exits 0. The
loud, nonzero failure happens inside `delegate run`, for the chosen route
only.

Interactive Codex, Gemini and OpenCode sessions you open in Orca are a
different path: they are sandboxed by the shell hook like any other terminal
(see [SANDBOX.md](SANDBOX.md)) and share the project's beads database.
