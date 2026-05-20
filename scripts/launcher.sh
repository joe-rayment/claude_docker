#!/bin/bash

# Claude Docker Launcher (self-bootstrapping)
# Installed to project root as ./claude-dev by bootstrap.sh or curl.
# If .claude-dev/ is missing, the launcher clones the repo automatically.
# Usage:
#   ./claude-dev              Auto-update, build if needed, start if needed, exec in
#   ./claude-dev --update     Force pull latest (bypass rate limit)
#   ./claude-dev --rebuild    Force rebuild (no cache)
#   ./claude-dev --stop       Stop the container
#   ./claude-dev --status     Show container status

set -e

# Colors
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_BOLD="\033[1m"
C_RESET="\033[0m"

# Helper: resolve host home directory for drag-and-drop file access.
# Returns the host $HOME path, or empty string if it conflicts with the container.
resolve_host_home() {
    local home="${HOME:-}"
    # No HOME set
    if [ -z "$home" ]; then
        return 0
    fi
    # Conflict: host home is the same as the container agent home
    if [ "$home" = "/home/agent" ]; then
        echo -e "${C_YELLOW}⚠${C_RESET}  Skipping host home mount: \$HOME (/home/agent) conflicts with container home" >&2
        return 0
    fi
    echo "$home"
}

# Self-discover paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DEV_DIR="$SCRIPT_DIR/.claude-dev"
COMPOSE_FILE="$CLAUDE_DEV_DIR/docker-compose.yml"

# Prereq checks — run early so failures are caught before any work
if ! command -v docker &> /dev/null; then
    echo -e "${C_RED}Error: Docker is not installed${C_RESET}"
    echo "Please install Docker Desktop first:"
    echo "  macOS: brew install --cask docker"
    echo "  Linux: https://docs.docker.com/engine/install/"
    exit 1
fi
if ! docker info &> /dev/null; then
    echo -e "${C_RED}Error: Docker is not running${C_RESET}"
    echo "Please start Docker Desktop and try again"
    exit 1
fi
if ! command -v git &> /dev/null; then
    echo -e "${C_RED}Error: Git is not installed${C_RESET}"
    echo "Please install git first"
    exit 1
fi

# Helper: first-time bootstrap — clone the repo and generate docker-compose.yml
bootstrap_repo() {
    # Derive project names from directory
    local raw_project_name project_name container_name volume_name image_tag
    raw_project_name=$(basename "$SCRIPT_DIR")
    project_name=$(echo "$raw_project_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
    if [ -z "$project_name" ]; then
        project_name="project"
    fi
    container_name="${project_name}-claude-dev"
    volume_name="${project_name}-agent-home"
    image_tag="claude-code-dev:${project_name}"

    # Check for container name collision with a different project
    local existing_workspace
    existing_workspace=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' "$container_name" 2>/dev/null || true)
    if [ -n "$existing_workspace" ] && [ "$existing_workspace" != "$SCRIPT_DIR" ]; then
        echo ""
        echo -e "${C_YELLOW}⚠${C_RESET}  Container '${container_name}' already exists for a different project:"
        echo "   Existing: $existing_workspace"
        echo "   Requested: $SCRIPT_DIR"
        echo ""
        echo "   Options:"
        echo "     1. Stop the existing container first: docker stop $container_name"
        echo "     2. Rename this project directory to get a unique container name"
        exit 1
    fi

    # Clone the repository
    local repo_url="https://github.com/joe-rayment/claude_docker.git"
    echo -e "${C_YELLOW}→${C_RESET} Cloning Claude Docker environment..."
    if ! git clone --quiet "$repo_url" "$CLAUDE_DEV_DIR"; then
        echo -e "${C_RED}Error: Failed to clone repository${C_RESET}"
        exit 1
    fi
    echo -e "${C_GREEN}✓${C_RESET} Repository cloned"

    # Generate docker-compose.yml from template
    if [ -f "$CLAUDE_DEV_DIR/docker-compose.yml.template" ]; then
        local host_home
        host_home=$(resolve_host_home)
        sed -e "s|\${CONTAINER_NAME}|${container_name}|g" \
            -e "s|\${VOLUME_NAME}|${volume_name}|g" \
            -e "s|\${IMAGE_TAG}|${image_tag}|g" \
            -e "s|\${PROJECT_NAME}|${project_name}|g" \
            -e "s|\${HOST_HOME}|${host_home}|g" \
            "$CLAUDE_DEV_DIR/docker-compose.yml.template" > "$COMPOSE_FILE"
        # Remove host home mount line if it was disabled (empty path)
        if [ -z "$host_home" ]; then
            grep -v '^ *- :.*:ro' "$COMPOSE_FILE" > "$COMPOSE_FILE.tmp" && mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"
        fi
        echo -e "${C_GREEN}✓${C_RESET} Generated docker-compose.yml"
    else
        echo -e "${C_RED}Error: docker-compose.yml.template not found in cloned repo${C_RESET}"
        exit 1
    fi

    # Set up .gitignore — only if this directory is itself a git repo top.
    # Skip when inside a parent repo (don't pollute it) or when there's no
    # git context at all (user isn't using git here).
    local git_top
    git_top=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
    if [ "$git_top" = "$SCRIPT_DIR" ]; then
        local gitignore="$SCRIPT_DIR/.gitignore"
        touch "$gitignore"
        local pattern
        for pattern in '.claude-dev/' '/claude-dev' '.mcp.json' '.claude/logs/' 'attachments/'; do
            grep -qxF "$pattern" "$gitignore" || echo "$pattern" >> "$gitignore"
        done
        echo -e "${C_GREEN}✓${C_RESET} Updated .gitignore"
    fi

    # Create attachments directory
    mkdir -p "$SCRIPT_DIR/attachments"

    # Create drops directory on host for file sharing
    mkdir -p "$HOME/claude-drops"

    # Resume: if a previous teardown left a beads snapshot for this project, offer to restore.
    # The entrypoint's ensure_beads() will rebuild the Dolt DB from the restored JSONL on
    # first container start (case B: .beads/ present, Dolt empty → bd doctor --fix --yes).
    local restore_slug state_root latest_snapshot
    restore_slug=$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
    [ -z "$restore_slug" ] && restore_slug="project"
    state_root="$HOME/.claude-dev-state/$restore_slug"
    if [ -d "$state_root" ]; then
        latest_snapshot=$(ls -1 "$state_root" 2>/dev/null | sort -r | head -1)
        if [ -n "$latest_snapshot" ] && [ -f "$state_root/$latest_snapshot/issues.jsonl" ]; then
            echo ""
            echo -e "${C_YELLOW}⚲${C_RESET}  Found previous beads snapshot from ${C_BOLD}$latest_snapshot${C_RESET}"
            echo -n "   Restore beads state for this project? [Y/n] "
            read -r _reply
            if [[ ! "$_reply" =~ ^[Nn]$ ]]; then
                mkdir -p "$SCRIPT_DIR/.beads"
                cp "$state_root/$latest_snapshot/issues.jsonl" "$SCRIPT_DIR/.beads/" 2>/dev/null || true
                [ -f "$state_root/$latest_snapshot/metadata.json" ] && \
                    cp "$state_root/$latest_snapshot/metadata.json" "$SCRIPT_DIR/.beads/" 2>/dev/null || true
                # bd init requires a .git/ in the workspace; create one so the entrypoint
                # can rebuild Dolt from the restored JSONL. This re-creates the nested
                # .git/ that --teardown removed — same trade-off as the initial dev session.
                if ! git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
                    git -C "$SCRIPT_DIR" init --quiet 2>/dev/null || true
                fi
                echo -e "${C_GREEN}✓${C_RESET} Beads snapshot restored — Dolt DB rebuilds on first container start"
            fi
        fi
    fi

    echo ""
    echo -e "${C_GREEN}✓ Bootstrap complete${C_RESET} — continuing with first launch..."
    echo ""
}

# Bootstrap if .claude-dev/ doesn't exist yet
if [ ! -d "$CLAUDE_DEV_DIR" ]; then
    echo -e "${C_BOLD}${C_BLUE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Claude Docker — First-time Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${C_RESET}"
    bootstrap_repo
fi

if [ ! -f "$COMPOSE_FILE" ]; then
    echo -e "${C_RED}Error: docker-compose.yml not found at $COMPOSE_FILE${C_RESET}"
    echo "Run the bootstrap script to regenerate it."
    exit 1
fi

# Read container name and image tag from docker-compose.yml
CONTAINER_NAME=$(grep 'container_name:' "$COMPOSE_FILE" | head -1 | sed 's/.*container_name: *//' | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]')
IMAGE_TAG=$(grep '^\s*image:' "$COMPOSE_FILE" | head -1 | sed 's/.*image: *//' | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]')

if [ -z "$CONTAINER_NAME" ]; then
    echo -e "${C_RED}Error: Could not read container_name from $COMPOSE_FILE${C_RESET}"
    exit 1
fi

IMAGE_TAG="${IMAGE_TAG:-claude-code-dev:latest}"

# Helper: run docker compose with the correct file and project name.
# The -p flag ensures compose operations are scoped to THIS project only,
# preventing one project's compose commands from tearing down another's containers.
# (Without -p, the project name defaults to the directory name "claude-dev",
# which is the same for every project.)
dc() {
    docker compose -f "$COMPOSE_FILE" -p "$CONTAINER_NAME" "$@"
}

# Helper: check if container is running
is_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]
}

# Helper: check if container exists (running or stopped)
container_exists() {
    docker inspect "$CONTAINER_NAME" &>/dev/null
}

# Helper: check if image exists
image_exists() {
    docker image inspect "$IMAGE_TAG" &>/dev/null
}

# Helper: record the current git SHA after a successful build
record_build_sha() {
    git -C "$CLAUDE_DEV_DIR" rev-parse HEAD > "$CLAUDE_DEV_DIR/.last-build-sha" 2>/dev/null || true
}

# Helper: check if repo has changed since last build
repo_has_changed() {
    local current_sha last_build_sha
    current_sha=$(git -C "$CLAUDE_DEV_DIR" rev-parse HEAD 2>/dev/null) || return 1
    last_build_sha=$(cat "$CLAUDE_DEV_DIR/.last-build-sha" 2>/dev/null) || return 0
    [ "$current_sha" != "$last_build_sha" ]
}

# Helper: regenerate docker-compose.yml from template
regenerate_compose() {
    if [ -f "$CLAUDE_DEV_DIR/docker-compose.yml.template" ]; then
        local volume_name project_name host_home
        volume_name=$(grep -A1 '^volumes:' "$COMPOSE_FILE" 2>/dev/null | tail -1 | sed 's/:.*//' | tr -d '[:space:]')
        project_name=$(echo "$CONTAINER_NAME" | sed 's/-claude-dev$//')
        volume_name="${volume_name:-${project_name}-agent-home}"
        host_home=$(resolve_host_home)
        sed -e "s|\${CONTAINER_NAME}|${CONTAINER_NAME}|g" \
            -e "s|\${VOLUME_NAME}|${volume_name}|g" \
            -e "s|\${IMAGE_TAG}|${IMAGE_TAG}|g" \
            -e "s|\${PROJECT_NAME}|${project_name}|g" \
            -e "s|\${HOST_HOME}|${host_home}|g" \
            "$CLAUDE_DEV_DIR/docker-compose.yml.template" > "$COMPOSE_FILE"
        # Remove host home mount line if it was disabled (empty path)
        if [ -z "$host_home" ]; then
            grep -v '^ *- :.*:ro' "$COMPOSE_FILE" > "$COMPOSE_FILE.tmp" && mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"
        fi
        echo -e "${C_GREEN}✓${C_RESET} Regenerated docker-compose.yml"
    fi
}

# Helper: replace launcher on disk and re-exec if it changed
update_launcher_and_restart() {
    local new_launcher="$CLAUDE_DEV_DIR/scripts/launcher.sh"
    local current_launcher="$SCRIPT_DIR/claude-dev"

    if [ -f "$new_launcher" ] && ! cmp -s "$new_launcher" "$current_launcher"; then
        cp "$new_launcher" "$current_launcher"
        chmod +x "$current_launcher"
        echo -e "${C_GREEN}✓${C_RESET} Launcher updated — restarting..."
        exec env _CLAUDE_DEV_SKIP_UPDATE=1 "$current_launcher" "$@"
    fi
}

# Helper: auto-update from upstream (rate-limited, silent on failure)
# Pass "$@" so re-exec preserves the original arguments.
auto_update() {
    local check_file="$CLAUDE_DEV_DIR/.last-update-check"
    local check_interval="${CLAUDE_DEV_UPDATE_INTERVAL:-3600}"  # 1 hour default

    # Disabled by env var
    if [ "$check_interval" = "0" ]; then
        return 0
    fi

    # Rate limit
    if [ -f "$check_file" ]; then
        local last_check now
        last_check=$(cat "$check_file" 2>/dev/null || echo "0")
        now=$(date +%s)
        if [ $((now - last_check)) -lt $check_interval ]; then
            return 0
        fi
    fi

    date +%s > "$check_file" 2>/dev/null || true

    # Fetch silently with 5s timeout — skip on slow/offline networks
    local fetch_ok=false
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 git -C "$CLAUDE_DEV_DIR" fetch --quiet 2>/dev/null && fetch_ok=true
    else
        # Fallback: background fetch with manual kill
        ( git -C "$CLAUDE_DEV_DIR" fetch --quiet 2>/dev/null & GIT_PID=$!
          ( sleep 5 && kill "$GIT_PID" 2>/dev/null ) &
          wait "$GIT_PID" 2>/dev/null
        ) && fetch_ok=true
    fi
    if ! $fetch_ok; then
        return 0
    fi

    local local_sha remote_sha
    local_sha=$(git -C "$CLAUDE_DEV_DIR" rev-parse HEAD 2>/dev/null) || return 0
    remote_sha=$(git -C "$CLAUDE_DEV_DIR" rev-parse origin/main 2>/dev/null) || return 0

    if [ "$local_sha" = "$remote_sha" ]; then
        return 0
    fi

    # Only update if local is behind upstream
    if ! git -C "$CLAUDE_DEV_DIR" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
        return 0
    fi

    # Skip auto-update if someone is editing .claude-dev/ — we'd silently
    # reset --hard their in-progress work otherwise. Explicit ./claude-dev
    # --update still runs (with a confirmation prompt).
    if ! git -C "$CLAUDE_DEV_DIR" diff --quiet HEAD 2>/dev/null; then
        echo -e "\033[2m.claude-dev has local changes — skipping auto-update. Commit or stash to re-enable.\033[0m"
        return 0
    fi

    echo -e "${C_YELLOW}→${C_RESET} Applying update..."
    if ! git -C "$CLAUDE_DEV_DIR" reset --hard --quiet origin/main 2>/dev/null; then
        echo -e "${C_YELLOW}  Warning: git reset failed — continuing with current version${C_RESET}"
        return 0
    fi

    regenerate_compose
    update_launcher_and_restart "$@"
    # If we get here, the launcher didn't change — continue normally
}

# Helper: warn if active Claude sessions are running; returns 1 if user declines teardown
warn_active_sessions() {
    if is_running; then
        local active_sessions
        active_sessions=$(docker exec "$CONTAINER_NAME" sh -c 'ps aux | grep -c "[c]laude"' 2>/dev/null | tr -dc '0-9')
        active_sessions="${active_sessions:-0}"
        if [ "$active_sessions" -gt 0 ]; then
            echo -e "${C_YELLOW}⚠${C_RESET}  ${C_BOLD}${active_sessions} active Claude session(s)${C_RESET} detected in ${CONTAINER_NAME}."
            echo -n "   Tear down container anyway? [y/N] "
            read -r reply
            if [[ ! "$reply" =~ ^[Yy]$ ]]; then
                echo -e "   ${C_YELLOW}Aborted.${C_RESET}"
                return 1
            fi
        fi
    fi
    return 0
}

# Helper: build image
build_image() {
    local extra_args=()
    if [ -n "$1" ]; then
        extra_args+=("$1")
    fi
    local build_sha
    build_sha=$(git -C "$CLAUDE_DEV_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    echo -e "${C_YELLOW}→${C_RESET} Building image..."
    # CLAUDE_CACHEBUST busts the Claude install layer when the repo moves forward,
    # so ./claude-dev --update picks up newly released Claude versions.
    dc build --quiet \
        --build-arg BUILD_SHA="$build_sha" \
        --build-arg CLAUDE_CACHEBUST="$build_sha" \
        "${extra_args[@]}"
    echo -e "${C_GREEN}✓${C_RESET} Image built"
}

# Helper: start container
start_container() {
    echo -e "${C_YELLOW}→${C_RESET} Starting container..."
    dc up -d
    echo -e "${C_GREEN}✓${C_RESET} Container ${C_BOLD}${CONTAINER_NAME}${C_RESET} started"
}

# Helper: exec into container
exec_into() {
    echo -e "${C_GREEN}✓${C_RESET} Entering ${C_BOLD}${CONTAINER_NAME}${C_RESET}..."
    exec docker exec -it "$CONTAINER_NAME" /bin/zsh
}

# --- Commands ---

cmd_default() {
    if [ "${_CLAUDE_DEV_SKIP_UPDATE:-}" != "1" ]; then
        auto_update "$@"
    fi

    # Build if image doesn't exist, or rebuild if repo has changed
    if ! image_exists; then
        echo -e "${C_YELLOW}→${C_RESET} First run — building image (this may take a few minutes)..."
        build_image
        record_build_sha
    elif repo_has_changed; then
        # Check for active sessions before tearing down the container
        if warn_active_sessions; then
            echo -e "${C_YELLOW}→${C_RESET} Environment updated — rebuilding image..."
            if is_running || container_exists; then
                dc down 2>/dev/null || true
            fi
            build_image
            record_build_sha
        fi
        # If warn_active_sessions returned 1 (user declined), skip rebuild and just exec in
    fi

    # Start if not running
    if ! is_running; then
        # If container exists but stopped, remove it first for clean start
        if container_exists; then
            dc down 2>/dev/null || true
        fi
        start_container
    else
        echo -e "${C_GREEN}✓${C_RESET} Container ${C_BOLD}${CONTAINER_NAME}${C_RESET} already running"
    fi

    exec_into
}

cmd_update() {
    echo -e "${C_BOLD}${C_BLUE}Updating claude-dev environment...${C_RESET}"

    # Check for active sessions before tearing down
    if ! warn_active_sessions; then
        return 0
    fi

    # Warn before discarding local edits in .claude-dev/
    if ! git -C "$CLAUDE_DEV_DIR" diff --quiet HEAD 2>/dev/null; then
        echo -e "${C_YELLOW}⚠${C_RESET}  ${C_BOLD}.claude-dev has local changes${C_RESET} that will be discarded by --update."
        echo -n "   Continue and overwrite them? [y/N] "
        read -r reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            echo -e "   ${C_YELLOW}Aborted.${C_RESET} Commit or stash your changes, then re-run --update."
            return 0
        fi
    fi

    # Force pull latest (bypasses rate limit)
    echo -e "${C_YELLOW}→${C_RESET} Pulling latest changes..."
    git -C "$CLAUDE_DEV_DIR" fetch --quiet origin main
    git -C "$CLAUDE_DEV_DIR" reset --hard --quiet origin/main

    # Reset rate-limit timestamp so auto_update doesn't immediately re-check
    date +%s > "$CLAUDE_DEV_DIR/.last-update-check" 2>/dev/null || true

    regenerate_compose

    # Re-copy launcher
    cp "$CLAUDE_DEV_DIR/scripts/launcher.sh" "$SCRIPT_DIR/claude-dev"
    chmod +x "$SCRIPT_DIR/claude-dev"
    echo -e "${C_GREEN}✓${C_RESET} Launcher updated"

    # Rebuild image
    build_image
    record_build_sha

    # Stop old container so next ./claude-dev creates fresh one from new image
    if is_running || container_exists; then
        echo -e "${C_YELLOW}→${C_RESET} Stopping old container..."
        dc down 2>/dev/null || true
    fi

    echo ""
    echo -e "\033[2mNote: Auth, git config, and history are preserved in the volume.\033[0m"
    echo -e "${C_GREEN}✓ Update complete${C_RESET}"

    # Start fresh container and exec in
    start_container
    exec_into
}

cmd_rebuild() {
    echo -e "${C_BOLD}${C_BLUE}Force rebuilding image (no cache)...${C_RESET}"

    # Check for active sessions before tearing down
    if ! warn_active_sessions; then
        return 0
    fi

    # Stop if running
    if is_running || container_exists; then
        echo -e "${C_YELLOW}→${C_RESET} Stopping container..."
        dc down 2>/dev/null || true
    fi

    build_image "--no-cache"
    record_build_sha

    echo ""
    echo -e "\033[2mNote: Auth, git config, and history are preserved in the volume.\033[0m"
    echo -e "${C_GREEN}Rebuild complete.${C_RESET} Run ${C_BOLD}./claude-dev${C_RESET} to start."
}

cmd_stop() {
    if is_running || container_exists; then
        echo -e "${C_YELLOW}→${C_RESET} Stopping container..."
        dc down
        echo -e "${C_GREEN}✓${C_RESET} Container stopped"
    else
        echo -e "${C_YELLOW}Container is not running${C_RESET}"
    fi
}

# Tear down the template artifacts so the project directory can be cleanly pushed
# back to a parent repo. Backs up beads state outside the project tree so it can
# be restored by a future bootstrap. Leaves the Docker volume intact unless --full.
cmd_teardown() {
    local force=false full=false
    shift  # consume "--teardown"
    for _arg in "$@"; do
        case "$_arg" in
            --force) force=true ;;
            --full)  full=true ;;
        esac
    done

    echo -e "${C_BOLD}${C_BLUE}Claude Docker Teardown${C_RESET}"
    echo ""
    echo "This will:"
    echo "  • Back up beads JSONL + metadata to ~/.claude-dev-state/<project>/<timestamp>/"
    echo "  • Stop and remove the container ($CONTAINER_NAME)"
    if $full; then
        echo -e "  • ${C_YELLOW}[--full]${C_RESET} Also remove the Docker volume (auth, plugins, shell history)"
    fi
    echo "  • Remove from this directory:"
    echo "      .git/, .gitignore, .beads/, .claude-dev/, claude-dev,"
    echo "      docker-compose.yml, attachments/, .claude/logs/"
    echo ""

    if ! $force; then
        echo -n "Continue? [y/N] "
        read -r _reply
        if [[ ! "$_reply" =~ ^[Yy]$ ]]; then
            echo -e "${C_YELLOW}Aborted.${C_RESET}"
            return 0
        fi
    fi

    local project_slug timestamp backup_dir
    project_slug=$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
    [ -z "$project_slug" ] && project_slug="project"
    timestamp=$(date +%Y%m%d-%H%M%S)
    backup_dir="$HOME/.claude-dev-state/$project_slug/$timestamp"

    # Flush latest beads state to JSONL while container is still alive
    if [ -d "$SCRIPT_DIR/.beads" ] && is_running; then
        echo -e "${C_YELLOW}→${C_RESET} Flushing beads state to JSONL..."
        docker exec "$CONTAINER_NAME" sh -c 'cd /workspace && bd export 2>/dev/null' || true
    fi

    # Back up beads JSONL + metadata (Dolt DB lives in the volume and rebuilds from JSONL)
    if [ -f "$SCRIPT_DIR/.beads/issues.jsonl" ]; then
        mkdir -p "$backup_dir"
        echo -e "${C_YELLOW}→${C_RESET} Backing up beads to $backup_dir"
        cp "$SCRIPT_DIR/.beads/issues.jsonl" "$backup_dir/" 2>/dev/null || true
        [ -f "$SCRIPT_DIR/.beads/metadata.json" ] && \
            cp "$SCRIPT_DIR/.beads/metadata.json" "$backup_dir/" 2>/dev/null || true
        echo -e "${C_GREEN}✓${C_RESET} Beads snapshot saved"
    fi

    # Stop & remove container
    if container_exists; then
        echo -e "${C_YELLOW}→${C_RESET} Stopping container..."
        dc down 2>/dev/null || true
    fi

    # Optionally remove the Docker volume (destroys auth, plugins, shell history)
    if $full; then
        local volume_name
        volume_name=$(grep -A1 '^volumes:' "$COMPOSE_FILE" 2>/dev/null | tail -1 | sed 's/:.*//' | tr -d '[:space:]')
        if [ -n "$volume_name" ]; then
            echo -e "${C_YELLOW}→${C_RESET} Removing Docker volume $volume_name..."
            docker volume rm "$volume_name" 2>/dev/null || true
        fi
    fi

    # Remove project artifacts. Launcher last so it can finish writing output.
    echo -e "${C_YELLOW}→${C_RESET} Removing template artifacts from project directory..."
    rm -rf "$SCRIPT_DIR/.git"
    rm -f  "$SCRIPT_DIR/.gitignore"
    rm -rf "$SCRIPT_DIR/.beads"
    rm -rf "$SCRIPT_DIR/.claude-dev"
    rm -rf "$SCRIPT_DIR/attachments"
    rm -rf "$SCRIPT_DIR/.claude/logs"
    # Only remove .claude/ if it's empty after logs are gone (preserves user settings if any)
    rmdir "$SCRIPT_DIR/.claude" 2>/dev/null || true
    rm -f  "$COMPOSE_FILE"
    rm -f  "$SCRIPT_DIR/claude-dev"

    echo ""
    echo -e "${C_GREEN}✓ Teardown complete${C_RESET}"
    if [ -d "$backup_dir" ]; then
        echo ""
        echo "Beads state preserved at:"
        echo "  $backup_dir"
    fi
    echo ""
    echo "To resume later, re-run the bootstrap one-liner from this directory:"
    echo "  curl -fsSL https://raw.githubusercontent.com/joe-rayment/claude_docker/main/bootstrap.sh | bash"
    echo ""
}

cmd_status() {
    echo -e "${C_BOLD}Container:${C_RESET} $CONTAINER_NAME"
    local build_sha
    build_sha=$(docker inspect --format='{{index .Config.Labels "build.sha"}}' "$IMAGE_TAG" 2>/dev/null || echo "unknown")
    echo -e "${C_BOLD}Build SHA:${C_RESET} $build_sha"
    if is_running; then
        HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "no healthcheck")
        echo -e "${C_BOLD}Status:${C_RESET}    ${C_GREEN}running${C_RESET} (health: $HEALTH)"
        echo ""
        docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.ID}}\t{{.Status}}\t{{.Ports}}"
    elif container_exists; then
        echo -e "${C_BOLD}Status:${C_RESET}    ${C_YELLOW}stopped${C_RESET}"
    else
        echo -e "${C_BOLD}Status:${C_RESET}    ${C_RED}not created${C_RESET}"
    fi
}

cmd_help() {
    echo -e "${C_BOLD}Claude Docker Launcher${C_RESET}"
    echo ""
    echo "Usage: ./claude-dev [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  (none)       Auto-update, build if needed, start if needed, exec in"
    echo "  --update     Force pull latest (bypass rate limit), rebuild, update launcher"
    echo "  --rebuild    Force rebuild image (no cache)"
    echo "  --stop       Stop the container"
    echo "  --status     Show container status"
    echo "  --teardown   Back up beads, remove template artifacts so the dir is clean to push back"
    echo "               (--force = skip prompt; --full = also remove the Docker volume)"
    echo "  --help       Show this help"
    echo ""
    echo "Environment:"
    echo "  CLAUDE_DEV_UPDATE_INTERVAL   Seconds between update checks (default: 3600, 0=disable)"
}

# --- Main ---

case "${1:-}" in
    --update)     cmd_update ;;
    --rebuild)    cmd_rebuild ;;
    --stop)       cmd_stop ;;
    --status)     cmd_status ;;
    --teardown)   cmd_teardown "$@" ;;
    --help|-h)    cmd_help ;;
    "")           cmd_default ;;
    *)
        echo -e "${C_RED}Unknown option: $1${C_RESET}"
        cmd_help
        exit 1
        ;;
esac
