# claude_orca

One command turns any folder on your Mac into an isolated agent workspace.
The folder gets its **own Linux virtual machine**, and the session manager
([Orca](https://onorca.dev)) runs *inside* it, serving its UI back to your
browser. Nothing this installs on the Mac runs an agent, so there is no
unconfined copy to start by mistake.

**The stack it assumes.** Claude Code is the master: it plans, decomposes,
reviews and decides. Low-cost **OpenRouter** models are the workers — a bead
names a route and Claude dispatches the slice headless, with the acceptance
contract and the check staying on the strong model ([Cheap workers without
losing quality](knowledge-base/DELEGATION_ROUTES.md#cheap-workers-without-losing-quality)).
**Orca's native coordination is on by default** for every folder this
registers, so worker terminals and orchestration are part of the setup
rather than an add-on.

One boundary does the confining, and it is the VM's own: the only Mac paths
that exist inside it are your project folder, mounted at its real absolute
path, and that folder's `.claude-dev/home`, mounted as the agent's home
directory. The rest of your Mac is not missing a permission — it is not
there. The worst a runaway `rm -rf` can do is empty the project folder.

## Requirements

- **macOS 26 on Apple silicon.** Apple's `container` runtime supports
  nothing older.
- **Apple's `container` CLI** —
  [github.com/apple/container/releases](https://github.com/apple/container/releases).
  Install the signed `.pkg`; the bootstrap prints the exact command and
  stops rather than asking for your admin password.
- **An authenticated GitHub CLI** (`brew install gh && gh auth login`). It
  fetches the bootstrap, signs in to the image registry, and its token rides
  into the VM so `gh` works there too.
- **git.**

## Quickstart

**1. Bootstrap the folder**, from inside the folder you want to isolate:

```bash
gh api repos/joe-rayment/claude_orca/contents/bootstrap.sh -H "Accept: application/vnd.github.raw" | bash
```

That checks the four requirements above, starts the container service if it
is not running, clones this template into `.claude-dev/template`, writes the
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

- **`container: command not found`** — install the `.pkg` from the releases
  page above, then re-run the one-liner.
- **`container system status` fails** — start the service by hand:

  ```bash
  container system start
  ```

  The bootstrap does this for you; it only reports when it cannot.
- **The image pull fails.** Registration falls back to building the image
  from the template's own `Dockerfile`, which takes a few minutes but needs
  nothing else. A pull failure is usually a `gh` token without
  `read:packages`; `gh auth refresh -s read:packages` fixes it.
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
./claude-dev shell            # a login shell inside the VM, in the project
./claude-dev logs             # follow the container's output
./claude-dev --how-to-run     # print the URL and the two commands again
./claude-dev --doctor         # CLI, service, image, container, port, web url
./claude-dev --update         # pull the template and the image, recreate
./claude-dev --teardown       # snapshot beads, remove this folder's install
```

`./claude-dev shell` is where you run `claude`, `bd` or `git` by hand: it is
a shell in the same VM, in the same directory, with the same home the agents
use. `--teardown` copies `.beads/issues.jsonl` to
`.claude-dev-snapshots/<timestamp>/` before it deletes anything, and a later
registration restores it.

## What is isolated

| Inside the VM | On the Mac |
|---|---|
| Orca, Claude Code, every agent and every shell they open | the `./claude-dev` launcher and nothing else |
| the project folder, at its real absolute path, read-write | — |
| `<project>/.claude-dev/home` as `/home/agent`: Claude's credentials, Orca's state, the git identity | — |
| any extra mounts you name, always read-only | — |

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
  "extraMounts": ["/Users/you/reference-repo:/Users/you/reference-repo"]
}
```

- **`port`** — the host port Orca is published on. Chosen from 6768 upward
  at registration; the same number is used on both sides, because the
  pairing code names it.
- **`cpus`, `memory`** — `null` means whatever `container` defaults to.
- **`extraMounts`** — `host:guest` pairs mounted **read-only**, always. They
  are outside the project, so the VM boundary is the only thing keeping them
  safe.

Apply a change with `./claude-dev --update`, which recreates the container.

## Orca coordination (on by default)

Orca runs natively inside the VM, so its CLI, its orchestration mode and its
worker terminals are simply there — no socket to expose, no key to set.
`orca orchestration worker-start --agent codex`, terminals, automations and
artifacts all work, and everything they spawn is inside the same VM and the
same boundary. This is a first-class part of the setup, not an add-on.

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
same VM and the same beads database.

**Which slices go there, and how quality survives it** —
[knowledge-base/DELEGATION_ROUTES.md](knowledge-base/DELEGATION_ROUTES.md#cheap-workers-without-losing-quality)
has the one explanation, with a worked `bd create` → `delegate run` →
verify sequence.

**Your OpenRouter key.** Export `OPENROUTER_API_KEY` in the shell that runs
the worker — `./claude-dev shell`, then your usual secret store, or a line
in `.claude-dev/home/.zshrc`, which is inside the folder and inside the VM.
`delegate check` says `OPENROUTER_API_KEY not set` until it is there, and no
key means no OpenRouter surface at all.

## Knowledge base

Deeper documentation lives in [knowledge-base/](knowledge-base/README.md).

## The image

`ghcr.io/joe-rayment/claude_orca`, pinned by the `IMAGE_TAG` file at the
root of this template, so a folder that only ever runs `./claude-dev
--update` moves to a new image with the pull.

- `Dockerfile` — Ubuntu 24.04 with pinned Orca Linux, Claude Code, beads,
  bats and Node 22. This template lands at `/opt/claude-orca`.
- `scripts/container/entrypoint.sh` — runs as PID 1 under tini: drops to
  the `agent` user, config-syncs, starts `orca-ide --serve`, and writes the
  browser URL to `<project>/.claude-dev/run/orca-web-url.txt` (mode 600 —
  it carries a pairing code) plus the port to `run/port`.
- `scripts/container/smoke.sh` — run inside the freshly built image by CI;
  starts the entrypoint against a throwaway project and fails the build
  unless Orca serves and the URL answers.
- `.github/workflows/image.yml` — builds, smoke-tests and publishes the
  image for both architectures.

## Tests

```bash
./run-tests.sh           # everything
bats tests/*.bats        # the suite directly
bats tests/docs.bats     # one file
```
