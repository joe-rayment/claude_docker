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
- **Persistent**: Auth, history, and configs saved between sessions
- **Auto-detection**: Recognizes package.json, requirements.txt, go.mod, Cargo.toml, Gemfile
- **Health check**: Docker monitors Claude auth status automatically

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

## Voicetree Integration (Optional)

[Voicetree](https://github.com/voicetreelab/voicetree) is a spatial IDE for recursive multi-agent orchestration — "Obsidian meets Claude Code". It runs as a desktop app on your host and connects to Claude Code in Docker via MCP.

### Quick Start

```bash
# 1. Bootstrap with Voicetree backend
gh api repos/joe-rayment/claude_docker/contents/bootstrap.sh -H "Accept: application/vnd.github.raw" | bash -s -- --voicetree

# 2. Enter container and configure MCP
./claude-dev
menu    # Choose option 3: Configure Voicetree MCP

# 3. Install & open Voicetree on your host
# macOS: brew install --cask voicetreelab/tap/voicetree
# Linux: see https://github.com/voicetreelab/voicetree/releases
```

Or add Voicetree to an existing setup:

```bash
./claude-dev --voicetree    # Builds + starts backend, then enters container
```

### Architecture

```
HOST                              DOCKER
┌─────────────────────┐          ┌──────────────────────┐
│ Voicetree Desktop   │   MCP   │ claude-dev container  │
│ Graph UI + Agents   │◄───────►│ Claude Code           │
│ localhost:3001/mcp  │         │ reads .mcp.json       │
└─────────────────────┘          ├──────────────────────┤
                                 │ voicetree-backend    │
                                 │ FastAPI :8001        │
                                 │ (optional profile)   │
                                 └──────────────────────┘
```

- **Voicetree Desktop** runs on your host (Electron app with graph visualization)
- **Voicetree Backend** runs in Docker as an optional service (text-to-graph, embeddings)
- **Claude Code** connects to Voicetree via MCP for agent orchestration
- **Default experience is unchanged** — Voicetree is fully opt-in

### Commands

| Where | Command | Description |
|-------|---------|-------------|
| Host | `./claude-dev --voicetree` | Start with Voicetree backend |
| Container | `voicetree-setup` | Configure MCP connection + API keys |
| Container | `menu` → option 3 | Same as above, from the setup menu |

### Important Notes

- Voicetree agents spawned from the desktop app run on your **host**, not inside Docker
- The Voicetree backend (text-to-graph processing) runs in Docker with a separate container
- Voicetree uses [BSL 1.1](https://github.com/voicetreelab/voicetree/blob/main/LICENSE) — installed from official sources, not bundled
- API keys (Google, OpenAI) are stored in `/workspace/.env` if you use the backend

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
