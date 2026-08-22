# Code Map — the per-repo code graph, and the guard around its engine

When to use: you want structure rather than string matches ("what calls
this", "what breaks if I change that"), you hit `graphify … is blocked in
this container`, or you need to upgrade/repair the graph engine. The
front end is `code-map`; the engine is `graphify`, and you never call it
directly.

Everything below was re-verified on **2026-08-22** against engine
`graphify 0.9.48` on this container, with the command that re-checks it.

## First: the shims may not be on PATH yet

`code-map`, `code-map-prime` and the `graphify` guard are staged into
`/usr/local/bin` by the image. On a container whose image predates the
feature they are simply absent — staleness, not breakage, the same shape
`CONFIG_SYNC.md` documents for every other staged artifact. Check, and
fall back to the repo copies:

```bash
command -v code-map graphify              # empty output = not staged yet
bash /workspace/scripts/code-map.sh doctor        # drives the shim from the repo
sh  /workspace/scripts/code-map-guard.sh version  # drives the guard from the repo
```

The staged-vs-repo split is asserted by the smoke test named
`code-map is staged` (grep it in `tests/smoke.bats`); that test is RED
until the next host rebuild and green after. Behavior is covered
independently from the working tree by `tests/code-map.bats`.

Every `code-map …` example below therefore reads
`bash /workspace/scripts/code-map.sh …` on a pre-rebuild container.

## What it is

A knowledge graph of this repo's code, built from tree-sitter ASTs, kept
in `graphify-out/` at the repo root.

- **Local AST, no API key** for `build`, `refresh` and every query:
  `code-map build` runs `graphify extract --code-only`, documented in the
  engine's own help as "index code (local AST, no API key)". The LLM path
  is opt-in per provider key and is never on this path. (`upgrade` is a
  package install and does reach the network.)
- **Engine**: `graphifyy` (two y's — the PyPI name; the CLI it installs is
  `graphify`), pinned in the `Dockerfile`, Apache-2.0
  (`License-Expression: Apache-2.0` in the wheel metadata).
- **Gitignored the polite way**: `graphify-out/` is added to
  `.git/info/exclude`, never the project's `.gitignore`, by every
  `code-map build` (`exclude_hygiene` in `scripts/code-map.sh`).
- **Kept current automatically** by the `code-map-prime` SessionStart
  hook, which refreshes the graph and prints the `[code-map]` block.

```bash
bash /workspace/scripts/code-map.sh status
# root: /workspace
# graph: /workspace/graphify-out/graph.json
# nodes: 629
# links: 868
# built_at_commit: e1d2db56b62e4d675aa6473aba4e58ec934f647e
# HEAD: e1d2db56b62e4d675aa6473aba4e58ec934f647e
# state: fresh
```

## Daily use

| Command | What you get |
|---|---|
| `code-map status` | node/link counts, `built_at_commit` vs `HEAD`, `fresh`/`STALE` |
| `code-map refresh` | update the graph (builds one if there is none) |
| `code-map explain "<sym>"` | what a symbol is, and every edge in and out of it |
| `code-map affected "<file>"` | what breaks if it changes |
| `code-map path "A" "B"` | shortest path between two nodes |
| `code-map query "<q>"` | traversal answering a question |
| `code-map god-nodes` | the most connected nodes |
| `code-map report` / `html` | print `GRAPH_REPORT.md` / the path to `graph.html` |
| `code-map doctor` | engine, versions, graph state, exclude entry |

**Freshness.** `state: fresh` means the graph's `built_at_commit` equals
`HEAD`; anything else is `STALE`. The engine only stamps that field when
it actually rewrites the graph, so the shim re-stamps after any
successful build or refresh (`stamp_commit` in `scripts/code-map.sh`) —
without it a genuinely-current graph would keep reporting `STALE`.

**Queries work from subdirectories.** The engine resolves its `--graph`
default against the *current* directory, so the shim appends
`--graph <root>/graphify-out/graph.json` — unless you passed a `--graph`
yourself, in which case yours wins untouched:

```bash
cd /workspace/tests && bash /workspace/scripts/code-map.sh explain "cmd_doctor"
```

**The session block.** `code-map-prime` prints two lines into context at
session start — counts, the 8-char commit, `fresh`/`STALE`, the queries
worth reaching for, and the standing reminder that INFERRED edges are
hints. It is silent by design when there is no graph to talk about: not a
git repo, no code files, no `code-map` on PATH, `CODE_MAP_DISABLE` set,
or an unreadable status. Its own chatter goes to
`.claude/logs/code-map.log`, never into context.

```bash
CODE_MAP_DISABLE=1 sh /workspace/scripts/code-map-prime.sh | wc -c   # 0
```

## Architecture — one seam, two files

```
PATH:   /usr/local/bin/graphify   →  scripts/code-map-guard.sh  →  engine
        /usr/local/bin/code-map   →  scripts/code-map.sh        →  engine
OFF PATH (engine, in resolution order):
        ~/.local/lib/code-map/bin/graphify      # `code-map upgrade` writes here; wins
        /opt/code-map/bin/graphify              # the image's pinned engine
```

The guard **is** the only `graphify` on PATH. The engine ships into its
own prefix that is deliberately not on PATH, so the guard is the only way
to reach it by name. Neither script resolves the engine through PATH —
the guard would exec itself forever, and the shim would bounce every call
through the allowlist for nothing.

**The seam:** every engine invocation in this project lives in
`scripts/code-map.sh` and `scripts/code-map-guard.sh`. Swapping engines
touches those two files and nothing else.

```bash
# no other script reaches the engine — this prints nothing
grep -ln 'graphify' /workspace/scripts/*.sh | grep -v code-map
```

## Upgrades — the supported path

```bash
code-map upgrade            # latest
code-map upgrade 0.9.48     # a specific version
```

`upgrade` runs `uv tool install --force` with `UV_TOOL_DIR` and
`UV_TOOL_BIN_DIR` redirected under `$HOME/.local/lib/code-map`, then
smoke-tests the result and refreshes an existing graph. Because `$HOME`
is a persistent volume, the override survives container restarts **and**
image rebuilds, and it shadows the image's pinned engine. A bad upgrade
is undone by deleting that prefix.

**Never add that bin directory to PATH.** `uv` prints an
`export PATH=…` suggestion after installing; following it puts the raw
engine ahead of the guard and every installer subcommand becomes
reachable again. The smoke test asserts the guard's primacy behaviorally
(`[ "$(command -v graphify)" = /usr/local/bin/graphify ]`), so this trips
a test rather than failing silently.

**The override is per-container; the pin is durable.** `doctor` compares
the two and says so:

```
image pin: graphifyy==0.9.48 (from /workspace/Dockerfile)
note: the override (X) differs from the image pin (Y) — the durable fix is
to bump the pin in /workspace/Dockerfile and rebuild
```

So: `code-map upgrade` to try a version now, bump the `graphifyy==` pin in
the `Dockerfile` and rebuild to make it stick for everyone.

## Why `graphify install|uninstall|hook` are blocked

The guard runs **deny-by-default**: an allowlist of graph subcommands
(`extract`, `update`, `cluster-only`, `query`, `explain`, `path`,
`affected`, `tree`, `god-nodes`, `diagnose`, `label`, `watch`,
`merge-graphs`, `merge-driver`, `export`, `benchmark`, `version`, `help`,
plus bare `--version`/`--help`) execs the engine; everything else exits
**2** with a pointer at `code-map`. Unknown future subcommands therefore
fail closed.

```bash
sh /workspace/scripts/code-map-guard.sh claude install; echo $?   # 2
sh /workspace/scripts/code-map-guard.sh version;        echo $?   # 0
```

Upstream ships ~20 per-platform installers, and they write exactly the
files this container generates from the image:

- **`~/.claude/skills/`** — the installers write a `SKILL.md` there
  (grep `skills` in the engine's `install.py`). The entrypoint deploys
  that whole directory from `/etc/claude-dev/configs/skills/` on every
  start.
- **`~/.claude/CLAUDE.md`** — `claude install` registers a `# graphify`
  section in it. The entrypoint overwrites that file from the image every
  start (grep `claude-user-memory.md` in `scripts/entrypoint.sh`), so the
  registration would silently vanish anyway.
- **A PreToolUse hook** — `claude install` adds one, stacking on this
  template's existing gate chain (`bd-guard`, `delegation-gate`,
  `tier-gate`, `contract-gate`).
- **Deletion, not just drift** — `uninstall` strips its section from the
  user-scope `CLAUDE.md`, but for a *project-scoped* `<project>/.claude/
  CLAUDE.md` whose entire content was that section it calls `unlink()`
  and prints `CLAUDE.md -> deleted …` (grep
  `_remove_claude_skill_registration` in `install.py`).

Config written out of band here is reverted at the next session start, or
sticks around as unexplained drift. Hence the block, and hence
`code-map upgrade` as the one sanctioned way to change the engine.

## What the graph sees — and what it does not

Measured on this repo, 2026-08-22, 629 nodes / 868 links:

```bash
jq -r '[.links[].relation] | group_by(.) | map({k:.[0],n:length})
       | sort_by(-.n) | .[] | "\(.n)\t\(.k)"' /workspace/graphify-out/graph.json
```

- **Call edges are real, including in shell.** Shell sources yield
  `calls` 149 / `defines` 127 / `contains` 27 — about half the edges from
  `.sh` files are genuine function→function calls, which is precisely
  what `csearch sig` cannot give you. Structural containment is the other
  half.
- **The containment label is language-dependent.** For Python, `contains`
  *is* file→function and there are zero `defines` edges; for shell,
  `defines` is file→function and `contains` points a file at its
  `__entry` pseudo-node. Do not generalize one language's label to
  another.
- **`.bats` and `Dockerfile` are not parsed at all.** The engine says so
  itself: `2 file(s) not classified (no supported extension or shebang),
  skipped: Dockerfile, thing.bats`. With 14 `.bats` files in this repo,
  zero appear as a `source_file`:

  ```bash
  jq -r '[.nodes[] | select((.source_file//"") | endswith(".bats"))] | length' \
      /workspace/graphify-out/graph.json    # 0
  ```

- **Config-mediated coupling is invisible.** A hook wired in
  `claude-settings.json` is a real dependency that no AST sees. The graph
  will not connect `settings.json` to the script it invokes.
- **`INFERRED` edges are hints.** Every edge carries `EXTRACTED` or
  `INFERRED`; this repo's graph is 867 `EXTRACTED` to 1 `INFERRED`.
  `explain` prints the label inline. Verify an `INFERRED` edge before
  acting on it. Aggressive inference is opt-in (`--mode deep`) and needs
  a key.

### `build` and `refresh` are different passes — this is not a bug

`code-map build` runs `extract --code-only`, which skips doc/paper/image
files entirely. `code-map refresh` runs `update` **without**
`--code-only`, which additionally extracts *structural* markdown headings
— keylessly. So the first refresh after a build legitimately raises the
counts on a tree that did not change, then holds steady. Observed on a
throwaway fixture (one `.py`, one `.sh`, one `.md`, one `.bats`, one
`Dockerfile`):

```
build       7 nodes,  8 edges     # .md, .bats, Dockerfile all absent
refresh #1  10 nodes, 10 edges    # +3 heading nodes from the .md
refresh #2  10 nodes, 10 edges    # stable
```

The freshness contract is unaffected — the shim stamps `built_at_commit`
either way. What *does* need a key is the **semantic** layer over docs: a
plain `graphify extract` (no `--code-only`) with a doc file present and
no key exits 2 with `no LLM API key found (1 doc/paper/image file(s) need
semantic extraction)`.

### Smaller sharp edges

- `code-map tree` writes `graphify-out/GRAPH_TREE.html` as a side effect
  (verified: absent before the call, present after) — it is not a
  read-only query.
- `code-map report` needs `GRAPH_REPORT.md`, which comes from the
  clustering pass. `build` runs that pass but treats a failure as
  non-fatal (the graph is the artifact that matters), so a clustering
  failure leaves you with a graph and no report; `code-map refresh`
  writes one when the code graph has changed.
- `graphify-out/` also accumulates a `cache/` directory and may hold
  dated snapshot subdirectories. All of it sits inside the excluded
  directory and is harmless.
- `GRAPHIFY_OUT` relocates the output (bare name or absolute path); the
  shim mirrors that resolution, and `exclude_hygiene` excludes the new
  directory too. `CODE_MAP_DISABLE=1` silences the session hook.

## Troubleshooting

**Always start with `code-map doctor`.** It reports the engine in use,
both candidate engines, the image pin, override-vs-pin drift, graph
freshness, and the `.git/info/exclude` entry.

| Symptom | Cause and fix |
|---|---|
| `code-map: command not found` | Shims not staged; the image predates the feature. Drive the repo copies (`bash /workspace/scripts/code-map.sh …`) until the next host rebuild. |
| `graphify engine not found` (exit 3) | Neither engine present. `doctor` says `image engine: … absent`; install the override with `code-map upgrade 0.9.48`. |
| `graphify … is blocked` (exit 2) | Working as designed — see the block section above. Use `code-map`; upgrade via `code-map upgrade`. |
| `state: STALE` | `code-map refresh`. If it stays stale, the engine found no topology change and the shim's stamp did not run — check the log. |
| Graph looks wrong or truncated | `rm -rf graphify-out && code-map build && code-map refresh` (the refresh is what picks up doc headings). |
| `no GRAPH_REPORT.md` | The clustering pass has not run for the current graph: `code-map refresh`. |
| Session block never appears | One of the deliberate silent gates in `scripts/code-map-prime.sh`: not a git repo, no code files, `CODE_MAP_DISABLE` set, no shim resolvable, or unreadable status. The log at `.claude/logs/code-map.log` shows what the refresh did. |
| `jq is required for this command` | `status` and the stamp need `jq`. Install it; the stamp silently no-ops without it, which is how a graph goes permanently `STALE`. |
