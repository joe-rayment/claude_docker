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
