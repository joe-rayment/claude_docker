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

Merge semantics for `settings.local.json`: objects deep-merge (local wins per key); the `permissions.allow`/`deny`/`ask` arrays are **unioned** with the base lists; any other array is replaced wholesale. If the local file contains invalid JSON, the entrypoint warns and skips the merge rather than corrupting `settings.json`.

## Core Principle

**Run code, don't guess.** Execute commands, run tests, check output. If you're unsure whether something works, run it.

## Answer Style — Caveman Brevity

**Talk like a caveman: brief, blunt, to the point.** Short sentences or fragments. Cut filler, hedging, and connective fluff. Lead with the answer. One or two lines is the norm.

- Terse beats polished: "Fixed bug. Pushed." not "I've gone ahead and fixed the bug and pushed it to the remote."
- **Don't narrate process** — what you explored, every file touched, each step. Report a finished task in a line or two (what changed, where), not a blow-by-blow.
- **Don't volunteer** caveats, alternatives, background, root-cause essays, or "what I could do next" unless asked. Answer the question; trust the user to ask follow-ups.
- **Match size to question.** Yes/no question gets yes/no plus at most a brief why — not a report.
- No preambles ("Great question…", "I'll now…") or postambles ("Let me know if…").
- **Brevity never costs correctness.** Code, commands, file paths, and exact values stay complete and accurate — never abbreviate those.

## Ownership — Never Assign Work to the User

**NEVER assign the user tasks.** You own the work end to end. Do not hand the user a to-do list, "next steps you should run", "verification owed by you", checklists of commands to execute, or anything framed as theirs to complete. The user directs; Claude executes.

- If something genuinely cannot be done or verified in this environment (e.g. a host-side `./claude-dev --rebuild` that must run outside the container), state it plainly as an **environment limitation**, do the best verification available here, and carry it as your own open item — do not delegate it back to the user.
- Don't end responses by telling the user to run, close, push, or check things you could do yourself. Just do them.
- **Don't ask the user to do something you have enough information to do or figure out yourself** (e.g. "run the following to confirm", "check whether X"). Run it, read it, work it out — then report the result.
- **Never ask the user to confirm details they've already given you.** Re-read the conversation before asking; if the answer is already there, use it. Only ask when information is genuinely missing and you cannot obtain or infer it yourself.
- Offering a choice when a decision is genuinely the user's to make is fine. Handing over execution work, or re-asking for what you already know, is not.

## Verification

**Always verify changes by running the actual application** — code inspection isn't enough. Run the app, hit the endpoint, screenshot the UI. For CLI tools use `take-screenshot term "<command>"`; for web UIs use `take-screenshot url <URL>` or the Playwright MCP server; for APIs use `curl` or similar. Install missing tools as needed (`apt-get install`, `pip install`, `npm install`). Code-based tests (unit, integration) are for regression protection, not for verifying current work — run them to confirm you haven't broken other things. Before reporting a task as done, ask yourself: "Did I actually see this working?"

## Logging

Use `dev-log` to record what happens during your session. Logs live at `/workspace/.claude/logs/`.

| Command | When to use |
|---------|-------------|
| `dev-log run "cmd" pass\|fail "reason" ["detail"]` | After running a command (tests, builds, deploys) |
| `dev-log decision "description"` | When choosing between approaches |
| `dev-log error "what" ["detail"]` | When something fails unexpectedly |
| `dev-log change "what" "why"` | After modifying code or config |
| `dev-log show [category] [N]` | View recent entries |

Log every test run, build, and deploy (pass or fail), decisions that affect architecture or approach, errors with enough detail to diagnose later, and non-obvious changes. Don't log trivial reads or explorations. Run `dev-log show` at session start to see what happened before you.

## Drag-and-Drop File Access

The host user's home directory is mounted read-only at its original path inside the container. This means dragging files from the host into the terminal "just works" — the pasted path resolves to the same file inside the container.

- **macOS**: Files under `/Users/<you>/` are accessible (Desktop, Downloads, Documents, etc.)
- **Linux**: Files under `/home/<you>/` are accessible
- For files outside your home directory, copy them to `/workspace/attachments/` instead

The mount is read-only — the container cannot modify host files outside `/workspace`.

## Sharing Files with Claude

`/workspace/attachments/` is the directory for sharing files between the host and container (host path: `<project>/attachments/`, gitignored). Use the Read tool to view images (PNG, JPG, WebP, PDF).

### When the user shares a file

- If the user mentions a screenshot, image, or file to review, check `/workspace/attachments/` for recent files.
- If the user pastes a path starting with `/Users/` or `/home/`, it's a **host path** — the host home mount makes these resolve directly. For paths outside `$HOME`, look in `/workspace/attachments/`.
- Use `ls -lt /workspace/attachments/` to find the most recently added files.
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

This environment uses [Beads](https://github.com/gastownhall/beads) (`bd`) for persistent task tracking across sessions, in **embedded Dolt mode** (no SQL server). The full command reference and session-close protocol are auto-injected each session via the `bd prime` SessionStart hook — refer to that block, not a duplicate copy here.

**Beads are ONLY for Claude Code's own work. They CANNOT be assigned to a human.** A bead is Claude's task memory across sessions. Never create a bead that represents work for the user to do — not "review this", not "decide X", not "run Y". If work is blocked on a human decision, ask the user directly in the conversation. Beads that assign humans work violate the [Ownership](#ownership--never-assign-work-to-the-user) rule.

Even though `bd` offers them, do NOT use: `bd update <id> --assignee=<human>` (the only valid assignee is Claude itself, via `--claim`) or `bd human <id>` as a way to park a question (it is not a substitute for asking — at most use it to *record* a decision you have already raised in conversation, with the bead still owned by Claude).

- The embedded Dolt database at `/workspace/.beads/embeddeddolt/` (gitignored) is the live source of truth; `.beads/issues.jsonl` is a passive, git-tracked export used to rebuild the database (e.g. after teardown/resume or corruption). Always edit issues via `bd` commands, never by editing the JSONL.
- To repair a broken database: `cd /workspace && bd doctor --fix --yes` (self-healing also runs at entrypoint, welcome screen, and menu option 3). No server to start — bd works directly against the on-disk database.
- Use `bd update <id> --flag` to modify issues — never `bd edit` (it opens `$EDITOR` and blocks). Include issue IDs in commit messages when relevant (`Fix auth bug (bd-a3f2)`).
- **Memory precedence:** project knowledge (decisions, gotchas, environment facts) goes in `bd remember` — it syncs with the repo and is shared across machines. The Claude Code harness's own auto-memory (`MEMORY.md` under `~/.claude/projects/`) is for user-specific context only (who the user is, how they like to work) — never project knowledge. The injected "do NOT use MEMORY.md" rule means: don't create ad-hoc MEMORY.md files for project facts; it does not disable the harness's user-memory feature.

## Working Inside a Larger Repo (Teardown / Resume)

When the template is dropped into a subdirectory of a larger git repo, `bd init` creates a nested `.git/` so beads can sync. That nested repo makes the parent treat the subdir as an embedded sub-repo (blocks `git add` from the parent). Use `./claude-dev --teardown` from the host before pushing back: it backs up `.beads/issues.jsonl` to `~/.claude-dev-state/<project>/<timestamp>/` and removes the template artifacts (`.git/`, `.gitignore`, `.beads/`, `.claude-dev/`, `claude-dev`, `docker-compose.yml`, `attachments/`, `.claude/logs/`). Re-bootstrapping in the same directory detects the snapshot and offers to restore beads — the embedded Dolt DB rebuilds from JSONL on first container start.

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
Follow the **[Session Completion](#session-completion)** workflow below — it is the single session-end protocol (file beads for follow-ups, run quality gates, update issue status, push to remote). In addition:
1. Ensure all changes are logged via `dev-log`.
2. Session logs are auto-exported on Claude exit (via hook).

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


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
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
- **Beads are ONLY for Claude Code's own work — NEVER assign a bead to a human.** No "review this", "decide X", or "run Y" beads. Ask the user directly instead.
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
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
