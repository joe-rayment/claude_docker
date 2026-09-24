# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
<!-- beads: rules live in ~/.claude/CLAUDE.md § Beads; markers kept so bd skips re-injection -->
<!-- END BEADS INTEGRATION -->


<!-- BEGIN PROJECT SECTIONS -->
## Build & Test

```bash
./run-tests.sh           # the fast subset -- the everyday run, ~2 minutes
./run-tests.sh --all     # every file, ~4 minutes (CLAUDE_ORCA_TEST_ALL=1 does the same)
bats tests/*.bats        # the whole suite, directly
bats tests/docs.bats     # one file
bats -f 'git push' tests/outbound-guard.bats   # only the cases whose name contains "git push"
```

**The full suite is the user's to run** -- by hand, or by asking (`/test`
runs it and explains every failure in plain English). While working, run
only the file(s) covering what you changed, and say what each one guards
when you report it. A red file you did not touch is one line in your
reply, never work. `tests/INDEX.md` says, for every file, what it guards,
whether it checks behavior or only wording, and how to read a failure.

The default run skips the dozen-odd files that stand up real processes or
churn through big fixtures -- the slow set was picked by timing every file,
and `run-tests.sh` names it in `SLOW_FILES` and prints how many it skipped.
Both times assume GNU `parallel` (`brew install parallel`), which lets
`run-tests.sh` run files side by side; one file at a time they are ~8 and
~15 minutes on a 4-core Linux box.
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
becomes the agent's home directory. There is no central install; nothing on
the Mac runs an agent.

The boundary is the container's. `claude-dev` runs one Docker container per
folder from an image built on that machine (`claude-orca`, pinned by the
`IMAGE_TAG` file; `CLAUDE_ORCA_IMAGE_REPO`/`CLAUDE_ORCA_IMAGE` override it),
mounting the project at **`/workspace/<name>`** and `.claude-dev/home` as
`/home/agent`, publishing Orca's port on `127.0.0.1` only. The project used
to be mounted at its own Mac path so paths meant the same thing on both
sides; the price was a container that spelled out its owner's home directory
and folder tree at every prompt — no sandbox at all. Everything
inside takes the path from `PROJECT_DIR`, so nothing needed them to agree;
the Mac path still rides in as `CLAUDE_ORCA_HOST_PROJECT_DIR` for messages
that name a file to open on the Mac, and `BEADS_DIR` names the folder's
tracker so `bd` answers from any directory.

The image carries the whole install: apt state (`setup.sh`'s `IMAGE_PHASES`)
plus the payload — Orca, opencode, bd, dolt, bats — one
Docker layer per phase, rarest-changing first, with the repo copy below them
so editing a script rebuilds no payload layer. That payload was briefly
installed per folder into `<project>/.claude-dev/toolchain` instead; the
measurement that ended the experiment was an ~18-minute first start — 15.5
of them downloading 1.3 GB at 2.5 MB/s — once per folder, shared with no
other folder, the job Docker's layer cache does for every folder at once.
Claude Code is the exception: `provision.d/15-claude-on-path` installs the
latest natively into the folder's home, where `claude update` updates it.
A folder still carries a toolchain on
the **runtime path** — plain `ubuntu:24.04`, where a folder lands when the
local `docker build` cannot run or fails — because there is no baked
anything to reuse there.
`setup.sh --check` is what says the image is the filesystem it promised.
Inside,
`scripts/container/entrypoint.sh` runs as PID 1, drops to the `agent` user,
and starts `orca-ide --serve`; it writes the browser URL to
`run/orca-web-url.txt` (mode 600 — the fragment carries a pairing code) —
the handshake the Mac side waits on before `open`. Only
then does it run `scripts/container/provision-run.sh`, where everything
folder-shaped lives now — the config sync, the seeds, `bd init`, a git init
when the folder has no commits, `orca repo add`, the toolchain verify, the
guard check — as numbered idempotent steps
under `scripts/container/provision.d/`, each writing
`run/provision/<step>.log` and `.status`, none fatal, all re-run by the next
start. Those two files per step are what `provision
status` reads back (one row per step; `provision run <step>` re-runs
exactly one) -- the SessionStart hook prints the FAILED rows only, so a
broken folder names its own fault on the first prompt and a clean one says
nothing, and `claude-dev --doctor` fetches the same rows over `docker
exec`. The one exception is the OpenRouter guard's
*start*, which stays in front of `--serve`: Orca's environment is fixed at
exec, so whether the guard's token reaches it is decided before it starts.
The steps run on the Orca-cannot-start path too, right before
the die. Claude
Code signs in on its own first run inside Orca. Registration seeds the stack
this template assumes — Claude Code as the master, low-cost OpenRouter models
as delegate-route workers, and Orca's native coordination, which needs no
opt-in now that Orca runs in the container. An opencode worker is a headless
`orca-worker-run` that exits when the slice is done (peak ~700 MB, nothing
resident afterwards); `--tui` restores the resident TUI for watching.

The UI is a client of that runtime, and on a Mac with the Orca desktop app
installed the client is the app, not a browser tab: the launcher launches it
and registers the container as a remote environment named
`remote-<project>` — the environment name IS the sidebar badge on every
workspace under the project, and the badge truncates, so the word the user
reads has to come first; the container itself is still
`claude-orca-<project>` — over Orca's pairing protocol (the E2EE websocket to
the published loopback port, keyed by `run/orca-pairing-url.txt` or the web
URL's `#pairing=` fragment). The `ui` key in `claude-orca.json`
(`desktop`|`web`, written at register) decides; no app found, or
`CLAUDE_ORCA_UI=web`, means Orca Web — the browser path stays whole. The
image is built at the app's version because Orca refuses a protocol
mismatch. The app can also open *local* unsandboxed workspaces, so the
launcher strips this folder out of `orca-data.json` while Orca is closed --
it never quits a running Orca for that window, attaches the remote host
either way, and prints the in-app clicks when a local project survives.

`HOME` is `<project>/.claude-dev/home`, whose `.claude` config dir is
populated from this repo's `config/` by a checksum-gated sync that preserves
Orca's own managed hook entries (status dots, sub-agent rows). One directory
under that home is NOT the folder's: Orca's `--user-data-dir`
(`~/.config/orca`) is a docker volume named after the container, because a
macOS bind mount cannot `chmod` or `link` a unix socket and that is where
Orca puts its RPC and daemon sockets. `./claude-dev --teardown` removes the
volumes with the container, so the state still dies with the folder. Four
more volumes (`.cache`, `.npm`, `.local/share/opencode`, `worktrees`) keep
small-file churn off the share (15x slower); the project folder stays
bind-mounted. The hook/guard
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

Worktree cleanup is one sweep, `worktree-gc`: it removes what a finished
piece of work leaves behind — every worktree other than the main one whose
work is already merged, the local branches that pointed at it, and the
`home/`+`config/` caches of finished delegate job dirs (receipts and logs
stay). `STRANDED` names work it refuses to touch — a branch with commits
not in main, a kept worktree still holding such a branch, or a main HEAD
parked off main — and any STRANDED line exits 1. It runs from boot step 65
(`65-worktree-sweep`), after every `git merge` and `git branch -d/-D` (the
PostToolUse hook's `--after-merge`), at SessionStart (`--quiet`, so the
first prompt carries the STRANDED lines and one summary), at SessionEnd
(`session-end-audit` dev-logs each STRANDED line), and from `disk-cleanup`.
An occupant that is only Orca's idle worktree terminal — a shell whose
parent is the orca-ide daemon and which has no children — does not make a
worktree busy, because `orca worktree rm` closes it; any other process
still does. `branch-guard` (PreToolUse, Bash) denies creating or switching
to a branch off main unless the command carries `BRANCH_OK=1`, so solo
work stays on main where the user can see it.

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
- **Frozen contracts, only when the user asks for one.** A bead's `FROZEN`
  files are frozen from its `RED-AT` commit onward: the test is committed
  red first, the implementation second, and the test is never edited to
  make an implementation pass.
- **The Mac side executes nothing it did not ship.** `claude-orca.json` is
  read as validated data through `jq`, never sourced and never run.
<!-- END PROJECT SECTIONS -->
