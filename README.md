# Claude Code Docker Development Environment

A portable, pre-configured development environment for Claude Code. Apply it to any project directory and start building.

---

## Setup

**Prerequisite:** [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running.

### Apply to a project

```bash
cd /path/to/your/project
curl -fsSL https://raw.githubusercontent.com/joe-rayment/claude_docker/main/bootstrap.sh | bash
```

Or pass the path directly:

```bash
curl -fsSL https://raw.githubusercontent.com/joe-rayment/claude_docker/main/bootstrap.sh | bash -s -- /path/to/project
```

This clones the environment into `.claude-dev/`, builds the image, and installs a `./claude-dev` launcher in your project root. Both are auto-added to `.gitignore`.

### Enter the container

```bash
./claude-dev
```

That's it. Builds if needed, starts if stopped, execs in. First time inside, the container walks you through Claude auth, git config, and dependency detection.

---

## Daily Commands

All commands run from your project root:

```bash
./claude-dev              # Build → start → enter (one step)
./claude-dev --stop       # Stop the container
./claude-dev --status     # Show container and health status
./claude-dev --update     # Pull latest environment, rebuild, update launcher
./claude-dev --rebuild    # Force rebuild (no cache)
```

Auth, git config, and shell history persist across stops and rebuilds — they live in a named Docker volume. Only `docker compose down -v` removes them.

---

## Inside the Container

### Claude

| Command | Description |
|---------|-------------|
| `cs` | Start Claude (skip permissions) |
| `csd` | Start Claude with debug logging |
| `claude` | Start Claude (normal) |

### Editor & Tools

| Command | Description |
|---------|-------------|
| `hx file.txt` | Open file in Helix editor |
| `vim file.txt` | Alias for Helix |
| `view-logs` | Interactive log viewer |
| `clog-latest` | View latest Claude log |
| `Ctrl+Space` | IntelliShell: search saved commands |
| `Ctrl+B` | IntelliShell: bookmark a command |

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
- **Dev Tools**: Git, GitHub CLI, Python 3 (numpy, pandas, matplotlib, scikit-learn, jupyter), Node.js, Go
- **Ralph**: Autonomous development loop ([frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code))
- **Persistent**: Auth, history, and configs saved between sessions
- **Auto-detection**: Recognizes package.json, requirements.txt, go.mod, Cargo.toml, Gemfile
- **Health check**: Docker monitors Claude auth status automatically

---

## Ralph - Autonomous Development

Ralph ([frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code)) provides intelligent autonomous development with built-in safety features: rate limiting, circuit breaker (3x no progress = exit), session continuity, and git automation.

### Quick Start

```bash
ralph-enable        # Interactive setup wizard
ralph-spec          # Edit your project spec (.ralph/PROMPT.md)
cs                  # Plan interactively with Claude
ralph-plan          # Edit your task list (.ralph/fix_plan.md)
ralph-run           # Run with automatic git commits
```

### Commands

| Command | Description |
|---------|-------------|
| `ralph` | Run the autonomous loop |
| `ralph --resume` | Resume previous session |
| `ralph --monitor` | Run with tmux dashboard |
| `ralph-run` | Run with git automation (auto-commits) |
| `ralph-enable` | Interactive setup wizard |
| `ralph-spec` | Edit .ralph/PROMPT.md |
| `ralph-plan` | Edit .ralph/fix_plan.md |

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

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `docker: command not found` | Install Docker Desktop and restart your terminal |
| `Cannot connect to Docker daemon` | Open Docker Desktop and wait for it to start |
| `container name already in use` | `./claude-dev --stop && ./claude-dev` |
| `Permission denied` on `./claude-dev` | `chmod +x ./claude-dev` |
| Claude auth issues | `claude auth logout && claude auth login` |
| Configs not updating after rebuild | Configs auto-sync now. To fully reset: `cd .claude-dev && docker compose down -v` (removes auth/history) |
| Permission issues with project files | `chmod -R 755 /path/to/your/project` on host |

---

## Manual Setup

If you prefer not to use the bootstrap script:

```bash
# 1. Clone into your project directory
cd /path/to/your/project
git clone https://github.com/joe-rayment/claude_docker.git .claude-dev
cd .claude-dev

# 2. Create .env file with your project path (if not using parent directory)
echo "PROJECT_PATH=/path/to/your/project" > .env

# 3. Copy and edit docker-compose.yml
cp docker-compose.yml.example docker-compose.yml
# Update container_name and volume name for your project

# 4. Build and start
docker compose build
docker compose up -d

# 5. Install launcher
cp scripts/launcher.sh ../claude-dev
chmod +x ../claude-dev

# 6. Enter
cd ..
./claude-dev
```

---

## Configuration

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
│  │  │   ├── docker-compose.yml  ◄── Generated        │  │
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
- Ralph Wiggum approach by [Geoffrey Huntley](https://ghuntley.com/)
