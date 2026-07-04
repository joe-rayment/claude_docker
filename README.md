# Claude Code Docker Development Environment

A portable, pre-configured development environment for Claude Code. Apply it to any project directory and start building.

---

## Setup

**Prerequisite:** [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running.

### First-time setup (or pulling updates)

Requires [GitHub CLI](https://cli.github.com/) (`gh`) authenticated with access to this repo.

```bash
cd /path/to/your/project
gh api repos/joe-rayment/claude_docker/contents/bootstrap.sh -H "Accept: application/vnd.github.raw" | bash
```

Or pass the path directly:

```bash
gh api repos/joe-rayment/claude_docker/contents/bootstrap.sh -H "Accept: application/vnd.github.raw" | bash -s -- /path/to/project
```

This clones (or pulls) the environment into `.claude-dev/`, builds the image, and installs a `./claude-dev` launcher in your project root. Both are auto-added to `.gitignore`. Re-running it always pulls the latest code and rebuilds, so use it to pick up upstream changes.

### Daily use

```bash
./claude-dev
```

That's it. Builds only if needed (image missing or local repo changed), starts if stopped, execs in. First time inside, the container walks you through Claude auth, git config, and dependency detection.

---

## Daily Commands

All commands run from your project root:

```bash
./claude-dev              # Build → start → enter (one step)
./claude-dev --stop       # Stop the container
./claude-dev --status     # Show container and health status
./claude-dev --update     # Pull latest environment, rebuild, update launcher
./claude-dev --rebuild    # Force rebuild (no cache)
./claude-dev --teardown   # Remove template artifacts (back up beads first) — see below
```

Auth, git config, and shell history persist across stops and rebuilds — they live in a named Docker volume. Only `docker compose down -v` removes them.

---

## Inside the Container

### Claude

| Command | Description |
|---------|-------------|
| `cs` | Start Claude (skip permissions) |
| `csd` | Start Claude with debug logging |
| `cn` | Start Claude (normal mode) |
| `claude` | Start Claude (normal) |

### Editor & Tools

| Command | Description |
|---------|-------------|
| `hx file.txt` | Open file in Helix editor |
| `vim file.txt` | Alias for Helix |
| `view-logs` | Interactive log viewer |
| `clog-latest` | View latest Claude debug log |
| `clog-export` | Export latest log to workspace |
| `Ctrl+Space` | IntelliShell: search saved commands |
| `Ctrl+B` | IntelliShell: bookmark a command |
| `Ctrl+R` | IntelliShell: history search |
| `Ctrl+X` | IntelliShell: AI fix |

### Multiple Terminals

Each `./claude-dev` call execs into the same running container:

```bash
# Tab 1: Claude        # Tab 2: Editor         # Tab 3: Tests
./claude-dev            ./claude-dev             ./claude-dev
cs                      hx src/main.py           npm test
```

---

## What's Included

- **Claude Code** with browser authentication
- **Terminal**: Zsh, Oh-My-Zsh, Pure prompt, IntelliShell
- **Editor**: Helix
- **Dev Tools**: Git, GitHub CLI, Python 3 (poetry, uv), Node.js (npm, pnpm, yarn), Go
- **Persistent**: Auth, history, and configs saved between sessions
- **Auto-detection**: Recognizes package.json, requirements.txt, go.mod, Cargo.toml, Gemfile
- **Health check**: Docker monitors container liveness automatically
- **Dev Logging**: Structured session logging with `dev-log`
- **Experience Tests**: bats-core tests to verify container UX

---

## Project Structure

```
your-project/
├── claude-dev            # Launcher script
├── .claude-dev/          # Environment (this repo, cloned)
│   ├── docker-compose.yml
│   ├── Dockerfile
│   └── ...
├── src/                  # Your project files
└── ...
```

Your project mounts at `/workspace` inside the container. Each project gets a unique container and volume based on the directory name:

| Project Folder | Container Name | Volume Name |
|----------------|----------------|-------------|
| MyProject | myproject-claude-dev | myproject-agent-home |
| my-web-app | my-web-app-claude-dev | my-web-app-agent-home |

---

### Development Logging

Agents log their work to `/workspace/.claude/logs/` using the `dev-log` command:

| Command | Description |
|---------|-------------|
| `dev-log run "cmd" pass\|fail "reason"` | Log a command execution |
| `dev-log decision "description"` | Log a design decision |
| `dev-log error "what" "detail"` | Log a failure |
| `dev-log change "what" "why"` | Log a code change |
| `dev-log show [category] [N]` | View recent entries |

See `CLAUDE.md` for full agent instructions.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `docker: command not found` | Install Docker Desktop and restart your terminal |
| `Cannot connect to Docker daemon` | Open Docker Desktop and wait for it to start |
| `container name already in use` | `./claude-dev --stop && ./claude-dev` |
| `Permission denied` on `./claude-dev` | `chmod +x ./claude-dev` |
| Claude auth issues | Run `claude`, then `/logout` and `/login` |
| Configs not updating after rebuild | Configs auto-sync on checksum change (see [Customizing Configs](#customizing-configs-survives-rebuilds)). To fully reset: `cd .claude-dev && docker compose down -v` (removes auth/history) |
| Permission issues with project files | `chmod -R 755 /path/to/your/project` on host |

---

## Manual Setup

If you prefer not to use the bootstrap script:

```bash
# 1. Clone into your project directory
cd /path/to/your/project
git clone https://github.com/joe-rayment/claude_docker.git .claude-dev

# 2. Install the launcher
cp .claude-dev/scripts/launcher.sh ./claude-dev
chmod +x ./claude-dev

# 3. Build, start, and enter
./claude-dev
```

The launcher derives per-project names from the directory, writes
`.claude-dev/.env` for compose interpolation, and builds the image on first
run — there is no `.env` or compose file to hand-edit.

---

## Configuration

### Customizing Configs (survives rebuilds)

Container configs (zshrc, Claude settings, Helix, etc.) sync from the image on startup whenever the image's config checksum changes. Direct edits to synced files get overwritten — put personal customizations in `.local` override files instead:

| Config | Override file | Mechanism |
|--------|--------------|-----------|
| Shell | `~/.zshrc.local` (in container) | Sourced at end of `.zshrc` |
| Claude Code | `~/.claude/settings.local.json` | Deep-merged into `settings.json` on startup; `permissions.allow`/`deny`/`ask` arrays are unioned with the base lists |

### Beads Task Tracking

The container runs [Beads](https://github.com/gastownhall/beads) (`bd`) in embedded Dolt mode (no SQL server) for persistent agent task tracking. The live database is `/workspace/.beads/embeddeddolt/` (gitignored); `.beads/issues.jsonl` is a git-tracked export used to rebuild it. A broken database self-heals at container start, or run `bd doctor --fix --yes`.

### Working Inside a Larger Repo (Teardown / Resume)

If you dropped the template into a subdirectory of a larger git repo, the nested `.git/` created for beads sync blocks `git add` from the parent. Run `./claude-dev --teardown` before pushing back: it backs up `.beads/issues.jsonl` to `~/.claude-dev-state/<project>/<timestamp>/` and removes the template artifacts (`.git/`, `.gitignore`, `.beads/`, `.claude-dev/`, `claude-dev`, `docker-compose.yml`, `attachments/`, `.claude/logs/`). Re-running the bootstrap in the same directory later detects the snapshot and offers to restore beads.

### Adding Python Packages

Edit `.claude-dev/Dockerfile`, then rebuild:

```dockerfile
RUN pip3 install --no-cache-dir your-package
```

```bash
./claude-dev --rebuild
```

---

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│  Your Machine                                           │
│  ┌───────────────────────────────────────────────────┐  │
│  │  your-project/                                    │  │
│  │  ├── claude-dev     ◄── Launcher (./claude-dev)   │  │
│  │  ├── src/                                         │  │
│  │  ├── .claude-dev/   ◄── This repo                 │  │
│  │  │   ├── docker-compose.yml  ◄── From repo        │  │
│  │  │   └── ...                                      │  │
│  │  └── ...                                          │  │
│  └───────────────────────────────────────────────────┘  │
│                         │                               │
│                    ./claude-dev                          │
│                         │                               │
│                         ▼                               │
│  ┌───────────────────────────────────────────────────┐  │
│  │  Docker Container (your-project-claude-dev)       │  │
│  │  /workspace/  ◄── your-project files mounted here │  │
│  │  /home/agent/ ◄── persistent (auth, config, etc.) │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

---

## License

MIT

## Acknowledgments

- [Docker Claude Code sandbox](https://docs.docker.com/ai/sandboxes/claude-code/)
- [zsh-in-docker](https://github.com/deluan/zsh-in-docker)
- [Pure prompt](https://github.com/sindresorhus/pure)
- [IntelliShell](https://github.com/lasantosr/intelli-shell)
- [Helix editor](https://helix-editor.com/)
