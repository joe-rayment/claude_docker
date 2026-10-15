# Ghostty instead of Orca

Status: PROPOSED, 2026-10-15. Nothing is implemented yet. Epic
claude-orca-9bh, one child bead per slice in the order listed under "Slices"
(A1 = 9bh.1 … A5 = .5, B1 = .6 … B5 = .10, C1 = .11 … C4 = .14). The
dependencies are wired in beads, so `bd ready` names what can start.

## The shape, in six lines

1. **Ghostty on the Mac is the whole UI.** Each project pane is an `ssh`
   session into that folder's container: sshd runs there as the agent user,
   accepts only the folder's own key, and listens on the one loopback port
   Orca used to have.
2. **Any pane opened inside a sandboxed folder opens in its container.** That
   covers cmd+d, the right-click Split menu, new tabs, and windows Ghostty
   restores. One Ghostty `command` routes each new pane by its working
   directory. The container reports its directory back to Ghostty as the
   matching Mac path (OSC 7), so splits inherit it.
3. **Images.** ctrl+v pastes the Mac clipboard into Claude Code: screenshots,
   copied images, and image files copied in Finder. A container-side `xclip`
   reads the clipboard through a socket that ssh forwards for the session.
   Dragging in a file from inside the project works natively.
4. **Soft returns work natively.** Claude Code negotiates the kitty keyboard
   protocol with Ghostty end to end over ssh.
5. **Workers are plain detached processes** (`opencode run`, `claude -p`)
   with a slot cap (default 3). Results arrive through the same inbox file as
   today. Claude-model workers default to in-process subagents.
6. **Orca is removed entirely.** That takes about 0.7 GB off the image and
   about 740 MB of RAM off every running folder, and the desktop app goes away.

## What was measured, not argued

All of these ran in this container (Ubuntu 24.04 arm64). Every item is real
software, not an inference:

| Question | How | Result |
|---|---|---|
| Can Claude Code in the container paste an image without a display? | Ran Claude Code 2.1.300 for real in a pty. A stub `xclip` was first on PATH, with no `DISPLAY`. Sent ctrl+v. | It calls `xclip -selection clipboard -t TARGETS -o`, then `-t image/png -o`, and shows `[Image #1]`. Linux Claude Code reads the clipboard *only* through `xclip`/`wl-paste`, so a shim is all it needs. |
| Does a pasted path attach an image? | Sent a bracketed paste of a PNG path that exists in the container. | `[Image #1]`, with no clipboard call. An empty paste does nothing. |
| Can sshd run unprivileged here? | OpenSSH 9.6p1 (24.04's own) extracted without root. Ran as `agent` with `StrictModes no`, `UsePAM no`, key-only. | Works. The first login takes 143 ms. Later panes take **3 ms** through ControlMaster. `SetEnv TERM_PROGRAM=ghostty` arrives. |
| Does closing a pane kill what ran in it? | Started `ssh -tt … sleep 777` through the ControlMaster. Then (a) closed the pty, which is what Ghostty does when a split closes, and (b) sent SIGKILL to the client. | The remote process was gone both times. No orphans. |
| Does shift+enter survive ssh? | Ran real Claude Code over ssh. The pty driver answered `CSI ? u` and XTVERSION the way Ghostty does, then sent `CSI 13;2u`. | Claude Code probed both, pushed the kitty keyboard mode, and the input box went to two lines without submitting. |
| Does the full image path work across ssh? | ssh `RemoteForward /tmp/cdev-clip.sock → <Mac-side socket>`. A fixture server stood in for the Mac. The container shim used `curl --unix-socket`. Claude Code ran over ssh. | ctrl+v gave `[Image #1]`. The forwarded socket is `srw-------` inside the container. |
| Can the Mac-side listener use only stock tools? | `nc -lU` with a FIFO per connection, under bash. Tested with OpenBSD netcat, the lineage macOS `nc` comes from. | 20 of 20 back-to-back TARGETS-then-PNG request pairs. |
| What does Orca cost per running folder? | `ps` RSS of the orca-ide processes plus Xvfb in this container. | ~740 MB resident: main 278, daemon 116, session scanner 111, network 79, two zygotes 110, GPU 47, Xvfb 16. `/opt/Orca` is 671 MB on disk before its apt dependencies. |
| Do tmux, screen or zellij cost anything? | Read Claude Code 2.1.300's terminal code. | It turns off synchronized output under `TMUX` or `ZELLIJ`, and one extended-key path under `TMUX` or `STY`. That rules out a multiplexer. |

The following are confirmed in Ghostty's source (main, 1.3.x) and nowhere else yet:

- A new split inherits only font size and working directory, never the command
  (`newSurfaceOptions`, `src/apprt/embedded.zig`). That is why routing has to
  be a global `command`.
- `command` "will be used for all new terminal surfaces". On macOS Ghostty wraps
  it as `login -flp <user> /bin/bash --noprofile --norc -c "exec -l <command>"`
  (`src/termio/Exec.zig`), so a custom command is still a real login session.
- OSC 7 is accepted only when the host is `localhost` or the Mac's own hostname
  (`reportPwd`, `src/os/hostname.zig`). The container therefore reports
  `file://localhost/<mac path>`.
- An explicit `shell-integration = zsh` forces zsh injection (ZDOTDIR) whatever
  the command is (`shell_integration.zig: setup(force_shell)`). Mac panes keep
  Ghostty's integration even though the command is a router.
- cmd+d, cmd+shift+d, the right-click Split menu, cmd+opt+arrows and zoom are
  all Ghostty defaults. None of them needs any config from us.

## Architecture

### Mac side (bash 3.2, stock macOS tools only)

| Piece | Where | What it does |
|---|---|---|
| `config/ghostty/claude-dev.ghostty` | shipped in the template, installed to `~/.config/ghostty/claude-dev.ghostty` | The only Ghostty config we add (full text below). Your config gets one line, `config-file = ?claude-dev.ghostty`. The `?` means Ghostty is stock again if the file goes away. |
| `ghostty-pane` (router) | `~/.local/share/claude-dev/ghostty-pane`, a copy, never a symlink into a project | Ghostty's `command`. It walks up from `$PWD`. At the first folder holding `.claude-dev/claude-orca.json` it runs `exec <folder>/claude-dev pane`; with no such folder it runs `exec -l $SHELL`, which is your normal Mac shell. About 10 `stat` calls and nothing else. |
| `claude-dev pane` | `scripts/launcher.sh` | **Fast path:** `ssh -O check` finds a live master, so it runs `exec ssh -tt` with `CDEV_CWD=<path relative to the project>`. **Slow path:** start Docker and the container as `./claude-dev` does today, wait for `run/sshd.ready`, make sure the keys and the clipboard listener exist, push terminfo once, then exec ssh. **On failure** it prints the reason, then a banner "Mac shell — NOT sandboxed", then a Mac shell. |
| `claude-dev ghostty [--uninstall]` | `scripts/launcher.sh` | Idempotent and version-stamped. Writes the include file and the router, adds the one include line, and writes `shell-integration =` from `$SHELL`. `bootstrap.sh` runs it once on a new machine, after `brew install --cask ghostty` when Ghostty is missing. Every later `./claude-dev` refreshes the router when the template's copy is newer. |
| ssh identity | `.claude-dev/state/ssh/` (the folder's authority, gitignored) | The Mac generates both keypairs with `ssh-keygen`: the client key and the container's host key. `known_hosts` is written from the host key directly, so nothing is trust-on-first-use. Also holds a generated `config` with `ControlMaster auto`, `ControlPersist 30m`, `ControlPath ~/.local/state/claude-dev/cm-%C` (short, because the macOS socket path limit is 104), `SetEnv TERM_PROGRAM=ghostty TERM_PROGRAM_VERSION COLORTERM`, and the `RemoteForward` for the clipboard. Nothing goes into `~/.ssh`. |
| clipboard listener | `scripts/mac/clip-listen` and `clip-serve`; socket at `~/.local/state/claude-dev/clip-<name>.sock`, mode 600 | `nc -lU` loop, one FIFO per connection, the shape prototyped above. `clip-serve` answers four requests (see "Images" below). Started by `claude-dev pane` and exits with the folder's ssh master (watchdog: `ssh -O check` once a minute). It is spawned from Ghostty's process tree, so the clipboard is read the way native Claude Code reads it, by `osascript` under Ghostty. That matters if macOS asks about pasteboard access: the prompt names Ghostty, not a nameless background agent. |

`./claude-dev` with no arguments now runs the slow path and then `exec ssh` *in
the current terminal*: the pane you typed it in becomes the sandbox. Outside
Ghostty it works the same, and prints one line about `claude-dev ghostty`.

#### The Ghostty include, in full (draft)

```ini
# Installed by `claude-dev ghostty`. Your config includes it with
#   config-file = ?claude-dev.ghostty
# Delete that line (or `claude-dev ghostty --uninstall`) and Ghostty is stock.

# Every new pane, split, tab and window starts here: inside a sandboxed folder
# it opens that folder's container, anywhere else your normal login shell. If
# the router has gone missing, the shell starts directly -- never an error.
command = /bin/sh -c 'r="$HOME/.local/share/claude-dev/ghostty-pane"; [ -x "$r" ] && exec "$r"; exec "${SHELL:-/bin/zsh}" -l'

# `command` is no longer a shell, so Ghostty cannot detect one; naming it keeps
# Ghostty's shell integration in Mac panes. (Written from $SHELL at install.)
shell-integration = zsh

# Splits and tabs stay where you are -- in a sandbox pane, that is the sandbox.
# A NEW WINDOW (cmd+n) starts in your home folder: a Mac shell. That is the
# one-keystroke way out.
window-inherit-working-directory = false
```

Splitting needs no keybinds of ours, because Ghostty's defaults already are
cmd+d (right), cmd+shift+d (down), the right-click menu, cmd+opt+arrows, and
cmd+shift+enter (zoom).

### Container side

| Piece | What |
|---|---|
| sshd | `openssh-server` is added to the image's base packages. PID 1 (`entrypoint.sh`) writes `/run/cdev/sshd_config` (container-local, agent-owned, 600) and copies the host key from `state/ssh/` to `/run/cdev/ssh/`. It starts `sshd -D` as `agent` under a restart loop, so a crashed sshd never takes the workers with it, then writes `run/sshd.ready`. Config: key-only, `AllowUsers agent`, `AuthorizedKeysFile <project>/.claude-dev/state/ssh/authorized_keys` (the Mac decides who may log in), `AcceptEnv TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM CDEV_CWD LANG LC_*`, `AllowStreamLocalForwarding remote`, `StreamLocalBindUnlink yes`, no TCP/X11/agent forwarding, `ForceCommand pane-entry`. |
| env snapshot | Orca used to inherit the entrypoint's environment, including the OpenRouter guard token. sshd sessions start clean. PID 1 therefore writes `/run/cdev/env` (600, never on the Mac share) after the guard is up. `pane-entry` sources it. |
| `pane-entry` | `scripts/container/pane-entry`. Sources the env snapshot. Turns `CDEV_CWD` into a path under `/workspace/<name>`, refusing anything outside it. Falls back to `TERM=xterm-256color` when `$TERM` has no terminfo. Then runs `zsh -l`, or `$SSH_ORIGINAL_COMMAND` under it. |
| OSC 7 and title | Two small `precmd` hooks in the shipped `.zshrc`. One reports `file://localhost<CLAUDE_ORCA_HOST_PROJECT_DIR><rel>`, URL-encoded, so a split lands in the same subfolder. The other sets the tab title to `<name> ▸ <rel>`. The green phosphor foreground (`terminalTheme`, OSC 10/12) already works in Ghostty, which keeps sandbox panes visibly different from Mac panes. |
| terminfo | `./claude-dev pane` pipes `infocmp -x xterm-ghostty \| ssh … tic -x -o ~/.terminfo -` once, with a stamp in `run/`. This is Ghostty's own `ssh-terminfo` trick, done once per folder, and it matches your Ghostty's version. |
| `xclip` shim | `bin/xclip`, ahead of `/usr/bin` on PATH. **Reads images only.** `-t TARGETS -o` and `-t image/png -o` go to the forwarded socket via `curl --unix-socket`, with a 3-try retry, because between connections the Mac listener re-arms. Text reads always exit 1, so nothing in the container can read text off your Mac clipboard, passwords included. `-i` (copy) goes to `pbcopy`, the same thing OSC 52 already allows. With no socket, it exits 1 and Claude Code says there is no image. |
| Mac-path symlink | Created by PID 1: `$CLAUDE_ORCA_HOST_PROJECT_DIR → /workspace/<name>`. It makes Mac paths that point *into the project* resolve inside the container. That covers dragging a project file onto a pane (proven: an existing path attaches), Finder "Copy as Pathname", and paths in Mac error messages. It reveals nothing new: the container already receives that path as an env var. `pwd` stays `/workspace/<name>`. |

### What happens on cmd+d (sequence)

1. You press cmd+d in a sandbox pane. Ghostty creates a split, and it inherits
   the pane's pwd, which is a Mac path because of the container's OSC 7.
2. Ghostty runs `command` in that directory, wrapped in `login`.
3. The router walks up, finds the project, and runs `exec claude-dev pane`.
4. `ssh -O check` finds the master, so it runs
   `exec ssh -tt -o SetEnv=CDEV_CWD=<rel> claude-dev-<name>`. That takes
   ~3 ms on the multiplexed master.
5. In the container, `pane-entry` sources the env, cds to `<rel>` and runs
   `zsh -l`. The prompt appears in green with the project in the title.

Closing the split closes the pty, ssh ends that channel, and sshd sends SIGHUP
to everything in it (proven above).

### Images

| You do | What happens |
|---|---|
| Screenshot to the clipboard (cmd+ctrl+shift+4), or copy an image in a browser, then **ctrl+v** in Claude Code | Claude Code calls `xclip … TARGETS`. The shim asks for `GET /targets`, and `clip-serve` checks the clipboard with `osascript -e 'the clipboard as «class PNGf»'`. Claude Code then calls `xclip … image/png`. The shim asks for `GET /png`, and the PNG is written with the same `open for access … write png_data` AppleScript native Claude Code uses. The result is `[Image #1]`. |
| Copy an image *file* in Finder (cmd+c), then ctrl+v | `clip-serve` sees `«class furl»`, which gives a path. If it is png/jpeg/gif/webp, it serves the bytes. Anything else (HEIC, TIFF) goes through `sips -s format png` first. |
| Drag a file **from inside the project** onto a pane | Ghostty pastes its Mac path. The symlink resolves it, and Claude Code attaches it natively. |
| Drag a file from **outside** the project | Phase B5 (optional): a `UserPromptSubmit` hook sees an unreadable `/Users/…\.(png|jpe?g|gif|webp)` in the prompt. It asks the bridge for `GET /drag?path=…`. The bridge serves the file *only if* it is the file on macOS's drag pasteboard, which means you just dragged it. The hook saves it to `run/inbox/` and tells the model to Read it there. Until then, the one-line way is Finder cmd+c, then ctrl+v. |
| **cmd+v** with an image | Phase B5 (optional): `keybind = performable:cmd+v=paste_from_clipboard` passes cmd+v through when the clipboard holds no text, and Claude Code's `chat:imagePaste` is bound to `cmd+v` in its keybindings. ctrl+v is the baseline that works from day one. It is also the key native Claude Code uses on a Mac. |

The bridge's boundary: it exists only while the folder's ssh master is alive,
and only inside that folder's container (a unix socket forwarded by ssh, with
no network port and no token to leak). It serves images, never text. One risk
is accepted: any process in that container could read an *image* off your
clipboard while a pane is open. `"clipboard": false` in `claude-orca.json` turns
the bridge off for a folder.

### Workers and /tier, without Orca

Orca provided five things here: Run/Task records, worker terminals,
`worker-start` for Claude TUIs, a mailbox (send, check, ack), and a ready-list
over a task DAG. All five have file- and process-shaped replacements:

| Was | Becomes |
|---|---|
| `orca-dispatch <bead>` | `dispatch <bead>`. It composes the same spec (`orch_spec`, kept), cuts a worktree `~/worktrees/<bead>` on the existing `worktrees` volume (branch `work/<bead>`) or uses `--worktree main`, installs the frozen hook, writes a job dir `run/workers/<job>/`, and starts `worker-run <job>` detached (`setsid nohup`). It returns the receipt JSON immediately. |
| Orca terminal plus `orca-worker-run` | `worker-run <job>`: acquire a slot, then run `opencode run -m … --variant … --format json` or `claude -p --model … --effort … --output-format stream-json --permission-mode bypassPermissions` in the worktree under `nice -n 10`. It writes the log and receipt, appends the bead note, and **appends one line to `run/orchestration/inbox.jsonl` under `flock`**. That line replaces Orca's mailbox and the whole `--spool` process. |
| Orca's mailbox `orchestration ask` / `orca-reply` | A headless worker that is blocked ends its run with `QUESTION:` (WORKER RULES text), and the inbox line gets `type: question`. `workers reply <job> "<answer>"` resumes *the same session* in the same worktree: `claude -p --resume <sid>` or `opencode run -s <sid>`. A reply is one more headless turn. |
| `orca-wait`, `orca-workers` | `workers wait [--until …]`, which reads the inbox from a cursor. Today's bare-read path already makes no Orca call. `workers` lists queued and running jobs (pid, model, elapsed, tokens, last event). `workers tail <job>` gives a readable live view, for watching a worker in a Ghostty split. `workers stop <job>`. |
| `orca-run --epic` with Orca's Task DAG | `dispatch --epic <id>`. Readiness comes from beads' own blockers, which `orca-run` already intersects today (`bd show` per blocker). The same path-token serialisation is kept. Parallelism is the slot cap. |
| Orca reachability probe in `/tier` | Gone. `backend` is `subagent` or `headless`, and an old `orca` value is migrated on read: claude becomes `subagent`, opencode becomes `headless`. A positional Claude model (`/tier opus sonnet haiku`) binds `subagent`, which is in-process, needs no extra process, and is the cheapest. `claude:sonnet` explicitly asks for a headless `claude -p` worker. Routes, `openrouter` and `openai` are always `headless`. `recon` runs when recon is `headless:opencode`, exactly as today minus the label. |
| `tier auth` opening an Orca tab | Prints the one command to run in a new split (cmd+d). The sign-in is the user's own credential step either way. (Optional later: B5's bridge could open that split itself, through Ghostty's AppleScript `split … with configuration`.) |
| Orca's status dots and sub-agent rows | The status line gains `workers 2/3 · 1 queued`. Claude Code's own Ghostty notifications (OSC 777, picked automatically when `TERM_PROGRAM=ghostty`) report a finished turn. Ghostty's tab progress bar (OSC 9;4) works when `TERM_PROGRAM_VERSION` ≥ 1.2, and ssh forwards it. |
| `orca worktree rm` in `worktree-gc` | Plain `git worktree remove`. The "idle Orca terminal" exemption is deleted. |

`delegate run --route` already runs headless without Orca. After the cutover it
and `dispatch` should share `worker-run` (slice A5), so one code path owns
worktrees, receipts, inbox lines and bead notes.

### Overhead budget: the "too many agents" problem

| Cost | Today | After |
|---|---|---|
| Per running folder, idle | Orca stack ~740 MB RSS + Xvfb, plus the Orca desktop app on the Mac | sshd ~5 MB + guard ~21 MB |
| Claude worker | a full Orca-hosted TUI each (a Claude TUI here is ~380 MB RSS, 8% of a core rendering while it waits) | in-process subagent by default; headless `claude -p` (no render loop) only when bound |
| opencode worker | headless, ~700 MB peak, exits when done | same |
| Concurrency | uncapped (a deliberate 2026-09-21 decision) | **slot cap, default 3 per folder** (`maxWorkers` in `claude-orca.json`). Extra dispatches queue. Workers run at `nice 10`, so your own panes stay responsive. The CPU cap (half the cores) and memory cap stay. |
| Image | Orca 671 MB on disk + GTK/Xvfb/at-spi deps, built at the app's version | Orca phases and deps gone, +openssh-server (~2 MB). Rebuilding no longer tracks an app version. |

## Day to day, after

| Want | Do |
|---|---|
| Open a folder's sandbox | `cd` into it in any Ghostty pane and run `./claude-dev`, or open a tab or split in a pane already there |
| Another pane in the same sandbox | cmd+d, cmd+shift+d, right-click → Split, or cmd+t |
| A Mac shell | cmd+n (new windows start at home) |
| Paste a screenshot | ctrl+v in Claude Code |
| Watch a worker | cmd+d, then `workers tail <bead>` |
| Stop, update, teardown | unchanged: `./claude-dev stop | --update | --teardown`, from a Mac shell |

## What you lose, and what replaces it

| Orca had | After |
|---|---|
| Sessions survive closing the UI | The orchestrator's pane closing ends that Claude session, as in native Ghostty, and `claude -c` resumes it. **Workers are detached and survive.** The container keeps running until `./claude-dev stop`. |
| Workspace sidebar and status dots | Ghostty tabs titled `<name> ▸ <rel>`, native notifications, the `workers` status line segment |
| Session history browser | `claude --resume` |
| Worktree UI | `git worktree list`, `workers`, `worktree-gc` |
| Embedded browser and computer-use | none (`take-screenshot` stays) |
| Orca Web from any browser | none: the UI is the Mac's Ghostty |

## Options considered and rejected

| Option | Why not |
|---|---|
| `docker exec -it` instead of ssh | No socket forwarding, so the clipboard would need a network port reachable by every container on the Mac, plus a token. What happens to the exec'd process when the client dies is not documented, and moby has reports of exec sessions outliving their client; ssh's behaviour is proven above. Panes would need the env snapshot anyway. |
| A separate Ghostty instance per folder (`open -na Ghostty --args --config-file=…`) | Removes the global `command`, but instances share the bundle's saved window state and preferences, global keybinds register twice, there are several Dock icons, and AppleScript cannot tell instances apart. |
| tmux, zellij or screen inside the container | Claude Code degrades under them (above), and they would replace Ghostty's own splits, scrollback and search: the reason for switching. |
| `dtach`/`abduco` for persistent sessions | Reattaching a new Ghostty surface loses the kitty-keyboard mode Claude Code pushed, so shift+enter would break until a restart. `claude -c` is enough. |
| launchd socket-activated clipboard service | Neat and resident-free, but it installs a LaunchAgent, and it reads the pasteboard from a process with no app attribution. Apple's pasteboard-privacy work (programmatic reads raise an alert naming the reading app; announced for macOS 16/26, enforcement not confirmed here) would make that read a nameless agent's. The `nc` listener reads from inside Ghostty's process tree instead. launchd stays the fallback if the `nc` loop ever proves flaky. |
| Mount `~/Desktop` / `~/Downloads` read-only for drag-and-drop | Puts your personal folders inside the sandbox. B5's drag-pasteboard gate serves only the file you just dragged. |
| Keep Orca as an option (`ui: orca`) | Doubles the launcher, entrypoint and test surface for a path you are leaving. Git history keeps it. |

## Decisions taken here (each is cheap to reverse before its slice lands)

1. **ssh, not `docker exec`**, for panes.
2. **One Ghostty, routed by a global `command`**, installed as a single
   optional include, not a per-folder Ghostty instance.
3. **`window-inherit-working-directory = false`**, so cmd+n means a Mac
   shell. This changes new-window behaviour for your Mac panes too.
4. **`maxWorkers` default 3.** This reverses the 2026-09-21 "deliberately
   uncapped" decision, because overload is the complaint.
5. **Claude workers default to subagents.** `claude:` binds a headless
   process. An existing `orca` + claude binding becomes `subagent`.
6. **Internal names stay** (`claude-orca.json`, `CLAUDE_ORCA_*`, container
   `claude-orca-<name>`, `/opt/claude-orca`). Renaming the project is its own
   later change, if wanted.
7. **The clipboard bridge is images only, and per folder**. It is on by
   default, and `"clipboard": false` turns it off.
8. **The Mac-path symlink** inside the container, so in-project drags resolve.

## Slices

Each one is a bead under the epic. Phases A and B touch different files, so
they can run in parallel. Phase C removes Orca and lands only after A1–A3 and
B1–B2, so every commit along the way leaves a working setup. Until C1 lands,
`orca-dispatch` keeps falling back to subagents whenever Orca is unreachable.
The setup still degrades gracefully at every step.

### Phase A: workers without Orca (container only)

- **A1. Worker runtime.** `dispatch`, `worker-run`, `workers`
  (list/wait/reply/tail/stop), inbox lines under `flock`, the slot cap,
  reply-as-resume and the stall watch (ported). Files: new
  `scripts/{dispatch,worker-run,workers}.sh` and `scripts/lib/workers.sh`
  (spec composer moved from `lib/orca-orch.sh`), `bin/` links.
  Check: a real `opencode run` against the stub provider used by
  `openai-stub-real.bats`, and one real `claude -p` haiku run, in a throwaway
  repo. Both land in the inbox and the bead notes. Four dispatches with
  `maxWorkers=2` show two running and two queued. New bats per behaviour.
- **A2. /tier without Orca.** `backend` becomes `subagent|headless`, with
  migration on read. Removes the probe, updates the grammar, and changes the
  messages in tier-gate, tier-prime and recon. Also updates the rulebook
  (`config/claude-user-memory.md` § Delegation), `config/agents/{executor,scout}.md`,
  and delegation-gate's nudge text. Check: `/tier opus sonnet haiku` for real
  prints `worker=subagent:sonnet`. An old tier.json carrying `orca` migrates.
  The tier-* bats are rewritten.
- **A3. Epics in waves.** `dispatch --epic` on bead blockers plus the slot
  cap. Check: a 3-bead fixture epic with one dependency runs as two waves
  against a stub runner.
- **A4. worktree-gc without Orca.** Delete the Orca branches; worker worktrees
  live under `~/worktrees`. Check: the worktree-gc* bats, and a real sweep of a
  merged and an unmerged worker worktree.
- **A5. One runner.** `delegate run --route` executes through `worker-run`.
  Check: `delegate.bats` stays green, and one real route run.

### Phase B: the terminal

- **B1. sshd in the container.** sshd, the env snapshot, `pane-entry`, OSC 7
  and the title, the terminfo fallback, the Mac-path symlink, the restart loop
  and `run/sshd.ready`. It is added *alongside* Orca until C1. Check: a native
  entrypoint boot on this box (the `native-entrypoint-boot-on-this-box`
  recipe), then ssh in. Real Claude Code over ssh, driven by a pty: ctrl+v
  through a fixture bridge gives `[Image #1]`, and the kitty probes are
  answered. Closing the pty leaves no orphans.
- **B2. Launcher speaks ssh.** Key, host key and known_hosts generation,
  `state/ssh/config`, `claude-dev pane`, `./claude-dev` exec'ing ssh, waiting
  on `sshd.ready` instead of the web URL, the terminfo push, and doctor/verify
  rows (sshd answers, key auth, router installed). Check: the launcher bats
  with the docker stub. Then **the real launcher against the `local` runtime**
  (`CLAUDE_ORCA_RUNTIME=local`): bash launcher → booted entrypoint → sshd →
  pane. That is the whole host path except Docker and macOS itself.
  `lint-bash32` passes.
- **B3. Ghostty integration.** `config/ghostty/claude-dev.ghostty`, the
  `ghostty-pane` router, `claude-dev ghostty [--uninstall]`, and bootstrap
  installing Ghostty. Check: bats for routing over a fake folder tree (inside,
  nested, outside, opted-out, router missing), plus include idempotence and
  uninstall restoring a byte-identical config. If it installs here, Ghostty
  1.3.1's own arm64 build under Xvfb shows the shared-core behaviours for real:
  a split runs `command` in the OSC 7 directory.
- **B4. Clipboard bridge.** `scripts/mac/clip-listen` and `clip-serve`, the
  `RemoteForward` wiring, the `xclip` shim, and the listener's lifetime tied to
  the master. Check: the prototype above, made real. That means OpenBSD
  `nc`, an `osascript` stub serving fixtures (PNG, a file URL, a JPEG through a
  `sips` stub, text that must be refused), real ssh, and real Claude Code
  ctrl+v giving `[Image #1]`.
- **B5. Optional extras.** Drag from outside the project through the
  drag-pasteboard gate (JXA) and a prompt hook; cmd+v image paste through a
  `performable:` keybind plus a Claude keybinding; the bridge opening a split
  for `tier auth` and `workers tail`. Check: hook bats with a bridge stub, and
  a pty run.

### Phase C: Orca out

- **C1. Image and entrypoint.** Drop the `orca` and `orcadeps` phases,
  `ORCA_*` and `ORCA_VERSION`, Xvfb, serve/URL/pairing, `seed-orca-state`,
  `patch-orca-web-theme`, provision steps 60 and 75, `orca.yaml`, and the
  orca-state volume. sshd becomes the long-running child. Check: a native
  entrypoint boot with no Orca present, idle RSS measured before and after,
  `setup.sh --check`, and the container-* bats.
- **C2. Launcher.** Delete the desktop/web/pairing/data-dir code (about 1,100
  lines tagged ORCA in the function map), the `ui` key (ignored if present),
  the app-versioned image tag, and the orca-state volume. Teardown cleans the
  ssh state. `--update` migrates an existing folder: rebuild, recreate,
  remove the Orca volume, generate keys. Check: the launcher bats and
  lint-bash32.
- **C3. config-sync.** On the next sync, remove the Orca-managed hook entries
  (`/.orca/agent-hooks/`) and the statusline chain; delete
  `orca-hooks-merge.sh`. Check: the config-sync bats against
  `tests/fixtures/orca/claude-settings-with-orca.json` produce a settings file
  with no Orca entries and our own hooks intact.
- **C4. Docs and tests.** Delete the 14 Orca-only bats files (68 cases) and
  `tests/helpers/orca-stub.bash`, and rewrite `tests/INDEX.md`. The README
  quickstart becomes Ghostty. `knowledge-base/ORCA_INTEGRATION.md` becomes
  `TERMINAL.md` (panes, routing, images, ssh). Updates SANDBOX.md (sshd port,
  the forwarded socket, the symlink) and TIERED_ORCHESTRATION.md.
  CLAUDE.md and AGENTS.md's architecture section stays under the 1,900-word
  cap, and the Orca text it drops makes room. `tests/mac-e2e.sh` is updated to
  exercise this path: a real container, ssh in, a pane. Check: `docs.bats` and
  the files touched.

## How each slice is verified here

Everything container-side is proven by running it on this box, which is the
same Ubuntu arm64 as the image: sshd, `pane-entry`, the workers, real Claude
Code over ssh. The Mac-side scripts get the `lint-bash32` check and bats with
stubbed `osascript`/`docker`/`open`. The ssh half of the Mac path is run for
real through the launcher's `local` runtime. macOS itself, meaning Ghostty's
login wrapping, `osascript` and macOS `nc`, cannot run here. Host-side commits
therefore carry "UNVERIFIED on a Mac" in the subject, per CLAUDE.md, and
`mac-e2e.sh` (C4) checks the new path wherever it runs. After the first real
rebuild on the Mac, `.claude-dev/run/` holds the real traces: `container.log`,
`build.log`, `provision/*`, and a new `pane.log` from `claude-dev pane`.

## Risks, and the slice that retires each

| Risk | Retired by |
|---|---|
| macOS shows a pasteboard prompt on ctrl+v | B4: the read runs under Ghostty, as native Claude Code's does, so a prompt (if any) names Ghostty and "Allow" sticks |
| macOS `nc -lU` differs from OpenBSD's | B4 uses only `-l -U`, which both document. If it misbehaves, the fallback is the launchd listener (the rejected-options row) |
| The router breaks every Ghostty pane | B3: the include's `command` falls back to `$SHELL` when the router is missing, and the router `exec`s the shell on any doubt. Uninstall is one line |
| Ghostty 1.4 changes `command` or OSC 7 semantics | Nothing relies on the AppleScript preview API in the core path. B3's bats pin the routing logic, and the source references above say what to re-check |
| Old folders keep Orca hooks and worktrees | C2 and C3 migrate on `--update`. `worktree-gc` reports anything unmerged as STRANDED, as today |
| A worker cap starves a big epic | `maxWorkers` is per folder and editable. Queued jobs show in `workers` and in the status line |
