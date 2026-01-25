# Claude Code Docker Development Environment

## Quick Start (Fresh Machine)

### If you don't have Docker installed:

```bash
# macOS - Install Docker Desktop
brew install --cask docker

# Or download from: https://www.docker.com/products/docker-desktop

# Start Docker Desktop (wait for it to fully start)
open -a Docker
```

### Get it running:

```bash
# Clone this repo
git clone https://github.com/joe-rayment/claude_docker.git
cd claude_docker

# Build and start
docker compose build
docker compose up -d

# Get into the terminal
docker compose exec claude-dev /bin/zsh

# First time only - authenticate
claude auth login
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

### Daily use:

```bash
# Start the container (if not running)
docker compose up -d

# Tab 1: Run Claude Code
docker compose exec claude-dev /bin/zsh
claude

# Tab 2: Open another terminal (new iTerm tab)
docker compose exec claude-dev /bin/zsh
hx myfile.txt

# When done
docker compose down
```

## What's Included

- **Claude Code** with browser authentication
- **Terminal**: Zsh, Oh-My-Zsh, Pure prompt, IntelliShell
- **Editor**: Helix (base16_default theme)
- **Dev Tools**: Git, GitHub CLI, Python 3 (numpy, pandas, matplotlib, scikit-learn, jupyter), Node.js, Go
- **Ralph Wiggum**: Simple bash loop for autonomous development (no plugin needed)
- **Detailed Logging**: Auto-enabled debug logs with easy export
- **Persistent**: All configs, history, and credentials saved between sessions

---

## Ralph Wiggum - Autonomous Development

This container implements the **simple bash loop approach** to Ralph Wiggum, as recommended by the community. No plugins required.

### Why This Approach?

1. **Fresh context each iteration** - No context degradation from accumulating history
2. **Spec is the source of truth** - Not conversation history
3. **True simplicity** - Ralph is literally just a bash while loop
4. **You own the spec** - Read every line, edit it yourself

### The Workflow

```
┌─────────────────────────────────────────────────────────────┐
│  1. ralph-init        Initialize project with SPEC.md      │
│  2. Edit SPEC.md      Define requirements & constraints    │
│  3. cs                Bidirectional planning with Claude   │
│  4. Edit PLAN.md      Break down into atomic tasks         │
│  5. git commit        Safety checkpoint                    │
│  6. ralph -n 10       Run the autonomous loop              │
│  7. git diff          Review changes                       │
└─────────────────────────────────────────────────────────────┘
```

### Quick Start

```bash
# 1. Initialize Ralph for your project
ralph-init

# 2. Edit the spec file (define what you're building)
ralph-spec   # or: hx SPEC.md

# 3. Do bidirectional planning with Claude
cs
# Ask Claude questions, let Claude ask you questions
# Refine your spec until it's bulletproof

# 4. Edit the plan file (break into tasks)
ralph-plan   # or: hx PLAN.md

# 5. Commit your work (safety checkpoint!)
git add -A && git commit -m "Before Ralph run"

# 6. Run Ralph
ralph -n 10   # Run 10 iterations

# 7. Review what Ralph did
git diff
```

### Key Principles

| Principle | Why It Matters |
|-----------|----------------|
| **Fresh context** | Each iteration starts clean - no context rot |
| **Spec is truth** | The spec file, not conversation history |
| **You own the spec** | Read every line, understand it, edit it yourself |
| **Keep it small** | Bloated specs leave no room for implementation |
| **Bidirectional planning** | Both you and Claude ask questions until aligned |
| **Always --max-iterations** | Start with 10-20, never run unlimited |
| **Git before running** | Always commit - it's your rollback point |

### Commands Reference

| Command | Description |
|---------|-------------|
| `ralph -n 10` | Run 10 iterations of the loop |
| `ralph --help` | Show all options |
| `ralph-init` | Initialize Ralph for a project |
| `ralph-spec` | Edit SPEC.md in Helix |
| `ralph-plan` | Edit PLAN.md in Helix |

### How It Works

Ralph is a simple bash loop:

```bash
while :; do
    cat SPEC.md | claude --dangerously-skip-permissions --print
    sleep 2
done
```

Each iteration:
1. Claude gets a **fresh context** (no accumulated history)
2. Reads your **SPEC.md** to understand the project
3. Reads **PLAN.md** to find the next unchecked task
4. Completes ONE task, marks it done
5. Exits, loop repeats

The spec and codebase (via git) are the source of truth.

### Writing Good Specs

Your SPEC.md should include:

```markdown
# Project Specification

## Context
[What is this? What problem does it solve?]

## Requirements
[Specific, testable requirements - be precise]

## Technical Constraints
Build: npm run build
Test:  npm test
Lint:  npm run lint

## Completion Criteria
- [ ] All requirements met
- [ ] All tests pass
- [ ] No lint errors

## Current Task
See PLAN.md
```

**Keep specs focused.** Bloated specs leave no room for implementation in each iteration.

### Writing Good Plans

Your PLAN.md should have atomic, ordered tasks:

```markdown
# Implementation Plan

## Tasks
- [ ] Create user model with email, password fields
- [ ] Add validation for email format
- [ ] Write unit tests for user model
- [ ] Create registration endpoint
- [ ] Add integration tests

## Completed
- [x] Set up project structure
```

Each task should be completable in one iteration.

### Bidirectional Planning

Before running Ralph, have a conversation with Claude:

1. **You ask Claude**: "What's unclear about this spec?"
2. **Claude asks you**: "How should X handle Y?"
3. **Repeat** until both sides have no questions
4. **Update** SPEC.md and PLAN.md with what you learned

This surfaces implicit assumptions that cause bugs.

---

## Logging & Debugging

All Claude Code sessions are automatically logged with detailed debug information.

### View Logs

```bash
# Quick view latest log
clog-latest

# Interactive log viewer
view-logs

# Export log to workspace
clog-export

# Manual export
cp ~/.claude/debug/latest /workspace/logs/my-session.log
```

### Log Locations
- Debug logs: `~/.claude/debug/`
- Session transcripts: `~/.claude/projects/`
- Exported logs: `/workspace/logs/`
- Latest log symlink: `~/.claude/debug/latest`

All logs persist across container restarts in the `agent-home` volume.

---

## Usage

### Opening Multiple Terminal Sessions

You can open multiple iTerm tabs/windows connected to the same container. This is useful for running Claude Code in one tab and using Helix editor or other tools in another.

```bash
# Tab 1: Run Claude Code
docker compose exec claude-dev /bin/zsh
claude

# Tab 2 (new iTerm tab): Open Helix editor
docker compose exec claude-dev /bin/zsh
hx myfile.txt

# Tab 3 (new iTerm tab): Run tests, git commands, etc.
docker compose exec claude-dev /bin/zsh
```

All tabs share the same filesystem and environment, so changes made in one are visible in all others.

### Starting Claude Code

Once inside the container:

```bash
cs    # Quick start (skip permissions)
csd   # With debug logging
claude   # Normal start
```

### Working with Projects

Your `workspace` directory is mounted at `/workspace` in the container. Any changes made here are persistent.

```bash
# Clone a GitHub repository
cd /workspace
gh repo clone username/repository

# Or create a new project
mkdir my-project
cd my-project
git init
```

### Using the Helix Editor

```bash
# Open a file
hx filename.txt

# Common keybindings
# Ctrl+S - Save
# Ctrl+Q - Quit
# See Helix docs for more: https://docs.helix-editor.com/
```

### IntelliShell Commands

- **Ctrl+Space** - Search command templates
- **Ctrl+B** - Bookmark current command
- **Ctrl+X** - Fix command with AI

---

## Project Structure

```
claude_docker/
├── Dockerfile              # Main Docker image definition
├── docker-compose.yml      # Docker Compose configuration
├── config/
│   ├── .zshrc             # Zsh configuration
│   ├── helix-config.toml  # Helix editor configuration
│   ├── SPEC.md.template   # Ralph spec template
│   └── PLAN.md.template   # Ralph plan template
├── scripts/
│   ├── entrypoint.sh      # Container initialization script
│   ├── ralph.sh           # Ralph Wiggum bash loop
│   ├── setup-ralph.sh     # Ralph setup wizard
│   └── view-logs.sh       # Log viewer
├── workspace/             # Your working directory (gitignored)
└── README.md              # This file
```

---

## Customization

### Adding Python Packages

Edit the Dockerfile to add more Python packages:

```dockerfile
RUN pip3 install --no-cache-dir \
    your-package-name \
    another-package
```

Then rebuild:

```bash
docker compose build
```

### Modifying Zsh Configuration

Edit `config/.zshrc` and rebuild the image, or modify `~/.zshrc` inside the running container for temporary changes.

### Changing the Theme

Edit `config/helix-config.toml` to change the Helix theme:

```toml
theme = "your_theme_name"
```

---

## Persistent Data

The following data is persisted in Docker volumes:

- Claude Code credentials and settings
- IntelliShell command history and templates
- Git configuration
- Zsh command history

To reset everything, remove the volumes:

```bash
docker compose down -v
```

---

## Troubleshooting

### Claude Code Authentication Issues

If Claude Code fails to authenticate, try resetting the auth:

```bash
# Inside the container
claude auth logout
claude auth login
```

Or remove the volume and start fresh:

```bash
# On host machine
docker compose down
docker volume rm claude_docker_agent-home
docker compose up -d
```

### Permission Issues

If you encounter permission issues with the workspace:

```bash
# On your host machine
chmod -R 755 workspace
```

---

## Advanced Usage

### Running Multiple Projects

You can create multiple docker-compose configurations for different projects:

```bash
# Copy docker-compose.yml
cp docker-compose.yml docker-compose.project1.yml

# Edit the workspace mount in the new file
# Then run with:
docker compose -f docker-compose.project1.yml up -d
```

### Accessing from VS Code

Install the "Remote - Containers" extension and attach to the running container for a full IDE experience.

---

## Contributing

Feel free to open issues or submit pull requests for improvements!

## License

MIT

## Acknowledgments

- Based on the official [Docker Claude Code sandbox](https://docs.docker.com/ai/sandboxes/claude-code/)
- Uses [zsh-in-docker](https://github.com/deluan/zsh-in-docker) for Zsh setup
- [Pure prompt](https://github.com/sindresorhus/pure) theme
- [IntelliShell](https://github.com/lasantosr/intelli-shell) for intelligent command management
- [Helix editor](https://helix-editor.com/)
- Ralph Wiggum approach inspired by [Geoffrey Huntley](https://ghuntley.com/) and community best practices
