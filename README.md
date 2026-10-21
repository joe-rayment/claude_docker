# claude_orca

One command turns any folder on your Mac into an isolated agent workspace.
The folder gets its **own Linux container** (on a Mac, inside Docker's own
Linux virtual machine), and you work in it through a plain **terminal pane**:
a Ghostty tab that is an `ssh` session into that container. Every agent, shell
and tool call runs there, a whole kernel away from your files. Nothing this
installs on the Mac runs an agent, so there is no unconfined copy to start by
mistake.

**The stack it assumes.** Claude Code is the master: it plans, decomposes,
reviews and decides. Low-cost **OpenRouter** models are the workers: a bead
names a route and Claude dispatches the slice headless, with the acceptance
contract and the check staying on the strong model ([Cheap workers without
losing quality](knowledge-base/DELEGATION_ROUTES.md#cheap-workers-without-losing-quality)).

One boundary does the confining, and it is the container's own: the only host
paths inside it are your project folder, at `/workspace/<name>`, and that
folder's `.claude-dev/home`, which is the agent's home directory. The rest of
your Mac is not missing a permission, it is not there. The worst a runaway
`rm -rf` can do is empty the project folder.

## Requirements

- **Docker.** On a Mac, Docker Desktop: the bootstrap installs it with
  Homebrew (`brew install --cask docker`) when it is missing; you start it
  once and leave it running. On Linux, whatever Docker your distribution
  ships, with your user able to talk to the daemon.
- Everything else the bootstrap installs in the same run: **git** (Xcode
  Command Line Tools), the **GitHub CLI** (`gh`, then signed in; its token
  rides into the container) and **Ghostty** (optional, by Homebrew cask).

The only thing it asks you for is your Mac **admin password**, to install
those. The container's image is built on your machine the first time a folder
registers, once per Mac; every folder after the first is a Docker cache hit
and starts in seconds.

## Quickstart

**1. Type this in the folder you want to isolate:**

```bash
gh api repos/joe-rayment/claude_docker/contents/bootstrap.sh -H "Accept: application/vnd.github.raw" | bash
```

It installs what is missing, clones this template into `.claude-dev/template`,
writes the `./claude-dev` launcher, runs `claude-dev ghostty` (below), builds
the image and starts the container. You see the steps print, then `sshd is up
(3s)`, and this terminal becomes the folder's first pane: on a new folder, the
startup menu (step 2). Without a terminal it prints `ready: run ./claude-dev
pane in a terminal` instead. Re-running is safe; to
isolate another folder, run the same line from inside it. The folder need not
be a git repository: the first start makes one on `main` with a seed commit.

**2. More panes.** Type `./claude-dev pane` in any terminal, or open a new
Ghostty tab in a folder whose `claude-orca.json` says `"route": true`. You land
at a prompt in
`/workspace/<name>`; `cd ..` shows that one folder and nothing else. The first
pane a folder ever gets (an existing folder too) opens a startup menu that sets up beads, offers
GitHub, then starts Claude Code; say no to any of it, and `startup-menu` runs
it again whenever you want.

**3. Sign in to Claude.** The first `claude` prints a login URL. Open it on
the Mac and paste the code back. That is the whole first run.

**Ghostty.** `./claude-dev ghostty` adds one line to your Ghostty config
(`config-file = ?claude-dev.ghostty`) and installs a small router. After that
a new tab, split or window is your normal Mac shell, so you can still run your
app in your own project folder. Only inside a folder whose `claude-orca.json`
says `"route": true` does it land in that folder's container; everywhere else,
`./claude-dev pane` enters the sandbox on purpose. `cmd+n` (a new window)
starts in your home folder, a Mac shell. `./claude-dev ghostty --check` asks
Ghostty whether the include applies; `--uninstall` gives your config back byte
for byte.

**What is Claude doing?** Type `activity` in any sandbox pane for one
plain-English page of what Claude Code and its executors are doing right now,
written by a cheap model through the guard, and only while the panel is open.
`"activity": false` in `claude-orca.json` turns the model off. Open it beside
your work with Ghostty's own split (cmd+d), then type `activity` in the new
pane (it opens as a Mac shell unless the folder says `"route": true`, so run
`./claude-dev pane` in it first); `q` quits.

**How to tell where you are.** A sandbox pane has `/workspace/<name>` as its
path. If the container cannot come up, the pane falls back to a Mac shell and
says so loudly: `== Mac shell -- NOT sandboxed ==`.

Everything below this is reference.

### If something stops

- **`docker: command not found`**: install Docker Desktop by hand from
  [docker.com](https://www.docker.com/products/docker-desktop/) (or
  `brew install --cask docker`) and re-run the one-liner.
- **`Cannot connect to the Docker daemon`**: Docker is installed but not
  running. `open -a Docker` on a Mac, `sudo systemctl start docker` on Linux,
  then `docker info` says yes when it is up.
- **`No image: the VM installs its toolchain on first start`**: not an error.
  When the local image build cannot run or fails, the folder runs the public
  `ubuntu:24.04` image and installs the toolchain inside on first start:
  several minutes, once; `./claude-dev logs` shows the progress.
- **sshd never becomes ready.** `./claude-dev logs` follows the container's
  output and `.claude-dev/run/sshd.log` has sshd's own. `./claude-dev
  --doctor` says which step failed: CLI, daemon, image, container, port, sshd
  or ssh key.
- **The port is taken.** The port is chosen once, at registration, and kept in
  `claude-orca.json`. Change the number there and run `./claude-dev --update`.
- **A folder from the Orca days.** `./claude-dev --update` migrates it: it
  removes the old Orca state volume and creates the folder's ssh keys. Beads
  are untouched.
- **Pasting an image does nothing.** Images cross from the Mac clipboard to
  Claude Code through the clipboard bridge (below). A folder with
  `"clipboard": false` has it off on purpose; text never crosses that way.

## Day to day

Every command is the `./claude-dev` stub in the project root, and every one of
them is about *this* folder:

```bash
./claude-dev                  # start the container (creates it as needed), wait for sshd
./claude-dev pane [dir]       # a sandbox pane in this terminal (fast when one is up)
./claude-dev ghostty          # set Ghostty up (tabs in a "route": true folder enter the sandbox); --check, --uninstall
./claude-dev stop             # stop this folder's container
./claude-dev shell            # a login shell through docker, no ssh (the fallback)
./claude-dev logs             # follow the container's output
./claude-dev verify           # is this folder set up the way the template promises?
./claude-dev --how-to-run     # print the pane how-to again
./claude-dev --doctor         # CLI, daemon, image, container, port, sshd, ssh
./claude-dev --update         # update the template, rebuild the image, recreate
./claude-dev --teardown       # snapshot beads, remove this folder's install
```

`--doctor` says whether the folder can open; `verify` says whether it is set
up (the boundary, the toolchain pins, beads, the rulebook, the hooks, the git
identity), each as its own row. `--teardown` copies `.beads/issues.jsonl` to
`.claude-dev-snapshots/<timestamp>/` before it deletes anything, and a later
registration restores it.

## What is isolated

| Inside the container | On the Mac |
|---|---|
| Claude Code, every agent and every shell they open | the `./claude-dev` launcher, the Ghostty include and router, the clipboard listener |
| the project folder, at `/workspace/<name>`, read-write | none of the rest of your files |
| `<project>/.claude-dev/home` as `/home/agent`: Claude's credentials, the git identity | the folder's ssh keys and `known_hosts`, in `.claude-dev/state/ssh` |
| the toolchain (opencode, bd, dolt, helix, bats), from the image | nothing in `~/.ssh` |
| any extra mounts you name, always read-only | |

The container runs sshd, published on `127.0.0.1` only, with the folder's own
key and no trust-on-first-use. The folder's ssh config (`state/ssh/config`)
multiplexes panes over one connection, so a new tab is one `exec ssh` and
costs no Docker call. Idle, the container holds ~36 MB.

**The clipboard bridge.** Claude Code on Linux pastes through `xclip`. The
container's `xclip` is a shim that asks the Mac's `clip-serve` through a
forwarded socket, so a screenshot on the Mac clipboard pastes into Claude Code.
Only images cross Mac to container, text never does; `xclip -i` in the
container copies text to the Mac. `"clipboard": false` turns it off.

The image carries the whole install, one Docker layer per tool, so a folder
whose build succeeded is ready the moment its container starts; version pins
live in `scripts/container/setup.sh`. Claude Code is the exception: it is
installed into the folder's home, where `claude update` updates it.

### Tuning it: `.claude-dev/claude-orca.json`

Written once at registration and never rewritten, so your edits survive every
update. A new file carries only the first few keys; add the rest as you need
them:

```json
{
  "version": 3,
  "port": 6768,
  "cpus": 4,
  "memory": "8g",
  "terminalTheme": "Homebrew",
  "dns": "1.1.1.1",
  "clipboard": true,
  "route": true,
  "extraMounts": ["/Users/you/reference-repo:/Users/you/reference-repo"]
}
```

- **`port`**: the host port sshd is published on; chosen from 6768 upward.
- **`cpus`, `memory`**: `null` means a default cap for cpus (half the VM's
  cores; `0` means none) and whatever Docker defaults to for memory.
- **`terminalTheme`**: a palette name; `Homebrew` (green on black) is the
  default. The shell sets the default foreground and cursor colour at every
  start; every colour another program picked on purpose is left alone. A name
  the shell does not know leaves the terminal alone.
- **`dns`**: the resolver the container starts with, `1.1.1.1` by default;
  `auto` passes no flag. `CLAUDE_ORCA_DNS` overrides it for one run.
- **`clipboard`**: `false` turns the clipboard bridge off.
- **`route`**: `true` routes new Ghostty tabs, splits and windows opened in
  this folder into its container; missing or `false` leaves them Mac shells,
  the default.
- **`router`**: `false` turns the per-prompt `[route]` hint off (not the
  same as `route` above); `routerModel` picks a different OpenRouter model.
- **`extraMounts`**: `host:guest` pairs, mounted **read-only**, always.

Apply a change with `./claude-dev --update`, which recreates the container.

## Workers

`dispatch <bead>` hands one bead to one headless `worker-run` in its own
worktree and returns at once; `workers list|wait|reply|tail|stop` watch them
(`workers wait` prints each finished worker's line and `workers reply` answers
one that asked rather than guessed); `dispatch --epic <id>` runs an epic's
ready children in waves, and a failed blocker blocks its dependents. None of
it needs anything but the container. The playbook is
[knowledge-base/TIERED_ORCHESTRATION.md](knowledge-base/TIERED_ORCHESTRATION.md).

Before each prompt, a hook makes one cheap model call (about a second, about
$0.0001) and tells the session which lane it looks like and who should do the
bulk of the work; it only advises, and it errs upward. See "Prompt router" in
the playbook above.

A bead can also name a route; Claude writes the brief and dispatches headless:

```bash
delegate run --route deepseek --bead claude-orca-3sk.22
```

Routes live in `config/delegate-routes.json`, **a file that is yours to
edit**: any model id from [openrouter.ai/models](https://openrouter.ai/models)
works as `openrouter/<id>`. It ships ten routes; see
[knowledge-base/DELEGATION_ROUTES.md](knowledge-base/DELEGATION_ROUTES.md)
for the table and for which slices belong there.

**Your OpenRouter key.** Run `./claude-dev key openrouter` on the Mac: it reads
the key without echoing it and stores it at `.claude-dev/home/.openrouter.key`
(mode 600, gitignored), and the container's guard is the only holder workers
see. `delegate check` says `OPENROUTER_API_KEY not set` until it is there.

**Your OpenAI (ChatGPT) subscription** needs no key: `/tier auth openai` opens
a sign-in, then `/tier opus openai:terra openai:luna@high` binds the worker and
recon seats to it.

## Knowledge base

Deeper documentation lives in [knowledge-base/](knowledge-base/README.md); the
terminal side (panes, the router, ssh, the clipboard) is in
[knowledge-base/TERMINAL.md](knowledge-base/TERMINAL.md).

## The image

Built locally by `acquire_image` in `scripts/launcher.sh`: `docker build`
against the folder's own template clone, once per Mac, cached by Docker's layer
cache. There is no registry in this path. The tag comes from `IMAGE_TAG`, so
`./claude-dev --update` moves a folder to a new image with the rebuild.

- `Dockerfile` copies and calls `scripts/container/setup.sh`, which carries
  every pin and is checked by `scripts/container/verify-rootfs.sh`.
- `scripts/container/entrypoint.sh` is PID 1: the OpenRouter guard, then the
  sshd supervisor (retries every 5 s), then provisioning as a background job.
  It writes `run/sshd.ready`, the handshake the Mac side waits on.
- `scripts/container/provision.d/`: numbered idempotent steps (toolchain
  verify, config sync, git identity, tracker, repository, guard check), each
  leaving `run/provision/<step>.log` and `.status`; none is fatal and the next
  start re-runs them all.
- `scripts/container/smoke.sh` and `tests/mac-e2e.sh`: the image's own check,
  and a real bootstrap, build and container on a real Mac, run by hand.

## Tests

```bash
./run-tests.sh           # the fast subset (~2 min with GNU parallel); --all for every file
bats tests/*.bats        # the suite directly
bats tests/docs.bats     # one file
```

New to tests? [`tests/INDEX.md`](tests/INDEX.md) explains how they work and
how to read a failure, and maps every file to what it guards. Inside a
project, `/test` runs its suite and explains the results in plain English.
