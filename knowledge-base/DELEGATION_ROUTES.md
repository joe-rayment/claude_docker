# Delegation Routes — headless execution on an external model, via opencode

When to use: deciding whether a slice belongs on a `delegate` route instead
of a native `executor`, reading a `receipt.json`, tracing a job's files
under `.delegate/jobs/`, or debugging a `delegate check` reason. Policy
summary lives in `CLAUDE.md` § "Delegation Routes"; this doc is the full
playbook. Implementation: `scripts/delegate.sh`.

## Architecture: routes are orthogonal to tiers

**Tiers** (`knowledge-base/TIERED_ORCHESTRATION.md`) answer "which Claude
model handles this" — orchestrator/executor/scout/verifier, bound via
`/tier` into `.model` and agent frontmatter, all still Claude Code.
**Routes** answer a different question: "should this slice leave Claude
Code's own model selection entirely and run headless under a different
tool, against a different provider". The two never share a name, a config
file, or a selection mechanism — `config/delegate-routes.json` and
`delegate run --route <route>` are a wholly separate surface from
`.model`/`/tier`.

That separation is deliberate, learned the hard way. Tiering's v1
(env-slot remap) tried to redefine what `"opus"`/`"sonnet"`/`"haiku"`
*meant* by rewriting `ANTHROPIC_DEFAULT_*_MODEL` underneath Claude Code's
own `/model` picker — a second, hidden namespace laid over names the
picker already owned, and it collided structurally (see
`knowledge-base/TIERED_ORCHESTRATION.md` § "Post-mortem: why v1 (env-slot
remap) was retired"). Routes avoid that mistake by construction: `glm` and
`local` are not aliases for any tier, are never written to `.model`, and
are invoked through their own CLI rather than by influencing what a tier
resolves to. A route and a tier can both be true of one job at once
(an `executor`-tier orchestrator dispatches a slice onto the `glm` route)
without either one meaning the other.

## Commands

```bash
delegate check
    # Per-route health table (route, status live|degraded, reason).
    # Always exits 0 — informational only, never a gate.

delegate run --route <route> (--bead <id> | --prompt <text> | --prompt-file <file>)
    # Dispatch one job. Exactly one of --bead/--prompt/--prompt-file.
    # --bead is refused on a scout-grade route (prompt-only there).
    # Unknown route or failed preflight -> loud error, nonzero exit,
    # no silent fallback to another route or model.

delegate ps
    # Lists .delegate/jobs/*: "running" (pid alive, no receipt.json yet)
    # vs "done" (receipt.json present). Never deletes or touches state.

delegate report
    # Per-route table: jobs, PASS/FAIL/TAMPERED counts (from delegated
    # beads' recorded verifier verdicts), delegated USD (lifetime ledger).
    # "no delegated beads yet" when both sources are empty. Exit 0 always.
```

Routes come from `config/delegate-routes.json` — name → `runner` (only
`opencode` is supported), `model` (`<provider>/<model-id>`), optional
`pin` (provider routing order/fallback policy), `grade` (`executor` or
`scout`). Override the path with `$DELEGATE_ROUTES` (tests only — never
point this at anything but a scratch config); override the repo `run`/`ps`
operate against with `$DELEGATE_REPO` (default `/workspace`).

## Receipt schema (`<job_dir>/receipt.json`)

Written by `cmd_run` after every job, success or failure:

| Field | Type | Notes |
|---|---|---|
| `job` | string | `<route>-<epoch>-<hex>`, also the job dir name and branch suffix |
| `route` | string | route name used |
| `model` | string | `<provider>/<model-id>` from the route |
| `bead` | string \| null | bead id for `--bead` dispatch, else `null` |
| `branch` | string | `delegate/<job>` |
| `tokens_in` / `tokens_out` | int \| null | from the opencode event stream's `usage`/`cost` event; `null` if the stream never carried one |
| `wall_seconds` | int | measured around the opencode invocation |
| `usd` | number \| null | provider-reported cost, verbatim; `null` if absent |
| `exit_code` | int | opencode's own exit code |
| `started_at` / `finished_at` | string | UTC `date -u +%Y-%m-%dT%H:%M:%SZ` |

## Job directory layout (`.delegate/jobs/<job>/`, gitignored)

```
worktree/                 ephemeral git worktree, branch delegate/<job>
config/opencode/opencode.json   route-scoped opencode config (own XDG_CONFIG_HOME)
home/                      job's own $HOME
pid                        opencode's pid while running (absent once done)
opencode.log               raw NDJSON event stream, secret-redacted after run
worktree-add.log           `git worktree add` output
receipt.json               schema above, secret-redacted after run
```

## Sandbox model

- **Scrubbed env**: `env -i` plus exactly `PATH`, `HOME` (the job's own),
  `XDG_CONFIG_HOME` (the job's own), `TERM=dumb`, and `OPENROUTER_API_KEY`
  only when the route's provider is `openrouter`. No `ANTHROPIC_*` var
  ever reaches the child process, by construction, not by denylist.
- **Key redaction**: `redact_secret()` does a literal (non-regex) replace
  of the route's key material in both `opencode.log` and `receipt.json`
  after the run, before either file is read again.
- **Worktree isolation**: `git worktree add <job_dir>/worktree -b
  delegate/<job> HEAD` — its own branch and working tree; the real repo's
  own `git worktree list` and current branch are untouched.
- **Merge-after-verify**: `delegate.sh` never merges. `--bead` jobs only
  append `delegated-to: <route>` / `branch:` / `receipt:` to the bead's
  notes — the branch sits until a native `verifier` PASS, at which point
  merging it in is a native, orchestrator-driven step, same as any other
  executor slice.

### Egress flags

Both default off; the egress firewall (`knowledge-base/EGRESS_FIREWALL.md`)
stays default-deny unless opted in:

- `CLAUDE_DEV_ALLOW_OPENROUTER=1` — allowlists `openrouter.ai:443` (needed
  for the `glm` route once the firewall is on).
- `CLAUDE_DEV_ALLOW_HOST_OLLAMA=1` — allowlists `host.docker.internal:11434`
  (needed for the `local` route once the firewall is on).

### `CLAUDE_DEV_ALLOW_API_BILLING` and `auth-guard.sh` — a different guard

`scripts/auth-guard.sh` (wired into `entrypoint.sh`) is orthogonal to
delegation: it FATALs container startup if `ANTHROPIC_BASE_URL`,
`ANTHROPIC_AUTH_TOKEN`, or `ANTHROPIC_API_KEY` are set — in the process
environment, or under the `.env` block of `~/.claude/settings.json` /
`settings.local.json` — because any of the three silently flips **Claude
Code's own billing** from subscription to API. `CLAUDE_DEV_ALLOW_API_BILLING=1`
downgrades the FATAL to a WARNING and lets startup continue. It does not
gate `OPENROUTER_API_KEY`: that key pays an external provider for a
delegate route's own model call, a deliberate and already-accounted-for
spend, never Claude Code's billing — the two guards protect different
money.

## Ledger integration

`cmd_run` best-effort ingests its own receipt into `cost-mirror`'s
lifetime ledger: `python3 scripts/cost-mirror.py --ingest-delegate-receipt
<job_dir>/receipt.json`, gated on the flag string existing in the file (so
an older `cost-mirror.py` degrades silently) and wrapped in `|| true` (a
ledger-write failure never fails the job). The ingested row lands in
`lifetime.json` with `side: "delegate"`, keyed by job id so a re-ingest of
the same receipt replaces rather than duplicates. `cost-mirror.py --report`
renders it as its own `delegated: <model> $X.XX (N job(s)) · ...` segment,
after the native side\|model table — a delegate job's dollars are a real
external bill, not tokens this file priced itself, so it is never blended
into the native table's actual/at-top/saved columns. State dir honors
`$COST_MIRROR_STATE_DIR` the same as every other `cost-mirror` entry
point.

## Troubleshooting (`delegate check` reasons)

| Reason | Cause | Fix |
|---|---|---|
| `opencode not found on PATH` | the `opencode` CLI isn't installed | install `opencode` and confirm `command -v opencode` |
| `OPENROUTER_API_KEY not set` | `glm` route, no key in the environment | export `OPENROUTER_API_KEY` |
| `egress blocked (flag off)` | firewall is default-deny (`-P OUTPUT DROP`) and `openrouter.ai` isn't in the applied rules | set `CLAUDE_DEV_ALLOW_OPENROUTER=1` and re-apply the firewall |
| `ollama unreachable` | `curl -sf -m 2 http://host.docker.internal:11434/api/version` failed | start Ollama on the host **and**, if the firewall is on, set `CLAUDE_DEV_ALLOW_HOST_OLLAMA=1` and re-apply — this same reason covers both causes, since the `local` route has no separate egress-blocked check the way `glm` does |

`delegate check` never blocks itself on a degraded route — it always exits
0; the loud, nonzero-exit failure happens only inside `delegate run` when
the *chosen* route's preflight fails.
