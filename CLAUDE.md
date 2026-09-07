# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
<!-- beads: rules live in ~/.claude/CLAUDE.md § Beads; markers kept so bd skips re-injection -->
<!-- END BEADS INTEGRATION -->


<!-- BEGIN PROJECT SECTIONS -->
## Build & Test

```bash
./run-tests.sh           # the whole suite
bats tests/*.bats        # the same thing, directly
bats tests/docs.bats     # one file
```

Tests are bats-core, and they run on Linux as well as macOS: the suite stubs
the host tooling (`docker`, `open`, `uname`, `gh`) and exercises the
scripts' logic rather than the Docker daemon itself. The in-container half
is exercised natively — this box is the same Ubuntu arm64 the image is built
on — but containers still cannot run here: Docker on this box dies with
`failed to register layer: unshare: operation not permitted`, no images
cached, user namespaces denied. So `.github/workflows/image.yml` is where the
image is built, smoke-tested and published, and — now that the runtime is
Docker rather than Apple's `container` — it is also where the host-side
launcher is driven end to end against a real daemon (the `e2e` steps: a
throwaway folder, a real container, a real HTTP request to the URL Orca
published). That check was impossible while the runtime ran only on macOS.

## Architecture Overview

One command (`gh api … bootstrap.sh | bash`), run from inside a project
folder, gives that folder **its own Linux container** (on a Mac, inside
Docker Desktop's own Linux VM). `<project>/.claude-dev/` carries the template
clone, `bin/claude-dev`, the folder's `claude-orca.json` and the `home/` that
becomes the agent's home directory. There is no central install and nothing
on the Mac runs an agent.

The boundary is the container's. `claude-dev` runs one Docker container per
folder from `ghcr.io/joe-rayment/claude_orca` (pinned by the `IMAGE_TAG` file),
mounting the project at its own absolute path and `.claude-dev/home` as
`/home/agent`, publishing Orca's port on `127.0.0.1` only. The image carries
only what a bind mount cannot: apt state — the base packages, node, gh and
the libraries Orca links against (`setup.sh`'s `IMAGE_PHASES`). The toolchain
proper — Orca, Claude Code, opencode, bd, dolt, bats — installs on a folder's
first start into `<project>/.claude-dev/toolchain`, mounted over `/usr/local`,
`/opt/Orca` and `/opt/claude`, so it is installed once per folder, survives
every recreate, and can be read and deleted from the Mac. What a recreate
then costs depends on the image (measured on a Mac, 2026-09-07): with the
prebuilt one, 3.7 s against ~11 minutes before, because both halves are
already in hand; on the runtime path (`ubuntu:24.04`, where a token without
`read:packages` lands a folder) 4m40s, because the apt half is reinstalled
every time — dpkg state is exactly what a bind mount cannot carry. First
starts pay ~3 minutes more than they used to on that path: 1.3 GB of
toolchain now lands in the folder over virtiofs rather than in the image. `setup.sh --check` is what says the two halves add up
to the same filesystem the fully baked image used to hand over. Inside,
`scripts/container/entrypoint.sh` runs as PID 1, drops to the `agent` user,
config-syncs, and starts `orca-ide --serve`; it writes the browser URL to
`run/orca-web-url.txt` (mode 600 — the fragment carries a pairing code),
which is the handshake the Mac side waits on before calling `open`. Claude
Code signs in on its own first run inside Orca. Registration seeds the stack
this template assumes — Claude Code as the master, low-cost OpenRouter models
as delegate-route workers, and Orca's native coordination, which needs no
opt-in now that Orca runs in the container.

`HOME` is `<project>/.claude-dev/home`, whose `.claude` config dir is
populated from this repo's `config/` by a checksum-gated sync that preserves
Orca's own managed hook entries (status dots, sub-agent rows). One directory
under that home is NOT the folder's: Orca's `--user-data-dir`
(`~/.config/orca`) is a docker volume named after the container, because a
macOS bind mount cannot `chmod` or `link` a unix socket and that is where
Orca puts its RPC and daemon sockets — on the folder home it never publishes
a web URL at all. `./claude-dev --teardown` removes the volume with the
container, so the state still dies with the folder. The hook/guard
suite (lane, tier, bd-guard, outbound-guard, auth-guard, contract-gate,
cost-mirror…) runs from there. `/tier` state lives in
`.claude-dev/run/tier.json` and is injected into sub-agent spawns by a
`PreToolUse` hook rather than written into agent frontmatter, because
config-sync owns those files.

## Conventions & Patterns

- **bash 3.2 on the Mac side.** macOS ships 3.2.57, so `bootstrap.sh` and
  `scripts/launcher.sh` stay inside it: no associative arrays, no `mapfile`,
  no `${x^^}`, no `+=` onto an empty array under `set -u`.
  `scripts/lint-bash32.sh` and a real 3.2 build in the suite enforce it.
  `scripts/container/*` runs only in the image and is not bound by this.
- **Paths come from `scripts/lib/paths.sh`.** Never hard-code `~/.claude`,
  the host dir, or a project path; resolve through the helpers so the same
  script works from a repo checkout and from the
  `<project>/.claude-dev/template` clone a folder actually runs.
- **`run/` holds results, `state/` holds authority.** What the agent side
  writes (tier state, the config-sync hash, the web URL, the port) lives in
  `.claude-dev/run`; anything the Mac side treats as authority lives in
  `.claude-dev/state`.
- **Frozen contracts.** A bead's `FROZEN` files are frozen from its `RED-AT`
  commit onward: the test is committed red first, the implementation second,
  and the test is never edited to make an implementation pass.
- **The Mac side executes nothing it did not ship.** `claude-orca.json` is
  read as validated data through `jq`, never sourced and never run.
<!-- END PROJECT SECTIONS -->
