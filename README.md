# claude_orca

One command turns any folder on your Mac into a sandboxed agent workspace:
every terminal opened in that folder re-execs into Apple's Seatbelt sandbox
(through Anthropic's `sandbox-runtime`) *before* any agent binary runs, and
[Orca](https://onorca.dev) drives the sessions — worktrees, status dots,
sub-agent rows, session history.

The worst a runaway `rm -rf` can do is empty the project folder and the
worktree you are sitting in.

## Setup

Once per machine. You need [Homebrew](https://brew.sh) and the GitHub CLI
authenticated:

```bash
brew install gh
gh auth login
```

Then, **from inside the project folder you want to sandbox**:

```bash
gh api repos/joe-rayment/claude_orca/contents/bootstrap.sh -H "Accept: application/vnd.github.raw" | bash
```

Everything it installs lands **inside that folder**, under `.claude-dev/`:
the template clone, the pinned `srt` runtime, this folder's own pinned copy
of Claude Code, `Orca.app`, and `bin/` (which leads the sandbox `PATH`, so
the `claude` an agent here can reach is this folder's copy and never a
central one). There is no central install and no central Orca. The
bootstrap also writes the `./claude-dev` launcher stub in the project root,
adds one marker-delimited block to `~/.zshrc`, `~/.zprofile` and
`~/.bash_profile` — generic, so it covers every folder you bootstrap — and
registers the folder. Re-running is safe. To bootstrap another folder, run
the same one-liner from inside it; from a folder that already has one:

```bash
./claude-dev register
```

Upgrading from a pre-v2 install? `claude-dev --doctor` flags the old
central `~/.claude-orca` and `claude-dev --remove-v1` removes it.

Registration ends by running the sandbox self-test, and **refuses to hand
off to Orca unless it passes** — see [Self-test](#self-test).

## Daily use

Open the folder in Orca, pick **Claude Code**, and work as usual. Orca
spawns your login shell in the worktree; the shell hook re-execs it into
the sandbox before Orca types `claude --dangerously-skip-permissions`, so
the agent is sandboxed no matter which CLI you launch.

The launcher on your PATH:

| Command | What it does |
|---|---|
| `claude-dev register <dir>` | Register a project folder (idempotent) |
| `claude-dev --doctor` | Tool presence + the 13 sandbox probes, with reasons |
| `claude-dev --update` | Pull the host template and refresh the pinned tools |
| `claude-dev --teardown` | Remove one project's `claude_orca` artifacts (beads snapshotted first) |
| `claude-dev --uninstall` | Remove the host-side install and the shell hook |
| `claude-dev rc-install` / `rc-uninstall` | Add/remove the shell hook only |

## What the sandbox allows

- **Writes**: the project folder and the current worktree only. A linked
  worktree session also gets the primary checkout's `.git`, `.beads`, and
  `.claude-dev/{home,tmp}` — nothing else. Sibling worktrees, `/private/tmp`
  and your real home are read-only or invisible.
- **Reads**: your real home is denied, so `~/.ssh`, `~/.aws`, Keychains and
  Documents cannot be read. Allowed: the project (which is where the whole
  install lives), `~/.local/bin`, `~/.local/share/claude`,
  `~/.orca/agent-hooks`, and Orca's runtime dir when `orca.cli` is on.
- **Network**: only through `srt`'s localhost proxy against an allowlist —
  `api.anthropic.com`, `claude.ai`, `console.anthropic.com`,
  `platform.claude.com`, `statsig.anthropic.com`, `*.sentry.io`,
  `github.com`, `api.github.com`, `*.githubusercontent.com`,
  `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`,
  `cdn.playwright.dev`, `playwright.download.prss.microsoft.com`. Local
  binding is on (dev servers, the beads Dolt server, Orca's hook endpoint).
- **Apple Events are off.** Nothing inside can drive another app, so OAuth
  prints a URL instead of opening a browser.
- **Environment**: `HOME` is `<project>/.claude-dev/home`, `TMPDIR` is
  `<project>/.claude-dev/tmp`, `BEADS_DIR` is the primary `.beads`. Your own
  dotfiles are not sourced inside.

### Extending it

Per project, in `<project>/.claude-dev/sandbox.json` — read as validated
data, never executed:

```json
{
  "network": { "extraAllowedDomains": ["registry.example.com"] },
  "filesystem": { "extraAllowWrite": [".cache/build"] },
  "orca": { "cli": false, "transcriptSymlink": true }
}
```

- `network.extraAllowedDomains` — host patterns only (`*.` wildcard allowed
  as a single leading label); anything else is rejected.
- `filesystem.extraAllowWrite` — must resolve to an existing directory
  inside the folder.
- `orca.cli` — opt in to the Orca CLI socket (see below).
- `orca.transcriptSymlink` — link the sandbox config dir's `projects/` into
  `~/.claude/projects/<slug>` so Orca's session-history panel sees
  transcripts.

Files the *host* executes implicitly stay write-denied inside the sandbox on
top of `srt`'s own list: `orca.yaml`, `.worktreeinclude`, `.envrc`,
`.git/hooks/**`, `.git/config`, `.beads/hooks/**`.

## Self-test

Thirteen probes actually exercise the boundary — writing outside, reading
the real home, the Keychain, sibling worktrees, a blocked and an allowed
domain, the Orca socket, `sandbox-exec` presence, the `srt` version pin, and
an audit of `.git/hooks/*`. `claude-dev --doctor` prints the table with a
reason per probe; `bootstrap.sh` runs it at registration and refuses to hand
off without a pass. `srt`'s generated Seatbelt profile is saved to
`.claude-dev/state/srt-debug-<hash>.log` for audit.

## Auth

- **Claude**: log in once inside the sandbox. Because the real home (and so
  the Keychain) is unreadable, Claude Code falls back to its documented
  plaintext store — `.claude-dev/home/.claude/.credentials.json`, mode 0600.
  Apple Events are off, so you paste the URL into your own browser and paste
  the code back.
- **GitHub**: the wrapper reads the host's `gh auth token` and passes it in
  **masked** — the agent sees a sentinel; `srt`'s proxy injects the real
  value only for `github.com` / `api.github.com`. Masking requires TLS
  termination by the proxy's ephemeral CA. Open question, to be settled by
  the self-test on a real Mac: Go clients (`gh`, `bd`, `dolt`) verify against
  Security.framework roots and ignore `SSL_CERT_FILE`, so if `gh auth status`
  fails under masking, masking becomes opt-in in `sandbox.json` and the token
  is passed through unmasked instead.
- Your git identity (name and email only) is seeded into the sandbox
  `.gitconfig` at bootstrap.

## Orca CLI (opt-in)

`orca.cli: true` exposes the Orca CLI's unix socket to the sandbox and
unlocks native orchestration (`orca orchestration worker-start --agent
codex`, terminals, automations, artifacts).

**This is an escape surface.** Everything the CLI drives — new terminals,
the embedded browser, automations, published artifacts — runs *outside* the
sandbox. Leave it off unless you need it; when it is on, `claude-dev
--doctor` prints the residual surface and the Orca settings to harden
(Floating Workspace off, public artifacts off).

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
