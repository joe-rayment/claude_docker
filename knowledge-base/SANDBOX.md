# The sandbox

Apple Seatbelt (`sandbox-exec`) driven by Anthropic's
`@anthropic-ai/sandbox-runtime` (`srt`), pinned at **0.0.75** in
`scripts/install-srt.sh` (`SRT_VERSION=`, the single source of truth — the
`srt-version-pinned` probe reads that line back).

## Trust boundary

Two roots, and the rule that follows from them.

| Root | Owner | Sandbox access |
|---|---|---|
| `~/.claude-orca/` — `bin/`, `template/`, `srt/`, `shellrc.zsh`, `shellrc.bash`, `state/` | host | read-only |
| `<project>/` — code, `.beads/`, `.claude-dev/{home,tmp,state,sandbox.json}`, worktrees | agent | read-write |

**Nothing that runs unsandboxed may execute or source anything the agent can
write.** `sandbox.json` is therefore read as *validated data only*: extra
domains must match a host pattern, extra write paths must resolve inside the
folder, and anything else exits 2 with a one-line reason
(`scripts/sandbox/gen-settings.sh`). There is no `claude-dev` script in the
project root; the launcher lives on PATH and is symlinked into the
host-owned template.

Files the host executes implicitly are write-denied *inside* the sandbox, on
top of `srt`'s own mandatory list (shell rc files, `.mcp.json`, `.ripgreprc`,
`.vscode`, `.idea`, `.claude/commands`, `.claude/agents`, `.git/hooks`,
`.git/config`): `orca.yaml`, `.worktreeinclude` and `.envrc`, in the primary
checkout *and* in the current worktree, plus `.beads/hooks/**` in the primary
checkout only — a linked worktree has no `.beads` of its own, it writes
through the primary's.

## How every shell ends up inside

`~/.zshrc` (and `~/.bash_profile`) source `~/.claude-orca/shellrc.zsh` from a
marker-delimited line. That file asks `claude-orca-root` whether the cwd
belongs to a registered project (`git rev-parse --git-common-dir` → primary
checkout → does it have `.claude-dev/sandbox.json`? non-git folders walk up),
and if so re-execs into `claude-orca-shell`, which generates the settings and
runs `srt --settings <generated> -c 'exec zsh -l'`.

Orca spawns your **login shell** per terminal, so this happens before Orca
types `claude --dangerously-skip-permissions` — and equally for Codex,
Gemini, OpenCode, `orca terminal create --command …`, and a plain Terminal
window opened in the folder. Non-interactive login shells (`zsh -l -c …`)
carry their execution string through the re-exec, and the block is repeated
in `.zprofile`.

**Fail closed.** If `srt` or `sandbox-exec` are missing, or the wrapper
errors, the shellrc shadows `claude`, `codex`, `gemini` and `opencode` with
functions that refuse and print why. There is no unsandboxed fallback.

## Scope

`allowWrite`, derived per session:

- **Primary checkout**: `<project>`, `<project>/.claude-dev/home`,
  `<project>/.claude-dev/tmp`.
- **Linked worktree**: `<worktree>`, plus the primary's `.git`, `.beads`,
  `.claude-dev/home`, `.claude-dev/tmp` — and nothing else. Sibling
  worktrees are explicitly not writable (there is a probe for it).

`denyRead: [<real home>]`; `allowRead` adds back `<project>`, `<worktree>`,
`~/.claude-orca`, `~/.local/bin`, `~/.local/share/claude`,
`~/.orca/agent-hooks` (and the Orca runtime dir only in CLI mode). `~/.ssh`,
`~/.aws`, the Keychains and Documents are unreadable by construction, not by
a rule someone remembered to write.

Network: `strictAllowlist: true` over the defaults — `api.anthropic.com`,
`claude.ai`, `console.anthropic.com`, `platform.claude.com`,
`statsig.anthropic.com`, `*.sentry.io`, `github.com`, `api.github.com`,
`*.githubusercontent.com`, `registry.npmjs.org`, `pypi.org`,
`files.pythonhosted.org`, `cdn.playwright.dev`,
`playwright.download.prss.microsoft.com` (the last two so `take-screenshot
url` can fetch its headless browser) — union
`network.extraAllowedDomains`. Also
`allowLocalBinding: true` (dev servers, the Dolt server, Orca's hook
endpoint on `127.0.0.1:$ORCA_AGENT_HOOK_PORT`), `allowPty: true`,
`enableWeakerNetworkIsolation: true` (one `trustd` mach-lookup, needed for Go
TLS in `gh`/`bd`/`dolt`), `allowAppleEvents: false`, and `allowUnixSockets:
[]` — except in Orca CLI mode, where it carries the same Orca runtime dir
`allowRead` gets, because the socket and a readable path to it are one
decision.

The generated file is
`<primary>/.claude-dev/state/srt-<sha1(worktree)>.json`, validated in the
suite against the pinned `srt` package's own zod schema.

## Environment inside

```
HOME                  <primary>/.claude-dev/home
CLAUDE_CONFIG_DIR     $HOME/.claude
TMPDIR                <primary>/.claude-dev/tmp
GIT_CONFIG_GLOBAL     $HOME/.gitconfig
GH_CONFIG_DIR         $HOME/.config/gh
BEADS_DIR             <primary>/.beads
ORCA_USER_DATA_PATH   <real home>/Library/Application Support/orca
CLAUDE_ORCA_SANDBOXED 1
CLAUDE_ORCA_REAL_HOME <real home>
CLAUDE_ORCA_ROOT      <primary>
DISABLE_AUTOUPDATER   1
PATH                  /opt/homebrew/bin:<real home>/.local/bin:~/.claude-orca/template/bin
```

The sandbox `HOME` carries our own `.zshrc`, so the environment inside is the
template's, never the user's dotfiles.

## The self-test

Thirteen probes, run by `scripts/sandbox/selftest.sh` inside the sandbox.
`bootstrap.sh` runs them at registration and **refuses to hand off to Orca**
unless they pass; `claude-dev --doctor` re-runs them and prints the table
with a one-line reason each. `--dry-run` lists the probes without executing
any of them.

| Probe | Expectation |
|---|---|
| `write-outside-denied` | `touch` under the real home fails |
| `read-real-home-denied` | `ls <real home>/.ssh` (or the home) fails |
| `keychain-denied` | `security find-generic-password -s 'Claude Code-credentials'` fails |
| `project-writable` | a temp file under the project can be created and removed |
| `worktree-writable` | same, in the current worktree |
| `sibling-worktree-denied` | another worktree is not writable |
| `tmp-outside-denied` | `touch` under `/private/tmp` fails |
| `network-blocked-domain` | `curl https://example.com` fails |
| `network-allowed-domain` | `curl https://api.anthropic.com/` returns any HTTP status |
| `orca-socket-unreachable` | `orca status --json` fails unless `orca.cli` is true |
| `sandbox-exec-present` | `sandbox-exec` on PATH (Darwin; reports `bwrap` elsewhere) |
| `srt-version-pinned` | installed `srt` version equals the `SRT_VERSION` pin |
| `git-hooks-audit` | git hooks reference only paths covered by `denyWrite` |

A probe returns 0 (expected), 1 (violated) or 2 (could not run). The runner
writes a results JSON and exits 0 only when no probe failed.

## Auditing the generated profile

`claude-orca-shell` runs the self-test with `SRT_DEBUG=true` and captures
`srt`'s stderr — the **generated Seatbelt profile** — to

```
<primary>/.claude-dev/state/srt-debug-<sha1(worktree)>.log
```

Read that file when a denial surprises you: it is the actual policy the
kernel enforced, not a description of it.

## bash 3.2

macOS ships bash **3.2.57**, and the wrapper runs before anything newer is on
PATH. Every script here must run under it: no associative arrays, no `${x^^}`,
no `mapfile`, and in particular no `+=` onto an empty array under `set -u`
(the one real incompatibility this port hit). `scripts/lint-bash32.sh` and a
real 3.2 build in the test suite enforce it — see `tests/helpers/ensure_bash32`.

## Known limits

- `sandbox-exec` is deprecated-but-shipped; Claude Code's own sandbox uses it,
  so it is the supported path in practice. If it ever goes, the fallback is
  `srt`'s Linux backend inside Apple's `container` — out of scope today.
- Apple Events stay denied, so OAuth flows print a URL to paste rather than
  opening a browser.
- `.git/config` stays write-denied inside because Orca runs git *unsandboxed*
  in the same repository; remotes are set by you or by bootstrap, never by
  the agent.
