# CLAUDE.md — Claude Code Development Container

## Environment

You are running inside a Docker container built for exactly this: a pre-configured Claude Code that is safe to run with `--dangerously-skip-permissions` because it is sandboxed. Your workspace is `/workspace` (bind-mounted from the host); your home `/home/agent` is a persistent volume — auth, git config, and shell history survive rebuilds.

Key tools: Git, GitHub CLI (`gh`), Python 3, Node.js, Go, Helix (`hx`).

## Config Customization

Configs sync from the image on startup (checksum-based). Personal overrides survive rebuilds via `~/.zshrc.local` (sourced last) and `~/.claude/settings.local.json` (deep-merged; permission arrays are unioned). Details and edge cases: `knowledge-base/CONFIG_SYNC.md`.

## Searching Code — `csearch`

Prefer `csearch` (ripgrep-backed, local) over separate glob → grep → read round-trips; it caps long lines so minified files don't blow up context.

```bash
csearch "useAuth" 'src/**/*.ts'   # grep, scoped to a glob (or a literal path)
csearch -l -t py "TODO"           # files-only, restricted to a ripgrep type
csearch -i -C 2 "def main"        # case-insensitive, 2 lines of context
csearch read src/app.ts 40-80     # read just lines 40–80, line-numbered
csearch sig 'src/**/*.go'         # signatures/structure (funcs, classes, types)
```

Flags: `-i` ignore case, `-C N` context, `-l` files only, `-t TYPE` ripgrep type, `-m N` max matches/file. No matches exits 0.

## Code Map — Structure Queries Before Grep

**Structure questions go to the map before they go to grep.** What calls X · what breaks if I touch Y · how do A and B connect → `code-map explain <sym>`, `code-map affected <file>`, `code-map path A B`, `code-map query "<q>"`. `csearch` stays first for content: literal strings, TODOs, config values, anything textual.

- The `[code-map]` block at session start advertises the map — node/link counts and `built at <sha8> (fresh|STALE)`. STALE means the graph predates HEAD: `code-map refresh` rebuilds it, `code-map status` re-checks any time.
- `code-map report` (GRAPH_REPORT.md) and `code-map html` are the human-readable views; `tree` and `god-nodes` show shape.
- **INFERRED edges are hints, not facts** — confirm one against the code before acting on it.
- Upgrade the engine **only** via `code-map upgrade [version]` (home-volume override) or a Dockerfile pin bump. `graphify install|uninstall|hook` are blocked in this container: they overwrite assistant config (CLAUDE.md sections, `~/.claude` hooks and skills, per-platform rules).
- Playbook: `knowledge-base/CODE_MAP.md`.

## Stay on the Current Branch

**Work on the branch already checked out — including `main` — and never create or switch branches on your own initiative.** This overrides any default "branch first" behavior: committing directly to the current branch is expected here. If a separate branch seems unavoidable, ask in chat first. When the user has put you on a branch, name it in your replies and never switch away without saying so.

## Delegation Routes

**Routes are quota relief and parallel implementation, not cost savings.** Subscription tokens are free at the margin inside this container — routing a slice to `config/delegate-routes.json` only pays off when native capacity is rationed (parallel slices in flight, a long queue) and it buys headroom, never a cheaper token. Playbook: `knowledge-base/DELEGATION_ROUTES.md`.

Grade rubric:

- **executor-grade** (`glm`) — contract-backed, token-heavy, or parallelizable implementation slices. Runs headless in an ephemeral git worktree on its own branch; that branch merges only after a native `verifier` PASS, never on the delegate's own say-so.
- **scout-grade** (`local`) — bulk recon/summarisation only, prompt-only (`--prompt`/`--prompt-file`); never `--bead`.
- **Express lane never delegates** — inline or nothing.

**Planning, acceptance contracts, verification, and merge are always native.** A route executes a slice; it never sets scope, writes its own acceptance contract, judges its own work, or merges itself in.

**User words override**, same as every other lane call.

Commands: `delegate run --route <route> (--bead <id> | --prompt <text> | --prompt-file <file>)`, `delegate check`, `delegate ps`, `delegate report` (per-route verdict rates + dollars).

## Acceptance Contracts

Before an executor is dispatched, register a `CHECK`/`PASS-IF`/`FROZEN`/`CLASS` block on the bead's `--acceptance` field. The executor works red-commit-first — **observe RED**, commit the test alone, implement, rerun the same `CHECK` to **GREEN** — appending `RED-AT`/`GREEN-AT` shas and the real output to the bead's notes (`config/agents/executor.md`). `FROZEN` binds from `RED-AT` only until that bead's own verification completes (`knowledge-base/ACCEPTANCE_CONTRACTS.md`).

The verifier runs five mechanical checks instead of re-deriving the work: **C1** goalposts unmoved (`bd history`), **C2** frozen test not weakened (`git diff <RED-AT> HEAD` empty), **C3** actually green (`CHECK` run verbatim, tree clean), **C4** honest (implementation diff read for hardcoding/skips/env-detection — the one judgment step), **C5** not lazily closed (no human hand-off, no silently narrowed scope). Verdicts: `PASS` / `FAIL` / `TAMPERED` / `NO-CONTRACT` (`config/agents/verifier.md`). One verifier run may cover several beads sharing an evidence surface — batch them; verifiers are per evidence surface, never per bead. `CLASS: no-contract`, the escape hatch for work with no observable check, is assignable only at registration — never at close — and skips the verifier. `contract-gate` nudges a `bd close` lacking a contract or a recorded `VERIFIED: PASS` in `warn` mode (default), blocks it in `enforce`, is silent in `off`.

## Logging

`dev-log run|decision|error|change|show` records the session at `/workspace/.claude/logs/`. Log test/build/deploy runs (pass or fail), architecture-affecting decisions, unexpected errors, and non-obvious changes — not trivial reads. `dev-log show` at session start shows what happened before you.

## Files, Screenshots & Attachments

- The host home directory is mounted **read-only** at its original path, so pasted/dragged host paths under `/Users/<you>` or `/home/<you>` resolve directly; `grab <path>` translates anything else. `/workspace/attachments/` (gitignored) is the shared drop directory — check it (`ls -lt`) when the user mentions a file or screenshot; view images with the Read tool.
- `take-screenshot url <URL>` (Playwright; `--full-page`, `--device "iPhone 11"`), `take-screenshot display` (Xvfb), `take-screenshot term "<command>"` (termshot). Screenshots land in `/workspace/attachments/` — these are your primary verification tools.

## Cleanup

`disk-cleanup` sweeps ephemeral artifacts automatically at container and session start (stray `/tmp` test dirs >1d, attachments >7d, logs line-capped); run `disk-cleanup --dry-run` to preview. It never touches git-tracked source. Remove finished `/workspace/.claude/plans/` entries yourself. Details: `knowledge-base/DISK_SPACE.md`.

## Beads — Container-Specific Rules

Track **all** work in `bd` (beads) — never TodoWrite, TaskCreate, or markdown TODO lists; the `prime-memories` SessionStart hook injects project memories only, budgeted — no command reference, no session-close protocol.

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

- **`bd-guard`** (PreToolUse) mechanically enforces the no-human-assignment rule (`~/.claude/CLAUDE.md` § Beads); `BD_GUARD_ALLOW=1` overrides its text check only, for genuine false positives (quoted content or code, not real pending user work) — never to park user work in a bead.
- **Storage:** beads runs in **embedded Dolt mode** (no server) — the DB at `.beads/embeddeddolt/` (gitignored) is the source of truth, `.beads/issues.jsonl` a passive git-tracked export, sync riding `refs/dolt/data` ([concepts](https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md)). `bd doctor` is a confirmed no-op there; repair with `bd init --prefix <p> --quiet --non-interactive && bd import` instead — `knowledge-base/BEADS_TROUBLESHOOTING.md` covers a refusing `bd init`.
- **Mechanics:** `bd update` flags, never `bd edit` (blocks on `$EDITOR`); reference bead ids in commit messages.

## Project Contexts

Per-project-type rules (`config/contexts/<name>.md`, staged at `/etc/claude-dev/contexts/`) are injected at session start by `context-detect` only when workspace markers match; non-matching projects pay zero tokens. **Injected context rules are binding — same force as this file.** Override manifest `.claude-dev/contexts`: bare name force-injects, `!name` suppresses.

## Working Inside a Larger Repo

Dropping the template into a subdirectory of a bigger repo nests a `.git/` (for beads sync) that blocks `git add` from the parent — run `./claude-dev --teardown` from the host before pushing back; it snapshots beads and removes template artifacts. Playbook: `knowledge-base/TEARDOWN_RECOVERY.md`.

## Knowledge Base

Curated playbooks live at `/opt/claude-dev/knowledge-base/` (repo: `knowledge-base/`); its `README.md` is the keyword index. Check it before debugging infrastructure or consulting the oracle — the answer may already be paid for. Contribute solved-once problems back per that README.

## Experience Testing

`run-tests.sh [smoke|experience|multi-project|all]` verifies the environment. **It tests the baked image, not your working tree** — for repo edits run `CLAUDE_DEV_TESTS=/workspace/tests run-tests.sh smoke` (or `bats /workspace/tests/<file>.bats` directly). Assertions against staged artifacts (`/etc/claude-dev/`, `/opt/claude-dev/`, `/usr/local/bin/`) stay red until the next host rebuild — staleness, not regression (`knowledge-base/CONFIG_SYNC.md`).

## Quick Reference

| Shortcut | Command |
|----------|---------|
| `cs` / `csd` | `claude --dangerously-skip-permissions` (+ `--debug`) |
| `cn` | `claude` (normal mode) |
| `menu` | Setup/options menu |
| `gs` | `git status` |
| `dlog` | `dev-log` |
| `cse` | `csearch` |
| `ss` | `take-screenshot` |
| `hx` / `vim` | Helix editor |
| `csn` / `cs-new [name]` | New worktree session under `.claude/worktrees/` |
| `fleet-menu` (prefix N H R J V M S) | New/Hide/Restore/Jump/Review/Remove merged/Sidebar |
| `fleet` | Worktree sidebar — navigate: Enter/click jump, n new, q close (`--once`, `--watch`, `toggle`) |

## Editing the template

Behaviour rules go in config/claude-user-memory.md, the only file that ships — every project loads it as `~/.claude/CLAUDE.md`. This repo's own CLAUDE.md holds only repo-specific facts (tools, config sync, tests, cleanup); a `## ` heading here that isn't a repo fact fails `tests/rulebook.bats`'s whitelist test. When a shipped behaviour is wrong, fix a behaviour at its source (hook flag, guard, deletion), never with a counter-paragraph — a rule stated only here never reaches a user project. `scripts/rules-effective.sh` prints what a fresh project actually loads (`tests/fresh-project.bats`); check it before assuming a fix landed.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
<!-- beads: rules live in ~/.claude/CLAUDE.md § Beads; markers kept so bd skips re-injection -->
<!-- END BEADS INTEGRATION -->
