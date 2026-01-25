# Claude Code Docker Development Environment

A portable, pre-configured development environment for Claude Code. Clone it once per project, point it at your code, and start building.

---

## Quickstart

### Prerequisites

1. **Docker Desktop** installed and running
   ```bash
   # macOS
   brew install --cask docker
   open -a Docker   # Wait for it to fully start
   ```

2. **A project to work on** (or create one)

### Setup (5 minutes)

```bash
# 1. Clone this repo INTO your project directory
cd /path/to/your/project
git clone https://github.com/joe-rayment/claude_docker.git .claude-dev

# 2. Configure it to use your project
cd .claude-dev
echo "PROJECT_PATH=.." > .env

# 3. Build the container (first time only)
docker compose build

# 4. Start the container
docker compose up -d

# 5. Enter the container
docker compose exec claude-dev /bin/zsh
```

### First Time Inside Container

```bash
# Authenticate Claude (opens browser)
claude auth login

# Configure git
git config --global user.name "Your Name"
git config --global user.email "your@email.com"
```

### Daily Use

```bash
# From your .claude-dev directory:
cd /path/to/your/project/.claude-dev

# Start the container
docker compose up -d

# Enter the container
docker compose exec claude-dev /bin/zsh

# Start Claude
cs

# When done for the day
exit
docker compose down
```

---

## What's Included

- **Claude Code** with browser authentication
- **Terminal**: Zsh, Oh-My-Zsh, Pure prompt, IntelliShell
- **Editor**: Helix
- **Dev Tools**: Git, GitHub CLI, Python 3 (numpy, pandas, matplotlib, scikit-learn, jupyter), Node.js, Go
- **Ralph Wiggum**: Simple bash loop for autonomous development
- **Persistent**: Auth, history, and configs saved between sessions

---

## Project Structure

After setup, your project looks like this:

```
your-project/
├── .claude-dev/          # This repo (gitignored or separate)
│   ├── docker-compose.yml
│   ├── Dockerfile
│   ├── .env              # Points to parent directory
│   └── ...
├── src/                  # Your actual project files
├── package.json
└── ...
```

Your project files appear at `/workspace` inside the container.

---

## Ralph Wiggum - Autonomous Development

Ralph is a simple bash loop that runs Claude autonomously with fresh context each iteration.

### Why This Approach?

- **Fresh context each iteration** - No context degradation
- **Spec is the source of truth** - Not conversation history
- **Simple** - It's just a bash while loop

### Workflow

```bash
# 1. Initialize Ralph
ralph-init

# 2. Edit your spec (what you're building)
ralph-spec

# 3. Plan with Claude interactively
cs
# Ask questions, let Claude ask questions, refine the spec

# 4. Edit your plan (break into tasks)
ralph-plan

# 5. Commit (safety checkpoint!)
git add -A && git commit -m "Before Ralph"

# 6. Run the loop
ralph -n 10

# 7. Review
git diff
```

### Commands

| Command | Description |
|---------|-------------|
| `ralph -n 10` | Run 10 iterations |
| `ralph --help` | Show options |
| `ralph-init` | Initialize for a project |
| `ralph-spec` | Edit SPEC.md |
| `ralph-plan` | Edit PLAN.md |

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
docker compose exec claude-dev /bin/zsh
cs

# Tab 2: Editor (new terminal tab)
docker compose exec claude-dev /bin/zsh
hx src/main.py

# Tab 3: Tests (new terminal tab)
docker compose exec claude-dev /bin/zsh
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

## Configuration

### Using a Different Project Path

Edit `.env`:
```bash
PROJECT_PATH=/absolute/path/to/project
```

Or use a relative path from the `.claude-dev` directory:
```bash
PROJECT_PATH=..           # Parent directory
PROJECT_PATH=../other     # Sibling directory
```

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
│  │  │   ├── .env      ◄── PROJECT_PATH=..            │  │
│  │  │   └── ...                                      │  │
│  │  └── ...                                          │  │
│  └───────────────────────────────────────────────────┘  │
│                         │                               │
│                         ▼                               │
│  ┌───────────────────────────────────────────────────┐  │
│  │  Docker Container                                 │  │
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
