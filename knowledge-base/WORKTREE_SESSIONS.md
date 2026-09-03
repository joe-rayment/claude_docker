# Worktree Sessions — cs-new, the fleet menu, peers, and the sidebar

When to use: opening a side session in its own git worktree, managing
worktrees via the menu/prefix keys, or reading the peers line and fleet
sidebar. Implementation: `scripts/cs-new.sh`, `scripts/fleet-menu.sh`,
`scripts/peers.sh`, `scripts/session-title.sh`, `scripts/fleet.sh`,
`config/tmux.conf`. Plan: `.claude/plans/worktree-sessions.md`.

## Starting a side session

Right-click a pane and choose "New worktree session", press prefix+N, or
run `csn` / `cs-new [name]`. Each creates a git worktree at
`.claude/worktrees/<name>` (branched from HEAD) and opens a Claude Code
session there: a tmux window inside tmux, else the foreground. Omit
`<name>` for a unique generated `<adjective>-<noun>`; an explicit name
is rejected if already taken.

The launched session gets `BEADS_DIR=<repo-root>/.beads`: every side
session reads and writes the main tree's beads database directly.

`fleet-menu new` / prefix N runs `cs-new` synchronously with no output
overlay, landing at Claude's prompt. Trust is seeded from the root's own
`hasTrustDialogAccepted` entry in `~/.claude.json` (best effort — a
rewrite of that file first just shows the trust dialog once); an open
sidebar follows the new window either way.

On the first prompt, a hook renames the window to a kebab-case slug of
its first few words, once per session (tracked under
`~/.claude/cache/fleet/`).

## Peers

Every session prints one line naming other live Claude sessions on the
same tmux server — any pane running `claude`, or under a
`.claude/worktrees/` path: `[peers] you: <branch>@<window> · live:
<window> (<branch>), … · coordinate with SendMessage`, or a "no other
live sessions" variant. Never edit another session's worktree directly.

## Menu and keys

Right-click any pane, or press prefix+<key>, for: New worktree session
(N), Hide (H), Restore… (R), Jump… (J), Review… (V), Remove merged… (M),
Sidebar (S) — built by `fleet-menu.sh` from live tmux/git state.

- **Hide** breaks the current pane into its own background window,
  keeping its name — parked, reachable from the sidebar and Restore…/Jump….
- **Restore…** lists windows other than the current one and rejoins the
  chosen one with a horizontal split.
- **Jump…** lists every window with its pane's git branch and switches
  to the chosen one.
- **Review…** lists worktrees and opens a paged `git log` / `diff
  --stat` / coloured-diff popup against `main`.
- **Remove merged…** runs `git worktree remove` plus `git branch -d`
  for a worktree merged into `main`; refuses unmerged branches.

## Sidebar

Prefix+S or the menu's Sidebar item toggles a 34-column pane to the
left; toggling again closes it. Rows are the worktrees (main first)
then every other tmux window, so nothing on the server is unreachable.
`Up`/`Down` or `k`/`j` move the cursor; `Enter` or a left click goes to
that row's window (opening a session with `cs-new --open` first if a
worktree has none); `n` = new worktree session; `r` = refresh; `q` =
close. One sidebar per server: it follows whichever window becomes
current, within a tick. Frames redraw every 3s as one buffered write,
never a `clear`, so there's no flicker. Direct: `fleet --once` prints
it once; `fleet toggle [pane_id]` is what the menu/key calls.

Columns, after a header row: a `*` marker for live subagents, window,
branch, dirty file count, ahead/behind `main`, a one-letter lane code
(`e`/`s`/`d`/`-`), live agent count with role letters (`e`xecutor,
`s`cout, `v`erifier), and last-activity age. Lane and agent data come
from that worktree's own session transcript under
`~/.claude/projects/`. The main tree's three follow its most recently
active session.

## Testing

Every tmux-touching test runs against a scratch `tmux -L <socket>`
server, never the live one: `$TMUX` points at it explicitly,
`config/tmux.conf` loads into it, and teardown kills the server and its
socket file. See `tests/tmux-fleet.bats` and `tests/fleet.bats`.
