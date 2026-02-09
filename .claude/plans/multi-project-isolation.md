# Multi-Project Container Isolation

## The Problem

When a user bootstraps this template into two different projects on the same machine and tries to work on both simultaneously, one of two things happens:

1. **If they use the root `docker-compose.yml` directly:** Both projects get container name `claude-dev-environment` and volume `agent-home` — Docker refuses to start the second container, or worse, both projects silently share the same home volume and bleed state into each other.

2. **If they use `bootstrap.sh` (the intended path):** Container and volume names *are* project-specific (`myproject-claude-dev`, `myproject-agent-home`), but there's no visual indicator of which project a terminal session belongs to. With multiple terminals open, it's easy to run commands in the wrong project's container.

The bootstrap path is close to correct but has gaps. The root compose file is fundamentally broken for multi-project use. And there's nothing to help users tell their containers apart visually.

---

## Root Causes

### 1. Root `docker-compose.yml` uses hardcoded names

| File | Line | Hardcoded Value | Conflict Type |
|------|------|-----------------|---------------|
| `docker-compose.yml` | 6 | `image: claude-code-dev:latest` | Image tag collision |
| `docker-compose.yml` | 7 | `container_name: claude-dev-environment` | Container name collision |
| `docker-compose.yml` | 18, 38 | `agent-home` volume | Volume sharing — full state leakage |

This file exists alongside the template system but doesn't participate in it. Anyone who runs `docker compose up` from the repo root (a natural thing to try) gets a singleton container.

### 2. No project identity inside the container

Once you `docker exec` into a container, nothing tells you which project you're in. The shell prompt, welcome screen, and window title are all generic. With two terminals open to two different project containers, they look identical.

Relevant gaps:
- `container-welcome.sh` header says "Claude Code Development Container" — no project name
- The zsh prompt (Pure theme) shows only the current directory, not the project/container identity
- No terminal title is set
- `dev-log.sh` labels entries with `agent` — no project distinction

### 3. The volume model is all-or-nothing

The entire `/home/agent` is a single Docker volume. This bundles together things that *should* be shared across projects (user auth, git identity) with things that *must not* be shared (shell history, debug logs, session state). The bootstrap path correctly gives each project its own volume, so this isn't a collision issue — but it means users re-authenticate Claude and GitHub for every new project, which is friction.

---

## Plan

### Change 1: Make the root `docker-compose.yml` project-aware

**Problem:** Hardcoded names cause collisions.

**Fix:** Replace hardcoded values with environment variables that default to the current directory name, matching what `bootstrap.sh` already does for the template path.

```yaml
services:
  claude-dev:
    image: claude-code-dev:${PROJECT_NAME:-default}
    container_name: ${PROJECT_NAME:-default}-claude-dev
    volumes:
      - ${PROJECT_PATH:-.}/:/workspace
      - ${PROJECT_NAME:-default}-agent-home:/home/agent

volumes:
  ${PROJECT_NAME:-default}-agent-home:
    driver: local
```

**Complication:** Docker Compose doesn't support variable interpolation in volume *definition* keys (`volumes:` top-level block). Two options:

- **Option A (recommended):** Add a thin wrapper script (`dc.sh` or similar) that sets `PROJECT_NAME` from `basename "$PWD"` and invokes `docker compose`. The root compose file becomes a convenience entry point that works correctly by default.
- **Option B:** Add a `.env` file with `PROJECT_NAME` and document that users must set it. Fragile — users will forget.
- **Option C:** Remove the root `docker-compose.yml` entirely and make `bootstrap.sh` the only entry point. Add a clear error/redirect if someone tries `docker compose up` from the repo root.

**Recommendation:** Option C. The root compose file is a trap. Remove it and replace with a `docker-compose.yml` that prints an error message telling users to use `bootstrap.sh`. This eliminates the collision vector entirely.

```yaml
# This file exists only to catch accidental 'docker compose up' invocations.
# Use bootstrap.sh to set up a project-specific container:
#   gh api repos/joe-rayment/claude_docker/contents/bootstrap.sh \
#     -H "Accept: application/vnd.github.raw" | bash
services:
  claude-dev:
    image: alpine:latest
    command: >
      sh -c 'echo "ERROR: Use bootstrap.sh to create project containers.
      See README for instructions." && exit 1'
```

**Files:** `docker-compose.yml`

### Change 2: Inject project name into the container environment

**Problem:** No way to identify which project a container belongs to, inside or outside.

**Fix:** Pass the project name as an environment variable so scripts inside the container can use it.

In `docker-compose.yml.template`, add:
```yaml
environment:
  - CLAUDE_PROJECT_NAME=${PROJECT_NAME}
```

In `bootstrap.sh`, this is already exported — the template substitution will pick it up.

**Files:** `docker-compose.yml.template`, `bootstrap.sh` (already exports `PROJECT_NAME`)

### Change 3: Show project name in the welcome screen and prompt

**Problem:** Multiple terminals to different containers look identical.

**Fix:** Use `CLAUDE_PROJECT_NAME` to brand the container session.

#### 3a. Welcome screen (`container-welcome.sh`)

Replace the generic header:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Claude Code Development Container
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

With the project-branded version:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  myproject — Claude Dev
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

If `CLAUDE_PROJECT_NAME` is unset, fall back to the generic title.

The `figlet` path should also include the project name (or skip figlet and use the consistent box format for predictability).

#### 3b. Terminal title (`.zshrc`)

Add to `.zshrc` before the welcome call:
```bash
# Set terminal title to project name for easy tab identification
if [ -n "$CLAUDE_PROJECT_NAME" ]; then
    print -Pn "\e]0;${CLAUDE_PROJECT_NAME} — Claude Dev\a"
fi
```

This sets the terminal tab/window title. Users with multiple terminal tabs will see the project name in each tab.

#### 3c. Shell prompt hint

The Pure prompt theme shows the current directory. To avoid fighting with Pure's configuration, add a lightweight right-prompt or precmd that shows the project name:

```bash
# Show project name in prompt if set
if [ -n "$CLAUDE_PROJECT_NAME" ]; then
    export RPROMPT="%F{blue}[$CLAUDE_PROJECT_NAME]%f"
fi
```

This puts `[myproject]` on the right side of every prompt line, always visible, out of the way.

#### 3d. Compact command hint for returning sessions

The returning-session one-liner in `container-welcome.sh` (line 41) should also include the project name:

```
[myproject] Commands: menu (setup)  cs (claude)
```

**Files:** `scripts/container-welcome.sh`, `config/.zshrc`

### Change 4: Tag dev-log entries with project name

**Problem:** If logs from multiple containers ever get mixed (shared workspace mount, exported logs), entries are indistinguishable.

**Fix:** In `dev-log.sh`, include the project name in log entries:

```bash
AGENT="${CLAUDE_AGENT_NAME:-${CLAUDE_PROJECT_NAME:-$(whoami)}}"
```

This uses the project name as the default agent identifier, so log lines read:
```
2026-02-09T12:00:00 [myproject] RUN: npm test → PASS
```

Instead of:
```
2026-02-09T12:00:00 [agent] RUN: npm test → PASS
```

**Files:** `scripts/dev-log.sh`

### Change 5: Validate project name in bootstrap.sh

**Problem:** Edge cases in project name sanitization could produce collisions (e.g., two directories that sanitize to the same slug).

**Fix:** After sanitizing, check if a container with that name is already running for a *different* project path. If so, warn the user.

Add after line 88 in `bootstrap.sh`:
```bash
# Check for container name collision with a different project
EXISTING_WORKSPACE=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)
if [ -n "$EXISTING_WORKSPACE" ] && [ "$EXISTING_WORKSPACE" != "$PROJECT_DIR" ]; then
    echo -e "${C_YELLOW}⚠${C_RESET}  Container '${CONTAINER_NAME}' already exists for a different project:"
    echo "   Existing: $EXISTING_WORKSPACE"
    echo "   Requested: $PROJECT_DIR"
    echo ""
    echo "   Options:"
    echo "     1. Stop the existing container first: docker stop $CONTAINER_NAME"
    echo "     2. Rename this project directory to get a unique container name"
    exit 1
fi
```

**Files:** `bootstrap.sh`

### Change 6: Document the multi-project model

**Problem:** Nothing explains that each project gets its own container, or how the naming works.

**Fix:** Add a section to the README (or CLAUDE.md) covering:
- Each project gets its own container, volume, and image tag
- Container naming convention: `{project-dir}-claude-dev`
- How to run multiple projects simultaneously
- How to list/manage running containers: `docker ps --filter "name=-claude-dev"`
- That auth credentials (Claude, GitHub) are per-volume and must be set up in each project container

**Files:** README.md or CLAUDE.md (documentation only)

---

## What NOT to change

### Volume splitting (auth sharing across projects)

It's tempting to split the `/home/agent` volume into "shared auth" and "project-specific state" volumes. Don't do this yet. Reasons:

- Adds significant Docker complexity (multiple named volumes, mount orchestration)
- Auth re-setup per project is a minor annoyance, not a blocker
- The current model (one volume per project) is simple and correct for isolation
- Can be revisited later if users report auth friction as a real pain point

### Port isolation

No ports are exposed in any compose file, so there are no port conflicts. No change needed.

### Network isolation

Each project's `docker compose up -d` creates its own default network scoped to the compose project. No change needed.

---

## Implementation Order

1. **Change 2** (inject env var) — foundation for everything else, no visible behavior change
2. **Change 3** (welcome screen + prompt + title) — immediate user-visible improvement
3. **Change 4** (dev-log tagging) — small, complements Change 3
4. **Change 1** (root compose file) — removes the collision trap
5. **Change 5** (collision detection) — safety net
6. **Change 6** (documentation) — last, after behavior is finalized

## Files Changed (summary)

| File | Changes |
|------|---------|
| `docker-compose.yml` | Replace with error-guard or remove |
| `docker-compose.yml.template` | Add `CLAUDE_PROJECT_NAME` env var |
| `bootstrap.sh` | Add collision detection |
| `scripts/container-welcome.sh` | Show project name in header and compact hint |
| `scripts/dev-log.sh` | Use project name in log entries |
| `config/.zshrc` | Set terminal title and RPROMPT with project name |
| `tests/experience.bats` | Update assertions for new header text |
| README.md / CLAUDE.md | Document multi-project usage |

## Testing

- Bootstrap two projects with different names → verify unique container names, volumes, image tags
- Run both simultaneously → verify both containers stay up, no collisions
- `docker exec` into each → verify welcome screen shows correct project name
- Check terminal title shows project name
- Check prompt RPROMPT shows project name
- Run `dev-log run "test" pass "reason"` in each → verify entries tagged with correct project
- Run `docker compose up` from repo root → verify error/redirect message
- Bootstrap two projects with names that sanitize identically (e.g., `My-App` and `my_app`) → verify collision warning
