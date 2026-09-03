# Plan: fleet navigation — sidebar drives, toolbar goes, New session lands

Filed 2026-09-03. Lane: deep. Supersedes the UX decisions of `worktree-sessions.md` (F2/F4b) after one day of real use.

## What is wrong (root causes, verified live on a scratch `tmux -L` server)

1. **Top toolbar** (`config/tmux.conf:9-17`, F2): the status bar was added so hidden windows stay visible. In use it is a row of `N:name` tabs the user does not use; it steals a row from Claude's TUI. Verdict: remove; the sidebar and the Jump…/Restore… menus cover the same ground.
2. **Sidebar is display-only** (`scripts/fleet.sh:391-397`, F4/F4b): `fleet --watch` is an output loop with no stdin handling, and the pane it opens belongs to one window — jumping elsewhere leaves it behind. Clicking a row does nothing because nothing reads the click.
3. **Blink every 3 s** (`scripts/fleet.sh:393`): the loop runs `clear`, then spends the next few hundred ms in git/tmux/jq subprocesses before the new frame is complete, so the pane is blank between the two. There is no diffing and the frame is written line by line.
4. **"New worktree session" opens to a stuck message** (`scripts/fleet-menu.sh:302-307` → `scripts/cs-new.sh:100-112`): `cmd_new` runs `tmux run-shell -b -c "$root" cs-new` — a nested, target-less, backgrounded run-shell. cs-new's captured output (git's `Preparing worktree… / HEAD is now at <sha> <subject>` plus `cs-new: name -> path`) is shown by tmux, at job completion, as a view-mode overlay on whatever pane is current *then* — which is the freshly created Claude pane (`pane_in_mode=1`, reproduced). Under the overlay, Claude is sitting on its folder-trust dialog: trust is per exact path and is **not** inherited by `.claude/worktrees/<name>` from the trusted root (probed: `/workspace` trusted, worktree under it still prompts), and the dialog's default answer is "No, exit", which closes the window.

## Decisions

- **Status bar off.** `set -g status off`; the right-click menu and prefix keys stay exactly as they are. Parked ("hidden") windows are reachable from the sidebar (which now lists every window) and from Restore…/Jump….
- **The sidebar is the navigator and it travels.** One sidebar pane per server (`@fleet_sidebar`), 34 columns, on the left. `fleet go <row>` moves it into the target window (`join-pane -d -hb -l 34`) and selects the target pane; `fleet follow` (called every tick, by cs-new and by the menu) does the same for whatever window became current by other means. Toggle: close if it is here, bring it here if it is elsewhere, open if there is none.
- **Rows = worktrees, then windows.** main + each `.claude/worktrees/*` as today; then one row per tmux window not already represented, so nothing on the server is unreachable once the status bar is gone. Machine-readable twin `fleet rows` (display line + kind/name/path/window/pane) is what the interactive loop and the tests consume; `fleet --once` keeps its header + rows shape.
- **Flicker-free frames.** Build the whole frame in a variable; write it once as `ESC[H` + one `ESC[K`-terminated line per row + `ESC[J`. Never `clear`. `FLEET_MAX_TICKS` ends the loop for tests.
- **Interaction in bash, in-pane.** Raw tty + SGR mouse tracking (tmux forwards clicks with `send-keys -M` once the pane asks for them). ↑/↓ or k/j move the cursor; Enter or left-click = go (jump to the row's window, or open a session in a worktree that has none); `n` = new worktree session; `r` = refresh now; `q` = close; wheel moves the cursor. Footer shows the keys. No Python, no fzf (not installed): the surface is small and the tests already drive scratch tmux panes with `send-keys`.
- **Opening a session in an existing worktree** reuses cs-new's launch line: `cs-new --open <name>` (no worktree creation). One launch command, `CS_NEW_LAUNCH` still substitutes it for tests.
- **New session lands at the prompt.** `fleet-menu new` runs cs-new synchronously and swallows its stdout (failure → `display-message`), so no run-shell overlay anywhere. cs-new seeds folder trust for the worktree path by copying the root's own `hasTrustDialogAccepted: true` entry in `~/.claude.json` (jq, temp+rename; skipped silently if the file/key is absent) — the same code the user already trusted, one directory deeper — then calls `fleet follow`.
- **Live apply at the end:** copy the scripts to `/usr/local/bin`, `config/tmux.conf` to `~/.tmux.conf`, `tmux source-file` on the live server; the baked copies wait for `./claude-dev --rebuild` (image-drift already reports the staging as stale).

## Slices (sequential; each red-commit-first; each closes on a viewed screenshot)

G1 `fleet` core: rows / go / follow / toggle-anywhere / buffered frame / window rows / `cs-new --open` ·
G2 `fleet-menu new` lands: synchronous cs-new, no overlay, trust seed, follow ·
G3 sidebar interaction: cursor, keys, mouse, footer ·
G4 status bar off, docs (WORKTREE_SESSIONS.md, CLAUDE.md row), tests re-pinned, screenshots.

Not in scope: dd3o (jump --print flake) stays open; the context menu's item list is unchanged; Orca.
