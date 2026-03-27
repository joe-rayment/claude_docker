# CLAUDE.md — Claude Code Development Container

## Environment

You are running inside a Docker container. Your workspace is at `/workspace` (bind-mounted from the host). Your home directory `/home/agent` is a persistent Docker volume — auth, git config, and shell history survive rebuilds.

Key tools: Git, GitHub CLI (`gh`), Python 3, Node.js, Go, Helix editor (`hx`).

## Config Customization

Config files are synced from the Docker image on startup (checksum-based). To persist personal customizations across rebuilds, use `.local` override files:

| Config | Override file | Mechanism |
|--------|--------------|-----------|
| Shell | `~/.zshrc.local` | Sourced at end of `.zshrc` |
| Claude Code | `~/.claude/settings.local.json` | Deep-merged into `settings.json` on startup |

Helix (`~/.config/helix/config.toml`) and IntelliShell (`~/.config/intelli-shell/config.toml`) can be edited directly — they only get overwritten when the image config checksum changes.

## Core Principle

**Run code, don't guess.** Execute commands, run tests, check output. If you're unsure whether something works, run it.

## Verification

**Always verify changes by running the actual application.** Do not report work as complete based on code inspection alone.

### Rules

- When a feature is added or changed, **run the app and check it works** — start the server, open the page, hit the endpoint.
- Use `take-screenshot url <URL>` or the Playwright MCP server to capture visual proof of UI changes.
- Use `curl`, `httpie`, or similar tools to verify API behavior. Install tools if needed (`apt-get install`, `pip install`, `npm install`).
- **Code-based tests (unit, integration) are for regression protection**, not for verifying current work. Run them to confirm you haven't broken other things.
- Before reporting a task as done, ask yourself: "Did I actually see this working?" If not, go verify.
- For CLI tools, run them and capture output with `take-screenshot term "<command>"`.
- For web UIs, take before/after screenshots to show the change.

### Verification Checklist

Before marking work complete, confirm at least one:

- [ ] Ran the application and observed correct behavior
- [ ] Took a screenshot showing the feature works
- [ ] Executed the endpoint/command and got expected output
- [ ] Opened it in a browser (Playwright MCP) and verified visually

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

## Drag-and-Drop File Access

The host user's home directory is mounted read-only at its original path inside the container. This means dragging files from the host into the terminal "just works" — the pasted path resolves to the same file inside the container.

- **macOS**: Files under `/Users/<you>/` are accessible (Desktop, Downloads, Documents, etc.)
- **Linux**: Files under `/home/<you>/` are accessible
- For files outside your home directory, copy them to `/workspace/attachments/` or `/drops/` instead

The mount is read-only — the container cannot modify host files outside `/workspace`.

## Sharing Files with Claude

There are two directories for sharing files between the host and the container:

| Directory | Host location | Purpose |
|-----------|---------------|---------|
| `/workspace/attachments/` | `<project>/attachments/` | Project-related files (gitignored) |
| `/drops/` | `~/claude-drops/` | Quick file sharing from anywhere on the host |

Both directories are gitignored. Use the Read tool to view images (PNG, JPG, WebP, PDF).

### When the user shares a file

- If the user mentions a screenshot, image, or file to review, check `/drops/` and `/workspace/attachments/` for recent files.
- If the user pastes a path starting with `/Users/` or `/home/`, it's a **host path** — the host home mount makes these resolve directly. For paths outside `$HOME`, look in `/drops/` or `/workspace/attachments/`.
- Use `ls -lt /drops/ /workspace/attachments/` to find the most recently added files.
- The `grab <path>` command translates host paths to container paths.

## Screenshots and Browser Tools

This container has full browser and screenshot capabilities. **Use these as your primary verification tools.**

### Quick Captures

| Command | What it captures |
|---------|-----------------|
| `take-screenshot url <URL>` | Web page via Playwright |
| `take-screenshot url --full-page <URL>` | Full scrollable page |
| `take-screenshot url --device "iPhone 11" <URL>` | Mobile emulation |
| `take-screenshot display` | X11 display (Xvfb) |
| `take-screenshot term "<command>"` | Terminal command output via termshot |

Screenshots save to `/workspace/attachments/` by default. View them with the Read tool (supports PNG, JPG, WebP).

### Playwright MCP Server

For interactive browser testing, use the Playwright MCP server:

- Navigate to URLs, click elements, fill forms
- Take screenshots at any point during interaction
- Verify multi-step UI workflows end-to-end
- Test responsive layouts with device emulation

### Verification Examples

```bash
# Verify a web app change
take-screenshot url http://localhost:3000

# Verify an API endpoint
curl -s http://localhost:8080/api/health | jq .

# Verify a CLI tool
take-screenshot term "my-tool --version"

# Verify with full browser interaction (via Playwright MCP)
# Navigate → click → fill → screenshot
```

## Cleanup

Periodically clean up ephemeral files that accumulate during development:

- `/workspace/attachments/` — Delete old screenshots and reference files
- `/workspace/.claude/plans/` — Remove completed or obsolete plan files
- `/workspace/.claude/logs/` — Logs are gitignored; clear if they grow large

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


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
