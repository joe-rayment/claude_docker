# Worktree Sessions — cs-new, the fleet menu, peers, and the sidebar

When to use: opening a side session in its own git worktree, using the
menu or prefix keys to manage worktrees, or reading the peers line and
fleet sidebar. Implementation: `scripts/cs-new.sh`,
`scripts/fleet-menu.sh`, `scripts/peers.sh`, `scripts/session-title.sh`,
`scripts/fleet.sh`, `config/tmux.conf`. Plan:
`.claude/plans/worktree-sessions.md`.

## Starting a side session

Right-click a pane and choose "New worktree session", press prefix+N, or
run `csn` (a `.zshrc` alias) / `cs-new [name]`. Each creates a git
worktree at `.claude/worktrees/<name>` (branched from HEAD) and opens a
Claude Code session there: a tmux window inside tmux, else the
foreground. Omit `<name>` for a unique generated `<adjective>-<noun>`,
checked against existing worktree dirs and (inside tmux) window names;
an explicit name is rejected if already taken.

The launched session gets `BEADS_DIR=<repo-root>/.beads`, so every side
session reads and writes the main tree's beads database directly —
nothing is exported into the worktree.

On the first prompt, a hook renames the tmux window to a kebab-case slug
of its first four meaningful words (stop words like "a/the/to/of"
dropped, capped at 24 chars), so the window reads as what it's doing
rather than the generated name. It fires once per session, tracked under
`~/.claude/cache/fleet/`.

## Peers

Every session prints one line naming the other live Claude sessions on
the same tmux server — any pane running `claude`, or whose path is under
a `.claude/worktrees/` directory:
`[peers] you: <branch>@<window> · live: <window> (<branch>), … ·
coordinate with SendMessage, not by editing their files`, or a "no other
live sessions" variant. Coordinate with peers by SendMessage; never edit
another session's worktree directly.

## Menu and keys

Right-click any pane, or press prefix+<key>, for: New worktree session
(N), Hide (H), Restore… (R), Jump… (J), Review… (V), Remove merged… (M),
Sidebar (S). All seven are built by `fleet-menu.sh` from live tmux/git
state, so the choices always match what exists.

- **Hide** breaks the current pane into its own background window,
  keeping its name, so it stays visible but parked in the status bar —
  on and pinned to the top so Claude Code's TUI keeps the bottom row.
- **Restore…** lists windows other than the current one and rejoins the
  chosen one with a horizontal split.
- **Jump…** lists every window with the git branch of its pane, and
  switches to the chosen one.
- **Review…** lists worktrees under `.claude/worktrees/` and opens a
  paged `git log` / `diff --stat` / coloured-diff popup against `main`.
- **Remove merged…** lists worktrees whose branch is merged into `main`
  and, on selection, runs `git worktree remove` plus `git branch -d`;
  refuses unmerged branches — the normal cleanup once work lands.

## Sidebar

Prefix+S or the menu's Sidebar item toggles a 34-column pane to the left
running `fleet --watch` (redraws every 3s); toggling again closes it.
Direct: `fleet --once` prints it once; `fleet toggle [pane_id]` is what
the menu/key calls. Columns, after a header row: a leading `*` marker
when a worktree has live subagents (blank otherwise), window, branch,
dirty file count, ahead/behind `main`, a one-letter lane code
(`e`/`s`/`d`/`-`), live agent count with role letters (`e`xecutor,
`s`cout, `v`erifier), and last-activity age. Lane and agent data come
from that worktree's own session transcript under `~/.claude/projects/`,
not this repo.

## Testing

Every tmux-touching test runs against a scratch `tmux -L <socket>`
server, never the live one: `$TMUX` is pointed at that socket
explicitly, `config/tmux.conf` is loaded into it, and teardown kills the
server and its socket file. See `tests/tmux-fleet.bats` and
`tests/fleet.bats`.
