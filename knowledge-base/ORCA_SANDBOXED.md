# Orca, Sandboxed — capture for later (not implemented)

When to use: evaluating whether to run Orca (an Electron GUI for
Claude/agent worktrees) fully inside this container instead of on the
host. Captured 2026-09-03; nothing below is implemented — no script or
config in this repo does any of it. See
`.claude/plans/worktree-sessions.md`.

## What Orca is

Orca (https://www.onorca.dev, repo https://github.com/stablyai/orca, MIT
licensed) is a desktop app built on Electron. "Orca is a desktop app"
per https://www.onorca.dev/docs/install — there is no browser client;
the GUI is the Electron shell, always.

## Remote/headless mode

`orca serve` (https://www.onorca.dev/docs/remote-servers, and the
repo's `docs/reference/headless-linux-server.md`) runs a headless
runtime on a remote machine; the desktop app is still required as the
client and pairs with it over a WebSocket, default port 6768, via a
pairing URL/token. The docs mark this beta and say to keep it off the
public internet.

## SSH worktrees

https://www.onorca.dev/docs/ssh describes a separate mode: Orca opens
worktrees over SSH by installing a node-pty relay on the remote host.

## Experimental local-Docker "run on"

https://www.onorca.dev/docs/ways-to-run documents a per-worktree "run
on" mode that can boot a local Docker container from a repo-supplied
recipe (`environmentRecipes`); the recipe format itself is undocumented
there.

## The fully-sandboxed shape (not built)

None of Orca's own remote modes puts the GUI itself in a sandbox —
`serve` still needs a desktop app somewhere as the client. The shape
that would: run the Linux AppImage inside this container, on the
image's own Xvfb, with software GL (`LIBGL_ALWAYS_SOFTWARE=1`),
extracted rather than FUSE-mounted (`--appimage-extract-and-run`), as
the unprivileged container user — then export the display over VNC, to
either macOS Screen Sharing or a noVNC tab in a browser, so only pixels
and input cross the container boundary.

Orca would launch `claude` with the worktree as its cwd, picking up
`~/.claude` like any other invocation — hooks and the rulebook would
still apply — but not the `cs` wrapper, since Orca calls `claude`
directly.

## Image gaps

Already present: Xvfb, `libnss3`, `libgbm1`, `libatk1.0-0t64`,
`libasound2t64`, `libcups2t64`. Missing: `libgtk-3-0t64`, `libxss1`,
`libxtst6`, `libegl1`, and a VNC server — `tigervnc-standalone-server`
1.15, `x11vnc` 0.9.17, and `novnc` 1.6 plus `websockify` are all present
in the Ubuntu 25.10 archive.

## Costs and upgrade path

Software rendering plus VNC adds latency; a container restart kills any
agent Orca has running; updates are manual, since there is no
auto-update channel inside a sandboxed container. The upgrade path, if
this stops being good enough, is a Linux VM with a virtual GPU (UTM or
similar), using the hypervisor's own console as the viewer instead of
VNC.

## Open questions

Whether Chromium's sandbox needs extra flags to run inside Docker, and
how the VNC round trip actually feels — both untested as of this
capture.
