# The isolation boundary

The project folder gets its own Linux virtual machine, and everything an
agent runs happens inside it. There is no second mechanism: no profile to
audit, no allowlist to tune, no wrapper to bypass. If it is not mounted into
the VM, it does not exist as far as any agent is concerned.

## What is inside

| Path in the VM | What it is |
|---|---|
| `/workspace/<name>` | the project folder, bind-mounted read-write. Not the Mac's own absolute path — a container that spelled out your home directory and folder tree at every prompt was no sandbox at all. The Mac path still rides in as `CLAUDE_ORCA_HOST_PROJECT_DIR`, for messages that name a file to open on the Mac. |
| `/home/agent` | `<project>/.claude-dev/home` on the Mac: Claude's credentials, the git identity, the synced `.claude` config dir. |
| whatever `claude-orca.json` names in `extraMounts` | mounted **read-only**, always. |

Nothing else from the Mac's filesystem is present. A runaway `rm -rf /`
inside the VM destroys the container, the project folder and that folder's
home — and nothing else on the Mac.

## What crosses the boundary, on purpose

- **One published port**, bound to `127.0.0.1` on the Mac only. It reaches
  the container's `sshd` (inside it listens on 2222 unless
  `CLAUDE_ORCA_SSHD_PORT` says otherwise; the launcher sets that to the
  folder's own port). Login is key-only, as the user `agent`; the keys live
  in `<project>/.claude-dev/state/ssh`. Every Ghostty pane is one `ssh`
  session through this port — see [TERMINAL.md](TERMINAL.md).
- **One forwarded unix socket**, `/tmp/cdev-clip.sock` inside the container.
  Each pane's `ssh` carries it back (a `RemoteForward`) to a small clipboard
  server on the Mac, and the `bin/xclip` symlink (to
  `../scripts/container/xclip`) talks to it. Images only ever travel from
  the Mac to the container, never the other way. Set `"clipboard": false` in
  `claude-orca.json` and the forward is not made.
- **`GH_TOKEN`**, passed in as an environment variable at `container run`
  from the Mac's own `gh auth token`, so `gh` and `git` over HTTPS work
  inside. It is struck out of `.claude-dev/run/container.log`.
- **Egress.** The VM reaches the network the way the Mac does. There is no
  per-domain allowlist; an in-VM egress filter is a possible later slice
  (`.claude/plans/container-v3.md` §8), not something this design has today.

## Checking it

```bash
./claude-dev --doctor
```

One row per thing that has to be true for the folder to open: the `docker`
CLI, the Docker daemon, the image (and where it came from), the project, the
container, the port (published on `127.0.0.1`), the OpenRouter key (optional),
each provisioning step, `sshd` (does it answer with an SSH banner), the ssh
master connection (panes reuse one), key auth (does this folder's key log
in), and the Ghostty settings and splits. It exits 2 on any finding, so it
is usable in a script. Rows name files and never their contents. For the pane
side of a problem, see [TERMINAL.md](TERMINAL.md).

`./claude-dev shell` puts you in the VM, in the project directory, with the
same home the agents use — the fastest way to confirm what is and is not
visible from inside.

## The bash 3.2 rule

macOS ships bash 3.2.57, and `bootstrap.sh` and `scripts/launcher.sh` run on
the Mac. Both stay inside 3.2: no associative arrays, no `mapfile`, no
`${x^^}`, no `+=` onto an empty array under `set -u`.
`scripts/lint-bash32.sh` and a real 3.2 build in the test suite enforce it.
Scripts under `scripts/container/` run only inside the image and are free of
this constraint.
