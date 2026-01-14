# Claude Code Docker Development Environment

A fully-configured Docker image for running Claude Code locally with a Mac-like terminal experience on Linux. This environment is designed for zero-configuration startup - just clone and run!

## Features

- **Claude Code** pre-installed and ready to use
- **Terminal Environment**:
  - Zsh with Oh-My-Zsh
  - Pure prompt theme
  - Syntax highlighting
  - IntelliShell integration
- **Development Tools**:
  - Helix editor (with base16_default theme)
  - GitHub CLI
  - Git
  - Python 3 with common packages (numpy, pandas, requests, matplotlib, scikit-learn, jupyter)
  - Node.js, Go, ripgrep, jq
- **Persistent Data**: Claude credentials, git config, and shell history saved across container restarts
- **Internet Access**: Fully configured for Claude authentication and web searches

## Prerequisites

- Docker installed and running
- Docker Compose (optional, but recommended)
- Anthropic API key for Claude Code

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/joe-rayment/claude_docker.git
cd claude_docker
```

### 2. Set Up Environment Variables

Create a `.env` file in the project root:

```bash
# Required for Claude Code
ANTHROPIC_API_KEY=your_api_key_here

# Optional: Git configuration
GIT_USER_NAME="Your Name"
GIT_USER_EMAIL="your.email@example.com"

# Optional: GitHub authentication
GITHUB_TOKEN=your_github_token
```

### 3. Create Workspace Directory

```bash
mkdir workspace
```

### 4. Build and Run

#### Using Docker Compose (Recommended)

```bash
# Build the image
docker-compose build

# Start the container
docker-compose up -d

# Attach to the container
docker-compose exec claude-dev /bin/zsh
```

#### Using Docker Directly

```bash
# Build the image
docker build -t claude-code-dev .

# Run the container
docker run -it \
  -e ANTHROPIC_API_KEY="your_api_key" \
  -e GIT_USER_NAME="Your Name" \
  -e GIT_USER_EMAIL="your.email@example.com" \
  -v $(pwd)/workspace:/workspace \
  claude-code-dev
```

## Usage

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
docker-compose build
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
docker-compose down -v
```

## Troubleshooting

### Claude Code Authentication Issues

If Claude Code fails to authenticate:

1. Ensure your `ANTHROPIC_API_KEY` is set correctly in `.env`
2. Try removing the Claude data volume and restart:
   ```bash
   docker-compose down
   docker volume rm claude_docker_claude-data
   docker-compose up -d
   ```

### GitHub CLI Not Authenticated

```bash
# Inside the container
gh auth login
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
docker-compose -f docker-compose.project1.yml up -d
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
