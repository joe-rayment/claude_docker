# claude_orca

One command turns any folder on your Mac into an isolated agent workspace.
The folder gets its **own Linux container**, and the session manager
([Orca](https://onorca.dev)) runs *inside* it. The Orca desktop app on your
Mac attaches to that runtime as a client when you have it installed, and
when you do not the same session serves its UI back to your browser. Either
way, every agent, shell and tool call runs in the container: on a Mac that
is inside Docker's own Linux virtual machine, a whole kernel away from your
files. Nothing this installs on the Mac runs an agent, so there is no
unconfined copy to start by mistake.

**The stack it assumes.** Claude Code is the master: it plans, decomposes,
reviews and decides. Low-cost **OpenRouter** models are the workers — a bead
names a route and Claude dispatches the slice headless, with the acceptance
contract and the check staying on the strong model ([Cheap workers without
losing quality](knowledge-base/DELEGATION_ROUTES.md#cheap-workers-without-losing-quality)).
**Orca's native coordination is on by default** for every folder this
registers, so worker terminals and orchestration are part of the setup
rather than an add-on.

One boundary does the confining, and it is the container's own: the only
host paths that exist inside it are your project folder, mounted at
`/workspace/<name>`, and that folder's `.claude-dev/home`, mounted as the
agent's home directory. The rest of your Mac is not missing a permission — it
is not there. Inside, `pwd` says `/workspace/your-project` and `cd ..` shows
that one folder, which is the truth about what the container holds. The worst
a runaway `rm -rf` can do is empty the project folder.

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

The container's image is built on your machine, from this template, the
first time a folder registers — once per Mac, cached by Docker's own layer
cache, so every folder after the first is a cache hit measured in seconds,
and a folder starts in seconds too. If a build cannot run at all (no
Dockerfile in reach) or fails outright, the folder runs the public
`ubuntu:24.04` base image instead and installs the toolchain inside the
container the first time it starts — several minutes, once, with
`./claude-dev logs` showing the progress. Either way the same command is
all you run.

## Quickstart

**1. Bootstrap the folder**, from inside the folder you want to isolate:

```bash
gh api repos/joe-rayment/claude_orca/contents/bootstrap.sh -H "Accept: application/vnd.github.raw" | bash
```

That installs any of the dependencies above you are missing, makes sure
Docker is running, clones this template into
`.claude-dev/template`, writes the
`./claude-dev` launcher stub, seeds `.claude-dev/claude-orca.json`, builds
the image, starts the folder's container, and opens Orca — the desktop app
when this Mac has one, your default browser otherwise. Re-running is safe.
To isolate another folder, run the same one-liner from inside it.

**2. Sign in to Claude, inside Orca.** The window (or the browser tab) is
the folder's own Orca, already paired and already holding the project. Pick
**Claude Code** and work as usual: the first `claude` run prints a login URL
in that terminal — open it on this Mac and paste the code back. That is the
whole first run. Nothing is asked of you along the way.

### How it opens — the desktop app, or the browser

On a Mac with the Orca desktop app installed, the desktop path is the
default. `./claude-dev` starts the container, launches the app, and
registers the container as a **remote environment** named
`claude-orca-<folder>` over Orca's own pairing protocol — an end-to-end
encrypted websocket to the port the folder already publishes on
`127.0.0.1`. Nothing needs picking — the app already shows it attached and
Connected in its **Remote Hosts** pane. The sidebar groups it under a
**project** named after the folder, and each workspace under that project
carries a badge with the environment name; open one and you are in the
container, the app a client exactly as the browser tab is, and nothing it
runs escapes the container. The app is launched on a private, per-folder
profile that holds only this container's environment, never the Mac's own
Orca profile; that profile starts every session with no local projects,
and `./claude-dev` empties any it finds before each launch. The app's own
"+ Add project" cannot be turned off in 1.4.197, so a local project added
mid-session lives on in that profile until the next `./claude-dev`, and
`./claude-dev verify`'s "local repos" row reports it in the meantime.

Which path a folder takes is the **`ui`** key in
`.claude-dev/claude-orca.json` (`desktop` or `web`), written once at
registration. Bootstrap with `CLAUDE_ORCA_UI=web` to keep the browser tab,
and a folder registered on a machine with no app found — every Linux host,
and any Mac without one — gets `web` on its own. The browser path is
unchanged and is the fallback for everything below.

The folder's image is built at the **version of the installed app**,
because Orca refuses a client/runtime protocol mismatch outright rather
than warning about it; `./claude-dev --doctor` prints both versions.

One thing the browser could not do, the desktop app can: it also opens
**local** workspaces, which run agents on your Mac with no sandbox at all —
the launcher never hands it one, and `./claude-dev verify` fails if this
folder's own conduit profile ever lists one.

Everything below this is reference.

### If something stops

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
- **`No image: the VM installs its toolchain on first start`** — not an
  error. The image is built locally the first time a folder registers; when
  that build cannot run or fails, the folder runs the public `ubuntu:24.04`
  base image instead and installs everything inside the container the first
  time it starts. That takes several minutes, once, and `./claude-dev logs`
  shows the progress (and, on a failed build, `docker build`'s own last
  lines). Every later start is fast, and nothing else about the folder
  differs.
- **Orca never publishes a URL.** `./claude-dev logs` follows the
  container's output, and `.claude-dev/run/orca-serve.log` inside the folder
  has Orca's own. `./claude-dev --doctor` says which of the six steps is the
  one that failed.
- **The port is taken.** The port is chosen once, at registration, and kept
  in `claude-orca.json`. Change the number there and run
  `./claude-dev --update` to recreate the container on it.
- **Pasting into a terminal reports `Image paste failed: … Read permission
  denied`, even when what you pasted was plain text.** That is the browser,
  not the container: Orca Web's paste handler tries `readClipboardText`
  first, and when Chrome's per-site Clipboard permission is not granted
  that call rejects silently, leaving the text empty and falling through to
  the image branch -- whose failure is the only one it ever reports, so a
  text paste shows an image error. Each folder has its own port, so each is
  its own origin with its own permission. In Chrome open
  `chrome://settings/content/siteDetails?site=http://127.0.0.1:<port>`, set
  **Clipboard** to Allow, reload the tab, and click into the terminal before
  pasting -- or run on an image whose served page carries the clipboard
  shim described in the next entry, which sidesteps the permission
  entirely.
- **Cmd+V does nothing in a terminal**, so the Claude Code login code
  cannot be pasted back. This was every folder on an image built before
  2026-09-08. Orca Web owns the terminal's paste key: its handler calls
  `preventDefault()` and reads the clipboard through
  `navigator.clipboard.readText()`, which Chrome gates behind the same
  per-site **Clipboard** permission and which Firefox and Safari never
  grant to a web page at all. When that read is denied Orca reports only
  "Paste failed.", and the browser's own paste event — which needs no
  permission, and which the terminal already listens for — never fires,
  because the keypress was consumed. The image now hides `readText` on the
  served page (`scripts/container/patch-orca-web-theme.py`), which selects
  the fallback Orca already ships for web clients without clipboard read:
  the native paste event gets through, in any browser, with nothing to
  allow. Copy was never affected. On a folder still running an older image,
  either start it again on a current image or set **Clipboard** to Allow
  for its origin as above.
- **A folder registered before the `/workspace` move.** Orca's state
  remembers the repo at its old path. Tear the folder down and register it
  again — `./claude-dev --teardown`, then the bootstrap one-liner. Beads
  survive: teardown snapshots `.beads/issues.jsonl` and registration restores
  it.

## Day to day

Every command is the `./claude-dev` stub in the project root, and every one
of them is about *this* folder:

```bash
./claude-dev                  # open Orca (starts or creates the container)
./claude-dev stop             # stop this folder's container
./claude-dev shell            # a login shell inside the container, in the project
./claude-dev logs             # follow the container's output
./claude-dev verify           # is this folder set up the way the template promises?
./claude-dev --how-to-run     # print the URL and the two commands again
./claude-dev --doctor         # CLI, daemon, image, container, port, web url
./claude-dev --update         # update the template, rebuild the image, recreate
./claude-dev --teardown       # snapshot beads, remove this folder's install
```

`./claude-dev shell` is where you run `claude`, `bd` or `git` by hand: it is
a shell in the same container, in `/workspace/<name>`, with the same home the
agents use. `./claude-dev verify` is the other one worth knowing: `--doctor`
says whether the folder can open, and `verify` says whether it is set up --
the boundary, the toolchain pins, beads, the rulebook, the agent
definitions, the hooks (with Orca's own kept), the git identity, the Claude
first-run keys and Orca's worktree base, each as its own row. `--teardown` copies `.beads/issues.jsonl` to
`.claude-dev-snapshots/<timestamp>/` before it deletes anything, and a later
registration restores it.

## What is isolated

| Inside the container | On the Mac |
|---|---|
| Orca, Claude Code, every agent and every shell they open | the `./claude-dev` launcher and nothing else |
| the project folder, at `/workspace/<name>`, read-write | — |
| `<project>/.claude-dev/home` as `/home/agent`: Claude's credentials, the git identity | — |
| Orca's own `~/.config/orca`, in a docker volume named after the container | — |
| the toolchain (Orca, Claude Code, opencode, bd, dolt, bats), from the image | — |
| any extra mounts you name, always read-only | — |

The image carries the whole install — apt state and the toolchain both — as
one Docker layer per tool, so a folder whose build succeeded is ready the
moment its container starts. Docker caches those layers per machine, which
is what makes the second folder on a Mac free; the folder itself holds only
your project, your agent home and your config. Version pins live in
`scripts/container/setup.sh`.

The exception is the runtime path. When the local build cannot run at all,
or fails, a folder runs plain `ubuntu:24.04`, where there is nothing baked
to reuse: it installs the toolchain into `<project>/.claude-dev/toolchain`
on its first start (several minutes, progress in `.claude-dev/run/setup.log`)
and mounts that back on every later start.

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
  "ui": "desktop",
  "cpus": 4,
  "memory": "8g",
  "theme": "dark",
  "terminalTheme": "Homebrew",
  "dns": "1.1.1.1",
  "extraMounts": ["/Users/you/reference-repo:/Users/you/reference-repo"]
}
```

- **`port`** — the host port Orca is published on. Chosen from 6768 upward
  at registration; the same number is used on both sides, because the
  pairing code names it.
- **`ui`** — `desktop` (the Mac's own Orca, attached to this container as a
  remote environment) or `web` (the browser tab). Written at registration:
  `desktop` when an app was found, `web` otherwise, and `web` for a folder
  registered before this key existed. Change it here to switch a folder over.
- **`cpus`, `memory`** — `null` means whatever Docker defaults to.
- **`theme`** — `dark` (the default), `light` or `system`. It reaches the
  container as `CLAUDE_ORCA_THEME`, and the entrypoint writes it into Orca's own
  settings the first time a folder starts — alongside a worktree base path of
  `<project>/.orca-worktrees`, so worktrees live in the bind mount and are
  still there on the Mac. That seed happens **once**: after Orca has run,
  whatever you change in its settings pane is what sticks, and this key stops
  mattering.
- **`terminalTheme`** — the terminal palette, by the name of one of Orca's
  own builtins; `Homebrew` (green on black — the phosphor-monitor look) is
  the default. It reaches the container as `CLAUDE_ORCA_TERMINAL_THEME` and
  lands on two paths that do deliberately different amounts.

  Orca resolves the name in the **browser**, out of `localStorage`, which the
  served `web-index.html` seeds — the full palette, all sixteen ANSI slots
  and the ground. That half only reaches a folder running an image built
  after the palette changed, which is exactly how it went unnoticed for two
  days: the folder's pull came back `403`, the launcher ran the local image
  anyway, and its older patcher skipped the seed.

  So the shipped `.zshrc` sets the colour again at every shell start, from
  the escapes xterm.js honours — but **only the default foreground and the
  cursor** (OSC 10 and 12), never the sixteen slots and never the background.
  That half needs no image, no browser state and no root. It stops where it
  does on evidence: repainting the whole palette live, on 2026-09-08, made
  Claude Code's chat input and status bar disappear, because the greys they
  are drawn in had been remapped onto the ground. Unstyled output goes green;
  every colour another program picked on purpose survives.

  Set the key to a name the shell's table does not carry and the shell leaves
  the terminal alone, which is the right thing when the browser seed is going
  to resolve that name itself.
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

Built locally, on the machine that runs it, by `acquire_image` in
`scripts/launcher.sh` — `docker build` against the folder's own template
clone, once per Mac, cached by Docker's own layer cache after that. There
is no registry in this path: no package, no token, no scope, and no CI
between a commit and the machine that needs it. The tag comes from the
`IMAGE_TAG` file at the root of this template, so a folder that only ever
runs `./claude-dev --update` moves to a new image with the rebuild.

- `Dockerfile` — Ubuntu 24.04. It only copies and calls
  `scripts/container/setup.sh`, which carries every pin (Orca Linux,
  Claude Code, beads, bats, Node 22) and is run for real inside a 24.04
  chroot by `scripts/container/verify-rootfs.sh`. This template lands at
  `/opt/claude-orca`.
- `scripts/container/entrypoint.sh` — runs as PID 1 under tini: drops to
  the `agent` user, starts `orca-ide --serve`, and writes the browser URL
  to `<project>/.claude-dev/run/orca-web-url.txt` (mode 600 — it carries a
  pairing code) plus the port to `run/port`. That fragment, decoded, is the
  pairing URL the desktop path registers; newer images also write it
  straight to `run/orca-pairing-url.txt`.
- `scripts/container/provision-run.sh` and `scripts/container/provision.d/`
  — everything that is about *this folder* rather than about the image:
  the toolchain verify, the config sync, the first-run seeds, the git
  identity, the tracker, the `orca repo add`, the guard check. They run
  **after** the URL is published, one numbered idempotent step at a time,
  each leaving `run/provision/<step>.log` and `run/provision/<step>.status`.
  No step is fatal and the next start re-runs all of them, so a step that
  died on a network hiccup is repaired by starting the folder again. They
  used to run in front of `--serve`, where a failure took the container
  with it and left nothing running that could say what went wrong.
- `scripts/container/smoke.sh` — starts the entrypoint against a throwaway
  project and fails unless Orca serves and the URL answers; run by hand
  against a freshly built image, or on the public base image to prove the
  runtime-install path (see `tests/mac-e2e.sh`).
- `tests/mac-e2e.sh` — the real bootstrap, a real build, a real container
  on a real Docker daemon, run on demand on a Mac (there is no CI to run it
  for you); its summary table is what a host-side change's commit or bead
  has to carry as evidence.

## Tests

```bash
./run-tests.sh           # everything
bats tests/*.bats        # the suite directly
bats tests/docs.bats     # one file
```
