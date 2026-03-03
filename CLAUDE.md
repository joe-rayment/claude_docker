# CLAUDE.md — Claude Code Development Container

## Environment

You are running inside a Docker container. Your workspace is at `/workspace` (bind-mounted from the host). Your home directory `/home/agent` is a persistent Docker volume — auth, git config, and shell history survive rebuilds.

Key tools: Git, GitHub CLI (`gh`), Python 3, Node.js, Go, Helix editor (`hx`), tmux.

## Core Principle

**Run code, don't guess.** Execute commands, run tests, check output. If you're unsure whether something works, run it.

## Logging

Use `dev-log` to record what happens during your session. Logs live at `/workspace/.claude/logs/`.

### Categories

| Command | When to use |
|---------|-------------|
| `dev-log run "cmd" pass\|fail "reason" ["detail"]` | After running a command (tests, builds, deploys) |
| `dev-log decision "description"` | When choosing between approaches |
| `dev-log error "what" ["detail"]` | When something fails unexpectedly |
| `dev-log change "what" "why"` | After modifying code or config |
| `dev-log show [category] [N]` | View recent entries |

### Rules

- Log every test run, build, and deploy — pass or fail.
- Log decisions that affect architecture, dependencies, or approach.
- Log errors with enough detail to diagnose later.
- Log changes that aren't obvious from the diff.
- Read logs at session start: `dev-log show` — understand what happened before you.
- Don't log trivial reads or explorations.

### Log Files

```
/workspace/.claude/logs/
├── runs.log        # Command executions and outcomes
├── decisions.log   # Architectural and design decisions
├── errors.log      # Failures and root causes
└── changes.log     # What changed and why
```

## Attachments

Drop files (screenshots, images, reference docs) into `/workspace/attachments/` to make them accessible inside the container. This directory is gitignored.

## Screenshots

Capture screenshots from inside the container using `take-screenshot` (aliases: `screenshot`, `ss`). Screenshots save to `/workspace/attachments/` by default. Claude can view saved screenshots using its Read tool.

| Command | What it captures |
|---------|-----------------|
| `take-screenshot url <URL>` | Web page via Playwright |
| `take-screenshot url --full-page <URL>` | Full scrollable page |
| `take-screenshot url --device "iPhone 11" <URL>` | Mobile emulation |
| `take-screenshot display` | X11 display (Xvfb) |
| `take-screenshot term "<command>"` | Terminal command output via termshot |

The Playwright MCP server is also available for deeper browser interaction (navigation, clicking, form filling).

## Cleanup

Periodically clean up ephemeral files that accumulate during development:

- `/workspace/attachments/` — Delete old screenshots and reference files
- `/workspace/.claude/plans/` — Remove completed or obsolete plan files
- `/workspace/.claude/logs/` — Logs are gitignored; clear if they grow large

## Agent Teams

Agent teams are enabled via `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and `teammateMode: "tmux"` in settings. Claude Code manages tmux panes automatically — you do not need to configure tmux manually.

### How It Works

- Use **Shift+Tab** to enter delegate mode. This keeps the team lead focused on coordination while teammates do the work.
- Claude Code spawns teammates in separate tmux panes automatically.
- Each teammate has its own context and tools.
- The team lead assigns tasks and reviews results.

### Teammate Guidelines

- Read `dev-log show` at the start to understand prior context.
- Log your work using `dev-log` as you go.
- Run tests before reporting completion.
- If blocked, log the blocker with `dev-log error` and report to the team lead.

## Beads (Agent Memory)

This environment uses [Beads](https://github.com/steveyegge/beads) (`bd`) for persistent task tracking across sessions. Beads uses a Dolt SQL server for database operations. The server starts automatically via `start-dolt` during container startup.

- **JSONL files** in `/workspace/.beads/` are git-tracked (task history survives across machines).
- **Dolt server data** lives at `/home/agent/.dolt-data/` (Docker volume, survives rebuilds).
- If the Dolt server isn't running, use `start-dolt` to start it.

### Self-Healing

Beads includes automatic database repair. If the `.beads/` config directory is git-tracked but the Dolt database hasn't been created in this container's volume (common when cloning a project from a template), the system detects the problem via `bd status` and attempts repair using `bd doctor --fix --yes`. This runs at three points:

1. **Container startup** (entrypoint) — silent, logged via `dev-log`
2. **Welcome screen** — silent, retries status display after repair
3. **Menu option 3** — user-visible "Repairing..." message with success/failure feedback

To manually repair: `cd /workspace && bd doctor --fix --yes`

### Session Start

Run `bd ready` to see tasks with no open blockers. If there are existing tasks, review them before starting new work.

### Key Commands

| Command | Purpose |
|---------|---------|
| `bd ready` | Show tasks with no blockers (start here) |
| `bd create "Title" -p 0` | Create a task (P0=critical, P3=low) |
| `bd update <id> --claim` | Claim a task and mark in-progress |
| `bd show <id>` | View task details and history |
| `bd close <id>` | Mark a task as done |
| `bd list` | List all issues |
| `start-dolt` | Start the Dolt server (if not running) |

### Claude Code Integration

Beads hooks inject workflow context automatically:
- **SessionStart** runs `bd prime` to load beads awareness into new sessions
- **PreCompact** runs `bd prime` to preserve context before compaction

These are managed by `bd setup claude` and configured during container startup.
Verify with: `bd setup claude --check`

### Workflow Rules

- Use `bd update` with flags to modify issues. Never use `bd edit` (it opens an editor).
- Include issue IDs in commit messages when relevant: `Fix auth bug (bd-a3f2)`.
- When discovering new work during a task, create a new bead with `bd create`.

## Knowledge Base

Curated reference docs for common issues live in `/opt/claude-dev/knowledge-base/`. When you encounter problems with a technology (deployment failures, configuration issues, environment-specific bugs), check this directory for relevant guides before searching the web. These are proven solutions to issues that come up repeatedly.

## Experience Testing

Run `run-tests.sh` inside the container to verify the environment works correctly. Tests cover:

- **Smoke tests**: Scripts present, binaries installed, configs valid.
- **Experience tests**: Welcome screen renders, menus navigate correctly, invalid input handled.

Run tests after making changes to container setup, entrypoint, or menu scripts.

```bash
run-tests.sh          # Run all tests
run-tests.sh smoke    # Smoke tests only
run-tests.sh experience  # Experience tests only
```

## Session Checklist

### Start
1. Read recent logs: `dev-log show`
2. Check git status: `gs` (alias for `git status`)
3. Understand the current task before writing code.

### End
1. Ensure all changes are logged.
2. Run tests if you made code changes.
3. Session logs are auto-exported on Claude exit (via hook).

## Quick Reference

| Shortcut | Command |
|----------|---------|
| `cs` | `claude --dangerously-skip-permissions` |
| `csd` | `claude --dangerously-skip-permissions --debug` |
| `menu` | Setup/options menu |
| `dlog` | `dev-log` |
| `gs` | `git status` |
| `cn` | `claude` (normal mode) |
| `hx` / `vim` | Helix editor |
| `view-logs` | Interactive Claude log viewer |
| `clog-latest` | View latest Claude debug log |
| `clog-export` | Export latest log to workspace |
| `screenshot` / `ss` | `take-screenshot` |
