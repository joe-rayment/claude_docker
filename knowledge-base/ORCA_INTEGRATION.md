# Orca integration

[Orca](https://onorca.dev) (v1.4.197, pinned in `scripts/install-orca.sh`)
is the session manager: worktrees, agent status dots, nested sub-agent rows,
session history. In v2 it is **not** a system application.

## The Orca in the folder

`install-orca.sh` downloads the pinned release DMG for this architecture,
records its checksum in `.claude-dev/state/orca.sha256` and copies the app
to `.claude-dev/app/Orca.app`. No cask, no `/Applications` copy: a central
Orca is exactly the unsandboxed app this design exists to avoid, so the only
Orca for this project is the one in the folder.

You never launch that copy directly. `claude-dev register` generates a tiny
launcher bundle, `<project>/Orca.app`, whose executable is one line — run
`.claude-dev/bin/orca-launch`. Double-clicking it (or `./claude-dev open`,
which is the same path from a terminal) makes `orca-launch`:

1. regenerate `.claude-dev/state/orca.sb` for this folder,
2. point `HOME` and `TMPDIR` inside `.claude-dev`,
3. `exec sandbox-exec -f state/orca.sb .claude-dev/app/Orca.app/…/Orca`.

It **replaces itself** with `sandbox-exec`, so the app inherits the terminal
and the process tree stays flat. There is no "after" in that process, which
is why the repo registration runs from a helper started just before the
exec: it waits for Orca to write `orca-runtime.json` under the user data
dir, then runs the CLI bundled inside the app **once**, as
`orca repo add --path <project>`. Adding an already-added path is a no-op,
and its exit status is logged to the launch log and discarded — repo
registration must never fail a launch.

Fail closed: no `sandbox-exec`, no profile, or no app bundle means no
launch. There is no unsandboxed fallback.

## What layer 1 costs Orca, and what it does not

`HOME` points at `.claude-dev/home`, so everything Orca keeps — its user
data directory, its dot-directory, the Claude config dir — lands in the
folder and disappears with it. Nothing under `/Users` or `/Volumes` outside
the folder is readable or writable.

- **The clipboard still works.** `(allow default)` keeps the mediated GUI
  services — WindowServer, the GPU and font services,
  `com.apple.pasteboard.1`. An editor you cannot copy out of is not usable,
  and a pasteboard connection is not file access.
- **The Keychain is cut.** `com.apple.SecurityServer`,
  `com.apple.securityd.xpc`, `com.apple.ctkd` and the keychain prompt agent
  are denied by name for the whole process tree, so Orca uses its own
  file-based auth storage and Claude Code inside falls back to
  `.credentials.json` in the folder — a credential store that lives and dies
  with the project. `com.apple.trustd` stays allowed: TLS certificate
  evaluation is not the Keychain. Set `orca.keychain: true` in
  `sandbox.json` if you want the real one back.

## Managed hooks

Orca tracks agent state through **Claude hooks it manages itself** —
`SessionStart`, `UserPromptSubmit`, `Stop`, `StopFailure`, `SubagentStart`,
`SubagentStop`, `TeammateIdle`, `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `PermissionRequest`, `PostCompact` — each invoking
`~/.orca/agent-hooks/claude-hook.sh`, which `curl`s
`http://127.0.0.1:$ORCA_AGENT_HOOK_PORT/hook/claude` with the pane metadata
Orca passes in the environment (`ORCA_PANE_KEY`, `ORCA_TAB_ID`,
`ORCA_AGENT_LAUNCH_TOKEN`, `ORCA_WORKTREE_ID`, `ORCA_AGENT_HOOK_ENV`).

With `HOME` redirected, Orca writes those entries **straight into the
folder's own config dir** — `.claude-dev/home/.claude/settings.json`, the
same file `config-sync` rewrites from the template. So the job is no longer
to copy them in; it is to **not lose them**. Every sync reads the previous
file first and re-attaches anything whose hook command mentions
`/.orca/agent-hooks/` (Orca's own matcher keys on exactly that), alongside
the template's hooks. `config-sync` never invents an Orca entry and never
drops one.

The POSTs reach `127.0.0.1` because layer 2 sets `allowLocalBinding: true`,
and the `ORCA_*` variables pass through the sandbox untouched — without them
the hook cannot tell Orca which pane it is.

**Status dots and sub-agent rows come from those entries.** If the dots stop
moving, look there first:

```bash
jq '.hooks' .claude-dev/home/.claude/settings.json
```

## Statusline

Orca installs its own statusline script into the same settings file. The
sync **chains** it: Orca's command first, ours (`config/statusline.sh`,
which renders tier, lane and cost) second, with our half remembered in
`.claude-dev/home/.claude/.orca-statusline-base` so a template change
refreshes only our half and leaves Orca's verbatim.

## Session history and transcripts

Orca discovers transcripts under `$CLAUDE_CONFIG_DIR/projects`, and its
`CLAUDE_CONFIG_DIR` is the folder's own config dir, because its `HOME` is
the folder's home. Transcripts are therefore already where it looks. The old
`orca.transcriptSymlink` knob, which linked a directory in the real home at
the sandboxed transcripts dir, is **retired**: still accepted so an older
`sandbox.json` keeps launching, but it warns once and does nothing.

## Worktrees

Orca's default worktree location is a **sibling of the repository**
(`<repo>/../<repoName>-<name>`), or `<workspaceRoot>/<repoName>/<name>` when
a Workspace root is configured. A sibling is *outside* the folder, and
therefore outside both sandboxes — so `claude-dev register` prints the
one-time setting to apply: **Settings → Repository → worktree base path** =
`<project>/.orca-worktrees`. The scope rules handle either layout; a
linked-worktree session gets that worktree plus the primary's `.git`,
`.beads` and `.claude-dev/{home,tmp,run}`.

## Orchestration mode (opt-in, off by default)

`orca.cli: true` in `sandbox.json` exposes the Orca CLI's unix socket and
token to layer 2, unlocking `orca orchestration worker-start --agent codex`,
terminal creation, the embedded browser, automations and artifacts.

It is off by default because **the CLI is a remote control for the
application that contains it**. New terminals it opens in this project's
worktrees are re-sandboxed by the shell hook, but the embedded browser,
automations and published artifacts are not. When you turn it on,
`claude-dev --doctor` prints the residual escape surface and the settings to
harden: Floating Workspace off, public artifacts off. The
`orca-socket-unreachable` probe flips its expectation to match the flag, so
the self-test always asserts the state you asked for.
