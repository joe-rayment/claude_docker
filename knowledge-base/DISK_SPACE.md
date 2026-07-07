# Disk Space: "container is full" is almost always the host Docker VM

When to use: `df` inside the container screams full (e.g. `/` at 100%,
bats/mkdir failing with "No space left on device"), and you need to know
what to clean. Short answer: the container itself is almost never the
problem — the number you see is the whole Docker Desktop VM disk, and the
real garbage is host-side.

## First: check for a runaway process (the case that actually happened)

Before blaming the host VM, look for a live process filling the disk from
inside — `du` scans miss it because the space is churning and gets cleaned
when the process dies, making the fill look "mysterious":

```
ps -ef | grep -E 'bats[-]core|run[-]tests'   # this repo's known offender
ls -d /tmp/bats-run-* | wc -l                # hundreds = recursion in progress
```

The 2026-07-06 disk-full incident was exactly this: the baked smoke test
"run-tests.sh accepts smoke argument" ran `run-tests.sh smoke | head -1`,
which re-runs the full suite containing itself — unbounded recursion, each
level writing `/tmp/bats-run-*` dirs (measured: ~8G and 401 dirs in minutes)
until resource exhaustion unwound it and bats cleanup erased the evidence.
Fixed in repo `tests/smoke.bats` (2026-07-07); the baked copies stay armed
until the next image rebuild. Do not invoke `run-tests.sh` at all pre-rebuild —
the installed runner also predates `CLAUDE_DEV_TESTS` and silently ignores it,
so every invocation reaches the armed baked suite. Run `bats
/workspace/tests/smoke.bats` directly instead.

## The trap that wastes 30 minutes

`df -h /` and `du -x /` disagree by ~100x:

```
df -h /            # overlay 224G, 189G USED, 89% full
du -xsh /*         # sums to ~3G  (staying on one device with -x)
```

That gap is the whole diagnosis. `df` on the `overlay` / `/dev/vda1`
filesystems reports usage of the **entire Docker Desktop VM disk** — every
image, build-cache layer, stopped container, and other project's volume on
the host — not this container's writable layer. Both `/` and `/home/agent`
show the *same* used figure because they are backed by the same VM disk.

Proof it is host-side, not in-container (run these — all three confirm):

```
du -xsh /* /home/agent/* | sort -rh   # entire reachable tree ~4.5G, all working set
ls /var/lib/docker                    # DOES NOT EXIST inside — daemon storage is on host
ls -la /var/run/docker.sock           # NOT mounted — can't even prune from inside
```

If `du -x` accounts for only a few GB but `df` says hundreds, stop looking
inside the container. There is nothing meaningful to delete here.

## What IS reachable (and whether it's worth clearing)

Entire container footprint is ~4.5G, essentially all active working set:

| Path | Size | Clear it? |
|------|------|-----------|
| `/home/agent/.cache/ms-playwright` | ~960M | **No** — breaks `take-screenshot` + 4 smoke tests |
| `/home/agent/.local/share/claude/versions` | ~250M | No — the Claude CLI itself (one version, no stale copies) |
| `/home/agent/.claude/plugins` | ~250M | No — live plugin cache/marketplaces |
| `/usr`, `/opt/claude`, `bd`, `dolt`, `node` | ~3G | No — installed tooling |
| `~/.cache/go-build`, npm cache, `/var/cache/apt` | ~100-200M | **Yes, safe** — `go clean -cache`, `npm cache clean --force`, `apt-get clean` |

The only safe in-container reclaim is the build/package caches (last row) —
recovers ~100-200M and they just repopulate. Do that, but don't expect it
to move the `df` number: it won't, because the number isn't about the
container.

```bash
go clean -cache; npm cache clean --force; rm -rf /home/agent/.cache/go-build; apt-get clean
```

## The real fix (host-side — cannot be done from inside the container)

No Docker socket is mounted, so the daemon is unreachable from here. Run on
the **host** (macOS/Linux terminal, not the container). Safe, high-yield,
in order of typical payoff:

```bash
docker builder prune -a      # build cache — usually the #1 hog, 100% safe (rebuilds slower once)
docker image prune -a        # unused images — safe, re-pullable/re-buildable
docker container prune       # stopped containers
docker system df             # itemize before/after to see what freed
```

**Do NOT run `docker system prune --volumes` blind.** This dev container's
`/home/agent` is a *persistent named volume* (auth, git config, bd data). A
`--volumes` prune while the container is stopped will wipe it. Only prune
volumes you can name and don't need.

macOS caveat — space won't return until `Docker.raw` is compacted: even
after a successful prune, the VM disk image (`~/Library/Containers/
com.docker.docker/Data/vms/0/data/Docker.raw`) does not shrink on its own.
Newer Docker Desktop compacts automatically; otherwise use Docker Desktop →
Settings → Resources → Advanced (disk image), or its "Clean / Purge data".
Also check the macOS disk itself — if the Mac volume backing Docker is near
full, that caps everything regardless of pruning.

## One-line takeaway

First rule out a live runaway process (`ps` before `du` — a recursing test
suite filled the disk from inside this very container). Then: container full
+ `du -x` shows only a few GB + no `/var/lib/docker` + no `docker.sock` =
host-side Docker VM garbage. Clear the safe caches inside
(marginal), then run `docker builder prune -a` / `docker image prune -a` on
the host. Nothing inside the container is the cause.
