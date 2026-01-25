# Future Improvements

Notes on barriers and friction points for new users.

## Current Friction Points

### 1. Volume Persistence Overwrites Config Updates
When rebuilding the image, the `agent-home` volume persists old config files (`.zshrc`, etc.). New users who rebuild won't get updated configs unless they delete the volume.

**Workaround**: `docker compose down -v` before rebuild
**Fix**: Entrypoint script should check and update configs, or use a version marker

### 2. Container Name Conflict
`container_name: claude-dev-environment` is hardcoded. Running multiple projects simultaneously will fail.

**Workaround**: Use different compose files with different container names
**Fix**: Remove hardcoded container name or make it configurable via .env

### 3. Volume Name Conflict
`agent-home` volume is shared across all instances using this compose file. Different projects will share Claude auth, git config, shell history.

**Workaround**: This might actually be desirable (shared auth). But if isolation needed, change volume name per project.
**Fix**: Make volume name configurable or use project-specific naming

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

- [ ] `./setup.sh` script that handles first-time setup interactively
- [ ] Health check to verify Claude auth status on container start
- [ ] Automatic `.env` creation from `.env.example` if missing
- [ ] Support for multiple concurrent projects (unique container/volume names)
- [ ] Pre-built image on Docker Hub to skip build step
