# Orca integration

[Orca](https://onorca.dev) (v1.4.197 at porting time) is the session
manager: worktrees, agent status dots, nested sub-agent rows, session
history. It runs **unsandboxed** on the host and spawns your login shell per
terminal — which is exactly the hook this template uses to sandbox
everything it launches (see [SANDBOX.md](SANDBOX.md)).

## Managed hooks merge

Orca tracks agent state through **Claude hooks it manages itself**, written
into the host's `~/.claude/settings.json`: `SessionStart`,
`UserPromptSubmit`, `Stop`, `StopFailure`, `SubagentStart`, `SubagentStop`,
`TeammateIdle`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`,
`PermissionRequest`, `PostCompact`. Every entry invokes
`~/.orca/agent-hooks/claude-hook.sh`, which `curl`s
`http://127.0.0.1:$ORCA_AGENT_HOOK_PORT/hook/claude` with `--noproxy
127.0.0.1` and the pane metadata Orca passes in the environment
(`ORCA_PANE_KEY`, `ORCA_TAB_ID`, `ORCA_AGENT_LAUNCH_TOKEN`,
`ORCA_WORKTREE_ID`, `ORCA_AGENT_HOOK_ENV`, `ORCA_VERSION`).

Our agents run against a *project-local* config dir
(`.claude-dev/home/.claude`), so those entries would be invisible. On every
launch the wrapper therefore **merges Orca's managed entries** — identified
by the `~/.orca/agent-hooks/claude-hook.sh` command, not by event name —
from the real `~/.claude/settings.json` into the project config dir's
`settings.json`, alongside the template's own hooks. Toggling a feature in
Orca's settings propagates on the next launch; nothing is copied that Orca
did not write.

The hook POSTs reach `127.0.0.1` because the profile sets
`allowLocalBinding: true`. `ORCA_*` variables are passed through the sandbox
untouched — without them the hook cannot tell Orca which pane it is.

**Status dots and sub-agent rows come from this merge.** If the dots stop
moving, check the merge first: `jq '.hooks' .claude-dev/home/.claude/settings.json`
and look for the `claude-hook.sh` entries.

## Statusline

Orca installs its own statusline script. The wrapper **chains** it: Orca's
script runs first, ours (`config/statusline.sh`, which renders tier, lane
and cost) appends. Neither replaces the other.

## Session history and transcripts

Orca discovers transcripts under `~/.claude/projects`, or under
`$CLAUDE_CONFIG_DIR/projects` when that variable is set. The *agent's*
environment sets `CLAUDE_CONFIG_DIR` to the project config dir; Orca's own
process does not see it. Where the panel stays empty, set

```json
{ "orca": { "transcriptSymlink": true } }
```

in `.claude-dev/sandbox.json` and the wrapper writes a **host-side** symlink
from `~/.claude/projects/<slug>` to the project config dir's `projects/`.
The link is created outside the sandbox on purpose: the sandbox cannot write
into the real home.

## Worktrees

Orca's default worktree location is a **sibling of the repository**
(`<repo>/../<repoName>-<name>`), or `<workspaceRoot>/<repoName>/<name>` when
a Workspace root is configured. The sandbox scope rules handle either
layout — a linked-worktree session gets that worktree plus the primary's
`.git`, `.beads` and `.claude-dev/{home,tmp}`.

Keeping worktrees *inside* the folder is tidier, so `claude-dev register`
prints the one-time setting to apply: **Settings → Repository → worktree base
path** = `<project>/.orca-worktrees`.

## Orchestration mode (opt-in, off by default)

`orca.cli: true` in `sandbox.json` exposes the Orca CLI's unix socket and
token (under `~/Library/Application Support/orca`, or `ORCA_USER_DATA_PATH`)
to the sandbox, unlocking `orca orchestration worker-start --agent codex`,
terminal creation, the embedded browser, automations and artifacts.

It is off by default because **the CLI is a remote control for an
unsandboxed application**. New terminals it opens in *this* project's
worktrees are re-sandboxed by the shell hook, but floating terminals, other
repositories, the embedded browser and published artifacts are not. When you
turn it on, `claude-dev --doctor` prints the residual escape surface and the
settings to harden: Floating Workspace off, public artifacts off. The
`orca-socket-unreachable` probe flips its expectation to match the flag, so
the self-test always asserts the state you asked for.
