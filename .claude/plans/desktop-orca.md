# Desktop Orca — the Mac's own Orca.app as the client, the container as the runtime

Plan written 2026-09-12. Replaces the browser tab (Orca Web, served from
the container) with the Orca desktop app the user already has installed,
attached to the same in-container runtime over Orca's own pairing
protocol. Nothing about the boundary moves: every agent, shell and tool
call still runs inside the folder's Docker container, which mounts
`/workspace/<name>` and the folder's home and nothing else. The desktop
app is a client of that runtime, the way the browser tab is today.

## 1. Verified facts this design rests on (read from Orca 1.4.197's app.asar, 2026-09-12)

- `orca serve` (and `orca-ide --serve`, the same code path in
  `out/main/index.js`) prints two lines once up: `Web client URL: <http…>`
  and `Pairing URL: orca://pair?code=<base64url json>`. The web URL's
  fragment carries the same pairing URL, percent-encoded
  (`#pairing=orca%3A%2F%2Fpair%3Fcode%3D…`) — so a launcher that already
  has `run/orca-web-url.txt` can derive the pairing URL from it without
  any change to the image.
- The pairing offer (`out/shared/mobile-relay-pairing-offer.js`) is
  `{v:2, endpoint: ws(s)://host:port, deviceToken, publicKeyB64, scope:
  'runtime'}`. **With no `--pairing-address`, the advertised hostname is
  `127.0.0.1`** (`Eea()` in `out/main/index.js`), which is exactly where
  `claude-dev` publishes the port. Runtime-scope offers carry no expiry
  (only mobile relay invites do). `--pairing-address` changes only the
  advertised address; the container needs no change here.
- Transport after pairing is a WebSocket with end-to-end encryption keyed
  on the offer's Curve25519 key (`remote-runtime-subscription-transport.js`).
  No SSH, no tunnel, no Node on the serving side. The `sshTunnelRequired`
  strings belong to the separate SSH-target feature, which this plan does
  not use.
- The desktop app reads its saved remote environments from
  `<user-data>/orca-environments.json` (`K4n` in `out/main/index.js`), the
  same file the CLI writes: `orca environment add --name <n> --pairing-code
  <orca://pair?…>`; `orca environment list|show|rm`; `orca host list`
  (`out/cli/specs/environment.js`). CLI commands accept `--environment
  <name>` to run against a paired server (`out/cli/execution-host-flag.js`).
- Version coupling is a **hard refusal**, not a warning:
  `evaluateRuntimeCompat()` (`out/shared/protocol-compat.js`) blocks with
  `client-too-old` / `server-too-old` on protocol-version mismatch. The
  protocol version moves less often than the app version, but the only
  guarantee is equal app versions on both sides.
- When attached to a remote runtime, agents run on the serving side
  (scout recon, no local-execution path found for a remote workspace).
  The desktop app also has **local** workspaces that run unsandboxed on
  the Mac; the browser cannot do that by construction, so this is the one
  new risk (§5).
- No `orca://` protocol handler is registered by the desktop app
  (`setAsDefaultProtocolClient` absent), so `open orca://pair?…` is not a
  path. The CLI is.

## 2. Three things only a Mac can answer (S0, before any code)

These decide the shape of S3 and are a ten-minute session with the
current image and the installed app. Record the answers in bead S0.

1. **Where the app's CLI is.** On Linux it is `resources/bin/orca-ide`;
   on the Mac, look under `/Applications/Orca.app/Contents/Resources/bin/`
   and at `command -v orca`. The launcher will probe both names.
2. **Whether the desktop re-reads `orca-environments.json` after the CLI
   writes it** while the app is running, or only at start. If only at
   start, S3 adds the environment BEFORE launching the app (or relaunches).
3. **Whether the desktop connects to a saved environment on its own or
   the user picks it** in the Runtime Environments pane. If it is a pick,
   the hand-off text names the pane; `orca repo list --environment <name>
   --json` from the Mac still proves the pairing works without the UI.

## 3. The flow (desktop)

`bootstrap.sh` (Mac): preflight gains one step beside docker/gh: find
Orca.app (`/Applications`, `~/Applications`, `CLAUDE_ORCA_APP` override).
Missing → print the download URL and stop, the same shape as the docker
check; `CLAUDE_ORCA_UI=web` skips the check and registers a web folder.
Linux hosts register web (there is no desktop app to find).

`claude-orca.json` gains `"ui": "desktop" | "web"` (default `desktop` when
the app was found at register, `web` otherwise). The Mac side reads it
through `jq` as validated data like every other key.

`./claude-dev` (open), with `ui = desktop`:

1. Container up and `run/orca-web-url.txt` published — unchanged.
2. Pairing URL: prefer `run/orca-pairing-url.txt` (S1 teaches the
   entrypoint to write it, 0600, for images that carry the change); else
   percent-decode the `#pairing=` fragment of the web URL (bash 3.2:
   `printf '%b' "${s//%/\\x}"`). Both paths, per the rule that a change
   must not ship only through the image.
3. Version gate: `defaults read <app>/Contents/Info.plist
   CFBundleShortVersionString` vs the image's `ORCA_VERSION`. Mismatch is
   a printed warning and a doctor row, not a refusal — Orca's own protocol
   check is the authority and will say so if it matters. S4 makes the
   mismatch rare by building the image at the app's version.
4. Launch: `open -a <app>`, then poll the app's CLI `orca status --json`
   for `.result.runtime.reachable == true` (≤ 60 s; note `status --json`
   always exits 0, parse the boolean).
5. Register: `orca environment add --name claude-orca-<project>
   --pairing-code "<url>" --json`. A name that already exists (re-open
   after a container recreate mints a fresh offer) is removed first and
   re-added. The returned id lands in `run/orca-environment.json` (a Mac
   result, so `run/`).
6. Hand-off block: the environment name, the pane to pick it in (per S0
   answer 3), `./claude-dev` to reopen, `./claude-dev shell`. If the CLI
   add failed, the pairing URL goes to the clipboard (`pbcopy`) and the
   block says to paste it into the pane — the manual fallback that always
   works.

`--doctor`: three new rows — `orca app` (path, version), `orca cli`
(reachable or not), `environment` (registered id or missing). `verify`
gains one row on the boundary: the Mac's own Orca does not track this
folder as a LOCAL repo (`orca repo list --host local --json` has no entry
under the project path) — the guard for §5.

`stop`: unchanged (the app shows the environment disconnected).
`--teardown`: `orca environment rm --environment claude-orca-<project>`
before the container goes. `--how-to-run`: prints the desktop block.

With `ui = web` every step above is skipped and today's `open <url>`
runs — the browser path stays whole as the fallback.

## 4. Version coupling (S4)

The image pins `ORCA_VERSION=1.4.197` (`Dockerfile:30`,
`scripts/container/setup.sh:26`). The desktop app auto-updates. So at
register and `--update`, `try_build` passes `--build-arg
ORCA_VERSION=<installed app version>` and `image_tag` folds that version
in, so a folder's image is always built at the version its client runs.
The `.deb` for that version must exist on Orca's releases page — the
same source the image uses today; a missing asset fails the build the
way any build failure does (runtime path), and the doctor row says which
version was asked for.

## 5. The one new risk, and its guard

The desktop app can open local workspaces that run agents on the Mac
with no sandbox. The browser tab cannot. The launcher only ever hands
the app a remote environment, never a local path; the `verify` row in §3
reads the app's own local repo list back and fails if this folder is in
it. That is a detection, not a prevention — there is no knob in 1.4.197
to disable local workspaces — and the README says so in one sentence.

## 6. Verification, honestly

| Claim | Where it is proven |
|---|---|
| entrypoint writes `run/orca-pairing-url.txt` 0600 from the `Pairing URL:` line | bats, natively (`tests/container-entrypoint.bats`) |
| launcher derives the pairing URL from the web URL's fragment; bash 3.2 clean | bats + `scripts/lint-bash32.sh` |
| bootstrap finds/misses the app; `ui` key written; Linux → web | bats with stubbed `open`, `defaults`, a fake `.app` dir |
| open: launch, wait, `environment add`, conflict re-add, clipboard fallback; teardown `rm` | bats with an `orca` stub logging argv |
| `--build-arg ORCA_VERSION` from the app; tag folds it in | bats (`tests/launcher-v3-build.bats`) |
| **the desktop actually attaches, agents run in the container** | `tests/mac-e2e.sh` on a Mac: rows for app found, versions equal, `environment add` ok, `orca repo list --environment <name> --json` lists the project, `orca repo list --host local` does not; plus a screenshot of the app showing the project. Table pasted into the closing bead. |

A green bats suite proves the launcher's logic and nothing about the
Mac; S5 is the only evidence for the last row, and the whole plan is
UNVERIFIED until it runs.

## 7. Slices (a bead each, with CHECK/PASS-IF/FROZEN/CLASS)

- **S0 — Mac probe** (manual, first): answers to §2, plus one
  `environment add` against the current image, pasted into the bead.
- **S1 — pairing URL on both paths**: entrypoint writes
  `run/orca-pairing-url.txt`; launcher `pairing_url_of()` prefers it and
  falls back to decoding the fragment. Container half and Mac half; no
  behaviour change yet.
- **S2 — app discovery + `ui` key**: bootstrap preflight, `find_orca_app`,
  `orca_cli`, `orca_app_version`, the `ui` default at register, doctor
  rows. No hand-off yet.
- **S3 — the desktop hand-off**: `cmd_open_v3` desktop branch (launch,
  wait, add, print), teardown `rm`, `--how-to-run`, the `verify` local-repo
  row, clipboard fallback. Shaped by S0's answers.
- **S4 — version coupling**: build arg from the app, tag, doctor row.
- **S5 — Mac e2e + docs**: `tests/mac-e2e.sh` desktop rows, README and
  CLAUDE.md architecture paragraph, run on the Mac, table in the bead.

S1 (container side) and S2 run in parallel in separate worktrees; S3 and
S4 follow S2 sequentially (all in `scripts/launcher.sh`); S5 last.
