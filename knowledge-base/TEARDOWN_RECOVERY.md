# Teardown and Resume

For when the template lives in a subdirectory of a larger git repo and needs to be removed before pushing back, then restored later.

## Why teardown is needed

`bd init` creates a nested `.git/` in the template directory so beads can sync. The parent repo then treats the subdir as an embedded sub-repo and blocks `git add` from the parent.

## Teardown (run on the HOST, not in the container)

```bash
./claude-dev --teardown
```

What it does:

1. Backs up `.beads/issues.jsonl` to `~/.claude-dev-state/<project>/<timestamp>/`
2. Removes template artifacts: `.git/`, `.gitignore`, `.beads/`, `.claude-dev/`, `claude-dev`, `docker-compose.yml`, `attachments/`, `.claude/logs/`

The directory is then safe to `git add` from the parent repo.

## Resume

Re-run the bootstrap in the same directory:

```bash
gh api repos/joe-rayment/claude_docker/contents/bootstrap.sh -H "Accept: application/vnd.github.raw" | bash
```

It detects the snapshot under `~/.claude-dev-state/<project>/` and restores it automatically, with no prompt — the project has no `.beads/issues.jsonl` of its own at this point (teardown removed it), so there is nothing to lose. A confirmation appears only in the ambiguous case, when the project already has its own `issues.jsonl` (e.g. a fresh clone that came with one); non-interactively that case defaults to keeping the existing data rather than overwriting. The embedded Dolt database rebuilds from the restored `issues.jsonl` on first container start — no manual import needed.

## Gotchas

| Symptom | Fix |
|---------|-----|
| Snapshot not offered on resume | Check `~/.claude-dev-state/<project>/` exists on the host; restore manually by copying `issues.jsonl` into `/workspace/.beads/` before first start |
| Beads empty after restore | Run `bd init --prefix <p> --quiet --non-interactive && bd import` to force a rebuild from JSONL (`bd doctor` is unsupported in embedded mode); if `bd init` refuses ("already initialized"), `rm -rf .beads/embeddeddolt` first — see knowledge-base/BEADS_TROUBLESHOOTING.md |
| Parent repo still blocks `git add` | A nested `.git/` survived — confirm teardown ran from the template subdir, remove leftover `.git/` manually |
