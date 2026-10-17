# The terminal: Ghostty panes into the sandbox

You work in [Ghostty](https://ghostty.org), a normal Mac terminal. Each pane
you open in a sandboxed folder is an ordinary `ssh` session into that
folder's container. There is no UI inside the container and no browser tab:
the only thing running there besides your shells is a small SSH server
(`sshd`). That is why an idle sandbox costs about 36 MB of memory, where the
old Orca web UI cost about 765 MB (both measured on a real boot).

## Getting started

```
cd ~/projects/myapp     # a folder you have already registered
./claude-dev            # starts the container, waits for sshd, opens a pane here
./claude-dev ghostty    # once per Mac: makes every new Ghostty tab do that for you
```

After `./claude-dev ghostty`, open a Ghostty tab or split inside a
registered folder and you land in that folder's sandbox. Anywhere else you
get your normal Mac shell. `./claude-dev --how-to-run` prints these steps.

## Where am I? Sandbox pane or Mac shell

A sandbox pane has the folder's colour as its text colour and a tab title like
`myapp ▸ src/lib`, and `pwd` starts with `/workspace/`. A Mac shell looks
like it always did.

When a sandbox pane cannot start (Docker is stopped, sshd never came up), the
pane does not fail silently. It prints the reason on stderr, then
`== Mac shell -- NOT sandboxed ==`, then drops you into your Mac shell so
the window is not wasted. If you see that banner, nothing you type is
protected: run `./claude-dev --doctor`, fix the red row, and open a new pane.

## How a pane finds its sandbox

Ghostty's `command` setting names the program every new pane runs. The
include file that `claude-dev ghostty` installs points it at a tiny router,
`~/.local/share/claude-dev/ghostty-pane`:

1. Walk up from the pane's directory to the first folder that holds
   `.claude-dev/claude-orca.json` (at most 40 levels).
2. Found, and `claude-orca.json` does not say `"route": false` -> run that
   folder's `./claude-dev pane <folder>`.
3. Anything else, or any doubt -> your normal `$SHELL -l`. The router never
   prints an error and never starts Docker itself.

`claude-dev pane` is also the command to type by hand. When the folder's
ssh connection is already up it is the **fast path**: no Docker call, just
a new channel on the connection, so a pane opens in milliseconds.
Otherwise it takes the slow path (`./claude-dev` itself: start the container,
wait for sshd). `run/pane.log` records `slow` or `fast` per pane.

To opt one folder out of routing, set `"route": false` in its
`.claude-dev/claude-orca.json`. Its panes are Mac shells again, and
`./claude-dev` still works there.

## What `./claude-dev ghostty` changes on your Mac

Three things, nothing else:

| What | Where |
|---|---|
| the include (settings) | `claude-dev.ghostty`, beside your Ghostty config |
| the router, a copy | `~/.local/share/claude-dev/ghostty-pane` |
| one line added to your Ghostty config | `config-file = ?claude-dev.ghostty` |

The include sets `command` (the router), `shell-integration` (so Mac panes
keep Ghostty's prompt marks) and `window-inherit-working-directory = false`.
It is idempotent, so run it again after `--update`; the router is refreshed
for you whenever the template's version is newer. Settings apply to *new*
panes; reload with cmd+shift+, or restart Ghostty.

- `./claude-dev ghostty --check` asks Ghostty itself whether the include
  applied and whether cmd+d / cmd+shift+d still split (two rows, also shown by
  `--doctor` and `verify`).
- `./claude-dev ghostty --uninstall` removes all three and gives your config
  back byte for byte.
- It refuses, and touches nothing, if your config already sets `command =`
  yourself: that setting *is* the routing, so two would fight.

## Keys

Ghostty's own defaults do the work; claude-dev binds nothing.

| Want | Press |
|---|---|
| Another pane in the same sandbox, right / below | cmd+d / cmd+shift+d (or right-click, Split) |
| A new tab in the same folder | cmd+t |
| A Mac shell | cmd+n (a new **window** starts in your home folder) |
| Paste a screenshot into Claude Code | ctrl+v |
| Watch a worker | split with cmd+d, then `workers tail <bead>` |
| See what Claude Code is doing | split with cmd+d, then `activity` (below) |

A split lands in the same subfolder because the shell reports its location
to Ghostty (OSC 7, from a `precmd` hook in the shipped `.zshrc` that runs
only in sandbox panes). The first pane of a brand-new folder also runs the
startup menu (beads, GitHub, Claude Code); later panes get one identity line.

## The activity panel

`activity`, typed in any sandbox pane, takes over that pane with one page of
plain English about what Claude Code and its executors are doing: the request
in hand, which workers are running, what changed. It is per folder (it reads
this folder's `.claude-dev/run`), so a split of a sandbox pane shows that
folder's page. Put it beside your work with cmd+d, then type `activity` in the
new pane.

- **The page is a summary, written by a cheap model through the guard**, and
  only while a panel is open: no panel, no model calls. `"activity": false` in
  `claude-orca.json` turns the model off; the footer then says "turned off in
  claude-orca.json" in place of the model name.
- **It refreshes about once a minute**, and sooner when a new request starts
  or an executor joins or leaves. When a new request starts the page clears
  and begins again, so it never mixes two requests.
- **No scrolling.** The page is cut to fit the pane and ends in `...` when
  there was more; make the pane taller to see more. The last line says how old
  the page is and which model wrote it.
- **`q` (or ctrl-c) quits** and gives the pane back as it was.
- **Logs**, for "why did it not update": `.claude-dev/run/activity/panel.log`
  has one line per refresh saying why it ran (first run, cadence, new request,
  which workers joined or left); `calls.log` in the same folder has one line
  per model call.

There is no dedicated key. A Ghostty keybind chain (`new_split:right`, then
`text:activity\r`) was measured on Ghostty 1.3.1 and types into the pane the
key was pressed in, not the new split, which would submit "activity" as a
message to Claude Code. Use cmd+d and type the word.

## Images and the clipboard

Claude Code on Linux reads the clipboard only by running `xclip`. The
container has no display, so `bin/xclip` is a small shim (a symlink to
`scripts/container/xclip`, first on `PATH`) that asks the Mac instead.

```
Claude Code -> xclip shim -> /tmp/cdev-clip.sock -> (ssh RemoteForward) -> Mac clip-serve
```

- **Mac to container: images only.** Screenshot to the clipboard
  (cmd+ctrl+shift+4) or copy an image in a browser or Finder, then ctrl+v in
  Claude Code. It answers `[Image #1]`. Anything that is not an image
  (`xclip -o` for text) exits 1 without asking the Mac, so nothing in the
  sandbox can read a password off your clipboard.
- **Container to Mac: text.** `xclip -i` posts up to 1 MB to the Mac's
  `pbcopy`.
- Dragging a file from inside the project onto a pane pastes its Mac path,
  which Claude Code resolves. A file from outside the project is not
  reachable; copy it in Finder (cmd+c) and ctrl+v instead.
- Off switch: `"clipboard": false` in `claude-orca.json` removes the
  forward. The shim then exits 1 quietly and nothing listens on the Mac.

The Mac end is `clip-listen` (a unix socket at
`~/.local/state/claude-dev/clip-<name>.sock`, mode 600) running `clip-serve`
once per request. `claude-dev pane` starts it; it stops by itself a minute or
so after the folder's ssh connection ends. macOS may ask once to let Ghostty
read the pasteboard; allow it. If ctrl+v does nothing, run
`CLAUDE_ORCA_CLIP_DEBUG=1 xclip -selection clipboard -t TARGETS -o` in the
pane; the shim then prints curl's error instead of staying silent.

## The ssh behind it

Everything lives in `<project>/.claude-dev/state/ssh/`, never in `~/.ssh`:

| File | What it is |
|---|---|
| `client_ed25519`, `.pub` | this folder's login key; created on first open |
| `host_ed25519`, `.pub` | the container's host key (copied into it at start) |
| `authorized_keys` | the one client key, with `restrict,pty,port-forwarding` |
| `known_hosts` | the host key under the alias `claude-dev-<name>`; ssh runs with `StrictHostKeyChecking yes`, so there is no "trust this host?" prompt and no man-in-the-middle window |
| `config` | rewritten on every open: `127.0.0.1`, the folder's published port, `ControlMaster auto`, `ControlPersist 30m`, the clipboard `RemoteForward` |

The master socket sits under `~/.local/state/claude-dev/` (a literal path
short enough for a unix socket). The server accepts only that key, only for
user `agent`, and refuses TCP forwarding; the one forward it allows is the
clipboard's unix socket. Your terminal name and the current subfolder travel
as environment variables, and the container maps `xterm-ghostty` to
`xterm-256color` unless the Ghostty terminfo was installed, which
`./claude-dev` does for you (`infocmp -x xterm-ghostty | tic`).

Closing a pane hangs up its shell (and what that shell was running).
`./claude-dev stop` also stops the clipboard listener, and `--teardown`
closes the shared ssh connection too.

## When something is wrong

| Symptom | Look at |
|---|---|
| Pane says `NOT sandboxed` | the reason line above it; `./claude-dev --doctor` |
| `./claude-dev` waits, then gives up on sshd | `./claude-dev logs`, `.claude-dev/run/sshd.log`; the supervisor retries every 5 s, so a missing key fixes itself once `--update` creates it |
| `ssh key auth` row is red in `--doctor` | the container predates this folder's key: `./claude-dev --update` |
| New tabs are Mac shells | `./claude-dev ghostty --check`; also `"route": false` or a `command =` of your own |
| ctrl+v pastes no image | the clipboard bridge above; `"clipboard": false`? |

See [SANDBOX.md](SANDBOX.md) for the boundary itself and
[TEARDOWN_RECOVERY.md](TEARDOWN_RECOVERY.md) for removing a folder.
