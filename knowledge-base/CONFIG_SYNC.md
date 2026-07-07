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
