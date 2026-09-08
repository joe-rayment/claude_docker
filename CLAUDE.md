# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
<!-- beads: rules live in ~/.claude/CLAUDE.md § Beads; markers kept so bd skips re-injection -->
<!-- END BEADS INTEGRATION -->


<!-- BEGIN PROJECT SECTIONS -->
## Build & Test

```bash
./run-tests.sh           # the fast subset -- the everyday run, ~2 minutes
./run-tests.sh --all     # every file, ~8 minutes (CLAUDE_ORCA_TEST_ALL=1 does the same)
bats tests/*.bats        # the whole suite, directly
bats tests/docs.bats     # one file
```

The default run skips the dozen-odd files that stand up real processes or
churn through big fixtures -- the slow set was picked by timing every file,
and `run-tests.sh` names it in `SLOW_FILES` and prints how many it skipped.
There is no CI in this repo: `.github/workflows/image.yml` used to build and
publish the image on every push to main and run its own smoke and e2e
checks, but once the image stopped being pulled from a registry and started
being built on the machine that runs it, there was nothing left for a
shared workflow to gate -- a red test must never stop a fix from reaching
the machine that needs it, and neither should a build nobody but that
machine can act on. `scripts/container/smoke.sh` (the image's own check) and
`tests/mac-e2e.sh` (the host-side launcher against a real daemon) are both
run by hand now, on demand, against a real Mac.

Tests are bats-core, and they run on Linux as well as macOS: the suite stubs
the host tooling (`docker`, `open`, `uname`, `gh`) and exercises the
scripts' logic rather than the Docker daemon itself. The in-container half
is exercised natively — this box is the same Ubuntu arm64 the image is built
on — but containers still cannot run here: Docker on this box dies with
`failed to register layer: unshare: operation not permitted`, no images
cached, user namespaces denied. So proving the image itself, and the
host-side launcher against a real daemon (a throwaway folder, a real
container, a real HTTP request to the URL Orca published), is
`tests/mac-e2e.sh`'s job -- see "Definition of done for host-side changes"
below.

## Architecture Overview

One command (`gh api … bootstrap.sh | bash`), run from inside a project
folder, gives that folder **its own Linux container** (on a Mac, inside
Docker Desktop's own Linux VM). `<project>/.claude-dev/` carries the template
clone, `bin/claude-dev`, the folder's `claude-orca.json` and the `home/` that
becomes the agent's home directory. There is no central install and nothing
on the Mac runs an agent.

The boundary is the container's. `claude-dev` runs one Docker container per
folder from an image built on that machine (`claude-orca`, pinned by the
`IMAGE_TAG` file; `CLAUDE_ORCA_IMAGE_REPO`/`CLAUDE_ORCA_IMAGE` override it),
mounting the project at **`/workspace/<name>`** and `.claude-dev/home` as
`/home/agent`, publishing Orca's port on `127.0.0.1` only. The project used
to be mounted at its own Mac path so that paths meant the same thing on both
sides; the price was a container that spelled out its owner's home directory
and folder tree at every prompt, which reads as no sandbox at all. Everything
inside takes the path from `PROJECT_DIR`, so nothing needed them to agree;
the Mac path still rides in as `CLAUDE_ORCA_HOST_PROJECT_DIR` for messages
that name a file to open on the Mac, and `BEADS_DIR` names the folder's
tracker so `bd` answers from any directory.

The image carries the whole install: apt state (`setup.sh`'s `IMAGE_PHASES`)
plus the payload — Orca, Claude Code, opencode, bd, dolt, bats — one
Docker layer per phase, rarest-changing first, with the repo copy below them
so editing a script rebuilds no payload layer. That payload was briefly
installed per folder into `<project>/.claude-dev/toolchain` instead, and the
measurement that ended the experiment was a first start of ~18 minutes on a
real Mac, 15.5 of them downloading 1.3 GB at 2.5 MB/s, once per folder,
shared with no other folder — the job Docker's layer cache does for every
folder at once. (It also made the macOS CI job impossible: colima's virtiofs
refuses the `chown` into a bind mount.) A folder still carries a toolchain on
the **runtime path** — plain `ubuntu:24.04`, where a folder lands when the
local `docker build` cannot run or fails — because there is no baked
anything to reuse there.
`setup.sh --check` is what says the image is the filesystem it promised.
Inside,
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

## Definition of done for host-side changes

A change to `bootstrap.sh`, `scripts/launcher.sh`, the `Dockerfile`, or
anything under `scripts/container/` is done only when `tests/mac-e2e.sh`
has been run on a Mac against that
change, and its summary table is pasted into the commit message or the
bead. A green bats suite is not evidence for the Mac path: the suite
stubs `docker`, `open`, `gh` and `uname`, so it proves the launcher's
logic and nothing about a Mac. If no Mac is available, the change is
UNVERIFIED and the commit subject has to say so.

Two things follow from that, and both were learned the expensive way in
the first week of September 2026:

- **`mac-e2e.sh` clones HEAD**, because bootstrap does. Commit before you
  run it, or you are testing the commit before the one you just made.
- **A measurement beats a plausible argument.** The toolchain was moved
  out of the image on a sound-looking argument about bind mounts and cost
  ~15 minutes per folder; the first real build of the image that carries
  it was 7.84 GB because nobody had read `docker history`. Both were
  found by running the thing once.

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
