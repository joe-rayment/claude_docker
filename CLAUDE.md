# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
<!-- beads: rules live in ~/.claude/CLAUDE.md § Beads; markers kept so bd skips re-injection -->
<!-- END BEADS INTEGRATION -->


<!-- BEGIN PROJECT SECTIONS -->
## Build & Test

```bash
./run-tests.sh           # the fast set: small tests, not flaky, 60 s limit each
./run-tests.sh --medium  # small + medium (they sleep, poll or run servers), 300 s each
./run-tests.sh --all     # everything, flaky included (CLAUDE_ORCA_TEST_ALL=1 does the same)
bats tests/*.bats        # the whole suite, directly
bats tests/docs.bats     # one file
bats -f 'git push' tests/outbound-guard.bats   # only the cases whose name contains "git push"
```

**Tests are the user's to run** -- in the central Test Hub
(joe-rayment/test-suite), by hand, or by asking (`/test` runs them and
explains every failure in plain English). Agents write or run a test only
when the prompt asks (rulebook § Tests); otherwise they check a change by
running the real thing. `tests/INDEX.md` says, for every file, what it
guards, whether it checks behavior or only wording, and how to read a
failure.

Tests follow `config/testing-standard.md` (shipped as `~/.claude/TESTING.md`):
every test is small, medium or large by what it does, tagged
`# bats test_tags=size:medium` (or `file_tags=` for a whole file); untagged
is small. The fast set is 1,338 of 1,536 cases, ~7 minutes one file at a
time on this box; GNU `parallel` (`brew install parallel`) lets
`run-tests.sh` run files side by side.
There is no CI in this repo: the image is built on the machine that runs it,
so a red test must never stop a fix from reaching that machine.
`scripts/container/smoke.sh` (the image's own check) and `tests/mac-e2e.sh`
(the host-side launcher against a real daemon) are run by hand, on demand,
against a real Mac.

Tests are bats-core, and they run on Linux as well as macOS: the suite stubs
the host tooling (`docker`, `open`, `uname`, `gh`) and exercises the
scripts' logic rather than the Docker daemon itself. The in-container half
is exercised natively — this box is the same Ubuntu arm64 the image is built
on — but containers still cannot run here: Docker on this box dies with
`failed to register layer: unshare: operation not permitted`, no images
cached, user namespaces denied. So proving the image itself, and the
host-side launcher against a real daemon (a throwaway folder, a real
container, a real ssh login that lands in the project), is
`tests/mac-e2e.sh`'s job -- see "Definition of done for host-side changes"
below.

## Architecture Overview

One command (`gh api … bootstrap.sh | bash`), run from inside a project
folder, gives that folder **its own Linux container** (on a Mac, inside
Docker Desktop's own Linux VM). `<project>/.claude-dev/` carries the template
clone, `bin/claude-dev`, the folder's `claude-orca.json`, the `home/` that
becomes the agent's home directory, `run/` (results) and `state/` (authority,
including the folder's ssh keys). There is no central install; nothing on the
Mac runs an agent. The door is a **terminal pane**, not a UI: Ghostty (or any
terminal) ssh-es into the container and lands in the project.

The boundary is the container's. `claude-dev` runs one Docker container per
folder from an image built on that machine (`claude-orca`, pinned by the
`IMAGE_TAG` file; `CLAUDE_ORCA_IMAGE_REPO`/`CLAUDE_ORCA_IMAGE` override it),
mounting the project at **`/workspace/<name>`** and `.claude-dev/home` as
`/home/agent`. The only published port is sshd's, on `127.0.0.1`: it listens
on 2222 inside, and the launcher sets `CLAUDE_ORCA_SSHD_PORT` to the folder's
published port. The Mac path rides in as `CLAUDE_ORCA_HOST_PROJECT_DIR` for
messages that name a file to open on the Mac; `BEADS_DIR` names the folder's
tracker so `bd` answers from any directory.

The image carries the whole install: apt state (`setup.sh`'s `IMAGE_PHASES`)
plus the payload -- opencode, bd, dolt, helix, bats -- one Docker layer per
phase, rarest-changing first, with the repo copy below them. Claude Code is
the exception: `provision.d/15-claude-on-path` installs the latest natively
into the folder's home, where `claude update` updates it. On the **runtime
path** (plain `ubuntu:24.04`, when the local `docker build` fails) a folder
carries a toolchain instead. `setup.sh --check` says the image is the
filesystem it promised.

`scripts/container/entrypoint.sh` is PID 1: the OpenRouter guard first (its
environment is fixed at exec, so whether the token reaches sshd is decided
before it starts), then the sshd supervisor (`sshd-lib.sh`; it retries every
5 s on any refusal, such as no keys yet), then
`scripts/container/provision-run.sh` as a waited background job. TERM exits
143 within a second. Idle memory is ~36 MB. `run/sshd.ready` is the handshake
the Mac side waits on. Provisioning is numbered idempotent steps under
`scripts/container/provision.d/`, each writing `run/provision/<step>.log` and
`.status`, none fatal; `provision status` reads them back and the
SessionStart hook prints the FAILED rows only.

**The Mac side.** `./claude-dev` starts the container and waits for
`run/sshd.ready`. `./claude-dev pane` opens a shell in it (fast through the
ssh master; when it cannot, it says `== Mac shell -- NOT sandboxed ==`).
`./claude-dev ghostty [--check|--uninstall]` installs the Ghostty include and
the `ghostty-pane` router, so every new tab in a sandboxed folder lands in its
container. `--how-to-run` prints that how-to; `--update` migrates an old Orca
folder (removes its Orca state volume, creates the ssh keys). Keys and
`known_hosts` live in `state/ssh` -- no trust-on-first-use, nothing in
`~/.ssh`. `state/ssh/config` sets `ControlMaster auto`, `ControlPersist`, a
`ControlPath` under `~/.local/state/claude-dev` (a literal path) and, unless
`claude-orca.json` says `"clipboard": false`, the clipboard `RemoteForward`;
the pane adds `SetEnv` for `TERM_PROGRAM` and friends on its command line.
`pane-entry` (sshd's ForceCommand) rebuilds the environment and the cwd.

**Clipboard.** Claude Code on Linux pastes through `xclip -selection
clipboard -t TARGETS -o` / `-t image/png -o`. The container's `bin/xclip`
shim asks the Mac's `clip-serve` through the forwarded socket. Only images
cross Mac -> container, text never does; `xclip -i` copies text to the Mac.

**Workers.** `dispatch <bead>` hands one bead to a headless `worker-run`;
`workers list|wait|reply|tail|stop` watch them; `dispatch --epic` runs ready
children in waves, and a failed blocker blocks its dependents.

`HOME` is `<project>/.claude-dev/home`, whose `.claude` config dir is
populated from this repo's `config/` by a checksum-gated sync. Four docker
volumes (`.cache`, `.npm`, `.local/share/opencode`, `worktrees`) keep
small-file churn off the share (15x slower); the project folder stays
bind-mounted, and `./claude-dev --teardown` removes the volumes with the
container. The hook/guard suite (lane, tier, bd-guard, outbound-guard,
auth-guard, contract-gate, cost-mirror…) runs from there. `/tier` state
lives in `.claude-dev/run/tier.json` and is injected into sub-agent spawns by
a `PreToolUse` hook rather than written into agent frontmatter, because
config-sync owns those files.

## Definition of done for host-side changes

A change to `bootstrap.sh`, `scripts/launcher.sh`, the `Dockerfile`, or
anything under `scripts/container/` is done only when it has run for real
and what it printed is in the commit message or the bead: `tests/mac-e2e.sh`
on a Mac, or on this box the local runtime (`CLAUDE_ORCA_RUNTIME=local`, as
in `tests/e2e-local.bats`: the real launcher, entrypoint, provisioning, sshd
and ssh) driven through the user's own steps on a pty -- a brand-new folder,
`register` as `bootstrap.sh` runs it, then `./claude-dev`. A green bats
suite is not evidence for that path: the suite stubs `docker`, `open`, `gh`
and `uname`, so it proves the launcher's logic and nothing more. A change
neither path can run is redesigned until one can; "UNVERIFIED on a Mac" is
never a finish.

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
A locked worktree is reported as `locked: <reason>` and never unlocked. `branch-guard` (PreToolUse, Bash) denies creating or switching
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
