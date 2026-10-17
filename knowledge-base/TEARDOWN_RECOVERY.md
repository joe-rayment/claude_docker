# Teardown and recovery

One destructive command, and the snapshot mechanism that makes it safe.

## `claude-dev --teardown`

The install **is** the folder now, so teardown removes it whole:

- The folder's ssh master connection on the Mac (`ssh -O exit`). It is a
  process, not a file, so it would otherwise outlive the folder it points at.
  The clipboard listener (the small server behind the paste bridge) is
  stopped too.
- The folder's container, stopped and removed, plus its scratch volumes
  (`.cache`, `.npm`, `.local/share/opencode`, `worktrees`) — everything
  that matters lives in the mounted folder, never in the container.
- `<project>/.claude-dev/` — the template clone, `bin/`, the agent `home`,
  `state/`, `run/`, `claude-orca.json`, delegate job dirs. `state/ssh` is
  the part that holds the folder's identity: the key pair that logs in to
  the container's sshd, its `known_hosts`, and the ssh config the Ghostty
  panes use. There is no other state volume; the folder is its own
  authority.
- `<project>/claude-dev` — the launcher stub in the project root.
- The marker-delimited block in `~/.zprofile`, `~/.zshrc` and
  `~/.bash_profile`, if a folder upgraded from v2 still carries one. v3
  installs no shell hook; teardown only cleans up after the old one.
- Leftovers from the old browser-based setup, if the folder ever had them:
  `<project>/.orca-worktrees/` (removed through `git worktree remove`
  first, so git's own bookkeeping stays sane) and `<project>/.orca/`, plus
  a volume named `<container>-orca-state`.
- The lines `claude-dev register` seeded into `.gitignore`, and nothing
  else in that file. Your own patterns come back byte-identical, marker
  block included.
- The folder's `.git`, but only if claude-orca created it: it is the
  repository's top level, has exactly one root commit, and that commit's
  subject starts with `claude_orca: seed commit`. Anything else keeps its
  `.git`, and teardown prints one line saying why.

Your code, your git history and `.beads/` are untouched. `--purge-beads`
removes `.beads/` as well, and says so.

`./claude-dev --update` is the gentler sibling: it recreates the container
from the current image and keeps the folder, the keys and the scratch
volumes. It also creates the ssh keys if the folder predates the ssh panes,
and removes an old `<container>-orca-state` volume if one is still lying
around (it prints a line when it does).

Before deleting anything, teardown takes a **beads snapshot**:

```
<project>/.claude-dev-snapshots/<timestamp>/
```

`<timestamp>` is a local-time `YYYYMMDD-HHMMSS` stamp. The snapshot holds
`issues.jsonl` (the passive, git-tracked export) plus `metadata.json`, which
is what a rebuild actually needs — not the embedded database directory,
which is disposable and rebuildable.

**Why beside the folder rather than inside it.** There is no central
install and nothing outside the project to put state in, so the snapshot
directory is a *sibling* of `.claude-dev`, not a child: teardown deletes
`.claude-dev` whole, and anything inside it would go with it. Being in the
project also means the snapshots move, copy and back up with the project.
They are gitignored while the project is registered; teardown removes that seeded ignore line with the others, so re-run the bootstrap (or ignore the directory yourself) before committing after a teardown.

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
- The agent `HOME` (`.claude-dev/home/`), including
  `.claude/.credentials.json`. **You log in again after a teardown.** That
  is deliberate: the credential file is the whole credential store, and it
  is meant to live and die with the folder.
- The ssh keys in `.claude-dev/state/ssh`. A re-run of the bootstrap makes
  a fresh pair; nothing outside the folder trusted the old one.
- `settings.local.json`. It lives in the agent home, so a teardown takes
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
`<project>/.claude-dev-snapshots/`, and remove the folder's container if the
launcher never got to it (`docker rm -f claude-orca-<project-slug>`). A
leftover ssh master needs no action: it closes itself 30 minutes after its
last pane (`ControlPersist 30m`).
