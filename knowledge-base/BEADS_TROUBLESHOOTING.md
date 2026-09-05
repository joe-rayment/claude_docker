# Beads Troubleshooting

Beads (`bd`) runs in **embedded Dolt mode** — no SQL server. The live database is `<project>/.beads/embeddeddolt/` (gitignored); `<project>/.beads/issues.jsonl` is a passive, git-tracked export used to rebuild the database. Always modify issues via `bd` commands, never by editing the JSONL.

## Self-healing

Repair a database holding 0 issues with: `bd init --prefix <p> --quiet --non-interactive` (re-establishes the Dolt workspace) followed by `bd import` (upserts issues from `issues.jsonl`). Run the same pair manually any time the database misbehaves:

```bash
cd <project> && bd init --prefix <p> --quiet --non-interactive && bd import
```

Replace `<p>` with the project's issue prefix — take everything before the final `-<suffix>` of any existing issue ID (e.g. `beads_claude_docker-o15` → `beads_claude_docker`); `.beads/metadata.json`'s `dolt_database` field usually agrees too, but can diverge if `bd init --database` was used.

**If `bd init` itself refuses** with `Found existing Dolt database ... already initialized` (exit 1) — a broken workspace directory is present, e.g. missing its `issue_prefix` config, the exact corruption behind beads_claude_docker-o15 — `bd import` alone then also fails (`issue_prefix config is missing`), because a plain `bd init` won't touch an existing directory. Remove the broken workspace first; this is safe, `issues.jsonl` is a sibling file, not stored inside it:

```bash
rm -rf .beads/embeddeddolt && bd init --prefix <p> --quiet --non-interactive && bd import
```

Verified in-sandbox 2026-08-07: with `embeddeddolt/` present but its `issue_prefix` row deleted, the two-line recipe above exits 0 and restores every issue; without the `rm -rf` first, both `bd init` and `bd import` exit 1.

Don't reach for `bd init --reinit-local`/`--force` as the fix even though bd's own "already initialized" error suggests it — that flag authorizes overwriting the local database and, in the beads_claude_docker-o15 incident, committed the deletion of `issues.jsonl` itself (91 closed issues' history, recovered only because an older git commit still had a copy). `bd-guard` blocks it while `issues.jsonl` has uncommitted changes.

`bd doctor --fix --yes` is **unsupported in embedded Dolt mode**, confirmed 2026-08-07: it prints `Note: 'bd doctor' is not yet supported in embedded mode.` and exits 0 without repairing anything. It is not called anywhere in `ensure_beads()`.

## Stuck rebase (`git pull --rebase` wedged on a clean tree)

`git rebase` (interactive, single-commit pick during `pull --rebase`) can get
stuck showing the SAME commit as both "Last command done" and "Next command to
do" in `.git/rebase-merge/git-rebase-todo`, and repeatedly errors
"Your local changes ... would be overwritten by merge" on a genuinely clean
working tree (`git diff` / `git diff --cached` both empty).

**Recovery that worked:** confirm `git status` shows a truly clean tree, then
run `git rebase --continue` directly. Do **not** keep re-running
`git pull --rebase` — it re-enters the same bad state.

**Unconfirmed hypothesis** (from a parallel scout investigation): the beads
post-checkout hook (`bd hooks run post-checkout`) dirties the tree between
checkout and cherry-pick. Manually invoking that hook produced zero file
changes in the original session, so treat this as an open hypothesis, not a
fix; root cause never fully isolated. Ref: session 2026-08-10, commit
`4576aa2` rebase onto `53ace0a`, landed as `a30c558`, pushed clean.

## Common issues

| Symptom | Fix |
|---------|-----|
| `bd` hangs an agent session | You ran `bd edit` — it opens `$EDITOR` and blocks. Use `bd update <id> --title/--description/--notes` instead |
| Database corrupt / weird errors, incl. "issue_prefix config is missing" | `bd init --prefix <p> --quiet --non-interactive && bd import`, rebuilding from `issues.jsonl`; if `bd init` refuses, `rm -rf .beads/embeddeddolt` first (see Self-healing above) |
| Issues missing after teardown/resume | The embedded DB rebuilds from the restored `issues.jsonl` on the next `bd` run; run `bd list --status=open` to confirm |
| Priority rejected | Use `0-4` or `P0-P4`, not `high`/`medium`/`low` |
| Sync conflicts with remote | Sync uses `refs/dolt/data` on the git remote — see <https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md> |

## Rules worth remembering

- Beads track Claude Code's own work only — never assign a bead to a human (`--assignee` is off-limits for humans; the only valid claim is Claude's own `--claim`).
- Include issue IDs in commit messages: `Fix auth bug (bd-a3f2)`.
- `bd remember "insight"` stores persistent project knowledge; search with `bd memories <keyword>`.
