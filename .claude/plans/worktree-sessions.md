# Plan: worktree-per-session, tmux ergonomics, peers, sidebar

Filed 2026-09-03. Lane: deep. Status: filed — executing.

## Goal
Side sessions stop stepping on each other, can be opened from the right-click menu with no name to think up, can be hidden and brought back without the mouse, announce each other at session start, and (if it proves usable) show up in a live sidebar. Nothing leaves the mounted folder: worktrees live under `/workspace/.claude/worktrees/`.

## Decisions
- **`cs-new [name]`** creates the worktree itself (`git worktree add .claude/worktrees/<name> -b <name>` from the main tree's HEAD) and launches `claude --dangerously-skip-permissions -n <name>` in a new tmux window of the current server with cwd = the worktree. No `claude -w`: creating it ourselves makes the launcher testable (`CS_NEW_LAUNCH` substitutes the command) and independent of `worktree.baseRef`. Auto-name = `<adjective>-<noun>` from a built-in word list, unique against existing worktrees and windows; an explicit name still wins.
- **Shared tracker**: the launched session gets `BEADS_DIR=<root>/.beads`, so every side session reads and writes the main tree's beads and nothing is exported into the worktree.
- **Readable names**: a UserPromptSubmit hook renames the tmux window on a session's first prompt to a ≤24-char slug of that prompt (`fix-login-redirect`); the worktree keeps its generated name, and the sidebar and peers line show both. State per session under `~/.claude/cache/fleet/`.
- **Menu, not fzf**: one script, `fleet-menu.sh`, builds `tmux display-menu` lists dynamically (windows, hidden windows, worktrees) for New / Hide / Restore… / Jump… / Review… / Remove merged…; the same actions get prefix keybindings. Status bar on, at the top, so parked windows are visible.
- **Peers**: a SessionStart hook lists the other live Claude panes (branch, window) in one line; the rulebook gains one sentence: other live sessions are peers in their own worktrees, coordinated by SendMessage, never by editing their files.
- **Sidebar** (`fleet`): a left pane refreshing every 3 s — window · branch · dirty · ahead/behind main · lane · live agents · last activity — mapping worktree → `~/.claude/projects/<slug>/` for the session id, lane state and subagent sidecars. Toggle from the menu or prefix+S. Ships only if the orchestrator judges the screenshots usable; otherwise it stays an opt-in command, not wired into the menu.
- **Orca**: captured in `knowledge-base/ORCA_SANDBOXED.md` for later; not implemented.
- Tests never touch the live tmux server: every tmux test runs on `tmux -L <scratch>`.

## Slices
F1 beads_claude_docker-nmnb cs-new · F2 beads_claude_docker-f5i6 tmux menu/status/keys (+ review, remove-merged) · F3 beads_claude_docker-7bam peers hook + first-prompt title hook + rulebook sentence · F4 beads_claude_docker-1tym fleet sidebar + usability screenshots · F5 beads_claude_docker-l4z6 docs (WORKTREE_SESSIONS.md, ORCA_SANDBOXED.md, README index, CLAUDE.md quick reference). Sequence F1 → F2 → F3 → F4 → F5. UX slices (F2, F4) close on viewed screenshots.
