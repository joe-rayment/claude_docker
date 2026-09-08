# Recovery plan: make the template apply fast, correctly, and verifiably

Written 2026-09-07 at commit `92d1117`, from a session that had real access to
Joe's Mac (Docker Desktop, the registered folders, the logs). Everything in
section 1 was measured, not guessed. Read section 0 and section 1 before
touching anything.

This document is written so that a less capable model can execute it one step
at a time. Each step says: what it is, why, what to change, and the exact
check that proves it. Do the steps in order. Do not start a step until the
previous step's check passes.

---

## 0. Rules for whoever executes this plan

1. **One step at a time, in the order written.** Steps 1 to 3 run first in
   real life, so they are fixed first. A broken step 5 cannot be diagnosed
   while step 3 is unreliable.
2. **Every step ends with a check.** Run the check, paste its output into the
   bead or commit message. "The suite is green" is NOT the check for anything
   on the Mac side, because the bats suite stubs `docker`, `open`, `gh` and
   `uname`. The check for Mac-side code is `tests/mac-e2e.sh` (built in step
   0.3) run on a Mac.
3. **Never say "fixed" for a step you could not run.** Say "changed, not yet
   verified on a Mac". Four days were lost to models saying "fixed" about
   things they had never run.
4. **Destructive actions need Joe's explicit OK** in the current prompt:
   removing containers, images or volumes, `rm -rf`, teardown of a folder
   Joe uses. The plan marks these with **STOP: ask Joe**.
5. **Do not redesign.** The design is fixed by this document: Docker Desktop
   is the runtime, one container per folder, the image carries the whole
   toolchain (step 3), the project is mounted at `/workspace/<name>` (step 4).
   Do not switch runtimes, do not move the toolchain again, do not add
   features until gate G7 passes.
6. **Do not edit a test to make an implementation pass.** When a requirement
   changes (and this plan changes several), commit the new test red first,
   then the implementation. That is the repo's existing convention.
7. **bash 3.2** for anything that runs on the Mac (`bootstrap.sh`,
   `scripts/launcher.sh`, `tests/mac-e2e.sh`): no `mapfile`, no associative
   arrays, no `${x^^}`, no `+=` on an empty array under `set -u`.
   `scripts/lint-bash32.sh` enforces it for `scripts/`; add `tests/mac-e2e.sh`
   to its scope.

---

## 1. What is actually true today (measured on Joe's Mac, 2026-09-07)

### 1.1 The machine

| Fact | Value |
|---|---|
| Mac | 10 CPUs, 32 GB RAM, macOS 27.0 |
| Docker | Docker Desktop, engine 29.2.1, VM 16 GB, containerd snapshotter, file sharing = virtiofs |
| Network to GitHub release downloads | ~2.5 MB/s, identical inside the container and on the Mac (measured with the same 40 MB file) |
| gh token | classic OAuth token (`gho_`), scopes include `read:packages`; the private image pulls fine |
| Published image | `ghcr.io/joe-rayment/claude_orca:latest`, 1.59 GB, apt half only |
| Containers running | 4: `claude-orca-claude-orca`, `claude-orca-harness-test` (this template), `claude-orca-claude-dev`, `stocks-claude-dev` (the OLD `claude_docker` template, up 2 days, 8 GB images) |

### 1.2 "The folder does not seem mounted" -- it is. The sandbox works.

Inside the container the ONLY host path is the project. `ls /Users` shows
`joerayment`, `ls /Users/joerayment` shows `Documents`, `ls Documents` shows
`claude_orca`. Those parent directories are empty scaffolding Docker creates so
the bind mount can sit at its host path. Verified by `docker exec` and by
`mount`: one bind mount for the project, one for `.claude-dev/home` at
`/home/agent`, three for the toolchain, one volume for Orca state. Nothing
else from the Mac exists in there.

It LOOKS unsandboxed because the launcher mounts the project at its own
absolute Mac path on purpose (`--volume "$dir:$dir"`, `scripts/launcher.sh`,
`container_create`). Step 4 changes that to `/workspace/<name>` so `cd ..`
shows one folder and nothing that resembles the Mac.

### 1.3 "It takes 30 minutes" -- where the time goes

Timeline of this folder's first start (file mtimes in `.claude-dev/`):

| Time | Event | Elapsed |
|---|---|---|
| 16:38:47 | template cloned (bootstrap) | 0 |
| 16:41:01 | image pull finished (layers were already cached from an earlier folder) | 2 min |
| 16:48:50 | Claude Code installed into the folder's toolchain | 10 min |
| 16:51:03 | opencode installed ("added 2 packages in 2m") | 12 min |
| 16:56:26 | Orca installed | 17.5 min |
| 16:56:29 | Orca serving, URL written | 17.7 min |

So the first start of a folder is ~18 minutes, and ~15.5 minutes of it is
`setup.sh` installing ~1.3 GB of toolchain (Claude Code 205 MB, Orca 527 MB,
bd+dolt+opencode+bats 594 MB, 3,675 files) INTO THE FOLDER over the virtiofs
bind mount, downloading it at 2.5 MB/s. Every new folder repeats this 1 GB
download; nothing is shared between folders.

The "Harness test" folder tells the same story: its toolchain was installed
13:16 -> 13:31 (15 min). Its `setup.log` also shows three full apt reinstalls
from earlier that day, when the token was a fine-grained PAT and the launcher
fell back to plain `ubuntu:24.04` (5 min of apt on EVERY recreate). Its last
start, with the toolchain cached and the prebuilt image, took 13 seconds
(16:59:19 register -> 16:59:32 URL).

Virtiofs is slow for many small files but it is not the 15 minutes:
measured inside the container, creating 300 small files takes 83 ms on the
bind mount vs 5 ms on a docker volume; unpacking an Orca-sized tree (219 MB,
3,600 files) takes 2.05 s vs 0.15 s; a 200 MB sequential write is the same on
both. The minutes are download bytes + npm.

**Conclusion for step 3:** put the toolchain back in the image. One pull per
Mac (cached by Docker, shared by every folder, only changed layers re-pulled
on update), then a new folder's first start is seconds, not 18 minutes.

**Done, and measured** (2026-09-07, `tests/mac-e2e.sh`): a fresh folder
went from **383 s** to Orca serving to **6 s**, and a recreate from 4 s to
3 s. The image went from 1.59 GB to 3.66 GB, pulled once per Mac instead
of 1.3 GB downloaded per folder.

### 1.4 "bd is missing" -- it is installed and initialized; the failure was the working directory

Verified inside the running container, as the `agent` user, from the project
directory, both via `docker exec` and via an interactive `zsh -i`:
`bd where` -> `/Users/joerayment/Documents/claude_orca/.beads`, `bd status`
-> 70 closed, 4 ready. The Harness test folder's container also answers
`bd status`.

`bd` finds its database by walking UP from the current directory. In the
pasted transcript the shell had just done `cd ..` three times, to `/Users`,
where there is no `.beads` above it, so bd said "no beads database found".
Step 5 makes bd work from any directory in the container by setting
`BEADS_DIR`, so this cannot happen again.

### 1.5 "Image paste failed: Read permission denied" -- the browser, not the container

Orca Web reads images with `navigator.clipboard.read()` (grep of
`app.asar` confirms). The wording "Failed to execute 'read' on 'Clipboard':
Read permission denied" is Chromium's. It appears when the site permission
"Clipboard" for the origin `http://127.0.0.1:<port>` is Block, or a prompt
was dismissed. The URL Orca publishes is `http://127.0.0.1:6770/...`, which
is a secure context, so the permission CAN be granted. Every folder has a
different port, so it is a different origin, so it is granted per folder.
Step 8 covers the diagnosis; the template can only document it.

### 1.6 The verification gap that caused the 4 lost days

- The bats suite (752 tests) stubs docker. It proves logic, not the Mac.
- CI `image.yml`: the Linux job is green and publishes `:latest`. The macOS
  job (added 2026-09-07 00:01) has NEVER passed. Its latest failure is inside
  the container: `install: cannot change ownership of '/usr/local/bin/dolt':
  Permission denied` -- colima's virtiofs refuses `chown` on the toolchain
  bind mount. That is a second reason to stop installing the toolchain into
  a bind mount (step 3).
- Therefore the only place the Mac path has ever been verified is Joe's Mac,
  by Joe, by hand. Step 0.3 fixes this: a script that runs the real thing on
  the Mac and prints a timing table.

### 1.7 Clutter that confuses every diagnosis

- `claude_orca/.claude-dev/` on Joe's Mac is a git clone of the OLD
  `joe-rayment/claude_docker` template (2026-09-03, docker-compose era) with
  the v4 layout (`template/`, `bin/`, `home/`, `toolchain/`, `run/`) written
  on top of it as untracked files. Two generations in one directory.
- `~/.claude-orca` (18 MB) is a v2 Seatbelt leftover.
- The Harness test folder's `.claude-dev` carries `srt/`, `sandbox.json`,
  `app/`, `claude/` from v2 plus everything since.
- `container.log` has no timestamps and is 99% `docker inspect` polls
  (4,625 lines in Harness test), so it cannot tell where time went.
- The old-template containers (`claude-orca-claude-dev` 3.7 GB RAM,
  `stocks-claude-dev`) are still running next to the new ones.

---

## 2. The pipeline: the eight steps that run when the template is applied

| # | Step | Runs where | Code | Must leave behind | Check |
|---|---|---|---|---|---|
| 1 | Preflight: OS, git, gh, gh login, `read:packages`, docker, daemon up | Mac | `bootstrap.sh` top half | nothing | `bootstrap.sh` prints `==>` lines and reaches "Installing the claude_orca template" |
| 2 | Register: clone template, `bin/claude-dev` symlink, `./claude-dev` stub, `claude-orca.json`, port | Mac | `bootstrap.sh` bottom, `launcher.sh cmd_register_v3` | `.claude-dev/{template,bin,home,run,state}`, json v3, `run/port` | layout assertions (same as CI's "Assert the layout" step) |
| 3 | Image: registry login, pull, or runtime fallback | Mac | `launcher.sh acquire_image`, `try_pull` | `run/image-source` = `pulled`, image in `docker images` | `docker image inspect` ok, `image-source` = pulled |
| 4 | Container create: mounts, env, port, dns | Mac | `launcher.sh container_create` | container `claude-orca-<name>` running | `docker inspect` mounts and env |
| 5 | In-container install: `setup.sh` (no-op on a full image) | container, root | `scripts/container/setup.sh`, entrypoint | `run/setup.log` ending "all phases done" | `setup.sh --check` all ok (one allowed non-ok row: the remapped uid) |
| 6 | Seeding: uid remap, config-sync, git identity, Claude trust, Orca state, `bd init` | container, root then agent | `entrypoint.sh`, `seed-orca-state.sh`, `config-sync.sh` | `home/.claude/CLAUDE.md`, `home/.gitconfig`, `home/.claude.json`, Orca `orca-data.json`, `.beads/` | the "registered folder checklist" in step 6 |
| 7 | Serve: `orca-ide --serve`, URL file, `orca repo add`, browser open | container then Mac | `entrypoint.sh` bottom, `launcher.sh wait_for_web_url`, `open_url` | `run/orca-web-url.txt` (0600), `run/port` | `curl` of the URL returns 200 and the page mentions Orca |
| 8 | Working inside: terminals, `bd`, `claude` login, paste | browser + container | Orca, hooks, rulebook | -- | the in-container checklist and the browser checks in step 8 |

Gates: **G0** the loop exists (step 0). **G1-3** steps 1-3 correct and fast.
**G4** the mount. **G5-6** seeding checklist. **G7** serve. **G8** inside.

---

## Step 0 -- Build the verification loop before fixing anything (gate G0)

### 0.1 Clean the Mac so measurements mean something

Do these in this order. Each has a check.

a. **Stop this folder's stale template clone.** `claude_orca/.claude-dev` is
   the old `claude_docker` clone with v4 inside. Fix: after step 3 lands, run
   `./claude-dev --teardown` here (it snapshots `.beads/issues.jsonl` to
   `.claude-dev-snapshots/`, removes the container, its volume and the whole
   `.claude-dev`), then re-run the bootstrap one-liner. Not before step 3:
   re-registering today costs another 18 minutes. **STOP: ask Joe** before
   teardown -- the folder home holds the container's Claude login.
   Check: `ls .claude-dev` shows only `template bin home run state
   claude-orca.json` (and `toolchain` only on the runtime path).

b. **The v2 leftover.** `rm -rf ~/.claude-orca`. Nothing references it (no rc
   blocks found in `~/.zshrc`, `~/.zprofile`, `~/.bash_profile`).
   **STOP: ask Joe.** Check: `ls ~/.claude-orca` -> No such file.

c. **Old-template containers.** `claude-orca-claude-dev` and
   `stocks-claude-dev` belong to the previous template and may still be in
   use for the `stocks` project. **STOP: ask Joe** whether they are still
   used. If not: `docker rm -f <name>`, `docker rmi claude-code-dev:claude-orca
   claude-code-dev:stocks` (16 GB), and the `*-agent-home` volumes
   (`docker volume ls`). Check: `docker ps -a` lists only `claude-orca-*`
   containers from this template.

d. **The leftover test container.** `claude-orca-harness-test` is the Harness
   test folder's real container; leave it, it is Joe's test bed.

e. **Install bash 5 for the suite.** `brew install bash`. Reason:
   `run-tests.sh` documents that under macOS bash 3.2 a failing `[[ ]]` does
   not fail its test, so the suite is decorative. Check:
   `/opt/homebrew/bin/bash --version` prints 5.x, and `./run-tests.sh` prints
   `==> bash 3.2 ... running bats under /opt/homebrew/bin/bash`.

f. **Baseline the suite.** `./run-tests.sh 2>&1 | tail -20`. Record the count
   of `not ok` lines. Expected today: 0. If it is not 0, stop and report;
   do not "fix" tests.

### 0.2 Make the logs carry time

Small, safe, and everything after depends on it.

- `scripts/launcher.sh`, `ctr_log_line`: prefix every mirrored line with
  `$(date '+%H:%M:%S')`.
- `scripts/launcher.sh`, `ctr_mirror`: do not mirror `inspect` polls; instead
  `wait_for_web_url` logs one line when the state changes and one line
  `orca up after N s` when the URL appears. Also print that line to the
  terminal.
- `scripts/launcher.sh`, `try_pull`: log `pull started` / `pull done in N s`.
- `scripts/container/setup.sh`, `say()`: prefix with `+${SECONDS}s` so
  `setup.log` reads `[setup +312s] orca: installing 1.4.197`.
- `scripts/container/entrypoint.sh`, `log()`: same `+${SECONDS}s` prefix.

Check: after one `./claude-dev` on any registered folder,
`cat .claude-dev/run/container.log` shows timestamps and fewer than 20 lines
for that start, and `setup.log` lines carry `+Ns`.

### 0.3 Write `tests/mac-e2e.sh` -- the real end-to-end harness

This is the single most important deliverable of the plan. It is what the
CI macOS job tries to be, run on a real Mac, with timings. bash 3.2 clean.

Behaviour, in order:

1. Refuse to run unless `uname -s` is Darwin and `docker info` works.
2. Make a throwaway project at a SHORT path (unix-socket limits):
   `mktemp -d /tmp/orca-e2e.XXXXXX` then `$tmp/p`, `git init -b main`, one
   empty commit.
3. Run the REAL bootstrap against it, with the checkout under test as the
   template: `CLAUDE_ORCA_TEMPLATE_URL="$REPO_ROOT" CLAUDE_ORCA_OPEN=0 bash
   "$REPO_ROOT/bootstrap.sh" "$tmp/p"`. Time it. Capture output to
   `tests/.cache/mac-e2e-<timestamp>.log` (that directory is gitignored).
4. Assert the layout exactly as `image.yml`'s "Assert the layout" step does
   (template clone with `.git`, relative `bin/claude-dev` symlink, json v3,
   port >= 6768, `run/port` agrees, nothing created in `$HOME/.claude-dev`).
5. Assert the container exactly as the "Assert the container is up" step
   does (running, image ref, port on 127.0.0.1 only, URL file mode 600, GET
   the URL minus fragment -> 2xx/3xx, body mentions Orca).
6. Assert inside the container with `docker exec -u agent`:
   - `setup.sh --check`: every row ok except the one remapped-uid row.
   - `pwd` in `zsh -lic pwd` from `--workdir <guest project dir>` equals the
     guest project dir (after step 4: `/workspace/p`).
   - `bd status` from the project dir works; `cd / && bd status` also works
     (after step 5).
   - `ls /Users` fails with "No such file or directory" (after step 4).
   - `claude --version`, `bd --version`, `dolt version`, `opencode --version`
     print the pins from `setup.sh`.
7. Recreate: `docker rm -f` the container, run `./claude-dev` again, time it.
   Must serve again in under 60 s.
8. Print a table: `step | result | seconds` for bootstrap, pull, first serve,
   in-container checks, recreate. Exit 0 only if every row is ok.
9. Teardown with `./claude-dev --teardown` unless `--keep` is given; assert
   `.claude-dev` is gone and `docker volume ls` no longer lists the state
   volume.

Options: `--keep` (leave the folder and container for inspection),
`--image REF` (sets `CLAUDE_ORCA_IMAGE`, for a locally built image),
`--folder DIR` (use an existing folder instead of a throwaway one; never
tears it down).

Check for 0.3 itself: run it once against the current code. Expected result
TODAY: layout ok, container ok, first serve ~15-18 min (the toolchain
install), recreate < 60 s, the `/Users` and `cd /` rows FAIL (they are what
steps 4 and 5 fix). Save the table; it is the baseline every later step is
compared against.

### 0.4 Local image builds (so step 3 does not depend on CI)

Docker Desktop builds arm64 natively. `docker build -t
ghcr.io/joe-rayment/claude_orca:local .` from the checkout works on this Mac
(expect 10-15 min at 2.5 MB/s for the downloads). Then
`tests/mac-e2e.sh --image ghcr.io/joe-rayment/claude_orca:local`. The
launcher already honours `CLAUDE_ORCA_IMAGE` and skips the registry when the
image is local. Check: the e2e table shows `image: local` and `pull: 0 s`.

Gate **G0** passes when: 0.1 e/f done, 0.2 landed, 0.3 runs end to end and
prints a table, 0.4 built an image once.

---

## Steps 1-3 -- Preflight, register, image (gates G1-G3). Fix these first.

### Step 1: preflight (`bootstrap.sh` top half)

What it does today: OS check, installs git/gh/Docker Desktop if missing,
`gh auth login --scopes read:packages` when not logged in, asks for
`read:packages` via `gh auth refresh` only when the scope header says it is
missing, starts Docker Desktop and waits 60 s.

Known state: works on Joe's Mac (all four runs today got past it). Two
things to change:

- **Print the facts it decided on**, one line each, before "Installing the
  template": OS, git version, gh version, gh account, token kind (`gho_`
  classic / `github_pat_` fine-grained / other), `read:packages` yes/no/unknown,
  docker version, daemon up. A person or model reading a pasted log then
  knows which path step 3 will take without guessing.
- **Docker Desktop wait is 60 s.** A cold Docker Desktop on a Mac can take
  longer. Raise to 180 s and print a dot every 5 s.

Check: `bash bootstrap.sh /tmp/some-empty-dir 2>&1 | head -20` shows the
facts block, or the `mac-e2e.sh` log shows it.

### Step 2: register (`bootstrap.sh` bottom, `cmd_register_v3`)

What it does today: clone or `pull --ff-only` the template into
`.claude-dev/template` (stashing local edits), `link-bin.sh`, then `register`:
mkdir `home run state`, write `claude-orca.json` if absent, write the
`./claude-dev` stub, choose the port, then `acquire_image`, then open.

Known problem (section 1.7): register happily runs ON TOP of a foreign
`.claude-dev` -- an old-template clone, or a v2 layout -- and produces a
directory nobody can reason about.

Change: at the top of the install section of `bootstrap.sh`, before
`mkdir -p "$HOST"`: if `$HOST` exists and has no `claude-orca.json` and no
`template/` but does have `.git` (or `docker-compose.yml`, or `sandbox.json`,
or `srt/`), refuse:

```
Error: /path/.claude-dev is from an older claude_orca / claude_docker layout.
  Move it aside and re-run:   mv /path/.claude-dev /path/.claude-dev.old-<date>
  (nothing in it is needed; beads live in /path/.beads, not in there)
```

Bootstrap is non-interactive (its stdin is the script), so it must refuse
with the exact command rather than ask. Add the case to `tests/bootstrap.bats`
(red first).

Check: create a dir with `.claude-dev/.git` and `.claude-dev/docker-compose.yml`,
run bootstrap against it, expect the error and exit 1; on a clean dir the
layout assertions of `mac-e2e.sh` pass.

### Step 3: the image -- put the whole toolchain back in it (the big one)

**Decision.** The image carries everything `setup.sh` installs: the apt half
AND Orca, Claude Code, opencode, bd, dolt, bats. The folder no longer carries
a toolchain when it runs the prebuilt image. Reasons, all measured in
section 1: 15.5 of the 18 first-start minutes are the per-folder toolchain
install; every new folder re-downloads 1 GB; the toolchain-in-a-bind-mount is
what fails CI's macOS job (`chown` denied by colima's virtiofs); a full image
existed and was green in CI on 2026-09-06 (runs 34031372226, 34060560684),
so the QEMU arm64 build of it is proven feasible. The cost is a bigger image
(estimate ~2.9 GB, one pull per Mac, then Docker caches layers and an update
re-pulls only changed layers) and slower CI builds. Joe's stated priority is a
fast, verifiable apply, so that trade is correct.

**Keep** the runtime fallback (plain `ubuntu:24.04` + install at first start
into the folder's toolchain cache) for a token that cannot pull the private
image. It stays exactly as it is; it just stops being the common path.

Changes, in this order, each committed separately:

a. **Tests first (red).** New or superseded contracts:
   - `tests/container-image.bats`: the Dockerfile runs the toolchain phases
     (grep for `--phase orca`, `--phase claude`, ... or `--toolchain`).
   - `tests/launcher-v3.bats`: when `run/image-source` is `pulled`, the
     `docker run` line has NO `--volume .../toolchain/...` mounts; when it is
     `runtime`, it has all three (as today).
   - `tests/toolchain-cache.bats`: rewrite the claims: "the folder carries a
     toolchain only on the runtime path"; `weburl_timeout` is 120 s when
     `image-source` is `pulled` regardless of any folder cache, 1800 s on
     `runtime`.
   Commit as RED with the failing output pasted.

b. **`Dockerfile`.** After the `--image` RUN, one RUN per toolchain phase in
   order of how rarely each changes, so a version bump invalidates only the
   layers below it:
   ```
   RUN /opt/claude-orca-setup.sh --phase orca
   RUN /opt/claude-orca-setup.sh --phase dolt
   RUN /opt/claude-orca-setup.sh --phase bd
   RUN /opt/claude-orca-setup.sh --phase bats
   RUN /opt/claude-orca-setup.sh --phase opencode
   RUN /opt/claude-orca-setup.sh --phase claude
   ```
   Keep the `COPY . /opt/claude-orca` and `--phase template` after them (the
   repo copy changes on every commit and must not invalidate the toolchain
   layers). Add `ARG`s for the other pins only if needed; `setup.sh` already
   reads them from env.

c. **`scripts/launcher.sh`, `container_create`.** Add the three
   `TOOLCHAIN_MOUNTS` volumes ONLY when `image_source` is `runtime`. Drop
   `toolchain_cached()` from the timeout decision: `weburl_timeout` is 120
   when `pulled`, `CLAUDE_ORCA_WEBURL_TIMEOUT_RUNTIME` (1800) when `runtime`.
   `mkdir -p` of the toolchain dirs likewise only on the runtime path.

d. **`scripts/container/entrypoint.sh`.** No change needed: on the full
   image `setup.sh` reports every phase "already present" in a few seconds.
   Verify that claim in the check below; if the `--check` plus full run costs
   more than 10 s, skip the full run when `--check` passes.

e. **`.github/workflows/image.yml`.** Replace the "toolchain cache is what a
   recreate reuses" stage with: (1) `docker run --rm IMAGE setup.sh --check`
   is all-ok; (2) the e2e folder's first start has no `toolchain/` dir and
   serves in under 90 s; (3) a recreate serves in under 60 s. Keep the smoke
   stages. Keep the macOS job; with no toolchain bind mount its failure mode
   is gone -- if it still fails, its diagnostics step now shows the reason.

f. **Docs.** `README.md` ("The image", "What is isolated" table,
   "Requirements"), `CLAUDE.md` architecture paragraph, the `Dockerfile`
   header comment, `.claude/plans/startup-v4.md` (mark superseded on this
   point). Delete the sentence claiming a first start pays ~3 minutes more.

Local verification (no CI needed):

1. `docker build -t ghcr.io/joe-rayment/claude_orca:local .` (10-15 min).
2. `docker run --rm ghcr.io/joe-rayment/claude_orca:local
   /opt/claude-orca/scripts/container/setup.sh --check` -> every row
   `[check] ok`.
3. `tests/mac-e2e.sh --image ghcr.io/joe-rayment/claude_orca:local`.
   Expected table: bootstrap < 2 min, pull 0 s, first serve < 60 s, recreate
   < 60 s, no `toolchain/` directory in the folder.
4. Then publish main and watch `image.yml`; the Linux job must push
   `:latest`; then `tests/mac-e2e.sh` with no `--image` (a real pull).
   Record the pull time (expected 10-20 min ONCE on this network; a second
   run on the same Mac should show `Image is up to date` in seconds).

Gate **G1-3** passes when: the mac-e2e table for a fresh folder shows
bootstrap-to-URL under 3 minutes with the image already on the Mac, and the
Linux CI job is green.

**Optional decision for Joe, not for a model:** make the GHCR package public.
Then no token scope is ever needed and the runtime fallback is never taken.
The image contains this template's `config/` and scripts (no secrets), so
this is a question of whether the template itself may be public.

**Plan B if the QEMU arm64 build of a toolchain phase fails** (Bun binaries
have been seen to crash under emulation): build the arm64 leg natively on the
macOS runner (`docker buildx build --platform linux/arm64 --load` under
colima) and push a manifest list, OR install the toolchain once per Mac into
a shared named volume `claude-orca-toolchain-<pins-hash>` mounted read-only
into every folder's container. Do not go to plan B before the local build in
step 3 verification item 1 has actually failed.

---

## Step 4 -- The container sees one folder: mount at `/workspace/<name>` (gate G4)

**Decision.** The project is bind-mounted at `/workspace/<name>` where
`<name>` is `derive_project_name` of the folder (lowercased, hyphens; this
folder becomes `/workspace/claude-orca`, Harness test becomes
`/workspace/harness-test`). Then `pwd` shows `/workspace/claude-orca`,
`cd ..` shows exactly one entry, and nothing in the container spells a Mac
path.

Why this is safe: every in-container consumer already takes the path from
`PROJECT_DIR` (entrypoint, `seed-orca-state.sh`, `bd init`, the Claude trust
seed, `orca repo add`, the runtime-path entrypoint command). The Mac side
reads `run/*` files by host path. Nothing needs the two paths to be equal.

Changes:

a. **Tests first (red).** `tests/launcher-v3.bats` "open runs the container
   with the project and home mounted at the same paths..." becomes: the
   `docker run` line has `--volume $primary:/workspace/<name>` and
   `-e PROJECT_DIR=/workspace/<name>` and `-e CLAUDE_ORCA_HOST_PROJECT_DIR=$primary`;
   `shell` uses `--workdir /workspace/<name>`; on the runtime path the
   command is `bash /workspace/<name>/.claude-dev/template/scripts/container/entrypoint.sh`.
   Also `tests/docs.bats` "no doc mentions tmux, fleet, or /workspace as the
   project path": that test is a RESIDUE check left from the old template,
   which mounted the project at bare `/workspace`; it is not a design
   objection to this step. Drop `/workspace` from its term list (keep `tmux`
   and `fleet`) in the same red commit, or the README edit in 4d fails it.
   The `/workspace/src/x.py` paths in `tests/delegation-gate.bats` are
   fixture file names and stay as they are.

b. **`scripts/launcher.sh`.** One function `guest_project_dir() { printf
   '/workspace/%s\n' "$(derive_project_name "$1")"; }` used by
   `container_create` (volume target, `PROJECT_DIR`, the runtime command),
   `cmd_shell_v3` (`--workdir`), and the doctor (print it). Pass the host path
   too, as `CLAUDE_ORCA_HOST_PROJECT_DIR`, for messages only.

c. **`scripts/container/entrypoint.sh`.** No change. Optionally log
   `project: $PROJECT_DIR (host: ${CLAUDE_ORCA_HOST_PROJECT_DIR:-?})`.

d. **Docs.** README "One boundary" paragraph and the isolation table,
   `CLAUDE.md`, the launcher and Dockerfile header comments,
   `.claude/plans/container-v3.md` line 95 ("Same absolute path") -- mark
   superseded, do not rewrite history.

Migration of existing folders: Orca's state volume remembers the repo at the
old path, and `home/.claude.json` trusts the old path. A registered folder
must be torn down and re-registered once: `./claude-dev --teardown` then the
bootstrap one-liner. Beads survive via the snapshot round trip. Say this in
the README under "If the bootstrap stops".

Known consequences, to document, not to fix:
- Paths that agents write into beads notes, commits and Orca worktrees are
  `/workspace/...` paths. That is correct inside the container and
  meaningless on the Mac.
- A git worktree created inside the container (Orca puts them in
  `<project>/.orca-worktrees`) is recorded in `.git/worktrees/<name>/gitdir`
  with the container path; from the Mac `git worktree list` shows it as
  missing. Do not run `git worktree prune` on the Mac for such a folder.
- Orca's serve log showed `EACCES: mkdir '/Users/joerayment/orca'` while
  trying to delete a worktree that the Mac Orca app had once created at
  its own default location. Harmless; it goes away with the teardown.

Check (add all three rows to `mac-e2e.sh`): inside the container
`ls /Users` -> `No such file or directory`; `ls /workspace` -> exactly one
entry; `zsh -lic pwd` from the workdir -> `/workspace/<name>`. Plus, by hand
once: the Orca sidebar shows the repo and a new terminal opens in
`/workspace/<name>`.

---

## Steps 5-6 -- Inside the container: install and seeding (gates G5-G6)

### Step 5: `setup.sh` at start

After step 3 this is a no-op on the prebuilt image. Two changes:

- `bd` must work from ANY directory. The launcher passes
  `-e BEADS_DIR=/workspace/<name>/.beads` and `-e CLAUDE_ORCA_ROOT=/workspace/<name>`
  at `docker run` (so `./claude-dev shell` sees them), and the entrypoint
  exports both before starting `orca-ide --serve` (so every Orca terminal and
  agent inherits them, and the `local` runtime backend behaves the same).
  Add both to the env assertion in `tests/launcher-v3.bats` (red first).
- Silence the bd metrics banner once per folder: after `bd init` (or when
  `.beads` already exists) run `bd metrics off` as the agent; it writes
  `~/.config/bd/config.yaml` in the folder home. Optional, cosmetic.

Check: `docker exec -u agent -w / claude-orca-<name> bd status` prints the
status table; `./claude-dev shell` then `cd /tmp && bd status` also works.
Both rows go into `mac-e2e.sh`.

### Step 6: the registered-folder checklist

This is "the config I want" made explicit. After a first start, ALL of these
must hold. Put them in `mac-e2e.sh` as in-container assertions; also add
`./claude-dev --doctor --inside` (or a new `./claude-dev verify`) that runs
the same list through `docker exec` and prints ok/FAIL per row, so Joe can
run one command on any folder.

| # | What | Where | How to check |
|---|---|---|---|
| 1 | Orca serving, repo registered | container | `run/orca-web-url.txt` exists, mode 600; `orca repo list --json` (with `ORCA_USER_DATA_PATH=/home/agent/.config/orca`) lists `/workspace/<name>` |
| 2 | Worktree base inside the project | Orca state | `orca-data.json` in the state volume has `worktreeBasePath` = `/workspace/<name>/.orca-worktrees` |
| 3 | Theme | Orca state + web-index | `settings.theme` = the json's theme (default dark); `setup.sh --check` row "orca web theme seeded" ok |
| 4 | beads initialized with the folder's prefix | project | `.beads/` exists, `bd where` prints prefix = `derive_project_name`, `bd status` works from `/` |
| 5 | Rulebook synced | folder home | `home/.claude/CLAUDE.md` equals `config/claude-user-memory.md` (byte-identical); `run/config-hash` equals the template's config hash |
| 6 | Agents, commands, skills synced | folder home | `home/.claude/agents/{executor,verifier,scout,oracle,professor,bead-auditor}.md`, `home/.claude/commands/{tier,code-map}.md`, `home/.claude/skills/` present |
| 7 | Hooks wired, Orca's own hook entries preserved | folder home | `home/.claude/settings.json` has the template's `SessionStart`/`UserPromptSubmit`/`PreToolUse` entries AND Orca's `~/.orca/agent-hooks/claude-hook.sh` entry |
| 8 | Git identity | folder home | `home/.gitconfig` has `user.name` and `user.email` from the Mac |
| 9 | Claude first-run seeded | folder home | `home/.claude.json` has `hasCompletedOnboarding` and `projects["/workspace/<name>"].hasTrustDialogAccepted`; `home/.claude/settings.json` has `skipDangerousModePermissionPrompt` |
| 10 | Toolchain pins | container | `claude --version`, `bd version`, `dolt version`, `opencode --version`, `/opt/orca/VERSION` match `setup.sh` |
| 11 | uid mapping | container | files an agent creates in the project are owned by Joe on the Mac (`touch` inside, `ls -l` outside shows `joerayment`) |
| 12 | Boundary | container | `ls /Users` fails; `mount` lists exactly: the project, `/home/agent`, the Orca state volume (and the three toolchain mounts only on the runtime path) |
| 13 | Network egress | container | `curl -sI https://api.github.com` works; `getent hosts ports.ubuntu.com` resolves |
| 14 | OpenRouter guard (only when a key was stored) | container | `run/openrouter-guard.pid` alive, `OPENROUTER_BASE_URL` is the guard's loopback URL in Orca's agent env |

Rows 1-9 are already produced by the entrypoint today (its log for this
folder shows every seed line). What is missing is the CHECK. Build the check.

Gate **G5-6** passes when `./claude-dev verify` prints 14 ok rows on a fresh
folder and on this folder after its re-registration.

---

## Step 7 -- Serve, handshake, browser (gate G7)

Works today (URL published in 3 s once the toolchain is there). Keep, plus:

- `wait_for_web_url` prints `Orca is up (N s)` and the launcher prints the
  three-line "How to run it" block. Already there; keep.
- The `orca-serve.log` is full of dbus/keyring noise that hides real errors.
  Add to `--doctor`: the last 5 lines of `orca-serve.log` that are not dbus,
  keyring or codex-trust noise.

Check: `mac-e2e.sh` rows "first serve" and "recreate" green; the browser
opens on `http://127.0.0.1:<port>/web-index.html#pairing=...`.

---

## Step 8 -- Working inside (gate G8)

### 8.1 Terminals and bd
Covered by steps 4 and 5. By hand once: open a terminal in Orca, run `pwd`
(expect `/workspace/<name>`), `bd status` (expect the table), `cd .. && ls`
(expect one entry), `cd / && bd ready` (expect a list, not an error).

### 8.2 Claude Code sign-in
First `claude` run in an Orca terminal prints a login URL; open it on the
Mac, paste the code back. Credentials land in the folder home
(`.claude-dev/home/.claude/`) and survive recreates; teardown deletes them.
Document that teardown = sign in again. Nothing to fix.

### 8.3 The clipboard error (section 1.5)
Not a template bug; a browser permission. Diagnosis to add to README under
"If the bootstrap stops" (rename that section "If something stops"):

1. Which browser? The message wording is Chromium's (Chrome, Arc, Brave,
   Edge). Safari and Firefox behave differently and may not support image
   paste in this app at all.
2. In Chrome open `chrome://settings/content/siteDetails?site=http://127.0.0.1:<port>`
   and set **Clipboard** to Allow. Each folder has its own port, so its own
   origin, so its own permission.
3. Reload the tab, click into the terminal once (the page must be focused
   and the paste must come from a keypress), then paste.
4. Text paste never needs this permission; only images do.
If after that it still fails in Chrome, capture `chrome://policy` and the
DevTools console line and file it against Orca (`stablyai/orca`), because the
call is theirs (`navigator.clipboard.read` in `app.asar`).

### 8.4 The two instructions Joe keeps repeating, put where they bind

Findings: the rulebook shipped into every container
(`config/claude-user-memory.md` -> `~/.claude/CLAUDE.md`) already says
"Verification is running it -- never inspection". Nothing anywhere says what
"running it" means for the HOST side of this template, which is why Linux
agents kept reporting Mac fixes as done. The 17 `bd remember` memories hold
lessons, not rules.

Add to this repo's `CLAUDE.md` (the project file, both here and mirrored in
`AGENTS.md`), a section "Definition of done for host-side changes":

> A change to `bootstrap.sh`, `scripts/launcher.sh`, `Dockerfile`,
> `.github/workflows/image.yml` or anything under `scripts/container/` is
> done only when `tests/mac-e2e.sh` has been run on a Mac against that
> change and its summary table is pasted into the commit message or bead.
> A green bats suite is not evidence for the Mac path: the suite stubs
> docker, open, gh and uname. If no Mac is available, the change is
> "unverified on a Mac" and must say so in the commit subject.

And one line in the rulebook (`config/claude-user-memory.md`, under
"Sandbox vs. your systems"): "A claim that a step works is only ever made
about a step you ran in this session; otherwise say what you could not run."

Keep the bd memories; add one: "2026-09-07: Joe measured the Mac path
himself for four days because nothing else did. `tests/mac-e2e.sh` exists so
that never has to happen again."

---

## 9. Order of work, with gates (the checklist)

Ticked items were done in the session of 2026-09-07 and verified as noted.

- [x] 0.1 e-f: bash 5 installed; **baseline suite: 703 ok / 49 failed**
- [x] 0.2: timestamps in `container.log`, `setup.log` and the entrypoint (commit `0cc7ba3`)
- [x] 0.3: `tests/mac-e2e.sh` written and run; **baseline table: 383s to serving, 25 ok / 2 FAILED**
- [x] 0.4: `docker build` locally -> **G0**
- [x] 1: preflight facts block, 180s Docker wait (`22b446e`)
- [x] 2: bootstrap refuses a foreign `.claude-dev`
- [x] 3a-3d: toolchain back in the image, one layer per phase; mounts and wait keyed on the image
- [x] 3: **`mac-e2e.sh --image :local`: 6s to serving, 3s recreate, 27 ok / 0 FAILED** -> **G1-3**
- [x] 3e-f: CI stage rewritten; README and the architecture overview updated
- [x] 4: `/workspace/<name>`; `ls /Users` fails inside; a login shell lands in the project -> **G4**
- [x] 5: `BEADS_DIR`; `bd status` works from `/` -> confirmed by the e2e row
- [x] 6: `./claude-dev verify` -- 14 checks, the container's half in
      `scripts/container/verify-folder.sh` -> **G5-6**
- [ ] 0.1 a-d: **STOP: ask Joe**, then clean the Mac and re-register `claude_orca` and `Harness test`
- [ ] 7: both of Joe's folders opened in a browser after re-registration -> **G7**
- [ ] 8.1-8.2: the by-hand checks inside Orca (terminals, `claude` sign-in)
- [x] 8.3: the clipboard note is in the README
- [x] 8.4: the definition of done is in `CLAUDE.md` and `AGENTS.md`
- [ ] publish `main` and watch `image.yml`; then `tests/mac-e2e.sh` with a real pull
- [ ] the macOS CI job: its old failure (the toolchain chown into a bind
      mount) is gone, so it may pass now; if it does not, its diagnostics
      step names the reason

### What the numbers actually came out as

| | before | after |
|---|---|---|
| bootstrap to Orca serving, fresh folder | 383 s | **6 s** |
| recreate | 4 s | **3 s** |
| mac-e2e checks | 25 ok, 2 FAILED | **27 ok, 0 FAILED** |
| image size | 1.59 GB + 15.5 min per folder | **3.66 GB, once per Mac** |
| bats suite on this Mac | 703 ok, 49 failed | **740 ok, 30 skipped, 29 failed** |

No failure in that 29 is new: every one was already failing before this
session (checked by diffing the failing sets). They are all environment,
and none is a defect:
they were checked by running the same files on real Linux inside the
image. See "What is left" below.

## 10. What is left, and what it is worth

**The 30 failing bats cases on this Mac.** Run inside the image as the
`agent` user they come down to **six**: two need root (`phase_user`
chowning a home with a live socket) and four need root because the
entrypoint runs `setup.sh`. The suite has cases that need root and cases
that assume non-root, so no single user passes all of them. Making each
one declare the user it needs is a small, well-defined job, and it is what
stands between this repo and a CI job that runs the suite at all --
because today **no workflow runs bats**. `image.yml` is the only workflow
and it never invokes it. Measured 2026-09-07 inside the image as `agent`:
763 ok, 22 skipped, 6 failed.

**The container runs the IMAGE's copy of the template.** The entrypoint
prefers `/opt/claude-orca` when it exists, so on the pulled path
`setup.sh`, `config/` and the entrypoint itself all come from the image,
not from the folder's clone. A template change therefore reaches a folder
through an image pull. That is cheap now -- the repo COPY is the last
layer, so a source-only rebuild is seconds -- and the local loop is
`docker build -t ...:local . && tests/mac-e2e.sh --image ...:local`. Worth
knowing before anyone wonders why editing `.claude-dev/template` on a
pulled folder changes nothing.

**Image size.** 3.66 GB, of which 1.11 GB is apt, 1.67 GB the toolchain,
113 MB the app.asar rewritten by the theme patch in its own layer, and
110 MB the Ubuntu base. The asar layer could be avoided by patching in
`phase_orca`, at the cost of the per-folder theme; it was left alone.

**Making the GHCR package public** is still Joe's call (§3). With it, no
token scope is ever needed and the runtime path is never taken.

## Appendix A -- Evidence collected 2026-09-07 (so nobody re-derives it)

Commands were run on Joe's Mac in `/Users/joerayment/Documents/claude_orca`.

- `docker ps -a`: `claude-orca-harness-test` (this template, port 6769),
  `claude-orca-claude-orca` (this template, port 6770), `claude-orca-claude-dev`
  and `stocks-claude-dev` (old template, image `claude-code-dev`, up 2 days).
- `docker exec claude-orca-claude-orca mount | grep -E 'Users|home/agent|usr/local|opt/'`:
  six bind mounts (`fakeowner` = Docker Desktop virtiofs) and one ext4 volume
  at `/home/agent/.config/orca`. `ls /Users/joerayment/Documents` inside ->
  only `claude_orca`.
- `docker exec -u agent -w /Users/joerayment/Documents/claude_orca ... bd status`
  -> 70 closed, 4 ready. Same from `zsh -ic`. `bd where` -> the project's
  `.beads`, prefix `claude-orca`, database `.beads/embeddeddolt`.
- `.claude-dev/run/setup.log` (this folder): every apt phase "already
  present", then bats/bd/dolt/claude/opencode/orca installed; mtimes give the
  timeline in section 1.3.
- `Harness test/.claude-dev/run/container.log`: 799 command lines from Apple
  `container build/run` days through `docker run`, plus 4,625 `docker inspect`
  polls; `setup.log` there shows three full apt reinstalls (runtime path) and
  the toolchain phases cached.
- Speed probe inside the container (300 small files / untar 219 MB, 3,600
  files / 200 MB sequential): bind mount 83 ms / 2,050 ms / 167 ms; docker
  volume 5 ms / 146 ms / 174 ms.
- Download probe of `dolt-linux-arm64.tar.gz`: 2.52 MB/s inside, 2.61 MB/s
  on the Mac.
- `gh auth status`: classic token, scopes `gist, read:org, read:packages,
  repo, workflow`. Anonymous GHCR manifest fetch -> 403 (package private).
- `gh run list --workflow image.yml`: last success 34067831053 (2026-09-06
  23:46); every run since fails only in `macos-docker-e2e`; latest reason
  from its diagnostics step: `install: cannot change ownership of
  '/usr/local/bin/dolt': Permission denied` then `[entrypoint] setup.sh failed`.
- `orca-serve.log` (this folder): dbus and keyring noise; `codex` ENOENT
  (no codex installed, harmless); one `EACCES mkdir /Users/joerayment/orca`
  while deleting a worktree the Mac Orca app had created outside the mount.
- Orca Web bundle: `navigator.clipboard.read` (2 uses), "Image paste failed"
  strings; the served page has no Permissions-Policy header.
- `git worktree list` on the Mac: only main.
- `~/.claude-orca`: 18 MB v2 leftover (`bin/`, `srt/`, `template/`,
  `shellrc.*`); no rc-file blocks reference it.

## Appendix B -- Commands cheat sheet

```bash
# the real end-to-end check (after step 0.3 exists)
tests/mac-e2e.sh                       # fresh folder, real pull, teardown
tests/mac-e2e.sh --image ghcr.io/joe-rayment/claude_orca:local
tests/mac-e2e.sh --keep                # leave it running to poke at

# build the image locally (step 0.4 / step 3)
docker build -t ghcr.io/joe-rayment/claude_orca:local .
docker run --rm ghcr.io/joe-rayment/claude_orca:local /opt/claude-orca/scripts/container/setup.sh --check

# a folder's health
./claude-dev --doctor
./claude-dev verify                    # after step 6
./claude-dev logs                      # container output
cat .claude-dev/run/setup.log          # toolchain install, with +Ns after step 0.2
grep -vE 'dbus|keyring|codex' .claude-dev/run/orca-serve.log | tail -20

# inside
./claude-dev shell                     # zsh -l in /workspace/<name> after step 4
docker exec -u agent -w / claude-orca-<name> bd status   # cwd-independent after step 5

# the suite (needs brew install bash)
./run-tests.sh
```
