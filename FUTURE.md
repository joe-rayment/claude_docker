# Future Improvements

Notes on barriers and friction points for new users.

## Current Friction Points

### 1. Volume Persistence Overwrites Config Updates
When rebuilding the image, the `agent-home` volume persists old config files (`.zshrc`, etc.). New users who rebuild won't get updated configs unless they delete the volume.

**Workaround**: `docker compose down -v` before rebuild
**Fix**: Entrypoint script should check and update configs, or use a version marker

### ~~2. Container Name Conflict~~ ✅ RESOLVED
Bootstrap now generates unique container names from the project directory name (e.g. `myproject-claude-dev`).

### ~~3. Volume Name Conflict~~ ✅ RESOLVED
Bootstrap now generates unique volume names from the project directory name (e.g. `myproject-agent-home`).

### 4. No Validation of PROJECT_PATH
If PROJECT_PATH is invalid or doesn't exist, Docker will create an empty directory.

**Fix**: Add validation in entrypoint or a setup script

### 5. Claude Auth Required Every Fresh Start
After `docker compose down -v`, need to re-auth Claude.

**Workaround**: Don't use `-v` unless necessary
**Fix**: Document this clearly, or provide auth persistence outside the volume

### 6. Git Config Not Persisted Outside Volume
If volume is removed, git user.name/email must be reconfigured.

**Fix**: Same as above - document or persist differently

### 7. First-Time Docker Users
No guidance on Docker Desktop installation verification (is it running?).

**Fix**: Add troubleshooting section for "docker: command not found" and "Cannot connect to Docker daemon"

### 8. M1/M2 Mac vs Intel
Helix binary selection handles this, but not tested on all architectures.

**Fix**: Test on Intel Mac, document any issues

## Nice-to-Have Features

- [x] ~~`./setup.sh` script that handles first-time setup interactively~~ — Superseded by `./claude-dev` launcher
- [ ] Health check to verify Claude auth status on container start
- [ ] Automatic `.env` creation from `.env.example` if missing
- [x] ~~Support for multiple concurrent projects (unique container/volume names)~~ — Done via bootstrap naming
- [ ] Pre-built image on Docker Hub to skip build step
