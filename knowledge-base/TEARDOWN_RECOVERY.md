# Teardown and recovery

Two destructive commands, one snapshot mechanism between them.

## `claude-dev --teardown`

Removes **one project's** `claude_orca` artifacts: `<project>/.claude-dev/`
(sandbox home, tmp, state, generated `srt` settings, `srt-debug-*.log`,
delegate job dirs) and the project's registration on the host side. Your
code, your git history and `.beads/issues.jsonl` are untouched.

Before deleting anything, teardown takes a **beads snapshot**:

```
~/.claude-orca/state/<project>/<timestamp>/
```

`<project>` is the folder's slug, `<timestamp>` is UTC. The snapshot holds
`issues.jsonl` (the passive, git-tracked export) plus `metadata.json`, which
is what a rebuild actually needs — not the embedded Dolt directory, which is
disposable and rebuildable.

## `claude-dev --uninstall`

Removes the **host-side install**: `~/.claude-orca/{bin,template,srt}`, the
`shellrc.zsh` / `shellrc.bash` symlinks, and the marker-delimited lines from
`~/.zshrc` and `~/.bash_profile` (equivalent to `claude-dev rc-uninstall`,
which restores those files byte-for-byte). Project folders are left alone.

`~/.claude-orca/state/` — the snapshots — is **kept** by default, so
uninstalling and re-bootstrapping later still restores your issues. Delete
it by hand if you really want a clean slate.

Order matters if you want both: teardown each project first (so each gets a
snapshot), then uninstall.

## Restore

`claude-dev register <dir>` looks for the newest snapshot under
`~/.claude-orca/state/<project>/` and, when the project's beads database is
missing or empty, restores `issues.jsonl` and `metadata.json` before the
first session. The embedded Dolt database is then rebuilt from the JSONL by
`bd` on the next run:

```bash
cd <project> && bd init --prefix <p> --quiet --non-interactive && bd import
```

`<p>` is the project's issue prefix — everything before the final `-<suffix>`
of any existing issue id. See
[BEADS_TROUBLESHOOTING.md](BEADS_TROUBLESHOOTING.md) for the failure modes of
that pair (notably: if `bd init` refuses with "already initialized", remove
`.beads/embeddeddolt` first; `issues.jsonl` is a sibling file, not inside it).

## What is not backed up

- The embedded Dolt database (`.beads/embeddeddolt/`) — rebuildable.
- The sandbox `HOME` (`.claude-dev/home/`), including
  `.claude/.credentials.json`. **You log in again after a teardown.** That
  is deliberate: a credential file is not something to copy into a host-owned
  state directory.
- `settings.local.json`. It lives in the sandbox home, so a teardown takes
  your local overrides with it. Keep anything you care about in the
  template's `config/` instead, where it is version-controlled.
- Untracked working-tree files, delegate job branches, and anything else git
  does not know about — teardown does not touch them, but nothing snapshots
  them either.

## Recovering without the launcher

Every snapshot is plain files. If `claude-dev` itself is gone:

```bash
ls ~/.claude-orca/state/<project>/            # pick a timestamp
cp ~/.claude-orca/state/<project>/<ts>/issues.jsonl <project>/.beads/
cd <project> && bd init --prefix <p> --quiet --non-interactive && bd import
```

And to leave no trace at all, after that: `rm -rf ~/.claude-orca` plus the
marker-delimited block in `~/.zshrc` and `~/.bash_profile`.
