# claude_orca

One command turns any folder on your Mac into a sandboxed agent workspace.
Everything it installs lives **inside that folder**: the session manager
([Orca](https://onorca.dev)), this template, a pinned copy of Anthropic's
`sandbox-runtime` (`srt`), and the folder's own pinned Claude Code. There is
no central install, so there is no unsandboxed copy to start by mistake.

Two layers do the confining:

- **Layer 1 — the Orca app itself.** The folder's `Orca.app` is started by
  `sandbox-exec` under a generated Seatbelt profile: it may read and write
  the project folder, and nothing else under `/Users` or `/Volumes`.
- **Layer 2 — every shell Orca opens.** Each one re-execs into `srt` before
  any agent binary runs: writes narrowed to the worktree, network through a
  local proxy against a domain allowlist, credentials masked.

The worst a runaway `rm -rf` can do is empty the project folder and the
worktree you are sitting in.

## Setup

Once per machine, [Homebrew](https://brew.sh) and an authenticated GitHub
CLI:

```bash
brew install gh
gh auth login
```

Then, **from inside the folder you want to sandbox**:

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

Registration ends by running the sandbox self-test and **refuses to hand off
to Orca unless it passes** — see [Self-test](#self-test).

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

## Run it

Double-click **`Orca.app` in the project folder** — not a copy in
`/Applications`, which is the unsandboxed one this design exists to avoid.
The first launch needs right-click → Open, because the bundle is generated
on your machine and unsigned. From a terminal, `./claude-dev open` does
exactly the same thing. Orca opens with this folder already added; pick
**Claude Code** and work as usual. Each terminal prints
`[claude-orca] sandboxed: writes limited to <project>` as it starts, and the
first `claude` run prints a login URL to open on this Mac.

| Command | What it does |
|---|---|
| `./claude-dev open` | Start this folder's Orca, sandboxed |
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
    "cli": false,
    "keychain": false,
    "profileExceptions": { "allowRead": ["/opt/homebrew/share/fonts"] }
  }
}
```

- `network.extraAllowedDomains` — host patterns only, `*.` allowed as a
  single leading label.
- `filesystem.extraAllowWrite` — must resolve to an existing directory
  inside the folder.
- `orca.cli` — opt in to the Orca CLI socket (see below).
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

- **Claude**: log in once inside the sandbox. With the Keychain cut, Claude
  Code uses its documented plaintext store,
  `.claude-dev/home/.claude/.credentials.json`, mode 0600. It lives and dies
  with the folder.
- **GitHub**: the wrapper reads the host's `gh auth token` and passes it in
  **masked** — the agent sees a sentinel and `srt`'s proxy injects the real
  value only for `github.com` and `api.github.com`.
- Your git identity (name and email only) is seeded into the sandbox
  `.gitconfig` at bootstrap.

## Orca CLI (opt-in)

`orca.cli: true` exposes the Orca CLI's unix socket to the sandbox and
unlocks native orchestration (`orca orchestration worker-start --agent
codex`, terminals, automations, artifacts).

**This is an escape surface.** Everything the CLI drives — new terminals,
the embedded browser, automations, published artifacts — runs outside layer
2. Leave it off unless you need it; when it is on, `claude-dev --doctor`
prints the residual surface and the Orca settings to harden.

## Multi-model delegation

Claude Code stays the orchestrator. A bead names a route, Claude writes the
brief and dispatches headless:

```bash
delegate run --route glm --bead claude-orca-3sk.22
```

Routes live in `config/delegate-routes.json` (runners: `opencode run`,
`codex exec`, `gemini -p`), each job gets an ephemeral worktree under
`.claude-dev/delegate/<job>`, provider keys are masked through `srt`
credentials, and the receipt lands in the bead's notes. Interactive Codex,
Gemini and OpenCode sessions you open in Orca are sandboxed by the same
shell hook and share the beads database.

## Knowledge base

Deeper documentation lives in [knowledge-base/](knowledge-base/README.md).

## Tests

```bash
./run-tests.sh           # everything
bats tests/*.bats        # the suite directly
bats tests/docs.bats     # one file
```
