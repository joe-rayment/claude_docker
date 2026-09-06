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
| `glm` | `openrouter/z-ai/glm-5.2` (provider-pinned: novita, parasail, no fallbacks) | executor |
| `deepseek` | `openrouter/deepseek/deepseek-chat` | executor |
| `qwen-coder` | `openrouter/qwen/qwen3-coder` | executor |
| `local` | `ollama/qwen3-coder:30b` (loopback, no egress) | scout |
| `codex` / `gemini` | first-party examples for those runners | executor |

`config/delegate-routes.json` is **user-editable configuration, not a fixed
list**: any id from [openrouter.ai/models](https://openrouter.ai/models)
works as `"model": "openrouter/<id>"`, and the provider prefix is what
`delegate.sh` maps to a key variable and an egress host.

### Where the key goes

`<project>/.claude-dev/state/openrouter.key` — one line, mode 600:

```bash
printf '%s\n' 'sk-or-...' > .claude-dev/state/openrouter.key
chmod 600 .claude-dev/state/openrouter.key
```

The user writes that file; **no command in this repo ever writes a key**.
`state/` is host-owned and write-denied to both sandbox layers, so nothing
inside the sandbox can read or rewrite it. `claude-orca-shell` reads it on
the host at launch — the same place and the same way it reads `gh auth
token` — exports `OPENROUTER_API_KEY` into the session, and passes
`--openrouter-key-present` to `gen-settings.sh`, which adds the mask
(`credentials.envVars`) and the `openrouter.ai` inject host. An
`OPENROUTER_API_KEY` already exported on the host wins; the file is the
default, not an override. The value is never echoed, never written under the
project, and `claude-orca-shell --print-env` omits it exactly like
`GH_TOKEN`. No key file (and no exported key) means no export, no mask, and
no OpenRouter surface for that folder.

### The egress domain, and pre-existing folders

`claude-dev register` seeds `network.extraAllowedDomains: ["openrouter.ai"]`
when it *creates* a folder's `sandbox.json`, so the preflight below is
truthful for the shipped routes out of the box. An allowlist entry grants
nothing on its own — without a key there is nothing to send. An existing
`sandbox.json` is never rewritten (same rule as `orca.cli`), so a folder
registered before this change needs the one-line add:

```json
{"network": {"extraAllowedDomains": ["openrouter.ai"]}}
```

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
- **Masked provider keys**: the key is passed through `srt`'s credential
  masking, so the child sees a sentinel and the proxy injects the real value
  only for that provider's hosts. Key material is additionally literal-
  replaced out of `runner.log` and `receipt.json` after the run.
- **Egress preflight**: instead of the old iptables firewall, `delegate
  check` verifies the route's provider host is in the sandbox allowlist. If
  it is not, add it to `network.extraAllowedDomains` in
  `.claude-dev/sandbox.json` — a route cannot open a hole by itself.
- **Worktree isolation**: `git worktree add <job_dir>/worktree -b
  delegate/<job> HEAD`. The real repo's branch and worktree list are
  untouched.
- **Merge-after-verify**: `delegate.sh` never merges. A `--bead` job appends
  `delegated-to:` / `branch:` / `receipt:` to the bead's notes; the branch
  waits for a native `verifier` PASS, then merging is an ordinary
  orchestrator step.

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
| `<PROVIDER>_API_KEY not set` | no key in the environment for the route's provider | for OpenRouter, write `.claude-dev/state/openrouter.key` and restart the shell; otherwise export it before launching the session (the wrapper masks it either way) |
| `egress blocked (domain not allowlisted)` | the provider host is not in the sandbox allowlist | add it to `network.extraAllowedDomains` and restart the shell |
| `ollama unreachable` | `curl -sf -m 2 http://127.0.0.1:11434/api/version` failed | start Ollama; local binding is already allowed by the profile |

`delegate check` never blocks on a degraded route — it always exits 0. The
loud, nonzero failure happens inside `delegate run`, for the chosen route
only.

Interactive Codex, Gemini and OpenCode sessions you open in Orca are a
different path: they are sandboxed by the shell hook like any other terminal
(see [SANDBOX.md](SANDBOX.md)) and share the project's beads database.
