# Tests — what they are, how to run them, what each one guards

This page is for someone who has not worked with automated tests before.
Part 1 explains the ideas and the commands. Part 2 is a map of every test
file: what it protects, how long it takes, and whether it runs a script or
checks a config file.

## Part 1 — the basics

### What a test is

A **test** is a small script that runs a piece of this project and checks
that it did what it should. For example: "give the billing guard a
settings file that contains an API key, and check that it refuses to
start." If the guard ever stops refusing, that test goes **red** (fails)
and names what changed. If everything behaves, it stays **green** (passes).

- A **test case** is one check (one `@test "…"` block).
- A **test file** (`tests/<name>.bats`) groups the cases for one script or feature.
- The **suite** is all of them: 104 files, about 1,270 cases.

### What bats is

The tests are written for **bats** (Bash Automated Testing System), because
the project itself is mostly bash scripts. A bats file is ordinary bash
with `@test "description" { … }` blocks. Inside a block, `run <command>`
runs the thing under test and captures its exit code in `$status` and its
text in `$output`; each `[ … ]` line after it is an **assertion** — a
condition that must be true or the case fails.

Two words you will see in the files:

- **Stub** — a fake stand-in for a real program (`docker`, `open`, `gh`,
  `uname`, `bd`). A stub lets a test run on any machine, fast and without a
  network, and lets it check exactly which commands the script *tried* to
  run. The catch: a stubbed test proves the script's logic, not that the
  real program behaves the same way.
- **Fixture** — sample input kept on disk (`tests/fixtures/`), such as a
  recorded Orca web page or a real opencode output stream.

### How to run them

From the repo root:

```bash
./run-tests.sh                 # the everyday run: every file except the slow ones (~2 min)
./run-tests.sh --all           # everything, slow files included (~4 min)
bats tests/lane.bats           # one file
bats -f 'git push' tests/outbound-guard.bats   # only the cases in that file whose name contains "git push"
```

Or ask Claude: **`/test`** runs the suite and explains every failure in
plain English; `/test lane` runs a subset; `/test explain lane.bats`
explains a file without running it.

bats itself has to be installed first (`brew install bats-core` on a Mac).
Those times assume GNU parallel is installed too (`brew install parallel`):
it lets `run-tests.sh` run several files at once. Without it the same runs
take about four times as long.

### Reading the output

```
1..39
ok 1 (a) mode=off is silently allow
not ok 2 (b) mode=warn, contract but no PASS: warns on stderr, exits 0
# (in test file tests/contract-gate.bats, line 77)
#   `[[ "$stderr" == *"acceptance contract"* ]]' failed
```

- `1..39` — how many cases are about to run.
- `ok N …` — that case passed.
- `not ok N …` — that case failed. The `#` lines under it name the file,
  the line, and the exact assertion that was false. That assertion is the
  thing to read first: it says what the test expected.
- `ok N … # skip <reason>` — the case did not run, usually because a tool
  it needs is missing on this machine. A skip is neither a pass nor a fail.

### Two kinds of test

- **Behavior** — runs a script and checks what it does. These are the
  ones that catch real bugs.
- **Config** — reads a config file and checks it is wired correctly (a
  guard hook is registered, two version pins agree). No script runs, but a
  mistake here silently switches something off, so these stay.
- **Wording** — only checks that a document says (or no longer says)
  certain words, or stays under a word count. These protect phrasing, not
  behavior: they go red when someone rewords a doc, even when nothing is
  broken, and caused most of the "it got hung up on a test that had nothing
  to do with my question" moments. They were retired in Sept 2026; don't
  add new ones.

### What the tests cannot tell you

Every test here runs on Linux with stubs. None of them proves the real Mac
path: a real Docker Desktop, a real container, a real browser. Those checks
are run by hand:

- `tests/mac-e2e.sh` — on a Mac: a throwaway folder, a real container, a
  real HTTP request to the URL Orca publishes.
- `scripts/container/smoke.sh` — the image's own self-check.

### Who runs what

- **The agent**, while it works: checks its change the way it will really
  be used, then runs only the file(s) covering the code it touched. A red
  file it did not touch gets one line in its reply, never a detour.
- **You**: the full suite, by hand or with `/test`, whenever you want the
  whole picture.
- **New tests** the agent writes open with three comment lines, so you can
  tell what they are for without reading the code:

  ```bash
  # Guards:   <the behavior it protects, in plain words>
  # Fails if: <a concrete way to break it>
  # Run:      <the exact command for this one test>
  ```

## Part 2 — the map

104 files, 1,267 cases: 89 files check behavior only, 11 mix behavior with
a few config checks, and 4 are config checks only. **Speed** is from
`run-tests.sh`'s timing: `slow` files are skipped by the everyday run.

**Config checks** read a config file instead of running a script, and they
were kept on purpose: each guards something that silently breaks if it
drifts -- a guard hook no longer wired into `claude-settings.json`, a
version pin two files must agree on, the data-residency allowlist. The last
column says which ones each file keeps.

**Retired (Sept 2026):** 64 cases. Almost all only checked wording -- word
counts, required headings, "this old phrase is gone", sentences in agent
prompt files. The rest were one dead file (it linted a folder that no longer
exists) and one case that re-ran two other test files from inside itself. Five files went
entirely: `rulebook`, `agent-report-relay`, `recon-routing-docs`, `v2-gone`,
`gha-workflows-lint`. If you add a test, it should run something and check
what happens; a test that greps prose goes red on harmless edits and
catches no bugs.

| File | Tests | Speed | What it guards (what breaks if this goes red) | Kind | Non-behavior checks kept, and why |
|---|---|---|---|---|---|
| `acceptance-contracts.bats` | 1 | fast | Every agent file in config/agents/ still parses as frontmatter + body, so Claude Code can load it. (The 11 prompt-wording cases were retired.) | config | the one case is a structure check |
| `activity-digest.bats` | 17 | fast | scripts/activity-digest.py condenses a folder's Claude Code sessions, executors, scouts and headless workers into one small JSON digest (who is running, what was asked), with no secrets in it and a capped size. | behavior | — |
| `activity-summarize.bats` | 16 | fast | The activity panel's summarizer asks the OpenRouter guard (a fake one here) for a plain-text page, stays inside the terminal's row budget, never leaks a key into the request, and falls back quietly (no retry for 300 s) when the guard is down. | behavior | — |
| `activity-viewer.bats` | 17 | fast | scripts/activity.py and bin/activity, the full-screen activity panel: every frame fits the window and ends in the dim footer, the page never scrolls, the summarizer is called only when the work changed, and quitting puts the terminal back. | behavior | — |
| `auth-guard.bats` | 21 | fast | scripts/auth-guard.sh refuses to start when an ANTHROPIC_* env var or settings `.env` key would silently switch Claude Code from subscription billing to pay-per-use API billing. | behavior | — |
| `bd-guard.bats` | 233 | slow | scripts/bd-guard.sh (a PreToolUse hook) blocks bd commands that would assign a bead to a human, tag it "human", skip verification, or reinit an uncommitted export, including through quoting tricks. | behavior | — |
| `bootstrap.bats` | 31 | slow | bootstrap.sh, the first-run installer: checks the OS and gh auth, installs missing Docker/gh/git, clones the template under `<project>/.claude-dev`, registers the project without clobbering config. | behavior | — |
| `branch-guard.bats` | 10 | fast | scripts/branch-guard.sh (a PreToolUse hook) denies creating/switching branches and `git worktree add` unless the command starts with BRANCH_OK=1, keeping work on main. | behavior | — |
| `chown-sockets.bats` | 5 | fast | setup.sh's and entrypoint.sh's ownership fix over the folder's home survives a live unix socket Orca left behind (a plain `chown -R` dies on it). | mixed | 1 config check: both shipped chowns pass `-h` (needed for dangling Orca links) |
| `claude-not-in-image.bats` | 1 | fast | `setup.sh --list` has no Claude Code phase and still lists opencode and orca, so the image stays free of a Claude binary. | behavior | — |
| `clipboard-bridge.bats` | 20 | fast | The Mac end of the image-paste bridge: clip-serve answers only the image routes and `POST /copy`, never hands out clipboard text; clip-listen serves back-to-back requests on a private unix socket and exits when the ssh session is gone. | behavior | — |
| `clipboard-xclip.bats` | 14 | fast | The container's `xclip` shim reads only the Mac clipboard's image through the bridge socket: a text read makes no request, TARGETS and image/png become `GET /targets` and `/png`, `-i` becomes `POST /copy`, and a missing or flaky socket fails quietly. | mixed | 1 wiring check: bin/xclip is a symlink to the shim and wins over /usr/bin/xclip on a pane's PATH |
| `code-map.bats` | 53 | slow | scripts/code-map-guard.sh blocks the `graphify` CLI's dangerous subcommands (install/uninstall/global/clone) that would rewrite ~/.claude, while letting graph-building and queries through. | mixed | 1 wiring check: settings.json runs code-map-prime after context-detect |
| `config-resync.bats` | 6 | fast | Registration and `--update` re-sync a running container's ~/.claude config from the folder's own template clone (never the image's frozen copy), warning rather than failing if they can't. | behavior | — |
| `config-sync.bats` | 18 | fast | scripts/config-sync.sh writes settings.json/CLAUDE.md/agents/commands/skills/hooks into the container home from config/, keeping a settings.local.json overlay and no host-only paths. | mixed | 1 lint: no script hard-codes `~/.claude` |
| `container-entrypoint-guard.bats` | 15 | fast | The entrypoint starts the OpenRouter guard when a key exists (env var, then `.openrouter.key`, then opencode's auth.json); sshd and so every ssh pane inherit only the guard token and its loopback URL, never the real key. | behavior | — |
| `container-entrypoint-sshd.bats` | 7 | fast | sshd is the entrypoint's one long-running child: its supervisor retries (no keys yet, no sshd binary, unusable runtime dir) instead of dying, starts sshd the moment the refusal clears, and a TERM takes everything down in under 5 s with exit 143. | behavior | — |
| `container-entrypoint-sync.bats` | 6 | fast | The entrypoint syncs config from the folder's own template clone once, before sshd starts (never fatal), runs the provision.d steps after sshd is supervised, and writes, merges or leaves alone the managed settings file as policy says. | behavior | — |
| `container-entrypoint.bats` | 10 | slow | The container entrypoint: runs setup, starts Orca headless, publishes the pairing URL, re-syncs config, seeds files, starts the OpenRouter guard, and no failing step kills the container. | mixed | 1 pin check: setup.sh pins the Orca version the image needs |
| `container-image.bats` | 6 | slow | setup.sh and the Dockerfile install the pinned Orca .deb and pinned opencode, and the Dockerfile itself makes no direct apt-get/curl calls. | behavior | — |
| `container-provision-worktree-sweep.bats` | 5 | fast | Provision step 65-worktree-sweep removes stale git worktrees while keeping ones with uncommitted changes or a live process using them. | behavior | — |
| `container-sshd.bats` | 10 | fast | scripts/container/sshd-lib.sh: the sshd config text it writes, the env snapshot ssh panes source (no OpenRouter key in it), the Mac-path symlink, the host-key fingerprint, and a real OpenSSH server kept alive by the restart loop. | behavior | — |
| `context-detect.bats` | 12 | fast | scripts/context-detect.sh (a SessionStart hook) injects project-type rules (e.g. a Snowflake warning) when workspace markers match, and stays silent otherwise. | behavior | — |
| `context-meter.bats` | 18 | fast | scripts/context-meter.sh warns, then refuses, a sub-agent's tool calls as its transcript nears the context budget (the full notice once, then a one-line reminder); the main loop is never metered. | mixed | 2 wiring checks: hook entries in settings.json, bin symlink |
| `contract-gate.bats` | 39 | fast | python/contract-gate.py (a PreToolUse hook) warns, or in enforce mode denies, a `bd close` of a bead that carries an acceptance contract but has no verifier-corroborated "VERIFIED: PASS" note. Beads without a contract pass silently. | behavior | — |
| `cpu-cap.bats` | 9 | fast | The launcher caps a new container at half the Docker VM's CPU cores (and applies it live to a kept one) unless claude-orca.json sets a value or 0 to opt out. | behavior | — |
| `delegate.bats` | 40 | fast | scripts/delegate.sh runs work on cheaper external runners (opencode/codex/gemini) in scratch worktrees, scrubbing keys from logs and writing a JSON receipt plus bead notes. | behavior | — |
| `delegation-gate.bats` | 54 | fast | A PreToolUse hook counts consecutive inline tool calls in the main loop and nudges (never blocks) toward delegating; git/gh/bd and reads are exempt or half-weight. | behavior | — |
| `disk-cleanup-gc-scope.bats` | 3 | fast | scripts/disk-cleanup.sh's worktree sweep targets this folder's workspace, never some other folder that happens to be in the shell's environment. | behavior | — |
| `disk-cleanup-ondemand.bats` | 6 | fast | scripts/disk-cleanup.sh removes idle, easily re-fetched caches (old Playwright browsers, stale npx and Claude-version dirs) by age, leaving fresh ones alone. | behavior | — |
| `disk-cleanup.bats` | 7 | fast | scripts/disk-cleanup.sh sweeps dated code-map snapshots, old transcripts and aged npm cache; `--report` deletes nothing; a repeat run changes nothing. | behavior | — |
| `dispatch-epic.bats` | 12 | fast | `dispatch --epic` runs an epic in waves on bead blockers: ready beads together, path-sharing beads one after the other, never above the slot cap, a failed blocker blocks its dependents, and only a fully done epic prints EPIC READY. | behavior | — |
| `docker-cli-contract.bats` | 3 | fast | Every docker flag the launcher really passes is checked against the real `docker --help`, so a typo'd or stub-only flag can't hide behind the test stubs. | behavior | — |
| `docs.bats` | 1 | fast | CLAUDE.md and AGENTS.md carry the same project sections, so agents that read AGENTS.md get the same instructions. | config | the one case is a sync check |
| `e2e-local.bats` | 3 | slow | The one full end-to-end run: the real launcher starts the real entrypoint and Orca, and the published URL must serve actual Orca Web over HTTP. | behavior | — |
| `first-start-dns.bats` | 7 | slow | scripts/container/entrypoint.sh's DNS auto-repair, setup.sh's DNS-not-package error message, and the launcher's `--dns` flag, fast-exit-on-crash, and install-log tail on a failed start | behavior | — |
| `fresh-project.bats` | 2 | slow | scripts/rules-effective.sh runs against a fresh temp project and its output carries the shipped rulebook and the lane declaration. | behavior | — |
| `frozen-hook.bats` | 9 | fast | scripts/lib/frozen-hook.sh's git pre-commit hook blocks commits touching a bead's FROZEN paths once a RED-AT commit exists, staying fail-open and chaining with an existing user hook | behavior | — |
| `ghostty-install.bats` | 26 | fast | `claude-dev ghostty` puts exactly three things on the Mac (an include beside the user's Ghostty config, the router copy, one `config-file` line), is a no-op the second time, refuses a config that sets its own `command =`, and `--uninstall` hands the config back byte for byte; `--check` and doctor report it. | behavior | — |
| `ghostty-router.bats` | 15 | fast | Ghostty's per-pane router sends a pane opened inside a sandboxed folder to that folder's `claude-dev pane`, and every other pane (outside any folder, `route: false`, no launcher, deleted cwd) to the user's normal Mac shell -- never an error. | behavior | — |
| `lane.bats` | 43 | fast | scripts/lane.sh, the per-prompt complexity-lane hook: declaring/reading/resetting a lane, the one-process `--prompt` hook, escalation flags, log truncation, and failing open on bad input/no session id | behavior | — |
| `launcher-pane.bats` | 31 | fast | `claude-dev pane`/`open` turns a terminal into a sandbox pane over ssh: the exact ssh command line (one SetEnv, quoting), the once-per-Ghostty-version terminfo push, the fast path (no docker) vs the slow path, the fallback labelled as a Mac shell, doctor's ssh rows, and teardown. | behavior | — |
| `launcher-ssh.bats` | 12 | fast | The launcher gives every folder its own ssh identity (client and host keys, authorized_keys, known_hosts, config) under state/ssh, never touches ~/.ssh, and starts the container with sshd on the folder's port, waiting for the host key it expects. | behavior | — |
| `launcher-update-migration.bats` | 4 | fast | `./claude-dev --update` on a folder made by the Orca image removes the leftover `<container>-orca-state` volume once, gives the folder its ssh keys, and creates a container with no Orca port, version, theme or state mount. | behavior | — |
| `launcher-v3-build.bats` | 11 | slow | scripts/launcher.sh's acquire_image logic: build from the folder's template, reuse a daemon-held image, or fall back to the base image/runtime install when a build fails | behavior | — |
| `launcher-v3-key.bats` | 3 | fast | `claude-dev key openrouter` stores the OpenRouter key at mode 600 in the folder-local home, never leaks it into container argv or logs, and `--doctor` reports it | behavior | — |
| `launcher-v3.bats` | 14 | fast | scripts/launcher.sh end-to-end: register/open/stop/shell/logs/doctor/teardown, the desktop-Orca hand-off, and rules for adopting vs. recreating a running container | behavior | — |
| `lifecycle.bats` | 1 | fast | `./claude-dev --teardown` snapshots the beads database to a documented location before deleting the install, leaving the user's own gitignore/files untouched | behavior | — |
| `lint-bash32.bats` | 1 | fast | The Mac-side scripts (bootstrap.sh, launcher.sh, link-bin.sh, scripts/lib, run-tests.sh) stay runnable on macOS's stock bash 3.2 (scripts/lint-bash32.sh). | behavior | — |
| `message-cap.bats` | 6 | fast | python/cost-mirror.py's per-message word-count cap readout in the UserPromptSubmit status line, and that its cap number matches the rulebook | mixed | 1 lockstep check: cost-mirror's cap number matches the rulebook's |
| `no-card.bats` | 2 | fast | config/claude-settings.json is valid JSON with no empty hook array, and the Stop hook still runs export-logs alongside Orca's own entries. | config | both cases are settings.json wiring checks |
| `no-residue.bats` | 1 | fast | config/claude-settings.json wires every required hook event and PreToolUse matcher -- a missing entry would silently switch a guard off. | config | the one case is a wiring check |
| `offramp.bats` | 24 | fast | scripts/offramp.sh off-ramps the MAIN session at ~40% context: stop mode prints the full notice once, then a one-line reminder, refuses tool calls from 45% (bd/git/offramp commands excepted) and sends a turn that ends with no HANDOFF saved back once to save it; continue mode keeps going and only refuses from 60% if the session never compacts; a `bd update <id> --notes "HANDOFF ..."` past the off-ramp records the handoff, and the next session start (after /clear or a compaction) is pointed at that bead; the CLI switches mode. | mixed | 1 wiring check: bin symlink |
| `openai-stub-real.bats` | 7 | fast | The real opencode against a stub OpenAI (tests/helpers/openai-stub.py, an HTTP proxy that terminates TLS for chatgpt.com/auth.openai.com with a test CA): a fake oauth login's bearer token/account-id/model reach the stub, an expired token is refreshed and rotated back into auth.json, --variant high arrives as reasoning.effort, `opencode models openai` lists what the subscription serves, and the whole OpenAI path end to end -- openai-auth.sh's device-flow sign-in, a recon run, and the headless worker path | behavior | needs opencode, openssl and python3 on PATH; skips when absent |
| `opencode-context-meter.bats` | 14 | fast | config/opencode/plugin/context-meter.js, which injects context-budget soft-notice/hard-refusal text into opencode's system prompt and aborts a session past the hard ceiling | behavior | — |
| `opencode-openai-launch.bats` | 14 | fast | An `openai/...` model (the user's ChatGPT subscription) runs through the same launch paths as an openrouter/ one: the readiness/catalogue/resolve helpers in tier-roles.sh, the one launch-config writer behind orca_opencode_command and recon (no guard env, `reasoningEffort` key), and the signed-in guards on orca-dispatch and recon | behavior | — |
| `opencode-permissions.bats` | 4 | fast | scripts/lib/orca-orch.sh's orca_opencode_command writes a per-launch opencode config with a non-interactive permission block so a headless worker never stalls on a prompt | behavior | — |
| `openrouter-guard-retry.bats` | 5 | fast | scripts/container/openrouter-guard.py retries a real stub upstream's 429 responses with exponential backoff and Retry-After, honoring retry-count limits and a disable switch | behavior | — |
| `openrouter-guard.bats` | 10 | fast | scripts/container/openrouter-guard.py forces every OpenRouter request onto the allowed-provider/country list, swaps the guard token for the real key, and streams SSE through unchanged | mixed | 1 policy check: the provider allowlist denies China-hosted providers |
| `outbound-guard.bats` | 42 | fast | outbound-guard.sh (a Claude Code hook) blocks any Snowflake CLI use outright, and blocks git push/gh pr create/etc. unless GitHub is connected or the user asked. | mixed | 5 wiring checks: hook entries, permission denies, bin symlink |
| `output-cap.bats` | 4 | fast | output-cap.sh (a PreToolUse hook) rewrites large main-loop Bash commands to spill their output into a file instead of flooding the orchestrator's context. | mixed | 1 wiring check: settings register the hook |
| `pane-entry.bats` | 14 | fast | An ssh pane lands in the right folder with the container's env and a usable TERM, never follows `../` or a symlink out of the project, and the shell reports its folder (OSC 7) and title only inside a pane. | behavior | — |
| `port-collision.bats` | 4 | fast | claude-dev's port-registration logic moves a folder off a port another container now publishes, instead of letting `docker run` fail with "already allocated". | behavior | — |
| `prime-hook.bats` | 6 | slow | scripts/prime-memories.sh replaces bd's verbose boilerplate in the SessionStart hook with just the project's remembered facts, capped to a byte budget. | mixed | 2 wiring checks: the script exists, SessionStart runs it once |
| `provision-claude-on-path.bats` | 18 | fast | provision.d/15-claude-on-path keeps the folder's own native Claude Code install updated to the latest checksum-verified release without touching the container image's copy. | behavior | — |
| `provision-git-init.bats` | 15 | fast | provision.d/55-git-init makes every folder a git repo with a commit on main/master so Orca can resolve a base branch, without touching the user's files. | behavior | — |
| `provision.bats` | 15 | fast | scripts/container/provision-run.sh runs numbered provision.d steps idempotently, logs each one, keeps a failing step from blocking later steps or Orca, and guards the OpenRouter key. | behavior | — |
| `recon.bats` | 11 | fast | scripts/recon.sh runs a synchronous, read-only headless opencode question on the tier's recon model and reports tokens/cost, falling back to scout when recon isn't orca-backed. | behavior | — |
| `run-logs.bats` | 6 | fast | container.log, setup.sh and entrypoint.sh stamp every mirrored line with a wall-clock/elapsed time and drop noisy per-second `docker inspect` polls, so a slow start can be diagnosed. | behavior | — |
| `scratch-volumes-container.bats` | 9 | fast | Container-side scripts (volume-dirs.sh, entrypoint.sh, seed-orca-state.sh, provision.d/45-scratch-volumes) correctly identify, chown and migrate data onto the four scratch docker volumes. | behavior | — |
| `scratch-volumes.bats` | 6 | fast | claude-dev's launcher mounts four docker volumes (cache/npm/opencode/worktrees) under the agent home, recreates a container predating them, and removes them all on teardown. | behavior | — |
| `seed-gitignore-orca-skills.bats` | 4 | fast | scripts/container/seed-project.sh seeds .gitignore with the three orca-skills paths so git ignores them but still sees the user's own project skills; teardown removes exactly those lines. | behavior | — |
| `seed-project.bats` | 16 | fast | `seed-project.sh` seeds a fresh project's .gitignore/orca.yaml/beads snapshot exactly once, never overwrites user edits, and never writes through a symlink. | behavior | — |
| `session-cost.bats` | 5 | fast | `session-cost.py` computes the exact per-session and per-turn token/byte/word counts from a transcript, used to measure token-diet changes, without ever printing transcript content. | behavior | — |
| `session-end-audit.bats` | 6 | fast | `session-end-audit.sh` (SessionEnd hook) logs how many files are dirty when a session ends, stays silent on a clean tree, and fails open on bad input. | behavior | — |
| `setup-check-uid.bats` | 3 | fast | `setup.sh --check`'s agent-user row compares against the container's real running uid (HOST_UID), not a hardcoded 1000, so Mac machines don't get a false FAIL. | behavior | — |
| `start-professor.bats` | 5 | fast | `start-professor.sh` execs `claude --agent professor`, strips CLAUDECODE first, and only cd's to the project root when one can actually be resolved. | behavior | — |
| `startup-menu.bats` | 9 | fast | `startup-menu` offers beads, then GitHub, then Claude Code in a new folder's first pane, only when the folder is new, and later panes print one identity line and never fail the shell. | behavior | — |
| `statusline.bats` | 6 | fast | `statusline.sh` renders model, context, branch, the 5-hour/weekly usage Claude Code sends ("?" when it sends none), and the cache-hit/context-left/cost segments when those fields are present. | behavior | — |
| `stub-write.bats` | 4 | fast | `launcher.sh`'s stub/key/config writers (write_project_stub, cmd_key_v3, register) never write through a symlink, which previously could brick the launcher or leak the OpenRouter key. | behavior | — |
| `take-screenshot.bats` | 8 | fast | `take-screenshot.sh` launches sandboxed headless Playwright correctly for `url` mode, rejects the removed term/display modes, and installs Playwright on demand when missing. | behavior | — |
| `teardown-git.bats` | 4 | fast | `claude-dev --teardown` removes `.git` only when claude_orca created that repo's root commit, never a user's own repo or one nested in a larger repo. | behavior | — |
| `teardown-orca-residue.bats` | 4 | fast | `claude-dev --teardown` removes Orca's worktrees/`.orca` state and unseeds the gitignore lines, leaving the user's own gitignore and branches untouched. | behavior | — |
| `tier-gate-headless.bats` | 9 | fast | `tier-gate.sh` under the headless worker backend: a Claude role still gets its model injected (with a note naming `dispatch <bead>`), a model-less spawn onto a non-Claude role is denied rather than misrouted, and an explicit model stays the in-process fallback. | behavior | — |
| `tier-headless.bats` | 8 | fast | A tier.json written when Orca still existed (backend "orca") reads back and rewrites as subagent/headless, and `/tier` binds headless, never orca. | behavior | — |
| `tier-hooks.bats` | 43 | fast | The whole `/tier` model system (`tier-derive/set/gate/prime/reconcile.sh`): deriving, binding, injecting and reconciling the worker/recon/checker models correctly. | behavior | — |
| `tier-openai.bats` | 16 | fast | `openai` / `openai:<family\|id>` binds a role to the user's ChatGPT subscription (orca + opencode, model `openai/...`) -- visibly distinct from the same model on OpenRouter; unknown families error with the list, a signed-out bind saves and names `/tier auth openai`, `models openai` lists families and pins, and `auth openai` opens the sign-in tab (or the manual fallback) behind scripts/openai-auth.sh | behavior | — |
| `tier-openrouter-auth-2.bats` | 4 | fast | `openrouter-auth.sh` gives a clear, distinct refusal message for a malformed key vs. one OpenRouter itself rejects, and reports success without ever printing the key. | behavior | — |
| `tier-openrouter-auth.bats` | 12 | fast | `openrouter-auth.sh`/`tier-set.sh` write the key mode 600, start the local guard proxy, and dispatch never puts the credential on a command line. | behavior | — |
| `tier-phrases.bats` | 12 | fast | `tier-set.sh` accepts natural-language `/tier` phrases (comma/space-separated, `@high` effort suffixes, short route names) and resolves them identically to explicit vendor/model ids. | behavior | — |
| `tier-presets.bats` | 9 | fast | `/tier <preset-name>` binds exactly what its underlying explicit args would bind, gets cleared by any later non-preset bind, and reserved/route names always beat a preset. | behavior | — |
| `toolchain-cache.bats` | 13 | slow | The Dockerfile/`setup.sh`/`launcher.sh` split between what the image bakes at build time vs. what a folder installs at runtime, so rebuilds stay fast and caches don't shadow real paths. | behavior | — |
| `update-hygiene.bats` | 5 | slow | `claude-dev --update` reports the image id it actually moved to, deletes only its own untagged/superseded image layers, and clears only run/ results — never auth, config or home. | behavior | — |
| `variant-carry.bats` | 8 | fast | A role's reasoning-effort variant (e.g. `@high`) actually reaches opencode's generated config on both the Orca-terminal and batch `delegate run` dispatch paths. | behavior | — |
| `verifier-doc.bats` | 2 | fast | The verifier agent definition documents its "C6 unseen-case" check, and `delegate-routes.json` ships the flash-class scout routes with the right shape. | mixed | 2 config checks: verifier's C6 section, delegate-routes.json shape |
| `verify.bats` | 9 | fast | `claude-dev verify`/`verify-folder.sh` read back whether a folder's setup (hooks, rulebook, git identity, OpenRouter guard) actually succeeded, failing loudly instead of silently looking fine. | behavior | — |
| `workers-cli.bats` | 7 | fast | `workers` (list/wait/reply/tail/stop) reads the job dirs and the inbox honestly -- no double-delivered or skipped inbox line, no hidden dead pid -- and the slot cap really queues extra dispatches. | behavior | — |
| `workers-dispatch.bats` | 14 | fast | scripts/dispatch.sh turns a bead into a worktree, a job directory and a started (stub) runner, honours tier.json, and prints one valid receipt line. | behavior | — |
| `workers-handoff-spec.bats` | 2 | fast | A dispatch folds the last HANDOFF-AT block of its bead's notes into the next worker's spec, once; a bead with no such block gets a spec byte-identical to one without notes. | behavior | — |
| `workers-run.bats` | 23 | fast | scripts/worker-run.sh runs one turn of one headless worker: waits for a slot, runs the agent (a stub here) in the job's worktree, writes the receipt and exactly one inbox line, never reports a QUESTION:/failed run as done, and frees the slot on TERM. | behavior | — |
| `workflows.bats` | 11 | fast | The shipped `recon-fanout.js`/`verify-contracts.js` workflows are valid JS, every spawned agent names a model, and `workflow-lint.sh` denies a model-stripped mutant of either script. | behavior | — |
| `worktree-gc-log.bats` | 4 | fast | Every `worktree-gc.sh` sweep run appends a dated, size-capped log block explaining what it did, including which process kept a worktree busy. | behavior | — |
| `worktree-gc-noleak.bats` | 2 | fast | The worktree sweep never runs against the wrong/ambient project (not the user's real folder), and every log block names its actual calling process. | behavior | — |
| `worktree-gc-wiring.bats` | 7 | fast | The worktree/branch sweep (`worktree-gc.sh`) is actually wired into the real hooks in `claude-settings.json` (PreToolUse, PostToolUse, SessionStart) and fires correctly after a merge. | behavior | — |
| `worktree-gc.bats` | 12 | fast | `worktree-gc.sh`: merged clean worktrees/branches get deleted, dirty or unmerged ones are kept and reported STRANDED, finished delegate job dirs get swept. | behavior | — |
