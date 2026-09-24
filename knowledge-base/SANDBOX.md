# The isolation boundary

The project folder gets its own Linux virtual machine, and everything an
agent runs happens inside it. There is no second mechanism: no profile to
audit, no allowlist to tune, no wrapper to bypass. If it is not mounted into
the VM, it does not exist as far as any agent is concerned.

## What is inside

| Path in the VM | What it is |
|---|---|
| `/workspace/<name>` | the project folder, bind-mounted read-write. Not the Mac's own absolute path — a container that spelled out your home directory and folder tree at every prompt was no sandbox at all. The Mac path still rides in as `CLAUDE_ORCA_HOST_PROJECT_DIR`, for messages that name a file to open on the Mac. |
| `/home/agent` | `<project>/.claude-dev/home` on the Mac: Claude's credentials, Orca's state, the git identity, the synced `.claude` config dir. |
| whatever `claude-orca.json` names in `extraMounts` | mounted **read-only**, always. |

Nothing else from the Mac's filesystem is present. A runaway `rm -rf /`
inside the VM destroys the container, the project folder and that folder's
home — and nothing else on the Mac.

## What crosses the boundary, on purpose

- **One published port**, bound to `127.0.0.1` on the Mac. That is how your
  browser reaches Orca. The pairing URL is written to
  `<project>/.claude-dev/run/orca-web-url.txt` with mode 600, because its
  fragment carries the pairing code — treat that file as a credential.
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

Six rows, one per thing that has to be true for the folder to open: the
`container` CLI, the container service, the image, the container's state, the
port, and whether the web URL has been published. It exits 2 on any finding,
so it is usable in a script. The URL row names the file and never its
contents.

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
