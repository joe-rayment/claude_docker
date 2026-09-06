# claude_orca

One command turns any folder on your Mac into a sandboxed agent workspace.
Everything it installs lives **inside that folder**: the session manager
([Orca](https://onorca.dev)), this template, a pinned copy of Anthropic's
`sandbox-runtime` (`srt`), and the folder's own pinned Claude Code. There is
no central install, so there is no unsandboxed copy to start by mistake.

**The stack it assumes.** Claude Code is the master: it plans, decomposes,
reviews and decides. Low-cost **OpenRouter** models are the workers — a bead
names a route and Claude dispatches the slice headless, with the acceptance
contract and the check staying on the strong model ([Cheap workers without
losing quality](knowledge-base/DELEGATION_ROUTES.md#cheap-workers-without-losing-quality)).
**Orca's native coordination is on by default** for every folder this
registers, so worker terminals and orchestration are part of the setup
rather than an add-on.

Two layers do the confining:

- **Layer 1 — the Orca app itself.** The folder's `Orca.app` is started by
  `sandbox-exec` under a generated Seatbelt profile: it may read and write
  the project folder, and nothing else under `/Users` or `/Volumes`.
- **Layer 2 — every shell Orca opens.** Each one re-execs into `srt` before
  any agent binary runs: writes narrowed to the worktree, network through a
  local proxy against a domain allowlist, credentials masked.

The worst a runaway `rm -rf` can do is empty the project folder and the
worktree you are sitting in.

## Quickstart

**1. Once per machine** — [Homebrew](https://brew.sh) and an authenticated
GitHub CLI:

```bash
brew install gh
gh auth login
```

**2. Bootstrap the folder**, from inside the folder you want to sandbox:

```bash
gh api repos/joe-rayment/claude_orca/contents/bootstrap.sh -H "Accept: application/vnd.github.raw" | bash
```

That clones this template into `.claude-dev/template`, installs the pinned
`srt`, Claude Code and `Orca.app` beside it, writes the `./claude-dev`
launcher stub and the double-clickable `Orca.app` bundle in the project
root, adds one marker-delimited block to `~/.zshrc`, `~/.zprofile` and
`~/.bash_profile` (generic — it covers every folder you bootstrap), and
registers the folder. Re-running is safe. To sandbox another folder, run the
same one-liner from inside it.

It ends by initialising this folder's `bd` tracker, running the sandbox
self-test — which **refuses to hand off to Orca** if a *confinement* probe
fails, see [Self-test](#self-test) — and then opening
**`Orca.app` in the project folder** for you. It asks nothing along the way.
A probe that only reports something unavailable (a domain unreachable, the
Orca socket down) prints a warning and hands off anyway.

**3. Sign in to Claude, inside Orca.** Orca opens with this folder already
added; pick **Claude Code** and work as usual. Each terminal prints
`[claude-orca] sandboxed: writes limited to <project>` as it starts, and the
first `claude` run prints a login URL — open it on this Mac and paste the
code back. That is the whole first run.

The app that opens is the folder's own `Orca.app`, never a copy in
`/Applications` (the unsandboxed one this design exists to avoid). Its very
first launch may need right-click → Open, because the bundle is generated on
your machine and unsigned. `./claude-dev open` opens it again later, and
`CLAUDE_ORCA_OPEN=0` tells registration not to open it at all.

**4. Optional extras — the guided walk-through.** Everything below this is
reference:

```bash
./claude-dev setup
```

Nothing here is required to start working. It walks the things only you can
do: your OpenRouter key (that is what pays the cheap workers), `gh auth
login` inside the sandbox, the git identity commits from this folder carry,
beads, and the one Orca worktree setting worth changing. Every step
is skippable — Enter or `n` skips one, `a` skips the rest — and it ends with
a menu that opens Orca, or runs `claude-dev --doctor`.

Upgrading from a pre-v2 install? `claude-dev --doctor` flags the old central
`~/.claude-orca`; `claude-dev --uninstall` and `claude-dev --remove-v1` both
remove it, naming the path first.

### If the bootstrap stops

Every dependency and precondition is checked before anything is written, so
a refusal leaves your folder untouched. The script prints the fix; these are
the ones it can't apply for you. **In every case, re-run the same one-liner
afterwards — it is idempotent and picks up where it left off.**

| It says | Paste this |
|---|---|
| `git is required` | macOS opens the Xcode Command Line Tools installer for you — click Install, wait, re-run |
| `brew is required` | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` (it asks for your password) |
| `gh is required` | `brew install gh` — though with Homebrew present the bootstrap runs this itself |
| `gh is not authenticated` | `gh auth login --web` |
| `the claude_orca shell hook cannot be installed` | `sudo chown $(id -un) <file> && chmod u+w <file>` for each file it names (`ls -l <file>` shows who owns it) — only reachable for a file it cannot even read |
| `cannot write to the project folder` | `sudo chown -R $(id -un) <folder>` |

A shell rc file left root-owned by some earlier `sudo`-ed installer is *not*
in that list: as long as it is readable and your home directory is yours,
both the bootstrap and `claude-dev rc-install` rebuild it in place with
identical contents and your own ownership, print one `Reclaimed …` line, and
carry on. No sudo, no re-run.

If it stops *after* the preflight, the last line names the step —
`Bootstrap failed during: …` — with the failing command's own output above
it.

## Day to day

| Command | What it does |
|---|---|
| `./claude-dev open` | Start this folder's Orca, sandboxed |
| `claude-dev setup` | Guided walk-through: git identity, `gh`, OpenRouter key, beads, Orca settings |
| `claude-dev --how-to-run` | Print the launch instructions again |
| `claude-dev --doctor` | Tool presence plus the 17 sandbox probes, with reasons |
| `claude-dev --update` | Pull the template, re-pin `srt`/Claude Code/Orca, re-sync, re-test |
| `claude-dev --teardown` | Remove this folder's install (beads snapshotted first) |
| `claude-dev --uninstall` | Teardown, plus the shell hook and any pre-v2 leftovers |
| `claude-dev register` | Re-register this folder (idempotent) |

## What is sandboxed, layer by layer

**Layer 1 (the app, Seatbelt).** Reads and writes are denied everywhere
under `/Users` and `/Volumes` except the project folder; writes are denied
everywhere else except the per-user temp tree and `/dev`. `HOME` and
`TMPDIR` point inside the folder, so Orca's own state, its dot-directory and
the Claude config dir all land there. Host-owned paths inside the folder —
`./claude-dev`, `Orca.app`, `.claude-dev/{bin,template,app,srt,claude,state}`,
`.claude-dev/sandbox.json`, `orca.yaml`, `.worktreeinclude`, `.envrc`,
`.beads/hooks` — are write-denied even to the app, because the host executes
them.

**Where Orca's own data goes.** `HOME` points into the folder, but Electron
on macOS takes its `userData` from NSSearchPath rather than `$HOME`, and
packaged Orca never calls `app.setPath('userData')` — so the app would write
to the real `~/Library/Application Support/orca`, which layer 1 denies, and
die on its `SingletonLock`. `orca-launch` therefore passes `--user-data-dir`,
the one switch Electron honours natively, pointing at a short per-project
root: `/private/tmp/co-<first 8 hex of sha1(project path)>`, a symlink to
`<project>/.claude-dev/home`, re-pointed on every launch and refused (exit 2)
if something that is not that symlink is in the way. Short because macOS
caps a unix socket path at 104 bytes and Orca puts its socket inside that
directory; the writes themselves still land in the folder, through the
symlink. `CLAUDE_ORCA_SHORT_ROOT` overrides the root, and `orca-launch
--print-command` prints the exports and the exact `sandbox-exec` line without
launching anything.

**Layer 2 (each shell, `srt`).** Writes: the project folder and the current
worktree only; a linked worktree also gets the primary checkout's `.git`,
`.beads` and `.claude-dev/{home,tmp,run}`. Reads: your real home is denied, so
`~/.ssh`, `~/.aws` and Documents are unreadable; the project, `~/.local/bin`,
`~/.local/share/claude` and `~/.orca/agent-hooks` are allowed. Network: only
`srt`'s localhost proxy, against `api.anthropic.com`, `claude.ai`,
`console.anthropic.com`, `platform.claude.com`, `statsig.anthropic.com`,
`*.sentry.io`, `github.com`, `api.github.com`, `*.githubusercontent.com`,
`registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`,
`cdn.playwright.dev` and `playwright.download.prss.microsoft.com`. Local
binding stays on for dev servers, the beads database and Orca's hook
endpoint.

### The exceptions, and why

- **Mediated GUI services stay reachable** at layer 1 — WindowServer, the
  GPU and font services, and the clipboard (`com.apple.pasteboard.1`). A
  window server connection is not file access, and an editor you cannot
  copy out of is not usable.
- **The Keychain is cut.** The profile denies the Keychain mach services by
  name, for the whole process tree, so Claude Code falls back to its
  documented `.credentials.json` inside the folder and Orca uses its own
  file-based auth storage. Certificate evaluation (`com.apple.trustd`) is
  not the Keychain and stays allowed. Set `orca.keychain` to `true` to hand
  the app the real Keychain back.
- **Apple Events are off** at layer 2. Nothing inside can drive another
  app, so OAuth prints a URL to paste rather than opening a browser.
- **Metadata on the path to the folder is readable.** Opening anything
  `stat()`s every parent directory, so each ancestor of the project is
  allowed for metadata only — never its contents.
- **`.git/config` and `.git/hooks` stay write-denied** inside: Orca runs git
  unsandboxed in the same repository.

### Tuning it — `.claude-dev/sandbox.json`

Read as validated data, never executed; anything malformed or out of scope
fails the launch with a one-line reason rather than widening quietly.

```json
{
  "network":    { "extraAllowedDomains": ["registry.example.com"] },
  "filesystem": { "extraAllowWrite": [".cache/build"] },
  "orca": {
    "cli": true,
    "keychain": false,
    "profileExceptions": { "allowRead": ["/opt/homebrew/share/fonts"] }
  }
}
```

- `network.extraAllowedDomains` — host patterns only, `*.` allowed as a
  single leading label.
- `filesystem.extraAllowWrite` — must resolve to an existing directory
  inside the folder.
- `orca.cli` — the Orca CLI socket, and with it native orchestration.
  **Seeded `true` for a newly registered folder**; set it to `false` to opt
  out (see below).
- `orca.keychain` — re-allow the Keychain services for layer 1.
- `orca.profileExceptions` — extra absolute `allowRead`/`allowWrite` paths
  for layer 1 only; no traversals, and host-owned paths are re-denied after
  them.

The file itself is write-denied inside both layers: what it contains widens
a sandbox one launch later, so you edit it from outside.

## Self-test

Seventeen probes exercise the boundary from the inside: writing outside,
reading the real home, the Keychain, sibling worktrees, a blocked and an
allowed domain, the Orca socket, `sandbox-exec` presence, the `srt` version
pin, a `.git/hooks` audit, and — from a terminal Orca opened — that layer 1
is really active, that `HOME` was redirected into the folder, that Orca's
data landed there, and that the host-owned files are write-denied.
`claude-dev --doctor` prints the table with a reason per probe.

## Auth

- **Claude**: nothing to do. Claude Code asks you to sign in the first time
  it runs inside the sandbox — from Orca, or from a sandboxed shell — and
  with the Keychain cut it writes its documented plaintext store,
  `.claude-dev/home/.claude/.credentials.json`, mode 0600. It lives and dies
  with the folder.
- **GitHub**: the wrapper reads the host's `gh auth token` and passes it in
  **masked** — the agent sees a sentinel and `srt`'s proxy injects the real
  value only for `github.com` and `api.github.com`.
- Your git identity (name and email only) is seeded into the sandbox
  `.gitconfig` at bootstrap.

## Orca coordination (on by default)

`orca.cli: true` exposes the Orca CLI's unix socket to the sandbox and
unlocks native orchestration (`orca orchestration worker-start --agent
codex`, terminals, automations, artifacts). `claude-dev register` **seeds it
`true`** when it creates a folder's `sandbox.json`, because coordinating
multi-provider agents through Orca is a first-class part of this setup, not
an add-on. An existing `sandbox.json` is never rewritten — including one
with no `orca` key, which `gen-settings.sh` still reads as `false`.

**What that grants, plainly.** The sandboxed agent can reach the host Orca
app's unix socket and drive it. Worker terminals it spawns re-enter the
sandbox via the layer-2 shell hook when they open in the project folder
(`--worktree current`); anything the CLI drives *outside* the folder does
not — the embedded browser, automations and published artifacts all run
outside layer 2. `claude-dev register` and `claude-dev --doctor` both say
the mode is on and name that residual surface plus the Orca settings to
harden.

**Opt out with one key**: `{"orca": {"cli": false}}` in
`.claude-dev/sandbox.json`.

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
`.claude-dev/delegate/<job>`, provider keys are masked through `srt`
credentials, and the receipt lands in the bead's notes. Interactive Codex,
Gemini and OpenCode sessions you open in Orca are sandboxed by the same
shell hook and share the beads database.

**Which slices go there, and how quality survives it** —
[knowledge-base/DELEGATION_ROUTES.md](knowledge-base/DELEGATION_ROUTES.md#cheap-workers-without-losing-quality)
has the one explanation, with a worked `bd create` → `delegate run` →
verify sequence.

**Your OpenRouter key.** Put it in
`.claude-dev/state/openrouter.key` — one line, nothing else:

```bash
printf '%s\n' 'sk-or-...' > .claude-dev/state/openrouter.key
chmod 600 .claude-dev/state/openrouter.key
```

Your key is written only from your own paste — by hand, as above, or through
the `claude-dev setup` prompt on this Mac, which reads it without echoing it
and shows you a masked tail. The
shell wrapper reads it on the host at launch (where the sandbox cannot see
it), exports `OPENROUTER_API_KEY` into the session, and has `srt` mask it —
the agent sees a sentinel and the proxy injects the real value only on the
way to `openrouter.ai`. An `OPENROUTER_API_KEY` already exported in your
shell wins, so the file is a default and not an override. No key file means
no export and no mask: a folder without one has no OpenRouter surface at all.

`claude-dev register` seeds `openrouter.ai` into `network.extraAllowedDomains`
for **new** folders only. A folder registered before this change keeps its
own `sandbox.json` untouched; add the one line yourself:

```json
{"network": {"extraAllowedDomains": ["openrouter.ai"]}}
```

## Knowledge base

Deeper documentation lives in [knowledge-base/](knowledge-base/README.md).

## The Linux container image (v3, in progress)

A second isolation model is being built alongside the one above: instead of
Seatbelt on the Mac, the project folder gets its own Linux VM and Orca runs
*inside* it, headless, serving its web UI back to the Mac's browser. The VM
boundary is the sandbox — the only Mac paths inside are the project folder
and its own `.claude-dev/home`.

- `Dockerfile` — Ubuntu 24.04 with pinned Orca Linux, Claude Code, beads,
  bats and Node 22. This template lands at `/opt/claude-orca`.
- `scripts/container/entrypoint.sh` — runs as PID 1 under tini: drops to
  the `agent` user, config-syncs, starts `orca-ide --serve`, and writes the
  browser URL to `<project>/.claude-dev/run/orca-web-url.txt` (mode 600 —
  it carries a pairing code) plus the port to `run/port`.
- `scripts/container/smoke.sh` — run inside the freshly built image by CI;
  starts the entrypoint against a throwaway project and fails the build
  unless Orca serves and the URL answers.
- `.github/workflows/image.yml` — builds, smoke-tests and publishes
  `ghcr.io/joe-rayment/claude_orca`.

The Mac-side launcher for it is not written yet; the plan is
`.claude/plans/container-v3.md`.

## Tests

```bash
./run-tests.sh           # everything
bats tests/*.bats        # the suite directly
bats tests/docs.bats     # one file
```
