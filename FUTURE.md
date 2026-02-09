# Future Improvements

Notes on barriers and friction points for new users.

## Current Friction Points

### ~~1. Volume Persistence Overwrites Config Updates~~ ✅ RESOLVED
Entrypoint now compares `CONFIG_VERSION` baked into the image against a version marker in the volume. Configs are updated automatically when the image is newer.

### ~~2. Container Name Conflict~~ ✅ RESOLVED
Bootstrap now generates unique container names from the project directory name (e.g. `myproject-claude-dev`).

### ~~3. Volume Name Conflict~~ ✅ RESOLVED
Bootstrap now generates unique volume names from the project directory name (e.g. `myproject-agent-home`).

### ~~4. No Validation of PROJECT_PATH~~ ✅ RESOLVED
Entrypoint now warns if `/workspace` is empty (project may not be mounted).

### ~~5. Claude Auth Required Every Fresh Start~~ ✅ RESOLVED
Auth, git config, and history are preserved in the named volume. Update and rebuild commands now display a note confirming this. Only `docker compose down -v` removes them.

### ~~6. Git Config Not Persisted Outside Volume~~ ✅ RESOLVED
Same as #5 — git config lives in the persistent volume. Update/rebuild notes clarify this.

### ~~7. First-Time Docker Users~~ ✅ RESOLVED
Bootstrap checks for Docker installation and running state. README troubleshooting covers "docker: command not found" and "Cannot connect to Docker daemon".

### 8. M1/M2 Mac vs Intel
Helix binary selection handles this, but not tested on all architectures.

**Fix**: Test on Intel Mac, document any issues

## Nice-to-Have Features

- [x] ~~`./setup.sh` script that handles first-time setup interactively~~ — Superseded by `./claude-dev` launcher
- [x] ~~Health check to verify Claude auth status on container start~~ — Added via Docker healthcheck in compose
- [x] ~~Automatic `.env` creation from `.env.example` if missing~~ — Documented in README Manual Setup
- [x] ~~Support for multiple concurrent projects (unique container/volume names)~~ — Done via bootstrap naming
- [ ] Pre-built image on Docker Hub to skip build step
- [x] ~~Voicetree spatial IDE integration~~ — Removed; added agent teams + dev-log instead
- [x] ~~Agent teams support~~ — Enabled via `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` + tmux mode
- [x] ~~Structured development logging~~ — `dev-log` with four category files
- [x] ~~Experience testing~~ — bats-core smoke + experience tests
