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

## Voicetree Integration (Built-in)

[Voicetree](https://github.com/voicetreelab/voicetree) is a spatial IDE for recursive multi-agent orchestration — "Obsidian meets Claude Code". It gives you an interactive graph interface where nodes are markdown files, agents can be spawned visually, and context flows through the graph structure.

The setup has two parts:

- **Desktop app** — The Electron-based graph UI. Runs natively on your Mac/Linux host. This is what you interact with: the visual graph, node editor, agent spawning, etc.
- **Backend server** — A headless Python service for text-to-graph processing, embeddings, and semantic search via ChromaDB. Baked into the container image, started on demand. Has no UI of its own.

You need the desktop app for the graph interface. The backend enhances it with LLM-powered features but is optional.

### Architecture

```
YOUR MAC                          DOCKER CONTAINER
┌─────────────────────┐          ┌──────────────────────┐
│ Voicetree Desktop   │          │ Claude Code           │
│ Graph UI + Agents   │◄── MCP ─►│ (sandboxed)           │
│ Node editor         │          │                      │
│ Agent spawning      │          │ Voicetree Backend    │
│ localhost:3001/mcp  │          │ FastAPI :8001         │
└─────────────────────┘          └──────────────────────┘
```

Claude Code stays sandboxed in Docker. The desktop app connects to it over MCP via `host.docker.internal` (configured automatically in the compose file).

### Setup

#### 1. Install the desktop app on your host

```bash
# macOS (Homebrew)
brew tap voicetreelab/voicetree && brew install voicetree

# macOS (direct download)
# Apple Silicon: https://github.com/voicetreelab/voicetree/releases/latest/download/voicetree-arm64.dmg
# Intel:         https://github.com/voicetreelab/voicetree/releases/latest/download/voicetree-x64.dmg

# Linux
curl -fsSL https://raw.githubusercontent.com/voicetreelab/voicetree/main/install.sh | sh
```

Open Voicetree and enable MCP in its settings.

#### 2. Start the backend and configure MCP (inside the container)

```bash
./claude-dev
menu           # Choose option 3: Voicetree
               #   [a] Start backend server
               #   [c] Configure MCP connection
```

The MCP setup will ask for the port (default `3001`) and write the connection to `/workspace/.mcp.json`. It auto-detects the Docker host IP.

#### 3. Restart Claude to pick up MCP config

```bash
cs             # or: claude --dangerously-skip-permissions
```

Claude will now have access to Voicetree's MCP tools. You can verify by checking for voicetree in Claude's `/mcp` output.

#### 4. (Optional) Configure API keys for the backend

If you want the backend's LLM-powered features (text-to-graph, semantic search), it needs API keys:

```bash
menu           # Option 3 → [c] Configure MCP connection
               # Follow the prompts for Google/OpenAI API keys
```

Keys are stored in `/workspace/.env` (already in `.gitignore`).

### Commands

| Command | Description |
|---------|-------------|
| `voicetree-start` | Start the backend server |
| `voicetree-stop` | Stop the backend server |
| `voicetree-status` | Check if backend is running |
| `voicetree-logs` | Tail backend logs |
| `voicetree-setup` | Configure MCP connection + API keys |
| `menu` → option 3 | Voicetree submenu (all of the above) |

### Notes

- The desktop app runs on your **host**, not in Docker — it's an Electron app that needs a display
- Claude Code remains fully sandboxed in Docker; MCP bridges the connection
- Voicetree agents spawned from the desktop app also run on your host
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
