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
