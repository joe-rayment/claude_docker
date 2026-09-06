# Plan — claude_orca v3: Linux Orca inside an Apple container, the VM is the sandbox

Filed 2026-09-06. Supersedes the Seatbelt design in `orca-port.md` §9 (v2). The user's
original plan, restated by them today: **use Apple's native containers and run the Linux
version of Orca.** v2's "Seatbelt confirmed" line (§9.4) was not their decision.

## 1. Goal

One command, run inside a project folder on a Mac, ends with Orca open in the browser and
every agent it launches running inside a Linux VM that can see **the project folder and
nothing else** on the Mac. Claude Code signs in on its own first run inside Orca. No walk-through,
no separate login, no Seatbelt, no shell-rc hook, no `srt`.

## 2. Verified facts this design rests on (all checked 2026-09-06, this container)

- **Orca 1.4.197 Linux (AppImage) runs headless with no display** in serve mode:
  `orca-ide --serve --port N --project-root <dir>` prints `Orca server ready`, serves
  `Orca Web` at `http://127.0.0.1:N/`, and prints a **Web client URL** with the pairing offer
  in the fragment (`web-index.html#pairing=orca%3A%2F%2Fpair%3Fcode%3D…`). Opening that URL in
  a browser auto-pairs and renders the full Orca UI (screenshot `orca-web-paired.png`).
  `--no-pairing` leaves the client unpaired (a "paste a pairing URL" form) — never use it.
- Electron honours `--user-data-dir` natively (SingletonLock, `orca-runtime.json`, the unix
  socket all land there). On Linux Electron also follows `XDG_CONFIG_HOME`/`HOME`, so the
  in-folder home works without tricks.
- Orca's Mac desktop app can also attach to an **SSH remote runtime** (Node 18+ on the host);
  kept as an alternative UI in §8, not the primary path.
- **Apple `container`** (github.com/apple/container): macOS 26 + Apple silicon only; installed
  from the signed `.pkg` on the releases page into `/usr/local/bin`; `container system start`
  boots the service. One lightweight Linux VM per container. Flags verified from the command
  reference: `run -d --name … --volume host:guest[:ro] --publish 127.0.0.1:HP:CP -e K=V
  --user … --workdir … --rm --cpus --memory --ssh`, `exec -it`, `build -t -f`, `image pull`,
  `stop`, `rm`, `ls`, `logs -f`. Published ports are reached on the Mac at `127.0.0.1:HP`;
  the host can also reach the container IP directly (`container inspect`). Docker Hub / OCI
  registries work (`docker.io/...`, and GHCR).
- **This box cannot run containers** (no mount namespaces: `unshare -m` is EPERM). The image is
  therefore built and smoke-tested with real Docker in **GitHub Actions** (Actions is enabled on
  the repo), and everything *inside* the image is exercised natively here — this container is
  Ubuntu arm64, the same base.
- The old Docker template (`attachments/claude_docker/`) is the reference for the in-container
  half: entrypoint config-sync, auth-guard, pinned Claude native install, beads/dolt, bats.

## 3. Architecture

```
Mac (host)                                   │ Linux VM (one per project)
─────────────────────────────────────────────┼──────────────────────────────────────────────
<project>/                                   │ <project>/            (same absolute path,
  .claude-dev/                               │                        bind mount, rw)
    template/   (this repo, cloned)          │ /home/agent  ⇐ <project>/.claude-dev/home
    home/       (agent HOME, persisted)      │   .claude/   (config-synced hooks, creds)
    run/        (web url, logs, port)        │   .config/orca (Orca data, --user-data-dir)
    bin/claude-dev                           │ /opt/claude-orca  (template copy in image)
  ./claude-dev  (stub)                       │ /opt/orca         (Orca Linux, orca-ide + cli)
  Orca.app      (optional launcher bundle)   │ entrypoint: config-sync → seed Orca settings
                                             │   → orca-ide --serve --port P (as agent)
container run -d --name claude-orca-<name>   │   → orca repo add <project>
  -v <project>:<project>                     │   → write run/orca-web-url.txt
  -v <project>/.claude-dev/home:/home/agent  │
  -p 127.0.0.1:P:P  -e GH_TOKEN -e HOST_UID  │ Browser on the Mac ⇐ http://127.0.0.1:P/…#pairing=
```

- **Isolation**: the VM boundary. The only Mac paths inside are the project folder and its own
  `.claude-dev/home`. Worst case "delete everything" empties the project folder. Network egress
  is open (the old opt-in iptables firewall is a later, optional slice).
- **Same absolute path** for the project inside the VM, so paths Orca stores (worktrees, repos)
  and paths agents print match the Mac. Home is folder-local on purpose: credentials and Orca
  state live and die with the folder; teardown is `rm -rf .claude-dev`.
- **Worktrees**: Orca's default sibling location is outside the mount, so the entrypoint seeds
  Orca's global settings with worktree base `<project>/.orca-worktrees` (and the dark theme)
  when the settings file is absent — no manual Orca setting.
- **Port**: per project, chosen once at register (`6768` if free, else the next free), stored in
  `.claude-dev/run/port`; the same number on both sides so the advertised `ws://127.0.0.1:P`
  in the pairing code is reachable from the Mac browser.
- **Users/uids**: the image user `agent` (uid 1000). The entrypoint starts as root, re-maps
  `agent` to `HOST_UID` when given (Apple's virtiofs share exposes host uids), then drops to it.
  *Mac-check*: file ownership seen from the Mac after an agent writes into the folder.
- **Auth**: Claude Code logs in on first run inside an Orca terminal (prints a URL; paste the
  code). `GH_TOKEN` from the Mac's `gh auth token` is passed as env. Git identity is seeded into
  the home `.gitconfig` from the Mac's global config at register.

## 4. Image (`ghcr.io/joe-rayment/claude_orca`)

Ubuntu 24.04 (arm64 for Macs, amd64 for CI's own run), Node 22, pinned Claude Code native
install (autoupdate off), Orca Linux 1.4.197 extracted from the release AppImage to `/opt/orca`
(no FUSE needed), zsh, git, gh, jq, ripgrep, bats-core, beads (`bd`) + dolt, python3, tini,
`setpriv`, the Electron runtime libs (libgtk-3, libnss3, libasound2, libgbm1, libxss1, libnotify4,
libsecret-1). This template lives at `/opt/claude-orca`; `config/` is synced into
`$HOME/.claude` by the same checksum-gated config-sync as today. Entry: `/opt/claude-orca/scripts/
container/entrypoint.sh` under tini. Built and pushed by `.github/workflows/image.yml` on every
push to main (tag = short SHA + `latest`), with a smoke stage that starts the entrypoint in the
built image and asserts `Orca server ready` plus the web-url file. Bootstrap pulls the image
after `container registry login ghcr.io` with the `gh` token; if the pull fails it falls back to
`container build` from the template clone.

## 5. Mac side (`bootstrap.sh`, `claude-dev`)

Preflight (nothing written before it passes): Apple silicon + macOS 26; `container` on PATH
(else print the releases URL and the `installer` line — a `.pkg` needs an admin password, so it
is instructed, not run); `container system start` (idempotent); `gh` authenticated; git. Then
clone the template into `.claude-dev/template`, link `bin/`, and `register`: seed `sandbox.json`
→ becomes `claude-orca.json` (port, cpus, memory, extra mounts ro), seed home + gitconfig, pull
the image, run the container, wait for `run/orca-web-url.txt`, `open` it in the default browser.
Prints one three-line "how to run it". `./claude-dev` with no args = open (start if stopped,
create if missing); `stop`; `shell` (`container exec -it … zsh`); `logs`; `--doctor`
(container CLI, service, image, container state, port, web url); `--update` (pull template +
image, recreate container); `--teardown` (stop, rm, snapshot beads, remove `.claude-dev`).
No shell-rc hook: nothing runs agents on the Mac. Old v2 rc blocks are removed by `--update`.

## 6. What gets deleted

`scripts/sandbox/*` (orca-launch, gen-orca-profile, gen-settings, selftest, claude-orca-shell,
shellrc.*, host-owned-paths, make-launcher-app — the launcher bundle returns later as a thin
"open the browser" bundle if wanted), `install-srt.sh`, `install-orca.sh` (DMG), the 17-probe
self-test and its doctor sections, `setup-menu.sh`'s gh/OpenRouter steps stay (they are
in-container concerns now — run from `claude-dev shell`), and every test that pins them.
`ORCA_INTEGRATION.md`/`SANDBOX.md` are rewritten for the VM model.

## 7. Verification, honestly

| Surface | Where it is proven |
|---|---|
| Orca serve + web UI + pairing, entrypoint, config-sync, hooks, Claude/bd inside | **Here, natively** (bats + Playwright screenshots) |
| The image builds, starts, and Orca comes up inside it | **GitHub Actions**, real Docker, both arches |
| `container` CLI invocation, virtiofs uid behaviour, `open` of the URL | **Only the Mac** — bootstrap prints the exact command it ran and `--doctor` shows every step |

## 8. Alternatives kept in view

- Mac desktop Orca attached to the VM over SSH (`sshd` in the image, `container --ssh`): native
  feel, but the unsandboxed desktop Orca sees the whole Mac. Offer later as `claude-orca.json`
  `ui: "desktop-ssh"`.
- Named volume for home instead of the folder: faster I/O, less transparent. Not now.
- Egress allowlist inside the VM (the old iptables script): optional later slice.

## 9. Slices (sequential; each a bead with CHECK/PASS-IF/FROZEN/CLASS)

1. **Image + entrypoint + CI** — Dockerfile, `scripts/container/entrypoint.sh`, smoke script,
   `image.yml`. CHECK here: `bats tests/container-entrypoint.bats` runs the entrypoint natively
   against the extracted AppImage and a temp home; CI-CHECK: the workflow run is green.
2. **Mac launcher + bootstrap** — `container` stubbed in tests; register/open/stop/shell/doctor/
   update/teardown; port allocation; web-url wait; README quick start.
3. **Delete v2** — Seatbelt/srt/self-test code, tests, docs; doctor rewritten; suite green.
4. **In-Orca polish** — worktree base + theme seed, `repo add`, orchestration mode inside the
   VM, Playwright walk-through: open project, open a terminal, run `claude --version`, screenshot.
