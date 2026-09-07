# claude_orca

One command turns any folder on your Mac into an isolated agent workspace.
The folder gets its **own Linux container**, and the session manager
([Orca](https://onorca.dev)) runs *inside* it, serving its UI back to your
browser. On a Mac it lives inside Docker's own Linux virtual machine, a
whole kernel away from your files. Nothing this installs on the Mac runs an
agent, so there is no unconfined copy to start by mistake.

**The stack it assumes.** Claude Code is the master: it plans, decomposes,
reviews and decides. Low-cost **OpenRouter** models are the workers — a bead
names a route and Claude dispatches the slice headless, with the acceptance
contract and the check staying on the strong model ([Cheap workers without
losing quality](knowledge-base/DELEGATION_ROUTES.md#cheap-workers-without-losing-quality)).
**Orca's native coordination is on by default** for every folder this
registers, so worker terminals and orchestration are part of the setup
rather than an add-on.

One boundary does the confining, and it is the container's own: the only
host paths that exist inside it are your project folder, mounted at its real
absolute path, and that folder's `.claude-dev/home`, mounted as the agent's
home directory. The rest of your Mac is not missing a permission — it is not
there. The worst a runaway `rm -rf` can do is empty the project folder.

## Requirements

**Docker** is the runtime, and it is the only thing you might have to
satisfy yourself:

- **On a Mac** — Docker Desktop. The bootstrap installs it with Homebrew
  (`brew install --cask docker`) when it is missing; you start it once and
  leave it running. Any Mac Docker Desktop supports will do — there is no
  macOS 26 or Apple-silicon requirement any more.
- **On Linux** — whatever Docker your distribution ships, with your user
  able to talk to the daemon.

Everything else the bootstrap installs for you, in the same run, and then
carries on:

- **The GitHub CLI** (`gh`), by Homebrew if you have it and from cli/cli's
  own macOS `.pkg` if you do not, then signed in. Its token rides into the
  container, so `gh` works there too.
- **git**, via the Xcode Command Line Tools.

The only thing it ever asks you for is your **admin password**, which macOS
needs to install those.

The container's image comes one of two ways, and you do not choose: if your
`gh` token carries `read:packages`, the prebuilt image is pulled and the
first start takes seconds. If it does not, the folder runs the public
`ubuntu:24.04` base image and installs its own toolchain inside the
container the first time it starts — several minutes, once, with
`./claude-dev logs` showing the progress. Either way the same command is all
you run.

## Quickstart

**1. Bootstrap the folder**, from inside the folder you want to isolate:

```bash
gh api repos/joe-rayment/claude_orca/contents/bootstrap.sh -H "Accept: application/vnd.github.raw" | bash
```

That installs any of the dependencies above you are missing, makes sure
Docker is running, clones this template into
`.claude-dev/template`, writes the
`./claude-dev` launcher stub, seeds `.claude-dev/claude-orca.json`, pulls the
pinned image, starts the folder's container, and opens Orca in your default
browser. Re-running is safe. To isolate another folder, run the same
one-liner from inside it.

**2. Sign in to Claude, inside Orca.** The browser tab is the folder's own
Orca, already paired and already holding the project. Pick **Claude Code**
and work as usual: the first `claude` run prints a login URL in that
terminal — open it on this Mac and paste the code back. That is the whole
first run. Nothing is asked of you along the way.

Everything below this is reference.

### If the bootstrap stops

- **`docker: command not found`** — the bootstrap installs Docker Desktop
  with Homebrew itself; if that failed, install it by hand from
  [docker.com](https://www.docker.com/products/docker-desktop/) (or
  `brew install --cask docker`), then re-run the one-liner.
- **`Cannot connect to the Docker daemon`** — Docker is installed but not
  running. Start it by hand:

  ```bash
  open -a Docker          # macOS
  sudo systemctl start docker   # Linux
  docker info             # says yes when it is up
  ```

  The bootstrap does this for you; it only reports when it cannot.
- **`No prebuilt image: the VM installs its toolchain on first start`** — not
  an error. The prebuilt image is private, so pulling it needs a `gh` token
  carrying `read:packages`; without one, the folder runs the public
  `ubuntu:24.04` base image instead and installs everything inside the
  container the first time it starts. That takes several minutes, once, and
  `./claude-dev logs` shows the progress. Every later start is fast, and
  nothing else about the folder differs.
- **Orca never publishes a URL.** `./claude-dev logs` follows the
  container's output, and `.claude-dev/run/orca-serve.log` inside the folder
  has Orca's own. `./claude-dev --doctor` says which of the six steps is the
  one that failed.
- **The port is taken.** The port is chosen once, at registration, and kept
  in `claude-orca.json`. Change the number there and run
  `./claude-dev --update` to recreate the container on it.

## Day to day

Every command is the `./claude-dev` stub in the project root, and every one
of them is about *this* folder:

```bash
./claude-dev                  # open Orca (starts or creates the container)
./claude-dev stop             # stop this folder's container
./claude-dev shell            # a login shell inside the container, in the project
./claude-dev logs             # follow the container's output
./claude-dev --how-to-run     # print the URL and the two commands again
./claude-dev --doctor         # CLI, daemon, image, container, port, web url
./claude-dev --update         # pull the template and the image, recreate
./claude-dev --teardown       # snapshot beads, remove this folder's install
```

`./claude-dev shell` is where you run `claude`, `bd` or `git` by hand: it is
a shell in the same container, in the same directory, with the same home the
agents use. `--teardown` copies `.beads/issues.jsonl` to
`.claude-dev-snapshots/<timestamp>/` before it deletes anything, and a later
registration restores it.

## What is isolated

| Inside the container | On the Mac |
|---|---|
| Orca, Claude Code, every agent and every shell they open | the `./claude-dev` launcher and nothing else |
| the project folder, at its real absolute path, read-write | — |
| `<project>/.claude-dev/home` as `/home/agent`: Claude's credentials, the git identity | — |
| Orca's own `~/.config/orca`, in a docker volume named after the container | — |
| the toolchain (Orca, Claude Code, opencode, bd, dolt, bats) in `<project>/.claude-dev/toolchain` | visible: it is in the folder |
| any extra mounts you name, always read-only | — |

The image is deliberately thin: it carries apt state — base packages, node,
gh, and the GTK/at-spi/xvfb libraries Orca links against — because that is
the half a bind mount cannot hold. Everything else installs on a folder's
first start (a few minutes, progress in `.claude-dev/run/setup.log`) into
`.claude-dev/toolchain`, and every later start reuses it. Version pins for
those tools live in `scripts/container/setup.sh`, so moving one is a
template pull rather than an image rebuild.

Orca's user-data dir is the one thing that cannot live in the folder: it
holds the unix sockets Orca chmods and hard-links on startup, and a macOS
bind mount supports neither (`chmod` returns EINVAL, `link` fails), so Orca
would never come up. It gets a docker volume — a real Linux filesystem at
the path Orca expects — named `claude-orca-<folder>-orca-state` and removed
by `./claude-dev --teardown`, so it still dies with the folder.

Nothing else under `/Users` is visible. The pairing URL Orca prints is a
credential (its fragment carries the pairing code), so it is written to
`.claude-dev/run/orca-web-url.txt` with mode 600 and the doctor names the
file rather than its contents. The published port is bound to `127.0.0.1`
only.

### Tuning it — `.claude-dev/claude-orca.json`

Written once at registration and never rewritten, so your edits survive
every update:

```json
{
  "version": 3,
  "port": 6768,
  "cpus": 4,
  "memory": "8g",
  "theme": "dark",
  "dns": "1.1.1.1",
  "extraMounts": ["/Users/you/reference-repo:/Users/you/reference-repo"]
}
```

- **`port`** — the host port Orca is published on. Chosen from 6768 upward
  at registration; the same number is used on both sides, because the
  pairing code names it.
- **`cpus`, `memory`** — `null` means whatever Docker defaults to.
- **`theme`** — `dark` (the default), `light` or `system`. It reaches the
  container as `CLAUDE_ORCA_THEME`, and the entrypoint writes it into Orca's own
  settings the first time a folder starts — alongside a worktree base path of
  `<project>/.orca-worktrees`, so worktrees live in the bind mount and are
  still there on the Mac. That seed happens **once**: after Orca has run,
  whatever you change in its settings pane is what sticks, and this key stops
  mattering.
- **`dns`** — the resolver the container is started with, `1.1.1.1` by
  default. Set it to `auto` to pass no `--dns` flag at all and leave Docker's
  own choice alone. It exists because a container that starts with a resolver
  answering nothing fails the toolchain install on `Temporary failure
  resolving 'ports.ubuntu.com'`. `CLAUDE_ORCA_DNS` overrides it for one run,
  and an empty value there means no flag either.
- **`extraMounts`** — `host:guest` pairs mounted **read-only**, always. They
  are outside the project, so the container boundary is the only thing
  keeping them safe.

Apply a change with `./claude-dev --update`, which recreates the container.

## Orca coordination (on by default)

Orca runs natively inside the container, so its CLI, its orchestration mode
and its worker terminals are simply there — no socket to expose, no key to
set. `orca orchestration worker-start --agent codex`, terminals, automations
and artifacts all work, and everything they spawn is inside the same
container and the same boundary. This is a first-class part of the setup, not an add-on.

Because of that, a delegated slice is an Orca worker by default rather than an
in-process sub-agent. `orca-dispatch <bead-id>` turns one bead into one
supervised worker — Claude Code, or an OpenRouter model through OpenCode, in
its own terminal and worktree — with the bead's acceptance contract and the
same worker rules attached; `orca-wait` collects each `worker_done`, releases
the worker and appends the outcome to the bead; `orca-reply` answers a worker
that asked rather than guessed; `orca-workers` prints who is running what; and
`orca-run --epic <id>` drives a whole epic in waves, one worktree per epic,
dispatching every independent bead at once. When the runtime is not reachable
the same slice runs as an in-process executor instead, so nothing depends on
Orca being up. The playbook is
[knowledge-base/TIERED_ORCHESTRATION.md](knowledge-base/TIERED_ORCHESTRATION.md).

## The workers: OpenRouter models on a route

A bead names a route, Claude writes the brief and dispatches the slice
headless:

```bash
delegate run --route deepseek --bead claude-orca-3sk.22
```

Routes live in `config/delegate-routes.json` (runners: `opencode run`,
`codex exec`, `gemini -p`). It ships `glm`, `deepseek` and `qwen-coder` on
OpenRouter, `local` on Ollama, plus `codex`/`gemini` examples — **the file is
yours to edit**: any model id from
[openrouter.ai/models](https://openrouter.ai/models) works as
`openrouter/<id>`. Each job gets an ephemeral worktree under
`.claude-dev/delegate/<job>`, and the receipt lands in the bead's notes.
Interactive Codex, Gemini and OpenCode sessions you open in Orca share the
same container and the same beads database.

**Which slices go there, and how quality survives it** —
[knowledge-base/DELEGATION_ROUTES.md](knowledge-base/DELEGATION_ROUTES.md#cheap-workers-without-losing-quality)
has the one explanation, with a worked `bd create` → `delegate run` →
verify sequence.

**Your OpenRouter key.** Run `./claude-dev key openrouter` on the Mac: it
reads the key without echoing it, stores it at
`.claude-dev/home/.openrouter.key` (mode 600, inside the folder and
gitignored), and every container from then on gets it as
`OPENROUTER_API_KEY`. Exporting the variable yourself inside
`./claude-dev shell` still works. `delegate check` says
`OPENROUTER_API_KEY not set` until it is there, and no key means no
OpenRouter surface at all.

## Knowledge base

Deeper documentation lives in [knowledge-base/](knowledge-base/README.md).

## The image

`ghcr.io/joe-rayment/claude_orca`, pinned by the `IMAGE_TAG` file at the
root of this template, so a folder that only ever runs `./claude-dev
--update` moves to a new image with the pull.

- `Dockerfile` — Ubuntu 24.04. It only copies and calls
  `scripts/container/setup.sh`, which carries every pin (Orca Linux,
  Claude Code, beads, bats, Node 22) and is run for real inside a 24.04
  chroot by `scripts/container/verify-rootfs.sh`. This template lands at
  `/opt/claude-orca`.
- `scripts/container/entrypoint.sh` — runs as PID 1 under tini: drops to
  the `agent` user, config-syncs, starts `orca-ide --serve`, and writes the
  browser URL to `<project>/.claude-dev/run/orca-web-url.txt` (mode 600 —
  it carries a pairing code) plus the port to `run/port`.
- `scripts/container/smoke.sh` — run inside the freshly built image by CI;
  starts the entrypoint against a throwaway project and fails the build
  unless Orca serves and the URL answers.
- `.github/workflows/image.yml` — builds the image, smoke-tests it, drives
  the real `./claude-dev` launcher against it on a live Docker daemon (the
  `e2e` steps: a throwaway project folder, a real container, and a real HTTP
  request to the URL Orca published), and only then publishes both
  architectures.

## Tests

```bash
./run-tests.sh           # everything
bats tests/*.bats        # the suite directly
bats tests/docs.bats     # one file
```
