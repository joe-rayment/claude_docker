# Teardown and recovery

Two destructive commands, one snapshot mechanism between them.

## `claude-dev --teardown`

The install **is** the folder now, so teardown removes it whole:

- `<project>/.claude-dev/` — the template clone, `srt`, Claude Code,
  `app/Orca.app`, `bin/`, the sandbox `home` and `tmp`, `state/`, `run/`,
  `sandbox.json`, delegate job dirs.
- `<project>/claude-dev` — the launcher stub in the project root.
- `<project>/Orca.app` — the generated launcher bundle, and only ours: it
  is identified by the bundle id `dev.onorca.sandboxed.<slug>`, so a real
  Orca you happen to keep in the folder is left alone.
- The lines `claude-dev register` seeded into `.gitignore`, and nothing
  else in that file. Your own patterns come back byte-identical, marker
  block included.

Your code, your git history and `.beads/` are untouched. `--purge-beads`
removes `.beads/` as well, and says so.

Before deleting anything, teardown takes a **beads snapshot**:

```
<project>/.claude-dev-snapshots/<timestamp>/
```

`<timestamp>` is a local-time `YYYYMMDD-HHMMSS` stamp. The snapshot holds
`issues.jsonl` (the passive, git-tracked export) plus `metadata.json`, which
is what a rebuild actually needs — not the embedded database directory,
which is disposable and rebuildable.

**Why beside the folder rather than inside it.** In v2 there is no central
install and nothing outside the project to put state in, so the snapshot
directory is a *sibling* of `.claude-dev`, not a child: teardown deletes
`.claude-dev` whole, and anything inside it would go with it. Being in the
project also means the snapshots move, copy and back up with the project.
They are gitignored while the project is registered; teardown removes that seeded ignore line with the others, so re-run the bootstrap (or ignore the directory yourself) before committing after a teardown.

## `claude-dev --uninstall`

Teardown, plus everything this template put outside the folder:

- the marker-delimited block in `~/.zprofile`, `~/.zshrc` and
  `~/.bash_profile` (equivalent to `claude-dev rc-uninstall`, which restores
  those files byte-for-byte);
- a pre-v2 central install at `~/.claude-orca`, if this machine still has
  one. The path is **printed before it is removed** — the one thing this
  command deletes outside the project is always named on the way past.
  `claude-dev --remove-v1` does that part alone, for a machine with no
  bootstrapped folder left to run `--uninstall` from.

It refuses to run unless the launcher it was invoked through really lives in
a `<project>/.claude-dev` install: `rm -rf` is not the place to guess.

**Snapshots survive an uninstall**, because they sit beside `.claude-dev`
rather than inside it. Nothing in this command touches
`.claude-dev-snapshots/`, your code, or your git history.

## Restore

A teardown takes the launcher with it, so coming back means re-running the
bootstrap one-liner from inside the folder. Its last step is
`claude-dev register`, which looks for the newest directory under
`<project>/.claude-dev-snapshots/` and restores `issues.jsonl` and
`metadata.json` from it — **only when the project has none of its own**.
That case is unambiguous: there is nothing there to lose. A project that
still carries beads data keeps it, and is never overwritten with a possibly
older snapshot.

The embedded database is then rebuilt from the JSONL by `bd` on the next
run:

```bash
cd <project> && bd init --prefix <p> --quiet --non-interactive && bd import
```

`<p>` is the project's issue prefix — everything before the final `-<suffix>`
of any existing issue id. See
[BEADS_TROUBLESHOOTING.md](BEADS_TROUBLESHOOTING.md) for the failure modes of
that pair (notably: if `bd init` refuses with "already initialized", remove
`.beads/embeddeddolt` first; `issues.jsonl` is a sibling file, not inside it).

## What is not backed up

- The embedded database (`.beads/embeddeddolt/`) — rebuildable.
- The sandbox `HOME` (`.claude-dev/home/`), including
  `.claude/.credentials.json`. **You log in again after a teardown.** That
  is deliberate: with the Keychain cut, the credential file is the whole
  credential store, and it is meant to live and die with the folder.
- `settings.local.json`. It lives in the sandbox home, so a teardown takes
  your local overrides with it. Keep anything you care about in the
  template's `config/` instead, where it is version-controlled.
- Untracked working-tree files, delegate job branches, and anything else git
  does not know about — teardown does not touch them, but nothing snapshots
  them either.

## Recovering without the launcher

Every snapshot is plain files. If `.claude-dev` is already gone:

```bash
ls <project>/.claude-dev-snapshots/                       # pick a timestamp
cp <project>/.claude-dev-snapshots/<ts>/issues.jsonl <project>/.beads/
cd <project> && bd init --prefix <p> --quiet --non-interactive && bd import
```

And to leave no trace at all, after that: delete
`<project>/.claude-dev-snapshots/` and the marker-delimited block in
`~/.zprofile`, `~/.zshrc` and `~/.bash_profile`.
