# Plan — claude_orca: port claude_docker to a macOS Seatbelt sandbox managed by Orca

Filed 2026-09-04. Beads: epic `claude-orca` (see `bd list`). Source material:
`attachments/claude_docker/` (the Docker template, 566 commits, last 2026-09-03),
Orca 1.4.197 source (github.com/stablyai/orca, MIT), Anthropic `@anthropic-ai/sandbox-runtime`
0.0.75 (`srt`, github.com/anthropic-experimental/sandbox-runtime, the engine behind Claude
Code's own `/sandbox`). Both were cloned and read; `file:line` refs below point into them.

## 1. Goal

Keep the idea — one command pulls a template from GitHub and every agent that touches the
folder runs sandboxed *to that folder* — and change three things:

1. **Apple's native sandbox instead of Docker.** Seatbelt (`sandbox-exec`) via Anthropic's
   `srt`, which generates the profile and runs a domain-allowlisting proxy. Hard requirement:
   the worst a "delete everything" can do is empty the project folder (+ the current worktree).
2. **Orca (onorca.dev) as the session manager**, fully featured: worktrees, agent status dots,
   sub-agent child rows, session history. Beads, `--dangerously-skip-permissions`, `/tier`
   and the hook/guard suite stay. Claude Code stays primary; other CLIs (Codex, Gemini,
   OpenCode) work inside the same sandbox and take instructions from Claude.
3. **Drop** the tmux fleet sidebar, the worktree-sessions layer (cs-new/peers/session-title),
   and everything Docker-bound (image, entrypoint, iptables egress firewall, Xvfb).

Non-goals: Linux/Windows hosts (srt has a bubblewrap backend; not exercised), Orca running
inside a container (the old `knowledge-base/ORCA_SANDBOXED.md` idea — inverted here), the
Claude Code plugin distribution (old open bead 54s) — a direct config dir is simpler.

## 2. Findings that shape the design

### Old template (attachments/claude_docker)
- Bootstrap: `gh api …/bootstrap.sh | bash` → clones template into `<project>/.claude-dev/`,
  installs `./claude-dev`, builds the image, mounts `..` as `/workspace`, home in a named
  volume (`claude-dev:181,206`, `docker-compose.yml:25-27`). Claude native binary pinned,
  autoupdater off (`Dockerfile:129-169`).
- Hook surface (`config/claude-settings.json`): UserPromptSubmit lane/outbound-guard/
  cost-mirror/tier-display/session-title; SessionStart prime-memories/context-detect/
  code-map-prime/disk-cleanup/tier-reconcile/tier-prime/image-drift/cost-mirror/peers;
  PreToolUse bd-guard, outbound-guard (Bash), tier-gate (Agent), workflow-lint, delegation-gate.
- Host-portable as-is: tier-*, lane, bd-guard, outbound-guard, auth-guard, contract-gate,
  delegation-gate, cost-mirror, prime-memories, session-end-audit, workflows, agents/*.md,
  rulebook. Docker-bound: entrypoint, egress-firewall (iptables), image-drift, delegate.sh
  (`/workspace`, iptables check), code-map-guard (`/opt/code-map`), take-screenshot (Xvfb/tmux).
- Removal map: fleet = `scripts/fleet.sh`, `fleet-menu.sh`, `config/tmux.conf`, tests
  `fleet.bats`/`tmux-fleet.bats`; sessions = `cs-new.sh`, `peers.sh`, `session-title.sh`,
  hooks `session-title` (UserPromptSubmit) + `peers` (SessionStart), rulebook line 41,
  `.zshrc:71`. Independent of everything else (fleet scout).
- Delegation routes already exist: `config/delegate-routes.json` routes `glm`/`local` to
  `opencode` headless with scrubbed env, ephemeral worktree, receipt + bead notes
  (`scripts/delegate.sh`). Only its Docker bits need replacing.

### Orca (source, v1.4.197)
- Spawns the user's **login shell** per terminal (`src/main/providers/local-pty-launch-plan.ts:243`
  `shellArgs: ['-l']`, node-pty, cwd = worktree) and delivers the agent command to it
  (`claude '--dangerously-skip-permissions'`, `src/shared/tui-agent-permissions.ts:7`). So the
  binary resolves through the user's shell rc → a shell-level hook can sandbox *every*
  terminal Orca opens in a project, not just Claude.
- Per-agent global overrides exist (`agentCmdOverrides`, `agentDefaultArgs`,
  `agentDefaultEnv` — `src/shared/global-settings-types.ts:366-378`); no per-repo launch hook,
  no command-wrapper/sandbox setting for local worktrees.
- Worktree default location is a **sibling of the repo**: `<repo>/../<repoName>-<name>`
  (`src/main/ipc/worktree-logic.ts:217`), or `<workspaceRoot>/<repoName>/<name>` when a
  Workspace root is set (`:127-129`); per-repo `worktreeBasePath` override
  (`src/shared/repo-types.ts:58`, Settings → Repository).
- Status/sub-agent tracking = **Orca-managed Claude hooks** written to `~/.claude/settings.json`
  (`src/main/claude/hook-settings.ts:37-97,99`): SessionStart, UserPromptSubmit, Stop,
  StopFailure, SubagentStart, SubagentStop, TeammateIdle, PreToolUse, PostToolUse,
  PostToolUseFailure, PermissionRequest, PostCompact → `~/.orca/agent-hooks/claude-hook.sh`
  (`src/main/agent-hooks/installer-utils.ts:104-106`) which curls
  `http://127.0.0.1:$ORCA_AGENT_HOOK_PORT/hook/claude` with `--noproxy 127.0.0.1` and env
  metadata `ORCA_PANE_KEY/TAB_ID/AGENT_LAUNCH_TOKEN/WORKTREE_ID/AGENT_HOOK_ENV/VERSION`
  (`src/main/agent-hooks/hook-post-command.ts`). Plus a statusline script. Orca also reads
  transcripts under `~/.claude/projects` or `$CLAUDE_CONFIG_DIR/projects` (scout:
  `transcript-file-discovery.ts`, `worktree-retirement-discovery.ts:174`).
- `orca` CLI talks to the app over a unix socket + token under
  `~/Library/Application Support/orca` (`src/cli/runtime/metadata.ts:54`; `ORCA_USER_DATA_PATH`
  override `:50`). It can create terminals with arbitrary commands, drive the embedded browser,
  schedule automations, publish artifacts, and run an orchestration layer
  (`docs/site/content/docs/cli/orchestration.mdx`: `worker-start --agent codex`, messages,
  gates). That is a remote control for an **unsandboxed** app — see §4.
- First launch imports `~/.claude`; "Claude Agent Teams" launch via `orca claude-teams`;
  Agent Dashboard shows nested Claude sub-agents as child rows (`docs/.../agents/claude-code.mdx`).

### Seatbelt / srt
- `sandbox-exec` is deprecated-but-present on macOS 15/26 (apple/containerization#737); Claude
  Code's own sandbox uses it, so it is the supported path in practice.
- srt profile is `(deny default)` (`src/sandbox/macos-sandbox-utils.ts:859`); reads allowed
  unless `denyRead` (re-open with `allowRead`); writes **allow-only** (`allowWrite`, cwd is NOT
  writable by default); network only via its localhost HTTP/SOCKS proxies with a domain
  allowlist (`network.allowedDomains`, `strictAllowlist`); `allowLocalBinding` opens
  bind/inbound on `*:*` and outbound to `localhost:*` (`:1056-1059`); `allowUnixSockets`
  per path (`:1078-1089`); `allowPty` for `/dev/ttys*` (`:1155-1163`); SecurityServer
  mach-lookup always allowed (`:1012`); `enableWeakerNetworkIsolation` adds trustd for
  Go TLS (`gh`, `bd`, `dolt`); Apple Events denied unless `allowAppleEvents`.
- Mandatory write-denies at any depth under cwd (`src/sandbox/sandbox-utils.ts:15-40`,
  `macos-sandbox-utils.ts:79-106`): shell rc files, `.mcp.json`, `.ripgreprc`, `.vscode`,
  `.idea`, `.claude/commands`, `.claude/agents`, `.git/hooks`, `.git/config`. Consequence:
  `/tier` cannot rewrite agent frontmatter inside the sandbox → tier binding becomes hook-
  injected state (§3.6).
- Credentials: `credentials.envVars` masks a secret with a sentinel and the proxy injects the
  real value only for `injectHosts` — the agent never sees `GH_TOKEN`.
- Claude Code credential store: macOS Keychain first, plaintext `.credentials.json` (0600) in
  the config dir when the Keychain is unreachable; `CLAUDE_CONFIG_DIR` keys both
  (code.claude.com/docs/en/authentication).

## 3. Design

### 3.1 Trust boundary (the invariant everything else follows)
Two roots:
- **Host-owned, read-only to the sandbox:** `~/.claude-orca/` = `bin/` (launcher `claude-dev`,
  wrapper `claude-orca-shell`, selftest), `template/` (this repo, cloned once, pulled by
  `claude-dev --update`), `srt/` (pinned `@anthropic-ai/sandbox-runtime@0.0.75` via
  `npm --prefix`), `shellrc.zsh`/`shellrc.bash`, `state/`. Plus one marker-delimited line in
  `~/.zshrc` (and `~/.bash_profile`) that sources the shellrc.
- **Project-owned, agent-writable:** `<project>/` including `.claude-dev/{home,tmp,state,
  sandbox.json}`, `.beads/`, worktrees.

Rule: nothing that runs unsandboxed may execute or source anything agent-writable. The
wrapper reads `<project>/.claude-dev/sandbox.json` as *validated data only* (extra domains
must match a host pattern; extra write paths must resolve inside the folder). There is **no
`./claude-dev` in the project root** any more — the launcher is `claude-dev` on PATH. Files the
host executes implicitly are also write-denied inside the sandbox: `orca.yaml`,
`.worktreeinclude`, `.envrc`, `.git/hooks/**`, `.git/config`, `.beads/hooks/**` (on top of
srt's list). The self-test audits `.git/hooks/*` for references into the writable scope.

### 3.2 Every shell in the folder sandboxes itself
`shellrc.zsh` (sourced by the user's real `~/.zshrc`, last line):
```
if [[ -z "$CLAUDE_ORCA_SANDBOXED" ]] && root=$(claude-orca-root 2>/dev/null); then
  exec "$HOME/.claude-orca/bin/claude-orca-shell" --root "$root" -- zsh -l
fi
```
`claude-orca-root` = `git rev-parse --git-common-dir` → primary checkout → has
`.claude-dev/sandbox.json`? (non-git folders: walk up). Orca's `zsh -l` in any worktree of a
bootstrapped project therefore re-execs into `srt --settings <generated> -c 'exec zsh -l'`
before Orca types `claude --dangerously-skip-permissions`. The same happens for Codex/Gemini/
OpenCode launches, `orca terminal create --command …`, and Terminal.app shells opened in the
folder. **Fail closed:** if srt/sandbox-exec are missing or the wrapper errors, the shellrc
shadows `claude`, `codex`, `gemini`, `opencode` with refusing functions and prints why.

Inside: `HOME=<primary>/.claude-dev/home`, `CLAUDE_CONFIG_DIR=$HOME/.claude`,
`TMPDIR=<primary>/.claude-dev/tmp`, `GIT_CONFIG_GLOBAL=$HOME/.gitconfig`, `GH_CONFIG_DIR=
$HOME/.config/gh`, `BEADS_DIR=<primary>/.beads`, `ORCA_USER_DATA_PATH=<real ~>/Library/
Application Support/orca`, `DISABLE_AUTOUPDATER=1`, `CLAUDE_ORCA_SANDBOXED=1`,
`CLAUDE_ORCA_REAL_HOME`, PATH = `/opt/homebrew/bin`, `<real ~>/.local/bin`,
`~/.claude-orca/template/bin`. The sandbox HOME carries our `.zshrc` (like the Docker one),
so the environment inside is ours, not the user's dotfiles.

### 3.3 Scope (what srt is told)
- `allowWrite` — primary session: `[<project>, <project>/.claude-dev/home, .../tmp]`;
  linked-worktree session: `[<worktree>, <primary>/.git, <primary>/.beads,
  <primary>/.claude-dev/home, <primary>/.claude-dev/tmp]`. Sibling worktrees, `/private/tmp`,
  the real home: not writable. Blast radius of `rm -rf` = the folder + the current worktree.
- `denyRead: [<real ~>]`, `allowRead: [<project>, <worktree>, ~/.claude-orca, ~/.local/bin,
  ~/.local/share/claude, ~/.orca/agent-hooks]` (+ the Orca runtime dir only in §4 mode).
  `~/.ssh`, `~/.aws`, Keychains, Documents… unreadable by construction.
- `network.allowedDomains` = defaults (api.anthropic.com, claude.ai, console.anthropic.com,
  statsig.anthropic.com, *.sentry.io, github.com, api.github.com, *.githubusercontent.com,
  registry.npmjs.org, pypi.org, files.pythonhosted.org, plus route providers when
  configured) ∪ `sandbox.json` extras; `strictAllowlist: true`; `allowLocalBinding: true`
  (dev servers, Dolt server, Orca hook endpoint); `allowPty: true`;
  `enableWeakerNetworkIsolation: true` (Go TLS for gh/bd/dolt); `allowAppleEvents: false`
  (OAuth prints the URL, as in Docker); `allowUnixSockets: []` by default.
- Generated file: `<primary>/.claude-dev/state/srt-<sha1(worktree)>.json`, validated against
  the pinned srt zod schema in tests.

### 3.4 Auth
Keychain unreachable (fake HOME + denyRead) → Claude Code's documented fallback writes
`.claude-dev/home/.claude/.credentials.json` (0600) after a one-time in-sandbox login
(URL + code paste, same as Docker). `auth-guard` ported (subscription billing protection).
`GH_TOKEN` is taken from the host's `gh auth token` by the wrapper and **masked** through
srt credentials (`injectHosts: github.com, api.github.com`); git identity seeded into the
sandbox `.gitconfig` from the host's (name/email only) by bootstrap.

### 3.5 Orca integration
- Status dots + sub-agent rows: the wrapper merges Orca's managed hook entries (identified by
  the `~/.orca/agent-hooks/claude-hook.sh` command) from the real `~/.claude/settings.json`
  into the project config dir's `settings.json` on every launch (toggling in Orca propagates),
  chains Orca's statusline script before ours, keeps `ORCA_*` env untouched; hooks POST to
  `127.0.0.1:$ORCA_AGENT_HOOK_PORT` — covered by `allowLocalBinding`.
- Session history / usage: Orca honors `CLAUDE_CONFIG_DIR` for transcripts; the agent's env
  has it, Orca's own process does not — verified on the Mac; if the panel stays empty, S6
  adds a `~/.claude/projects/<slug>` symlink written by the wrapper (host side).
- Worktrees: `claude-dev` registration prints the one-time Settings → Repository field
  (worktree base path = `<project>/.orca-worktrees`) so worktrees stay inside the folder; the
  scope rules work either way.

### 3.6 The ported suite and what changes
- Config dir sync (repo `config/` → `.claude-dev/home/.claude/`): settings.json with hook
  commands rewritten to `~/.claude-orca/template/bin/<name>`, agents/, commands/, skills/,
  rulebook `CLAUDE.md` (Sandbox section rewritten for "this folder", peers/worktree lines
  gone), statusline; `settings.local.json` overlay wins; checksum-gated.
- `/tier`: binding stored in `.claude-dev/state/tier.json`; `tier-gate` (PreToolUse Agent)
  injects `model` for `executor`/`scout` spawns that omit it (Agent tool: explicit model beats
  frontmatter), `tier-prime` reads the same file; agent files are never rewritten.
- Kept as-is (paths via `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`): lane, bd-guard,
  outbound-guard, auth-guard, contract-gate, delegation-gate, cost-mirror, prime-memories,
  session-end-audit, workflow-lint, workflows, agents.
- Multi-model: `delegate.sh` ported (REPO_DIR from git-common-dir, job worktrees under
  `.claude-dev/delegate/<job>`, runners `opencode run` / `codex exec` / `gemini -p`, provider
  keys masked via srt credentials, egress preflight = allowlist check). Claude Code stays the
  orchestrator: a bead names a route, Claude writes the brief, dispatches headless, reads the
  receipt. Interactive Codex/Gemini sessions the user opens in Orca are sandboxed too (§3.2)
  and share the beads DB.
- Removed: fleet, tmux, cs-new/peers/session-title, egress-firewall, entrypoint,
  image-drift, container-welcome, Xvfb screenshot modes, Docker files. Screenshots become
  `take-screenshot url` via Playwright headless in the sandbox (S10, may fail under Seatbelt →
  documented fallback).

## 4. Decisions and risks
- **srt over a hand-written profile.** A deny-default profile that runs node/claude/git/dolt
  needs ~150 rules and iteration on a Mac we don't have here; srt's is proven by Claude Code,
  adds the domain proxy and credential masking, and is pinned. We keep an audit hook: the
  self-test prints srt's generated profile (`SRT_DEBUG`) into `.claude-dev/state/`.
- **Orca CLI inside the sandbox is OFF by default (S9 opt-in).** `orca terminal create
  --command`, the embedded browser (`orca goto`), automations and artifacts run *outside* the
  sandbox; exposing the socket would hand the agent an escape. The rc mechanism closes the
  terminal hole for this project's worktrees, not floating terminals or other repos, and
  nothing closes the browser/network hole. When the user turns it on, `claude-dev --doctor`
  prints the residual surface and the Orca settings to harden (Floating Workspace off, public
  artifacts off). Native `orca orchestration worker-start --agent codex` becomes available then.
- **Worktrees default outside the folder** (Orca sibling layout); scope rules cover it, and
  registration suggests the in-folder base path.
- **sandbox-exec deprecation**: still shipped and used by Apple-signed tools; if it goes, the
  fallback is srt's Linux backend inside Apple's `container` — out of scope now.
- **Go TLS** needs trustd (weaker network isolation flag = one mach-lookup). **Apple Events**
  stay denied (no `open`; OAuth via pasted URL). **`.git/config` stays write-denied** inside
  the sandbox because Orca runs git unsandboxed in the same repo — remotes are set by
  bootstrap/user, not by the agent.
- **Verification split**: this container is Linux, so beads carry a Linux-runnable `CHECK`
  (bats over the wrapper's logic with srt/brew/gh stubbed, schema validation with the pinned
  srt) and a `MAC-CHECK` line naming the self-test that bootstrap runs on the Mac and refuses
  to hand over without. The self-test is part of the product, not a to-do.

## 5. Slices (one bead each; contracts on the beads)
| # | Bead | Depends on |
|---|------|-----------|
| S1 | Bootstrap & `claude-dev` launcher for macOS (Brewfile tools, template clone into `~/.claude-orca`, srt pin, project registration) | — |
| S2 | Sandbox wrapper: srt settings generator, scope derivation, env, shell re-exec, fail-closed | S1 |
| S3 | Sandbox self-test + `claude-dev --doctor` (13 probes, bootstrap gate) | S2 |
| S4 | Project-local Claude config dir + config sync + hook-injected tier state | S1 |
| S5 | Auth in the sandbox: credentials file, masked gh token, git identity, auth-guard | S2, S4 |
| S6 | Orca integration: managed hooks merge, statusline chain, sub-agent rows, transcript visibility | S2, S4 |
| S7 | Port the host-portable hook/guard suite + tests; no-residue gate (tmux/fleet/docker/iptables/xvfb//workspace) | S4 |
| S8 | Multi-model delegation in the sandbox (routes: opencode, codex, gemini; masked keys) | S2, S7 |
| S9 | Opt-in Orca orchestration mode (socket + skills + hardening checklist) | S6 |
| S10 | Screenshots in the sandbox (Playwright headless) | S2 |
| S11 | Docs: README, rulebook, knowledge-base (SANDBOX, ORCA_INTEGRATION, CONFIG_SYNC, DELEGATION_ROUTES, TEARDOWN_RECOVERY) | S7 |
| S12 | `claude-dev --update / --teardown / --uninstall` with beads snapshot | S1, S3 |

Order: S1 → S2 → S3 → S4 → S7 → S5 → S6 → S8 → S12 → S11 → S9 → S10.

## 6. Status
- Repo name `claude_orca` (beads prefix already `claude-orca`). GitHub creation is blocked
  from this session: the `gh` token cannot create repositories (GraphQL `createRepository`
  and REST `POST /user/repos` both 403 "Resource not accessible by personal access token").
  Once `joe-rayment/claude_orca` exists: add it as `origin` and publish `main`.
