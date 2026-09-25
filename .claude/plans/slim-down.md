# Slim-down plan — smaller, faster, same behavior

Status: IMPLEMENTED (Sept 2026) except D3, D5, E4 and G4 -- see "Outcome"
below. B5, D1, D2, D4 and D6 touch the host side or the image and are
UNVERIFIED until `tests/mac-e2e.sh` runs on a Mac against them.

## Outcome

Measured on the same Linux box before (commit 674228f) and after, medians
of 30 calls:

| What | Before | After |
|---|---|---|
| Hooks on one Bash call (CPU, 9 processes) | ~305 ms | ~195 ms |
| Slowest hook on a Bash call | 55 ms (outbound-guard) | 32 ms (contract-gate, delegation-gate) |
| Hooks on one prompt (CPU) | ~229 ms, 5 processes | ~132 ms, 4 processes |
| Hook on an Agent spawn (tier-gate) | 52 ms | 24 ms |
| Status line, per message | 65 ms, 20 processes, own API call | 27 ms, 5 processes, no API call |
| Source (scripts, python, config, docs, bin) | 1,529 KB | 1,340 KB |
| Test suite, everyday subset / all files | ~8 / ~15 min one file at a time | ~2 / ~4 min, files in parallel |

Per item:
- A1-A6, F1-F5, found-along-the-way: done.
- B1-B8: done. branch-guard got the B1/B2 treatment too once the final
  benchmark showed it had become the slowest Bash hook (31 -> 13 ms).
- C1-C5: done. C5 keys its "already told this agent" marker by the
  agent's transcript path, under $TMPDIR.
- D1, D2, D4, D6: done, UNVERIFIED on a Mac. D4 went a safer way than
  planned: the boot pass still checks every file but only chowns the
  ones not already agent-owned, so the end state is unchanged.
- D3: done, UNVERIFIED on a Mac. `container_matches` reads image, image
  id, port and mounts from one `docker inspect` (JSON through jq); a Mac
  without jq keeps the old per-field templates.
- D5: done, UNVERIFIED on a Mac. Each payload phase's pin and functions
  live in `scripts/container/phases/<name>.sh`, copied right before its
  own RUN; functions byte-identical, `--check`/`--list` output unchanged.
  Not built here (no Docker).
- E1-E5: done. E4 is `scripts/lib/hook.sh` (`hook_deny`), used by
  outbound-guard, tier-gate, branch-guard and workflow-lint.
- G1-G3, G5: done (G5 kept SLOW_FILES: the slow files skip in under a
  second on a box without Orca/Docker, and are slow where those exist).
- G4: built, measured, NOT landed. A per-file cache of make_project
  (keyed on args, env and the tmpdir tree; replay rewrites the recorded
  temp paths) passed every one of the 33 files that use it, with the
  same results as without it. It hit 81 of 149 calls, a hit costs 0.48 s
  against 1.9 s for a real bootstrap -- and the 33 files went from 601 s
  to 544 s run one at a time, and from 164 s to 165 s run in parallel,
  because container-entrypoint.bats (154 s, one fixture call) is the
  critical path either way. ~110 lines of fixture code for no wall-clock
  gain, so it was dropped.

Tests after all of it: the full suite, 101 files / 1,229 cases. The 8
cases that used to fail on this box were fixed afterwards: one was a real
bug (provision step 75-orca-skills called the Orca CLI without
ORCA_USER_DATA_PATH, so it could ask the wrong Orca -- the "flaky" case
lost that race only when it stopped early), two were races on provision
running after the web URL, one expected an Orca reachability probe the
worktree sweep only makes when it has something to remove, and four
assumed tools this box lacks (gh/bd/dolt, an `agent` user, Docker 29's
new no-daemon wording, Orca/Xvfb) -- those now follow the box or skip.

How this was found: seven parallel reviews (hook timing, what the model
reads, dead code, duplication, container/startup, test suite, docs), then
every claim that made the cut was re-checked against the code, and the
biggest ones were measured again by hand. Timings are medians on the Linux
dev box; absolute numbers on a Mac differ, the ratios hold. Items that touch
the host side or the image need `tests/mac-e2e.sh` on a Mac before they
count as done (CLAUDE.md, "Definition of done").

## Where the cost is today (measured)

| What | How often | Cost now |
|---|---|---|
| Hooks on one Bash tool call | every Bash call | 9 processes, ~340 ms CPU. Claude Code runs matching hooks in parallel, so the felt delay is the slowest one (~70 ms, `output-cap`) plus CPU contention in a CPU-capped container |
| Hooks on one prompt | every prompt | 5 processes, ~217 ms CPU; slowest `cost-mirror` 72 ms |
| Status line | every assistant message (300 ms debounce) | ~68 ms and 20 process launches, plus its own call to the usage API at most once a minute |
| Always-loaded context | every session | rulebook ~2.3k tokens, 6 agent descriptions ~1k, skill + command descriptions ~240 |
| Image | per build | 3.66 GB (recovery.md, `docker history`), of which 113 MB is `app.asar` written twice |
| Rebuild after editing `setup.sh` | per edit, per Mac | every payload layer rebuilds (~11 min, over 1.3 GB of downloads) |
| `claude-dev` on a running folder | every open | 5–6 separate `docker inspect` calls |
| Reading the biggest files | whenever an agent edits them | `cost-mirror.py` ~40k tokens, `launcher.sh` ~37k, `bd-guard.sh` ~29k (81% comments) |
| Test suite | every run you start | everyday subset 8.5 min, all files 16 min (measured while other reviews were running, so inflated). It can't safely run files in parallel today (G1) |

---

## A. Delete — no behavior change

| ID | What | Evidence | Saves |
|---|---|---|---|
| A1 | `attachments/orca-web-paired.png` | committed by a worker by accident: `attachments/` is in `.gitignore`; nothing reads it | 64 KB per clone |
| A2 | `config/orca-skills/` and `config/orca-cli-addendum.md` | their installer (`scripts/sandbox/claude-orca-shell`, `sandbox.json`) no longer exists; `config-sync.sh` never ships them; `provision.d/75-orca-skills` says that path is dead | 13 KB |
| A3 | `scripts/detect-dependencies.sh` and `bin/detect-dependencies` | no caller anywhere | 5.7 KB |
| A4 | `scripts/colors.sh` | never sourced; `view-logs.sh` defines its own colors | small |
| A5 | `map_col3()` in `scripts/orca-run.sh:127` | never called | 1 line |
| A6 | Three bash wrappers `scripts/{contract-gate,delegation-gate,cost-mirror}.sh` | they only find and `exec` the Python file next door. The `.py` files are executable, have a shebang and don't use `__file__`, so `bin/<name>` can link straight to them. Measured: 54→42 ms and 46→35 ms per call (contract-gate, delegation-gate) | ~25 ms CPU on every Bash call, ~12 ms on every prompt, 3 files |

A6 also needs the three callers repointed (`scripts/delegate.sh:570`,
`scripts/recon.sh:291`, `scripts/rules-effective.sh:69-72`).
Verify A1–A6: a repo-wide grep for each name comes back empty, then run the
bats files for the scripts involved (`contract-gate`, `delegation-gate`,
`message-cap`, `delegate`, `recon`, `orca-run`).

## B. Hot path — same output, less time

Each item is checked the same way: run the hook's own bats file, and diff
its output and exit code on a corpus of real payloads before and after.

| ID | What | Evidence | Saves (est.) |
|---|---|---|---|
| B1 | Parse the hook input once. `output-cap.sh` calls `jq` up to 6 times on the same input (lines 50–109 + the emit), `outbound-guard.sh` 4 (192–228), `tier-gate.sh` 5–6 (78–104, plus an unguarded read of a settings file that may not exist). One `jq … @tsv` read replaces each set | measured `jq` start ~6 ms each | ~20–30 ms per hook per call |
| B2 | Exit early when a guard can't match. `outbound-guard.sh` looks up the session id for every Bash call, though only `gh pr create`, `gh repo create` and `bd dolt push` need it. A cheap substring check first skips the rest (`bd-guard.sh` already works this way, which is why it's the fastest guard at 19 ms despite being 115 KB) | code read | 2 `jq` calls on most Bash calls |
| B3 | `contract-gate.py` imports `subprocess` and `glob` at the top but only uses them when the command really is a `bd close` (rare). Import them inside those functions | measured +6.4 ms and +1.5 ms | ~8 ms per Bash call |
| B4 | Let Python cache the compiled hooks. A script run directly is recompiled from source on every call; only imported modules get a `.pyc`. Split each `.py` into a 3-line entry that imports its body | measured compile time: cost-mirror 15.4 ms, contract-gate 2.3, delegation-gate 1.9 | ~15 ms per prompt, ~4 ms per Bash call |
| B5 | `_resolve_script_path` (copied into 35 scripts) spawns `readlink` plus two `dirname`s on every run. Replace `dirname` with `${x%/*}` (same result for these absolute paths) | measured ~7 ms tax per script | ~4–5 ms per hook that carries it |
| B6 | `output-cap.sh:145` sweeps its spill folder with `find … -delete` on every qualifying Bash call. Nothing else cleans that folder, so keep the sweep but run it at most hourly (stamp file) or move it into `disk-cleanup` at session start. Also `date` → bash's built-in `printf '%(…)T'` | code read | 1–2 processes per Bash call |
| B7 | Status line: read every field with one `jq` call and format with one `awk`. Then drop its own usage-API call: Claude Code now passes `rate_limits.five_hour/seven_day.used_percentage` to the status line, so the OAuth-token read, the `curl`, the `/tmp` cache file and 2 more `jq` calls go away | prototype diffed identical on every real input; 68→35 ms and 20→7 processes before dropping the API call | ~35–45 ms per message, one less network call, no script reading the OAuth token |
| B8 | Merge `lane --reset` and `lane --prime --short` into one process (they're two hooks on every prompt, designed to tolerate running in parallel) | measured 48 ms + 31 ms today | ~15–30 ms CPU per prompt |

Expected result of B1–B8 plus A6: a Bash call goes from ~340 ms to about
~240 ms of CPU, and its slowest hook from ~70 ms to ~35 ms. A prompt goes
from ~217 ms to ~150 ms of CPU. All of these are estimates until B is done
and re-measured.

Deferred: merging the seven Bash `PreToolUse` hooks into one dispatcher
would save roughly another ~90 ms of CPU per Bash call. It changes the
settings wiring and each guard's deny semantics, so it's only worth doing
if B leaves the hooks still noticeably slow.

## C. What the model reads — fewer tokens, same rules

| ID | What | Saves |
|---|---|---|
| C1 | `tier-prime.sh:111` session-start line re-explains dispatch rules already in the rulebook § Delegation; keep only the state readout | ~41 tokens per session |
| C2 | `lane.sh` per-prompt reminder: shorten the line (the rubric is in the rulebook, which is always loaded) | ~11 tokens per prompt |
| C3 | `delegation-gate.py` Bash nudge repeats the list of exempt commands every ~8 calls; drop the list (it's in TIERED_ORCHESTRATION.md) | ~49 tokens per nudge |
| C4 | Shared blocks in the agent files ("Context budget" in 3 files, "Report delivery" in all 6) tightened | ~12–36 tokens per spawn |
| C5 | `context-meter` repeats its full 30% notice on every tool call once over budget; send the full text once, then a one-line reminder | up to ~120 tokens per call past the budget |

The always-loaded context is already fairly lean. These are small but they
recur, and C1–C4 are text-only edits (the `lane.bats` exact-output case
changes with C2).

## D. Image, build and startup — needs a Mac to confirm

| ID | What | Evidence | Saves |
|---|---|---|---|
| D1 | Patch `app.asar` in `phase_orca` instead of `phase_template` (copy the small patcher in before it). Boot-time repatching for a folder's own theme still runs as today | recovery.md:773–775 measured a 113 MB duplicate layer | 113 MB per image; a template update also stops rewriting 113 MB |
| D2 | `.dockerignore`: add `tests/`, `.beads/`, `.claude/plans/`, `.codex/`, `.agents/`. Nothing in the image reads them, yet 39 of the last 66 commits changed only these paths, and each such commit makes the next `--update` rebuild the repo-copy layer and the `phase_template` layer after it (113 MB until D1 lands) | grep: no reader; `git log` count | ~3 MB per image; most updates stop rebuilding anything |
| D3 | One `docker inspect` per `claude-dev` open instead of 5–6 (`launcher.sh` 1159, 2224, 2460/2462, 2475, 2526) | code read | ~0.4–1 s per open (estimate) |
| D4 | `setup.sh phase_user` re-chowns the whole bind-mounted home on every boot; every other phase skips when already done. Run it only when the agent user is first created | code read | up to seconds per boot on a big home over the Mac file share (measure) |
| D5 | Split `setup.sh` into per-phase files, each copied right before its own `RUN`, so editing one phase stops rebuilding every payload layer | Dockerfile:32–56; `setup.sh` changed twice in the last 5 days | ~11 min per `setup.sh` edit per Mac. Medium risk; do only if `setup.sh` keeps changing |
| D6 | `bootstrap.sh:430` clones the template with full history for every folder; `--depth 1` works with the `git pull --ff-only` that updates use | code read | the template's history per folder |

D1, D2, D4 and D5 touch `Dockerfile`/`scripts/container/`, and D3 and D6
touch the Mac side, so each needs `tests/mac-e2e.sh` plus a before/after
`docker history` or timing.

## E. Source size — cheaper for the agents that maintain this repo

| ID | What | Saves |
|---|---|---|
| E1 | `bd-guard.sh` is 81% comments, mostly round-by-round bug archaeology with bead ids. Keep every "why this rule is shaped this way" sentence; move the history to one line + a pointer to BEADS_TROUBLESHOOTING.md | ~35–45 KB (~10k tokens per read), ~1 ms per Bash call |
| E2 | Same pass over `outbound-guard.sh` (1.4 comment lines per code line) and `cost-mirror.py` (1,138 docstring lines) | tens of KB |
| E3 | One small shared Python helper for the code copied between the three Python hooks (`_claude_config_dir()` ×3, the command splitter ×2, session-id cleaning) | ~60 lines |
| E4 | One `hook_deny` helper instead of four copies of the same deny JSON (`outbound-guard`, `branch-guard`, `tier-gate`, `workflow-lint`) | ~30 lines |
| E5 | `delegation-gate.py`: three emit functions that differ only in their text become one | ~14 lines |

E1–E2 are comment-only and verified by the same bats files. E3–E5 are pure
extractions; each has bats coverage (see tests/INDEX.md).

## F. Docs that are wrong — fix and shrink

| ID | What |
|---|---|
| F1 | `knowledge-base/DELEGATION_ROUTES.md:85-108, 256-257` says the OpenRouter key lives at `.claude-dev/state/openrouter.key`, set by `claude-dev setup` and read by `claude-orca-shell`/`gen-settings.sh`. None of these exist. The real answer is `./claude-dev key openrouter` → `.claude-dev/home/.openrouter.key` |
| F2 | `knowledge-base/SANDBOX.md:12` says the project is mounted at the same path on both sides. It's `/workspace/<name>`, the change CLAUDE.md describes as the reason the sandbox exists |
| F3 | `knowledge-base/TIERED_ORCHESTRATION.md` rollback section points at `/etc/claude-dev/configs/…`, which doesn't exist. The file is 95 KB; its history-only sections (the delegation-gate experiment write-up, cost-monitor bug stories, rollback log) can shrink to dated one-liners |
| F4 | Dangling references: 4 comments cite `tests/shell-entry.bats` and 3 cite `.claude/plans/instruction-surface-fix.md`; neither exists |
| F5 | README's route list names 3 routes; `config/delegate-routes.json` ships 10 |

## G. Test suite — faster runs, same coverage

| ID | What | Evidence | Saves |
|---|---|---|---|
| G1 | `tests/helpers/setup.bash:37` builds each file's fixture template under `$BATS_RUN_TMPDIR`, which every file in one run shares. Use `$BATS_FILE_TMPDIR` (one per file) | `bats --jobs 4` on a 165-test sample: files overwrote each other's fixture and 27 tests silently never ran (only a one-line "Executed 138 instead of expected 165" warning) | makes G2 possible; costs nothing, each file already rebuilds its own copy |
| G2 | After G1, `run-tests.sh` passes `--jobs <cores>` when GNU `parallel` is installed (it is here; `brew install parallel` on a Mac). Check the full suite once; a file whose own tests share state opts out of running them side by side with `BATS_NO_PARALLELIZE_WITHIN_FILE=true` | same sample: 164 s serial, 71 s with each file's tests in parallel, 35 s with files in parallel too | roughly 3–4× faster runs (estimate for the full suite; the 90 s+ files set the floor) |
| G3 | `setup()` writes 17 stub commands on every test in the 34 files that use the shared helper; most tests use none of them. Build them once per file and copy them in per test | ~145 ms per test × ~300 tests | ~40 s per full run |
| G4 | `make_project` runs the real bootstrap + register (~2 s) 224 times across 33 files. Outside `bootstrap.bats`, register once per file and copy the result into each test | 312 processes per call (strace) | ~150–300 s per full run. Medium risk: some tests check what that registration itself logged, so it needs a file-by-file pass |
| G5 | Re-time every file on a quiet machine, then refresh `SLOW_FILES` in `run-tests.sh` and the speed column in `tests/INDEX.md` | this sweep ran alongside six other reviews | accurate numbers |

Kept as they are: `container-entrypoint.bats`'s fixed sleeps (they prove
something did *not* happen, so shortening them weakens the test) and the
two large fixtures (faithful copies of real output; they parse in
milliseconds).

## Found along the way (not waste, but worth fixing)

- **The bash 3.2 lint isn't run by anything.** CLAUDE.md says
  `scripts/lint-bash32.sh` enforces bash 3.2 on the Mac side, but the test
  that ran it (`tests/shell-entry.bats`) no longer exists. The lint passes
  today; one fast bats case running it on `bootstrap.sh` and `scripts/`
  restores the guarantee.
- **`config/.zshrc` sets `EDITOR`/`VISUAL` and aliases `vim`/`vi` to `hx`
  (Helix), which the image never installs, and no other editor is installed
  either.** Drop those lines; add `nano` or `vim-tiny` to the image only if
  you want an editor in Orca's terminal. (Confirm on a Mac with
  `docker exec <container> command -v hx vim nano`.)

## Looked at and kept

- **`bd-guard.bats`'s 233 cases:** each tries a different way past a
  security guard.
- **CLAUDE.md/AGENTS.md duplication:** Codex reads AGENTS.md and a test
  keeps them in sync.
- **`bats` in the image:** agents use it on your projects' tests.
- **`build-essential`, `python3-pip`, `wget`, `gnupg`, `unzip`, `xz-utils`
  in the base image:** nothing in this repo's scripts calls them, but agents may need
  a compiler or pip for your projects. Removing them is a policy choice,
  not waste; it needs an `apt-get --dry-run` on a Mac first.
- **Gating the Snowflake skill to Snowflake projects:** saves ~139 tokens
  per session, but a brand-new Snowflake project has no markers yet, so it
  would lose the skill exactly when it's needed.
- **The every-start `claude update` check (`provision.d/15-claude-on-path`)
  and the second toolchain check (`10-toolchain-verify`):** both run after
  Orca is already up, so they don't delay you.
- **`.claude/plans/*` history (128 KB):** cited from ~25 code comments;
  excluding it from the image (D2) is enough.
- **The slow test files:** each covers something no fast file does.

## Order of work

1. **G1–G3** first. They make every later check faster, and G1 is one line.
2. **A, F** — deletions and doc fixes. No behavior change; one commit each.
3. **B** — one hook per commit, each with its bats file green and a
   before/after timing in the commit message. Re-measure the whole hook set
   at the end.
4. **C** — text edits, one commit.
5. **E** — comment and duplicate trims, one file per commit.
6. **G4–G5** — the bigger test-fixture change, then fresh timings.
7. **D** — each item separately, each with `mac-e2e.sh` and a before/after
   measurement. Until a Mac run, the commit subject says UNVERIFIED.
