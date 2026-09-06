# Startup v4 — the container installs and seeds itself

Epic claude-orca-qa2 follow-on, 2026-09-06. Rule (user, 2026-09-06): the
stages that cannot run on this box — bootstrap.sh, launcher.sh, the image
build — stay thin; every piece of logic that can run inside the running
container moves there, where `scripts/container/*` is exercised natively
(bats) and in a real Ubuntu 24.04 chroot (`verify-rootfs.sh`).

## What moves, and where it comes from

| Today (Mac side, stub-tested only)                | v4 (inside the container, run for real)                         |
|---------------------------------------------------|-----------------------------------------------------------------|
| Dockerfile RUN steps (now `setup.sh` at build)    | entrypoint runs `setup.sh` at every start, as root, before the privilege drop; on the prebuilt image it is a no-op in seconds, on a base image it installs the toolchain (first start only) |
| `container build` fallback on the Mac             | gone. No prebuilt image reachable ⇒ run `docker.io/library/ubuntu:24.04` with the mounted template's entrypoint; `setup.sh` installs at first start |
| `seed_gitignore`                                  | entrypoint, same entries and marker                             |
| `mkdir attachments`                               | entrypoint                                                      |
| `restore_beads_snapshot`                          | entrypoint, before `bd init`                                     |
| `seed_git_identity` (the write)                   | entrypoint writes `/home/agent/.gitconfig` from `CLAUDE_ORCA_GIT_NAME` / `CLAUDE_ORCA_GIT_EMAIL`; the Mac only reads its global git config and passes the two values as env |
| `ensure_packages_scope` (`gh auth refresh`), DNS retry, stale-credential retry | gone: unverifiable Mac-side code the base-image path makes unnecessary |

Stays on the Mac (it cannot run anywhere else): dependency install in
bootstrap, template clone, `./claude-dev` stub, `claude-orca.json`
defaults, port choice, registry login + pull when the token has
read:packages, `container run`, wait for the web URL, `open`.

## Contract between the two halves

`container run` env: `PROJECT_DIR`, `ORCA_PORT`, `HOST_UID`, `GH_TOKEN`,
`CLAUDE_ORCA_THEME`, `CLAUDE_ORCA_PROJECT_NAME`, `OPENROUTER_API_KEY`
(optional) — plus new `CLAUDE_ORCA_GIT_NAME`, `CLAUDE_ORCA_GIT_EMAIL`
(optional, may be empty). Mounts: the project at its own absolute path,
`.claude-dev/home` at `/home/agent`.

Entrypoint template root: `/opt/claude-orca` when present (prebuilt
image), else `$PROJECT_DIR/.claude-dev/template` (base image). `setup.sh`
is taken from the same root. On the base image the command is
`bash <template>/scripts/container/entrypoint.sh` (no tini; the
entrypoint already waits on Orca as PID 1).

## Slices

- **S1 (container side)** — entrypoint: setup step (`run/setup.log`, a
  one-line "first start installs the toolchain" notice), template-root
  resolution, the four seedings. Native bats cases; `verify-rootfs.sh`
  unchanged (it already proves `setup.sh`).
- **S2 (Mac side + CI)** — launcher: git identity env, remove the moved
  seedings, `acquire_image` = pull when scoped else base image; no
  `container build`, no refresh prompt, no retries. image.yml: a second
  smoke stage that runs `smoke.sh` inside plain `ubuntu:24.04` with the
  checkout mounted, proving the runtime-install path end to end.

Sequential: S1 then S2. Each has a CHECK/PASS-IF/FROZEN/CLASS contract on
its bead; verifier per slice.
