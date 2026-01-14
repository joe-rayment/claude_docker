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
- **Persistent**: All configs, history, and credentials saved between sessions

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
claude
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

## Project Structure

```
claude_docker/
├── Dockerfile              # Main Docker image definition
├── docker-compose.yml      # Docker Compose configuration
├── config/
│   ├── .zshrc             # Zsh configuration
│   └── helix-config.toml  # Helix editor configuration
├── scripts/
│   └── entrypoint.sh      # Container initialization script
├── workspace/             # Your working directory (gitignored)
└── README.md              # This file
```

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
