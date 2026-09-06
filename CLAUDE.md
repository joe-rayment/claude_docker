# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
<!-- beads: rules live in ~/.claude/CLAUDE.md § Beads; markers kept so bd skips re-injection -->
<!-- END BEADS INTEGRATION -->


<!-- BEGIN PROJECT SECTIONS -->
## Build & Test

```bash
./run-tests.sh           # the whole suite
bats tests/*.bats        # the same thing, directly
bats tests/docs.bats     # one file
```

Tests are bats-core, and they run on Linux as well as macOS: the suite stubs
`brew`, `gh`, `npm`, `curl`, `hdiutil` and `srt`, and exercises the scripts'
logic rather than Seatbelt itself. The Seatbelt behaviour is checked on a
real Mac by the 17-probe self-test (`claude-dev --doctor`), which
registration runs and refuses to hand off without.

## Architecture Overview

One command (`gh api … bootstrap.sh | bash`), run from inside a project
folder, installs everything **into that folder**: `<project>/.claude-dev/`
carries the template clone, a pinned `@anthropic-ai/sandbox-runtime`
(`srt`), a pinned Claude Code, `app/Orca.app` from the pinned release DMG,
and `bin/`. There is no central install. `claude-dev register` seeds a new
folder for the stack this template assumes — Claude Code as the master,
low-cost OpenRouter models as delegate-route workers (`openrouter.ai` in
`network.extraAllowedDomains`), and Orca's native coordination on
(`orca.cli: true`) — and `claude-dev setup` is the guided walk-through of
the human half.

Two Seatbelt layers confine it. **Layer 1**: `Orca.app` in the project root
is a generated launcher bundle that runs `.claude-dev/bin/orca-launch`,
which regenerates `.claude-dev/state/orca.sb`, redirects `HOME` and `TMPDIR`
into the folder, and `exec`s `sandbox-exec` on the folder's own Orca — so
the app sees the project folder and nothing else under `/Users`. **Layer
2**: one marker-delimited block in the user's shell rc walks up from `$PWD`
to `.claude-dev/bin/claude-orca-shell` and re-execs any login shell into
`srt` *before* any agent binary runs, scoping writes to the project and the
current worktree, denying the real home, and allowlisting egress through
`srt`'s proxy. `scripts/sandbox/host-owned-paths.sh` is the one list of
host-executed paths inside the folder that both layers write-deny.

Inside, `HOME` is `<project>/.claude-dev/home`, whose `.claude` config dir
is populated from this repo's `config/` by a checksum-gated sync that
preserves Orca's own managed hook entries (status dots, sub-agent rows). The
hook/guard suite (lane, tier, bd-guard, outbound-guard, auth-guard,
contract-gate, cost-mirror…) runs from there. `/tier` state lives in
`.claude-dev/run/tier.json` and is injected into sub-agent spawns by a
`PreToolUse` hook, because agent files are write-denied inside the sandbox.

## Conventions & Patterns

- **bash 3.2.** macOS ships 3.2.57 and the wrapper runs before anything newer
  is on PATH. No associative arrays, no `mapfile`, no `${x^^}`, no `+=` onto
  an empty array under `set -u`. `scripts/lint-bash32.sh` and a real 3.2
  build in the suite enforce it.
- **Paths come from `scripts/lib/paths.sh`.** Never hard-code `~/.claude`,
  the host dir, or a project path; resolve through the helpers so the same
  script works from a repo checkout and from the
  `<project>/.claude-dev/template` clone a folder actually runs.
- **`run/` holds results, `state/` holds authority.** Anything the host
  feeds to `sandbox-exec` or `srt` lives in `.claude-dev/state` and is
  write-denied to both layers; what the sandbox itself writes (tier state,
  self-test results, debug captures, the config-sync hash) lives in
  `.claude-dev/run`.
- **Frozen contracts.** A bead's `FROZEN` files are frozen from its `RED-AT`
  commit onward: the test is committed red first, the implementation second,
  and the test is never edited to make an implementation pass.
- **Nothing unsandboxed executes anything agent-writable.** Config the
  sandbox can write (`sandbox.json`, `settings.local.json`) is read as
  validated data, never sourced or run by the host side.
<!-- END PROJECT SECTIONS -->
