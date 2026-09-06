# Orca integration

[Orca](https://onorca.dev) (v1.4.197, pinned in the `Dockerfile`) is the
session manager: worktrees, agent status dots, nested sub-agent rows, session
history. In v3 it is a **Linux** Orca that runs inside the folder's VM and
serves its UI to your browser. There is no Mac application involved.

## How it comes up

`scripts/container/entrypoint.sh`, PID 1 in the container, starts

```
orca-ide --serve --port <port> --project-root <project>
```

as the `agent` user. Orca prints `Orca server ready` and a **Web client URL**
whose fragment carries a pairing offer; the entrypoint writes that URL to
`<project>/.claude-dev/run/orca-web-url.txt` (mode 600 — it is a credential)
and the port beside it. The Mac side waits for that file, then `open`s the
URL. The browser auto-pairs and renders the full UI. Nothing is ever served
with `--no-pairing`.

If the tab never appears, `./claude-dev logs` follows the container and
`.claude-dev/run/orca-serve.log` has Orca's own output.

## Managed hooks

Orca tracks agent state through **Claude hooks it manages itself** —
`SessionStart`, `UserPromptSubmit`, `Stop`, `StopFailure`, `SubagentStart`,
`SubagentStop`, `TeammateIdle`, `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `PermissionRequest`, `PostCompact` — each invoking
`~/.orca/agent-hooks/claude-hook.sh`, which `curl`s
`http://127.0.0.1:$ORCA_AGENT_HOOK_PORT/hook/claude` with the pane metadata
Orca passes in the environment (`ORCA_PANE_KEY`, `ORCA_TAB_ID`,
`ORCA_AGENT_LAUNCH_TOKEN`, `ORCA_WORKTREE_ID`, `ORCA_AGENT_HOOK_ENV`).

Orca and the agents share one `HOME` (`/home/agent`, which is
`<project>/.claude-dev/home` on the Mac), so Orca writes those entries
straight into the same `settings.json` that `config-sync` rewrites from the
template. The job is therefore not to copy them in; it is to **not lose
them**. Every sync reads the previous file first and re-attaches anything
whose hook command mentions `/.orca/agent-hooks/` — Orca's own matcher keys
on exactly that — alongside the template's hooks. `config-sync` never invents
an Orca entry and never drops one.

`scripts/orca-hooks-merge.sh` still ships for the case where Orca's home and
the config dir are genuinely different directories; when they are the same
file, as they are here, it detects that and does nothing.

**Status dots and sub-agent rows come from those entries.** If the dots stop
moving, look there first:

```bash
jq '.hooks' .claude-dev/home/.claude/settings.json
```

## Statusline

Orca installs its own statusline script into the same settings file. The
sync **chains** it: Orca's command first, ours (`config/statusline.sh`, which
renders tier, lane and cost) second, with our half remembered in
`.claude-dev/home/.claude/.orca-statusline-base` so a template change
refreshes only our half and leaves Orca's verbatim.

## Session history and transcripts

Orca discovers transcripts under `$CLAUDE_CONFIG_DIR/projects`, and its
`CLAUDE_CONFIG_DIR` is the same config dir the agents write to, because they
share a home. Transcripts are already where it looks.

## Worktrees

Orca's default worktree location is a **sibling of the repository**
(`<repo>/../<repoName>-<name>`). A sibling of the project is outside the one
mount the VM has, so set **Settings → Repository → worktree base path** to
`<project>/.orca-worktrees` and every worktree lands inside the folder, where
both Orca and the agents can reach it.

## Orchestration

Orca's CLI, its orchestration mode, its terminals, automations and artifacts
are simply available: the CLI and the app are the same process tree inside
the same VM, so there is no socket to expose and no flag to set.
`orca orchestration worker-start --agent codex`, `orca status` and terminal
creation all work out of the box.

Everything they spawn stays inside the VM and inside the same boundary — the
one exception worth knowing is Orca's embedded browser, which reaches the
network like anything else in the VM does.
