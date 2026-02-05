# Claude Code Docker Development Environment

A portable, pre-configured development environment for Claude Code. Run one command from any project directory and start building.

---

## Quickstart

### Prerequisites

**Docker Desktop** installed and running
```bash
# macOS
brew install --cask docker
open -a Docker   # Wait for it to fully start
```

### One-Line Setup

From your project directory:

```bash
curl -fsSL https://raw.githubusercontent.com/joe-rayment/claude_docker/main/bootstrap.sh | bash
```

This will:
- Clone the environment into `.claude-dev/`
- Build the container (first time only)
- Create a uniquely-named container for your project
- Start everything up

Then enter your container:

```bash
docker exec -it {your-project}-claude-dev /bin/zsh
```

The bootstrap script will show you the exact command.

### First Time Inside Container

The container will guide you through:
- Claude authentication (opens browser)
- Git configuration
- GitHub authentication (for pushing, PRs, issues)
- Dependency installation (auto-detected)
- Getting started menu

### Daily Use

```bash
# From your project directory:
cd /path/to/your/project/.claude-dev

# Start the container
docker compose up -d

# Enter the container
docker exec -it {your-project}-claude-dev /bin/zsh

# Or re-run bootstrap (it's idempotent):
cd /path/to/your/project
curl -fsSL https://raw.githubusercontent.com/joe-rayment/claude_docker/main/bootstrap.sh | bash
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

---

## Project Structure

After setup, your project looks like this:

```
your-project/
├── .claude-dev/          # Claude Docker environment
│   ├── docker-compose.yml  # Generated with unique names
│   ├── Dockerfile
│   └── ...
├── src/                  # Your actual project files
├── package.json
└── ...
```

Your project files appear at `/workspace` inside the container.

Container naming convention:
| Project Folder | Container Name | Volume Name |
|----------------|----------------|-------------|
| MyProject | myproject-claude-dev | myproject-agent-home |
| my-web-app | my-web-app-claude-dev | my-web-app-agent-home |

---

## Ralph - Autonomous Development

Ralph ([frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code)) provides intelligent autonomous development with built-in safety features.

### Features

- **Intelligent exit detection** - Dual-condition completion (indicators + EXIT_SIGNAL)
- **Rate limiting** - Configurable calls/hour (default 100)
- **Circuit breaker** - Detects stuck loops (3x no progress = exit)
- **Session continuity** - 24-hour sessions with `--resume`
- **Git automation** - Auto-commits before and after loop runs

### Project Structure

Ralph uses a `.ralph/` folder to organize project files:

```
your-project/
├── .ralph/
│   ├── PROMPT.md       # Project specification
│   ├── fix_plan.md     # Task list
│   ├── AGENT.md        # Agent instructions
│   └── ...
├── .ralphrc            # Configuration
└── ...
```

### Workflow

```bash
# 1. Initialize Ralph (interactive wizard)
ralph-enable

# 2. Edit your spec
ralph-spec

# 3. Plan with Claude interactively
cs

# 4. Edit your task list
ralph-plan

# 5. Run with git automation (auto-commits!)
ralph-run

# 6. Review
git log --oneline -5
```

### Commands

| Command | Description |
|---------|-------------|
| `ralph` | Run the autonomous loop |
| `ralph --resume` | Resume previous session |
| `ralph --monitor` | Run with tmux dashboard |
| `ralph-run` | Run with git automation (auto-commits) |
| `ralph-enable` | Interactive setup wizard |
| `ralph-init` | Alias for ralph-enable |
| `ralph-spec` | Edit .ralph/PROMPT.md |
| `ralph-plan` | Edit .ralph/fix_plan.md |

### Git Automation

The `ralph-run` command wraps ralph with automatic git commits:

1. **Before loop**: Creates a checkpoint commit if there are uncommitted changes
2. **After loop**: Generates an AI commit message and commits automatically

This ensures you always have a safety checkpoint and clean commits for each Ralph session.

---

## Commands Reference

### Claude
| Command | Description |
|---------|-------------|
| `cs` | Start Claude (skip permissions) |
| `csd` | Start Claude with debug logging |
| `claude` | Start Claude (normal) |

### Logs
| Command | Description |
|---------|-------------|
| `view-logs` | Interactive log viewer |
| `clog-latest` | View latest log |
| `clog-export` | Export log to workspace |

### Editor
| Command | Description |
|---------|-------------|
| `hx file.txt` | Open file in Helix |
| `vim file.txt` | Alias for Helix |

### IntelliShell
| Shortcut | Description |
|----------|-------------|
| `Ctrl+Space` | Search saved commands |
| `Ctrl+B` | Bookmark command |

---

## Multiple Terminal Sessions

Open multiple tabs connected to the same container:

```bash
# Tab 1: Claude
docker exec -it {your-project}-claude-dev /bin/zsh
cs

# Tab 2: Editor (new terminal tab)
docker exec -it {your-project}-claude-dev /bin/zsh
hx src/main.py

# Tab 3: Tests (new terminal tab)
docker exec -it {your-project}-claude-dev /bin/zsh
npm test
```

---

## Troubleshooting

### "docker: command not found"
Docker Desktop isn't installed or not in PATH. Install it and restart your terminal.

### "Cannot connect to Docker daemon"
Docker Desktop isn't running. Open Docker Desktop and wait for it to start.

### "container name already in use"
```bash
cd .claude-dev
docker compose down
docker compose up -d
```

### Claude authentication issues
```bash
claude auth logout
claude auth login
```

### Configs not updating after rebuild
The home directory is persisted in a volume. To reset:
```bash
cd .claude-dev
docker compose down -v   # Warning: removes auth, history
docker compose up -d
# Re-authenticate after this
```

### Permission issues with project files
```bash
# On your host machine
chmod -R 755 /path/to/your/project
```

---

## Manual Setup (Alternative)

If you prefer not to use the bootstrap script:

```bash
# 1. Clone this repo INTO your project directory
cd /path/to/your/project
git clone https://github.com/joe-rayment/claude_docker.git .claude-dev
cd .claude-dev

# 2. Create docker-compose.yml with your project name
# (copy from docker-compose.yml.example and update container/volume names)

# 3. Build and start
docker compose build
docker compose up -d

# 4. Enter the container
docker compose exec claude-dev /bin/zsh
```

---

## Configuration

### Using a Different Project Path

The bootstrap script automatically configures the parent directory. For manual setup, the docker-compose.yml mounts `../` as `/workspace`.

### Adding Python Packages

Edit `Dockerfile`, then rebuild:
```dockerfile
RUN pip3 install --no-cache-dir your-package
```

```bash
docker compose build
docker compose down && docker compose up -d
```

---

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│  Your Machine                                           │
│  ┌───────────────────────────────────────────────────┐  │
│  │  your-project/                                    │  │
│  │  ├── src/                                         │  │
│  │  ├── .claude-dev/  ◄── This repo                  │  │
│  │  │   ├── docker-compose.yml  ◄── Generated        │  │
│  │  │   └── ...                                      │  │
│  │  └── ...                                          │  │
│  └───────────────────────────────────────────────────┘  │
│                         │                               │
│                         ▼                               │
│  ┌───────────────────────────────────────────────────┐  │
│  │  Docker Container (your-project-claude-dev)      │  │
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
