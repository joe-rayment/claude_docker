# Config Sync and Local Overrides

How container configs are synced from the image, and how to keep customizations from being overwritten.

## Mechanism

On every container start, the entrypoint hashes the staged configs in `/etc/claude-dev/configs/` and compares against `/home/agent/.config-hash`. On mismatch (i.e. the image shipped new configs), it copies the staged files over the volume copies and writes the new hash:

- `~/.zshrc`
- `~/.config/helix/config.toml`
- `~/.config/intelli-shell/config.toml` and `defaults.txt`
- `~/.tmux.conf`
- `~/.claude/settings.json`, `~/.claude/statusline.sh`
- `~/.claude/agents/*.md` and `~/.claude/skills/`

Direct edits to these files survive restarts but are lost when the image config checksum changes (typically after `./claude-dev --update` or `--rebuild`).

## The four layers (and what updates when)

A config change is not "done" until you know which layers have it:

| # | Layer | Path examples | Updates when |
|---|-------|---------------|--------------|
| 1 | Repo (source of truth) | `config/`, `scripts/`, `tests/`, `knowledge-base/` | you edit + commit |
| 2 | Image-baked | `/etc/claude-dev/configs/`, `/opt/claude-dev/{tests,knowledge-base}/`, `/usr/local/bin/<script>` | **host `./claude-dev --rebuild` only** |
| 3 | Live volume | `~/.zshrc`, `~/.claude/settings.json`, `~/.claude/agents/*.md` | container start, only if layer-2 checksum changed |
| 4 | Local overrides | `~/.zshrc.local`, `~/.claude/settings.local.json` | merged over layer 3 every start; **local wins**; survives rebuilds |

When changing a setting "everywhere", check all four — especially layer 4: a stale
`settings.local.json` key silently re-wins the merge on every start (an old
`advisorModel` pin survived a template fix exactly this way). For immediate effect
without a rebuild, live-patch layer 2/3 yourself (`sudo cp scripts/x.sh
/usr/local/bin/x`, `cp config/agents/a.md ~/.claude/agents/`) — the next rebuild
converges them anyway.

## Verification trap: run-tests.sh tests the baked image

`run-tests.sh` defaults to `/opt/claude-dev/tests/` (layer 2). After editing repo
tests or configs, a green default run means nothing — the baked suite may predate
your tests entirely. Verify repo work with:

```bash
CLAUDE_DEV_TESTS=/workspace/tests run-tests.sh smoke
```

Tests asserting layer-2 paths stay red until the host rebuild — staleness, not
regression; never "fix" them by editing the assertions.

## Automated detection: image-drift

`/usr/local/bin/<tool>` is layer 2 (the image-baked copy); `scripts/<tool>`
in the repo is layer 1 (the source of truth). A `git commit` to a script
updates layer 1 immediately but layer 2 only on the next host-side
`./claude-dev --rebuild` — nothing enforced that gap before
beads_claude_docker-0v3, which caused three separate confusions in one
session (a hook crashing because the image predated it, `cost-mirror`
printing a stale output format, `run-tests.sh` silently resolving to the
image copy and running 6 suites instead of 8).

`scripts/image-drift.py` is a SessionStart hook that hashes every script
named in a Dockerfile `COPY ... /usr/local/bin/<dest>` line (mapping
derived from the Dockerfile, never hardcoded — via `copy_entries()`, which
`scripts/image-drift.py` owns and `tests/helpers/hook-staging-check.py`'s
sibling "missing COPY" check imports FROM it, not the reverse: a
production script staged into the image must never depend on `tests/`
being present) against its staged counterpart. Silent when everything matches;
one line naming every drifted script otherwise, e.g.:

```
image-drift: staged /usr/local/bin copies are stale vs repo (cost-mirror, run-tests.sh) — run ./claude-dev --rebuild on the host
```

It fails open always (no Dockerfile, no repo, unreadable file — silent,
exit 0) and only fires inside the template repo itself: the positive
marker is the Dockerfile referencing `/opt/claude-dev` (the template's own
staging root), not mere presence of a `scripts/` + `Dockerfile` pair — an
unrelated project can easily have both (a scratch project with its own
`Dockerfile` and `scripts/` produced a spurious "staged copies are stale"
hit before this marker was added, beads_claude_docker-0v3 blocker 2). The
hook registration in `claude-settings.json`
prefers the **repo** copy of the checker over the staged one (resolved via
`git rev-parse --show-toplevel`) — the checker is itself a staged script,
so running the possibly-stale staged copy to detect staleness would be
circular.

Seeing the message means: the repo has diverged from what is actually
running in this container. Run a host-side `./claude-dev --rebuild`, or
live-patch the specific file (`sudo cp scripts/x.sh /usr/local/bin/x`) to
unblock immediately.

## Gotcha: the live settings.json diverges — and the session writes to it

`~/.claude/settings.json` (layer 3) is only re-copied when the layer-2 checksum
changes, so a container provisioned from an old image keeps old keys, hooks, and
plugins indefinitely — the template being clean does not mean the container is.
Also, a *running* Claude session re-persists some keys (e.g. its active `agent`)
back into `settings.json` on exit: an edit made mid-session can reappear. Re-check
after the session ends.

## Persisting customizations

| Config | Override file | Mechanism |
|--------|--------------|-----------|
| Shell | `~/.zshrc.local` | Sourced at end of `.zshrc` |
| Claude Code | `~/.claude/settings.local.json` | Merged into `settings.json` after each sync |

## settings.local.json merge semantics

- Objects deep-merge; on key conflict, local wins.
- `permissions.allow` / `permissions.deny` / `permissions.ask` arrays are **unioned** with the base lists (local entries extend, never wipe, the base allowlist).
- Any other array is replaced wholesale by the local value.
- Invalid JSON in the local file: the entrypoint prints a warning and skips the merge — `settings.json` is never corrupted, but your overrides are not applied until you fix the file and restart.

## Recovery

| Symptom | Fix |
|---------|-----|
| `settings.json` invalid (entrypoint warns) | `jq empty ~/.claude/settings.json` to locate the error, fix or delete the file, restart — sync re-copies the base |
| Overrides not applied | `jq empty ~/.claude/settings.local.json` — invalid JSON skips the merge |
| Config stuck on old version | `rm ~/.config-hash` and restart the container to force a full re-sync |

## Confirming a rebuild actually happened

Use PID 1's start time, not `uptime -s`: `uptime -s` reports the **host**
kernel's boot time, which is shared across every container on that host and
looks unchanged across a plain container restart — it tells you nothing
about whether *this* container was rebuilt. `ps` on PID 1 (the container's
own init) is the container-relevant clock:

```bash
ps -o pid,lstart,etime,cmd -p 1          # container init start time
uptime -s                                # host kernel boot time — do NOT use this for rebuild evidence
```

Verified 2026-07-31 in this container: `ps -p 1` reports `Wed Jul 29
07:45:23 2026`; `uptime -s` reports `2026-07-29 01:40:25` — they diverge,
confirming these are two different clocks. Compare PID 1's `lstart`
against the mtimes of files under `/etc/claude-dev/configs`
(`ls -la --time-style=full-iso /etc/claude-dev/configs`): init starting
**after** those mtimes is real rebuild evidence; init starting before them
(or `uptime -s` alone) is not. Recorded after a session wrongly declared a
rebuild had not happened based on a stable `uptime -s`.

## Renaming a scripts/*.sh file requires updating its Dockerfile COPY line

Scripts install to bare names in `/usr/local/bin/` via one `COPY
--chown=agent:agent scripts/<file> /usr/local/bin/<dest>` line per script,
and every runtime reference — shell aliases, tests, the entrypoint,
docs, `settings.json` permission entries — uses the **installed** name,
not the repo filename. Renaming a script therefore touches exactly one
Dockerfile line in addition to the rename itself; skipping it breaks the
image build (the old `COPY` source no longer exists) on the next rebuild.

Find the current line with a grep anchor, not an absolute line number —
line numbers drift silently as the Dockerfile grows. Verified 2026-07-31:
a previously-recorded citation of `Dockerfile:170` had already drifted to
line 178 by the time of this check.

```bash
grep -n "COPY --chown=agent:agent scripts/" Dockerfile
```

## Self-modification blocks when live-syncing config

The permission classifier blocks an agent from live-editing its own
startup config, even when the content being copied is verbatim template
material the user asked to sync. Agent-file copies into
`~/.claude/agents/` and shell-function injection into `~/.zshrc` clear
with one round of explicit per-action user authorization; edits that add
hooks to a **live** `~/.claude/settings.json` stay blocked even then,
because hooks in that file auto-execute at every session start. Do not
retry a blocked self-modification with a workaround (e.g. a wrapper
script) — surface the block and let the user decide how to proceed.
