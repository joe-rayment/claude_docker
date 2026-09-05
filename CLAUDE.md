# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->


<!-- BEGIN PROJECT SECTIONS -->
## Build & Test

```bash
./run-tests.sh           # the whole suite
bats tests/*.bats        # the same thing, directly
bats tests/docs.bats     # one file
```

Tests are bats-core, and they run on Linux as well as macOS: the suite stubs
`brew`, `gh`, `npm` and `srt`, and exercises the wrapper's logic rather than
Seatbelt itself. The Seatbelt behaviour is checked on a real Mac by the
13-probe self-test (`claude-dev --doctor`), which `bootstrap.sh` runs at
registration and refuses to hand off without.

## Architecture Overview

One command (`gh api … bootstrap.sh | bash`) installs a host-owned tree under
`~/.claude-orca` (template clone, pinned `@anthropic-ai/sandbox-runtime`,
`bin/claude-dev`) and adds one marker-delimited line to the user's shell rc.
That line re-execs any login shell started inside a registered project into
Apple's Seatbelt sandbox via `srt`, *before* any agent binary runs — so every
terminal Orca (onorca.dev) opens in the folder is sandboxed, whichever CLI it
launches. The generated profile scopes writes to the project folder and the
current worktree, denies reading the real home, and allowlists egress through
`srt`'s proxy. Inside, `HOME` is `<project>/.claude-dev/home`, whose
`.claude` config dir is populated from this repo's `config/` by a
checksum-gated sync; the hook/guard suite (lane, tier, bd-guard,
outbound-guard, auth-guard, contract-gate, cost-mirror…) runs from there,
with Orca's own managed hooks merged in for status dots and sub-agent rows.
`/tier` state lives in `.claude-dev/state/tier.json` and is injected into
sub-agent spawns by a `PreToolUse` hook, because agent files are write-denied
inside the sandbox.

## Conventions & Patterns

- **bash 3.2.** macOS ships 3.2.57 and the wrapper runs before anything newer
  is on PATH. No associative arrays, no `mapfile`, no `${x^^}`, no `+=` onto
  an empty array under `set -u`. `scripts/lint-bash32.sh` and a real 3.2
  build in the suite enforce it.
- **Paths come from `scripts/lib/paths.sh`.** Never hard-code `~/.claude`,
  the host dir, or a project path; resolve through the helpers so the same
  script works from the repo copy and from the `~/.claude-orca/template/bin`
  symlink.
- **Frozen contracts.** A bead's `FROZEN` files are frozen from its `RED-AT`
  commit onward: the test is committed red first, the implementation second,
  and the test is never edited to make an implementation pass.
- **Nothing unsandboxed executes anything agent-writable.** Config the
  sandbox can write (`sandbox.json`, `settings.local.json`) is read as
  validated data, never sourced or run by the host side.
<!-- END PROJECT SECTIONS -->
